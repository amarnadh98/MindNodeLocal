import Foundation
import Testing

@testable import MapCore

/// F-DOC-4 (SPEC §5.18): a package from a newer app version. `read`
/// refuses it with `unsupportedFormatVersion` (a forward migration is
/// impossible); `readWithoutMigration` decodes it as-is so the host can
/// open the document read-only with a banner instead of failing.
struct NewerFormatPackageTests {
    private func newerVersionPackage() throws -> (FileWrapper, MapModel) {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        var model = MapModel.emptyDocument()
        model.formatVersion = ArborFormat.formatVersion + 1
        let rootID = UUID().uuidString
        model.roots = [rootID]
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "From the Future"),
            created: timestamp, modified: timestamp)
        let wrapper = try ArborPackage.makeFileWrapper(
            model: model, meta: PackageMeta(docID: model.docID))
        return (wrapper, model)
    }

    @Test func readRefusesANewerFormatVersion() throws {
        let (wrapper, _) = try newerVersionPackage()
        #expect(throws: ArborError.self) {
            try ArborPackage.read(from: wrapper)
        }
    }

    @Test func readWithoutMigrationDecodesANewerModelAsIs() throws {
        let (wrapper, model) = try newerVersionPackage()
        let contents = try ArborPackage.readWithoutMigration(from: wrapper)
        // No migration ran: the model keeps the future version and its
        // nodes verbatim (JSON decoding ignores unknown future keys).
        #expect(contents.model == model)
        #expect(contents.model.formatVersion == ArborFormat.formatVersion + 1)
        #expect(contents.meta.docID == model.docID)
        #expect(contents.validationErrors.isEmpty)
    }

    @Test func readWithoutMigrationStillReadsTheCurrentFormat() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        var model = MapModel.emptyDocument()
        let rootID = UUID().uuidString
        model.roots = [rootID]
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "Present Day"),
            created: timestamp, modified: timestamp)
        let wrapper = try ArborPackage.makeFileWrapper(
            model: model, meta: PackageMeta(docID: model.docID))

        let contents = try ArborPackage.readWithoutMigration(from: wrapper)
        #expect(contents.model == model)
    }
}
