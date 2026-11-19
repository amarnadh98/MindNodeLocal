import AppKit
import CoreGraphics
import MapCore

/// The scene→minimap fit transform (F-CAN-6): the mapping from model
/// space to minimap-local points (flipped, y-down — the same convention
/// as the canvas). Pure math, so every geometry question the view
/// answers — where a click lands, where the viewport rect strobes, when
/// the map fits — is headless-testable without a window.
public struct MinimapProjection: Equatable, Sendable {
    /// The model-space bounds being mapped.
    public let sceneBounds: CGRect
    /// The minimap's own size, in points.
    public let minimapSize: CGSize
    /// Minimap points per model point.
    public let scale: CGFloat

    /// Scales `sceneBounds` to fit (letterboxed, never stretched) inside
    /// `minimapSize` minus `padding` on every side. Nil for an empty
    /// scene or a minimap too small to pad — the view shows nothing then.
    public static func fit(
        sceneBounds: CGRect, in minimapSize: CGSize, padding: CGFloat
    ) -> MinimapProjection? {
        guard
            !sceneBounds.isNull,
            sceneBounds.width > 0,
            sceneBounds.height > 0,
            minimapSize.width > padding * 2,
            minimapSize.height > padding * 2
        else { return nil }
        let scale = min(
            (minimapSize.width - padding * 2) / sceneBounds.width,
            (minimapSize.height - padding * 2) / sceneBounds.height)
        guard scale > 0, scale.isFinite else { return nil }
        return MinimapProjection(sceneBounds: sceneBounds, minimapSize: minimapSize, scale: scale)
    }

    /// A model point → minimap-local point. The scene's centre lands on
    /// the minimap's centre.
    public func point(for model: CGPoint) -> CGPoint {
        CGPoint(
            x: (model.x - sceneBounds.midX) * scale + minimapSize.width / 2,
            y: (model.y - sceneBounds.midY) * scale + minimapSize.height / 2)
    }

    /// The inverse of `point(for:)`.
    public func modelPoint(for point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - minimapSize.width / 2) / scale + sceneBounds.midX,
            y: (point.y - minimapSize.height / 2) / scale + sceneBounds.midY)
    }

    /// A model rect → minimap-local rect. Unclamped: the viewport rect
    /// can extend past the scene (and past the minimap); the view clips.
    public func rect(for modelRect: CGRect) -> CGRect {
        CGRect(
            origin: point(for: modelRect.origin),
            size: CGSize(width: modelRect.width * scale, height: modelRect.height * scale))
    }
}

/// Minimap camera math and F-CAN-6's auto-hide predicate — pure, for
/// headless tests.
public enum MinimapGeometry {
    /// The camera that puts `model` at the viewport's centre, keeping the
    /// zoom: a click or drag in the minimap pans the canvas to here.
    public static func camera(
        centeringOn model: CGPoint, scale: CGFloat, viewportSize: CGSize
    ) -> Camera {
        Camera(
            origin: CGPoint(
                x: model.x - viewportSize.width / (2 * scale),
                y: model.y - viewportSize.height / (2 * scale)),
            scale: scale)
    }

    /// F-CAN-6's auto-hide rule: the minimap hides when the whole map
    /// already fits in the viewport. An empty scene or viewport counts as
    /// fitting (there is nothing to show). `tolerance` widens the visible
    /// rect a little so a map that only just fits doesn't strobe between
    /// pan and auto-hide.
    public static func mapFitsViewport(
        camera: Camera,
        viewportSize: CGSize,
        sceneBounds: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        guard !sceneBounds.isNull, viewportSize.width > 1, viewportSize.height > 1 else {
            return true
        }
        return camera.visibleRect(viewportSize: viewportSize)
            .insetBy(dx: -tolerance, dy: -tolerance)
            .contains(sceneBounds)
    }
}

/// F-CAN-6: the minimap, anchored bottom-right of the canvas. Shows a
/// cached, simplified image of the scene — node rects in their branch
/// colours, no text — plus the live viewport rect.
///
/// Drawing stays cheap: the downscaled scene image is re-rendered only
/// when the scene (or the view's own size/backing) changes; camera moves
/// merely blit the cached image and re-stroke the viewport rect.
///
/// The view never touches the canvas: a click, drag or VoiceOver press
/// computes the camera that centres the clicked model point and emits it
/// through `onCameraChange`; the host assigns it to its canvas.
///
/// Light/dark: the host rebuilds the scene per appearance, so the
/// snapshot follows through `scene`; the material adapts on its own.
/// Reduce Transparency swaps the material for a solid window background.
///
/// VoiceOver: a standalone element labelled "Minimap", one press away
/// from centring the view — deliberately NOT one of the canvas's node
/// rows (the canvas's accessibility children are the rows; this view is
/// a sibling outside that hierarchy, SPEC §11.6).
public final class MinimapView: NSView {
    /// The overlay's footprint in the canvas, in points.
    public static let defaultSize = CGSize(width: 180, height: 128)
    /// Distance kept from the canvas's bottom-right corner.
    public static let canvasMargin: CGFloat = 12
    /// Whitespace around the fitted scene inside the minimap.
    static let contentPadding: CGFloat = 8

    /// The scene to mirror; synced by the host after every build. Its
    /// `didSet` re-renders the downscaled image — the only render path
    /// besides a size/appearance change.
    public var scene: CanvasScene? {
        didSet {
            projection = scene.flatMap {
                MinimapProjection.fit(sceneBounds: $0.bounds, in: bounds.size, padding: Self.contentPadding)
            }
            rebuildSnapshot()
            updateVisibility()
            needsDisplay = true
        }
    }

    /// The canvas camera, synced by the host on every move. Cheap: only
    /// the viewport rect re-strokes.
    public var camera = Camera() {
        didSet {
            guard camera != oldValue else { return }
            updateVisibility()
            needsDisplay = true
        }
    }

    /// The canvas's visible size, synced from the superview.
    public internal(set) var viewportSize = CGSize.zero {
        didSet {
            guard viewportSize != oldValue else { return }
            updateVisibility()
            needsDisplay = true
        }
    }

    /// The user's visibility preference (⌥⌘M, persisted by the host in
    /// UserDefaults). Effective visibility is `preferredVisible` AND the
    /// auto-hide rule (the minimap hides while the whole map fits).
    public var preferredVisible = true {
        didSet {
            guard preferredVisible != oldValue else { return }
            updateVisibility()
        }
    }

    /// Emits the camera the canvas should adopt for a minimap pan. The
    /// view stays model-clean (SPEC §11.3 — the host owns the camera).
    public var onCameraChange: ((Camera) -> Void)?

    /// The current scene→minimap transform (test seam; nil with no
    /// fittable scene).
    private(set) var projection: MinimapProjection?

    /// The Liquid Glass background; hidden under Reduce Transparency,
    /// where `draw` paints a solid window background instead.
    let effectView = NSVisualEffectView()

    /// Notification center for accessibility-display changes, stored so
    /// the nonisolated `deinit` can unsubscribe without touching
    /// MainActor state.
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter

    /// The downscaled scene image — re-rendered only on scene, size,
    /// backing-scale or appearance changes.
    private(set) var sceneImage: NSImage?
    private var snapshotSize = CGSize.zero
    private var snapshotBacking: CGFloat = 0
    /// Counts snapshot rebuilds — the test seam for "camera moves must
    /// not re-render the scene".
    private(set) var snapshotRebuildCount = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMinimapChrome()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMinimapChrome()
    }

    deinit {
        workspaceNotifications.removeObserver(self)
    }

    /// Same orientation as the canvas (y-down), so the projection's
    /// points map straight onto drawing coordinates.
    public override var isFlipped: Bool { true }

    private func setupMinimapChrome() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 8
        effectView.layer?.masksToBounds = true
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)

        workspaceNotifications.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        refreshReduceTransparencyFallback()
    }

    /// Reduce Transparency (§14.1): the material becomes a solid fill.
    @objc private func accessibilityDisplayOptionsChanged() {
        refreshReduceTransparencyFallback()
    }

    private func refreshReduceTransparencyFallback() {
        effectView.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        needsDisplay = true
    }

    // MARK: geometry upkeep

    public override func layout() {
        super.layout()
        refreshGeometry()
    }

    public override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        syncViewportFromSuperview()
        refreshGeometry()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncViewportFromSuperview()
        refreshGeometry()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The hairline border is a dynamic color the layer can't track.
        layer?.borderColor = NSColor.separatorColor.cgColor
        // The host rebuilds the scene for the new variant; re-render
        // ours in case the appearance event arrived first.
        refreshGeometry()
    }

    private func syncViewportFromSuperview() {
        viewportSize = superview?.bounds.size ?? .zero
    }

    /// Re-fits the projection and re-renders the snapshot when the
    /// minimap's own size or backing scale changed; camera moves never
    /// come through here (their cost is one rect stroke).
    private func refreshGeometry() {
        let backing = window?.backingScaleFactor ?? 2
        if bounds.size != snapshotSize || backing != snapshotBacking {
            projection = scene.flatMap {
                MinimapProjection.fit(sceneBounds: $0.bounds, in: bounds.size, padding: Self.contentPadding)
            }
            rebuildSnapshot()
        }
        updateVisibility()
    }

    /// F-CAN-6's auto-hide: hidden when the user turned it off, or while
    /// the whole map already fits the viewport.
    func updateVisibility() {
        let fits = MinimapGeometry.mapFitsViewport(
            camera: camera, viewportSize: viewportSize, sceneBounds: scene?.bounds ?? .null)
        isHidden = !preferredVisible || fits
    }

    /// Renders the simplified scene (node rects in their branch colours,
    /// no text — F-CAN-6) into the cached image. The bitmap uses the
    /// projection's y-down coordinates directly, and the blit goes
    /// through `NSImage.draw(in:respectFlipped:)`, which lands it upright
    /// in this flipped view.
    private func rebuildSnapshot() {
        sceneImage = nil
        snapshotRebuildCount += 1
        guard
            let scene,
            let projection,
            bounds.width > 4,
            bounds.height > 4,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }
        let backing = window?.backingScaleFactor ?? 2
        let pixelsWide = Int((bounds.width * backing).rounded())
        let pixelsHigh = Int((bounds.height * backing).rounded())
        guard
            pixelsWide > 8,
            pixelsHigh > 8,
            let bitmap = CGContext(
                data: nil,
                width: pixelsWide,
                height: pixelsHigh,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        bitmap.scaleBy(x: backing, y: backing)

        for node in scene.nodes.values {
            let rect = projection.rect(for: node.frame)
            guard rect.width >= 0.5, rect.height >= 0.5 else { continue }
            // Filled levels use their fill; underline levels have no
            // fill and show their branch colour.
            guard let color = node.style.fillColor ?? node.style.borderColor else { continue }
            bitmap.setFillColor(color)
            let radius = min(
                min(rect.width, rect.height) / 2, node.style.cornerRadius * projection.scale)
            bitmap.addPath(
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            bitmap.fillPath()
        }

        if let image = bitmap.makeImage() {
            sceneImage = NSImage(cgImage: image, size: bounds.size)
        }
        snapshotSize = bounds.size
        snapshotBacking = backing
    }

    // MARK: drawing

    public override func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Reduce Transparency fallback: the material is hidden, so paint
        // a solid window background instead.
        if effectView.isHidden {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(bounds)
        }
        guard let sceneImage, let projection else { return }
        context.saveGState()
        context.clip(to: bounds)
        sceneImage.draw(
            in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
        if viewportSize.width > 1, viewportSize.height > 1 {
            // The viewport rect is the only thing camera moves re-draw.
            let visible = projection.rect(for: camera.visibleRect(viewportSize: viewportSize))
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor)
            context.fill(visible)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.stroke(visible)
        }
        context.restoreGState()
    }

    // MARK: pan (F-CAN-6: click or drag in the minimap pans the canvas)

    public override func mouseDown(with event: NSEvent) {
        panCamera(to: convert(event.locationInWindow, from: nil))
    }

    public override func mouseDragged(with event: NSEvent) {
        panCamera(to: convert(event.locationInWindow, from: nil))
    }

    private func panCamera(to point: NSPoint) {
        guard let camera = camera(forMinimapPoint: point) else { return }
        onCameraChange?(camera)
    }

    /// The camera that puts the minimap point under the cursor at the
    /// viewport centre, keeping the zoom. Package-internal for tests; the
    /// mouse handlers and the VoiceOver press go through it.
    func camera(forMinimapPoint point: NSPoint) -> Camera? {
        guard
            let projection,
            viewportSize.width > 1,
            viewportSize.height > 1,
            camera.scale > 0
        else { return nil }
        let model = projection.modelPoint(for: point)
        return MinimapGeometry.camera(
            centeringOn: model, scale: camera.scale, viewportSize: viewportSize)
    }

    // MARK: accessibility (SPEC §11.6)

    /// A standalone VoiceOver element — a sibling of the canvas's node
    /// rows, never inside that hierarchy.
    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .button }

    public override func accessibilityLabel() -> String? { "Minimap" }

    public override func accessibilityHelp() -> String? {
        "Shows the whole map. Press to centre the view; click or drag to pan."
    }

    /// VoiceOver's press centres the camera on the map (the projection's
    /// centre is the scene's centre).
    public override func accessibilityPerformPress() -> Bool {
        guard
            let camera = camera(forMinimapPoint: CGPoint(x: bounds.midX, y: bounds.midY))
        else { return false }
        onCameraChange?(camera)
        return true
    }
}
