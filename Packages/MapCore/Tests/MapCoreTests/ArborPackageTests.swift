import Foundation
import Testing

@testable import MapCore

@Test func packageRoundTripsThroughDisk() throws {
    let model = try sampleTree()
    let meta = PackageMeta(docID: model.docID)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arbor-test-\(UUID().uuidString).arbor")
    defer { try? FileManager.default.removeItem(at: url) }

    try ArborPackage.write(model, meta: meta, to: url)
    let read = try ArborPackage.read(at: url)

    #expect(read.model == model)
    #expect(read.meta.docID == meta.docID)
    #expect(read.meta.formatVersion == ArborFormat.formatVersion)
    #expect(read.validationErrors.isEmpty)

    #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("assets").path))
    #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("study").path))
    #expect(
        FileManager.default.fileExists(atPath: url.appendingPathComponent("QuickLook").path))
}

@Test func emptyPackageRoundTrips() throws {
    let model = MapModel.emptyDocument()
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arbor-test-\(UUID().uuidString).arbor")
    defer { try? FileManager.default.removeItem(at: url) }

    try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)
    let read = try ArborPackage.read(at: url)
    #expect(read.model == model)
    #expect(read.validationErrors.isEmpty)
}

@Test func foreignEntriesSurviveWrapperUpdates() throws {
    let model = MapModel.emptyDocument()
    let meta = PackageMeta(docID: model.docID)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arbor-test-\(UUID().uuidString).arbor")
    defer { try? FileManager.default.removeItem(at: url) }

    try ArborPackage.write(model, meta: meta, to: url)
    let root = try FileWrapper(url: url, options: [])

    let asset = FileWrapper(regularFileWithContents: Data("asset-bytes".utf8))
    asset.preferredFilename = "hello.txt"
    let assetsDir = FileWrapper(directoryWithFileWrappers: ["hello.txt": asset])
    assetsDir.preferredFilename = ArborPackage.assetsEntryName
    let reviews = FileWrapper(regularFileWithContents: Data("{\"card\":\"c1\"}\n".utf8))
    reviews.preferredFilename = "reviews.jsonl"
    let studyDir = FileWrapper(directoryWithFileWrappers: ["reviews.jsonl": reviews])
    studyDir.preferredFilename = ArborPackage.studyEntryName

    if let oldAssets = root.fileWrappers?[ArborPackage.assetsEntryName] {
        root.removeFileWrapper(oldAssets)
    }
    if let oldStudy = root.fileWrappers?[ArborPackage.studyEntryName] {
        root.removeFileWrapper(oldStudy)
    }
    root.addFileWrapper(assetsDir)
    root.addFileWrapper(studyDir)
    try root.write(to: url, options: [.atomic], originalContentsURL: nil)

    var reloaded = try FileWrapper(url: url, options: [])
    for _ in 0..<2 {
        try ArborPackage.updateFileWrapper(reloaded, model: model, meta: meta)
    }
    try reloaded.write(to: url, options: [.atomic], originalContentsURL: nil)

    let assetPath = url.appendingPathComponent("assets/hello.txt").path
    let reviewsPath = url.appendingPathComponent("study/reviews.jsonl").path
    #expect(
        FileManager.default.contents(atPath: assetPath) == Data("asset-bytes".utf8))
    #expect(
        FileManager.default.contents(atPath: reviewsPath) == Data("{\"card\":\"c1\"}\n".utf8))
}

@Test func updateFileWrapperEnsuresMissingDirectories() throws {
    let model = try sampleTree()
    let bare = FileWrapper(directoryWithFileWrappers: [
        ArborPackage.mapEntryName: FileWrapper(regularFileWithContents: try MapDocumentCoder.encode(model))
    ])
    let mapWrapper = bare.fileWrappers?[ArborPackage.mapEntryName]
    mapWrapper?.preferredFilename = ArborPackage.mapEntryName

    try ArborPackage.updateFileWrapper(bare, model: model, meta: PackageMeta(docID: model.docID))

    #expect(bare.fileWrappers?[ArborPackage.assetsEntryName]?.isDirectory == true)
    #expect(bare.fileWrappers?[ArborPackage.studyEntryName]?.isDirectory == true)
    #expect(bare.fileWrappers?[ArborPackage.quickLookEntryName]?.isDirectory == true)
}

@Test func validationViolationsDoNotRefuseToOpen() throws {
    var model = try sampleTree()
    let rootID = model.roots[0]
    model.nodes[rootID]?.tags = ["ghost-tag"]

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arbor-test-\(UUID().uuidString).arbor")
    defer { try? FileManager.default.removeItem(at: url) }

    try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)
    let read = try ArborPackage.read(at: url)

    #expect(read.model == model)
    #expect(read.validationErrors.contains { if case .danglingTag = $0 { true } else { false } })
}

@Test func missingMapJSONThrows() throws {
    let model = MapModel.emptyDocument()
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arbor-test-\(UUID().uuidString).arbor")
    defer { try? FileManager.default.removeItem(at: url) }

    try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)
    try FileManager.default.removeItem(at: url.appendingPathComponent("map.json"))

    #expect(throws: ArborError.missingPackageEntry(ArborPackage.mapEntryName)) {
        _ = try ArborPackage.read(at: url)
    }
}

@Test func newerFormatVersionThrows() throws {
    var model = MapModel.emptyDocument()
    model.formatVersion = ArborFormat.formatVersion + 1
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arbor-test-\(UUID().uuidString).arbor")
    defer { try? FileManager.default.removeItem(at: url) }

    try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)

    let expected = ArborError.unsupportedFormatVersion(
        found: model.formatVersion, expected: ArborFormat.formatVersion)
    #expect(throws: expected) {
        _ = try ArborPackage.read(at: url)
    }
}

@Test func currentVersionMigrationIsIdentity() throws {
    let model = try sampleTree()
    let migrated = try Migrations.migrate(model, from: ArborFormat.formatVersion)
    #expect(migrated == model)
}

@Test func nonPackageURLThrows() throws {
    let notAPackage = FileManager.default.temporaryDirectory
        .appendingPathComponent("arbor-test-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: notAPackage) }
    try Data("hello".utf8).write(to: notAPackage)

    #expect(throws: ArborError.self) {
        _ = try ArborPackage.read(at: notAPackage)
    }
}
