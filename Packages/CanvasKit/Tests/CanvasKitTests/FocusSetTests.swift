import Foundation
import MapCore
import Testing

@testable import CanvasKit

/// F-FOC-1/2 focus-set semantics: the anchor's whole subtree plus its
/// ancestor path to the root.
struct FocusSetTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// root ▸ a ▸ [a1 ▸ a1x, a2], root ▸ b
    private func model() -> MapModel {
        var model = MapModel.emptyDocument(docID: "focus")
        let names = ["root", "a", "a1", "a1x", "a2", "b"]
        for (index, name) in names.enumerated() {
            model.nodes[name] = Node(
                id: name, title: NodeTitle(text: name), created: date, modified: date)
        }
        model.roots = ["root"]
        model.nodes["root"]?.children = ["a", "b"]
        model.nodes["a"]?.parent = "root"
        model.nodes["a"]?.children = ["a1", "a2"]
        model.nodes["a1"]?.parent = "a"
        model.nodes["a1"]?.children = ["a1x"]
        model.nodes["a1x"]?.parent = "a1"
        model.nodes["a2"]?.parent = "a"
        model.nodes["b"]?.parent = "root"
        return model
    }

    @Test func focusSetIsSubtreePlusAncestorPath() {
        let ids = FocusSet.ids(around: "a1x", in: model())
        #expect(ids == ["root", "a", "a1", "a1x"])
    }

    @Test func focusSetOfARootIsItsOwnSubtree() {
        let ids = FocusSet.ids(around: "root", in: model())
        #expect(ids == Set(["root", "a", "a1", "a1x", "a2", "b"]))
    }

    @Test func subtreeIncludesEveryDescendant() {
        #expect(FocusSet.subtree(of: "a", in: model()) == ["a", "a1", "a1x", "a2"])
        #expect(FocusSet.subtree(of: "a2", in: model()) == ["a2"])
    }

    @Test func ancestorPathRunsRootFirstWithoutTheAnchor() {
        #expect(FocusSet.ancestorPath(of: "a1x", in: model()) == ["root", "a", "a1"])
        #expect(FocusSet.ancestorPath(of: "root", in: model()).isEmpty)
    }

    @Test func unknownAnchorYieldsNothing() {
        #expect(FocusSet.ids(around: "ghost", in: model()).isEmpty)
    }
}
