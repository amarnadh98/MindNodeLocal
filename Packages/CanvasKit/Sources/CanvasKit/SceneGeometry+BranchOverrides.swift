import CoreGraphics
import MapCore
import MapRender

/// Branch-width resolution for `SceneGeometry`'s connectors, split out to
/// keep the scene builder reviewable: the theme's §7.2 taper, plus the
/// per-node branch overrides (F-STY-2 width/taper, ADR-0011).
extension SceneGeometry {
    /// Branch widths after the child node's overrides (F-STY-2 branch
    /// width/taper, ADR-0011): `branchWidth` sets the width — the start
    /// of a taper, or the constant stroke of curved/straight/elbow —
    /// and `branchTaper` is the fall-off to the child end (floored at
    /// the §7.2 leaf width 2). The theme's own widths fill every field
    /// the patch leaves unset.
    static func overrideWidths(
        theme: Theme, patch: NodeStylePatch?, lineStyle: BranchLineStyle,
        parentLevel: Int, childLevel: Int
    ) -> (start: CGFloat, end: CGFloat) {
        let overrideWidth = patch?.branchWidth.map { CGFloat($0) }
        switch lineStyle {
        case .tapered:
            let start = overrideWidth ?? theme.branchWidth(level: parentLevel)
            let end: CGFloat
            if let taper = patch?.branchTaper {
                end = max(2, start - CGFloat(taper))
            } else {
                end = theme.branchWidth(level: childLevel)
            }
            return (start, end)
        case .curved, .straight, .elbow:
            let width = overrideWidth ?? theme.branchWidth(level: parentLevel)
            return (width, width)
        case .none:
            return (0, 0)
        }
    }
}
