import Foundation
import MapCore
import Testing

@testable import Arbor

@MainActor
struct MapDocumentTests {
    @Test func emptyDocumentRoundTrips() throws {
        let document = MapDocument()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m0-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }

        try document.write(to: url, ofType: AppIdentity.documentUTI)
        let reopened = try MapDocument(contentsOf: url, ofType: AppIdentity.documentUTI)

        #expect(reopened.model == document.model)
        #expect(reopened.meta?.docID == document.meta?.docID)
    }

    @Test func savedDocumentIsAPackageWithEntries() throws {
        let document = MapDocument()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m0-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }

        try document.write(to: url, ofType: AppIdentity.documentUTI)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("map.json").path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("meta.json").path))
    }

    @Test func newDocumentHasModelAndMeta() {
        let document = MapDocument()
        #expect(document.model.nodes.isEmpty)
        #expect(document.model.roots.isEmpty)
        #expect(document.meta?.formatVersion == ArborFormat.formatVersion)
        #expect(document.meta?.docID == document.model.docID)
    }
}
