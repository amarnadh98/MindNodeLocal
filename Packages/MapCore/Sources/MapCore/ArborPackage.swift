import Foundation

/// Reads and writes the `.arbor` file package (SPEC §8.1).
public enum ArborPackage {
    public static let mapEntryName = "map.json"
    public static let metaEntryName = "meta.json"
    public static let assetsEntryName = "assets"
    public static let studyEntryName = "study"
    public static let quickLookEntryName = "QuickLook"

    public static func write(
        _ model: MapModel,
        meta: PackageMeta,
        to url: URL,
        options: FileWrapper.WritingOptions = [.atomic]
    ) throws {
        let mapData = try MapDocumentCoder.encode(model)
        let metaData = try encodeMeta(meta)

        let root = FileWrapper(directoryWithFileWrappers: [
            mapEntryName: FileWrapper(regularFileWithContents: mapData),
            metaEntryName: FileWrapper(regularFileWithContents: metaData),
            assetsEntryName: FileWrapper(directoryWithFileWrappers: [:]),
            studyEntryName: FileWrapper(directoryWithFileWrappers: [:]),
            quickLookEntryName: FileWrapper(directoryWithFileWrappers: [:]),
        ])
        root.preferredFilename = url.lastPathComponent
        try root.write(to: url, options: options, originalContentsURL: nil)
    }

    public static func read(at url: URL) throws -> (model: MapModel, meta: PackageMeta) {
        guard let root = try? FileWrapper(url: url, options: []) else {
            throw ArborError.notAPackage(url)
        }
        guard root.isDirectory else {
            throw ArborError.notAPackage(url)
        }

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

        guard model.formatVersion == ArborFormat.formatVersion else {
            throw ArborError.unsupportedFormatVersion(
                found: model.formatVersion, expected: ArborFormat.formatVersion)
        }

        return (model, meta)
    }

    public static func readValidating(at url: URL) throws -> (model: MapModel, meta: PackageMeta) {
        let result = try read(at: url)
        let errors = MapValidator.validate(result.model)
        if !errors.isEmpty {
            throw ArborError.validationFailed(errors)
        }
        return result
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

/// Placeholder for forward migrations `vN → vN+1` (SPEC §8.4).
public enum Migrations {
    public static func migrate(_ model: MapModel, from version: Int) throws -> MapModel {
        guard version == ArborFormat.formatVersion else {
            throw ArborError.unsupportedFormatVersion(
                found: version, expected: ArborFormat.formatVersion)
        }
        return model
    }
}
