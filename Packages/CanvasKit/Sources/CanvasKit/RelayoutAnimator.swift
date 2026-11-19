import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender

/// One node's motion in a relayout (SPEC §7.6), decidable headlessly:
/// which ids animate, from where, to where, and how. The layer tree
/// turns a plan into `CAAnimation`s; tests read the plan directly.
public struct RelayoutPlan: Equatable {
    /// Nodes animate to new frames with the §7.6 spring; new nodes
    /// scale in from the parent anchor; deleted nodes fade and shrink.
    public enum Move: Equatable {
        /// A node whose frame moved: position springs from the old
        /// origin to the new one.
        case spring(fromOrigin: CGPoint, toOrigin: CGPoint)
        /// A node that appeared: fades 0→1, scales 0.85→1, sliding out
        /// of the parent's outgoing anchor (220 ms).
        case appear(fromAnchor: CGPoint, frame: CGRect)
        /// A node that vanished: fades and scales to 0.9 (160 ms),
        /// then the layer is recycled.
        case disappear(frame: CGRect)
    }

    public let moves: [String: Move]
    public let branchMorphs: [BranchMorph]

    public var isEmpty: Bool { moves.isEmpty && branchMorphs.isEmpty }
}

/// Builds a `RelayoutPlan` from a scene diff. Pure — `Reduce Motion`
/// collapses everything to an empty plan (no movement animation), and a
/// first scene (nothing before it) never animates: opening a document
/// must land at first paint, not ease into it.
public enum RelayoutPlanner {
    public static func plan(
        old: CanvasScene?,
        new: CanvasScene,
        diff: SceneDiff,
        reduceMotion: Bool
    ) -> RelayoutPlan {
        guard old != nil, !reduceMotion else {
            return RelayoutPlan(moves: [:], branchMorphs: [])
        }

        var moves: [String: RelayoutPlan.Move] = [:]
        var incoming: [String: SceneBranch] = [:]
        for branch in new.branches {
            incoming[branch.childID] = branch
        }

        for (id, change) in diff.nodes {
            switch change {
            case .added:
                let node = new.nodes[id]
                let frame = node?.frame ?? .zero
                // New roots have no incoming branch: they fade in place.
                let anchor = incoming[id]?.from ?? frame.origin
                moves[id] = .appear(fromAnchor: anchor, frame: frame)
            case .removed:
                moves[id] = .disappear(frame: old?.nodes[id]?.frame ?? .zero)
            case .moved(let fromFrame, let toFrame):
                moves[id] = .spring(fromOrigin: fromFrame.origin, toOrigin: toFrame.origin)
            case .restyled(let fromFrame, let toFrame):
                // Re-rastered regardless; the frame only springs when it
                // actually moved.
                if fromFrame != toFrame {
                    moves[id] = .spring(fromOrigin: fromFrame.origin, toOrigin: toFrame.origin)
                }
            }
        }
        return RelayoutPlan(moves: moves, branchMorphs: diff.branchMorphs)
    }
}

/// System motion preferences (SPEC §7.6): Reduce Motion turns relayout
/// springs into instant applies.
@MainActor
enum MotionPreferences {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The CA side of SPEC §7.6: spring constants derived from the
/// response/damping pair, and the standard durations.
enum RelayoutAnimator {
    /// §7.6 relayout spring: response 0.32 s, damping ratio 0.86,
    /// ≈ 280 ms — expressed as stiffness/damping for CASpringAnimation
    /// (mass 1).
    static let springResponse: Double = 0.32
    static let springDampingRatio: Double = 0.86
    static let relayoutDuration: CFTimeInterval = 0.32
    static let appearDuration: CFTimeInterval = 0.22
    static let disappearDuration: CFTimeInterval = 0.16

    private static var omega: Double { 2 * .pi / springResponse }

    static func relayoutSpring(keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = omega * omega
        animation.damping = 2 * springDampingRatio * omega
        animation.duration = relayoutDuration
        animation.fromValue = from
        animation.toValue = to
        animation.isRemovedOnCompletion = true
        return animation
    }

    /// New node: scales 0.85 → 1 and fades in, sliding out of the
    /// parent anchor (220 ms). Screen-space: the layer's own transform
    /// already carries the camera scale, so the animation's transform
    /// values compose the zoom in.
    static func appearAnimations(
        camera: Camera, frame: CGRect, fromAnchor: CGPoint
    ) -> [CAAnimation] {
        let toPoint = camera.screenPoint(for: frame.origin)
        let fromPoint = camera.screenPoint(for: fromAnchor)

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: fromPoint)
        position.toValue = NSValue(point: toPoint)
        position.duration = appearDuration
        position.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let alpha = CABasicAnimation(keyPath: "opacity")
        alpha.fromValue = 0
        alpha.toValue = 1
        alpha.duration = appearDuration
        alpha.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(
            caTransform3D: CATransform3DMakeScale(camera.scale * 0.85, camera.scale * 0.85, 1))
        scale.toValue = NSValue(
            caTransform3D: CATransform3DMakeScale(camera.scale, camera.scale, 1))
        scale.duration = appearDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        return [position, alpha, scale]
    }

    /// Deleted node: fades and scales to 0.9 (160 ms), then the layer
    /// is recycled. The camera's zoom composes into the scale values.
    static func disappearAnimations(camera: Camera) -> [CAAnimation] {
        let alpha = CABasicAnimation(keyPath: "opacity")
        alpha.fromValue = 1
        alpha.toValue = 0
        alpha.duration = disappearDuration
        alpha.timingFunction = CAMediaTimingFunction(name: .easeIn)

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(
            caTransform3D: CATransform3DMakeScale(camera.scale, camera.scale, 1))
        scale.toValue = NSValue(
            caTransform3D: CATransform3DMakeScale(camera.scale * 0.9, camera.scale * 0.9, 1))
        scale.duration = disappearDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)

        return [alpha, scale]
    }
}
