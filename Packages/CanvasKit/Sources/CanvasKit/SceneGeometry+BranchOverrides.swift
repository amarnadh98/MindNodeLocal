import CoreGraphics
import MapCore
import MapRender

/// Branch-width resolution for `SceneGeometry`'s connectors, split out to
/// keep the scene builder reviewable: the theme's §7.2 taper, plus the
/// per-node branch overrides (F-STY-2 width/taper, ADR-0028).
extension SceneGeometry {
    /// Branch widths after the child node's overrides (F-STY-2 branch
    /// width/taper, ADR-0028): `branchWidth` sets the width — the start
    /// of a taper, or the constant stroke of curved/straight/elbow —
    /// and `branchTaper` is the fall-off to the child end (floored at
    /// the §7.2 leaf width 2). The theme's own widths (precomputed by
    /// the caller — `Theme.branchWidth(level:)`, a borrowed-self
    /// method) fill every field the patch leaves unset.
    ///
    /// Deliberately scalar parameters: a `Theme` value is a large
    /// struct, and one connector resolves per branch — passing it by
    /// value through a non-inlined call is a measurable cost on the
    /// §11.8 path.
    static func overrideWidths(
        parentWidth: CGFloat, childWidth: CGFloat,
        patch: NodeStylePatch?, lineStyle: BranchLineStyle
    ) -> (start: CGFloat, end: CGFloat) {
        let overrideWidth = patch?.branchWidth.map { CGFloat($0) }
        switch lineStyle {
        case .tapered:
            let start = overrideWidth ?? parentWidth
            let end: CGFloat
            if let taper = patch?.branchTaper {
                end = max(2, start - CGFloat(taper))
            } else {
                end = childWidth
            }
            return (start, end)
        case .curved, .straight, .elbow:
            let width = overrideWidth ?? parentWidth
            return (width, width)
        case .none:
            return (0, 0)
        }
    }
}
