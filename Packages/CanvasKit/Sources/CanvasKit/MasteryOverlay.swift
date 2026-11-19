import AppKit
import CoreGraphics
import Foundation
import QuartzCore

/// What the mastery overlay draws for one node (F-STD-6). The app layer
/// converts MapStudy's mastery buckets into these marks; CanvasKit only
/// draws them, so the overlay never depends on the study engine.
public enum MasteryMark {
    /// A translucent fill over the node frame — a reviewed card, tinted
    /// by its retrievability bucket.
    case tint(CGColor)
    /// A gray outline over the node frame — a never-reviewed card.
    case outline(CGColor)
    /// The aggregate ring on an ancestor of card nodes: stroked in the
    /// bucket color of the subtree's mean retrievability, the arc filled
    /// to `progress` (0…1).
    case ring(color: CGColor, progress: Double)
}

/// The F-STD-6 mastery overlay: one pooled shape layer per visible card
/// node (tint or outline) plus one ring layer per visible ancestor, all
/// riding the same content layer as the selection rings. Purely additive
/// to the render pipeline: node rasters are never touched (the budget
/// rule "no re-raster of untouched nodes"), the camera re-transforms the
/// overlay layers like every other model-space decoration, and a nil
/// marks table takes the whole overlay down.
@MainActor
public final class MasteryOverlay {
    private weak var content: CALayer?
    private var marks: [String: MasteryMark] = [:]
    private var tintLayers: [String: CAShapeLayer] = [:]
    private var ringLayers: [String: CAShapeLayer] = [:]

    /// The visible overlay's node ids (test surface).
    public var visibleNodeIDs: Set<String> { Set(tintLayers.keys) }
    /// The visible aggregate rings' node ids (test surface).
    public var visibleRingIDs: Set<String> { Set(ringLayers.keys) }

    /// Hosts the overlay's layers under the canvas content layer.
    public func attach(to content: CALayer) {
        self.content = content
    }

    /// Applies a new marks table (nil hides the overlay). Existing
    /// layers are reused; only ids that left the scene (or the table)
    /// drop out.
    public func update(_ marks: [String: MasteryMark]?, scene: CanvasScene?, camera: Camera) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let newMarks = marks ?? [:]
        self.marks = newMarks

        let stale = tintLayers.filter { newMarks[$0.key] == nil || scene?.nodes[$0.key] == nil }
        for (id, layer) in stale {
            layer.removeFromSuperlayer()
            tintLayers.removeValue(forKey: id)
        }
        for (id, mark) in newMarks {
            guard let node = scene?.nodes[id] else { continue }
            switch mark {
            case .tint, .outline:
                let layer = tintLayers[id] ?? makeTintLayer()
                tintLayers[id] = layer
                configureTint(layer, mark: mark, node: node, camera: camera)
            case .ring:
                // A ring and a tint never share a node id in practice;
                // if they did, the tint wins the dictionary slot and the
                // ring keeps its own.
                continue
            }
        }

        let staleRings = ringLayers.filter { newMarks[$0.key] == nil || scene?.nodes[$0.key] == nil }
        for (id, layer) in staleRings {
            layer.removeFromSuperlayer()
            ringLayers.removeValue(forKey: id)
        }
        for (id, mark) in newMarks {
            guard let node = scene?.nodes[id], case .ring(let color, let progress) = mark else { continue }
            let layer = ringLayers[id] ?? makeRingLayer()
            ringLayers[id] = layer
            configureRing(layer, color: color, progress: progress, node: node, camera: camera)
        }
    }

    /// Pan/zoom: re-transform every overlay layer (never a re-raster).
    public func updateCamera(camera: Camera) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let transform = CanvasLayerTree.modelSpaceTransform(for: camera)
        for (id, layer) in tintLayers {
            layer.transform = transform
            if case .outline = marks[id] {
                layer.lineWidth = Self.outlineWidth / camera.scale
            }
        }
        for layer in ringLayers.values {
            layer.transform = transform
            layer.lineWidth = Self.ringWidth / camera.scale
        }
    }

    /// Takes the whole overlay down (scene cleared / overlay off).
    public func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (_, layer) in tintLayers {
            layer.removeFromSuperlayer()
        }
        tintLayers.removeAll()
        for (_, layer) in ringLayers {
            layer.removeFromSuperlayer()
        }
        ringLayers.removeAll()
        marks = [:]
    }

    // MARK: layer construction

    /// Sits just under the selection rings (z 2) and above node rasters
    /// (z 1): the tint reads as a wash over the node, not a replacement.
    static let zPosition: CGFloat = 1.5
    static let outlineWidth: CGFloat = 2.5
    static let ringWidth: CGFloat = 3

    private func makeTintLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.zPosition = Self.zPosition
        content?.addSublayer(layer)
        return layer
    }

    private func makeRingLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.zPosition = Self.zPosition
        content?.addSublayer(layer)
        return layer
    }

    private func configureTint(_ layer: CAShapeLayer, mark: MasteryMark, node: SceneNode, camera: Camera) {
        let radius: CGFloat = node.style.shape == .underline ? 4 : min(10, node.style.cornerRadius + 3)
        switch mark {
        case .tint(let color):
            layer.fillColor = color
            layer.strokeColor = nil
            layer.path = CGPath(
                roundedRect: node.frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .outline(let color):
            layer.fillColor = nil
            layer.strokeColor = color
            layer.lineWidth = Self.outlineWidth / camera.scale
            layer.path = CGPath(
                roundedRect: node.frame.insetBy(dx: -2, dy: -2), cornerWidth: radius, cornerHeight: radius,
                transform: nil)
        case .ring:
            break
        }
        layer.transform = CanvasLayerTree.modelSpaceTransform(for: camera)
    }

    private func configureRing(
        _ layer: CAShapeLayer, color: CGColor, progress: Double, node: SceneNode, camera: Camera
    ) {
        let geometry = Self.ringGeometry(for: node.frame)
        layer.path = Self.ringPath(geometry: geometry, progress: progress)
        // Two strokes per ring would need two layers; one color carries
        // it — the arc's length IS the aggregate.
        layer.strokeColor = color
        layer.lineWidth = Self.ringWidth / camera.scale
        layer.transform = CanvasLayerTree.modelSpaceTransform(for: camera)
    }

    /// The ring sits at the node's top-right corner: small, out of the
    /// text's way, anchored where the eye lands on a branch node.
    static func ringGeometry(for frame: CGRect) -> (center: CGPoint, radius: CGFloat) {
        (center: CGPoint(x: frame.maxX, y: frame.minY), radius: 8 + frame.height * 0.08)
    }

    /// The ring's path: a full circle stroked as the track plus the
    /// progress arc drawn into the same path's outline? A shape layer
    /// strokes its whole path, so the arc alone is the layer's path —
    /// the track is implied by the arc's own color and width.
    static func ringPath(geometry: (center: CGPoint, radius: CGFloat), progress: Double) -> CGPath? {
        let path = CGMutablePath()
        let clamped = min(max(progress, 0), 1)
        path.addArc(
            center: geometry.center, radius: geometry.radius,
            startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * clamped, clockwise: false)
        return clamped == 0 ? nil : path
    }
}
