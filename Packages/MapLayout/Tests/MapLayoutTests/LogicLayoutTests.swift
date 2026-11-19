import CoreGraphics
import Foundation
import Testing

@testable import MapLayout

/// F-LAY-4 logic chart (right): the one-sided placement at a compact,
/// uniform gap rhythm — every parent's children align at one left edge
/// (an outline's density), the level-1 rhythm uses the sibling gap
/// (where the mind map widens to the subtree gap), and the incremental
/// path is bit-identical to the full pass (the invariants suites cover
/// it through `allStructures`).
struct LogicLayoutTests {
    private func depthOf(_ tree: LayoutNode, _ id: String) -> Int {
        func walk(_ node: LayoutNode, _ depth: Int) -> Int? {
            if node.id == id { return depth }
            for child in node.children {
                if let found = walk(child, depth + 1) { return found }
            }
            return nil
        }
        return walk(tree, 0) ?? 0
    }

    @Test func everyParentsChildrenAlignAtOneLeftEdge() {
        let frames = TreeLayout.layout(root: sampleTree(), structure: .logicChartRight)
        func assertAligned(_ node: LayoutNode) {
            let edges = Set(node.children.map { frames[$0.id]?.minX ?? -1 })
            #expect(edges.count <= 1, "\(node.id)'s children align at one left edge")
            for child in node.children {
                assertAligned(child)
            }
        }
        assertAligned(sampleTree())
    }

    @Test func levelOneUsesTheCompactRhythm() throws {
        let spacing = LayoutSpacing.default
        let compact = LogicLayout.compacted(spacing)
        // Consecutive childless level-1 siblings: their contour IS their
        // own frame, so the rhythm is directly observable.
        let tree = node(
            "root", 100, 30,
            [node("x1", 80, 20), node("x2", 80, 20), node("x3", 80, 20)])
        let frames = TreeLayout.layout(root: tree, structure: .logicChartRight, spacing: spacing)
        let root = try #require(frames["root"])
        let first = try #require(frames["x1"])
        let second = try #require(frames["x2"])
        // The first level sits one LEVEL gap past the root (the mind map
        // would use the wider root gap)…
        #expect(abs(first.minX - (root.maxX + compact.rootGap)) < 0.001)
        // …and consecutive level-1 children separate by the SIBLING gap.
        #expect(abs(second.minY - (first.maxY + compact.siblingGap)) < 0.001)
        // Compactness is real: the mind map's rhythm is wider here.
        let mindmap = TreeLayout.layout(root: tree, structure: .mindmapRight, spacing: spacing)
        let mindmapFirst = try #require(mindmap["x1"])
        #expect(mindmapFirst.minX > first.minX + 0.001, "rootGap > levelGap at level 1")
    }

    @Test func compactedSpacingIsTheUniformRhythm() {
        let spacing = LayoutSpacing.default
        let compact = LogicLayout.compacted(spacing)
        #expect(compact.rootGap == compact.levelGap)
        #expect(compact.subtreeGap == compact.siblingGap)
        #expect(compact.levelGap == spacing.levelGap)
        #expect(compact.siblingGap == spacing.siblingGap)
    }

    @Test func incrementalEqualsFullForTheLogicChart() {
        // The same equivalence the other structures carry
        // (IncrementalLayoutTests), pinned for the compact rhythm: a
        // dirty chain rebuild matches a full pass exactly.
        let tree = fan(children: 12, grandchildren: 3)
        let source: (String) -> LayoutSourceNode? = sourceBuilder(tree)

        let full = IncrementalLayout.update(
            rootID: tree.id, structure: .logicChartRight, dirty: nil, source: source)
        let incremental = IncrementalLayout.update(
            rootID: tree.id, structure: .logicChartRight,
            state: full.state, dirty: ["fan-4"], source: source)
        let rebuilt = IncrementalLayout.update(
            rootID: tree.id, structure: .logicChartRight, dirty: nil, source: source)
        #expect(incremental.frames == rebuilt.frames, "dirty chain == full pass")
    }

    @Test func structureSwitchInvalidatesTheCachedState() {
        // A mind-map state must not be reused at the logic chart's
        // rhythm (and back): the spacing tag forces the full pass.
        let tree = sampleTree()
        let source: (String) -> LayoutSourceNode? = sourceBuilder(tree)
        let mindmap = IncrementalLayout.update(
            rootID: tree.id, structure: .mindmapRight, dirty: nil, source: source)
        let asChart = IncrementalLayout.update(
            rootID: tree.id, structure: .logicChartRight, state: mindmap.state,
            dirty: [], source: source)
        let chartFresh = IncrementalLayout.update(
            rootID: tree.id, structure: .logicChartRight, dirty: nil, source: source)
        #expect(asChart.frames == chartFresh.frames)
        #expect(
            asChart.frames != IncrementalLayout.update(
                rootID: tree.id, structure: .mindmapRight, dirty: nil, source: source
            ).frames,
            "the compact rhythm must actually differ from the mind map's")
    }
}

/// Walks a `LayoutNode` tree as a layout source (the test trees carry
/// no pinned sides).
private func sourceBuilder(_ root: LayoutNode) -> (String) -> LayoutSourceNode? {
    var byID: [String: LayoutNode] = [:]
    func walk(_ node: LayoutNode) {
        byID[node.id] = node
        for child in node.children {
            walk(child)
        }
    }
    walk(root)
    return { id in
        guard let node = byID[id] else { return nil }
        return LayoutSourceNode(
            id: node.id, size: node.size, side: nil,
            childIDs: node.children.map(\.id))
    }
}
