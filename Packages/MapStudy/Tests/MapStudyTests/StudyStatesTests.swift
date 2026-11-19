import Foundation
import MapCore
import Testing

@testable import MapStudy

/// Per-card state storage on the node (SPEC §10, ADR-0015): the basic
/// card keeps `study.fsrs`, companions live under `fsrsByCard`.
struct StudyStatesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, kind: Card.Kind, nodeID: String) -> Card {
        Card(id: id, kind: kind, nodeID: nodeID, front: id, back: id)
    }

    @Test func stateKeysFollowTheCardIdShape() {
        #expect(StudyStates.stateKey(for: card("n1", kind: .basic, nodeID: "n1")) == nil)
        #expect(StudyStates.stateKey(for: card("n1#r", kind: .reversed, nodeID: "n1")) == "r")
        #expect(StudyStates.stateKey(for: card("n1#c12", kind: .cloze, nodeID: "n1")) == "c12")
        #expect(StudyStates.stateKey(for: card("sum-1", kind: .summary, nodeID: "n1")) == "s:sum-1")
    }

    @Test func readingFallsBackToANewCard() {
        #expect(StudyStates.cardState(for: card("n1", kind: .basic, nodeID: "n1"), in: nil, now: now).state == .new)
        #expect(
            StudyStates.cardState(for: card("n1#r", kind: .reversed, nodeID: "n1"), in: NodeStudy(), now: now)
                .state == .new)
    }

    @Test func basicCardsUseTheOriginalFieldCompanionsUseTheMap() {
        let basicState = FSRSState(due: now, stability: 4, reps: 2, state: .review)
        let clozeState = FSRSState(due: now, stability: 9, reps: 1, state: .review)

        // Read the basic card from the original field.
        var study = NodeStudy(card: .on, fsrs: basicState)
        #expect(StudyStates.cardState(for: card("n1", kind: .basic, nodeID: "n1"), in: study, now: now).reps == 2)

        // Write a companion card: the basic field is untouched.
        study = StudyStates.writing(clozeState, for: card("n1#c1", kind: .cloze, nodeID: "n1"), in: study)
        #expect(study.fsrs == basicState)
        #expect(study.fsrsByCard?["c1"] == clozeState)
        #expect(
            StudyStates.cardState(for: card("n1#c1", kind: .cloze, nodeID: "n1"), in: study, now: now).stability == 9)

        // Write the basic card: the companion map is untouched.
        var next = StudyStates.writing(basicState, for: card("n1", kind: .basic, nodeID: "n1"), in: nil)
        #expect(next.fsrs == basicState)
        #expect(next.fsrsByCard == nil)
        next = StudyStates.writing(clozeState, for: card("sum-9", kind: .summary, nodeID: "n1"), in: next)
        #expect(next.fsrsByCard?["s:sum-9"] == clozeState)
        #expect(next.fsrs == basicState)
    }

    @Test func statesForAMapFeedTheQueue() {
        var model = MapModel.emptyDocument()
        var deckRoot = Node(
            id: "root", title: NodeTitle(text: "Deck"),
            study: NodeStudy(deck: true))
        deckRoot.children = ["a", "b"]
        model.nodes[deckRoot.id] = deckRoot
        model.roots = [deckRoot.id]
        model.nodes["a"] = Node(id: "a", parent: "root", title: NodeTitle(text: "A"), note: "n")
        model.nodes["b"] = Node(id: "b", parent: "root", title: NodeTitle(text: "B"), note: "n")
        model.nodes["root"]?.children = ["a", "b"]

        // A graded card shows up; ungraded ones don't.
        let graded = FSRSState(due: now.addingTimeInterval(-60), stability: 5, reps: 1, state: .review)
        model.nodes["a"]?.study = StudyStates.writing(graded, for: card("a", kind: .basic, nodeID: "a"), in: nil)

        let cards = CardExtractor.extract(from: model)
        let states = StudyStates.states(for: cards, in: model)
        #expect(states["a"]?.state == .review)
        #expect(states["b"] == nil)
        #expect(
            StudyQueue.build(cards: cards, states: states, reviews: [], now: now).map(\.card.id) == ["a", "root", "b"])
    }

    @Test func togglingDeckAndPolicyBuildStudySections() {
        #expect(StudyStates.togglingDeck(in: nil).deck == true)
        #expect(StudyStates.togglingDeck(in: NodeStudy(deck: true)).deck == false)
        #expect(StudyStates.togglingDeck(in: NodeStudy(card: .off)).card == .off)
        #expect(StudyStates.settingPolicy(.on, in: nil).card == .on)
        #expect(StudyStates.settingPolicy(.auto, in: NodeStudy(card: .off, deck: true)).deck == true)
    }
}

/// "Make Cloze" (F-STD-2): next-free index and title wrapping.
struct ClozeMakerTests {
    @Test func nextFreeIndexFillsGapsAcrossTitleAndNote() {
        #expect(ClozeMaker.nextFreeIndex(title: "plain", note: nil) == 1)
        #expect(ClozeMaker.nextFreeIndex(title: "{{c1::a}}", note: nil) == 2)
        #expect(ClozeMaker.nextFreeIndex(title: "{{c1::a}} and {{c3::b}}", note: nil) == 2)
        #expect(ClozeMaker.nextFreeIndex(title: "plain", note: "{{c2::note cloze}}") == 1)
        #expect(ClozeMaker.nextFreeIndex(title: "{{c1::a}}", note: "{{c1::n}} {{c2::m}}") == 3)
    }

    @Test func wrappingSelectedTextUsesTheNextFreeIndex() throws {
        let title = NodeTitle(text: "The powerhouse of the cell")
        let wrapped = ClozeMaker.wrapped(title: title, note: nil, location: 4, length: 10)
        #expect(wrapped?.text == "The {{c1::powerhouse}} of the cell")

        // A second cloze on the same node (title or note) takes index 2.
        let again = ClozeMaker.wrapped(title: wrapped!, note: nil, location: 26, length: 3)
        #expect(again?.text == "The {{c1::powerhouse}} of {{c2::the}} cell")
    }

    @Test func theNoteCountsTowardsUsedIndices() {
        let title = NodeTitle(text: "X matters")
        let wrapped = ClozeMaker.wrapped(title: title, note: "{{c1::already}}", location: 0, length: 1)
        #expect(wrapped?.text == "{{c2::X}} matters")
    }

    @Test func styleRunsShiftAroundTheWrap() {
        let title = NodeTitle(
            text: "abcXYZdef",
            runs: [
                Run(range: [0, 3]),  // before the wrap: untouched
                Run(range: [3, 3]),  // the wrapped text: shifted by the prefix
                Run(range: [6, 3]),  // after the wrap: shifted by prefix + suffix
            ])
        let wrapped = ClozeMaker.wrapped(title: title, note: nil, location: 3, length: 3)
        #expect(wrapped?.text == "abc{{c1::XYZ}}def")
        #expect(wrapped?.runs.map(\.range) == [[0, 3], [9, 3], [14, 3]])
    }

    @Test func emptyOrOutOfRangeSelectionsAreNoOps() {
        #expect(ClozeMaker.wrapped(title: NodeTitle(text: "abc"), note: nil, location: 1, length: 0) == nil)
        #expect(ClozeMaker.wrapped(title: NodeTitle(text: "abc"), note: nil, location: 3, length: 1) == nil)
        #expect(ClozeMaker.wrapped(title: NodeTitle(text: "abc"), note: nil, location: -1, length: 2) == nil)
    }
}

/// The "Good · 4d" next-interval labels (F-STD-4).
struct IntervalLabelTests {
    @Test func labelsMatchAnkiShortForms() {
        #expect(IntervalLabel.text(forSeconds: 30) == "<1m")
        #expect(IntervalLabel.text(forSeconds: 60) == "1m")
        #expect(IntervalLabel.text(forSeconds: 600) == "10m")
        #expect(IntervalLabel.text(forSeconds: 4 * 86_400) == "4d")
        #expect(IntervalLabel.text(forSeconds: 40 * 86_400) == "1mo")
        #expect(IntervalLabel.text(forSeconds: 100 * 86_400) == "3mo")
        #expect(IntervalLabel.text(forSeconds: 400 * 86_400) == "1y")
    }

    @Test func labelFromDatesHandlesOverdueAsUnderAMinute() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(IntervalLabel.text(from: now.addingTimeInterval(60), now: now) == "1m")
        #expect(IntervalLabel.text(from: now.addingTimeInterval(3_600), now: now) == "60m")
        #expect(IntervalLabel.text(from: now.addingTimeInterval(-60), now: now) == "<1m")
    }

    @Test func schedulerPreviewsLandOnTheseLabels() {
        // A grade preview through the real scheduler: a good answer to a
        // fresh card goes through learning steps (minutes), an easy
        // answer to a mature review lands in days.
        let scheduler = FSRSScheduler()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = FSRSCard.new(now: now)
        let good = scheduler.review(fresh, at: now, grade: .good)
        #expect(IntervalLabel.text(from: good.card.due, now: now) == "10m")

        var mature = FSRSCard.new(now: now.addingTimeInterval(-86_400 * 30))
        mature.state = .review
        mature.stability = 20
        mature.difficulty = 5
        mature.lastReview = now.addingTimeInterval(-86_400 * 30)
        let easy = scheduler.review(mature, at: now, grade: .easy)
        let label = IntervalLabel.text(from: easy.card.due, now: now)
        #expect(label.hasSuffix("d") || label.hasSuffix("mo"))
    }
}
