import Foundation
import Testing

@testable import MapCore

struct CommandPropertyTests {
    @Test func everyCommandRoundTripsThroughItsInverse() throws {
        for seed: UInt64 in 0..<200 {
            let model = randomModel(seed: seed)
            var generator = CommandGenerator(state: seed &+ 0x9E37)
            for command in try candidateCommands(for: model, generator: &generator) {
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
            var generator = CommandGenerator(state: seed &+ 0x517B)
            for command in try candidateCommands(for: model, generator: &generator) {
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
            var generator = CommandGenerator(state: seed &+ 0xD1B5)

            for _ in 0..<60 {
                let candidates = try candidateCommands(for: model, generator: &generator)
                guard let command = generator.pick(from: candidates) else { break }
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

    @Test func appliesKeepAllInvariants() throws {
        for seed: UInt64 in 0..<100 {
            var model = randomModel(seed: seed)
            var generator = CommandGenerator(state: seed &+ 0x2545)
            for command in try candidateCommands(for: model, generator: &generator) {
                guard (try? command.apply(to: &model)) != nil else { continue }
                let errors = MapValidator.validate(model)
                if !errors.isEmpty {
                    Issue.record("seed \(seed): \(command) broke invariants: \(errors)")
                    return
                }
            }
        }
    }

    /// A few valid commands for the given model: one per kind, targeting
    /// seeded-random nodes. Everything is derived from `generator`, so a
    /// failing seed reproduces exactly.
    private func candidateCommands(
        for model: MapModel, generator: inout CommandGenerator
    ) throws -> [MapCommand] {
        guard let node = generator.pick(from: Array(model.nodes.values)) else { return [] }
        let nodeID = node.id
        var commands = unconditionalCommands(nodeID: nodeID, model: model, generator: &generator)
        commands.append(
            contentsOf: conditionalCommands(nodeID: nodeID, node: node, model: model, generator: &generator))
        commands.append(
            contentsOf: contentCommands(nodeID: nodeID, node: node, model: model, generator: &generator))
        return commands.filter { command in
            (try? command.inverse(in: model)) != nil
        }
    }

    private func unconditionalCommands(
        nodeID: String, model: MapModel, generator: inout CommandGenerator
    ) -> [MapCommand] {
        [
            .addChild(
                parent: nodeID, index: nil,
                node: Node(id: "g\(generator.next())", title: NodeTitle(text: "c"))),
            .addSibling(
                anchor: nodeID, before: generator.next() % 2 == 0,
                node: Node(id: "g\(generator.next())", title: NodeTitle(text: "s"))),
            .insertParent(
                anchor: nodeID, node: Node(id: "g\(generator.next())", title: NodeTitle(text: "p"))),
            .addRoot(
                index: nil, node: Node(id: "g\(generator.next())", title: NodeTitle(text: "r"))),
            .deleteSubtrees(ids: [nodeID]),
            .deleteNodePromotingChildren(id: nodeID),
            .editText(id: nodeID, title: NodeTitle(text: "renamed \(generator.next())")),
            .setNote(id: nodeID, note: generator.next() % 2 == 0 ? "note \(generator.next())" : nil),
            .reorderSibling(id: nodeID, delta: Int(generator.next() % 5) - 2),
            .promote(id: nodeID),
            .setSide(id: nodeID, side: generator.next() % 2 == 0 ? .left : .right),
            .setFolded(id: nodeID, folded: generator.next() % 2 == 0),
            .setOffset(id: nodeID, offset: ModelOffset(x: 10, y: -5)),
            .setTheme(id: generator.next() % 2 == 0 ? "ocean" : nil),
            // F-STY-6: the per-document appearance override.
            .setAppearance(mode: generator.next() % 2 == 0 ? .light : .dark),
            .setStudy(
                name: "Grade Card", id: nodeID,
                study: NodeStudy(
                    card: generator.next() % 2 == 0 ? .on : .auto,
                    fsrs: FSRSState(due: fixedDate, reps: Int(generator.next() % 5)),
                    fsrsByCard: generator.next() % 2 == 0
                        ? ["r": FSRSState(due: fixedDate, state: .review)] : nil,
                    deck: generator.next() % 2 == 0)),
            .recolorBranches(
                assignments: [
                    PaletteIndexAssignment(
                        id: nodeID,
                        index: generator.next() % 2 == 0 ? Int(generator.next() % 8) : nil)
                ]),
            .setAIPolicy(
                policy: generator.next() % 2 == 0
                    ? DocumentAIPolicy(neverSendToCloud: generator.next() % 2 == 0)
                    : nil),
            .setNote(id: nodeID, note: generator.next() % 2 == 0 ? "note \(generator.next())" : nil),
            .setTitle(generator.next() % 2 == 0 ? "title \(generator.next())" : nil),
            // M3 content commands (links/tasks/tags): exercised the
            // same way — apply∘inverse identity over fuzzed trees.
            .setLink(
                id: nodeID,
                link: generator.next() % 2 == 0 ? "https://example.com/\(generator.next() % 100)" : nil),
            .setTaskValue(
                id: nodeID,
                task: generator.next() % 3 == 0
                    ? nil
                    : NodeTask(
                        done: generator.next() % 2 == 0,
                        due: generator.next() % 2 == 0 ? "2026-12-01" : nil,
                        priority: Int(generator.next() % 3) + 1)),
            .setNodeTags(
                id: nodeID,
                tags: generator.next() % 3 == 0
                    ? nil
                    : (0..<Int(generator.next() % 3)).map { "t\($0)" }),
            // M3 media/content commands (F-CNT-2/3/5/7/8, F-TAG-3):
            // the same apply∘inverse identity over fuzzed trees.
            .setImage(
                id: nodeID,
                image: generator.next() % 3 == 0
                    ? nil
                    : NodeImage(
                        asset: "abc\(generator.next() % 9).png",
                        size: [Double(generator.next() % 200) + 20, 120],
                        placement: generator.next() % 2 == 0 ? .above : .left)),
            .setMarkers(
                id: nodeID,
                markers: generator.next() % 3 == 0
                    ? nil
                    : (0..<Int(generator.next() % 3)).map {
                        ["sf:star.fill", "emoji:💡", "sticker:priority-\($0 + 1)"][$0 % 3]
                    }),
            .setAttachments(
                id: nodeID,
                attachments: generator.next() % 3 == 0
                    ? nil
                    : [Attachment(asset: "def\(generator.next() % 9).pdf", name: "Paper.pdf")]),
            .setSource(
                id: nodeID,
                source: generator.next() % 3 == 0
                    ? nil
                    : SourceRef(
                        url: "https://example.com/a\(generator.next() % 50)",
                        page: generator.next() % 2 == 0 ? Int(generator.next() % 300) : nil,
                        time: generator.next() % 2 == 0 ? Double(generator.next() % 600) : nil)),
            .setMath(id: nodeID, math: generator.next() % 2 == 0),
            .setFilters(
                generator.next() % 3 == 0
                    ? nil
                    : [SavedFilter(id: "f\(generator.next())", name: "due", query: "is:task")]),
            (try? MapCommand.duplicate(id: nodeID, in: model)),
            // M6 (F-PRE-2/3): a wholesale presentation-list replace; the
            // inverse restores the pre-state list exactly.
            .setPresentations(
                model.presentations.map { list in
                    var updated = list
                    updated.append(
                        Presentation(
                            id: "p\(generator.next())", name: "Deck",
                            slides: [Slide(id: "s\(generator.next())", title: "slide")]))
                    return updated
                } ?? [
                    Presentation(
                        id: "p\(generator.next())", name: "Deck",
                        slides: [Slide(id: "s\(generator.next())", title: "slide")])
                ]),
        ].compactMap { $0 } + relationCommands(nodeID: nodeID, model: model, generator: &generator)
    }

    /// The fine-grained relation commands (F-REL-1/2/3): created against
    /// live ids, plus the edit/remove paths exercised against ids that
    /// exist in the current model.
    private func relationCommands(
        nodeID: String, model: MapModel, generator: inout CommandGenerator
    ) -> [MapCommand] {
        var commands: [MapCommand] = []
        let others = Array(model.nodes.keys).filter { $0 != nodeID }
        if let other = generator.pick(from: others) {
            commands.append(
                .addConnection(
                    Connection(
                        id: "gc-\(generator.next())", from: nodeID, to: other,
                        label: generator.next() % 2 == 0 ? "link" : nil,
                        control: ModelOffset(x: 8, y: -4))))
            commands.append(
                .addBoundary(Boundary(id: "gb-\(generator.next())", nodes: [nodeID, other])))
            if let summaryParent = model.nodes[nodeID]?.parent,
                let firstChild = model.nodes[summaryParent]?.children.first
            {
                commands.append(
                    .addSummary(
                        Summary(
                            id: "gs-\(generator.next())", parent: summaryParent,
                            range: [firstChild], node: nodeID)))
            }
        }
        if let connection = generator.pick(from: model.connections ?? []) {
            commands.append(.editConnection(id: connection.id, connection: connection))
            commands.append(.removeConnection(id: connection.id))
        }
        if let boundary = generator.pick(from: model.boundaries ?? []) {
            commands.append(.editBoundary(id: boundary.id, boundary: boundary))
            commands.append(.removeBoundary(id: boundary.id))
        }
        if let summary = generator.pick(from: model.summaries ?? []) {
            commands.append(.removeSummary(id: summary.id))
        }
        // Absent ids: remove no-ops must invert to no-ops.
        commands.append(.removeConnection(id: "missing"))
        commands.append(.removeBoundary(id: "missing"))
        commands.append(.removeSummary(id: "missing"))
        return commands
    }

    /// Content commands that need their target to exist in a given
    /// state (a task for `setTaskDone`, a document tag for
    /// `toggleTag`) — always valid over the fuzzed fixtures, which
    /// seed at least one task and one tag definition.
    private func contentCommands(
        nodeID: String, node: Node, model: MapModel, generator: inout CommandGenerator
    ) -> [MapCommand] {
        var commands: [MapCommand] = []
        let tagID = model.tags?.first?.id ?? "t0"
        commands.append(.setTask(ids: [nodeID], isTask: generator.next() % 2 == 0))
        if node.task != nil {
            commands.append(.setTaskDone(ids: [nodeID], done: generator.next() % 2 == 0))
            commands.append(
                .setTaskDetails(
                    id: nodeID,
                    due: generator.next() % 2 == 0 ? "2027-01-15" : nil,
                    priority: generator.next() % 2 == 0 ? Int(generator.next() % 3) + 1 : nil,
                    repeat: generator.next() % 2 == 0 ? "weekly" : nil))
        }
        commands.append(.toggleTag(ids: [nodeID], tagID: tagID, assigned: generator.next() % 2 == 0))
        let second = generator.pick(from: Array(model.nodes.keys)) ?? nodeID
        if second != nodeID {
            commands.append(.toggleTag(ids: [nodeID, second], tagID: tagID, assigned: true))
        }
        if let tag = model.tags?.first {
            commands.append(
                .setTags(
                    (model.tags ?? []).map { $0.id == tag.id ? Tag(id: $0.id, name: "renamed", color: "#E5484D") : $0 })
            )
            if let delete = try? MapCommand.deleteTag(id: tag.id, in: model) {
                commands.append(delete)
            }
        }
        return commands
    }

    private func conditionalCommands(
        nodeID: String, node: Node, model: MapModel, generator: inout CommandGenerator
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

        let allIDs = Array(model.nodes.keys)
        if allIDs.count >= 2 {
            var multiDelete: [String] = [nodeID]
            let second = generator.pick(from: allIDs) ?? nodeID
            multiDelete.append(second)
            if allIDs.count >= 3, generator.next() % 2 == 0 {
                multiDelete.append(generator.pick(from: allIDs) ?? nodeID)
            }
            commands.append(.deleteSubtrees(ids: multiDelete))
        }
        return commands
    }
}

let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

func randomModel(seed: UInt64) -> MapModel {
    var generator = CommandGenerator(state: seed)
    var model = MapModel.emptyDocument(docID: "seed-\(seed)")
    var frontier: [String] = []
    let rootID = "n0"
    model.nodes[rootID] = Node(id: rootID, title: NodeTitle(text: "root"), created: fixedDate, modified: fixedDate)
    model.roots = [rootID]
    frontier = [rootID]
    var counter = 1

    while counter < 40, !frontier.isEmpty {
        let parent = frontier.removeFirst()
        let childCount = generator.count(in: 0...4)
        for _ in 0..<childCount where counter < 40 {
            let id = "n\(counter)"
            counter += 1
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: "node \(id)"),
                created: fixedDate, modified: fixedDate)
            model.nodes[parent]?.children.append(id)
            frontier.append(id)
        }
    }

    let ids = Array(model.nodes.keys)
    let connectionCount = generator.count(in: 0...3)
    var connections: [Connection] = []
    for index in 0..<connectionCount where ids.count >= 2 {
        let from = ids[index % ids.count]
        let to = ids[(index + 1) % ids.count]
        if from != to {
            connections.append(Connection(id: "conn-\(index)", from: from, to: to))
        }
    }
    model.connections = connections.isEmpty ? nil : connections

    if ids.count >= 3 {
        model.boundaries = [
            Boundary(id: "bd-0", nodes: [ids[1], ids[2]], title: "scope")
        ]
    }
    let rootChildren = model.nodes[rootID]?.children ?? []
    if rootChildren.count >= 2 {
        model.summaries = [
            Summary(
                id: "sm-0", parent: rootID,
                range: [rootChildren[0], rootChildren[1]], node: ids[3 % ids.count])
        ]
    }

    // M3 fixtures: a couple of task nodes, a couple of tag definitions
    // and assignments, so the content commands have real targets.
    model.tags = [
        Tag(id: "t0", name: "exam", color: "#E5484D"),
        Tag(id: "t1", name: "later", color: "#46A758"),
    ]
    for (index, id) in ids.enumerated() {
        if index % 7 == 1 {
            model.nodes[id]?.task = NodeTask(done: index % 14 == 1)
        }
        if index % 5 == 2 {
            model.nodes[id]?.tags = [index % 2 == 0 ? "t0" : "t1"]
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

    mutating func pick<T>(from items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[Int(next() % UInt64(items.count))]
    }
}
