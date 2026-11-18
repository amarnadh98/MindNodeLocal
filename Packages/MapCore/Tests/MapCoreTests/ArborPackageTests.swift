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
    let read = try ArborPackage.readValidating(at: url)

    #expect(read.model == model)
    #expect(read.meta.docID == meta.docID)
    #expect(read.meta.formatVersion == ArborFormat.formatVersion)

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
    let read = try ArborPackage.readValidating(at: url)
    #expect(read.model == model)
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

@Test func nonPackageURLThrows() throws {
    let notAPackage = FileManager.default.temporaryDirectory
        .appendingPathComponent("arbor-test-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: notAPackage) }
    try Data("hello".utf8).write(to: notAPackage)

    #expect(throws: ArborError.self) {
        _ = try ArborPackage.read(at: notAPackage)
    }
}
