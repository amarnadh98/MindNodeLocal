import Foundation
import Testing

@testable import MapCore

@Test func cleanModelNeedsNoRepair() throws {
    let model = try sampleTree()
    let result = MapRepairer.repair(model)
    #expect(result.applied.isEmpty)
    #expect(result.remaining.isEmpty)
    #expect(result.model == model)
}

@Test func missingRootIsRemoved() throws {
    var model = try sampleTree()
    model.roots.append("ghost-root")
    let result = MapRepairer.repair(model)
    #expect(!result.model.roots.contains("ghost-root"))
    #expect(
        result.applied.contains { if case .removedMissingRoot(let id) = $0 { id == "ghost-root" } else { false } })
    #expect(result.remaining.isEmpty)
}

@Test func duplicateRootIsDeduplicated() throws {
    var model = try sampleTree()
    model.roots.append(model.roots[0])
    let result = MapRepairer.repair(model)
    #expect(result.model.roots.filter { $0 == model.roots[0] }.count == 1)
    #expect(result.applied.contains { if case .removedDuplicateRoot = $0 { true } else { false } })
    #expect(result.remaining.isEmpty)
}

@Test func rootWithParentIsDetached() throws {
    var model = try sampleTree()
    let rootID = model.roots[0]
    let firstChild = model.nodes[rootID]!.children[0]
    model.nodes[rootID]!.parent = firstChild
    let result = MapRepairer.repair(model)
    #expect(result.model.nodes[rootID]?.parent == nil)
    #expect(result.applied.contains { if case .clearedParentOfRoot(let id) = $0 { id == rootID } else { false } })
}

@Test func orphanAndDanglingParentArePromotedToRoots() throws {
    var model = try sampleTree()
    let orphanID = UUID().uuidString
    model.nodes[orphanID] = Node(id: orphanID)
    let danglingID = UUID().uuidString
    model.nodes[danglingID] = Node(id: danglingID, parent: "no-such-parent")

    let result = MapRepairer.repair(model)

    #expect(result.model.roots.contains(orphanID))
    #expect(result.model.roots.contains(danglingID))
    #expect(result.model.nodes[orphanID]?.parent == nil)
    #expect(result.model.nodes[danglingID]?.parent == nil)
    #expect(result.remaining.isEmpty)
}

@Test func danglingChildReferenceIsRemoved() throws {
    var model = try sampleTree()
    let rootID = model.roots[0]
    model.nodes[rootID]?.children.append("ghost-child")
    let result = MapRepairer.repair(model)
    #expect(result.model.nodes[rootID]?.children.contains("ghost-child") == false)
    #expect(result.remaining.isEmpty)
}

@Test func parentChildMismatchResyncsBothWays() throws {
    var model = try sampleTree()
    let rootID = model.roots[0]
    let firstChild = model.nodes[rootID]!.children[0]
    let secondChild = model.nodes[rootID]!.children[1]
    model.nodes[rootID]?.children.removeFirst()
    model.nodes[secondChild]?.parent = firstChild

    let result = MapRepairer.repair(model)

    #expect(result.model.nodes[firstChild]?.children.contains(secondChild) == true)
    #expect(result.model.nodes[secondChild]?.parent == firstChild)
    #expect(result.model.nodes[rootID]?.children.contains(firstChild) == true)
    #expect(result.model.nodes[rootID]?.children.contains(secondChild) == false)
    #expect(result.remaining.isEmpty)
}

@Test func connectionWithMissingEndpointIsDropped() throws {
    var model = try sampleTree()
    let rootID = model.roots[0]
    let goodID = UUID().uuidString
    let badID = UUID().uuidString
    model.connections = [
        Connection(id: goodID, from: rootID, to: model.nodes[rootID]!.children[0]),
        Connection(id: badID, from: rootID, to: "ghost"),
    ]
    let result = MapRepairer.repair(model)
    #expect(result.model.connections?.count == 1)
    #expect(result.model.connections?.first?.id == goodID)
    #expect(result.applied.contains { if case .droppedConnection = $0 { true } else { false } })
    #expect(result.remaining.isEmpty)
}

@Test func boundaryWithOnlyMissingNodesIsDropped() throws {
    var model = try sampleTree()
    model.boundaries = [Boundary(id: UUID().uuidString, nodes: ["ghost-1", "ghost-2"])]
    let result = MapRepairer.repair(model)
    #expect(result.model.boundaries?.isEmpty != false)
    #expect(result.applied.contains { if case .droppedBoundary = $0 { true } else { false } })
    #expect(result.applied.contains { if case .removedBoundaryNode = $0 { true } else { false } })
}

@Test func summaryWithBrokenRangeIsDropped() throws {
    var model = try sampleTree()
    let rootID = model.roots[0]
    model.summaries = [
        Summary(id: UUID().uuidString, parent: rootID, range: ["ghost", "ghost"], node: rootID)
    ]
    let result = MapRepairer.repair(model)
    #expect(result.model.summaries?.isEmpty != false)
    #expect(result.applied.contains { if case .droppedSummary = $0 { true } else { false } })
}

@Test func danglingTagReferenceIsRemoved() throws {
    var model = try sampleTree()
    let rootID = model.roots[0]
    let goodTag = UUID().uuidString
    model.tags = [Tag(id: goodTag, name: "real", color: "#E5484D")]
    model.nodes[rootID]?.tags = [goodTag, "ghost-tag"]
    let result = MapRepairer.repair(model)
    #expect(result.model.nodes[rootID]?.tags == [goodTag])
    #expect(
        result.applied.contains {
            if case .removedTagReference(let nodeID, let tagID) = $0 {
                nodeID == rootID && tagID == "ghost-tag"
            } else {
                false
            }
        })
    #expect(result.remaining.isEmpty)
}

@Test func rootCycleIsBrokenAndDetachedCycleIsReported() throws {
    var model = try sampleTree()
    let rootID = model.roots[0]
    let firstChild = model.nodes[rootID]!.children[0]
    model.nodes[rootID]!.parent = firstChild
    model.nodes[firstChild]!.children.append(rootID)

    let nodeA = UUID().uuidString
    let nodeB = UUID().uuidString
    let nodeC = UUID().uuidString
    model.nodes[nodeA] = Node(id: nodeA, parent: nodeB)
    model.nodes[nodeB] = Node(id: nodeB, parent: nodeC)
    model.nodes[nodeC] = Node(id: nodeC, parent: nodeA)
    model.nodes[nodeA]?.children = [nodeC]
    model.nodes[nodeB]?.children = [nodeA]
    model.nodes[nodeC]?.children = [nodeB]

    let result = MapRepairer.repair(model)

    #expect(result.applied.contains { if case .clearedParentOfRoot(let id) = $0 { id == rootID } else { false } })
    #expect(result.model.nodes.count == model.nodes.count)
    let detached = [nodeA, nodeB, nodeC]
    #expect(
        result.remaining.contains {
            if case .unreachableNode(let id) = $0 { detached.contains(id) } else { false }
        })
    #expect(result.remaining.contains { if case .cycle = $0 { true } else { false } })
}
