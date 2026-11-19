import Foundation
import MapCore
import Testing

@testable import MapAI

/// F-AI-3: the level-by-level generator against a scripted provider
/// (two requests, flat `{text, parentIndex}` lists), and the
/// sketch → ONE grouped command mapping (F-AI-5).
struct MapGeneratorTests {
    private let levelOne = [
        "{\"text\":\"Optics\",\"parentIndex\":-1}\n",
        "{\"text\":\"Chlorophyll\",\"parentIndex\":-1}\n",
        "{\"text\":\"Stages\",\"parentIndex\":-1}\n",
    ]
    private let levelTwo = [
        "{\"text\":\"Light reactions\",\"parentIndex\":0}\n",
        "{\"text\":\"Chloroplasts\",\"parentIndex\":1}\n",
    ]

    private func model() throws -> MapModel {
        var model = MapModel.emptyDocument()
        let root = Node(id: "root", title: NodeTitle(text: "Seed"))
        model.nodes[root.id] = root
        model.roots = [root.id]
        return model
    }

    @Test func generatesTwoLevelsWithTwoRequests() async throws {
        let provider = ScriptedProvider(script: [levelOne, levelTwo])
        let sketch = try await MapSketchGenerator.generate(
            source: .topic("Photosynthesis"), provider: provider)
        #expect(sketch.centralTitle == "Photosynthesis")
        #expect(
            sketch.items.map(\.text) == ["Optics", "Chlorophyll", "Stages", "Light reactions", "Chloroplasts"])
        // Level-2 children address the level-1 items by their merged
        // list indexes.
        #expect(sketch.items[3].parentIndex == 0)
        #expect(sketch.items[4].parentIndex == 1)
        #expect(provider.servedRequests.count == 2)
        // Both prompts delimit the topic as data (SPEC §12 injection
        // guard) and answer JSON lines.
        #expect(provider.servedRequests[0].system == Prompts.listSystemPrompt)
        #expect(provider.servedRequests[0].prompt.contains("<topic>"))
    }

    @Test func sanitizerAttachesOrphansToTheCenter() {
        let dirty: [AIListItem] = [
            AIListItem(text: "good", parentIndex: nil),
            AIListItem(text: "orphan", parentIndex: 9),
            AIListItem(text: "later-parent", parentIndex: 2),
            AIListItem(text: "   ", parentIndex: nil),
            AIListItem(text: "valid child", parentIndex: 0),
        ]
        let sketch = SketchSanitizer.clean(dirty, centralTitle: "T")
        #expect(sketch.items.map(\.text) == ["good", "orphan", "later-parent", "valid child"])
        #expect(sketch.items.map(\.parentIndex) == [-1, -1, -1, 0])
    }

    @Test func refusalDuringGenerationThrows() async throws {
        let provider = ScriptedProvider(script: [levelOne], failure: AIError.refused)
        await #expect(throws: AIError.refused) {
            _ = try await MapSketchGenerator.generate(source: .topic("T"), provider: provider)
        }
    }

    @Test func fullSketchBecomesOneGroupedCommandWithExactTree() throws {
        let sketch = MapSketch(
            centralTitle: "Photosynthesis",
            items: [
                MapSketch.Item(text: "A", parentIndex: -1),
                MapSketch.Item(text: "B", parentIndex: -1),
                MapSketch.Item(text: "A1", parentIndex: 0),
            ])
        let model = try model()
        let command = SketchCommands.makeCommand(sketch: sketch, insertUnder: nil)
        var working = model
        try command.apply(to: &working)

        #expect(working.roots.count == 2)  // the seed root + the new map root
        let rootID = try #require(working.roots.last)
        #expect(working.nodes[rootID]?.title.text == "Photosynthesis")
        let children = working.nodes[rootID]?.children ?? []
        #expect(children.count == 2)
        #expect(working.nodes[children[0]]?.title.text == "A")
        #expect(working.nodes[children[1]]?.title.text == "B")
        #expect(working.nodes[children[0]]?.children.map { working.nodes[$0]?.title.text } == ["A1"])

        // One exact inverse restores the pre-state.
        let inverse = try command.inverse(in: model)
        try inverse.apply(to: &working)
        #expect(working == model)
    }

    @Test func insertUnderAddsNoRoot() throws {
        let sketch = MapSketch(
            centralTitle: "ignored here",
            items: [
                MapSketch.Item(text: "A", parentIndex: -1),
                MapSketch.Item(text: "A1", parentIndex: 0),
            ])
        let model = try model()
        let command = SketchCommands.makeCommand(sketch: sketch, insertUnder: "root")
        var working = model
        try command.apply(to: &working)
        #expect(working.roots == model.roots)
        let children = working.nodes["root"]?.children ?? []
        #expect(children.count == 1)
        #expect(working.nodes[children[0]]?.title.text == "A")
        #expect(working.nodes[children[0]]?.children.map { working.nodes[$0]?.title.text } == ["A1"])
    }

    @Test func generatedCommandPassesTheValidator() throws {
        let sketch = MapSketch(
            centralTitle: "Photosynthesis",
            items: [
                MapSketch.Item(text: "A", parentIndex: -1),
                MapSketch.Item(text: "A1", parentIndex: 0),
            ])
        var working = try model()
        try SketchCommands.makeCommand(sketch: sketch, insertUnder: nil).apply(to: &working)
        #expect(MapValidator.validate(working).isEmpty)
    }
}

/// F-AI-2: the expand-node request builder.
struct ExpandContextTests {
    private func tree() -> MapModel {
        var model = MapModel.emptyDocument()
        func add(_ id: String, _ parent: String?, _ text: String) {
            model.nodes[id] = Node(id: id, parent: parent, title: NodeTitle(text: text))
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        add("root", nil, "Root")
        add("plan", "root", "Plan")
        add("execute", "root", "Execute")
        add("steps", "plan", "Steps")
        return model
    }

    @Test func requestCarriesAncestorPathAndSiblings() throws {
        let request = try #require(ExpandContext.request(for: "steps", in: tree()))
        #expect(request.prompt.contains("Root"))
        #expect(request.prompt.contains("Plan"))
        #expect(request.prompt.contains("<map_data>"))
        // Siblings of "steps": none; ancestors: Root → Plan.
        #expect(ExpandContext.ancestorTitles(of: "steps", in: tree()) == ["Root", "Plan"])
        #expect(ExpandContext.siblingTitles(of: "steps", in: tree()) == [])
        #expect(ExpandContext.siblingTitles(of: "execute", in: tree()) == ["Plan"])
    }

    @Test func missingNodeYieldsNil() {
        #expect(ExpandContext.request(for: "gone", in: tree()) == nil)
    }

    @Test func rootSiblingsAreOtherRoots() {
        var model = tree()
        model.nodes["other"] = Node(id: "other", title: NodeTitle(text: "Other"))
        model.roots.append("other")
        #expect(ExpandContext.siblingTitles(of: "root", in: model) == ["Other"])
    }
}
