import AppKit
import CanvasKit
import MapRender

/// The study session's corner minimap (F-STD-4): a simplified scene —
/// node rects in their branch colors, no text — with the current card's
/// node circled. Geometry is `MinimapProjection` (the F-CAN-6 minimap's
/// own fit math), so the two views agree on what a minimap is.
@MainActor
final class SessionMinimapView: NSView {
    static let preferredSize = CGSize(width: 180, height: 128)
    private var projection: MinimapProjection?
    private var frames: [String: CGRect] = [:]
    private var highlightID: String?
    private var snapshot: NSImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    /// The scene to mirror plus the card node to highlight: caches the
    /// downscaled snapshot (rebuilt only when the scene changes) and the
    /// node frames, then draws.
    func setScene(_ scene: CanvasScene, highlight: String?) {
        frames = scene.nodes.mapValues(\.frame)
        projection = MinimapProjection.fit(sceneBounds: scene.bounds, in: bounds.size, padding: 8)
        snapshot = renderSnapshot(scene)
        highlightID = highlight
        needsDisplay = true
    }

    /// Moves the highlight to another card's node (no scene rebuild).
    func setHighlight(_ id: String?) {
        highlightID = id
        needsDisplay = true
    }

    private func renderSnapshot(_ scene: CanvasScene) -> NSImage? {
        guard let projection else { return nil }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            for node in scene.nodes.values {
                let rect = projection.rect(for: node.frame)
                context.setFillColor(node.style.fillColor ?? NSColor.controlAccentColor.cgColor)
                context.fill(rect)
            }
        }
        image.unlockFocus()
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A hairline material-ish backdrop keeps the minimap readable on
        // the theme background without a real visual-effect view.
        context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor)
        context.fill(bounds)
        snapshot?.draw(in: bounds)
        guard let projection, let highlightID, let frame = frames[highlightID] else { return }
        let rect = projection.rect(for: frame)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: rect.insetBy(dx: -3, dy: -3))
    }
}
