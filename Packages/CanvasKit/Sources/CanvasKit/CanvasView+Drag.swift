import AppKit
import CoreGraphics
import MapCore
import MapRender

/// Drag lifecycle state (F-EDT-5): a mouse-down grab waiting to cross
/// the 4 pt threshold (below which it stays a click, SPEC §6.2), or the
/// live drag session.
enum DragState {
    case pending(PendingDrag)
    case active(DragSession)
}

extension CanvasView {
    /// True while a node drag (or its pending threshold) is active —
    /// the contextual bar's hide-while-dragging contract (§6.3).
    public var isDragging: Bool { drag != nil }
}

/// A mouse-down on a node, before the threshold decides click vs drag.
struct PendingDrag {
    let grabbedID: String
    let startView: CGPoint
    let startModel: CGPoint
    let optionDown: Bool
    let commandDown: Bool
    let shiftDown: Bool

    init(
        grabbedID: String,
        startView: CGPoint,
        startModel: CGPoint,
        optionDown: Bool = false,
        commandDown: Bool = false,
        shiftDown: Bool = false
    ) {
        self.grabbedID = grabbedID
        self.startView = startView
        self.startModel = startModel
        self.optionDown = optionDown
        self.commandDown = commandDown
        self.shiftDown = shiftDown
    }
}

/// The modifier state of a live drag, sampled as it changes (F-EDT-5):
/// ⌥/⌘ arrive through `flagsChanged`, D/Space/Esc through the drag's
/// key monitor.
struct DragModifiers {
    var option = false
    var command = false
    var detachKey = false
    var connectKey = false
    /// ⇧ held since the grab (F-REL-1: a shift-drag from node to node
    /// drops as a connection, not a reparent).
    var shift = false
}

/// One node drag in progress (F-EDT-5): from the threshold crossing to
/// the drop. Carries the ghost's model-space delta and the latest
/// resolved drop target for the overlay to draw.
@MainActor
final class DragSession {
    /// SPEC §6.2: motion below this stays a click.
    static let threshold: CGFloat = 4

    let grabbedID: String
    /// The topmost dragged ids, in id order; landing order is decided at
    /// the drop (stacking order under the resolved parent).
    let dragged: [String]
    let startModel: CGPoint
    var lastViewPoint: CGPoint = .zero
    var deltaModel: CGPoint = .zero
    var modifiers: DragModifiers
    var target: DropTarget = .none
    var keyMonitor: Any?
    fileprivate weak var overlay: DragOverlayView?

    init(grabbedID: String, dragged: [String], startModel: CGPoint, modifiers: DragModifiers) {
        self.grabbedID = grabbedID
        self.dragged = dragged
        self.startModel = startModel
        self.modifiers = modifiers
    }
}

/// Drag to reparent (F-EDT-5) — the interaction half; the pure target
/// resolution and command building live in DragReparent.swift. A drag is
/// one command performed by the host through `onDrop` (the view never
/// mutates the model), one undo step, and the selection stays on the
/// moved nodes.
extension CanvasView {
    // MARK: event plumbing (the NSView overrides live in CanvasView.swift)

    /// A mouse drag on a grabbed node: crosses the threshold into a drag
    /// session, or moves the live one. Returns true when consumed (the
    /// rubber band never runs while a node is grabbed).
    func handleMouseDragged(_ viewPoint: CGPoint) -> Bool {
        // F-CNT-2: an image-resize drag owns the gesture before any
        // node drag.
        if handleImageResizeDragged(to: viewPoint) {
            return true
        }
        switch drag {
        case .none:
            return false
        case .pending(let pending):
            let dx = viewPoint.x - pending.startView.x
            let dy = viewPoint.y - pending.startView.y
            guard hypot(dx, dy) >= DragSession.threshold else { return true }
            beginDrag(pending)
            updateDrag(at: viewPoint)
            return true
        case .active:
            updateDrag(at: viewPoint)
            return true
        }
    }

    /// A mouse up ends the drag (drop or cancel); a grab that never
    /// crossed the threshold was a click, and mouseDown already applied
    /// the selection. Returns true when consumed.
    func handleMouseUp(_ viewPoint: CGPoint) -> Bool {
        // F-CNT-2: committing the image resize.
        if handleImageResizeDragged(to: viewPoint, ending: true) {
            return true
        }
        switch drag {
        case .none:
            return false
        case .pending:
            endDrag()
            return true
        case .active(let session):
            finishDrag(session)
            endDrag()
            return true
        }
    }

    /// ⌥/⌘/⇧ read live through flagsChanged while dragging (F-EDT-5).
    func handleFlagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard let session = activeSession() else { return }
        session.modifiers.option = modifiers.contains(.option)
        session.modifiers.command = modifiers.contains(.command)
        session.modifiers.shift = modifiers.contains(.shift)
        session.overlay?.needsDisplay = true
    }

    /// One key event during a live drag (D detach, Space connect, Esc
    /// cancel — F-EDT-5). Returns true when consumed. Tests drive this
    /// directly; the app installs a local monitor (below).
    func handleDragKey(_ characters: String?, down: Bool) -> Bool {
        guard let session = activeSession() else { return false }
        switch characters?.lowercased() {
        case "d":
            session.modifiers.detachKey = down
            return true
        case " ":
            session.modifiers.connectKey = down
            return true
        case "\u{1b}" where down:
            cancelDrag()
            return true
        default:
            return false
        }
    }

    // MARK: session lifecycle

    private func beginDrag(_ pending: PendingDrag) {
        guard let model = dragModel, model.nodes[pending.grabbedID] != nil else {
            drag = nil
            return
        }
        // The drag carries the whole (topmost) selection when the
        // grabbed node is part of it; mouseDown already made a lone grab
        // the selection otherwise.
        let moving = selection.contains(pending.grabbedID) ? selection : [pending.grabbedID]
        let dragged = DragCommands.topmost(moving, in: model)
        guard !dragged.isEmpty else {
            drag = nil
            return
        }
        let session = DragSession(
            grabbedID: pending.grabbedID,
            dragged: dragged,
            startModel: pending.startModel,
            modifiers: DragModifiers(
                option: pending.optionDown, command: pending.commandDown,
                shift: pending.shiftDown))
        drag = .active(session)
        installKeyMonitor(into: session)
        addOverlay(for: session)
    }

    private func updateDrag(at viewPoint: CGPoint) {
        guard let session = activeSession(), let model = dragModel, let scene else { return }
        session.lastViewPoint = viewPoint
        // Panning changes the model point under the cursor, so the ghost
        // delta and the target are resolved after it.
        autoScrollIfNeeded(viewPoint)
        let modelPoint = camera.modelPoint(for: viewPoint)
        session.deltaModel = CGPoint(
            x: modelPoint.x - session.startModel.x,
            y: modelPoint.y - session.startModel.y)
        session.target = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: Set(session.dragged), point: modelPoint)
        session.overlay?.needsDisplay = true
    }

    private func finishDrag(_ session: DragSession) {
        guard let model = dragModel, let scene else { return }
        // The last drag event resolved the target at this same cursor
        // position; re-resolving here would auto-scroll once more and
        // slide the model point off the hovered target.
        guard let command = dropCommand(session, model: model, scene: scene),
            !DragCommands.isNoOp(command, in: model)
        else { return }
        onDrop?(command, Set(session.dragged))
    }

    private func endDrag() {
        if case .active(let session) = drag {
            if let monitor = session.keyMonitor {
                NSEvent.removeMonitor(monitor)
            }
            session.overlay?.removeFromSuperview()
        }
        drag = nil
    }

    /// Esc cancels the drag: no command, nothing performed.
    private func cancelDrag() {
        endDrag()
        needsDisplay = true
    }

    private func activeSession() -> DragSession? {
        if case .active(let session) = drag { return session }
        return nil
    }

    // MARK: drop resolution

    /// The one command this drop performs, per the live modifier state
    /// (F-EDT-5 + F-REL-1 + ADR-0032): Space or ⇧ drops as a connection
    /// to the hovered target, ⌥ free-positions via `setOffset`, D
    /// detaches into new roots, and no modifier reparents — except that
    /// a plain drag of ROOTS moves the map (ADR-0032), keeping the
    /// reparent only over another node's frame.
    private func dropCommand(
        _ session: DragSession, model: MapModel, scene: CanvasScene
    ) -> MapCommand? {
        if session.modifiers.connectKey || session.modifiers.shift {
            // F-REL-1: a connection drop — nil when nothing valid is
            // hovered (the host performs nothing, no phantom undo).
            return DragCommands.connect(
                model: model, from: session.grabbedID, target: session.target)
        }
        if session.modifiers.detachKey {
            return DragCommands.detach(model: model, dragged: session.dragged)
        }
        if session.modifiers.option {
            return DragCommands.offsets(
                model: model, dragged: session.dragged, delta: session.deltaModel)
        }
        // ⌘ (keep the node's own style): a no-op today — the branch
        // palette is positional (ADR-0004), so a moved node already
        // keeps its own style; revisit when per-node style adoption
        // lands (F-STY-2/F-STY-3).
        switch session.target {
        case .reparent(let parent, let slot):
            let ordered = DragCommands.orderedByStacking(session.dragged, in: scene, parent: parent)
            return DragCommands.reparent(model: model, dragged: ordered, parent: parent, slot: slot)
        case .insertBetween(let parent, let index, _):
            // ADR-0032: a plain drag of roots never inserts between
            // siblings — a corridor (like empty canvas) is a map move.
            if DragCommands.movesRoots(session.dragged, in: model) {
                return DragCommands.offsets(
                    model: model, dragged: session.dragged, delta: session.deltaModel)
            }
            let ordered = DragCommands.orderedByStacking(session.dragged, in: scene, parent: parent)
            return DragCommands.reparent(model: model, dragged: ordered, parent: parent, slot: index)
        case .newRoot, .none:
            // ADR-0032: a plain drag of the ROOT moves the whole map —
            // MindNode's contract. Roots carry no absolute position,
            // so the drag delta becomes the root's manual `offset`
            // (the same F-LAY-11 mechanism the ⌥ free-position drop
            // uses) and every descendant travels along. Empty canvas
            // still never tears a child out of its branch (D is the
            // deliberate way to detach); dropping a root ON another
            // node's frame keeps the reparent above.
            guard DragCommands.movesRoots(session.dragged, in: model) else { return nil }
            return DragCommands.offsets(
                model: model, dragged: session.dragged, delta: session.deltaModel)
        }
    }

    // MARK: camera auto-scroll

    /// The camera auto-scrolls while the cursor drags near the viewport
    /// edge (F-EDT-5): a fixed nudge per drag event toward the edge.
    private func autoScrollIfNeeded(_ viewPoint: CGPoint) {
        let margin: CGFloat = 28
        let step: CGFloat = 14
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if viewPoint.x < margin {
            dx = step
        } else if viewPoint.x > bounds.width - margin {
            dx = -step
        }
        if viewPoint.y < margin {
            dy = step
        } else if viewPoint.y > bounds.height - margin {
            dy = -step
        }
        guard dx != 0 || dy != 0 else { return }
        panByScreen(dx: dx, dy: dy)
    }

    // MARK: keys while dragging

    /// While the drag is live, a local key monitor reads D / Space / Esc
    /// without touching the responder chain's key handling. Skipped
    /// headless (no window): tests drive `handleDragKey` directly.
    private func installKeyMonitor(into session: DragSession) {
        guard window != nil else { return }
        session.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            guard let self else { return event }
            let consumed = self.handleDragKey(
                event.charactersIgnoringModifiers, down: event.type == .keyDown)
            return consumed ? nil : event
        }
    }

    // MARK: feedback overlay

    private func addOverlay(for session: DragSession) {
        let overlay = DragOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.render = { [weak self] context in
            self?.drawDragOverlay(in: context)
        }
        addSubview(overlay)
        session.overlay = overlay
    }

    /// The drag feedback (F-EDT-5): (a) the hovered drop parent
    /// highlights, (b) the landing slot draws as an insertion line, and
    /// (c) a translucent ghost of the dragged nodes follows the cursor.
    private func drawDragOverlay(in context: CGContext) {
        guard let session = activeSession(), let scene else { return }
        let accent = NSColor.controlAccentColor.cgColor

        context.saveGState()
        context.scaleBy(x: camera.scale, y: camera.scale)
        context.translateBy(x: -camera.origin.x, y: -camera.origin.y)

        if case .reparent(let parent, let index) = session.target,
            let node = scene.nodes[parent]
        {
            let ring = node.frame.insetBy(dx: -3, dy: -3)
            let radius: CGFloat =
                node.style.shape == .underline ? 4 : min(10, node.style.cornerRadius + 3)
            let path = CGPath(
                roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.setStrokeColor(accent)
            context.setLineWidth(2.5 / camera.scale)
            context.addPath(path)
            context.strokePath()
            if let model = dragModel,
                let line = DropTargetResolver.slotLine(
                    model: model, scene: scene, parent: parent, index: index,
                    dragged: Set(session.dragged))
            {
                stroke(line, in: context, color: accent)
            }
        }
        // ADR-0032: an all-roots drag never inserts between siblings
        // (the corridor drop moves the map), so no insertion line
        // misleads there.
        let rootMove = dragModel.map { DragCommands.movesRoots(session.dragged, in: $0) } ?? false
        if case .insertBetween(_, _, let line) = session.target, !rootMove {
            stroke(line, in: context, color: accent)
        }

        context.saveGState()
        context.setAlpha(0.5)
        for id in session.dragged {
            guard let node = scene.nodes[id] else { continue }
            NodeRenderer.draw(
                style: node.style,
                title: node.title,
                measurer: SceneRenderer.sharedMeasurer,
                in: context,
                frame: node.frame.offsetBy(dx: session.deltaModel.x, dy: session.deltaModel.y))
        }
        context.restoreGState()
        context.restoreGState()
    }

    private func stroke(_ line: DropLine, in context: CGContext, color: CGColor) {
        context.setStrokeColor(color)
        context.setLineWidth(2 / camera.scale)
        context.setLineCap(.round)
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.strokePath()
    }
}

/// The transparent, flipped subview above the canvas that draws the drag
/// feedback. It never intercepts events.
@MainActor
private final class DragOverlayView: NSView {
    var render: ((CGContext) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        render?(context)
    }

    override func hitTest(_ aPoint: NSPoint) -> NSView? { nil }
}
