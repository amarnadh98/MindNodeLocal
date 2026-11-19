import AppKit
import MapCore
import MapStudy
import Testing

@testable import Arbor
@testable import CanvasKit

/// Golden-path scenario 3 (SPEC §3 item 3 — the M7 exit criterion):
/// select a branch → Study Branch → review 10 cards → the map shows
/// mastery colors. The map goes through the real document/store/window
/// path (Make Study Deck is the menu action, the session is the real
/// controller), the session is driven by the real key path (Space
/// reveals, Space/1–4 grade), and the asserts check the review log, the
/// nodes' FSRS state, the undo stack's silence on grading (ADR-0015)
/// and the mastery overlay's marks.
@MainActor
struct GoldenScenarioThreeTests {
    private struct DeckMap {
        var rootID = ""
        var deckID = ""
        var cardIDs: [String] = []
    }

    @Test func selectBranchStudyTenCardsMasteryColorsTheMap() throws {
        let (document, controller) = try Self.makeShownUntitledDocument()
        defer { document.close() }

        // Type the root ("Biology") through the editing overlay and
        // commit; the branch and its ten noted cards go through the
        // same store the canvas uses.
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("Biology")
        controller.canvas.commitEditing(next: .none)
        #expect(document.model.nodes[rootID]?.title.text == "Biology")

        let deck = DeckMap(rootID: rootID, deckID: "deck", cardIDs: (1...10).map { "card\($0)" })
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: deck.deckID, title: NodeTitle(text: "Anatomy"), study: NodeStudy(card: .off))))
        for (position, cardID) in deck.cardIDs.enumerated() {
            try document.store.perform(
                .addChild(
                    parent: deck.deckID, index: position,
                    node: Node(id: cardID, title: NodeTitle(text: "Term \(position + 1)"), note: "definition")))
        }
        controller.updateScene(preserveCamera: true)

        // F-STD-1: the branch becomes a deck through the menu action.
        controller.canvas.setSelection([deck.deckID])
        controller.makeStudyDeckAction(nil)
        #expect(document.model.nodes[deck.deckID]?.study?.deck == true)

        // …and can be undone as ONE step with the exact pre-state back.
        document.undoManager?.undo()
        #expect(document.model.nodes[deck.deckID]?.study?.deck == nil)
        document.undoManager?.redo()
        #expect(document.model.nodes[deck.deckID]?.study?.deck == true)

        // F-STD-1: ten cards (the deck node opted out, leaves have notes).
        let cards = CardExtractor.extract(from: document.model, subtreeRoot: deck.deckID)
        #expect(cards.count == 10)
        #expect(cards.map(\.id).sorted() == deck.cardIDs.sorted())

        // Study Branch: the real session over the selected deck.
        controller.studyBranchAction(nil)
        let session = try #require(controller.activeStudySession)
        let sessionView = session.sessionView

        // Grade keys are inert before the reveal (F-STD-4's Space-first flow).
        Self.sendKey(to: sessionView, "3")
        #expect(!sessionView.revealed)

        // The scripted session: Space reveals; the first Good arrives by
        // Space itself, the rest through the grade keys 1–4.
        let ladder: [Grade] = [.good, .again, .hard, .easy] + .init(repeating: .good, count: 6)
        var script: [Grade] = []
        for grade in ladder {
            Self.sendKey(to: sessionView, " ")
            #expect(sessionView.revealed, "Space must reveal the answer")
            if grade == .good && script.isEmpty {
                Self.sendKey(to: sessionView, " ")  // Space = Good once revealed
            } else {
                Self.sendKey(to: sessionView, key(for: grade))
            }
            script.append(grade)
        }
        // The summary replaced the card (session complete).
        #expect(!sessionView.revealed)

        // ADR-0015: grading is history — the review log has ten entries
        // and no undo step exists for any grading: the one undo still
        // available is the deck toggle (the last registered EDIT), and
        // undoing it leaves every grade intact.
        #expect(document.reviewLog.count == 10)
        document.undoManager?.undo()
        #expect(document.model.nodes[deck.deckID]?.study?.deck == nil)
        #expect(document.reviewLog.count == 10)
        for cardID in deck.cardIDs {
            #expect(document.model.nodes[cardID]?.study?.fsrs?.reps == 1)
        }
        document.undoManager?.redo()
        #expect(document.model.nodes[deck.deckID]?.study?.deck == true)

        // The FSRS state lives on every card node (F-STD-3): reviewed
        // once, out of the new state.
        for cardID in deck.cardIDs {
            let study = document.model.nodes[cardID]?.study
            #expect(study?.fsrs?.reps == 1, "\(cardID) was not graded")
            #expect(study?.fsrs?.state != .new)
        }
        // The grades landed as scripted (the log records each grade).
        #expect(document.reviewLog.map(\.grade) == script)

        // Grading dirtied the document without an undo group (the
        // non-undoable write path must still save).
        Self.settle()
        #expect(document.isDocumentEdited)

        // The map shows mastery colors (F-STD-6): ⌥⌘H through the menu
        // action (the pref pinned off first, so the toggle deterministically
        // flips it on), then the overlay realizes marks for the card nodes.
        UserDefaults.standard.set(false, forKey: DocumentWindowController.masteryDefaultsKey)
        controller.applyMasteryOverlay()
        controller.toggleMasteryOverlayAction(nil)
        let marks = try Self.marks(for: controller, document: document)
        for cardID in deck.cardIDs {
            #expect(marks[cardID] != nil, "\(cardID) has no mastery mark")
            if case .outline = marks[cardID] {
                Issue.record("\(cardID) is fresh but was just graded")
            }
        }
        // The deck node (a card ancestor, opted out as a card) carries
        // the aggregate ring.
        if case .ring = marks[deck.deckID] {
        } else {
            Issue.record("the deck node has no aggregate ring")
        }
        // The overlay actually realized layers for the visible marks.
        #expect(controller.canvas.layerTree.mastery.visibleNodeIDs.contains(deck.cardIDs.first!))

        // And the overlay is pure view state: toggling it never dirties.
        let editedBefore = document.isDocumentEdited
        controller.toggleMasteryOverlayAction(nil)
        #expect(document.isDocumentEdited == editedBefore)
        UserDefaults.standard.removeObject(forKey: DocumentWindowController.masteryDefaultsKey)
    }

    // MARK: grading persists across save and reopen (F-STD-3, §14.1.4)

    @Test func gradesAndReviewLogSurviveSaveAndReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("study-\(UUID().uuidString).arbor")
        let truncatedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("study-truncated-\(UUID().uuidString).arbor")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: truncatedURL)
        }

        let (document, controller) = try Self.makeShownUntitledDocument()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("Deck Root")
        controller.canvas.commitEditing(next: .none)

        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(
                    id: "deck", title: NodeTitle(text: "Deck"),
                    study: NodeStudy(card: .off, deck: true))))
        try document.store.perform(
            .addChild(
                parent: "deck", index: 0,
                node: Node(id: "card", title: NodeTitle(text: "Card"), note: "answer")))
        try document.store.perform(
            .addChild(
                parent: "deck", index: 1,
                node: Node(id: "card2", title: NodeTitle(text: "Card 2"), note: "answer 2")))

        // Two real gradings through the document path.
        let extracted = CardExtractor.extract(from: document.model)
        let card = try #require(extracted.first { $0.id == "card" })
        let card2 = try #require(extracted.first { $0.id == "card2" })
        document.grade(card: card, grade: .good)
        document.grade(card: card2, grade: .hard)
        #expect(document.reviewLog.count == 2)

        try await document.save(to: url, ofType: AppIdentity.documentUTI, for: .saveAsOperation)

        // Reopen through the document controller: the FSRS state and the
        // review log both come back from the package.
        let reopened = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { reopened.close() }
        #expect(reopened.reviewLog.count == 2)
        #expect(reopened.reviewLog.first?.cardID == card.id)
        #expect(reopened.reviewLog.first?.grade == .good)
        #expect(reopened.reviewLog.last?.cardID == card2.id)
        #expect(reopened.reviewLog.last?.grade == .hard)
        #expect(reopened.model.nodes["card"]?.study?.fsrs?.reps == 1)
        #expect(reopened.model.nodes["card"]?.study?.fsrs?.state == .learning)

        // …and a truncated tail reads as the log's history minus the
        // interrupted append (never a failure to open).
        let root = try FileWrapper(url: url, options: [])
        let study = try #require(root.fileWrappers?["study"])
        let log = try #require(study.fileWrappers?["reviews.jsonl"])
        let raw = String(data: log.regularFileContents ?? Data(), encoding: .utf8) ?? ""
        // Interrupt the append mid-last-line: the history before it reads.
        ArborPackage.setStudyLog(Data(raw.dropLast(20).utf8), in: root)
        try root.write(to: truncatedURL, options: [.atomic], originalContentsURL: nil)
        let reopenedTruncated = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: truncatedURL, ofType: AppIdentity.documentUTI) as? MapDocument)
        #expect(reopenedTruncated.reviewLog.count == 1)
        #expect(reopenedTruncated.reviewLog.first?.cardID == "card")
        reopenedTruncated.close()
    }

    // MARK: Make Cloze through the editor (F-STD-2)

    @Test func makeClozeWrapsSelectedTitleTextWithTheNextFreeIndex() throws {
        let (document, controller) = try Self.makeShownUntitledDocument()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("The powerhouse of the cell")
        controller.canvas.commitEditing(next: .none)

        // Re-enter editing and select "powerhouse" (F-EDT-2, then ⇧⌘C).
        controller.canvas.beginEditing(nodeID: rootID)
        let editor = controller.canvas.nodeTextEditor
        let text = try #require(editor.currentTitle())
        let location = (text.text as NSString).range(of: "powerhouse").location
        editor.selectTitleRange(NSRange(location: location, length: "powerhouse".count))
        controller.makeClozeAction(nil)

        #expect(document.model.nodes[rootID]?.title.text == "The {{c1::powerhouse}} of the cell")
        // The undo step is named for the action (F-DOC-2).
        #expect(document.undoManager?.canUndo == true)
        document.undoManager?.undo()
        #expect(document.model.nodes[rootID]?.title.text == "The powerhouse of the cell")
        document.undoManager?.redo()

        // A second cloze on the same node takes index 2 (next free).
        controller.canvas.beginEditing(nodeID: rootID)
        editor.selectTitleRange(NSRange(location: 0, length: 3))
        controller.makeClozeAction(nil)
        #expect(document.model.nodes[rootID]?.title.text == "{{c2::The}} {{c1::powerhouse}} of the cell")
    }

    // MARK: helpers (shared with the other study suites in this file)

    static func makeShownUntitledDocument() throws -> (MapDocument, DocumentWindowController) {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(
                ofType: AppIdentity.documentUTI) as? MapDocument)
        document.undoManager?.groupsByEvent = false
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        controller.viewStateStore = ViewStateStore(
            baseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("study-tests-\(UUID().uuidString)", isDirectory: true))
        controller.viewStateSaveDelay = .milliseconds(10)
        controller.showWindow(nil)
        return (document, controller)
    }

    /// NSDocument posts its undo-group change counts on a later run-loop
    /// turn; spin briefly so `isDocumentEdited` reflects them.
    static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private static func marks(
        for controller: DocumentWindowController, document: MapDocument
    ) throws -> [String: MasteryMark] {
        let report = MasteryReport.compute(map: document.model, now: Date())
        return DocumentWindowController.masteryMarks(from: report)
    }

    private func key(for grade: Grade) -> String {
        switch grade {
        case .again: "1"
        case .hard: "2"
        case .good: "3"
        case .easy: "4"
        }
    }

    private static func sendKey(to view: NSView, _ key: String) {
        view.keyDown(with: keyEvent(key))
    }

    private static func keyEvent(_ key: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    }
}

/// The mastery overlay as a document-window citizen (F-STD-6): ⌥⌘H
/// toggles pure view state — the document's change count never moves.
@MainActor
struct MasteryOverlayHostedTests {
    @Test func togglingNeverDirtiesTheDocument() throws {
        let (document, controller) = try GoldenScenarioThreeTests.makeShownUntitledDocument()
        defer { document.close() }

        // A clean document: the toggle on and off changes no model state.
        UserDefaults.standard.set(false, forKey: DocumentWindowController.masteryDefaultsKey)
        #expect(!controller.masteryOverlayEnabled)
        #expect(!document.isDocumentEdited)
        controller.toggleMasteryOverlayAction(nil)
        #expect(controller.masteryOverlayEnabled)
        #expect(!document.isDocumentEdited)
        #expect(document.model.nodes.values.allSatisfy { $0.study == nil })

        // An edited document: the toggle leaves the change count alone.
        try document.store.perform(.setFolded(id: document.model.roots[0], folded: false))
        controller.updateScene(preserveCamera: true)
        GoldenScenarioThreeTests.settle()
        controller.toggleMasteryOverlayAction(nil)
        #expect(!controller.masteryOverlayEnabled)
        #expect(document.isDocumentEdited)
        controller.toggleMasteryOverlayAction(nil)
        #expect(document.isDocumentEdited)
    }
}
