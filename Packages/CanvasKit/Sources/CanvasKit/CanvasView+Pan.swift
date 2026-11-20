import AppKit
import CoreGraphics

/// Space-drag pan state (F-CAN-1, ADR-0033).
@MainActor
final class SpacePanState {
    /// Space is held: the next mouse-down pans instead of selecting,
    /// rubber-banding or grabbing a node.
    var armed = false
    /// The button is down in a space-started pan: drags keep panning
    /// until mouse-up, even if Space was released mid-drag.
    var dragging = false
    /// The previous drag event's view point.
    var lastPoint = CGPoint.zero
    /// A mouse-down happened while armed — the release is a pan, never
    /// the replace-edit tap (ADR-0033's tap-vs-hold rule).
    var sawMouseDown = false
}

/// Space-drag panning (SPEC §6.2, F-CAN-1, ADR-0033). Space held =
/// pan mode: open-hand cursor, a mouse drag pans the camera via
/// `panByScreen` — no selection, rubber band or node grab, even over a
/// node. Releasing Space ends it. The tap-vs-hold rule: keyDown only
/// *arms* and consumes the event; the plain-tap meaning (the F-EDT-2
/// replace-edit on a single selected node) is deferred to keyUp and
/// only fires when no mouse button went down in between, so a Space
/// down+up with no mouse activity behaves exactly as before this
/// feature existed.
extension CanvasView {
    /// True while Space is held and the next mouse-down pans.
    var isSpacePanArmed: Bool { spacePan.armed }

    // MARK: key events

    /// The arm half of ADR-0033's rule: a plain unmodified Space down
    /// (no ⌘/⌥/⌃/⇧ — ⌘ shortcuts and ⌃⌥Space Quick Entry keep their
    /// events) arms pan mode and consumes the event. Returns false when
    /// Space means something else here and the event must fall through
    /// to `keyDown`'s normal handling.
    func handleSpacePanKeyDown(_ event: NSEvent) -> Bool {
        guard isPlainSpace(event) else { return false }
        // A live node drag owns the key first (F-REL-1): Space while
        // dragging means "drop as a connection", exactly as before.
        if case .active = drag {
            _ = handleDragKey(" ", down: true)
            return true
        }
        // Never arm while another gesture owns the canvas: a pending
        // node grab (inside the 4 pt threshold), ⌘L's next-click
        // connection mode, a live connection-handle drag, or an open
        // editing overlay — while editing, the overlay's text view is
        // first responder and Space types; this guard is defense in
        // depth for direct keyDown delivery.
        guard drag == nil, pendingConnectionSource == nil, relationDrag == nil,
            !isEditing, !connectionLabelEditor.isEditing
        else { return false }
        spacePan.armed = true
        // The Node Well buttons hide while pan mode owns the canvas
        // (CanvasView+Hover.swift).
        updateAddHandles()
        window?.invalidateCursorRects(for: self)
        NSCursor.openHand.set()
        return true
    }

    /// The tap half of ADR-0033's rule, on keyUp: disarm (an ongoing
    /// pan drag finishes as a pan — the gesture isn't handed back
    /// mid-button), and when Space went down and up with no mouse
    /// activity in between, run the very replace-edit keyDown's default
    /// branch used to run on the way down — `replaceEditText(for:)` +
    /// `beginEditingSelection(prefill:)`, so a single selected node
    /// edits its title prefilled " ", and an image node Quick Looks
    /// (SPEC §5.4) — all exactly as before.
    func handleSpacePanKeyUp(_ event: NSEvent) -> Bool {
        guard isPlainSpace(event), spacePan.armed || spacePan.dragging else { return false }
        let isTap = spacePan.armed && !spacePan.sawMouseDown
        spacePan.armed = false
        spacePan.sawMouseDown = false
        if !spacePan.dragging {
            window?.invalidateCursorRects(for: self)
            NSCursor.arrow.set()
        }
        // Pan mode gave the canvas back: the Node Well buttons can
        // show again under the pointer (CanvasView+Hover.swift).
        updateAddHandles()
        if isTap, let prefill = replaceEditText(for: event) {
            beginEditingSelection(prefill: prefill)
        }
        return true
    }

    /// A bare Space with no modifier keys (⇧Space keeps the old
    /// keyDown path; ⌘/⌃⌥ combos belong to menus and shortcuts).
    private func isPlainSpace(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == " "
            && event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
    }

    // MARK: mouse events (the NSView overrides in CanvasView.swift call
    // these before any other handling)

    /// A mouse-down while armed begins a pan instead of selecting,
    /// rubber-banding or grabbing a node. Returns true when consumed.
    func handleSpacePanMouseDown(_ point: CGPoint) -> Bool {
        guard spacePan.armed else { return false }
        spacePan.sawMouseDown = true
        spacePan.dragging = true
        spacePan.lastPoint = point
        NSCursor.closedHand.set()
        return true
    }

    /// One drag step of a space pan: the camera moves by the screen
    /// delta (the content follows the cursor), at any zoom —
    /// `panByScreen` divides by the camera scale. Returns true when
    /// consumed.
    func handleSpacePanMouseDragged(_ point: CGPoint) -> Bool {
        guard spacePan.dragging else { return false }
        panByScreen(dx: point.x - spacePan.lastPoint.x, dy: point.y - spacePan.lastPoint.y)
        spacePan.lastPoint = point
        return true
    }

    /// A mouse-up ends the pan drag; with Space still held the cursor
    /// stays an open hand. Returns true when consumed.
    func handleSpacePanMouseUp(_ point: CGPoint) -> Bool {
        guard spacePan.dragging else { return false }
        spacePan.dragging = false
        spacePan.lastPoint = point
        if spacePan.armed {
            NSCursor.openHand.set()
        } else {
            window?.invalidateCursorRects(for: self)
            NSCursor.arrow.set()
        }
        // The drag gate in `addHandlesAllowed` just lifted.
        updateAddHandles()
        return true
    }
}

/// The pan-mode event overrides (the mouseDown/mouseDragged/mouseUp
/// entry points live in CanvasView.swift, which already owns them).
extension CanvasView {
    public override func keyUp(with event: NSEvent) {
        if handleSpacePanKeyUp(event) {
            return
        }
        super.keyUp(with: event)
    }

    /// The open hand everywhere while armed (closed hand while the
    /// button is down), including over nodes; the normal arrow when
    /// idle.
    public override func resetCursorRects() {
        if spacePan.armed || spacePan.dragging {
            addCursorRect(bounds, cursor: spacePan.dragging ? .closedHand : .openHand)
        } else {
            super.resetCursorRects()
        }
    }

    public override func resignFirstResponder() -> Bool {
        // Focus left the canvas mid-hold (Quick Open, Find, another
        // pane): the keyUp never arrives, so pan mode must not stick.
        if spacePan.armed || spacePan.dragging {
            spacePan.armed = false
            spacePan.dragging = false
            spacePan.sawMouseDown = false
            window?.invalidateCursorRects(for: self)
            // The pan gates lifted: re-resolve the Node Well buttons.
            updateAddHandles()
        }
        return super.resignFirstResponder()
    }
}
