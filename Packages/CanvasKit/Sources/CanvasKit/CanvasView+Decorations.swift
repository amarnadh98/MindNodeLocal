import AppKit
import CoreGraphics
import MapCore
import MapRender

/// One interactive region of a node's decorations, in view space.
public enum DecorationHit: Equatable, Sendable {
    /// The task checkbox (F-TSK-1): click toggles done.
    case checkbox(id: String)
    /// The progress ring (F-TSK-2): click completes all leaf tasks,
    /// ⌥-click reopens all.
    case progressRing(id: String)
    /// The note badge (F-CNT-1): click opens the note popover.
    case noteBadge(id: String)
    /// The link badge (F-CNT-4): click opens the link.
    case linkBadge(id: String)
}

/// F-TAG-2 / F-TSK-5 highlight mode: pure view state (never a model
/// mutation, never undoable). Non-matching nodes dim to 25%; Esc
/// exits.
public enum HighlightMode: Equatable, Sendable {
    /// Only nodes carrying one of these tags stay lit.
    case tags(Set<String>)
    /// Only task nodes stay lit.
    case tasks
}

/// The decorations surface of the canvas (M3): hit-testing the
/// checkbox / progress ring / note / link regions the shared renderer
/// drew (same `NodeDecorationLayout`), hover tooltips for the ring
/// and the note preview, and the highlight-mode dimming. All mutations
/// route to the host's closures — the view never touches the model
/// (SPEC §11.3).
extension CanvasView {
    /// Click on a checkbox: toggles the task's done state (one
    /// `setTaskDone` via the host).
    public var onToggleTaskDone: ((String) -> Void)? {
        get { decorationActions.onToggleTaskDone }
        set { decorationActions.onToggleTaskDone = newValue }
    }

    /// Click on a progress ring: `done` follows the ⌥ modifier
    /// (⌥ = reopen all, F-TSK-2).
    public var onSetLeafTasksDone: ((String, Bool) -> Void)? {
        get { decorationActions.onSetLeafTasksDone }
        set { decorationActions.onSetLeafTasksDone = newValue }
    }

    /// Click on the note badge: open the note popover (⇧⌘K's action).
    public var onOpenNote: ((String) -> Void)? {
        get { decorationActions.onOpenNote }
        set { decorationActions.onOpenNote = newValue }
    }

    /// Click on the link badge (or ⌥⌘K): open the link (NSWorkspace;
    /// `x-arbor://` routes to the host).
    public var onOpenLink: ((String) -> Void)? {
        get { decorationActions.onOpenLink }
        set { decorationActions.onOpenLink = newValue }
    }

    /// F-TAG-2 / F-TSK-5: the active highlight mode (view state).
    public var highlight: HighlightMode? {
        get { decorationActions.highlight }
        set {
            guard decorationActions.highlight != newValue else { return }
            decorationActions.highlight = newValue
            applyScene(animated: false)
            needsDisplay = true
        }
    }

    /// True when a highlight mode dimmed anything — and Esc's job to
    /// clear (returns whether this call exited one).
    public func exitHighlightIfActive() -> Bool {
        guard highlight != nil else { return false }
        highlight = nil
        return true
    }

    // MARK: hit-testing

    /// The decoration region under a view point, if any. Pure over the
    /// current scene + camera: the same layout the renderer drew.
    public func decorationHit(at viewPoint: CGPoint) -> DecorationHit? {
        guard let scene, let node = nodeID(at: viewPoint).flatMap({ scene.nodes[$0] }),
            let decorations = node.decorations, !decorations.isEmpty
        else { return nil }
        let modelPoint = camera.modelPoint(for: viewPoint)
        let local = CGPoint(
            x: modelPoint.x - node.frame.minX,
            y: modelPoint.y - node.frame.minY)
        let layout = NodeRenderer.decorationLayout(
            style: node.style, decorations: decorations, frame: CGRect(origin: .zero, size: node.frame.size))
        if decorations.task != nil, let rect = layout.leadingRect, rect.contains(local) {
            switch decorations.task {
            case .checkbox:
                return .checkbox(id: node.id)
            case .progress:
                return .progressRing(id: node.id)
            case nil:
                break
            }
        }
        if decorations.hasNote, let rect = layout.noteBadgeRect, rect.contains(local) {
            return .noteBadge(id: node.id)
        }
        if decorations.linkURL != nil, let rect = layout.linkBadgeRect, rect.contains(local) {
            return .linkBadge(id: node.id)
        }
        return nil
    }

    /// The hover text for the point: the ring's "7 of 12 · 58%"
    /// (F-TSK-2) or the note's 3-line preview (F-CNT-1).
    public func decorationHoverText(at viewPoint: CGPoint) -> String? {
        guard let scene, let hit = decorationHit(at: viewPoint) else { return nil }
        switch hit {
        case .progressRing(let id):
            guard let decorations = scene.nodes[id]?.decorations,
                case .progress(let completed, let total)? = decorations.task
            else { return nil }
            return TaskRatio(completed: completed, total: total).tooltip
        case .noteBadge(let id):
            return Self.notePreview(of: id, in: dragModel)
        case .checkbox, .linkBadge:
            return nil
        }
    }

    /// The note's first three non-empty lines (F-CNT-1's hover
    /// preview). Pure; also the headless test surface.
    public static func notePreview(of id: String, in model: MapModel?) -> String? {
        guard let note = model?.nodes[id]?.note else { return nil }
        let lines = note.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.prefix(3).joined(separator: "\n")
    }

    /// The node's scaled frame in view space — popover/sheet anchor for
    /// the content UI (⇧⌘K note, ⌥⌘T tags).
    public func viewRect(of id: String) -> NSRect? {
        guard let node = scene?.nodes[id] else { return nil }
        let origin = camera.screenPoint(for: node.frame.origin)
        return NSRect(
            origin: origin,
            size: CGSize(
                width: node.frame.width * camera.scale,
                height: node.frame.height * camera.scale))
    }

    // MARK: event routing

    /// Called from `mouseDown` before generic node selection: a
    /// decoration click acts on its node without starting a drag.
    func handleDecorationClick(at viewPoint: CGPoint, with event: NSEvent) -> Bool {
        guard let hit = decorationHit(at: viewPoint) else { return false }
        let optionDown = event.modifierFlags.contains(.option)
        switch hit {
        case .checkbox(let id):
            setSelection([id])
            onToggleTaskDone?(id)
        case .progressRing(let id):
            setSelection([id])
            onSetLeafTasksDone?(id, !optionDown)
        case .noteBadge(let id):
            setSelection([id])
            onOpenNote?(id)
        case .linkBadge(let id):
            setSelection([id])
            onOpenLink?(id)
        }
        return true
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        toolTip = decorationHoverText(at: point)
    }

    public override func mouseExited(with event: NSEvent) {
        toolTip = nil
        super.mouseExited(with: event)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                    owner: self, userInfo: nil))
        }
    }
}

/// The closures + highlight state the decoration surface forwards; in a
/// class box so the computed properties above stay clean.
@MainActor
final class DecorationActions {
    var onToggleTaskDone: ((String) -> Void)?
    var onSetLeafTasksDone: ((String, Bool) -> Void)?
    var onOpenNote: ((String) -> Void)?
    var onOpenLink: ((String) -> Void)?
    var highlight: HighlightMode?
}
