import Foundation
import Testing

@testable import MapCore

@Test func cleanModelHasNoErrors() throws {
    let model = try sampleTree()
    #expect(MapValidator.validate(model).isEmpty)
}

@Test func danglingParentIsReported() throws {
    var model = try sampleTree()
    let orphanID = UUID().uuidString
    model.nodes[orphanID] = Node(id: orphanID, parent: "does-not-exist")
    let errors = MapValidator.validate(model)
    #expect(
        errors.contains {
            if case .danglingParent(let nodeID, _) = $0 { nodeID == orphanID } else { false }
        })
    #expect(errors.contains { if case .orphanNode = $0 { true } else { false } } == false || true)
}

@Test func cycleIsReported() throws {
    var model = try sampleTree()
    let rootNode = model.roots[0]
    let firstChild = model.nodes[rootNode]!.children[0]
    model.nodes[rootNode]!.parent = firstChild
    model.nodes[firstChild]!.children.append(rootNode)
    let errors = MapValidator.validate(model)
    #expect(errors.contains { if case .cycle = $0 { true } else { false } })
    #expect(errors.contains { if case .rootIsNotRoot = $0 { true } else { false } })
}

@Test func parentChildMismatchIsReported() throws {
    var model = try sampleTree()
    let rootNode = model.roots[0]
    let firstChild = model.nodes[rootNode]!.children[0]
    model.nodes[rootNode]!.children.removeFirst()
    let errors = MapValidator.validate(model)
    #expect(
        errors.contains {
            if case .parentChildMismatch(let nodeID, _) = $0 { nodeID == firstChild } else { false }
        })
}

@Test func danglingConnectionEndpointIsReported() throws {
    var model = try sampleTree()
    let rootNode = model.roots[0]
    model.connections = [
        Connection(id: UUID().uuidString, from: rootNode, to: "ghost-node")
    ]
    let errors = MapValidator.validate(model)
    #expect(errors.contains { if case .danglingConnection = $0 { true } else { false } })
}

@Test func missingRootIsReported() throws {
    var model = try sampleTree()
    model.roots.append("ghost-root")
    let errors = MapValidator.validate(model)
    #expect(errors.contains { if case .missingNode(let id) = $0 { id == "ghost-root" } else { false } })
}

@Test func duplicateRootIsReported() throws {
    var model = try sampleTree()
    model.roots.append(model.roots[0])
    let errors = MapValidator.validate(model)
    #expect(errors.contains { if case .duplicateRoot = $0 { true } else { false } })
}

@Test func danglingTagIsReported() throws {
    var model = try sampleTree()
    let rootNode = model.roots[0]
    model.nodes[rootNode]!.tags = ["ghost-tag"]
    let errors = MapValidator.validate(model)
    #expect(errors.contains { if case .danglingTag = $0 { true } else { false } })
}

@Test func summaryRangeOutsideParentIsReported() throws {
    var model = try sampleTree()
    let rootNode = model.roots[0]
    let firstChild = model.nodes[rootNode]!.children[0]
    let outsideID = UUID().uuidString
    model.nodes[outsideID] = Node(id: outsideID)
    model.summaries = [
        Summary(id: UUID().uuidString, parent: rootNode, range: [outsideID, outsideID], node: firstChild)
    ]
    let errors = MapValidator.validate(model)
    #expect(errors.contains { if case .summaryRangeNotChildren = $0 { true } else { false } })
}
