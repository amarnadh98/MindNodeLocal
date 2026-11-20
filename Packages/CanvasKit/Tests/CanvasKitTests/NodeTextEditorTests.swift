import AppKit
import CoreGraphics
import CoreText
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// Inline editing overlay tests (SPEC §11.4, F-EDT-1/2/7/8, F-EDT-15):
/// title⇄attributed-string conversion with the §8.3 allow-list enforced,
/// the key-routing table, the IME guard through the real event path,
/// one-commit-one-undo-step, empty commits keeping brand-new nodes, and
/// overlay geometry.
@MainActor
struct NodeTextEditorTests {
    // MARK: title ⇄ attributed string (§8.3)

    @Test func roundTripsRunsThroughTheEditorString() throws {
        let font = NSFont.systemFont(ofSize: 16)
        let color = NSColor.labelColor
        let title = NodeTitle(
            text: "hello bold world",
            runs: [
                Run(range: [6, 4], bold: true),
                Run(range: [11, 5], color: "#FF0000"),
            ])

        let attributed = NodeTitleText.attributed(title, baseFont: font, baseColor: color)
        let back = NodeTitleText.title(from: attributed, baseFont: font, baseColor: color)

        #expect(back.text == title.text)
        let bold = try #require(back.runs.first { $0.bold == true })
        #expect(bold.range == [6, 4])
        let red = try #require(back.runs.first { $0.color == "#FF0000" })
        #expect(red.range == [11, 5])
        // Nothing outside the allow-list leaks into the editor string.
        let keys = try #require(collectedAttributeKeys(attributed))
        #expect(keys.isSubset(of: NodeTitleText.allowListedKeys))
    }

    @Test func extractionDropsNonAllowListedAttributes() {
        let junk = NSMutableAttributedString(
            string: "plain",
            attributes: [
                .kern: 5.0, .obliqueness: 0.5, .toolTip: "junk",
            ])
        junk.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 16), range: NSRange(0..<5))

        let back = NodeTitleText.title(
            from: junk, baseFont: NSFont.systemFont(ofSize: 16), baseColor: .labelColor)

        #expect(back.text == "plain")
        #expect(back.runs.count == 1)
        #expect(back.runs.first?.bold == true)
        #expect(back.runs.first?.range == [0, 5])
        #expect(back.runs.first?.color == nil)
        #expect(back.runs.first?.font == nil)
    }

    @Test func semiboldBaseFontIsNotABookmarkBoldRun() {
        // The Paper theme's root is 20 pt semibold, and AppKit reports
        // the bold mask for semibold system fonts — a plain-typed root
        // title must not persist a phantom `bold` run (it would export
        // as **bold** Markdown and mark a style override in map.json).
        let semibold = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let plain = NSMutableAttributedString(
            string: "Golden", attributes: [.font: semibold])

        let back = NodeTitleText.title(
            from: plain, baseFont: semibold, baseColor: .labelColor)

        #expect(back.runs.isEmpty)
    }

    @Test func explicitBoldRecordsAgainstASemiboldBaseFont() {
        // ⌘B on the semibold root still records: the run font is heavier
        // than the base, which is what "explicit" means.
        let semibold = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let styled = NSMutableAttributedString(
            string: "Golden", attributes: [.font: semibold])
        styled.addAttribute(
            .font, value: NSFont.systemFont(ofSize: 20, weight: .bold), range: NSRange(0..<6))

        let back = NodeTitleText.title(
            from: styled, baseFont: semibold, baseColor: .labelColor)

        #expect(back.runs.count == 1)
        #expect(back.runs.first?.bold == true)
        #expect(back.runs.first?.range == [0, 6])
    }

    @Test func extractionCoalescesAdjacentIdenticalRuns() {
        let title = NodeTitle(
            text: "abcdef",
            runs: [
                Run(range: [0, 2], bold: true),
                Run(range: [2, 2], bold: true),
            ])
        let attributed = NodeTitleText.attributed(
            title, baseFont: NSFont.systemFont(ofSize: 14), baseColor: .labelColor)
        let back = NodeTitleText.title(
            from: attributed, baseFont: NSFont.systemFont(ofSize: 14), baseColor: .labelColor)
        #expect(back.runs.count == 1)
        #expect(back.runs.first?.range == [0, 4])
    }

    @Test func outOfRangeRunsAreClampedNotCrashing() {
        let title = NodeTitle(text: "abc", runs: [Run(range: [2, 100], bold: true)])
        let attributed = NodeTitleText.attributed(
            title, baseFont: NSFont.systemFont(ofSize: 14), baseColor: .labelColor)
        #expect(attributed.length == 3)
        let back = NodeTitleText.title(
            from: attributed, baseFont: NSFont.systemFont(ofSize: 14), baseColor: .labelColor)
        #expect(back.runs.first?.range == [2, 1])
    }

    @Test func lineBreaksSurviveTheRoundTrip() {
        let title = NodeTitle(text: "one\ntwo")
        let attributed = NodeTitleText.attributed(
            title, baseFont: NSFont.systemFont(ofSize: 14), baseColor: .labelColor)
        let back = NodeTitleText.title(
            from: attributed, baseFont: NSFont.systemFont(ofSize: 14), baseColor: .labelColor)
        #expect(back.text == "one\ntwo")
        #expect(back.runs.isEmpty)
    }

    // MARK: key routing table (F-EDT-1/2, F-EDT-15)

    @Test func keyDecisionsMatchTheSpec() {
        typealias Decision = NodeTextEditor.KeyDecision
        #expect(
            NodeTextEditor.decide(key: "\r", command: false, option: false, shift: false, hasMarkedText: false)
                == .commitAndCreate(.siblingBelow))
        #expect(
            NodeTextEditor.decide(key: "\t", command: false, option: false, shift: false, hasMarkedText: false)
                == .commitAndCreate(.child))
        #expect(
            NodeTextEditor.decide(key: "\r", command: false, option: true, shift: false, hasMarkedText: false)
                == .commitAndCreate(.siblingAbove))
        #expect(
            NodeTextEditor.decide(key: "\t", command: false, option: true, shift: false, hasMarkedText: false)
                == .commitAndCreate(.insertParent))
        #expect(
            NodeTextEditor.decide(key: "\r", command: false, option: false, shift: true, hasMarkedText: false)
                == .insertLineBreak)
        #expect(
            NodeTextEditor.decide(key: "\r", command: true, option: false, shift: false, hasMarkedText: false)
                == .commit)
        #expect(
            NodeTextEditor.decide(key: "\u{1b}", command: false, option: false, shift: false, hasMarkedText: false)
                == .commit)
        #expect(
            NodeTextEditor.decide(key: "a", command: false, option: false, shift: false, hasMarkedText: false)
                == nil)
    }

    @Test func markedTextClaimsEveryEditingKey() {
        // During an IME composition ⏎/⇥/⎋ belong to the input method and
        // must never commit or create (F-EDT-15).
        for key in ["\r", "\t", "\u{1b}"] {
            let marked = NodeTextEditor.decide(
                key: key, command: false, option: false, shift: false, hasMarkedText: true)
            #expect(marked == .passToInputMethod)
        }
        // Non-editing keys are still nobody's business.
        #expect(
            NodeTextEditor.decide(key: "a", command: false, option: false, shift: false, hasMarkedText: true)
                == nil)
    }

    // MARK: the event path, end to end

    @Test func commitThroughKeyEquivalentCreatesOneUndoStep() throws {
        let harness = EditingHarness(model: sceneModel())
        canvasBeginEditing(harness, node: "branch-0")
        harness.editor.insertText("hello ")
        harness.editor.insertText("world")

        // Two keystrokes, one draft each — but nothing in the store yet.
        #expect(harness.drafts.count == 2)
        #expect(harness.store.model.nodes["branch-0"]?.title.text == "alpha")

        let handled = try #require(harness.view).performKeyEquivalent(with: Self.keyEvent("\r"))
        #expect(handled)
        #expect(harness.commits.count == 1)
        #expect(harness.commits.first?.next == .siblingBelow)
        #expect(!harness.canvas.isEditing)
        #expect(harness.store.model.nodes["branch-0"]?.title.text == "hello world")

        // Exactly one undo step covers the whole typing session: a single
        // undo restores the session's start (F-DOC-2).
        harness.store.undoManager.undo()
        #expect(harness.store.model.nodes["branch-0"]?.title.text == "alpha")
        #expect(!harness.store.undoManager.canUndo)
    }

    @Test func aSecondSessionOnTheSameNodeIsASecondUndoStep() throws {
        let harness = EditingHarness(model: sceneModel())
        canvasBeginEditing(harness, node: "branch-0")
        harness.editor.insertText("first")
        harness.editor.commit(next: .none)

        canvasBeginEditing(harness, node: "branch-0")
        harness.editor.insertText("second")
        harness.editor.commit(next: .none)
        #expect(harness.store.model.nodes["branch-0"]?.title.text == "second")

        harness.store.undoManager.undo()
        #expect(harness.store.model.nodes["branch-0"]?.title.text == "first")
        harness.store.undoManager.undo()
        #expect(harness.store.model.nodes["branch-0"]?.title.text == "alpha")
    }

    @Test func shiftReturnInsertsALineBreakWithoutCommitting() throws {
        let harness = EditingHarness(model: sceneModel())
        canvasBeginEditing(harness, node: "branch-0")
        harness.editor.insertText("two words")

        let handled = try #require(harness.view).performKeyEquivalent(
            with: Self.keyEvent("\r", modifiers: [.shift]))
        #expect(handled)
        #expect(harness.commits.isEmpty)
        #expect(harness.canvas.isEditing)
        // The draft now carries the line break (multi-line titles, F-EDT-7).
        #expect(harness.drafts.last?.title.text == "two words\n")
    }

    @Test func markedTextReturnNeverCommitsOrCreates() throws {
        let harness = EditingHarness(model: sceneModel())
        canvasBeginEditing(harness, node: "branch-0")
        let view = try #require(harness.view)

        // Simulated IME session: ⏎ confirms the composition only.
        view.simulateMarkedText = true
        #expect(view.performKeyEquivalent(with: Self.keyEvent("\r")))
        #expect(harness.commits.isEmpty)
        #expect(harness.canvas.isEditing)
        #expect(harness.store.model.nodes["branch-0"]?.title.text == "alpha")

        // Same for ⇥ and ⎋ while composed.
        #expect(view.performKeyEquivalent(with: Self.keyEvent("\t")))
        #expect(view.performKeyEquivalent(with: Self.keyEvent("\u{1b}")))
        #expect(harness.commits.isEmpty)

        // With the session over, ⏎ is back to commit-and-create.
        view.simulateMarkedText = false
        #expect(view.performKeyEquivalent(with: Self.keyEvent("\r")))
        #expect(harness.commits.count == 1)
    }

    @Test func realMarkedTextBlocksTheCommit() throws {
        let harness = EditingHarness(model: sceneModel())
        canvasBeginEditing(harness, node: "branch-0")
        let view = try #require(harness.view)

        // A real input-method session: setMarkedText is exactly what the
        // IME calls on the text view.
        view.setMarkedText(
            "あ", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        #expect(view.hasMarkedText())

        #expect(view.performKeyEquivalent(with: Self.keyEvent("\r")))
        #expect(harness.commits.isEmpty)
        #expect(harness.canvas.isEditing)
    }

    @Test func emptyCommitKeepsTheBrandNewNode() throws {
        // MindNode behaviour (ADR-0006): committing empty text on a fresh
        // node keeps the node instead of deleting it.
        var model = sceneModel()
        let fresh = "fresh"
        model.nodes[fresh] = Node(
            id: fresh, parent: "root", title: NodeTitle(text: ""),
            created: sceneDate, modified: sceneDate)
        model.nodes["root"]?.children.append(fresh)

        let harness = EditingHarness(model: model)
        canvasBeginEditing(harness, node: fresh)
        harness.editor.commit(next: .none)

        #expect(harness.store.model.nodes[fresh] != nil)
        #expect(harness.store.model.nodes[fresh]?.title.text == "")
        #expect(harness.commits.first?.title.text == "")
    }

    // MARK: overlay geometry (SPEC §11.4)

    @Test func overlayTracksTheNodeTextBlockThroughPanAndZoom() throws {
        let harness = EditingHarness(model: sceneModel())
        let canvas = harness.canvas
        canvas.camera = Camera(origin: CGPoint(x: 100, y: 50), scale: 2)
        canvasBeginEditing(harness, node: "branch-0")

        let scene = try #require(canvas.scene)
        let node = try #require(scene.nodes["branch-0"])
        let view = try #require(harness.view)

        // The text block origin: the content rect's top-left (an auto-width
        // node hugs its text, so NodeRenderer's centering offsets are 0).
        let expected = canvas.camera.screenPoint(
            for: CGPoint(
                x: node.frame.minX + node.style.paddingWidth,
                y: node.frame.minY + node.style.paddingHeight))
        #expect(abs(view.frame.minX - expected.x) < 1.5)
        #expect(abs(view.frame.minY - expected.y) < 1.5)
        // Growth room: the full wrap width at the current zoom (F-EDT-8).
        #expect(abs(view.frame.width - node.style.maxWidth * 2) < 0.5)

        // Panning moves the overlay with the node.
        canvas.panByScreen(dx: -30, dy: 20)
        let moved = canvas.camera.screenPoint(
            for: CGPoint(
                x: node.frame.minX + node.style.paddingWidth,
                y: node.frame.minY + node.style.paddingHeight))
        #expect(abs(view.frame.minX - moved.x) < 1.5)
        #expect(abs(view.frame.minY - moved.y) < 1.5)
    }

    @Test func clicksOutsideTheNodePassThroughToTheCanvas() throws {
        let harness = EditingHarness(model: sceneModel())
        canvasBeginEditing(harness, node: "branch-0")
        let canvas = harness.canvas
        let view = try #require(harness.view)
        let scene = try #require(canvas.scene)
        let frame = try #require(scene.nodes["branch-0"]?.frame)
        let origin = canvas.camera.screenPoint(for: frame.origin)

        // Inside the node: the text view places the caret.
        #expect(view.hitTest(CGPoint(x: origin.x + 5, y: origin.y + 5)) === view)
        // Inside the overlay's growth room but outside the node: the
        // canvas gets the click (commit + select).
        #expect(view.hitTest(CGPoint(x: origin.x + 240, y: origin.y + 5)) == nil)
    }

    @Test func draftGrowsTheNodeThroughTheSharedMeasurer() throws {
        let harness = EditingHarness(model: sceneModel())
        canvasBeginEditing(harness, node: "branch-0")
        let canvas = harness.canvas
        let before = try #require(canvas.scene?.nodes["branch-0"]?.frame)

        harness.editor.insertText(" now a much longer title than before")
        let after = try #require(canvas.scene?.nodes["branch-0"]?.frame)

        #expect(after.width > before.width + 50)
        // Auto-width caps at max width, then wraps (F-EDT-8).
        #expect(after.width <= before.width + 300)
    }

    // MARK: formatting toggles (F-EDT-7)

    @Test func boldItalicUnderlineTogglesBecomeAllowListedRuns() throws {
        let harness = EditingHarness(model: sceneModel())
        canvasBeginEditing(harness, node: "branch-0")
        let view = try #require(harness.view)
        // beginEditing selects all, so the toggles hit the whole title.
        view.toggleBoldAction(nil)
        view.toggleItalicAction(nil)
        view.toggleUnderlineAction(nil)

        let title = try #require(harness.editor.currentTitle())
        #expect(title.text == "alpha")
        let run = try #require(title.runs.first)
        #expect(run.bold == true)
        #expect(run.italic == true)
        #expect(run.underline == true)
        #expect(run.range == [0, 5])

        // Toggles are all-on semantics: pressing again removes.
        view.toggleBoldAction(nil)
        let back = try #require(harness.editor.currentTitle())
        #expect(back.runs.first?.bold == nil)
        #expect(back.runs.first?.italic == true)
    }

    // MARK: canvas-level entry points

    @Test func doubleClickOnANodeBeginsEditingIt() throws {
        let harness = EditingHarness(model: sceneModel())
        let canvas = harness.canvas
        let scene = try #require(canvas.scene)
        let frame = try #require(scene.nodes["root"]?.frame)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = canvas.camera.screenPoint(for: center)

        canvas.mouseDown(with: Self.mouseEvent(at: screen, clickCount: 2))

        #expect(canvas.selection == ["root"])
        #expect(canvas.isEditing)
        #expect(canvas.editingNodeID == "root")
        // All text selected (F-EDT-2).
        let titleLength = (scene.nodes["root"]?.title.text as NSString?)?.length ?? 0
        #expect(harness.view?.selectedRange() == NSRange(0..<titleLength))
    }

    @Test func doubleClickOnEmptyCanvasAsksForAFloatingRootAtThePoint() throws {
        let harness = EditingHarness(model: sceneModel())
        let canvas = harness.canvas
        var requested: CGPoint?
        canvas.onCreateFloatingNode = { point in requested = point }

        let emptyScreen = CGPoint(x: 750, y: 550)
        canvas.mouseDown(with: Self.mouseEvent(at: emptyScreen, clickCount: 2))

        let modelPoint = try #require(requested)
        #expect(abs(modelPoint.x - canvas.camera.modelPoint(for: emptyScreen).x) < 0.001)
        #expect(abs(modelPoint.y - canvas.camera.modelPoint(for: emptyScreen).y) < 0.001)

        // A single click still rubber-bands: the host is only asked for a
        // genuine double-click (F-CAN-5).
        var secondRequest: CGPoint?
        canvas.onCreateFloatingNode = { point in secondRequest = point }
        canvas.mouseDown(with: Self.mouseEvent(at: emptyScreen, clickCount: 1))
        #expect(secondRequest == nil)
    }

    @Test func typingAPrintableCharacterOnASelectionReplacesItsText() throws {
        let harness = EditingHarness(model: sceneModel())
        let canvas = harness.canvas
        canvas.setSelection(["branch-1"])

        let event = Self.keyEventTyped("Q")
        let prefill = canvas.replaceEditText(for: event)
        #expect(prefill == "Q")
        canvas.beginEditingSelection(prefill: prefill ?? "")

        #expect(canvas.isEditing)
        #expect(harness.editor.currentTitle()?.text == "Q")
        // The caret sits after the replacement, not a select-all.
        #expect(harness.view?.selectedRange() == NSRange(location: 1, length: 0))
    }

    // MARK: event helpers

    private static func keyEvent(_ key: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    }

    private static func keyEventTyped(_ key: String) -> NSEvent {
        keyEvent(key)
    }

    /// A click at a canvas-space point (flipped), delivered in window
    /// coordinates like real events are.
    private static func mouseEvent(at canvasPoint: CGPoint, clickCount: Int) -> NSEvent {
        let windowPoint = CGPoint(x: canvasPoint.x, y: 600 - canvasPoint.y)
        return NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 0)!
    }

    private func canvasBeginEditing(_ harness: EditingHarness, node: String) {
        harness.canvas.setSelection([node])
        harness.canvas.beginEditing(nodeID: node)
    }

    private func collectedAttributeKeys(_ attributed: NSAttributedString) -> Set<NSAttributedString.Key>? {
        var keys = Set<NSAttributedString.Key>()
        var index = 0
        let length = attributed.length
        while index < length {
            var effective = NSRange(location: index, length: 0)
            let attributes = attributed.attributes(at: index, effectiveRange: &effective)
            if effective.length == 0 {
                effective.length = min(1, length - index)
            }
            keys.formUnion(attributes.keys)
            index += effective.length
        }
        return keys
    }
}

/// The host wiring mirrored headlessly: a canvas + a `MapStore` with the
/// commit handler performing ONE `editText` command (then ending the
/// coalescing session, like `DocumentWindowController`), and the draft
/// handler rebuilding the scene like `updateScene` does.
@MainActor
private final class EditingHarness {
    let canvas: CanvasView
    let store: MapStore
    let editor: NodeTextEditor
    var commits: [(id: String, title: NodeTitle, next: NodeTextEditor.PostCommitAction)] = []
    var drafts: [(id: String, title: NodeTitle)] = []

    var view: EditingTextView? { editor.textView }

    init(model: MapModel) {
        let manager = UndoManager()
        manager.groupsByEvent = false
        store = MapStore(model: model, undoManager: manager)
        canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.scene = SceneGeometry.build(
            model: store.model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        editor = canvas.nodeTextEditor

        editor.onCommit = { [unowned self] id, title, next in
            if self.store.model.nodes[id]?.title != title {
                try? self.store.perform(.editText(id: id, title: title))
            }
            // One undo step per edit session (F-DOC-2): end the typing
            // session so a later session on the same node registers anew.
            self.store.closeEditSession()
            self.commits.append((id, title, next))
        }
        editor.onDraftChange = { [unowned self] id, draft in
            self.drafts.append((id, draft))
            self.canvas.scene = SceneGeometry.build(
                model: self.store.model, variant: .light, measurer: SceneRenderer.sharedMeasurer,
                editingTitle: (id, draft))
        }
    }
}

/// The overlay editor must show the face the node was laid out with, or
/// the text changes typeface the moment editing starts.
@MainActor
struct EditorFontTests {
    @Test func theRoundedFamilyTokenGivesTheRoundedFaceInTheEditorAndTheLabelEditor() {
        for weight: CGFloat in [0, 0.23, 0.3] {
            let spec = FontSpec(size: 18, weight: weight, family: FontSpec.roundedFamily)
            #expect(NodeTextEditor.nsFont(for: spec).fontName.contains("Rounded"), "weight \(weight)")
            #expect(ConnectionLabelEditor.nsFont(for: spec).fontName.contains("Rounded"), "weight \(weight)")
            // Same face as the one the measurer uses.
            #expect(
                NodeTextEditor.nsFont(for: spec).fontName
                    == (CTFontCopyPostScriptName(spec.ctFont) as String))
        }
    }

    @Test func thePlainSystemFontIsUnchanged() {
        let font = NodeTextEditor.nsFont(for: FontSpec(size: 16, weight: 0.23))
        #expect(!font.fontName.contains("Rounded"))
        #expect(font.pointSize == 16)
    }
}
