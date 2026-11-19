import AppKit
import CoreGraphics
import MapCore
import MapRender

/// The mind-map canvas: a flipped `NSView` that renders a `CanvasScene`
/// through a camera, drawing into its standard backing layer. Pan with
/// two-finger scroll (content follows the fingers), zoom with pinch
/// (anchored at the cursor), ⌘+/⌘−/⌘0/⌘9/⌘* step, fit and zoom-to-
/// selection per F-CAN-2. Click and ⌘-click select, drag on empty canvas
/// rubber-bands (F-CAN-4).
///
/// Zoom steps are exposed as methods so the View menu can target them
/// with key equivalents (§14.1: reachable from menus); the canvas handles
/// the keys itself when it is first responder.
public final class CanvasView: NSView {
    public var scene: CanvasScene? {
        didSet {
            rebuildGrid()
            // The editing node's frame may have moved (or vanished) in
            // the rebuilt scene; the overlay follows or tears down.
            nodeTextEditor.reconcileWithScene()
            needsDisplay = true
        }
    }

    public var camera: Camera {
        didSet {
            guard camera != oldValue else { return }
            clampCameraScale()
            // Pan/zoom move the editing node on screen; the overlay is
            // re-positioned, never re-rendered (SPEC §11.4).
            nodeTextEditor.syncPosition()
            needsDisplay = true
        }
    }

    public private(set) var selection: Set<String> = []

    /// The inline editing overlay (SPEC §11.4); owns the TextKit 2 text
    /// view and the session state.
    public let nodeTextEditor = NodeTextEditor()

    /// F-CAN-5: double-click on empty canvas → the host creates a
    /// floating root at this model point and enters edit mode.
    public var onCreateFloatingNode: ((CGPoint) -> Void)?

    /// True until the host has run the first `zoomToFit` against the
    /// window's real on-screen content size (windows open at the creation
    /// frame and resize with the window frame).
    public var needsInitialFit = true

    /// Called after any selection change caused by canvas interaction.
    public var onSelectionChange: ((Set<String>) -> Void)?

    /// Called when the system appearance changes, so the host can rebuild
    /// the scene for the new variant (dark mode is part of §14.1).
    public var onEffectiveAppearanceChange: (() -> Void)?

    /// The F-CAN-2 zoom step list: ⌘+ and ⌘− snap to the next stop.
    public static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    private var grid = SpatialGrid()
    private var rubberBandStart: CGPoint?
    private var rubberBandRect: NSRect?
    private var lastRenderedVariant: ThemeVariant?

    public override init(frame frameRect: NSRect) {
        self.camera = Camera()
        super.init(frame: frameRect)
        wantsLayer = true
        nodeTextEditor.canvas = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        self.camera = Camera()
        super.init(coder: coder)
        wantsLayer = true
        nodeTextEditor.canvas = self
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// The theme variant matching this view's effective appearance.
    public var effectiveVariant: ThemeVariant {
        let names = [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua]
        let best = effectiveAppearance.bestMatch(from: names) ?? .aqua
        return best == .darkAqua ? .dark : .light
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let scene else { return }
        SceneRenderer.draw(
            scene: scene,
            camera: camera,
            selection: selection,
            selectionColor: selectionColor,
            editingNodeID: nodeTextEditor.editingNodeID,
            in: context,
            viewport: bounds.size)

        if let rubberBandRect {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            context.fill(rubberBandRect)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1)
            context.stroke(rubberBandRect)
        }
    }

    private var selectionColor: CGColor {
        NSColor.controlAccentColor.cgColor
    }

    // MARK: camera actions

    /// Pans by a screen-space delta. The canvas is flipped and follows
    /// natural scrolling: a positive delta moves the *content* with the
    /// fingers, so the camera origin moves the opposite way (the same
    /// `origin -= delta` an `NSClipView` applies).
    public func panByScreen(dx: CGFloat, dy: CGFloat) {
        camera.origin.x -= dx / camera.scale
        camera.origin.y -= dy / camera.scale
        needsDisplay = true
    }

    /// Zooms keeping the model point under `screenAnchor` fixed on screen.
    public func zoom(scale newScale: CGFloat, around screenAnchor: CGPoint) {
        let clamped = min(max(newScale, 0.1), 4)
        let anchorModel = camera.modelPoint(for: screenAnchor)
        camera.scale = clamped
        camera.origin = CGPoint(
            x: anchorModel.x - screenAnchor.x / clamped,
            y: anchorModel.y - screenAnchor.y / clamped)
        needsDisplay = true
    }

    /// Snaps to the next (or previous) F-CAN-2 zoom stop around the
    /// viewport center. Zooming in accepts the `=` character as ⌘+ (US
    /// layouts send it unshifted).
    public func zoomStep(_ direction: ZoomDirection) {
        let target: CGFloat
        switch direction {
        case .closer:
            let next = Self.zoomSteps.first { $0 > camera.scale + 0.01 } ?? Self.zoomSteps.last!
            target = next
        case .farther:
            let previous = Self.zoomSteps.last { $0 < camera.scale - 0.01 } ?? Self.zoomSteps.first!
            target = previous
        }
        zoom(scale: target, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    public enum ZoomDirection {
        case closer
        case farther
    }

    /// Zooms to the given scale around the viewport center.
    public func zoomToScale(_ target: CGFloat) {
        zoom(scale: target, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Actual size (F-CAN-2: ⌘0).
    public func zoomToActualSize() {
        zoomToScale(1)
    }

    /// Zooms so the whole scene fits the viewport with padding
    /// (F-CAN-2: ⌘9, also ⌘*).
    public func zoomToFit(padding: CGFloat = 40) {
        guard let scene, !scene.nodes.isEmpty, bounds.width > 1, bounds.height > 1 else { return }
        let content = scene.bounds.insetBy(dx: -padding, dy: -padding)
        guard content.width > 0, content.height > 0 else { return }
        let scale = min(
            bounds.width / content.width,
            bounds.height / content.height,
            4)
        camera.scale = min(max(scale, 0.1), 4)
        camera.origin = CGPoint(
            x: content.midX - bounds.midX / camera.scale,
            y: content.midY - bounds.midY / camera.scale)
        needsDisplay = true
    }

    /// Zooms so the selection fills the viewport (F-CAN-2: ⌥⌘0).
    public func zoomToSelection(padding: CGFloat = 40) {
        guard !selection.isEmpty, bounds.width > 1, bounds.height > 1 else {
            zoomToFit(padding: padding)
            return
        }
        var content: CGRect = .null
        for id in selection {
            if let node = scene?.nodes[id] {
                content = content.union(node.frame)
            }
        }
        guard !content.isNull else { return }
        content = content.insetBy(dx: -padding, dy: -padding)
        let scale = min(
            bounds.width / content.width, bounds.height / content.height, 4)
        camera.scale = min(max(scale, 0.1), 4)
        camera.origin = CGPoint(
            x: content.midX - bounds.midX / camera.scale,
            y: content.midY - bounds.midY / camera.scale)
        needsDisplay = true
    }

    private func clampCameraScale() {
        camera.scale = min(max(camera.scale, 0.1), 4)
    }

    // MARK: hit-testing

    public override func layout() {
        super.layout()
        needsDisplay = true
    }

    private func rebuildGrid() {
        grid = SpatialGrid()
        guard let scene else { return }
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
    }

    /// The scene node under a view point, if any.
    public func nodeID(at viewPoint: CGPoint) -> String? {
        grid.id(at: camera.modelPoint(for: viewPoint))
    }

    // MARK: events

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let delta = event.deltaY
            if delta != 0 {
                let anchor = convert(event.locationInWindow, from: nil)
                zoom(scale: camera.scale * pow(1.1, delta), around: anchor)
            }
            return
        }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            let lineHeight: CGFloat = 12
            dx *= lineHeight
            dy *= lineHeight
        }
        panByScreen(dx: dx, dy: dy)
    }

    public override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        zoom(scale: camera.scale * (1 + event.magnification), around: anchor)
    }

    public override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        let hasCommand = event.modifierFlags.contains(.command)
        let hasOption = event.modifierFlags.contains(.option)
        let hasShift = event.modifierFlags.contains(.shift)
        switch (characters, hasCommand, hasOption) {
        case ("+", true, false), ("=", true, false):
            zoomStep(.closer)
        case ("-", true, false):
            zoomStep(.farther)
        case ("0", true, false):
            zoomToActualSize()
        case ("9", true, false), ("*", true, false):
            zoomToFit()
        case ("0", true, true):
            zoomToSelection()
        case ("\r", _, false) where !hasShift:
            // ⏎/⌘⏎ edit the selected node (F-EDT-2); ⇧⏎ (new root) and
            // ⌥⏎ (sibling above) fall through to the host's menu actions.
            beginEditingSelection()
        case ("\u{f705}", false, false):
            // F2 (Edit Title, §6.1).
            beginEditingSelection()
        default:
            if let prefill = replaceEditText(for: event) {
                // Typing a printable character on a selected node replaces
                // its text (F-EDT-2).
                beginEditingSelection(prefill: prefill)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Any click while editing first commits the session, so the click
        // lands on the committed model (F-EDT-1: ⎋-equivalent behavior).
        if nodeTextEditor.editingNodeID != nil {
            nodeTextEditor.commit(next: .none)
        }
        // Double-click: a node edits its title (F-EDT-2); empty canvas
        // creates a floating root at the point (F-CAN-5) instead of
        // rubber-banding.
        if event.clickCount == 2 {
            if let id = nodeID(at: point) {
                selection = [id]
                onSelectionChange?(selection)
                beginEditing(nodeID: id)
                rubberBandStart = nil
                needsDisplay = true
                return
            }
            if let create = onCreateFloatingNode {
                create(camera.modelPoint(for: point))
                return
            }
        }
        if let id = nodeID(at: point) {
            if event.modifierFlags.contains(.command) {
                if selection.contains(id) {
                    selection.remove(id)
                } else {
                    selection.insert(id)
                }
            } else {
                selection = [id]
            }
            onSelectionChange?(selection)
            rubberBandStart = nil
        } else {
            rubberBandStart = point
            rubberBandRect = nil
            if !event.modifierFlags.contains(.command) {
                selection = []
                onSelectionChange?(selection)
            }
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = rubberBandStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        rubberBandRect = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            rubberBandStart = nil
            rubberBandRect = nil
            needsDisplay = true
        }
        guard let start = rubberBandStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y))
        guard rect.width > 2, rect.height > 2 else { return }
        let modelRect = CGRect(
            x: camera.modelPoint(for: rect.origin).x,
            y: camera.modelPoint(for: rect.origin).y,
            width: rect.width / camera.scale,
            height: rect.height / camera.scale)
        let hits = grid.ids(intersecting: modelRect)
        if event.modifierFlags.contains(.command) {
            selection.formUnion(hits)
        } else {
            selection = hits
        }
        onSelectionChange?(selection)
    }
}

/// First-responder actions the View menu targets, so the zoom commands
/// work even before the canvas has been clicked (§14.1: reachable from
/// menus).
extension CanvasView {
    @objc public func zoomInAction(_ sender: Any?) {
        zoomStep(.closer)
    }

    @objc public func zoomOutAction(_ sender: Any?) {
        zoomStep(.farther)
    }

    @objc public func actualSizeAction(_ sender: Any?) {
        zoomToActualSize()
    }

    @objc public func zoomToFitAction(_ sender: Any?) {
        zoomToFit()
    }

    @objc public func zoomToSelectionAction(_ sender: Any?) {
        zoomToSelection()
    }
}

/// Selection maintenance for the editing loop (F-CAN-4: the selection
/// stays valid after every model change).
extension CanvasView {
    /// Sets the selection, dropping ids that no longer exist in the
    /// scene (deleted nodes, descendants of newly folded nodes).
    public func setSelection(_ ids: Set<String>) {
        selection = ids.filter { scene?.nodes[$0] != nil }
        needsDisplay = true
        onSelectionChange?(selection)
    }

    /// Drops selection ids that fell out of the scene in a rebuild.
    public func pruneSelection() {
        let valid = selection.filter { scene?.nodes[$0] != nil }
        guard valid != selection else { return }
        selection = valid
        needsDisplay = true
        onSelectionChange?(selection)
    }

    /// True when `id` renders left of its root — its incoming branch
    /// heads left — so promote/demote mirror there (F-EDT-6).
    public func isOnLeftSide(_ id: String) -> Bool {
        scene?.branches.contains { $0.childID == id && $0.direction == .left } ?? false
    }
}
