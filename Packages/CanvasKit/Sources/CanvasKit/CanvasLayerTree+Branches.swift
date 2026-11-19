import CoreGraphics
import MapRender
import QuartzCore

/// Branch shape layers of the virtualized tree (SPEC §11.4): culling
/// bounds, the tapered/staight path, and geometry-vs-color updates —
/// split out of `CanvasLayerTree` to keep the class body reviewable.
extension CanvasLayerTree {
    // MARK: branches

    /// A branch's conservative bounds for culling (same as the
    /// renderer's): the from→to box inflated by the wider end.
    static func branchBounds(_ branch: SceneBranch) -> CGRect {
        let width = max(branch.startWidth, branch.endWidth)
        return CGRect(
            x: min(branch.from.x, branch.to.x),
            y: min(branch.from.y, branch.to.y),
            width: abs(branch.to.x - branch.from.x),
            height: abs(branch.to.y - branch.from.y)
        ).insetBy(dx: -width, dy: -width)
    }

    static func branchPath(_ branch: SceneBranch) -> CGPath {
        branch.tapered
            ? MapRender.BranchPath.tapered(
                from: branch.from, to: branch.to,
                startWidth: branch.startWidth, endWidth: branch.endWidth,
                axis: branch.axis)
            : MapRender.BranchPath.straight(from: branch.from, to: branch.to)
    }

    func configureBranchLayer(
        _ layer: BranchVisualLayer, branch: SceneBranch, camera: Camera, reduceMotion: Bool
    ) {
        layer.transform = Self.modelSpaceTransform(for: camera)
        // M6 (F-PRE/§10): the branch dims with the weaker of its two
        // ends under a reveal overlay.
        if let overlay = revealOverlay {
            layer.opacity = Float(overlay.branchOpacity(parentID: branch.parentID, childID: branch.childID))
        } else if layer.opacity != 1 {
            layer.opacity = 1
        }
        guard let old = layer.branch else {
            applyBranchPath(layer, old: nil, branch: branch, reduceMotion: reduceMotion)
            return
        }
        let sameGeometry = old == branch
        let sameColor = SceneBranch.isSameColor(old, branch)
        if sameGeometry, sameColor { return }
        if !sameColor {
            layer.fillColor = branch.tapered ? branch.color : nil
            layer.strokeColor = branch.tapered ? nil : branch.color
        }
        if !sameGeometry {
            applyBranchPath(layer, old: old, branch: branch, reduceMotion: reduceMotion)
        } else {
            layer.branch = branch
        }
    }

    func applyBranchPath(
        _ layer: BranchVisualLayer, old: SceneBranch?, branch: SceneBranch, reduceMotion: Bool
    ) {
        let newPath = Self.branchPath(branch)
        if let old, !reduceMotion {
            // Identical element structure on both paths (fixed
            // 16-sample taper) — §11.4's requirement for path
            // animation.
            let morph = RelayoutAnimator.relayoutSpring(
                keyPath: "path", from: Self.branchPath(old), to: newPath)
            layer.add(morph, forKey: "relayout-path")
        }
        layer.path = newPath
        layer.fillColor = branch.tapered ? branch.color : nil
        layer.strokeColor = branch.tapered ? nil : branch.color
        layer.lineWidth = branch.tapered ? 0 : max(branch.startWidth, branch.endWidth)
        layer.branch = branch
    }
}
