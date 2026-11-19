import Foundation
import MapCore
import Testing

@testable import MapAutomation

/// F-INT-4/1 closed-document edits: one coordinated read → commands →
/// ONE atomic write; a failing command leaves the file byte-identical;
/// the model stays valid; author stamps land.
struct HeadlessMapEditorTests {
    @Test func applyStampsAuthorAndKeepsModelValid() throws {
        let directory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Reno.arbor")
        try FixtureMap.write(at: url)

        try HeadlessMapEditor.apply(
            [
                .addChild(
                    parent: "root", index: nil,
                    node: Node(id: "new-1", title: NodeTitle(text: "Contractor")))
            ],
            at: url, author: .mcp)

        let contents = try HeadlessMapEditor.read(at: url)
        #expect(contents.model.nodes["new-1"]?.parent == "root")
        #expect(contents.model.nodes["new-1"]?.modifiedBy == .mcp)
        #expect(contents.validationErrors.isEmpty)
        // The untouched nodes keep their stamps; the parent's children
        // list changed, so it is stamped mcp like the new node.
        #expect(contents.model.nodes["root"]?.modifiedBy == .mcp)
        #expect(contents.model.nodes["paint"]?.modifiedBy == .user)
        // meta.json was refreshed.
        #expect(contents.meta.docID == contents.model.docID)
    }

    @Test func oneAtomicWriteNoPartialStateOnFailure() throws {
        let directory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Reno.arbor")
        try FixtureMap.write(at: url)
        let before = try HeadlessMapEditor.read(at: url).model

        // The second command is invalid (missing node): nothing may land.
        #expect(throws: Error.self) {
            try HeadlessMapEditor.apply(
                [
                    .addChild(
                        parent: "root", index: nil,
                        node: Node(id: "new-2", title: NodeTitle(text: "will not persist"))),
                    .editText(id: "does-not-exist", title: NodeTitle(text: "boom")),
                ],
                at: url, author: .mcp)
        }
        let after = try HeadlessMapEditor.read(at: url).model
        #expect(after == before)
        #expect(after.nodes["new-2"] == nil)
    }

    @Test func foreignEntriesSurviveTheWrite() throws {
        let directory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Reno.arbor")
        try FixtureMap.write(at: url)
        // An asset and a review log stand in for everything MapDocument
        // would write but the automation does not manage.
        let asset = url.appendingPathComponent("assets/abc.txt")
        try FileManager.default.createDirectory(
            at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("image-bytes".utf8).write(to: asset)
        let log = url.appendingPathComponent("study/reviews.jsonl")
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            #"{"cardID":"root","elapsed":0,"grade":"good","stateAfter":"review","stateBefore":"new","ts":"2026-11-19T10:00:00.000Z"}"#
                .utf8
        )
        .write(to: log)

        try HeadlessMapEditor.apply(
            [.editText(id: "root", title: NodeTitle(text: "Loft Reno"))],
            at: url, author: .mcp)

        #expect(String(decoding: try Data(contentsOf: asset), as: UTF8.self) == "image-bytes")
        #expect(try HeadlessMapEditor.readReviews(at: url).count == 1)
        #expect(try HeadlessMapEditor.read(at: url).model.nodes["root"]?.title.text == "Loft Reno")
    }

    @Test func writeNewCreatesAValidPackage() throws {
        let directory = try FixtureMap.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Fresh.arbor")
        var model = try OutlineConversion.importModel(from: "Goals\n\tShip v1")
        model.docID = "fresh-doc"

        try HeadlessMapEditor.writeNew(
            model: model, at: url, author: .mcp, appVersion: "0.1.0")

        let contents = try HeadlessMapEditor.read(at: url)
        #expect(contents.model.docID == "fresh-doc")
        #expect(contents.model.nodes[contents.model.roots[0]]?.title.text == "Goals")
        #expect(contents.validationErrors.isEmpty)
    }

    @Test func updateNodeCommandsRoundTripExactly() throws {
        var model = FixtureMap.model()
        let before = model
        var task = model.nodes["paint"]?.task ?? NodeTask()
        task.done = false
        let commands: [MapCommand] = [
            .setNote(id: "paint", note: "changed note"),
            .setTask(id: "paint", task: task),
            .setTask(id: "budget", task: nil),
        ]
        for command in commands {
            let inverse = try command.inverse(in: model)
            try command.apply(to: &model)
            try inverse.apply(to: &model)
        }
        #expect(model == before)
    }
}
