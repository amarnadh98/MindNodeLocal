import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import QuartzCore

/// F-LAY-14's folded-count pill: one small capsule per **visible folded**
/// node, drawn as a vector `CAShapeLayer` plus a `CATextLayer` (an
/// interactive affordance like the selection ring — never a node
/// re-raster, never part of export). The pill sits just outside the
/// node on the side its children emerge from, carrying the hidden-
/// descendant count; the hit-test frame is exposed so `CanvasView` can
/// turn a click into ONE `setFolded` undo step through the host.
extension CanvasLayerTree {
    /// The pill's model-space frame for a folded node — outside the
    /// node's right edge when its children grow rightward, outside the
    /// left edge otherwise (the incoming branch's direction says which
    /// side the node sits on).
    static func pillFrame(node: SceneNode, growsRight: Bool) -> CGRect {
        let digits = max(1, "\(node.foldedCount ?? 0)".count)
        let width = FoldedPillMetrics.baseWidth + CGFloat(digits - 1) * 8
        let x =
            growsRight
            ? node.frame.maxX + FoldedPillMetrics.gap
            : node.frame.minX - FoldedPillMetrics.gap - width
        return CGRect(
            x: x, y: node.frame.midY - FoldedPillMetrics.height / 2,
            width: width, height: FoldedPillMetrics.height)
    }

    /// Brings the pill set in line with the visible folded nodes: adds,
    /// updates and removes capsule layers as the scene, camera and
    /// culling change. Called from `apply` and `updateCamera`.
    ///
    /// §11.8 fast path: maps without visible folded nodes (the common
    /// case, and every keystroke on one) pay only the pill-dict lookup
    /// — no branch scan, no work at all.
    func syncFoldedPills(camera: Camera, backingScale: CGFloat) {
        guard let scene else {
            removeFoldedPills()
            return
        }
        // §11.8 fast path: the scene pre-collects its folded ids — a map
        // with no folded node pays one isEmpty check per apply.
        guard !scene.foldedIDs.isEmpty else {
            if !foldedPillLayers.isEmpty {
                removeFoldedPills()
            }
            return
        }
        // The visible pill set follows the visible node layers.
        var wanted: [String: SceneNode] = [:]
        for id in scene.foldedIDs where nodeLayers[id] != nil {
            if let node = scene.nodes[id], node.foldedCount != nil {
                wanted[id] = node
            }
        }
        if wanted.isEmpty {
            if !foldedPillLayers.isEmpty {
                removeFoldedPills()
            }
            return
        }
        // One pass over the branches serves every visible pill: which
        // side each folded node's children emerge from (the incoming
        // branch's direction — a right-side child grows rightward), and
        // the incoming branch color for the pill's tint.
        var growsRight: [String: Bool] = [:]
        var incomingColor: [String: CGColor] = [:]
        for branch in scene.branches where wanted[branch.childID] != nil {
            growsRight[branch.childID] =
                branch.direction == .right || branch.direction == .down
            incomingColor[branch.childID] = branch.color
        }
        let stale = foldedPillLayers.filter { wanted[$0.key] == nil }
        for (id, pill) in stale {
            pill.removeFromSuperlayer()
            foldedPillLayers.removeValue(forKey: id)
            foldedPillFrames.removeValue(forKey: id)
        }
        for id in wanted.keys.sorted() {
            guard let node = wanted[id] else { continue }
            let frame = Self.pillFrame(node: node, growsRight: growsRight[id] ?? true)
            let pill: FoldedPillLayer
            if let existing = foldedPillLayers[id] {
                pill = existing
            } else {
                pill = FoldedPillLayer()
                foldedPillLayers[id] = pill
                content.addSublayer(pill)
                pill.zPosition = 2.2
            }
            pill.configure(
                frame: frame, count: node.foldedCount ?? 0,
                color: incomingColor[id]
                    ?? node.style.borderColor ?? node.style.fillColor
                    ?? CGColor(gray: 0.5, alpha: 1),
                screenPoint: camera.screenPoint(for: frame.origin), zoom: camera.scale,
                contentsScale: max(
                    2, Self.clampedRasterScale(backingScale: backingScale, camera: camera)))
            foldedPillFrames[id] = frame
        }
    }

    /// The folded node whose pill covers `modelPoint`, if any (a padded
    /// frame: the pill is a small target).
    public func foldedPillID(atModel modelPoint: CGPoint) -> String? {
        for (id, frame) in foldedPillFrames {
            if frame.insetBy(dx: -4, dy: -4).contains(modelPoint) {
                return id
            }
        }
        return nil
    }

    private func removeFoldedPills() {
        for pill in foldedPillLayers.values {
            pill.removeFromSuperlayer()
        }
        foldedPillLayers.removeAll()
        foldedPillFrames.removeAll()
    }
}

/// Capsule geometry (model points), deliberately nonisolated so the
/// layer class can read it from Core Animation's own call paths.
private enum FoldedPillMetrics {
    static let height: CGFloat = 16
    static let corner: CGFloat = 8
    static let gap: CGFloat = 8
    static let baseWidth: CGFloat = 22
}

/// One pill: the capsule (vector path, crisp at any zoom) plus the
/// count text riding inside it. Not actor-isolated — like the pooled
/// node layers, it only ever runs on the main thread but carries no
/// isolated state; every value `configure` needs arrives as a
/// parameter.
final class FoldedPillLayer: CALayer {
    private let capsule = CAShapeLayer()
    private let label = CATextLayer()

    override init() {
        super.init()
        isGeometryFlipped = true
        capsule.fillColor = nil
        capsule.strokeColor = CGColor(gray: 0, alpha: 0.35)
        capsule.lineWidth = 1
        label.alignmentMode = .center
        label.contentsScale = 2
        addSublayer(capsule)
        addSublayer(label)
    }

    override init(layer: Any) {
        // Core Animation's presentation-copy path.
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FoldedPillLayer is created directly, never decoded")
    }

    /// The node-layer placement contract (§11.4): model-point bounds
    /// pinned at the screen point of the model origin, scaled by the
    /// zoom — pan/zoom rewrite placement only, never a redraw.
    func configure(
        frame: CGRect, count: Int, color: CGColor,
        screenPoint: CGPoint, zoom: CGFloat, contentsScale: CGFloat
    ) {
        anchorPoint = .zero
        bounds = CGRect(origin: .zero, size: frame.size)
        position = screenPoint
        transform = CATransform3DMakeScale(zoom, zoom, 1)

        capsule.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerWidth: FoldedPillMetrics.corner, cornerHeight: FoldedPillMetrics.corner,
            transform: nil)
        capsule.fillColor = color
        capsule.strokeColor = CGColor(gray: 0, alpha: 0.25)
        capsule.lineWidth = 1 / zoom

        label.frame = CGRect(origin: .zero, size: frame.size)
        label.string = "\(count)"
        label.fontSize = 11
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.foregroundColor = CGColor(gray: 1, alpha: 1)
        // Keeps the count legible at the current zoom without waiting
        // for a settle pass.
        label.contentsScale = contentsScale
    }
}
