import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// Pure relation-command builder tests (F-REL-1/2/3): the builders'
/// validation rules (self/missing/duplicate connections, one-family
/// boundaries, consecutive-sibling summaries) and the handle-edit
/// commands' exact undo round trips — split out of
/// `RelationGeometryTests` to keep both bodies reviewable.
@MainActor
struct RelationCommandTests {
    private func sceneModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "relations")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ id: String, parent: String?, title: String) {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: title),
                created: date, modified: date)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        add("root", parent: nil, title: "Root")
        add("a", parent: "root", title: "Alpha")
        add("b", parent: "root", title: "Beta")
        add("c", parent: "root", title: "Gamma")
        add("a1", parent: "a", title: "Alpha child")
        return model
    }

    @Test func relationCommandBuildersValidate() throws {
        let model = sceneModel()
        // Connections: self, missing and duplicate pairs refuse.
        #expect(RelationCommands.connect(model: model, from: "a", to: "a") == nil)
        #expect(RelationCommands.connect(model: model, from: "a", to: "missing") == nil)
        let connect = try #require(RelationCommands.connect(model: model, from: "a", to: "b"))
        var connected = model
        try connect.apply(to: &connected)
        #expect(RelationCommands.connect(model: connected, from: "b", to: "a") == nil)
        #expect(RelationCommands.connect(model: connected, from: "a", to: "b") == nil)

        // Boundaries: siblings group; unrelated nodes refuse.
        #expect(RelationCommands.boundary(selection: ["a", "b"], in: model) != nil)
        #expect(RelationCommands.boundary(selection: ["a"], in: model) != nil)
        #expect(RelationCommands.boundary(selection: ["a", "root"], in: model) == nil)

        // Summaries: consecutive siblings summarize; mixed parents
        // refuse. The span covers the intermediate sibling.
        let summary = try #require(RelationCommands.summary(selection: ["a", "c"], in: model))
        var summarized = model
        try summary.apply(to: &summarized)
        let record = try #require(summarized.summaries?.first)
        #expect(record.parent == "root")
        #expect(record.range == ["a", "b", "c"])
        #expect(summarized.nodes[record.node]?.parent == "root")
        #expect(
            RelationCommands.summary(selection: ["a", "a1"], in: model) == nil)

        // Label commit: no-op on the same text registers nothing;
        // whitespace-only clears a set label.
        let labeled = Connection(id: "conn", from: "a", to: "b", label: "same")
        #expect(RelationCommands.setLabel(connection: labeled, label: "same") == nil)
        let unlabeled = Connection(id: "conn", from: "a", to: "b")
        #expect(RelationCommands.setLabel(connection: unlabeled, label: "  ") == nil)
        let renamed = try #require(RelationCommands.setLabel(connection: labeled, label: "new"))
        var edited = model
        edited.connections = [labeled]
        try renamed.apply(to: &edited)
        #expect(edited.connections?.first?.label == "new")
    }

    @Test func moveHandleAndResetCommandsRoundTrip() throws {
        let connection = Connection(id: "conn", from: "a", to: "b", control: ModelOffset(x: 5, y: 5))
        let anchors = (from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 40))
        let move = RelationCommands.moveHandle(
            connection: connection, handlePoint: CGPoint(x: 60, y: -10), anchors: anchors)
        var model = sceneModel()
        model.connections = [connection]
        var working = model
        try move.apply(to: &working)
        // The stored offset is the exact inversion of
        // handle = (midpoint + control) / 2.
        let midpoint = CGPoint(x: 50, y: 20)
        let defaultControl = RelationPath.defaultControl(from: anchors.from, to: anchors.to)
        let expected = ModelOffset(
            x: 2 * 60 - midpoint.x - defaultControl.x,
            y: 2 * -10 - midpoint.y - defaultControl.y)
        #expect(working.connections?.first?.control == expected)

        // Undo restores the previous offset exactly.
        let inverse = try move.inverse(in: model)
        try inverse.apply(to: &working)
        #expect(working == model)

        // Double-click reset clears the stored offset; a connection
        // without one resets to a no-op that registers nothing.
        let reset = RelationCommands.resetHandle(connection: connection)
        try reset.apply(to: &working)
        #expect(working.connections?.first?.control == nil)
        let plain = Connection(id: "conn", from: "a", to: "b")
        var second = model
        second.connections = [plain]
        let beforeNoop = second
        let noop = RelationCommands.resetHandle(connection: plain)
        try noop.apply(to: &second)
        #expect(second == beforeNoop)
    }
}
