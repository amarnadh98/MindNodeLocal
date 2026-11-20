import Foundation
import Testing

@testable import MapCore

/// ADR-0034's creation defaults (pure): a sibling inherits the shape
/// of the node it is created next to when that node has an explicit
/// override; a child follows the theme level style unless a sibling
/// already carries an explicit shape, in which case the last such
/// sibling's shape wins — lines stay lines, boxes stay boxes.
struct NodeCreationShapeTests {
    @Test func siblingWithoutOverrideFollowsTheTheme() {
        #expect(NodeCreationShape.sibling(anchorStyle: nil) == nil)
        #expect(NodeCreationShape.sibling(anchorStyle: NodeStylePatch()) == nil)
        #expect(
            NodeCreationShape.sibling(anchorStyle: NodeStylePatch(fill: "#E5484D")) == nil,
            "a non-shape override is not a shape choice")
    }

    @Test func siblingInheritsTheAnchorShape() {
        #expect(NodeCreationShape.sibling(anchorStyle: NodeStylePatch(shape: .underline)) == .underline)
        #expect(
            NodeCreationShape.sibling(anchorStyle: NodeStylePatch(shape: .roundedRect, fill: "#0F0"))
                == .roundedRect)
    }

    @Test func childWithUnstyledSiblingsFollowsTheTheme() {
        #expect(NodeCreationShape.child(existingSiblings: []) == nil)
        #expect(NodeCreationShape.child(existingSiblings: [nil, nil]) == nil)
        #expect(
            NodeCreationShape.child(existingSiblings: [NodeStylePatch(fill: "#E5484D")]) == nil)
    }

    @Test func childCopiesTheLastSiblingWithAShape() {
        // "Lines stay lines": every child of the branch was turned
        // into a line — the new one is a line too.
        #expect(
            NodeCreationShape.child(
                existingSiblings: [
                    NodeStylePatch(shape: .underline),
                    NodeStylePatch(shape: .underline),
                ]) == .underline)

        // The LAST sibling's shape wins, whatever it is.
        #expect(
            NodeCreationShape.child(
                existingSiblings: [
                    NodeStylePatch(shape: .underline),
                    NodeStylePatch(shape: .roundedRect),
                ]) == .roundedRect)

        // A trailing theme-default sibling does not hide the branch's
        // earlier explicit choice.
        #expect(
            NodeCreationShape.child(
                existingSiblings: [
                    NodeStylePatch(shape: .underline),
                    nil,
                ]) == .underline)

        // Style-only siblings (no shape) leave the theme in charge.
        #expect(
            NodeCreationShape.child(
                existingSiblings: [NodeStylePatch(fill: "#0090FF"), nil]) == nil)
    }
}
