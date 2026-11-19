import Foundation
import MapCore
import Testing

@testable import MapIO

/// F-EDT-9 paste placement: the pure anchor rule the host's ⌘V relies on
/// — under the document-order-first selected node as its LAST children, or
/// as roots appended at the end when nothing is selected.
@Suite
struct PasteAnchorTests {
    /// root(r) with children [a, b]; a has one child g; plus root z.
    private var model: MapModel {
        var model = MapModel.emptyDocument(docID: "anchor")
        for (id, parent) in [("r", nil as String?), ("a", "r"), ("g", "a"), ("b", "r"), ("z", nil)] {
            model.nodes[id] = Node(id: id, parent: parent, title: NodeTitle(text: id))
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        return model
    }

    @Test func landsUnderTheFirstSelectedNodeAsItsLastChild() {
        // Document order decides "first", not selection order: b comes
        // after a in the outline, so [b, a] pastes under a.
        let anchor = PasteboardParser.pasteAnchor(selection: ["b", "a"], in: model)
        #expect(anchor.parent == "a")
        #expect(anchor.index == model.nodes["a"]?.children.count)
    }

    @Test func emptySelectionAppendsRoots() {
        let anchor = PasteboardParser.pasteAnchor(selection: [], in: model)
        #expect(anchor.parent == nil)
        #expect(anchor.index == model.roots.count)
    }

    @Test func unknownIDsAreIgnoredEntirely() {
        let anchor = PasteboardParser.pasteAnchor(selection: ["ghost"], in: model)
        #expect(anchor.parent == nil)
        #expect(anchor.index == model.roots.count)
    }

    @Test func ancestorAndDescendantCollapseOntoTheAncestor() {
        // a's snapshot already covers g, so the pair means "a".
        let anchor = PasteboardParser.pasteAnchor(selection: ["g", "a"], in: model)
        #expect(anchor.parent == "a")
        #expect(anchor.index == model.nodes["a"]?.children.count)
    }

    @Test func aSoloDescendantPastesUnderItself() {
        let anchor = PasteboardParser.pasteAnchor(selection: ["g"], in: model)
        #expect(anchor.parent == "g")
        #expect(anchor.index == 0)
    }
}
