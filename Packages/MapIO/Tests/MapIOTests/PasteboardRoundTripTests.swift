import Foundation
import MapCore
import Testing

@testable import MapIO

/// Round trips through the internal paste payload: model → payload →
/// `insertSubtrees` → applied model preserves titles and structure with
/// fresh ids; the inverse restores the target exactly (F-EDT-9).
@Suite
struct PasteboardRoundTripTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// A source document: root r with children c1 (grandchildren g1, g2)
    /// and c2, carrying styles, notes, tags, assets and study state.
    private func sourceModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "source-doc")
        model.title = "Source"
        model.tags = [Tag(id: "t1", name: "exam", color: "#E5484D")]
        model.nodes["r"] = Node(
            id: "r", title: NodeTitle(text: "Root"), created: Self.fixedDate, modified: Self.fixedDate)
        model.roots = ["r"]
        model.nodes["c1"] = Node(
            id: "c1", parent: "r",
            title: NodeTitle(
                text: "Bold plain link",
                runs: [
                    Run(range: [0, 4], bold: true),
                    Run(range: [11, 4], link: "https://arbor.example"),
                ]),
            note: "a note",
            style: NodeStylePatch(shape: .pill, fill: "#0090FF"),
            tags: ["t1"],
            task: NodeTask(done: true),
            study: NodeStudy(card: .on, fsrs: FSRSState(due: Self.fixedDate, reps: 5, state: .review)),
            created: Self.fixedDate, modified: Self.fixedDate
        )
        model.nodes["c2"] = Node(
            id: "c2", parent: "r", title: NodeTitle(text: "Second branch"),
            image: NodeImage(asset: "sha.png", size: [200, 120], placement: .above),
            attachments: [Attachment(asset: "sha.pdf", name: "Paper.pdf")],
            created: Self.fixedDate, modified: Self.fixedDate
        )
        model.nodes["r"]?.children = ["c1", "c2"]
        model.nodes["g1"] = Node(
            id: "g1", parent: "c1", title: NodeTitle(text: "Grand one"),
            created: Self.fixedDate, modified: Self.fixedDate)
        model.nodes["g2"] = Node(
            id: "g2", parent: "c1", title: NodeTitle(text: "Grand two"),
            created: Self.fixedDate, modified: Self.fixedDate)
        model.nodes["c1"]?.children = ["g1", "g2"]
        return model
    }

    /// A paste target: root T with one child stay. Same docID as the source
    /// unless overridden, so asset/tag retention is testable per case.
    private func targetModel(docID: String = "source-doc") -> MapModel {
        var model = MapModel.emptyDocument(docID: docID)
        model.tags = [Tag(id: "t1", name: "exam", color: "#E5484D")]
        model.nodes["T"] = Node(
            id: "T", title: NodeTitle(text: "Target"), created: Self.fixedDate, modified: Self.fixedDate)
        model.nodes["stay"] = Node(
            id: "stay", parent: "T", title: NodeTitle(text: "Stays put"),
            created: Self.fixedDate, modified: Self.fixedDate)
        model.roots = ["T"]
        model.nodes["T"]?.children = ["stay"]
        return model
    }

    private func childTitles(of parentID: String, in model: MapModel) -> [String] {
        (model.nodes[parentID]?.children ?? []).compactMap { model.nodes[$0]?.title.text }
    }

    @Test func selectionDedupesCoveredDescendantsAndKeepsDocumentOrder() {
        let model = sourceModel()
        // g1 is covered by c1; c2 listed first; a bogus id and a repeat are dropped.
        let selection = PasteboardSerializer.normalizedSelection(
            in: model, selection: ["c2", "g1", "c1", "nope", "c1"])
        #expect(selection == ["c1", "c2"])
    }

    @Test func payloadRoundTripPreservesStructureWithFreshIDs() throws {
        let source = sourceModel()
        let data = try PasteboardSerializer.payload(from: source, selection: ["c1", "g1", "c2"])
        var target = targetModel()

        let pasted = try #require(
            try PasteboardParser.pasteCommand(fromPayload: data, parent: "T", index: 0, keepStyle: true, in: target))
        let undo = try pasted.inverse(in: target)
        try pasted.apply(to: &target)

        #expect(childTitles(of: "T", in: target) == ["Bold plain link", "Second branch", "Stays put"])

        let firstID = try #require(target.nodes["T"]?.children.first)
        let branch = try #require(target.nodes[firstID])
        #expect(branch.title.text == "Bold plain link")
        #expect(branch.note == "a note")
        #expect(branch.tags == ["t1"])
        #expect(branch.task?.done == true)
        #expect(branch.study?.card == .on)
        #expect(branch.study?.fsrs == nil)
        #expect(branch.style == NodeStylePatch(shape: .pill, fill: "#0090FF"))
        #expect(childTitles(of: firstID, in: target) == ["Grand one", "Grand two"])

        let secondID = try #require(target.nodes["T"]?.children.dropFirst().first)
        #expect(target.nodes[secondID]?.title.text == "Second branch")
        #expect(target.nodes[secondID]?.image?.asset == "sha.png")

        // Fresh ids and timestamps: nothing collides with the source.
        let sourceIDs = Set(source.nodes.keys)
        let newIDs = target.nodes.keys.filter { !sourceIDs.contains($0) && $0 != "T" && $0 != "stay" }
        #expect(newIDs.count == 4)
        for id in newIDs {
            #expect(target.nodes[id]?.created != Self.fixedDate)
            #expect(target.nodes[id]?.modified != Self.fixedDate)
        }
        #expect(MapValidator.validate(target).isEmpty)

        try undo.apply(to: &target)
        #expect(target == targetModel())
        #expect(MapValidator.validate(target).isEmpty)
    }

    @Test func plainPasteDropsStyleOverridesKeepStyleKeepsThem() throws {
        let source = sourceModel()
        let data = try PasteboardSerializer.payload(from: source, selection: ["c1"])

        var plainTarget = targetModel()
        let plain = try #require(
            try PasteboardParser.pasteCommand(fromPayload: data, parent: "T", index: 0, in: plainTarget))
        try plain.apply(to: &plainTarget)
        let plainID = try #require(plainTarget.nodes["T"]?.children.first)
        #expect(plainTarget.nodes[plainID]?.style == nil)

        var keepTarget = targetModel()
        let keep = try #require(
            try PasteboardParser.pasteCommand(
                fromPayload: data, parent: "T", index: 0, keepStyle: true, in: keepTarget))
        try keep.apply(to: &keepTarget)
        let keepID = try #require(keepTarget.nodes["T"]?.children.first)
        #expect(keepTarget.nodes[keepID]?.style == NodeStylePatch(shape: .pill, fill: "#0090FF"))
    }

    @Test func foreignPasteDropsAssetsAndUndeclaredTags() throws {
        let source = sourceModel()
        let data = try PasteboardSerializer.payload(from: source, selection: ["c1", "c2"])
        var target = targetModel(docID: "target-doc")
        target.tags = []

        let command = try #require(
            try PasteboardParser.pasteCommand(fromPayload: data, parent: "T", index: 0, in: target))
        try command.apply(to: &target)

        for childID in target.nodes["T"]?.children ?? [] where childID != "stay" {
            #expect(target.nodes[childID]?.image == nil)
            #expect(target.nodes[childID]?.attachments == nil)
            #expect(target.nodes[childID]?.tags == nil)
        }
        #expect(MapValidator.validate(target).isEmpty)
    }

    @Test func rootPasteInsertsAtRootIndexAndUndoIsExact() throws {
        let source = sourceModel()
        let data = try PasteboardSerializer.payload(from: source, selection: ["c1"])
        var target = targetModel(docID: "target-doc")
        let original = target

        let command = try #require(
            try PasteboardParser.pasteCommand(fromPayload: data, parent: nil, index: 0, in: target))
        let undo = try command.inverse(in: target)
        try command.apply(to: &target)
        #expect(target.roots.count == 2)
        #expect(target.nodes[target.roots[0]]?.title.text == "Bold plain link")
        #expect(target.nodes[target.roots[0]]?.parent == nil)

        try undo.apply(to: &target)
        #expect(target == original)
        #expect(MapValidator.validate(target).isEmpty)
    }

    @Test func malformedPayloadThrowsAndEmptyPayloadPastesNothing() throws {
        #expect(throws: ArborError.self) {
            _ = try PasteboardParser.parsePayload(Data("[not json".utf8))
        }
        #expect(throws: ArborError.self) {
            _ = try PasteboardParser.parsePayload(
                Data(#"{"version":99,"docID":"d","topIDs":[],"nodes":{}}"#.utf8))
        }
        let empty = try PastePayload(docID: "d", topIDs: [], nodes: [:]).encoded()
        #expect(try PasteboardParser.parsePayload(empty) == nil)
    }

    @Test func textFormatsSerializeSelectionInOutlineForm() {
        let model = sourceModel()
        #expect(
            PasteboardSerializer.plainText(from: model, selection: ["c1", "g1"])
                == "Bold plain link\n\tGrand one\n\tGrand two")

        let markdown = PasteboardSerializer.markdown(from: model, selection: ["r"])
        let expectedMarkdown =
            "- Root\n    - **Bold** plain [link](https://arbor.example)\n"
            + "        - Grand one\n        - Grand two\n    - Second branch"
        #expect(markdown == expectedMarkdown)

        let opml = PasteboardSerializer.opml(from: model, selection: ["c1"])
        #expect(opml.contains(#"<opml version="2.0">"#))
        #expect(opml.contains(#"<outline text="Bold plain link" _note="a note">"#))
        #expect(opml.contains(#"<outline text="Grand one"/>"#))
        #expect(opml.contains("<title>Source</title>"))
    }
}
