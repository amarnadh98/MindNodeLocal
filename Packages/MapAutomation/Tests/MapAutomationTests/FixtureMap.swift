import Foundation
import MapCore
import MapStudy
import Testing

@testable import MapAutomation

/// A throwaway package every test can build in a temp directory: the
/// canonical fixture the tool tests run against.
enum FixtureMap {
    /// root "Kitchen Reno" with children "Budget" (task open, tag
    /// "money") and "Paint colors" (task done, note), plus a grandchild.
    static func model() -> MapModel {
        var model = MapModel.emptyDocument(docID: "fixture-doc")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let tag = Tag(id: "tag-money", name: "money", color: "#E5484D")
        model.tags = [tag]

        func node(
            _ id: String, _ parent: String?, _ text: String, task: Bool? = nil, note: String? = nil,
            tags: [String]? = nil
        ) -> Node {
            var value = Node(
                id: id, parent: parent, title: NodeTitle(text: text),
                created: date, modified: date)
            value.note = note
            value.tags = tags
            if let task { value.task = NodeTask(done: task) }
            return value
        }

        model.nodes["root"] = node("root", nil, "Kitchen Reno")
        model.nodes["budget"] = node("budget", "root", "Budget", task: false, tags: ["tag-money"])
        model.nodes["paint"] = node("paint", "root", "Paint colors", task: true, note: "Sage maybe?")
        model.nodes["sage"] = node("sage", "paint", "Sage green", note: "warm light only")
        model.roots = ["root"]
        model.nodes["root"]?.children = ["budget", "paint"]
        model.nodes["paint"]?.children = ["sage"]
        return model
    }

    /// Writes the fixture as a package at `url` and returns its path.
    @discardableResult
    static func write(at url: URL) throws -> String {
        let meta = PackageMeta(
            formatVersion: ArborFormat.formatVersion,
            appVersion: "0.1.0",
            created: Date(timeIntervalSince1970: 1_800_000_000),
            modified: Date(timeIntervalSince1970: 1_800_000_000),
            docID: "fixture-doc"
        )
        try ArborPackage.write(model(), meta: meta, to: url)
        return url.path
    }

    /// A temp directory that cleans up after the test. Short name: the
    /// MCP socket tests bind a Unix socket inside it, and `sun_path`
    /// caps at 104 bytes.
    @discardableResult
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
