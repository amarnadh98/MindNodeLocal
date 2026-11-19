import Foundation
import MapCore
import MapStudy

/// Headless (closed-document) file access (SPEC §11.3, F-INT-4): every
/// mutation is `[MapCommand]`s applied to the loaded model inside ONE
/// `NSFileCoordinator` write coordination, then written back as a single
/// atomic package save — never a partial write. Edits carry their author
/// (`mcp`, or `.user` for URL/Services/intent actions), stamped on the
/// touched nodes exactly like `MapStore` stamps them.
public enum HeadlessMapEditor {
    public enum EditError: Error, Equatable, Sendable {
        /// A command failed against the file's current state; nothing
        /// was written.
        case commandFailed(String)
        /// The post-edit model violates a structural invariant; nothing
        /// was written.
        case invalidResult([String])
    }

    /// A coordinated read of a package.
    public static func read(at url: URL) throws -> PackageContents {
        var coordinationError: NSError?
        var contents: PackageContents?
        var readError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            readURL in
            do {
                contents = try ArborPackage.read(at: readURL)
            } catch {
                readError = error
            }
        }
        if let readError { throw readError }
        if let coordinationError { throw coordinationError }
        guard let contents else {
            throw ArborError.notAPackage(url)
        }
        return contents
    }

    /// The package's review log (SPEC §8.1 `study/reviews.jsonl`), empty
    /// when the package has none. A corrupted line throws — callers that
    /// only want a count may treat that as "unknown history" and pass an
    /// empty log.
    public static func readReviews(at url: URL) throws -> [ReviewLog] {
        let logURL = url.appendingPathComponent(ArborPackage.studyEntryName)
            .appendingPathComponent("reviews.jsonl")
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return try ReviewLogCodec.decode(text)
    }

    /// Applies `commands` to the package at `url` as one edit: coordinated
    /// read → command application against the loaded model → validation →
    /// one atomic write. On any failure the file is untouched.
    ///
    /// The wrapper from the read is reused (SPEC §11.1: unchanged
    /// `FileWrapper`s survive, so assets, the review log and Quick Look
    /// entries are never dropped), and the commands' inverses are
    /// computed before applying — the same contract `MapStore.perform`
    /// enforces on open documents.
    public static func apply(
        _ commands: [MapCommand], at url: URL, author: AuthorKind, now: Date = Date()
    ) throws {
        guard !commands.isEmpty else { return }
        var failure: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) {
            writeURL in
            do {
                try applyLocally(commands, at: writeURL, author: author, now: now)
            } catch {
                failure = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }

    /// Creates a new package at `url` from an imported model (CreateMap,
    /// MCP `create_map`): one atomic write, author-stamped, validated.
    public static func writeNew(
        model: MapModel, at url: URL, author: AuthorKind, appVersion: String, now: Date = Date()
    ) throws {
        var working = model
        stamp(in: &working, previous: nil, author: author, now: now)
        let violations = MapValidator.validate(working)
        guard violations.isEmpty else {
            throw EditError.invalidResult(violations.map { String(describing: $0) })
        }
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let meta = PackageMeta(
            formatVersion: ArborFormat.formatVersion,
            appVersion: appVersion,
            created: now,
            modified: now,
            docID: working.docID
        )
        try ArborPackage.write(working, meta: meta, to: url)
    }

    /// The read-modify-write, run inside the write coordination.
    private static func applyLocally(
        _ commands: [MapCommand], at url: URL, author: AuthorKind, now: Date
    ) throws {
        // Read the existing wrapper so foreign entries survive the save.
        let root: FileWrapper
        if let existing = try? FileWrapper(url: url, options: []), existing.isDirectory {
            root = existing
        } else {
            root = FileWrapper(directoryWithFileWrappers: [:])
        }
        let contents = try ArborPackage.read(from: root)
        var working = contents.model
        if !contents.validationErrors.isEmpty {
            working = MapRepairer.repair(working).model
        }
        let previous = working
        for command in commands {
            // Computing the inverse first is the MapStore contract: a
            // command that cannot invert against the current state has no
            // business applying. Headless edits keep no undo stack, but
            // the same input validation runs.
            _ = try command.inverse(in: working)
            try command.apply(to: &working)
        }
        stamp(in: &working, previous: previous, author: author, now: now)
        let violations = MapValidator.validate(working)
        guard violations.isEmpty else {
            throw EditError.invalidResult(violations.map(String.init(describing:)))
        }
        let meta = PackageMeta(
            formatVersion: contents.meta.formatVersion,
            appVersion: contents.meta.appVersion,
            created: contents.meta.created,
            modified: now,
            docID: working.docID
        )
        try ArborPackage.updateFileWrapper(root, model: working, meta: meta)
        root.preferredFilename = url.lastPathComponent
        try root.write(to: url, options: [.atomic], originalContentsURL: nil)
    }

    /// Authorship stamping, the `MapStore.stampTouchedNodes` contract:
    /// every node that differs from the pre-edit state records `modified`
    /// and `modifiedBy`.
    static func stamp(in working: inout MapModel, previous: MapModel?, author: AuthorKind, now: Date) {
        for (id, node) in working.nodes where previous?.nodes[id] != node {
            working.nodes[id]?.modified = now
            working.nodes[id]?.modifiedBy = author
        }
    }
}
