import CryptoKit
import Foundation

/// What `ArborPackage.read` found in a package: the decoded model and meta,
/// plus any structural invariant violations. Per SPEC §8.2 the loader
/// validates, reports, and still opens; it never refuses a document because
/// of a violation.
public struct PackageContents: Sendable {
    public let model: MapModel
    public let meta: PackageMeta
    public let validationErrors: [ValidationError]
    /// Raw bytes of `study/reviews.jsonl` when the package has one
    /// (SPEC §8.1). Opaque here — MapStudy owns the codec — and never
    /// fatal to read: a truncated tail is the log's normal failure mode.
    public let studyLogData: Data?

    init(
        model: MapModel,
        meta: PackageMeta,
        validationErrors: [ValidationError],
        studyLogData: Data? = nil
    ) {
        self.model = model
        self.meta = meta
        self.validationErrors = validationErrors
        self.studyLogData = studyLogData
    }
}

/// Reads and writes the `.arbor` file package (SPEC §8.1).
public enum ArborPackage {
    public static let mapEntryName = "map.json"
    public static let metaEntryName = "meta.json"
    public static let assetsEntryName = "assets"
    public static let studyEntryName = "study"
    public static let quickLookEntryName = "QuickLook"
    /// The append-only FSRS review log inside the `study` directory
    /// (SPEC §8.1). MapStudy owns its codec; the package layer only
    /// moves the bytes.
    public static let studyLogEntryName = "reviews.jsonl"

    /// Builds a complete package wrapper from scratch (new documents,
    /// importers). Regular saves should reuse the wrapper from the last read
    /// via `updateFileWrapper` instead, so foreign or not-yet-managed entries
    /// (assets, review logs, Quick Look previews) survive.
    public static func makeFileWrapper(model: MapModel, meta: PackageMeta) throws -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        try updateFileWrapper(root, model: model, meta: meta)
        return root
    }

    /// Replaces only `map.json` and `meta.json` inside an existing package
    /// wrapper and guarantees the structural directories exist. All other
    /// child wrappers are reused untouched (SPEC §11.1: unchanged
    /// `FileWrapper`s are reused, so autosave rewrites only `map.json`).
    public static func updateFileWrapper(
        _ root: FileWrapper,
        model: MapModel,
        meta: PackageMeta
    ) throws {
        replaceEntry(root, name: mapEntryName, contents: try MapDocumentCoder.encode(model))
        replaceEntry(root, name: metaEntryName, contents: try encodeMeta(meta))
        ensureDirectory(root, named: assetsEntryName)
        ensureDirectory(root, named: studyEntryName)
        ensureDirectory(root, named: quickLookEntryName)
    }

    public static func write(
        _ model: MapModel,
        meta: PackageMeta,
        to url: URL,
        options: FileWrapper.WritingOptions = [.atomic]
    ) throws {
        let root = try makeFileWrapper(model: model, meta: meta)
        root.preferredFilename = url.lastPathComponent
        try root.write(to: url, options: options, originalContentsURL: nil)
    }

    public static func read(at url: URL) throws -> PackageContents {
        guard let root = try? FileWrapper(url: url, options: []), root.isDirectory else {
            throw ArborError.notAPackage(url)
        }
        return try read(from: root)
    }

    public static func read(from root: FileWrapper) throws -> PackageContents {
        guard
            let mapWrapper = entry(root, named: mapEntryName),
            mapWrapper.isRegularFile
        else {
            throw ArborError.missingPackageEntry(mapEntryName)
        }
        guard
            let metaWrapper = entry(root, named: metaEntryName),
            metaWrapper.isRegularFile
        else {
            throw ArborError.missingPackageEntry(metaEntryName)
        }

        var model = try MapDocumentCoder.decode(mapWrapper.regularFileContents ?? Data())
        let meta = try decodeMeta(metaWrapper.regularFileContents ?? Data())

        if model.formatVersion != ArborFormat.formatVersion {
            model = try Migrations.migrate(model, from: model.formatVersion)
        }

        return PackageContents(
            model: model,
            meta: meta,
            validationErrors: MapValidator.validate(model),
            studyLogData: studyLogData(from: root)
        )
    }

    /// Reads a package whose `formatVersion` is NEWER than the app's
    /// (F-DOC-4). `read(from:)` refuses such files
    /// (`ArborError.unsupportedFormatVersion`); this entry point decodes
    /// the model as-is — JSON decoding ignores keys this version doesn't
    /// know, so a future schema degrades to "opens read-only" instead of
    /// "refuses to open" — and never migrates (a forward migration is
    /// impossible by definition). The caller is expected to open the
    /// document read-only with a banner.
    public static func readWithoutMigration(from root: FileWrapper) throws -> PackageContents {
        guard
            let mapWrapper = entry(root, named: mapEntryName),
            mapWrapper.isRegularFile
        else {
            throw ArborError.missingPackageEntry(mapEntryName)
        }
        guard
            let metaWrapper = entry(root, named: metaEntryName),
            metaWrapper.isRegularFile
        else {
            throw ArborError.missingPackageEntry(metaEntryName)
        }

        let model = try MapDocumentCoder.decode(mapWrapper.regularFileContents ?? Data())
        let meta = try decodeMeta(metaWrapper.regularFileContents ?? Data())

        return PackageContents(
            model: model,
            meta: meta,
            validationErrors: MapValidator.validate(model),
            studyLogData: studyLogData(from: root)
        )
    }

    // MARK: assets (SPEC §8.1: content-addressed `<sha256>.<ext>`)

    /// The package's asset entry filenames (images, attachments),
    /// sorted. Reading never throws: unreadable entries read as
    /// absent.
    public static func assetNames(in root: FileWrapper) -> [String] {
        guard let assets = entry(root, named: assetsEntryName), assets.isDirectory else { return [] }
        return (assets.fileWrappers?.keys.sorted()) ?? []
    }

    /// One asset's bytes by filename, or nil when the package has no
    /// such entry. Never throws — the validator's "every asset
    /// reference exists" repair treats an unreadable asset as gone.
    public static func assetData(_ name: String, in root: FileWrapper) -> Data? {
        guard let assets = entry(root, named: assetsEntryName), assets.isDirectory else { return nil }
        guard let file = entry(assets, named: name), file.isRegularFile else { return nil }
        return file.regularFileContents
    }

    /// Stores `data` content-addressed and returns the filename
    /// (`<sha256>.<ext>`): the same bytes always land on the same
    /// name, so re-drops and undo both reuse the entry. An existing
    /// entry of the same name is replaced (identical content — the
    /// write is idempotent).
    public static func addAsset(_ data: Data, ext: String, in root: FileWrapper) -> String {
        let name = assetFilename(data, ext: ext)
        guard let assets = entry(root, named: assetsEntryName), assets.isDirectory else {
            let assetsDirectory = FileWrapper(directoryWithFileWrappers: [:])
            assetsDirectory.preferredFilename = assetsEntryName
            root.addFileWrapper(assetsDirectory)
            return addAsset(data, ext: ext, in: root)
        }
        if let existing = entry(assets, named: name) {
            assets.removeFileWrapper(existing)
        }
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        assets.addFileWrapper(file)
        return name
    }

    /// The content-addressed filename: the SHA-256 hex of the bytes
    /// plus the (lowercased, dot-prefixed) extension.
    public static func assetFilename(_ data: Data, ext: String) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let clean = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return clean.isEmpty ? hex : "\(hex).\(clean.lowercased())"
    }

    /// Replaces `study/reviews.jsonl` inside an existing package wrapper,
    /// creating the `study` directory when missing. A nil `data` removes
    /// the log. The rest of the package is untouched (unchanged
    /// `FileWrapper`s are reused, so autosave rewrites only what changed).
    public static func setStudyLog(_ data: Data?, in root: FileWrapper) {
        var study = entry(root, named: studyEntryName)
        if study == nil {
            let directory = FileWrapper(directoryWithFileWrappers: [:])
            directory.preferredFilename = studyEntryName
            root.addFileWrapper(directory)
            study = directory
        }
        guard let study, study.isDirectory else { return }
        if let existing = entry(study, named: studyLogEntryName) {
            study.removeFileWrapper(existing)
        }
        if let data {
            let log = FileWrapper(regularFileWithContents: data)
            log.preferredFilename = studyLogEntryName
            study.addFileWrapper(log)
        }
    }

    /// The raw bytes of `study/reviews.jsonl`, or nil when the package
    /// has no log yet. Never throws: a missing or unreadable log simply
    /// reads as absent (the session treats that as an empty history).
    private static func studyLogData(from root: FileWrapper) -> Data? {
        guard let study = entry(root, named: studyEntryName), study.isDirectory else { return nil }
        guard let log = entry(study, named: studyLogEntryName), log.isRegularFile else { return nil }
        return log.regularFileContents
    }

    private static func replaceEntry(_ root: FileWrapper, name: String, contents: Data) {
        if let existing = root.fileWrappers?[name] {
            root.removeFileWrapper(existing)
        }
        let file = FileWrapper(regularFileWithContents: contents)
        file.preferredFilename = name
        root.addFileWrapper(file)
    }

    private static func ensureDirectory(_ root: FileWrapper, named name: String) {
        guard entry(root, named: name) == nil else { return }
        let directory = FileWrapper(directoryWithFileWrappers: [:])
        directory.preferredFilename = name
        root.addFileWrapper(directory)
    }

    private static func entry(_ root: FileWrapper, named name: String) -> FileWrapper? {
        root.fileWrappers?[name] ?? root.fileWrappers?[name.lowercased()]
    }

    private static func encodeMeta(_ meta: PackageMeta) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(CodableDate.string(from: date))
        }
        do {
            return try encoder.encode(meta)
        } catch {
            throw ArborError.invalidMetaJSON(String(describing: error))
        }
    }

    private static func decodeMeta(_ data: Data) throws -> PackageMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = CodableDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid ISO-8601 date: \(raw)")
            }
            return date
        }
        do {
            return try decoder.decode(PackageMeta.self, from: data)
        } catch {
            throw ArborError.invalidMetaJSON(String(describing: error))
        }
    }
}

/// Forward migrations `vN → vN+1` (SPEC §8.4). A package written by a newer
/// app version (`version > ArborFormat.formatVersion`) is refused with
/// `ArborError.unsupportedFormatVersion`; the document then opens read-only
/// with a banner (F-DOC-4, wired up when the format actually evolves).
///
/// Every step is deterministic and total: the same input model always
/// produces the same output (fixture-tested for every version ever
/// shipped), and a step never drops data.
public enum Migrations {
    public static func migrate(_ model: MapModel, from version: Int) throws -> MapModel {
        guard (1...ArborFormat.formatVersion).contains(version) else {
            throw ArborError.unsupportedFormatVersion(
                found: version, expected: ArborFormat.formatVersion)
        }
        var migrated = model
        for current in version..<ArborFormat.formatVersion {
            migrated = step(migrated, from: current)
        }
        return migrated
    }

    private static func step(_ model: MapModel, from version: Int) -> MapModel {
        switch version {
        case 1:
            return v1ToV2(model)
        case 2:
            return v2ToV3(model)
        case 3:
            return v3ToV4(model)
        default:
            return model
        }
    }

    /// v1 → v2: `Node.paletteIndex` (ADR-0009) stores the branch palette
    /// index persistently. Every level-1 node — a root's direct child —
    /// gets today's positional index, so v1 files keep rendering with
    /// exactly the colors they had under positional coloring; new and
    /// reordered branches then hold their color (the reason for the
    /// field). Deeper nodes stay `nil`; they inherit their level-1
    /// ancestor's index at render time.
    static func v1ToV2(_ model: MapModel) -> MapModel {
        var migrated = model
        for rootID in model.roots {
            guard let children = model.nodes[rootID]?.children else { continue }
            for (position, childID) in children.enumerated() where migrated.nodes[childID] != nil {
                if migrated.nodes[childID]?.paletteIndex == nil {
                    migrated.nodes[childID]?.paletteIndex = position
                }
            }
        }
        migrated.formatVersion = 2
        return migrated
    }

    /// v2 → v3: `MapModel.ai` (the per-document AI policy, SPEC §12)
    /// and `Node.note` editing are optional schema additions, so no
    /// back-fill is needed — the step only stamps the version, keeping
    /// every existing field byte-compatible.
    static func v2ToV3(_ model: MapModel) -> MapModel {
        var migrated = model
        migrated.formatVersion = 3
        return migrated
    }

    /// v3 → v4: four optional fields join the schema —
    /// `NodeStylePatch.fontWeight`, `NodeStylePatch.fontItalic` and
    /// `NodeStylePatch.minWidth` (F-STY-2, ADR-0028) and
    /// `ThemePatch.rainbowBranches` (F-STY-8's toggle as a document
    /// override) — all defaulting to `nil` (the pre-v4 behavior), so
    /// there is nothing to back-fill; the step only stamps the version
    /// so the next save writes a v4 file.
    static func v3ToV4(_ model: MapModel) -> MapModel {
        var migrated = model
        migrated.formatVersion = 4
        return migrated
    }
}
