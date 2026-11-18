import Foundation

/// What `ArborPackage.read` found in a package: the decoded model and meta,
/// plus any structural invariant violations. Per SPEC §8.2 the loader
/// validates, reports, and still opens; it never refuses a document because
/// of a violation.
public struct PackageContents: Sendable {
    public let model: MapModel
    public let meta: PackageMeta
    public let validationErrors: [ValidationError]
}

/// Reads and writes the `.arbor` file package (SPEC §8.1).
public enum ArborPackage {
    public static let mapEntryName = "map.json"
    public static let metaEntryName = "meta.json"
    public static let assetsEntryName = "assets"
    public static let studyEntryName = "study"
    public static let quickLookEntryName = "QuickLook"

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
            validationErrors: MapValidator.validate(model)
        )
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
        model
    }
}
