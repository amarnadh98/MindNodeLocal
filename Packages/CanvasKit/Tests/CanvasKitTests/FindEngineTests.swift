import Foundation
import MapCore
import Testing

@testable import CanvasKit

/// Pure F-FOC-3 engine coverage: case/diacritic-insensitive matching,
/// the tags toggle, document ordering, wrap-around stepping, replace
/// run preservation, replace-all as ONE undo step through the real
/// `MapStore`, and the view-level temporary unfold never touching the
/// model.
@MainActor
struct FindEngineTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// Root ▸ [alpha (▸ hidden leaf), beta]; alpha is folded, the
    /// leaf's title still matches, and beta carries a note and a tag.
    private func model() -> MapModel {
        var model = MapModel.emptyDocument(docID: "find")
        let root = Node(id: "root", title: NodeTitle(text: "Root idea"), created: date, modified: date)
        var alpha = Node(
            id: "alpha", parent: "root", title: NodeTitle(text: "Alpha beta"),
            folded: true, created: date, modified: date)
        let leaf = Node(
            id: "leaf", parent: "alpha", title: NodeTitle(text: "Hidden BETA leaf"),
            created: date, modified: date)
        var beta = Node(
            id: "beta", parent: "root", title: NodeTitle(text: "Gamma"),
            note: "A café with BETA notes", tags: ["tag1"], created: date, modified: date)
        alpha.children = ["leaf"]
        beta.children = []
        model.nodes = ["root": root, "alpha": alpha, "leaf": leaf, "beta": beta]
        model.roots = ["root"]
        model.nodes["root"]?.children = ["alpha", "beta"]
        model.tags = [Tag(id: "tag1", name: "exam", color: "#E5484D")]
        return model
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(FindEngine.matches(query: "", options: FindOptions(), in: model()).isEmpty)
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        let matches = FindEngine.matches(query: "BETA", options: FindOptions(), in: model())
        // Titles first (document order): alpha's title, the hidden
        // leaf's title, then beta's note. The folded subtree still
        // matches — the scene filtering is the host's business.
        #expect(matches.count == 3)
        #expect(matches[0].nodeID == "alpha")
        #expect(matches[0].field == .title)
        #expect(matches[2].nodeID == "beta")
        #expect(matches[2].field == .note)

        // Diacritics: "cafe" finds "café", with the original range.
        let cafe = FindEngine.matches(query: "cafe", options: FindOptions(), in: model())
        #expect(cafe.count == 1)
        #expect(cafe[0].text == "A café with BETA notes")
        #expect(cafe[0].ranges == [MatchRange(location: 2, length: 4)])
    }

    @Test func multipleOccurrencesWithinOneField() {
        var text = model()
        text.nodes["beta"]?.note = "beta and beta again"
        let matches = FindEngine.matches(query: "beta", options: FindOptions(), in: text)
        // alpha's title, the hidden leaf's title, then the note with
        // both of its occurrences in one match.
        #expect(matches.count == 3)
        #expect(matches[2].field == .note)
        #expect(matches[2].ranges.count == 2)
        #expect(matches[2].ranges[1].location > matches[2].ranges[0].location)
    }

    @Test func tagsAreBehindTheToggle() {
        let off = FindEngine.matches(query: "exam", options: FindOptions(), in: model())
        #expect(off.isEmpty)

        let on = FindEngine.matches(
            query: "EXAM", options: FindOptions(includeTags: true), in: model())
        #expect(on.count == 1)
        #expect(on[0].nodeID == "beta")
        #expect(on[0].field == .tag)
        #expect(on[0].text == "exam")
    }

    @Test func resultsFollowDocumentOrder() {
        var document = model()
        // Second root after the first tree: matches interleave by the
        // DFS pre-order of roots and children.
        let second = Node(
            id: "second", title: NodeTitle(text: "beta root"), created: date, modified: date)
        document.nodes["second"] = second
        document.roots = ["root", "second"]

        let matches = FindEngine.matches(query: "beta", options: FindOptions(), in: document)
        #expect(matches.map(\.nodeID) == ["alpha", "leaf", "beta", "second"])
    }

    @Test func steppingWrapsAroundBothWays() {
        #expect(FindEngine.step(index: nil, count: 0, forwards: true) == nil)
        #expect(FindEngine.step(index: nil, count: 3, forwards: true) == 0)
        #expect(FindEngine.step(index: nil, count: 3, forwards: false) == 2)
        #expect(FindEngine.step(index: 2, count: 3, forwards: true) == 0)
        #expect(FindEngine.step(index: 0, count: 3, forwards: false) == 2)
        #expect(FindEngine.step(index: 1, count: 1, forwards: true) == 0)
    }

    // MARK: replace preserving runs (§8.3)

    private func title(
        _ text: String, _ runs: [Run]
    ) -> NodeTitle {
        NodeTitle(text: text, runs: runs)
    }

    @Test func replacePreservesRunsAroundTheRange() {
        // A whole run replaced: the replacement inherits its style.
        let styled = title("Hello brave world", [Run(range: [6, 5], bold: true)])
        let replaced = FindEngine.replacedTitle(styled, replacing: [MatchRange(location: 6, length: 5)], with: "bold")
        #expect(replaced.text == "Hello bold world")
        #expect(replaced.runs == [Run(range: [6, 4], bold: true)])
    }

    @Test func replaceInsideARunSplitsIt() {
        // The match starts mid-run: the prefix keeps the run, the
        // replacement inherits it, the suffix keeps it too, and the
        // three pieces coalesce back into one run.
        let styled = title("abcdef", [Run(range: [1, 3], bold: true)])
        let replaced = FindEngine.replacedTitle(styled, replacing: [MatchRange(location: 2, length: 2)], with: "XY")
        #expect(replaced.text == "abXYef")
        #expect(replaced.runs == [Run(range: [1, 3], bold: true)])
    }

    @Test func replaceShiftsLaterRunsByTheLengthDelta() {
        let styled = title("beta one", [Run(range: [5, 3], italic: true)])
        let replaced = FindEngine.replacedTitle(styled, replacing: [MatchRange(location: 0, length: 4)], with: "zeta-x")
        #expect(replaced.text == "zeta-x one")
        #expect(replaced.runs == [Run(range: [7, 3], italic: true)])
    }

    @Test func replaceInUnstyledTextIntroducesNoRuns() {
        let plain = NodeTitle(text: "plain beta text")
        let replaced = FindEngine.replacedTitle(plain, replacing: [MatchRange(location: 6, length: 4)], with: "zeta")
        #expect(replaced.text == "plain zeta text")
        #expect(replaced.runs.isEmpty)
    }

    @Test func deletingTheMatchRemovesItAndKeepsLaterRuns() {
        let styled = title("ab", [Run(range: [1, 1], strike: true)])
        let replaced = FindEngine.replacedTitle(styled, replacing: [MatchRange(location: 0, length: 1)], with: "")
        #expect(replaced.text == "b")
        #expect(replaced.runs == [Run(range: [0, 1], strike: true)])
    }

    @Test func multipleReplacementsInOneTitle() {
        let styled = title("beta or beta", [Run(range: [9, 4], code: true)])
        let replaced = FindEngine.replacedTitle(
            styled,
            replacing: [MatchRange(location: 0, length: 4), MatchRange(location: 8, length: 4)],
            with: "b")
        #expect(replaced.text == "b or b")
        #expect(replaced.runs == [Run(range: [6, 1], code: true)])
    }

    // MARK: replace-all (one command, one undo step)

    @Test func replaceAllIsOneGroupedCommandOverTitlesAndNotes() throws {
        let command = FindEngine.replaceAllCommand(
            query: "beta", replacement: "zeta", options: FindOptions(), in: model())
        let grouped = try #require(command)
        guard case .group(let name, let commands) = grouped else {
            Issue.record("expected one grouped replace-all command")
            return
        }
        #expect(name == "Replace All")
        #expect(commands.count == 3)
        #expect(commands.contains { if case .editText("alpha", _) = $0 { true } else { false } })
        #expect(commands.contains { if case .editText("leaf", _) = $0 { true } else { false } })
        #expect(commands.contains { if case .setNote("beta", _) = $0 { true } else { false } })

        var applied = model()
        try grouped.apply(to: &applied)
        #expect(applied.nodes["alpha"]?.title.text == "Alpha zeta")
        #expect(applied.nodes["beta"]?.note == "A café with zeta notes")
    }

    @Test func replaceAllWithNoMatchesYieldsNoCommand() {
        #expect(
            FindEngine.replaceAllCommand(query: "zzz", replacement: "x", options: FindOptions(), in: model())
                == nil)
    }

    @Test func replaceAllUndoesInOneStepThroughTheStore() throws {
        let store = MapStore(model: model())
        let before = store.model
        let command = FindEngine.replaceAllCommand(
            query: "beta", replacement: "zeta", options: FindOptions(includeTags: true), in: store.model)
        try store.perform(try #require(command))

        #expect(store.model.nodes["alpha"]?.title.text == "Alpha zeta")
        #expect(store.model.nodes["leaf"]?.title.text == "Hidden zeta leaf")
        #expect(store.model.nodes["beta"]?.note == "A café with zeta notes")

        // ONE undo step restores every title and note at once.
        #expect(store.undoManager.canUndo)
        store.undoManager.undo()
        #expect(!store.undoManager.canUndo)
        #expect(store.model.nodes["alpha"]?.title.text == before.nodes["alpha"]?.title.text)
        #expect(store.model.nodes["leaf"]?.title.text == before.nodes["leaf"]?.title.text)
        #expect(store.model.nodes["beta"]?.note == before.nodes["beta"]?.note)
    }

    // MARK: the view-level temporary unfold

    @Test func temporaryUnfoldCopiesWithoutTouchingTheModel() {
        let original = model()
        #expect(original.nodes["alpha"]?.folded == true)

        let unfolded = FindEngine.modelUnfoldingAncestors(of: "leaf", in: original)
        #expect(unfolded.nodes["alpha"]?.folded == false)
        // The source model is untouched — a value copy, not a command.
        #expect(original.nodes["alpha"]?.folded == true)
        #expect(FindEngine.foldedAncestors(of: "leaf", in: original) == ["alpha"])
        #expect(FindEngine.foldedAncestors(of: "beta", in: original).isEmpty)
    }
}
