import AppKit
import CoreGraphics
import MapCore
import MapRender

/// The mind-map canvas: a flipped, layer-backed `NSView` that renders a
/// `CanvasScene` through a camera. Pan with two-finger scroll, zoom with
/// pinch (anchored at the cursor), ⌘+/⌘−/⌘0/⌘9 step and fit. Click and
/// ⌘-click select, drag on empty canvas rubber-bands (F-CAN-1..4).
///
/// Rendering is one `SceneRenderer` pass into the view's layer; the
/// virtualized CALayer tree with pooling and culling (SPEC §11.4) is the
/// performance pass planned with the animated-relayout slice.
public final class CanvasView: NSView {
    public var scene: CanvasScene? {
        didSet {
            rebuildGrid()
            clampCameraIntoContent()
            needsDisplay = true
        }
    }

    public var camera: Camera {
        didSet {
            guard camera != oldValue else { return }
            clampCameraScale()
            needsDisplay = true
        }
    }

    public private(set) var selection: Set<String> = []

    /// Called after any selection change caused by canvas interaction.
    public var onSelectionChange: ((Set<String>) -> Void)?

    private var grid = SpatialGrid()
    private var rubberBandStart: CGPoint?
    private var rubberBandRect: NSRect?

    public override init(frame frameRect: NSRect) {
        self.camera = Camera()
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.frame = NSRect(origin: .zero, size: frameRect.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        self.camera = Camera()
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let scene else { return }
        SceneRenderer.draw(
            scene: scene,
            camera: camera,
            selection: selection,
            selectionColor: selectionColor,
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

    public func panByScreen(dx: CGFloat, dy: CGFloat) {
        camera.origin.x += dx / camera.scale
        camera.origin.y += dy / camera.scale
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

    public func zoomToScale(_ target: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        zoom(scale: target, around: center)
    }

    /// Zooms so the whole scene fits the viewport with padding
    /// (F-CAN-2: ⌘9).
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

    private func clampCameraScale() {
        camera.scale = min(max(camera.scale, 0.1), 4)
    }

    private func clampCameraIntoContent() {
        guard let scene, !scene.nodes.isEmpty, bounds.width > 1 else { return }
        let content = scene.bounds
        let visible = camera.visibleRect(viewportSize: bounds.size)
        camera.origin.x = min(
            max(camera.origin.x, content.minX - visible.width * 0.75),
            content.maxX - visible.width * 0.25)
        camera.origin.y = min(
            max(camera.origin.y, content.minY - visible.height * 0.75),
            content.maxY - visible.height * 0.25)
    }

    // MARK: hit-testing

    public override func layout() {
        super.layout()
        layer?.frame = NSRect(origin: .zero, size: bounds.size)
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
        panByScreen(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
    }

    public override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        zoom(scale: camera.scale * (1 + event.magnification), around: anchor)
    }

    public override func keyDown(with event: NSEvent) {
        let step: CGFloat = 1.25
        switch event.charactersIgnoringModifiers {
        case "+" where event.modifierFlags.contains(.command):
            zoomToScale(camera.scale * step)
        case "-" where event.modifierFlags.contains(.command):
            zoomToScale(camera.scale / step)
        case "0" where event.modifierFlags.contains(.command):
            zoomToScale(1)
        case "9" where event.modifierFlags.contains(.command):
            zoomToFit()
        default:
            super.keyDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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
