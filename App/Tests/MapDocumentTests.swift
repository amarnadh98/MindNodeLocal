import AppKit
import Foundation
import MapCore
import Testing

@testable import Arbor

@MainActor
struct MapDocumentTests {
    @Test func untitledDocumentThroughController() throws {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        #expect(document.fileURL == nil)
        #expect(document.model.nodes.isEmpty)
        #expect(document.model.roots.isEmpty)
        #expect(document.meta?.formatVersion == ArborFormat.formatVersion)
        #expect(document.meta?.docID == document.model.docID)
    }

    @Test func openSaveRoundTripsThroughDocumentController() throws {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m0-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }

        try document.write(to: url, ofType: AppIdentity.documentUTI)

        let reopened = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        #expect(reopened.fileURL == url)
        #expect(reopened.fileType == AppIdentity.documentUTI)
        #expect(reopened.fileModificationDate != nil)
        #expect(reopened.model == document.model)
        #expect(reopened.meta?.docID == document.meta?.docID)
    }

    @Test func assetsAndReviewLogSurviveSaves() throws {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m0-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }

        try document.write(to: url, ofType: AppIdentity.documentUTI)

        try Data("asset-bytes".utf8)
            .write(to: url.appendingPathComponent("assets/hello.txt"))
        try Data("{\"card\":\"c1\"}\n".utf8)
            .write(to: url.appendingPathComponent("study/reviews.jsonl"))

        let opened = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        try opened.writeSafely(to: url, ofType: AppIdentity.documentUTI, for: .saveOperation)
        try opened.writeSafely(to: url, ofType: AppIdentity.documentUTI, for: .saveOperation)

        let assetPath = url.appendingPathComponent("assets/hello.txt").path
        let reviewsPath = url.appendingPathComponent("study/reviews.jsonl").path
        #expect(FileManager.default.contents(atPath: assetPath) == Data("asset-bytes".utf8))
        #expect(
            FileManager.default.contents(atPath: reviewsPath) == Data("{\"card\":\"c1\"}\n".utf8))

        let reopened = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        #expect(reopened.model == opened.model)
    }

    @Test func documentWithValidationViolationStillOpens() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000.25)
        var model = MapModel.emptyDocument()
        let rootID = UUID().uuidString
        model.roots = [rootID]
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "Root"), created: timestamp, modified: timestamp)
        model.nodes[rootID]?.tags = ["ghost-tag"]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m0-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)

        let opened = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        #expect(opened.fileURL == url)
        #expect(opened.model.nodes.count == model.nodes.count)
        #expect(opened.model.nodes[rootID]?.tags?.isEmpty == true)
        #expect(opened.model.nodes[rootID]?.title.text == "Root")
    }

    /// NSDocument posts its undo-group change counts on a later run-loop
    /// turn; spin briefly so `isDocumentEdited` reflects them.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// An untitled document whose store groups are the top-level undo
    /// groups. In the app each key event closes the undo manager's
    /// by-event group; a test runs inside one long run-loop pass, where
    /// that outer group would never close.
    private func makeEditableDocument() throws -> MapDocument {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        document.undoManager?.groupsByEvent = false
        return document
    }

    @Test func undoingBackToTheSavedStateClearsTheEditedFlag() throws {
        let document = try makeEditableDocument()
        try document.store.perform(.addRoot(index: nil, node: Node(id: UUID().uuidString)))
        settle()
        #expect(document.isDocumentEdited)

        document.undoManager?.undo()
        settle()
        #expect(!document.isDocumentEdited)
    }

    @Test func typingAfterASaveDirtiesTheDocumentAgain() throws {
        let document = try makeEditableDocument()
        let id = UUID().uuidString
        try document.store.perform(.addRoot(index: nil, node: Node(id: id)))
        try document.store.perform(.editText(id: id, title: NodeTitle(text: "A")))
        settle()
        _ = try document.fileWrapper(ofType: AppIdentity.documentUTI)
        document.updateChangeCount(.changeCleared)
        #expect(!document.isDocumentEdited)

        try document.store.perform(.editText(id: id, title: NodeTitle(text: "AB")))
        settle()
        #expect(document.isDocumentEdited)
    }

    /// The hosted test runner never schedules timed autosaves, so a late
    /// autosave error can't leave a modal alert blocking the host's exit.
    @Test func testHostDoesNotScheduleAutosaves() {
        #expect(!MapDocument.schedulesAutosaving)
    }
}
