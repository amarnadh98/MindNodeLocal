import Foundation
import MapCore
import MapRender
import Testing

@testable import SceneExport

/// SVG export tests: the hand-written emitter's escaping (`&`, `<`,
/// quotes, emoji, CJK), XML well-formedness, the outlines-text option,
/// and a golden file for the canonical map.
struct SVGExporterTests {
    @Test func goldenCanonicalMap() throws {
        let model = ExportFixtures.canonicalMap()
        let scene = ExportFixtures.scene(for: model)
        let svg = SVGExporter.export(scene: scene, model: model)

        // `UPDATE_GOLDEN=1 swift test …` rewrites the committed golden from
        // the current output (review the diff before committing it).
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] != nil {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/canonical-map.svg")
            try svg.write(to: source, atomically: true, encoding: .utf8)
        }
        let goldenURL = try #require(
            Bundle.module.url(forResource: "canonical-map", withExtension: "svg", subdirectory: "Fixtures"))
        let golden = try String(contentsOf: goldenURL, encoding: .utf8)
        #expect(svg == golden)
    }

    @Test func escapesEntitiesAndCarriesEmojiAndCJK() throws {
        var model = MapModel.emptyDocument()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        // Every XML-significant character at once, plus emoji and CJK;
        // the run's quoted font family exercises attribute escaping too.
        // Short enough to stay on one rendered line.
        let tricky = #""<P & Q>" 🌳 中"#
        let root = Node(
            id: "tricky-root",
            title: NodeTitle(
                text: tricky,
                runs: [Run(range: [0, tricky.utf16.count], font: #"Fancy "Serif""#)]),
            created: timestamp, modified: timestamp)
        model.nodes["tricky-root"] = root
        model.roots = ["tricky-root"]

        let scene = ExportFixtures.scene(for: model)
        let svg = SVGExporter.export(scene: scene, model: model)

        // Text content escapes `&`, `<`, `>` (quotes are legal there)…
        #expect(svg.contains("\"&lt;P &amp; Q&gt;\" 🌳 中"))
        #expect(!svg.contains("P & Q>"))
        // …attribute values escape quotes as well…
        #expect(svg.contains(#"font-family="Fancy &quot;Serif&quot;""#))
        // …emoji and CJK pass through as UTF-8…
        #expect(svg.contains("🌳"))
        #expect(svg.contains("中"))
        // …and the whole document is well-formed XML.
        let parser = XMLParser(data: Data(svg.utf8))
        let parserDelegate = WellFormednessChecker()
        parser.delegate = parserDelegate
        #expect(parser.parse())
        #expect(parser.parserError == nil)
    }

    @Test func textAsOutlinesEmitsGlyphPathsInsteadOfTextElements() throws {
        let model = ExportFixtures.canonicalMap()
        let scene = ExportFixtures.scene(for: model)
        var options = SVGExportOptions()
        options.textAsOutlines = true
        let svg = SVGExporter.export(scene: scene, model: model, options: options)

        #expect(!svg.contains("<text"))
        // Every node contributed glyph paths.
        #expect(svg.contains("<path transform="))
        #expect(svg.contains("<g id="))
    }

    @Test func selectionSubtreeFiltersNodes() throws {
        let model = ExportFixtures.canonicalMap()
        let scene = ExportFixtures.scene(for: model)
        let svg = SVGExporter.export(
            scene: scene, model: model, content: .subtree(["alpha-node"]))

        #expect(svg.contains("Alpha Child"))
        #expect(!svg.contains("Beta"))
    }
}

private final class WellFormednessChecker: NSObject, XMLParserDelegate {
    @Test func theRoundedFamilyTokenBecomesARealCSSFontStack() {
        let stack = SVGSupport.fontFamily(FontSpec(size: 18, family: FontSpec.roundedFamily))
        #expect(stack.contains("ui-rounded"))
        #expect(!stack.contains("system-rounded"), "the internal token must never reach the SVG")
    }
}
