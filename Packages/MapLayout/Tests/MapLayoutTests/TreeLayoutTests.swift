import CoreGraphics
import Foundation
import Testing

@testable import MapLayout

let allStructures: [LayoutStructure] = [
    .mindmapBalanced, .mindmapRight, .mindmapLeft, .orgDown, .orgUp,
]

func node(_ id: String, _ width: CGFloat, _ height: CGFloat, _ children: [LayoutNode] = []) -> LayoutNode {
    LayoutNode(id: id, size: CGSize(width: width, height: height), children: children)
}

func sampleTree() -> LayoutNode {
    node(
        "root", 120, 40,
        [
            node(
                "a", 90, 28,
                [
                    node("a1", 70, 24),
                    node("a2", 70, 24, [node("a2x", 60, 22)]),
                    node("a3", 70, 24),
                ]),
            node("b", 90, 30),
            node(
                "c", 80, 26,
                [
                    node("c1", 70, 24, [node("c1a", 60, 20), node("c1b", 60, 20)]),
                    node("c2", 70, 24),
                ]),
            node("d", 90, 30, [node("d1", 60, 20)]),
        ])
}

func chain(depth: Int) -> LayoutNode {
    var current = node("leaf", 60, 20)
    for level in 0..<depth {
        current = node("chain-\(level)", 70 + CGFloat(depth - level) * 4, 22, [current])
    }
    return current
}

func fan(children: Int, grandchildren: Int) -> LayoutNode {
    node(
        "fan-root", 100, 40,
        (0..<children).map { index in
            node(
                "fan-\(index)", 80, 26,
                (0..<grandchildren).map { sub in
                    node("fan-\(index)-\(sub)", 70, 22)
                })
        })
}

func variedTree() -> LayoutNode {
    node(
        "root", 120, 48,
        [
            node("tall", 80, 90, [node("tall1", 60, 40), node("tall2", 60, 40)]),
            node("wide", 300, 30),
            node(
                "mixed", 90, 30,
                [
                    node("mixed1", 50, 100),
                    node("mixed2", 200, 26),
                ]),
            node("small", 40, 20),
        ])
}

func ids(of tree: LayoutNode) -> [String] {
    [tree.id] + tree.children.flatMap { ids(of: $0) }
}

func assertNoOverlap(_ frames: LayoutResult, _ comment: String) {
    let list = frames.values.map { $0.standardized }.sorted { $0.minX < $1.minX }
    for i in list.indices {
        for j in list.indices where j > i {
            let first = list[i]
            let second = list[j]
            let separated =
                first.maxX <= second.minX || second.maxX <= first.minX
                || first.maxY <= second.minY || second.maxY <= first.minY
            #expect(separated, "\(comment): \(first) overlaps \(second)")
        }
    }
}

func assertOrderPreserved(_ tree: LayoutNode, _ frames: LayoutResult, horizontal: Bool, comment: String) {
    for parent in ids(of: tree).map({ id in subtree(tree, id) }).compactMap({ $0 }) where !parent.children.isEmpty {
        var previous: CGFloat?
        for child in parent.children {
            guard let frame = frames[child.id] else { continue }
            let center = horizontal ? frame.midY : frame.midX
            if let before = previous {
                #expect(center >= before - 0.001, "\(comment): order broke at \(child.id)")
            }
            previous = center
        }
    }
}

func subtree(_ tree: LayoutNode, _ id: String) -> LayoutNode? {
    if tree.id == id { return tree }
    for child in tree.children {
        if let found = subtree(child, id) { return found }
    }
    return nil
}

@Test func allStructuresCoverEveryNodeExactlyOnce() {
    for structure in allStructures {
        let frames = TreeLayout.layout(root: sampleTree(), structure: structure)
        #expect(frames.count == 14, "\(structure)")
        #expect(frames["root"] != nil, "\(structure)")
        let root = frames["root"]!
        #expect(root.minX == 0 && root.minY == 0, "\(structure): root at origin")
    }
}

@Test("no overlaps: sample tree") func noOverlapsSample() {
    for structure in allStructures {
        assertNoOverlap(TreeLayout.layout(root: sampleTree(), structure: structure), "\(structure)")
    }
}

@Test("no overlaps: chain of 6") func noOverlapsChain() {
    let tree = chain(depth: 6)
    for structure in allStructures {
        assertNoOverlap(TreeLayout.layout(root: tree, structure: structure), "\(structure)")
    }
}

@Test("no overlaps: fan 20 x 3") func noOverlapsFan() {
    let tree = fan(children: 20, grandchildren: 3)
    for structure in allStructures {
        assertNoOverlap(TreeLayout.layout(root: tree, structure: structure), "\(structure)")
    }
}

@Test("no overlaps: varied sizes") func noOverlapsVaried() {
    for structure in allStructures {
        assertNoOverlap(TreeLayout.layout(root: variedTree(), structure: structure), "\(structure)")
    }
}

@Test func siblingOrderPreserved() {
    let oneSided: [LayoutStructure] = [.mindmapRight, .mindmapLeft, .orgDown, .orgUp]
    for structure in oneSided {
        let frames = TreeLayout.layout(root: sampleTree(), structure: structure)
        let horizontal = structure == .mindmapRight || structure == .mindmapLeft
        assertOrderPreserved(sampleTree(), frames, horizontal: horizontal, comment: "\(structure)")
    }
}

@Test func deterministicAcrossRuns() {
    for structure in allStructures {
        let first = TreeLayout.layout(root: sampleTree(), structure: structure)
        let second = TreeLayout.layout(root: sampleTree(), structure: structure)
        #expect(first == second, "\(structure)")
    }
}

@Test func gapsRespected() throws {
    let spacing = LayoutSpacing.default
    let frames = TreeLayout.layout(root: sampleTree(), structure: .mindmapRight, spacing: spacing)
    let root = try #require(frames["root"])
    let childA = try #require(frames["a"])
    #expect(childA.minX == root.maxX + spacing.rootGap)

    let framesDeep = TreeLayout.layout(root: sampleTree(), structure: .mindmapLeft, spacing: spacing)
    let childALeft = try #require(framesDeep["a"])
    #expect(childALeft.maxX == -spacing.rootGap)
}

@Test func balancedSplitsAndCenters() throws {
    let frames = TreeLayout.layout(root: sampleTree(), structure: .mindmapBalanced)
    let root = try #require(frames["root"])
    assertNoOverlap(frames, "balanced")

    let rootMidX = root.midX
    let rightSide = frames.values.filter { $0.minX >= root.maxX }
    let leftSide = frames.values.filter { $0.maxX <= root.minX }
    #expect(!rightSide.isEmpty, "balanced has a right side")
    #expect(!leftSide.isEmpty, "balanced has a left side")

    let rightCenter = (rightSide.map(\.minY).min()! + rightSide.map(\.maxY).max()!) / 2
    let leftCenter = (leftSide.map(\.minY).min()! + leftSide.map(\.maxY).max()!) / 2
    #expect(abs(rightCenter - root.midY) < 80, "right side roughly centered")
    #expect(abs(leftCenter - root.midY) < 80, "left side roughly centered")

    for frame in rightSide {
        #expect(frame.minX >= rootMidX, "right side content right of root")
    }
    for frame in leftSide {
        #expect(frame.maxX <= rootMidX, "left side content left of root")
    }
}

@Test func balancedRespectsPinnedSides() {
    let tree = node(
        "root", 100, 40,
        [
            LayoutNode(id: "always-left", size: CGSize(width: 80, height: 30), side: .left, children: []),
            node("free1", 80, 30),
            node("free2", 80, 30),
            LayoutNode(id: "always-right", size: CGSize(width: 80, height: 30), side: .right, children: []),
        ])
    let frames = TreeLayout.layout(root: tree, structure: .mindmapBalanced)
    #expect(frames["always-left"]!.maxX <= 0)
    #expect(frames["always-right"]!.minX >= 100)
    assertNoOverlap(frames, "pinned")
}

@Test func mirroringKeepsRootAtOrigin() throws {
    let right = TreeLayout.layout(root: sampleTree(), structure: .mindmapRight)
    let left = TreeLayout.layout(root: sampleTree(), structure: .mindmapLeft)
    let rootWidth = right["root"]!.width
    for (id, frame) in right {
        let mirrored = left[id]!
        #expect(abs(frame.minY - mirrored.minY) < 0.001, "\(id) y preserved")
        if id != "root" {
            #expect(
                abs((frame.midX - rootWidth / 2) + (mirrored.midX - rootWidth / 2)) < 0.001,
                "\(id) mirrored around root center")
        }
    }
    #expect(left["root"]!.minX == 0 && left["root"]!.minY == 0)

    let downFrames = TreeLayout.layout(root: sampleTree(), structure: .orgDown)
    let upFrames = TreeLayout.layout(root: sampleTree(), structure: .orgUp)
    for (id, frame) in downFrames {
        let flipped = upFrames[id]!
        if id != "root" {
            #expect(abs(frame.minX - flipped.minX) < 0.001, "\(id) x preserved")
        }
    }
    #expect(upFrames["root"]!.minX == 0 && upFrames["root"]!.minY == 0)
}

@Test func goldenFramesMindmapRight() {
    let frames = TreeLayout.layout(root: sampleTree(), structure: .mindmapRight)
    let snapshot = frames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    print("GOLDEN-RIGHT: \(snapshot)")
    #expect(snapshot == goldenMindmapRight)
}

@Test func goldenFramesOrgDown() {
    let frames = TreeLayout.layout(root: sampleTree(), structure: .orgDown)
    let snapshot = frames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    print("GOLDEN-ORG: \(snapshot)")
    #expect(snapshot == goldenOrgDown)
}

let goldenMindmapRight = [
    "a=(192.0, -84.0, 90.0, 28.0)",
    "a1=(338.0, -118.0, 70.0, 24.0)",
    "a2=(338.0, -82.0, 70.0, 24.0)",
    "a2x=(464.0, -81.0, 60.0, 22.0)",
    "a3=(338.0, -46.0, 70.0, 24.0)",
    "b=(192.0, -22.0, 90.0, 30.0)",
    "c=(192.0, 32.0, 80.0, 26.0)",
    "c1=(328.0, 14.0, 70.0, 24.0)",
    "c1a=(454.0, 0.0, 60.0, 20.0)",
    "c1b=(454.0, 32.0, 60.0, 20.0)",
    "c2=(328.0, 52.0, 70.0, 24.0)",
    "d=(192.0, 95.0, 90.0, 30.0)",
    "d1=(338.0, 100.0, 60.0, 20.0)",
    "root=(0.0, 0.0, 120.0, 40.0)",
].joined(separator: ";")

let goldenOrgDown = [
    "a=(-190.25, 112.0, 90.0, 28.0)",
    "a1=(-262.25, 196.0, 70.0, 24.0)",
    "a2=(-180.25, 196.0, 70.0, 24.0)",
    "a2x=(-175.25, 276.0, 60.0, 22.0)",
    "a3=(-98.25, 196.0, 70.0, 24.0)",
    "b=(-28.25, 112.0, 90.0, 30.0)",
    "c=(85.75, 112.0, 80.0, 26.0)",
    "c1=(40.25, 194.0, 70.0, 24.0)",
    "c1a=(9.25, 274.0, 60.0, 20.0)",
    "c1b=(81.25, 274.0, 60.0, 20.0)",
    "c2=(141.25, 194.0, 70.0, 24.0)",
    "d=(220.25, 112.0, 90.0, 30.0)",
    "d1=(235.25, 198.0, 60.0, 20.0)",
    "root=(0.0, 0.0, 120.0, 40.0)",
].joined(separator: ";")

@Test func performanceSmoke() {
    for count in [1_000, 5_000] {
        let tree = bigTree(nodeCount: count)
        _ = TreeLayout.layout(root: tree, structure: .mindmapBalanced)

        // Best of 10: shared CI runners jitter by a few ms between
        // samples, and the budget is about the layout, not the host.
        var best: Double?
        for _ in 0..<10 {
            let start = DispatchTime.now()
            let frames = TreeLayout.layout(root: tree, structure: .mindmapBalanced)
            let elapsed =
                Double(
                    DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            best = min(best ?? elapsed, elapsed)
            #expect(frames.count == count)
        }
        let elapsed = best ?? 0
        print(
            "layout of \(count) nodes (balanced, best of 10): \(String(format: "%.1f", elapsed * 1000)) ms"
        )
        #expect(elapsed < 1.0, "layout budget blown for \(count) nodes")
        #if !DEBUG
            // Shared CI runners are 2-3x slower than an M1-class Mac, so CI
            // guards against regressions at twice the budget; local runs
            // enforce the SPEC §11.8 10 ms budget itself.
            let budget = ProcessInfo.processInfo.environment["CI"] == nil ? 0.010 : 0.020
            if count == 5_000 {
                #expect(elapsed < budget, "5k-node full layout must meet the SPEC §11.8 10 ms budget")
            }
        #endif
    }
}

func bigTree(nodeCount: Int) -> LayoutNode {
    let sizes = (0..<nodeCount).map {
        CGSize(width: 60 + CGFloat(($0 * 37) % 80), height: 22 + CGFloat(($0 * 13) % 10))
    }
    var nodes = (0..<nodeCount).map { LayoutNode(id: "n\($0)", size: sizes[$0]) }
    var childrenOf: [[Int]] = Array(repeating: [], count: nodeCount)
    var frontier = 0
    var nextChild = 1
    while nextChild < nodeCount {
        let childCount = min(7, nodeCount - nextChild)
        childrenOf[frontier] = Array(nextChild..<(nextChild + childCount))
        nextChild += childCount
        frontier += 1
    }
    func materialize(_ index: Int) -> LayoutNode {
        var current = nodes[index]
        current.children = childrenOf[index].map(materialize)
        return current
    }
    return materialize(0)
}
