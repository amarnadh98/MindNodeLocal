import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import QuartzCore

/// A pooled relation overlay layer (F-REL-1/2/3): one raster of a
/// connection, boundary or summary brace, placed and scaled like a
/// node layer (ADR-0008's per-layer camera) — pan and zoom rewrite its
/// transform and position, never its raster; only the 120 ms post-settle
/// pass re-rasters at the new sharpness.
final class RelationVisualLayer: CALayer {
    var relationID: String
    /// The overlay the current raster was built from (nil once pooled).
    var overlay: RelationOverlay?
    /// The raster's sharpness (contentsScale), for the settle pass.
    var rasterScale: CGFloat = 1

    init(relationID: String) {
        self.relationID = relationID
        super.init()
        anchorPoint = .zero
        contentsGravity = .resize
        magnificationFilter = .linear
    }

    /// The presentation-layer copy Core Animation makes for every
    /// running animation (see `NodeVisualLayer.init(layer:)`).
    override init(layer: Any) {
        let source = layer as? RelationVisualLayer
        relationID = source?.relationID ?? ""
        overlay = source?.overlay
        rasterScale = source?.rasterScale ?? 1
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RelationVisualLayer is created directly, never decoded")
    }

    func reset(for id: String) {
        relationID = id
        overlay = nil
        rasterScale = 1
    }
}

/// Rasters one relation overlay through the shared `RelationRenderer`
/// (the same drawing path export uses, SPEC §11's single-renderer rule).
@MainActor
enum RelationRasterizer {
    static func image(
        overlay: RelationOverlay, bounds: CGRect, rasterScale: CGFloat,
        measurer: TextMeasurer, halo: CGColor
    ) -> CGImage? {
        let size = bounds.size
        guard size.width >= 0.5, size.height >= 0.5 else { return nil }
        let scale = min(max(rasterScale, 1), CanvasLayerTree.maxRasterScale)
        let width = max(1, Int((size.width * scale).rounded(.up)))
        let height = max(1, Int((size.height * scale).rounded(.up)))
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The renderer's convention: flipped, top-left origin (the
        // RelationRenderer draws in overlay coordinates, translating by
        // the bounds origin itself).
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        RelationVisuals.visual(for: overlay, measurer: measurer, halo: halo)
            .draw(measurer: measurer, in: context)
        return context.makeImage()
    }
}

/// Relation overlay realization of the virtualized tree (SPEC §11.4):
/// one pooled layer per overlay intersecting the expanded visible rect,
/// re-rastered only when a pixel-relevant input changed — split out of
/// `CanvasLayerTree` to keep the class body reviewable.
extension CanvasLayerTree {
    static let relationPoolCap = 1_024

    /// Brings the overlay layer set in line with the expanded visible
    /// rect and the current scene: recycle what left, realize what
    /// entered (from the pool), re-raster only on change.
    func realizeRelations(camera: Camera, viewport: CGSize, backingScale: CGFloat) {
        guard let scene else { return }
        let expanded = Self.expandedVisibleRect(camera: camera, viewport: viewport)

        var visible: [String: RelationOverlay] = [:]
        var order: [String] = []
        for connection in scene.connections {
            let overlay = RelationOverlay.connection(
                connection, selected: selectedConnections.contains(connection.id))
            if expanded.intersects(connection.bounds) {
                visible[connection.id] = overlay
                order.append(connection.id)
            }
        }
        for boundary in scene.boundaries where expanded.intersects(boundary.bounds) {
            visible[boundary.id] = RelationOverlay.boundary(boundary)
            order.append(boundary.id)
        }
        for summary in scene.summaries where expanded.intersects(summary.bounds) {
            visible[summary.id] = RelationOverlay.summary(summary)
            order.append(summary.id)
        }

        let left = relationLayers.filter { visible[$0.key] == nil }
        for (id, layer) in left {
            relationLayers.removeValue(forKey: id)
            recycleRelationLayer(layer)
        }
        for id in order {
            guard let overlay = visible[id] else { continue }
            if let existing = relationLayers[id] {
                configureRelationLayer(
                    existing, overlay: overlay, camera: camera, backingScale: backingScale)
            } else {
                let layer = dequeueRelationLayer(id: id)
                relationLayers[id] = layer
                content.addSublayer(layer)
                configureRelationLayer(
                    layer, overlay: overlay, camera: camera, backingScale: backingScale)
            }
        }
    }

    /// Final geometry + contents for one overlay layer: the camera per
    /// ADR-0008 (position at the screen point of the bounds origin, pure
    /// scale), then the raster, skipped when nothing pixel-relevant
    /// changed.
    func configureRelationLayer(
        _ layer: RelationVisualLayer, overlay: RelationOverlay, camera: Camera,
        backingScale: CGFloat
    ) {
        let bounds = overlay.bounds
        layer.bounds = CGRect(origin: .zero, size: bounds.size)
        layer.position = camera.screenPoint(for: bounds.origin)
        layer.transform = Self.nodeTransform(for: camera)
        layer.zPosition = overlay.zPosition
        configureRelationContents(
            layer, overlay: overlay, camera: camera, backingScale: backingScale)
    }

    /// Rasters the overlay only when its pixel-relevant inputs changed
    /// (pan and pure moves never repaint — §11.4).
    func configureRelationContents(
        _ layer: RelationVisualLayer, overlay: RelationOverlay, camera: Camera,
        backingScale: CGFloat
    ) {
        let rasterScale = Self.clampedRasterScale(backingScale: backingScale, camera: camera)
        if let old = layer.overlay {
            let sameRaster =
                RelationRasterKey.sameOverlay(old, overlay, scaleEqual: layer.rasterScale == rasterScale)
            if sameRaster {
                return
            }
        }
        layer.overlay = overlay
        layer.rasterScale = rasterScale
        layer.contentsScale = rasterScale
        layer.contents = RelationRasterizer.image(
            overlay: overlay, bounds: overlay.bounds, rasterScale: rasterScale,
            measurer: measurer, halo: relationHaloColor)
    }

    /// The selection halo color for connections (§7.2's system accent).
    var relationHaloColor: CGColor {
        NSColor.controlAccentColor.cgColor
    }

    // MARK: pool

    func dequeueRelationLayer(id: String) -> RelationVisualLayer {
        guard let layer = relationPool.popLast() else {
            allocatedRelationLayers += 1
            return RelationVisualLayer(relationID: id)
        }
        pooledRelationLayerReuses += 1
        layer.reset(for: id)
        return layer
    }

    func recycleRelationLayer(_ layer: RelationVisualLayer) {
        layer.removeFromSuperlayer()
        layer.removeAllAnimations()
        layer.contents = nil
        layer.overlay = nil
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        if relationPool.count < Self.relationPoolCap {
            relationPool.append(layer)
        }
    }

    // MARK: test seams

    func relationLayerContents(_ id: String) -> Any? { relationLayers[id]?.contents }
    func relationLayerCount() -> Int { relationLayers.count }
}
