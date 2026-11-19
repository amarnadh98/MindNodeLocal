import CoreGraphics
import Foundation
import MapStudy
import QuartzCore

/// The presentation/recall side of the layer tree (SPEC §10, F-PRE-3):
/// an overlay of `RevealState`s dims, hides and reveals **existing**
/// layers through opacity alone — never a re-raster — and the reveal
/// build animation (fade + 8 pt slide from the parent, 250 ms,
/// 60 ms stagger) rides explicit `CAAnimation`s on the pooled layers,
/// which already implement `init(layer:)` for CA's presentation copies.
///
/// The overlay is stored on the tree, so layers realized later by
/// culling pick their state up on realization.
extension CanvasLayerTree {
    /// Installs (or clears) the overlay and re-applies it to every
    /// realized layer instantly. Ids the overlay does not mention keep
    /// full opacity unless dimmed.
    public func setRevealOverlay(_ overlay: RevealOverlay?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealOverlay = overlay
        if let overlay {
            for (id, layer) in nodeLayers {
                layer.opacity = Float(overlay.nodeOpacity(id))
            }
            for (key, layer) in branchLayers {
                layer.opacity = Float(overlay.branchOpacity(parentID: key.parentID, childID: key.childID))
            }
        } else {
            for layer in nodeLayers.values {
                layer.opacity = 1
            }
            for layer in branchLayers.values {
                layer.opacity = 1
            }
        }
        CATransaction.commit()
    }

    /// The §7 reveal build animation (F-PRE-3): the step's nodes fade
    /// in and slide 8 pt out of their parent's anchor — 250 ms,
    /// staggered 60 ms per node in the step — and each node's incoming
    /// branch fades with it. Under Reduce Motion everything lands
    /// instantly (the opacity write above already did). Only opacity
    /// and position change: no raster is ever rebuilt.
    public func revealNodes(_ ids: [String], camera: Camera, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let scene else { return }

        var incoming: [String: SceneBranch] = [:]
        for branch in scene.branches {
            incoming[branch.childID] = branch
        }

        for (index, id) in ids.enumerated() {
            guard let layer = nodeLayers[id] else { continue }
            layer.opacity = 1
            if let branch = incoming[id],
                let branchLayer = branchLayers[
                    BranchKey(parentID: branch.parentID, childID: id)]
            {
                branchLayer.opacity = 1
                if !reduceMotion {
                    branchLayer.add(
                        Self.revealFade(delay: Self.staggerDelay(index)), forKey: "reveal-branch")
                }
            }
            if reduceMotion { continue }
            let frame = scene.nodes[id]?.frame ?? .zero
            let toPoint = camera.screenPoint(for: frame.origin)
            let fromPoint: CGPoint
            if let anchor = incoming[id]?.from {
                fromPoint = camera.screenPoint(for: anchor)
            } else {
                fromPoint = toPoint
            }
            layer.add(
                Self.revealFade(delay: Self.staggerDelay(index)), forKey: "reveal-opacity")
            layer.add(
                Self.revealSlide(to: toPoint, from: fromPoint, delay: Self.staggerDelay(index)),
                forKey: "reveal-position")
        }
    }

    /// A step's duration (§7.6 motion table: reveal 250 ms).
    public static let revealDuration: CFTimeInterval = 0.25
    /// The per-node stagger within one step (§7.6: 60 ms).
    public static let revealStagger: CFTimeInterval = 0.06
    /// The slide distance out of the parent anchor (§7.6: 8 pt).
    public static let revealSlideDistance: CGFloat = 8

    static func staggerDelay(_ index: Int) -> CFTimeInterval {
        revealStagger * CFTimeInterval(index)
    }

    /// 0 → 1 fade, ease-out, delayed by the stagger. The begin time is
    /// always absolute (even at delay 0) so successive steps compare.
    static func revealFade(delay: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = revealDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .both
        fade.isRemovedOnCompletion = true
        fade.beginTime = CACurrentMediaTime() + delay
        return fade
    }

    /// Slides the layer 8 pt along the parent→child axis, out of the
    /// parent's outgoing anchor, into its final screen position.
    static func revealSlide(to: CGPoint, from parentAnchor: CGPoint, delay: CFTimeInterval)
        -> CABasicAnimation
    {
        let delta = CGVector(dx: to.x - parentAnchor.x, dy: to.y - parentAnchor.y)
        let length = hypot(delta.dx, delta.dy)
        // 8 pt *toward the parent* from the final position, whatever
        // the zoom: the slide is screen-space like the rest of the
        // layer geometry.
        let start: CGPoint
        if length > 0.001 {
            start = CGPoint(
                x: to.x - delta.dx / length * revealSlideDistance,
                y: to.y - delta.dy / length * revealSlideDistance)
        } else {
            start = CGPoint(x: to.x, y: to.y - revealSlideDistance)
        }
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: start)
        slide.toValue = NSValue(point: to)
        slide.duration = revealDuration
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        slide.fillMode = .both
        slide.isRemovedOnCompletion = true
        slide.beginTime = CACurrentMediaTime() + delay
        return slide
    }
}
