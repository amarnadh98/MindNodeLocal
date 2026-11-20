import Foundation

/// The Box|Line creation defaults (ADR-0037): the shape a freshly
/// created node should *store* so it matches what the user has been
/// shaping around it — `nil` means "follow the theme's level style,
/// persist nothing".
///
/// Pure and model-shaped so every creation path (⏎/⌥⏎ siblings, ⇥
/// and the Node Well's "+" children) shares one tested rule:
///
/// - A **sibling** inherits the shape of the node it is created next
///   to, but only when that node carries an explicit shape override —
///   otherwise the theme's level style should keep deciding.
/// - A **child** follows its theme level style, unless the parent
///   already has children with an explicit shape, in which case the
///   new child copies the shape of the last such sibling (lines stay
///   lines, boxes stay boxes).
public enum NodeCreationShape {
    /// The shape for a new sibling created next to `anchorStyle` — the
    /// anchor's stored patch when it carries a shape, else `nil`.
    public static func sibling(anchorStyle: NodeStylePatch?) -> NodeShape? {
        anchorStyle?.shape
    }

    /// The shape for a new child of a parent whose existing children
    /// carry `siblingStyles` (in sibling order): the last sibling with
    /// an explicit shape, else `nil` (the theme's level style).
    public static func child(existingSiblings: [NodeStylePatch?]) -> NodeShape? {
        for style in existingSiblings.reversed() where style?.shape != nil {
            return style?.shape
        }
        return nil
    }
}
