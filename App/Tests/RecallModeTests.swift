import AppKit
import MapCore
import MapStudy
import Testing

@testable import Arbor
@testable import CanvasKit

/// F-STD-5 — recall mode on the canvas, driven through the real app
/// paths (the ⌥⌘R menu action, the session's own event entry point,
/// the document's non-undoable grading write): placeholders hide the
/// branch's descendants, → and clicks reveal, ⌥-click reveals a
/// subtree, 1/2 grade the last revealed node's card Good/Again, Esc
/// exits — and none of it ever dirties the document except through
/// grading (ADR-0015's no-undo-step contract).
@MainActor
struct RecallModeTests {
    @Test func recallHidesRevealsMarksAndExitsThroughTheRealPaths() throws {
        let (document, controller) = try GoldenScenarioThreeTests.makeShownUntitledDocument()
        defer { document.close() }

        // Type the root, then build the branch: deck → a (noted) → a1
        // (noted), deck → b (noted). "b" is created LAST so the one
        // undo group after a grading is provably still an EDIT, never
        // the grading itself (ADR-0015).
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("Biology")
        controller.canvas.commitEditing(next: .none)
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "deck", title: NodeTitle(text: "Anatomy"))))
        try document.store.perform(
            .addChild(
                parent: "deck", index: 0,
                node: Node(id: "a", title: NodeTitle(text: "Mitochondria"), note: "the powerhouse")))
        try document.store.perform(
            .addChild(
                parent: "a", index: 0,
                node: Node(id: "a1", title: NodeTitle(text: "Cristae"), note: "the folds")))
        try document.store.perform(
            .addChild(
                parent: "deck", index: 1,
                node: Node(id: "b", title: NodeTitle(text: "Ribosome"), note: "protein factory")))
        controller.updateScene(preserveCamera: true)

        // ⌥⌘R (Study ▸ Recall) through the menu action.
        controller.canvas.setSelection(["deck"])
        let editedBefore = document.isDocumentEdited
        controller.recallAction(nil)
        let session = try #require(controller.recallSessionBox)

        // All descendants hide behind placeholders; the branch node
        // itself (the prompt), the root and everything else stay
        // drawn. Entering never dirties: still exactly the edits.
        let states = try #require(controller.canvas.layerTree.revealOverlay?.states)
        #expect(states["a"] == .placeholder)
        #expect(states["a1"] == .placeholder)
        #expect(states["b"] == .placeholder)
        #expect(states["deck"] == nil)
        #expect(states[rootID] == nil)
        #expect(document.isDocumentEdited == editedBefore)

        // → reveals ONE node at a time, never a subtree (the order is
        // map order: a, a1, b).
        session.handle(.revealNext)
        #expect(controller.canvas.layerTree.revealOverlay?.states["a"] == .visible)
        #expect(controller.canvas.layerTree.revealOverlay?.states["a1"] == .placeholder)

        // 1 (✓ remembered): the node IS a card under the branch
        // session's implicit deck — graded Good through the
        // non-undoable path, no undo group, document now dirty.
        session.handle(.remembered)
        #expect(document.reviewLog.count == 1)
        #expect(document.reviewLog[0].cardID == "a")
        #expect(document.reviewLog[0].grade == .good)
        #expect(document.model.nodes["a"]?.study?.fsrs?.reps == 1)
        #expect(document.model.nodes["a"]?.study?.fsrs?.state != .new)
        #expect(document.isDocumentEdited)
        // The recall run survives its own grading (the .nonUndoable
        // origin must not end the mode).
        #expect(controller.recallSessionBox != nil)

        // ⌥-click on a1's placeholder reveals exactly its subtree (a
        // leaf here), through the RevealEngine's collection.
        let a1Frame = try #require(controller.canvas.scene?.nodes["a1"]?.frame)
        let point = controller.canvas.camera.screenPoint(
            for: CGPoint(x: a1Frame.midX, y: a1Frame.midY))
        session.handle(.click(point: point, option: true))
        #expect(controller.canvas.layerTree.revealOverlay?.states["a1"] == .visible)

        // A plain click on a visible node reveals nothing new.
        session.handle(.click(point: point, option: false))
        #expect(controller.canvas.layerTree.revealOverlay?.states["b"] == .placeholder)

        // 2 (✗ forgot) on the just-revealed a1: graded Again.
        session.handle(.forgot)
        #expect(document.reviewLog.count == 2)
        #expect(document.reviewLog[1].cardID == "a1")
        #expect(document.reviewLog[1].grade == .again)
        #expect(document.model.nodes["a1"]?.study?.fsrs?.reps == 1)
        // Untouched node: no state, no log entry.
        #expect(document.model.nodes["b"]?.study == nil)

        // Esc exits: overlay gone, canvas first responder again, the
        // document's change count untouched by the exit itself.
        session.handle(.exit)
        #expect(controller.recallSessionBox == nil)
        #expect(controller.canvas.layerTree.revealOverlay == nil)
        #expect(controller.canvas.layerTree.nodeLayers.values.allSatisfy { $0.opacity == 1 })
        #expect(controller.window?.firstResponder == controller.canvas)

        // The ⌥⌘R menu action toggles: active → exit, inactive → start.
        controller.recallAction(nil)
        #expect(controller.recallSessionBox != nil)
        controller.recallAction(nil)
        #expect(controller.recallSessionBox == nil)
    }

    @Test func markingWithoutARevealIsInertAndANonCardNodeNeverGrades() throws {
        let (document, controller) = try GoldenScenarioThreeTests.makeShownUntitledDocument()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("Root")
        controller.canvas.commitEditing(next: .none)
        // A branch of bare un-noted leaves: not cards under the auto
        // rule, so marks are session feedback only.
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "deck", title: NodeTitle(text: "Deck"))))
        try document.store.perform(
            .addChild(
                parent: "deck", index: 0,
                node: Node(id: "leaf", title: NodeTitle(text: "Leaf"))))
        controller.updateScene(preserveCamera: true)

        controller.canvas.setSelection(["deck"])
        controller.recallAction(nil)
        let session = try #require(controller.recallSessionBox)

        // 1/2 before any reveal: no target, no grading, no dirtying.
        let editedBefore = document.isDocumentEdited
        session.handle(.remembered)
        #expect(document.reviewLog.isEmpty)
        #expect(document.isDocumentEdited == editedBefore)

        // A revealed non-card node: the HUD feedback happens, but no
        // FSRS write ever lands on the model.
        session.handle(.revealNext)
        session.handle(.forgot)
        #expect(document.reviewLog.isEmpty)
        #expect(document.model.nodes["leaf"]?.study == nil)
        #expect(document.isDocumentEdited == editedBefore)
        session.handle(.exit)
    }

    @Test func recallExitsOnARealEditButNotOnItsOwnGrading() throws {
        let (document, controller) = try GoldenScenarioThreeTests.makeShownUntitledDocument()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("Root")
        controller.canvas.commitEditing(next: .none)
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "deck", title: NodeTitle(text: "Deck"))))
        try document.store.perform(
            .addChild(
                parent: "deck", index: 0,
                node: Node(id: "card", title: NodeTitle(text: "Card"), note: "answer")))
        controller.updateScene(preserveCamera: true)

        controller.canvas.setSelection(["deck"])
        controller.recallAction(nil)
        let session = try #require(controller.recallSessionBox)

        // Grading keeps the mode alive…
        session.handle(.revealNext)
        session.handle(.remembered)
        #expect(document.reviewLog.count == 1)
        #expect(controller.recallSessionBox != nil)

        // …but a real edit (undo/redo included) ends it, so the
        // overlay can never go stale against the tree. Undoing the
        // grade itself must not exist on the stack: the first undo
        // reverts the LAST EDIT — the card's addChild — and the grade
        // survives it in the history (ADR-0015: the review log entry
        // cannot be un-happened; the node's state went with the
        // deleted node, restored by redo at its pre-grade snapshot).
        document.undoManager?.undo()
        #expect(controller.recallSessionBox == nil)
        #expect(document.model.nodes["card"] == nil)
        #expect(document.reviewLog.count == 1)

        // Redo restores the edit; the log keeps the review.
        document.undoManager?.redo()
        #expect(document.model.nodes["card"] != nil)
        #expect(document.model.nodes["card"]?.study?.fsrs == nil)
        #expect(document.reviewLog.count == 1)
    }

    @Test func aFoldedOrChildlessBranchHasNothingToRecall() throws {
        let (document, controller) = try GoldenScenarioThreeTests.makeShownUntitledDocument()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("Root")
        controller.canvas.commitEditing(next: .none)
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "deck", title: NodeTitle(text: "Deck"))))
        try document.store.perform(
            .addChild(
                parent: "deck", index: 0,
                node: Node(id: "child", title: NodeTitle(text: "Child"))))
        controller.updateScene(preserveCamera: true)

        // A childless selection: recall has nothing to hide — no
        // session starts.
        controller.canvas.setSelection(["child"])
        controller.recallAction(nil)
        #expect(controller.recallSessionBox == nil)

        // A branch whose descendants are folded away on the canvas:
        // recall has nothing to hide (F-STD-5 is spatial).
        controller.canvas.setSelection(["deck"])
        try document.store.perform(.setFolded(id: "deck", folded: true))
        controller.updateScene(preserveCamera: true)
        controller.recallAction(nil)
        #expect(controller.recallSessionBox == nil)
    }

    // MARK: menu validation (the ONE validateMenuItem's recall arm)

    @Test func recallMenuItemValidatesBySelectionAndRunState() throws {
        let (document, controller) = try GoldenScenarioThreeTests.makeShownUntitledDocument()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("Root")
        controller.canvas.commitEditing(next: .none)
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "deck", title: NodeTitle(text: "Deck"))))
        try document.store.perform(
            .addChild(
                parent: "deck", index: 0,
                node: Node(id: "leaf", title: NodeTitle(text: "Leaf"))))
        controller.updateScene(preserveCamera: true)

        let item = NSMenuItem(
            title: "Recall", action: #selector(DocumentWindowController.recallAction(_:)),
            keyEquivalent: "r")

        // Nothing selected: disabled.
        controller.canvas.setSelection([])
        #expect(!controller.validateMenuItem(item))

        // A branch with descendants: enabled, unchecked.
        controller.canvas.setSelection(["deck"])
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .off)

        // A live run: enabled and checkmarked (⌥⌘R toggles).
        controller.recallAction(nil)
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .on)
        controller.recallAction(nil)
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .off)
    }

    // MARK: shield key translation (the pure half of the input path)

    @Test func recallKeysTranslateFromEvents() {
        func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> RecallKey {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
            return RecallKey.key(for: event)
        }
        #expect(key("\u{f703}") == .revealNext)
        #expect(key("1") == .remembered)
        #expect(key("2") == .forgot)
        #expect(key("\u{1b}") == .exit)
        #expect(key("3") == .unknown)
        #expect(key("r", modifiers: [.option, .command]) == .unknown)
    }
}

/// F-STD-7's dashboard snapshot: the per-deck due breakdown rides with
/// the precomputed values the SwiftUI view renders.
@MainActor
struct StudyDashboardSnapshotTests {
    @Test func snapshotCarriesDuePerDeck() throws {
        let (document, controller) = try GoldenScenarioThreeTests.makeShownUntitledDocument()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        controller.canvas.nodeTextEditor.insertText("Biology")
        controller.canvas.commitEditing(next: .none)
        // deckA → (a1, a2, deckB(b1)); plain p1 outside every deck.
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "deckA", title: NodeTitle(text: "Anatomy"), study: NodeStudy(deck: true))))
        for (index, id) in ["a1", "a2"].enumerated() {
            try document.store.perform(
                .addChild(
                    parent: "deckA", index: index,
                    node: Node(id: id, title: NodeTitle(text: id), note: "answer")))
        }
        try document.store.perform(
            .addChild(
                parent: "deckA", index: 2,
                node: Node(id: "deckB", title: NodeTitle(text: "Cells"), study: NodeStudy(deck: true))))
        try document.store.perform(
            .addChild(
                parent: "deckB", index: 0,
                node: Node(id: "b1", title: NodeTitle(text: "Mitochondria"), note: "answer")))
        controller.updateScene(preserveCamera: true)

        // One card graded Good an hour ago is due (its learning step
        // elapsed); everything else is still new.
        let cards = CardExtractor.extract(from: document.model)
        let a1 = try #require(cards.first { $0.id == "a1" })
        document.grade(card: a1, grade: .good, now: Date().addingTimeInterval(-3_600))

        let snapshot = DashboardSnapshot.snapshot(of: document)
        #expect(snapshot.decks.map(\.id) == ["deckA", "deckB"])
        #expect(snapshot.decks[0].name == "Anatomy")
        #expect(snapshot.decks[0].due == 1)
        // The nearest-deck rule counts the deck node's own card too
        // (deckA has children, so it is a card inside its own deck).
        #expect(snapshot.decks[0].total == 3)
        #expect(snapshot.decks[1].name == "Cells")
        #expect(snapshot.decks[1].due == 0)
        #expect(snapshot.decks[1].total == 2)
        // The document-level tiles still work (F-STD-7's due today).
        #expect(snapshot.dueToday == 1)
        #expect(snapshot.totalCards == 5)
    }

    @Test func reminderTimeDefaultsToNineAndReadsThePreference() throws {
        let suiteName = "recal-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // No stored time: 9:00 local.
        let morning = StudyPreferences.reminderTime(defaults: defaults)
        let components = Calendar.current.dateComponents([.hour, .minute], from: morning)
        #expect(components.hour == 9)
        #expect(components.minute == 0)

        // A stored time round-trips untouched.
        let stored = Date(timeIntervalSince1970: 0).addingTimeInterval(14 * 3_600 + 30 * 60)
        defaults.set(stored, forKey: StudyPreferences.dailyReminderTimeKey)
        let readBack = StudyPreferences.reminderTime(defaults: defaults)
        #expect(readBack == stored)
    }
}
