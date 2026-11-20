import CoreGraphics
import Foundation

/// F-LAY-4 **logic chart (right)**: children to the right, aligned at
/// the left, "compact, like a horizontal outline". Geometrically it is
/// the one-sided placement (a parent's children already share the left
/// edge at `parent.width + gap`) run at a **uniform gap rhythm**: the
/// level gap between parent and children and the sibling gap between
/// consecutive children at *every* level — where the mind map widens
/// level 1 to the subtree gap and the root's own `rootGap`, the logic
/// chart stays outline-dense.
///
/// Because the y stacking is still the non-layered tidy tree, every
/// engine invariant carries over unchanged: no overlaps, sibling order,
/// determinism, and the incremental cache (the compacted spacing tags
/// the layout state, so a structure switch recomputes from scratch).
enum LogicLayout {
    /// F-LAY-4's uniform rhythm: level gap everywhere parent→children,
    /// sibling gap everywhere between children.
    static func compacted(_ spacing: LayoutSpacing) -> LayoutSpacing {
        LayoutSpacing(
            levelGap: spacing.levelGap,
            siblingGap: spacing.siblingGap,
            subtreeGap: spacing.siblingGap,
            rootGap: spacing.levelGap)
    }

    /// Full path.
    static func layout(root: LayoutNode, spacing: LayoutSpacing) -> LayoutResult {
        MindmapLayout.layout(root: root, spacing: compacted(spacing), mirror: false)
    }
}
