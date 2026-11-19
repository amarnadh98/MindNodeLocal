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
}

extension ArborLink {
    /// Test helper: the web case's host, nil otherwise.
    var webSchemeHost: String? {
        guard case .web(let url) = self else { return nil }
        return url.host
    }
}
