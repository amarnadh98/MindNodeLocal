import Foundation
import Testing

@testable import MapCore

/// M3 content commands (notes, links, tasks, tags): exact inverses on
/// representative trees, grouped multi-select steps, the ring's
/// complete-all/reopen-all, smart-typing parsing and link validation.
struct ContentCommandTests {
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

    // MARK: notes & links

    @Test func setNoteAndSetLinkRoundTrip() throws {
        var model = makeModel()
        try roundTrip(.setNote(id: "a", note: "# Heading\n- item"), on: &model, label: "setNote")
        try roundTrip(.setLink(id: "b", link: "https://example.com"), on: &model, label: "setLink")

        try MapCommand.setNote(id: "a", note: "  ").apply(to: &model)
        #expect(model.nodes["a"]?.note == nil, "a whitespace-only note stores as no note")

        try MapCommand.setLink(id: "a", link: nil).apply(to: &model)
        #expect(model.nodes["a"]?.link == nil)
    }

    @Test func noteAndLinkSurviveRoundTripThroughJSON() throws {
        var model = makeModel()
        model.nodes["a"]?.note = "Read **this**"
        model.nodes["a"]?.link = "x-arbor://open?doc=content&node=b"
        let data = try MapDocumentCoder.encode(model)
        let decoded = try MapDocumentCoder.decode(data)
        #expect(decoded.nodes["a"]?.note == "Read **this**")
        #expect(decoded.nodes["a"]?.link == "x-arbor://open?doc=content&node=b")
    }

    // MARK: tasks

    @Test func taskCommandsHaveExactInverses() throws {
        var model = makeModel()
        try MapCommand.setTask(ids: ["a", "b"], isTask: true).apply(to: &model)
        try roundTrip(
            .setTaskValue(id: "a", task: NodeTask(done: true, due: "2026-12-01", priority: 2)),
            on: &model, label: "setTaskValue")
        try roundTrip(.setTaskDone(ids: ["a", "b"], done: true), on: &model, label: "setTaskDone")
        try roundTrip(
            .setTaskDetails(id: "a", due: "2027-01-01", priority: 3, repeat: "weekly"),
            on: &model, label: "setTaskDetails")

        try MapCommand.setTask(ids: ["a", "b"], isTask: true).apply(to: &model)
        try MapCommand.setTaskDetails(id: "a", due: "2027-01-01", priority: 1, repeat: "daily")
            .apply(to: &model)
        #expect(model.nodes["a"]?.task?.due == "2027-01-01")
        #expect(model.nodes["a"]?.task?.priority == 1)
        #expect(model.nodes["a"]?.task?.`repeat` == "daily")

        // Toggling a task off and back on loses the details (they live
        // in the value); the exact inverse still restores them.
        let inverse = try MapCommand.setTask(ids: ["a"], isTask: false).inverse(in: model)
        try MapCommand.setTask(ids: ["a"], isTask: false).apply(to: &model)
        #expect(model.nodes["a"]?.task == nil)
        try inverse.apply(to: &model)
        #expect(model.nodes["a"]?.task?.due == "2027-01-01")
    }

    @Test func multiSelectTaskToggleIsOneCommand() throws {
        var model = makeModel()
        try MapCommand.setTask(ids: ["a", "a1", "b1"], isTask: true).apply(to: &model)
        for id in ["a", "a1", "b1"] {
            #expect(model.nodes[id]?.task != nil)
        }
        // One group undoes all three at once.
        let inverse = try MapCommand.setTask(ids: ["a", "a1", "b1"], isTask: false).inverse(in: model)
        try MapCommand.setTask(ids: ["a", "a1", "b1"], isTask: false).apply(to: &model)
        try inverse.apply(to: &model)
        for id in ["a", "a1", "b1"] {
            #expect(model.nodes[id]?.task != nil)
        }
    }

    // MARK: progress ring

    @Test func progressRatioAggregatesLeafTasksOverNesting() throws {
        var model = makeModel()
        // a is a parent task with one leaf child task (a1 done) and
        // one non-task child (a2) whose only child is a task — that
        // grandchild IS a leaf task and must count.
        model.nodes["a"]?.task = NodeTask()
        model.nodes["a1"]?.task = NodeTask(done: true)
        model.nodes["a2"]?.children = ["a2x"]
        model.nodes["a2x"] = Node(id: "a2x", parent: "a2", title: NodeTitle(text: "a2x"))
        model.nodes["a2x"]?.task = NodeTask(done: false)
        // b is an open task with a done leaf child.
        model.nodes["b"]?.task = NodeTask()
        model.nodes["b1"]?.task = NodeTask(done: true)

        let ratios = TaskProgress.index(model)
        #expect(ratios["root"] == TaskRatio(completed: 2, total: 3))
        #expect(ratios["a"] == TaskRatio(completed: 1, total: 2))
        #expect(ratios["b"] == TaskRatio(completed: 1, total: 1))
        // The index holds only ring nodes (with task descendants): a
        // leaf task renders a checkbox instead and never appears.
        #expect(ratios["a1"] == nil)
        #expect(ratios["a2x"] == nil)
        // A non-task parent with a task descendant still carries a
        // ring (F-TSK-2 says "a parent with task descendants").
        #expect(ratios["a2"] == TaskRatio(completed: 0, total: 1))

        #expect(TaskRatio(completed: 7, total: 12).tooltip == "7 of 12 · 58%")
    }

    @Test func ringClickCompletesAllLeafTasksAsOneGroupedStep() throws {
        var model = makeModel()
        model.nodes["a"]?.task = NodeTask()
        model.nodes["a1"]?.task = NodeTask(done: true)
        model.nodes["a2"]?.task = NodeTask()
        model.nodes["b"]?.task = NodeTask()

        let command = try #require(
            MapCommand.setLeafTasksDone(parent: "root", done: true, in: model))
        let inverse = try command.inverse(in: model)
        let original = model
        try command.apply(to: &model)
        for id in ["a1", "a2", "b"] {
            #expect(model.nodes[id]?.task?.done == true)
        }
        // The parent task itself is not a leaf task (it has task
        // descendants) — its own done flag is untouched.
        try inverse.apply(to: &model)
        #expect(model == original)

        let reopen = try #require(
            MapCommand.setLeafTasksDone(parent: "root", done: false, in: model))
        try reopen.apply(to: &model)
        for id in ["a1", "a2", "b"] {
            #expect(model.nodes[id]?.task?.done == false)
        }
    }

    @Test func ringCommandIsNilWithoutLeafTasks() {
        let model = makeModel()
        #expect(MapCommand.setLeafTasksDone(parent: "root", done: true, in: model) == nil)
    }

    // MARK: tags

    @Test func tagCRUDRoundTrips() throws {
        var model = makeModel()
        let exam = Tag(id: "t-exam", name: "exam", color: "#E5484D")

        try roundTrip(MapCommand.addTag(exam, in: model), on: &model, label: "addTag")
        try MapCommand.addTag(exam, in: model).apply(to: &model)
        try MapCommand.toggleTag(ids: ["a", "b"], tagID: "t-exam", assigned: true).apply(to: &model)
        #expect(model.nodes["a"]?.tags == ["t-exam"])
        #expect(model.nodes["b"]?.tags == ["t-exam"])

        // Rename + recolor in one wholesale replace.
        try roundTrip(
            MapCommand.updateTag(Tag(id: "t-exam", name: "midterm", color: "#46A758"), in: model),
            on: &model, label: "updateTag")
        try MapCommand.updateTag(Tag(id: "t-exam", name: "midterm", color: "#46A758"), in: model)
            .apply(to: &model)
        #expect(model.tags?.first?.name == "midterm")

        // Delete removes the definition AND the assignments; undo
        // restores both exactly.
        let delete = try MapCommand.deleteTag(id: "t-exam", in: model)
        let inverse = try delete.inverse(in: model)
        let original = model
        try delete.apply(to: &model)
        #expect(model.tags?.contains { $0.id == "t-exam" } != true)
        #expect(model.nodes["a"]?.tags == nil)
        #expect(model.nodes["b"]?.tags == nil)
        try inverse.apply(to: &model)
        #expect(model == original)
    }

    @Test func unassignLeavesEmptyListAsNil() throws {
        var model = makeModel()
        model.tags = [Tag(id: "t", name: "solo", color: "#E5484D")]
        try MapCommand.toggleTag(ids: ["a"], tagID: "t", assigned: true).apply(to: &model)
        try MapCommand.toggleTag(ids: ["a"], tagID: "t", assigned: false).apply(to: &model)
        #expect(model.nodes["a"]?.tags == nil)
    }

    // MARK: smart typing

    @Test func smartTypingParsesTagTokens() {
        func parse(_ text: String) -> (title: String, tags: [String]) {
            SmartTyping.parseTags(in: text)
        }

        #expect(parse("Plan #exam") == ("Plan", ["exam"]))
        #expect(parse("Plan") == ("Plan", []))
        #expect(parse("复习 #考试 now") == ("复习 now", ["考试"]))
        #expect(parse("Learn #fun!") == ("Learn", ["fun"]))
        #expect(parse("#a #b tail") == ("tail", ["a", "b"]))
        #expect(parse("See https://ex.com/x#frag #real") == ("See https://ex.com/x#frag", ["real"]))
        #expect(parse("mid#word stays") == ("mid#word stays", []))
        #expect(parse("just # alone") == ("just # alone", []))
        #expect(parse("#a #a dup") == ("dup", ["a"]))
        #expect(parse("x-arbor://open?doc=d#node stays") == ("x-arbor://open?doc=d#node stays", []))
        #expect(parse("#tag. #other,") == ("", ["tag", "other"]))
        #expect(parse("#!!!") == ("#!!!", []))
        #expect(parse("tail #done") == ("tail", ["done"]))
    }

    @Test func smartTypingRemapsStyleRunsToTheShrunkenText() {
        // "Buy **milk** #urgent" — the bold run must survive the
        // token strip with its range shifted left.
        let title = NodeTitle(
            text: "Buy milk #urgent now",
            runs: [Run(range: [4, 4], bold: true)])
        let parsed = SmartTyping.parseTags(in: title)
        #expect(parsed.tags == ["urgent"])
        #expect(parsed.title.text == "Buy milk now")
        #expect(parsed.title.runs == [Run(range: [4, 4], bold: true)])

        // A run INSIDE the removed token drops entirely.
        let inner = NodeTitle(
            text: "Ship #urgent",
            runs: [Run(range: [5, 6], italic: true)])
        let innerParsed = SmartTyping.parseTags(in: inner)
        #expect(innerParsed.title.text == "Ship")
        #expect(innerParsed.title.runs == [])

        // A run spanning the token shrinks by the overlap.
        let spanning = NodeTitle(
            text: "AB #tag CD",
            runs: [Run(range: [0, 10], underline: true)])
        let spanningParsed = SmartTyping.parseTags(in: spanning)
        #expect(spanningParsed.title.text == "AB CD")
        #expect(spanningParsed.title.runs.count == 1)
        #expect(spanningParsed.title.runs.first?.range == [0, 5])
    }

    @Test func smartTagCommitIsOneGroupedStep() throws {
        var model = makeModel()
        let command = MapCommand.smartTagCommit(
            id: "a", title: NodeTitle(text: "Study"), names: ["exam", "exam"], in: model)
        let inverse = try command.inverse(in: model)
        let original = model
        try command.apply(to: &model)

        #expect(model.nodes["a"]?.title.text == "Study")
        #expect(model.tags?.count == 1)
        let tagID = try #require(model.tags?.first?.id)
        #expect(model.nodes["a"]?.tags == [tagID])
        #expect(model.tags?.first?.name == "exam")

        try inverse.apply(to: &model)
        #expect(model == original, "one undo step restores title, definition and assignment")

        // An existing tag definition is reused, not duplicated.
        try command.apply(to: &model)
        let second = MapCommand.smartTagCommit(id: "b", title: NodeTitle(text: "Again"), names: ["exam"], in: model)
        try second.apply(to: &model)
        #expect(model.tags?.count == 1)
        #expect(model.nodes["b"]?.tags == [tagID])
    }

    // MARK: link validation

    @Test func parsesValidLinks() {
        #expect(
            ArborLink.parse("https://example.com/maps") == .web(URL(string: "https://example.com/maps")!))
        #expect(ArborLink.parse("http://a.b/c?d=e#f")?.webSchemeHost != nil)
        #expect(ArborLink.parse("file:///Users/x/map.arbor") != nil)
        #expect(ArborLink.parse("/Users/x/notes.md") != nil)
        #expect(ArborLink.parse("x-arbor://open?doc=d1&node=n2") == .arbor(docID: "d1", nodeID: "n2"))
        #expect(ArborLink.parse("x-arbor://open") == .arbor(docID: nil, nodeID: nil))

        #expect(ArborLink.parse("junk://x") == nil)
        #expect(ArborLink.parse("not a url with spaces") == nil)
        #expect(ArborLink.parse("") == nil)
        #expect(ArborLink.parse("example.com") == nil, "scheme-less strings are not guessed here")
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

extension ArborLink {
    /// Test helper: the web case's host, nil otherwise.
    var webSchemeHost: String? {
        guard case .web(let url) = self else { return nil }
        return url.host
    }
}
