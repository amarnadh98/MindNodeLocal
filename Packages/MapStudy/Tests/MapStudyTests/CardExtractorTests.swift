import Foundation
import MapCore
import Testing

@testable import MapStudy

/// Card extraction (SPEC §10, F-STD-1/2): policies, stable ids, cloze edge
/// cases, summaries and outline order.
struct CardExtractorTests {
    private func node(
        _ id: String,
        parent: String? = nil,
        title: String,
        note: String? = nil,
        children: [String] = [],
        card: CardPolicy? = nil
    ) -> Node {
        Node(
            id: id,
            parent: parent,
            children: children,
            title: NodeTitle(text: title),
            note: (note == nil || note!.isEmpty) ? nil : note,
            study: card.map { NodeStudy(card: $0) }
        )
    }

    private func map(_ nodes: [Node], roots: [String], summaries: [Summary]? = nil) -> MapModel {
        var model = MapModel(roots: roots)
        for node in nodes {
            model.nodes[node.id] = node
        }
        model.summaries = summaries
        return model
    }

    // MARK: - The auto rule (F-STD-1)

    @Test func autoCardsNeedChildrenOrANote() {
        let model = map(
            [
                node("root", title: "Biology", children: ["branch", "leaf", "noted"]),
                node("branch", parent: "root", title: "Cell", children: ["mito"]),
                node("mito", parent: "branch", title: "Mitochondria"),
                node("leaf", parent: "root", title: "Lonely leaf"),
                node("noted", parent: "root", title: "Noted leaf", note: "Has a note"),
            ],
            roots: ["root"]
        )
        let cards = CardExtractor.extract(from: model)
        let ids = cards.map(\.id)

        // Root (has children), branch (has children), noted leaf (has a note)
        // are cards; a bare leaf is not.
        #expect(ids.contains("root"))
        #expect(ids.contains("branch"))
        #expect(ids.contains("noted"))
        #expect(!ids.contains("leaf"))
        #expect(!ids.contains("mito"))

        // Front = breadcrumb path plus title (F-STD-1 example shape).
        let mitoless = cards.first { $0.id == "branch" }!
        #expect(mitoless.front == "Biology › Cell")
        #expect(mitoless.back == "Mitochondria")
        let noted = cards.first { $0.id == "noted" }!
        #expect(noted.front == "Biology › Noted leaf")
        #expect(noted.back == "Has a note")
    }

    @Test func explicitPolicyOverridesAuto() {
        let model = map(
            [
                node("root", title: "R", children: ["forced", "suppressed", "reversible"]),
                // A bare leaf explicitly marked Card.
                node("forced", parent: "root", title: "Forced", card: .on),
                // A node with children explicitly marked Not a card.
                node("suppressed", parent: "root", title: "Suppressed", children: ["s1"], card: .off),
                node("s1", parent: "suppressed", title: "S1", note: "note"),
                // Explicit Card with answer content gains the reversed card.
                node("reversible", parent: "root", title: "Reversible", note: "the answer", card: .on),
            ],
            roots: ["root"]
        )
        let cards = CardExtractor.extract(from: model)
        let ids = cards.map(\.id)

        #expect(ids.contains("forced"))
        let forced = cards.first { $0.id == "forced" }!
        #expect(forced.kind == .basic)
        #expect(forced.back.isEmpty)

        // "off" suppresses this node's own cards; other nodes (here the child
        // with a note) still follow their own policy.
        #expect(!ids.contains("suppressed"))
        #expect(ids.contains("s1"))

        #expect(ids.contains("reversible"))
        #expect(ids.contains("reversible#r"))
        let reversed = cards.first { $0.id == "reversible#r" }!
        #expect(reversed.kind == .reversed)
        #expect(reversed.front == "the answer")
        #expect(reversed.back == "R › Reversible")
    }

    // MARK: - Cloze (F-STD-2)

    @Test func clozeEdgeCases() {
        let model = map(
            [
                node("root", title: "Root", children: ["c1", "multi", "noteonly", "broken", "twelve"]),
                node("c1", parent: "root", title: "The {{c1::mitochondrion}} is the powerhouse"),
                node("multi", parent: "root", title: "{{c1::A}} and {{c2::B}} and {{c1::A again}}"),
                node("noteonly", parent: "root", title: "Plain title", note: "Note has {{c2::secret}} inside"),
                node("broken", parent: "root", title: "Unclosed {{c1::oops and {{c2::no}} tail"),
                node("twelve", parent: "root", title: "{{c12::multi-word}} and {{c1::x::hint}}"),
            ],
            roots: ["root"]
        )
        let cards = CardExtractor.extract(from: model)
        let ids = cards.map(\.id)

        // One card per distinct index, ascending, id nodeID#cN.
        #expect(ids.contains("c1#c1"))
        let c1 = cards.first { $0.id == "c1#c1" }!
        #expect(c1.kind == .cloze)
        #expect(c1.front == "The […] is the powerhouse")
        #expect(c1.back == "The mitochondrion is the powerhouse")

        // Duplicate indices collapse to one card that masks every match.
        #expect(ids.filter { $0 == "multi#c1" }.count == 1)
        let multi1 = cards.first { $0.id == "multi#c1" }!
        #expect(multi1.front == "[…] and B and […]")
        let multi2 = cards.first { $0.id == "multi#c2" }!
        #expect(multi2.front == "A and […] and A again")

        // Cloze in the note only; the title rides along unmasked.
        let noteCloze = cards.first { $0.id == "noteonly#c2" }!
        #expect(noteCloze.front == "Plain title\n\nNote has […] inside")

        // Markup closes at the FIRST "}}", so the "inner" deletion is swallowed
        // by the outer one, and the first "::" of the swallowed text acts as
        // its hint: c1 exists (masked as "[no]"), c2 does not.
        #expect(ids.contains("broken#c1"))
        #expect(!ids.contains("broken#c2"))
        let broken = cards.first { $0.id == "broken#c1" }!
        #expect(broken.front == "Unclosed [no] tail")

        // Multi-digit indices and hints.
        let twelve = cards.first { $0.id == "twelve#c12" }!
        #expect(twelve.front == "[…] and x")
        let hinted = cards.first { $0.id == "twelve#c1" }!
        #expect(hinted.front == "multi-word and [hint]")

        // Clozes appear even without children/note (markup is explicit intent).
        #expect(ids.contains("c1#c1"))
    }

    @Test func clozeParserMalformedMarkup() {
        // No digits, no separator, no closing: all literal.
        #expect(ClozeParser.deletions(in: "{{c::answer}}").isEmpty)
        #expect(ClozeParser.deletions(in: "{{c1}}").isEmpty)
        #expect(ClozeParser.deletions(in: "{{c1::").isEmpty)
        #expect(ClozeParser.deletions(in: "{{1::x}}").isEmpty)
        #expect(ClozeParser.deletions(in: "no markup").isEmpty)
        // Valid ones still parse.
        #expect(ClozeParser.deletions(in: "{{c1::x}}").count == 1)
        #expect(ClozeParser.deletions(in: "{{c01::x}}").count == 1)
        #expect(ClozeParser.indices(in: "{{c2::a}}{{c1::b}}") == [1, 2])
        // Literal text survives rendering untouched.
        #expect(ClozeParser.rendered(text: "plain {{c1::", clozeIndex: 1) == "plain {{c1::")
        // Empty answer still masks.
        #expect(ClozeParser.rendered(text: "{{c1::}}", clozeIndex: 1) == "[…]")
    }

    // MARK: - Summaries (F-STD-2, F-REL-3)

    @Test func summaryCardsUseTheSummaryID() {
        let model = map(
            [
                node("root", title: "Root", children: ["a", "b", "c", "summary"]),
                node("a", parent: "root", title: "Alpha", note: "n"),
                node("b", parent: "root", title: "Beta", note: "n"),
                node("c", parent: "root", title: "Gamma", note: "n"),
                node("summary", parent: "root", title: "A–C in Greek"),
            ],
            roots: ["root"],
            summaries: [Summary(id: "sum-1", parent: "root", range: ["a", "c"], node: "summary")]
        )
        let cards = CardExtractor.extract(from: model)
        let summary = cards.first { $0.id == "sum-1" }
        #expect(summary != nil)
        #expect(summary!.kind == .summary)
        #expect(summary!.nodeID == "summary")
        #expect(summary!.front == "Alpha\nBeta\nGamma")
        #expect(summary!.back == "A–C in Greek")
        // Emitted after the last sibling of its range, in outline order.
        let order = cards.map(\.id)
        #expect(order.firstIndex(of: "sum-1")! > order.firstIndex(of: "c")!)
        #expect(order.firstIndex(of: "sum-1")! < order.firstIndex(of: "root")! + 6)
        // The summary node itself is a bare leaf: not a card under "auto".
        #expect(!cards.map(\.id).contains("summary"))

        // The summary node can opt out; a stale summary is skipped.
        var optedOut = model
        optedOut.nodes["summary"]!.study = NodeStudy(card: .off)
        #expect(!CardExtractor.extract(from: optedOut).map(\.id).contains("sum-1"))

        var stale = model
        stale.summaries = [Summary(id: "sum-2", parent: "root", range: ["a", "nope"], node: "summary")]
        #expect(!CardExtractor.extract(from: stale).map(\.id).contains("sum-2"))
    }

    // MARK: - Stable ids across unrelated edits

    @Test func cardIDsAreStableAcrossUnrelatedEdits() {
        var model = map(
            [
                node("root", title: "Root", children: ["a", "b"]),
                node("a", parent: "root", title: "A", children: ["a1"]),
                node("a1", parent: "a", title: "{{c1::hidden}} detail", note: "note"),
                node("b", parent: "root", title: "B", children: ["b1", "b2"]),
                node("b1", parent: "b", title: "B1"),
                node("b2", parent: "b", title: "B2", note: "note"),
            ],
            roots: ["root"]
        )
        let before = CardExtractor.extract(from: model).map(\.id)

        // Edits that don't touch the a-subtree: rename b, add a sibling under b,
        // change the root title.
        model.nodes["b"]!.title = NodeTitle(text: "B renamed")
        model.nodes["root"]!.children.append("b3")
        model.nodes["b3"] = node("b3", parent: "root", title: "B3", note: "note")

        let after = CardExtractor.extract(from: model).map(\.id)
        // The a-subtree's cards keep their ids in the same relative order.
        let aBefore = before.filter { $0 == "a" || $0 == "a1" || $0.hasPrefix("a1#") }
        let aAfter = after.filter { $0 == "a" || $0 == "a1" || $0.hasPrefix("a1#") }
        #expect(aBefore == aAfter)
        // The new node becomes a card; b is still a card; bare-leaf b1 never was.
        #expect(after.contains("b3"))
        #expect(after.contains("b"))
        #expect(after.contains("b2"))
        #expect(!after.contains("b1"))
    }

    @Test func cardsFollowOutlineOrder() {
        let model = map(
            [
                node("r1", title: "One", children: ["c1", "c2"]),
                node("c1", parent: "r1", title: "C1", note: "n"),
                node("c2", parent: "r1", title: "C2", note: "n"),
                node("r2", title: "Two", note: "n2"),
            ],
            roots: ["r2", "r1"]
        )
        let ids = CardExtractor.extract(from: model).map(\.id)
        // Roots in creation order (map.roots), then depth-first per children order.
        #expect(ids == ["r2", "r1", "c1", "c2"])
    }
}
