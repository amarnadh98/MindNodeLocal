import Foundation
import Testing

@testable import MapCore

/// M8 schema + AI-facing commands (SPEC §5.15, §12): the optional
/// `MapModel.ai` policy, the exact inverses of the AI-associated
/// commands, and the authorship metadata that F-AI-5 records.
struct AIPolicyCommandTests {
    private func minimalModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "ai-doc")
        let root = Node(id: "root", title: NodeTitle(text: "Root"))
        model.nodes[root.id] = root
        model.roots = [root.id]
        return model
    }

    @Test func setAIPolicyRoundTripsExactly() throws {
        let model = minimalModel()
        let command = MapCommand.setAIPolicy(policy: DocumentAIPolicy(neverSendToCloud: true))
        let inverse = try command.inverse(in: model)

        var applied = model
        try command.apply(to: &applied)
        #expect(applied.ai?.neverSendToCloud == true)

        try inverse.apply(to: &applied)
        #expect(applied == model)
    }

    @Test func setAIPolicyClearingReinstates() throws {
        var model = minimalModel()
        model.ai = DocumentAIPolicy(neverSendToCloud: true)
        let command = MapCommand.setAIPolicy(policy: nil)
        let inverse = try command.inverse(in: model)

        var applied = model
        try command.apply(to: &applied)
        #expect(applied.ai == nil)

        try inverse.apply(to: &applied)
        #expect(applied == model)
    }

    @Test func setNoteRoundTripsAndClears() throws {
        let model = minimalModel()
        var withNote = model
        withNote.nodes["root"]?.note = "existing note"

        let set = MapCommand.setNote(id: "root", note: "AI summary")
        let back = try set.inverse(in: withNote)
        var applied = withNote
        try set.apply(to: &applied)
        #expect(applied.nodes["root"]?.note == "AI summary")
        try back.apply(to: &applied)
        #expect(applied == withNote)

        let clear = MapCommand.setNote(id: "root", note: nil)
        let restore = try clear.inverse(in: withNote)
        var cleared = withNote
        try clear.apply(to: &cleared)
        #expect(cleared.nodes["root"]?.note == nil)
        try restore.apply(to: &cleared)
        #expect(cleared == withNote)
    }

    @Test func setNoteThrowsOnMissingNode() throws {
        let model = minimalModel()
        #expect(throws: ArborError.self) {
            _ = try MapCommand.setNote(id: "ghost", note: "n").inverse(in: model)
        }
    }

    @Test func setTitleRoundTripsExactly() throws {
        let model = minimalModel()
        let command = MapCommand.setTitle("AI suggested title")
        let inverse = try command.inverse(in: model)

        var applied = model
        try command.apply(to: &applied)
        #expect(applied.title == "AI suggested title")

        try inverse.apply(to: &applied)
        #expect(applied == model)
    }

    @Test func policyFieldDecodesAsAbsentFromOlderFiles() throws {
        // A v3-less JSON (no "ai" key) decodes with a nil policy — old
        // documents open with no restriction (SPEC §12).
        let legacy = try MapDocumentCoder.decode(
            try MapDocumentCoder.encode(minimalModel()))
        #expect(legacy.ai == nil)
    }

    @Test func metaCarriesLastModifiedBy() throws {
        var meta = PackageMeta(docID: "ai-doc")
        meta.lastModifiedBy = .ai
        #expect(meta.lastModifiedBy == .ai)

        // Old meta.json (without the field) decodes with nil.
        let plainJSON = """
            {"formatVersion":3,"appVersion":"0.1.0","docID":"d",
             "created":"2026-11-01T10:00:00.000Z","modified":"2026-11-01T10:00:00.000Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(PackageMeta.self, from: Data(plainJSON.utf8))
        #expect(old.lastModifiedBy == nil)
    }
}
