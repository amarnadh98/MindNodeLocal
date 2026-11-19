import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// F-FOC-3 hosted coverage: ⌘F finds, ⌘G moves the selection and the
/// camera follows; the folded ancestors of the current match temporarily
/// unfold in the SCENE only (the model, the undo stack and the saved
/// state are untouched); Replace and Replace All are each ONE undo
/// step, with runs preserved; ⌘E and the tags toggle work.
@MainActor
struct FindAndReplaceTests {
    @Test func commandFFindsAndCommandGMovesSelectionAndCamera() throws {
        let (document, controller) = try FocusFindFixtures.makeShownDocument(model: FocusFindFixtures.model())
        defer { document.close() }
        let canvas = controller.canvas

        // No session yet: the menu action validates off.
        #expect(!controller.focusFind.isFindActive)

        // ⌘F opens the find bar.
        controller.findAction(nil)
        #expect(controller.focusFind.isFindBarVisible)

        // Typing "beta": the matches, in document order, are a1's title
        // (behind the fold), b's title, b's note and b1's title — the
        // current match is a1, selected and followed by the camera.
        controller.focusFind.setFindQuery("beta")
        #expect(controller.focusFind.matches.count == 4)
        #expect(canvas.selection == ["a1"])
        #expect(canvas.overlays.findHighlightedIDs.isSuperset(of: ["b", "b1"]))
        #expect(canvas.overlays.currentHighlightID == "a1")

        // The current match is on screen (camera follow).
        let visible = canvas.camera.visibleRect(viewportSize: canvas.bounds.size)
        #expect(visible.contains(canvas.scene?.nodes["a1"]?.frame ?? .null))

        // ⌘G steps through: b's title, b's note (same node), b1, then
        // wraps around to a1. ⇧⌘G steps back.
        controller.findNextAction(nil)
        #expect(canvas.selection == ["b"])
        controller.findNextAction(nil)
        #expect(canvas.selection == ["b"])
        controller.findNextAction(nil)
        #expect(canvas.selection == ["b1"])
        controller.findNextAction(nil)
        #expect(canvas.selection == ["a1"])
        controller.findPreviousAction(nil)
        #expect(canvas.selection == ["b1"])

        // ⎋ hides the bar (through the Deselect escape hook) and
        // clears the rings.
        controller.deselectAction(nil)
        #expect(!controller.focusFind.isFindBarVisible)
        #expect(canvas.overlays.findRingCount == 0)
        #expect(canvas.overlays.currentHighlightID == nil)
    }

    @Test func foldedAncestorsUnfoldTemporarilyWithoutTouchingTheModel() throws {
        let (document, controller) = try FocusFindFixtures.makeShownDocument(model: FocusFindFixtures.model())
        defer { document.close() }
        let canvas = controller.canvas

        // The leaf hides behind the folded "alpha branch".
        #expect(document.model.nodes["a"]?.folded == true)
        #expect(canvas.scene?.nodes["a1"] == nil)
        #expect(!document.undoManager!.canUndo)

        // Finding it temporarily unfolds the ancestor in the scene…
        controller.findAction(nil)
        controller.focusFind.setFindQuery("hidden beta")
        #expect(canvas.selection == ["a1"])
        #expect(canvas.scene?.nodes["a1"] != nil, "the match must be visible through the temporary unfold")

        // …but NOT in the model: no command ran, nothing to undo, and
        // the document is not marked edited.
        #expect(document.model.nodes["a"]?.folded == true)
        #expect(!document.undoManager!.canUndo, "the temporary unfold must never be an undo step")
        #expect(!document.isDocumentEdited)

        // Closing the find bar folds the scene back.
        controller.deselectAction(nil)
        #expect(canvas.scene?.nodes["a1"] == nil)
    }

    @Test func replaceCurrentRewritesTheMatchInOneUndoStepAndAdvances() throws {
        let (document, controller) = try FocusFindFixtures.makeShownDocument(model: FocusFindFixtures.model())
        defer { document.close() }
        let canvas = controller.canvas

        controller.findReplaceAction(nil)
        controller.focusFind.setFindQuery("hidden beta")
        #expect(canvas.selection == ["a1"])

        // Replace: one command over the current match's title.
        controller.focusFind.replaceCurrent(with: "visible zeta")
        #expect(document.model.nodes["a1"]?.title.text == "visible zeta leaf")

        // The search re-ran against the replaced model: nothing left.
        #expect(controller.focusFind.matches.isEmpty)
        #expect(controller.focusFind.currentMatchIndex == nil)

        // ONE undo step for the Replace press — and the search that
        // follows the undo re-finds the restored title.
        #expect(document.undoManager!.canUndo)
        document.undoManager!.undo()
        #expect(document.model.nodes["a1"]?.title.text == "hidden beta leaf")
        #expect(controller.focusFind.matches.count == 1)
    }

    @Test func replaceAllOverTitlesAndNotesIsOneUndoStepAndPreservesRuns() throws {
        let (document, controller) = try FocusFindFixtures.makeShownDocument(model: FocusFindFixtures.model())
        defer { document.close() }

        controller.findReplaceAction(nil)
        #expect(controller.focusFind.isReplaceVisible)

        controller.focusFind.setFindQuery("beta")
        controller.focusFind.replaceAll(with: "zeta")

        // Every title and note replaced, runs preserved around the
        // ranges (b's bold run on "branch" shifts with the text).
        #expect(document.model.nodes["a1"]?.title.text == "hidden zeta leaf")
        #expect(document.model.nodes["b"]?.title.text == "zeta branch")
        #expect(document.model.nodes["b"]?.title.runs == [Run(range: [5, 6], bold: true)])
        #expect(document.model.nodes["b"]?.note == "a note containing zeta text")
        #expect(document.model.nodes["b1"]?.title.text == "zeta child")

        // ONE undo step restores every title and note at once.
        #expect(document.undoManager!.canUndo)
        document.undoManager!.undo()
        #expect(!document.undoManager!.canUndo)
        #expect(document.model.nodes["a1"]?.title.text == "hidden beta leaf")
        #expect(document.model.nodes["b"]?.title.text == "beta branch")
        #expect(document.model.nodes["b"]?.title.runs == [Run(range: [5, 6], bold: true)])
        #expect(document.model.nodes["b"]?.note == "a note containing BETA text")
        #expect(document.model.nodes["b1"]?.title.text == "beta child")
    }

    @Test func useSelectionForFindTakesTheSelectedTitle() throws {
        let (document, controller) = try FocusFindFixtures.makeShownDocument(model: FocusFindFixtures.model())
        defer { document.close() }
        let canvas = controller.canvas

        canvas.setSelection(["c"])
        controller.useSelectionForFindAction(nil)
        #expect(controller.focusFind.findQuery == "gamma branch")
        #expect(controller.focusFind.matches.count == 1)
        #expect(canvas.selection == ["c"])
    }

    @Test func tagsAreBehindTheFindBarToggle() throws {
        let (document, controller) = try FocusFindFixtures.makeShownDocument(model: FocusFindFixtures.model())
        defer { document.close() }

        controller.findAction(nil)
        controller.focusFind.setFindQuery("exam")
        #expect(controller.focusFind.matches.isEmpty)

        controller.focusFind.toggleTagSearch(true)
        #expect(controller.focusFind.matches.count == 1)
        #expect(controller.focusFind.matches[0].field == .tag)
        #expect(controller.canvas.selection == ["c"])
    }
}
