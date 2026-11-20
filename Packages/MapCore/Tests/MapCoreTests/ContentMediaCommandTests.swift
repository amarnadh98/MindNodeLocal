import Foundation
import Testing

@testable import MapCore

/// The M3 media commands' tests (F-CNT-2/3/5/7/8, F-TAG-3), split out of
/// `ContentCommandTests` to keep each suite under the lint budgets —
/// the same makeModel/roundTrip helpers, redeclared locally.
struct ContentMediaCommandTests {
    private func makeModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "content")
        for id in ["root", "a", "b", "a1", "a2", "b1"] {
            model.nodes[id] = Node(id: id, parent: nil, title: NodeTitle(text: id))
        }
        model.roots = ["root"]
        model.nodes["root"]?.children = ["a", "b"]
        model.nodes["a"]?.parent = "root"
        model.nodes["b"]?.parent = "root"
        model.nodes["a"]?.children = ["a1", "a2"]
        model.nodes["a1"]?.parent = "a"
        model.nodes["a2"]?.parent = "a"
        model.nodes["b"]?.children = ["b1"]
        model.nodes["b1"]?.parent = "b"
        return model
    }

    private func roundTrip(
        _ command: MapCommand, on model: inout MapModel, label: String
    ) throws {
        let inverse = try command.inverse(in: model)
        let original = model
        try command.apply(to: &model)
        try inverse.apply(to: &model)
        #expect(model == original, "\(label): apply∘inverse ≠ identity")
    }

    // MARK: media & content commands (F-CNT-2/3/5/7/8, F-TAG-3)

    @Test func mediaCommandsHaveExactInverses() throws {
        var model = makeModel()
        let image = NodeImage(asset: "aa11.png", size: [200, 120], placement: .above)
        try roundTrip(.setImage(id: "a", image: image), on: &model, label: "setImage")
        try roundTrip(.setImage(id: "a", image: nil), on: &model, label: "clearImage")
        try roundTrip(
            .setMarkers(id: "b", markers: ["sf:star.fill", "emoji:💡", "sticker:priority-1"]),
            on: &model, label: "setMarkers")
        try roundTrip(.setMarkers(id: "b", markers: nil), on: &model, label: "clearMarkers")
        try roundTrip(
            .setAttachments(id: "a1", attachments: [Attachment(asset: "bb22.pdf", name: "Paper.pdf")]),
            on: &model, label: "setAttachments")
        try roundTrip(
            .setSource(
                id: "a2",
                source: SourceRef(url: "https://example.com", page: 12, time: 93.5, excerpt: "quote")),
            on: &model, label: "setSource")
        try roundTrip(.setMath(id: "b1", math: true), on: &model, label: "setMath")
        try roundTrip(.setMath(id: "b1", math: nil), on: &model, label: "clearMath")
        try roundTrip(
            .setFilters([SavedFilter(id: "f1", name: "Open Tasks", query: "is:open-task")]),
            on: &model, label: "setFilters")
        try roundTrip(.setFilters(nil), on: &model, label: "clearFilters")

        // A missing node is a thrown no-op, never a crash.
        #expect(throws: ArborError.self) {
            try MapCommand.setImage(id: "ghost", image: image).apply(to: &model)
        }
        #expect(throws: ArborError.self) {
            try MapCommand.setMarkers(id: "ghost", markers: nil).apply(to: &model)
        }
    }

    @Test func mediaFieldsRoundTripThroughJSON() throws {
        var model = makeModel()
        model.nodes["a"]?.image = NodeImage(asset: "aa11.png", size: [200, 120], placement: .right)
        model.nodes["a"]?.markers = ["sf:star.fill", "emoji:💡", "sticker:priority-3"]
        model.nodes["b"]?.attachments = [Attachment(asset: "bb22.pdf", name: "Paper.pdf")]
        model.nodes["b"]?.source = SourceRef(
            url: "https://example.com/video", time: 42.5, excerpt: "the key claim")
        model.nodes["b1"]?.math = true
        model.filters = [SavedFilter(id: "f1", name: "Has Image", query: "has:image")]

        let data = try MapDocumentCoder.encode(model)
        let decoded = try MapDocumentCoder.decode(data)
        #expect(decoded.nodes["a"]?.image?.asset == "aa11.png")
        #expect(decoded.nodes["a"]?.image?.placement == .right)
        #expect(decoded.nodes["a"]?.image?.size == [200, 120])
        #expect(decoded.nodes["a"]?.markers?.count == 3)
        #expect(decoded.nodes["a"]?.markers?.first == "sf:star.fill")
        #expect(decoded.nodes["b"]?.attachments?.first?.name == "Paper.pdf")
        #expect(decoded.nodes["b"]?.source?.time == 42.5)
        #expect(decoded.nodes["b1"]?.math == true)
        #expect(decoded.filters?.first?.name == "Has Image")
        // formatVersion is untouched: §8.2's v1 schema already
        // modelled every one of these fields (additive optionals).
        #expect(decoded.formatVersion == ArborFormat.formatVersion)
    }

    // MARK: smart typing rows (F-EDT-10)

    @Test func commitParseReadsTaskPrefixes() {
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "[ ] Buy milk")).task == true)
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "[ ] Buy milk")).taskDone == false)
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "-[] Buy milk")).task == true)
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "[x] Done")).taskDone == true)
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "-[x] Done")).taskDone == true)
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "[X] Done")).taskDone == true)
        // The prefix is stripped from the stored title.
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "[ ] Buy milk")).title.text == "Buy milk")
        // A mid-text checkbox is literal (only prefixes count).
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "ship [ ] later")).task == nil)
        #expect(SmartTyping.parseCommit(in: NodeTitle(text: "plain")).task == nil)
    }

    @Test func commitParseReadsMathCodeAndNoteSplit() {
        let math = SmartTyping.parseCommit(in: NodeTitle(text: "$$x = \\frac{1}{2}$$"))
        #expect(math.math)
        #expect(math.title.text == "x = \\frac{1}{2}")
        #expect(!math.code)

        let code = SmartTyping.parseCommit(in: NodeTitle(text: "```func f() {}```"))
        #expect(code.code)
        #expect(code.title.text == "func f() {}")
        #expect(code.title.runs == [Run(range: [0, 11], code: true)])

        let split = SmartTyping.parseCommit(in: NodeTitle(text: "Title line\n--\nthe note body"))
        #expect(split.title.text == "Title line")
        #expect(split.note == "the note body")
        // A trailing `--` with nothing after it is not a split.
        let trailing = SmartTyping.parseCommit(in: NodeTitle(text: "Title\n--"))
        #expect(trailing.note == nil)
        #expect(trailing.title.text == "Title\n--")
    }

    @Test func commitParseCombinesRows() {
        let parse = SmartTyping.parseCommit(in: NodeTitle(text: "[x] Ship #ops\n--\nran the deploy"))
        #expect(parse.task == true)
        #expect(parse.taskDone == true)
        #expect(parse.tags == ["ops"])
        #expect(parse.title.text == "Ship")
        #expect(parse.note == "ran the deploy")
    }

    @Test func smartCommitIsOneUndoableStep() throws {
        var model = makeModel()
        let parse = SmartTyping.parseCommit(in: NodeTitle(text: "[x] Ship #ops\n--\nran the deploy"))
        let command = MapCommand.smartCommit(id: "a", parse: parse, in: model)
        let inverse = try command.inverse(in: model)
        let original = model
        try command.apply(to: &model)

        #expect(model.nodes["a"]?.title.text == "Ship")
        #expect(model.nodes["a"]?.task?.done == true)
        #expect(model.nodes["a"]?.note == "ran the deploy")
        #expect(model.nodes["a"]?.tags?.count == 1)

        try inverse.apply(to: &model)
        #expect(model == original, "one undo step restores title, task, note and tag")

        // Math rides through the same path.
        let mathParse = SmartTyping.parseCommit(in: NodeTitle(text: "$$E=mc^2$$"))
        let mathCommand = MapCommand.smartCommit(id: "b", parse: mathParse, in: model)
        try mathCommand.apply(to: &model)
        #expect(model.nodes["b"]?.math == true)
        #expect(model.nodes["b"]?.title.text == "E=mc^2")
    }

    // MARK: marker cycling (F-CNT-3)

    @Test func markerTokensParseAndRoundTrip() {
        #expect(MarkerKind.parse("sf:star.fill") == .sfSymbol("star.fill"))
        #expect(MarkerKind.parse("emoji:💡") == .emoji("💡"))
        #expect(MarkerKind.parse("sticker:priority-1") == .sticker("priority-1"))
        #expect(MarkerKind.parse("sticker:") == nil)
        #expect(MarkerKind.parse("junk") == nil)
        #expect(MarkerKind.parse("sf:star.fill")?.token == "sf:star.fill")
    }

    @Test func clickingCyclesPriorityAndProgressMarkers() {
        // No markers → the first step inserts.
        #expect(MarkerCycler.cycled(nil, in: MarkerCycler.priorities) == ["sticker:priority-1"])
        // priority-2 → priority-3 (the unrelated marker survives).
        let advanced = MarkerCycler.cycled(
            ["sf:star.fill", "sticker:priority-2"], in: MarkerCycler.priorities)
        #expect(advanced == ["sf:star.fill", "sticker:priority-3"])
        // The last member clears the family.
        #expect(
            MarkerCycler.cycled(["sticker:priority-5"], in: MarkerCycler.priorities) == [])
        // An empty family is a no-op.
        #expect(MarkerCycler.cycled(["sf:star.fill"], in: []) == ["sf:star.fill"])
        // Progress steps through eighths.
        #expect(
            MarkerCycler.cycled(["sticker:progress-3"], in: MarkerCycler.progress)?
                .contains("sticker:progress-4") == true)
        #expect(
            MarkerCycler.cycled(["sticker:progress-8"], in: MarkerCycler.progress) == [])
    }
}
