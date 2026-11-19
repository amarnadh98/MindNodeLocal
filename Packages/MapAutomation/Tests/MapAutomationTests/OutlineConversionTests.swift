import Foundation
import MapCore
import MapIO
import Testing

@testable import MapAutomation

/// Text → model/commands (the engine behind CreateMap, `new`, the
/// Services and MCP `add_nodes`/`create_map`).
struct OutlineConversionTests {
    @Test func detectsPlainMarkdownAndOPML() {
        #expect(OutlineConversion.detectFormat("Idea\n\tChild") == DocumentFormats.plainText)
        #expect(OutlineConversion.detectFormat("# Title\n- item") == DocumentFormats.markdown)
        #expect(OutlineConversion.detectFormat("<?xml version=\"1.0\"?><opml/>") == DocumentFormats.opml)
        #expect(OutlineConversion.detectFormat("   ") == nil)
    }

    @Test func importsIndentedText() throws {
        let model = try OutlineConversion.importModel(from: "Kitchen\n\tBudget\n\tPaint")
        #expect(model.roots.count == 1)
        #expect(model.nodes[model.roots[0]]?.children.count == 2)
        #expect(MapValidator.validate(model).isEmpty)
    }

    @Test func importsMarkdownTasks() throws {
        let model = try OutlineConversion.importModel(from: "# Trip\n\n- [ ] book hotel\n- [x] passport")
        let children = model.nodes[model.roots[0]]?.children ?? []
        #expect(children.count == 2)
        #expect(model.nodes[children[0]]?.task?.done == false)
        #expect(model.nodes[children[1]]?.task?.done == true)
    }

    @Test func emptyTextThrows() {
        #expect(throws: OutlineConversion.ConversionError.emptyText) {
            try OutlineConversion.importModel(from: "  \n ")
        }
    }

    @Test func insertCommandIsOneInsertSubtrees() throws {
        let target = FixtureMap.model()
        let command = try OutlineConversion.insertCommand(
            fromText: "Contractor\n\tQuotes", parent: "root", index: 2, in: target)
        guard case .insertSubtrees(let mapping, let anchors)? = command else {
            Issue.record("expected an insertSubtrees command")
            return
        }
        #expect(mapping.count == 2)
        #expect(anchors.count == 1)
        #expect(anchors[0].parent == "root")
        // Applied: two nodes under the root, one a child of the other.
        var working = target
        try command?.apply(to: &working)
        #expect(MapValidator.validate(working).isEmpty)
        let inserted = anchors[0].id
        #expect(working.nodes["root"]?.children.contains(inserted) == true)
        #expect(working.nodes[inserted]?.children.count == 1)
    }

    @Test func outlineJSONShape() throws {
        let json = try OutlineConversion.outlineJSON(from: FixtureMap.model())
        let outline = try JSONDecoder().decode([OutlineNode].self, from: Data(json.utf8))
        #expect(outline.count == 1)
        let root = outline[0]
        #expect(root.title == "Kitchen Reno")
        #expect(root.children.count == 2)
        let paint = root.children[1]
        #expect(paint.title == "Paint colors")
        #expect(paint.taskDone == true)
        #expect(paint.note == "Sage maybe?")
        #expect(paint.children.count == 1)
        let budget = root.children[0]
        #expect(budget.tags == ["money"])
        #expect(budget.taskDone == false)
    }

    @Test func markdownExportContainsTasksAndNotes() {
        let markdown = OutlineConversion.markdown(from: FixtureMap.model())
        #expect(markdown.contains("Kitchen Reno"))
        #expect(markdown.contains("- [x] Paint colors"))
        #expect(markdown.contains("Sage maybe?"))
    }
}
