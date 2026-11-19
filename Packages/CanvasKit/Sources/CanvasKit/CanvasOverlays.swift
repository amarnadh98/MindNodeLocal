import AppKit
import CoreGraphics
import Foundation
import MapCore
import QuartzCore

/// The F-FOC overlay surface of the canvas: find-highlight rings
/// (F-FOC-3 — a ring layer per match, never a re-raster of the nodes)
/// and the Focus/Zen dimming (F-FOC-1/2 — a plain opacity write per
/// layer, again never a re-raster). One object owns the state so the
/// hooks inside `CanvasView` itself stay one-liners.
///
/// Rings live as direct children of the layer tree's root, in model
/// space with the camera transform (the same geometry the selection
/// rings use inside `content`), one level above the whole content
/// subtree and below the rubber band. Dimming writes `opacity` on the
/// pooled node layers and branch shape layers; it is re-applied after
/// every scene application and camera change because those can realize
/// fresh layers at full opacity.
@MainActor
public final class CanvasOverlays {
    /// SPEC F-FOC-1: everything outside the focus set dims to 15%.
    public static let dimmedOpacity: Float = 0.15
    static let matchRingName = "arbor-find-ring"
    static let currentRingName = "arbor-find-current-ring"
    private static let fadeDuration: CFTimeInterval = 0.2

    /// The ids that stay fully opaque; nil when nothing is dimmed.
    private var dimmingIDs: Set<String>?
    private var matchRings: [String: CAShapeLayer] = [:]
    private var currentRing: CAShapeLayer?  // MARK: state (host + test introspection)

    /// True while Focus or Zen dims everything outside its set.
    public var isDimmingActive: Bool { dimmingIDs != nil }

    /// The ids currently kept at full opacity, or nil when not dimming.
    public var activeDimmingIDs: Set<String>? { dimmingIDs }

    /// The node ids with a find-highlight ring.
    public var findHighlightedIDs: Set<String> { Set(matchRings.keys) }

    /// The emphasized (current-match) node id, if any.
    public var currentHighlightID: String?

    // MARK: dimming (F-FOC-1/2)

    /// Dims every node and branch layer outside `focusIDs` to 15%
    /// opacity (an opacity write per layer — SPEC §11.4's invariant:
    /// no re-raster). Re-applying with the same set is cheap and is
    /// what the scene/camera sync paths do.
    public func applyDimming(_ canvas: CanvasView, focusIDs: Set<String>, animated: Bool) {
        dimmingIDs = focusIDs
        writeLayerOpacities(canvas, animated: animated && !reduceMotion)
    }

    /// Lifts the dimming: every layer back at full opacity.
    public func clearDimming(_ canvas: CanvasView, animated: Bool) {
        guard dimmingIDs != nil else { return }
        dimmingIDs = nil
        CATransaction.begin()
        CATransaction.setDisableActions(!(animated && !reduceMotion))
        if animated && !reduceMotion {
            CATransaction.setAnimationDuration(Self.fadeDuration)
        }
        for layer in canvas.layerTree.nodeLayers.values {
            layer.opacity = 1
        }
        for layer in canvas.layerTree.branchLayers.values {
            layer.opacity = 1
        }
        CATransaction.commit()
    }

    private func writeLayerOpacities(_ canvas: CanvasView, animated: Bool) {
        guard let dimmingIDs else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(Self.fadeDuration)
        }
        for (id, layer) in canvas.layerTree.nodeLayers {
            layer.opacity = dimmingIDs.contains(id) ? 1 : Self.dimmedOpacity
        }
        for (key, layer) in canvas.layerTree.branchLayers {
            layer.opacity = dimmingIDs.contains(key.childID) ? 1 : Self.dimmedOpacity
        }
        CATransaction.commit()
    }

    // MARK: find rings (F-FOC-3)

    /// A soft ring around every matched node in the scene, with the
    /// current match emphasized in the accent color. Rebuilds from
    /// scratch — matches move rarely and the layer count is small.
    public func showFindHighlights(_ canvas: CanvasView, matchIDs: Set<String>, currentID: String?) {
        clearFindHighlights()
        currentHighlightID = currentID
        guard let scene = canvas.scene else { return }
        let host = canvas.layerTree.root
        let camera = canvas.camera
        for id in matchIDs.sorted() {
            guard let node = scene.nodes[id] else { continue }
            let ring = makeRing(node: node, camera: camera, name: Self.matchRingName)
            ring.strokeColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
            ring.lineWidth = 2.5 / camera.scale
            ring.zPosition = 2.5
            host.addSublayer(ring)
            matchRings[id] = ring
        }
        if let currentID, let node = scene.nodes[currentID] {
            let ring = makeRing(node: node, camera: camera, name: Self.currentRingName)
            ring.strokeColor = NSColor.controlAccentColor.cgColor
            ring.lineWidth = 3.5 / camera.scale
            ring.zPosition = 2.6
            host.addSublayer(ring)
            currentRing = ring
        }
    }

    /// Removes every find ring.
    public func clearFindHighlights() {
        for ring in matchRings.values {
            ring.removeFromSuperlayer()
        }
        matchRings.removeAll()
        currentRing?.removeFromSuperlayer()
        currentRing = nil
        currentHighlightID = nil
    }

    // MARK: sync (called by the one-line CanvasView hooks)

    /// After a scene application: relayouts moved the node frames, so
    /// the ring paths follow, rings of vanished nodes drop out, and
    /// dimming re-applies (freshly realized layers start at full
    /// opacity).
    public func sceneDidApply(_ canvas: CanvasView) {
        guard let scene = canvas.scene else {
            clearFindHighlights()
            return
        }
        var droppedMatchIDs: [String] = []
        for (id, ring) in matchRings {
            if let node = scene.nodes[id] {
                ring.path = CanvasLayerTree.ringPath(node: node)
            } else {
                droppedMatchIDs.append(id)
                ring.removeFromSuperlayer()
            }
        }
        for id in droppedMatchIDs {
            matchRings.removeValue(forKey: id)
        }
        if let currentID = currentHighlightID {
            if let node = scene.nodes[currentID], let ring = currentRing {
                ring.path = CanvasLayerTree.ringPath(node: node)
            } else {
                currentRing?.removeFromSuperlayer()
                currentRing = nil
                currentHighlightID = nil
            }
        }
        writeLayerOpacities(canvas, animated: false)
    }

    /// After a camera change: the rings' model-space transform and
    /// line widths re-pin, and dimming re-applies to whatever the new
    /// viewport realized.
    public func cameraDidChange(_ canvas: CanvasView) {
        let camera = canvas.camera
        for ring in matchRings.values {
            ring.transform = CanvasLayerTree.modelSpaceTransform(for: camera)
            ring.lineWidth = 2.5 / camera.scale
        }
        if let ring = currentRing {
            ring.transform = CanvasLayerTree.modelSpaceTransform(for: camera)
            ring.lineWidth = 3.5 / camera.scale
        }
        writeLayerOpacities(canvas, animated: false)
    }

    // MARK: test seams

    /// The realized node layer's opacity, or nil when the id has no
    /// layer (outside the visible rect).
    public func nodeLayerOpacity(_ canvas: CanvasView, id: String) -> Float? {
        canvas.layerTree.nodeLayers[id]?.opacity
    }

    /// The dimming POLICY for `id`, independent of whether the node's
    /// layer is currently realized (culling): full opacity inside the
    /// focus set, 15% outside, nil when nothing is dimmed.
    public func dimmingOpacity(for id: String) -> Float? {
        guard let dimmingIDs else { return nil }
        return dimmingIDs.contains(id) ? 1 : Self.dimmedOpacity
    }

    /// The number of live find rings (matches + current emphasis).
    public var findRingCount: Int {
        matchRings.count + (currentRing != nil ? 1 : 0)
    }

    // MARK: internals

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func makeRing(node: SceneNode, camera: Camera, name: String) -> CAShapeLayer {
        let ring = CAShapeLayer()
        ring.name = name
        ring.fillColor = nil
        ring.path = CanvasLayerTree.ringPath(node: node)
        ring.transform = CanvasLayerTree.modelSpaceTransform(for: camera)
        return ring
    }
}
