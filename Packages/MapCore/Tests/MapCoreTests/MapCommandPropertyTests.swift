import Foundation
import Testing

@testable import MapCore

struct CommandPropertyTests {
    @Test func everyCommandRoundTripsThroughItsInverse() throws {
        for seed: UInt64 in 0..<200 {
            let model = randomModel(seed: seed)
            for command in try candidateCommands(for: model) {
                let forward = try command.inverse(in: model)
                var applied = model
                try command.apply(to: &applied)

                var restored = applied
                try forward.apply(to: &restored)

                if restored != model {
                    Issue.record("seed \(seed): apply∘inverse ≠ identity for \(command)")
                }
            }
        }
    }

    @Test func redoAfterUndoRestoresTheEditedState() throws {
        for seed: UInt64 in 0..<100 {
            let model = randomModel(seed: seed)
            for command in try candidateCommands(for: model) {
                let undo = try command.inverse(in: model)

                var applied = model
                try command.apply(to: &applied)
                let redo = try undo.inverse(in: applied)

                var roundTripped = applied
                try undo.apply(to: &roundTripped)
                try redo.apply(to: &roundTripped)

                if roundTripped != applied {
                    Issue.record("seed \(seed): undo∘redo ≠ identity for \(command)")
                }
            }
        }
    }

    @Test func fuzzedSequencesSurviveFullUndo() throws {
        for seed: UInt64 in 0..<50 {
            var model = randomModel(seed: seed)
            let original = model
            var undoStack: [MapCommand] = []

            for _ in 0..<60 {
                let candidates = try candidateCommands(for: model)
                guard let command = candidates.randomElement() else { break }
                undoStack.append(try command.inverse(in: model))
                try command.apply(to: &model)
            }

            while let undo = undoStack.popLast() {
                try undo.apply(to: &model)
            }

            if model != original {
                Issue.record("seed \(seed): fuzzed undo did not restore the original model")
            }
        }
    }

    @Test func appliesKeepStructuralInvariants() throws {
        for seed: UInt64 in 0..<100 {
            var model = randomModel(seed: seed)
            for command in try candidateCommands(for: model) {
                guard (try? command.apply(to: &model)) != nil else { continue }
                let errors = MapValidator.validate(model)
                let structural = errors.filter { error in
                    switch error {
                    case .cycle, .unreachableNode, .orphanNode, .danglingParent, .danglingChild,
                        .parentChildMismatch, .duplicateChild, .duplicateRoot, .rootIsNotRoot,
                        .missingNode:
                        true
                    default: false
                    }
                }
                if !structural.isEmpty {
                    Issue.record("seed \(seed): \(command) broke invariants: \(structural)")
                    return
                }
            }
        }
    }

    private func randomNode(of model: MapModel) -> Node? {
        let ids = Array(model.nodes.keys)
        guard let id = ids.randomElement() else { return nil }
        return model.nodes[id]
    }

    /// A few valid commands for the given model: one per kind, targeting
    /// random nodes.
    private func candidateCommands(for model: MapModel) throws -> [MapCommand] {
        guard let node = randomNode(of: model) else { return [] }
        let nodeID = node.id
        var commands = unconditionalCommands(nodeID: nodeID, model: model)
        commands.append(contentsOf: conditionalCommands(nodeID: nodeID, node: node, model: model))
        return commands.filter { command in
            (try? command.inverse(in: model)) != nil
        }
    }

    private func unconditionalCommands(nodeID: String, model: MapModel) -> [MapCommand] {
        [
            .addChild(parent: nodeID, index: nil, node: Node(id: UUID().uuidString, title: NodeTitle(text: "c"))),
            .addSibling(
                anchor: nodeID, before: Bool.random(), node: Node(id: UUID().uuidString, title: NodeTitle(text: "s"))),
            .insertParent(anchor: nodeID, node: Node(id: UUID().uuidString, title: NodeTitle(text: "p"))),
            .addRoot(index: nil, node: Node(id: UUID().uuidString, title: NodeTitle(text: "r"))),
            .deleteSubtrees(ids: [nodeID]),
            .deleteNodePromotingChildren(id: nodeID),
            .editText(id: nodeID, title: NodeTitle(text: "renamed \(UUID().uuidString)")),
            .reorderSibling(id: nodeID, delta: Int.random(in: -2...2)),
            .promote(id: nodeID),
            .setSide(id: nodeID, side: Bool.random() ? .left : .right),
            .setFolded(id: nodeID, folded: Bool.random()),
            .setOffset(id: nodeID, offset: ModelOffset(x: 10, y: -5)),
            (try? MapCommand.duplicate(id: nodeID, in: model)),
        ].compactMap { $0 }
    }

    private func conditionalCommands(
        nodeID: String, node: Node, model: MapModel
    ) -> [MapCommand] {
        var commands: [MapCommand] = []
        if let parent = node.parent {
            if let slot = model.nodes[parent]?.children.firstIndex(of: nodeID), slot > 0 {
                commands.append(.demote(id: nodeID))
                commands.append(
                    .moveNode(id: nodeID, parent: model.nodes[parent]!.children[slot - 1], index: 0))
            }
        }
        if let parent = node.parent, let grandParent = model.nodes[parent]?.parent {
            commands.append(.moveNode(id: nodeID, parent: grandParent, index: 0))
        }
        if let parent = node.parent, model.nodes[parent]?.parent != nil {
            commands.append(.detach(id: nodeID))
        }
        return commands
    }
}

let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

func randomModel(seed: UInt64) -> MapModel {
    var generator = CommandGenerator(state: seed)
    var model = MapModel.emptyDocument(docID: "seed-\(seed)")
    var parents: [(String)] = []
    let rootID = "n0"
    model.nodes[rootID] = Node(id: rootID, title: NodeTitle(text: "root"), created: fixedDate, modified: fixedDate)
    model.roots = [rootID]
    parents = [rootID]
    var counter = 1

    while counter < 40, !parents.isEmpty {
        let parent = parents.removeFirst()
        let childCount = generator.count(in: 0...4)
        for _ in 0..<childCount where counter < 40 {
            let id = "n\(counter)"
            counter += 1
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: "node \(id)"),
                created: fixedDate, modified: fixedDate)
            model.nodes[parent]?.children.append(id)
            parents.append(id)
        }
    }
    return model
}

struct CommandGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func count(in range: ClosedRange<Int>) -> Int {
        Int(next() % UInt64(range.upperBound - range.lowerBound + 1)) + range.lowerBound
    }
}
