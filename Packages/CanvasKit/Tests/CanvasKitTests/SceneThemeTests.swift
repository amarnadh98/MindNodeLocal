import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// F-STY-3/F-STY-4 at the scene level: the canvas resolves styles from
/// the document's theme selection, and the persistent palette index
/// (ADR-0009) keeps branch colors stable regardless of sibling order.
struct SceneThemeTests {
    private func themedModel(themeID: String?) -> MapModel {
        var model = MapModel.emptyDocument(docID: "theme")
        if let themeID {
            model.theme = ThemeSelection(id: themeID)
        }
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "root"), created: sceneDate, modified: sceneDate)
        model.roots = [rootID]
        for (index, id) in ["branch-0", "branch-1", "branch-2"].enumerated() {
            model.nodes[id] = Node(
                id: id, parent: rootID, title: NodeTitle(text: id),
                created: sceneDate, modified: sceneDate)
            model.nodes[rootID]?.children.append(id)
        }
        return model
    }

    @Test func sceneResolvesTheDocumentsTheme() throws {
        let model = themedModel(themeID: "ocean")
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let ocean = BuiltInThemes.theme(id: "ocean")
        #expect(
            PaperTheme.hex(of: try #require(scene.canvasColor))
                == PaperTheme.hex(of: ocean.canvasColor(for: .light)))

        let branchEdge = try #require(scene.branches.first { $0.childID == "branch-1" })
        #expect(
            PaperTheme.hex(of: try #require(branchEdge.color))
                == PaperTheme.hex(of: ocean.branchColor(level1Index: 1, variant: .light)))
        #expect(branchEdge.tapered == (ocean.branch.lineStyle == .tapered))

        let rootNode = try #require(scene.nodes["root"])
        let rootFill = ocean.light.levels.root.fill
        guard case .solid(let fillHex) = rootFill else {
            Issue.record("ocean root fill must be solid")
            return
        }
        #expect(
            PaperTheme.hex(of: try #require(rootNode.style.fillColor))
                == PaperTheme.hex(of: try #require(ThemeHex.color(fillHex))))
    }

    @Test func unknownThemeIdFallsBackToPaper() throws {
        let model = themedModel(themeID: "no-such-theme")
        let scene = SceneGeometry.build(
            model: model, variant: .dark, measurer: SceneRenderer.sharedMeasurer)
        #expect(PaperTheme.hex(of: try #require(scene.canvasColor)) == PaperTheme.canvasDarkHex)
    }

    @Test func defaultDocumentUsesPaper() throws {
        let scene = SceneGeometry.build(
            model: themedModel(themeID: nil), variant: .light,
            measurer: SceneRenderer.sharedMeasurer)
        #expect(
            PaperTheme.hex(of: try #require(scene.canvasColor)) == PaperTheme.canvasLightHex)
    }

    @Test func storedPaletteIndexBeatsPosition() throws {
        var model = themedModel(themeID: nil)
        // Deliberately out of order: index 2 first, 0 last; branch-1 keeps
        // no stored index and falls back to its position.
        model.nodes["branch-0"]?.paletteIndex = 2
        model.nodes["branch-2"]?.paletteIndex = 0
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        #expect(try #require(scene.nodes["branch-0"]).level1Index == 2)
        #expect(try #require(scene.nodes["branch-1"]).level1Index == 1)
        #expect(try #require(scene.nodes["branch-2"]).level1Index == 0)
        let expected: [String: Int] = ["branch-0": 2, "branch-1": 1, "branch-2": 0]
        for (childID, stored) in expected {
            let edge = try #require(scene.branches.first { $0.childID == childID })
            #expect(
                PaperTheme.hex(of: try #require(edge.color))
                    == PaperTheme.hex(
                        of: BuiltInThemes.paper.branchColor(level1Index: stored, variant: .light)))
        }
    }

    @Test func missingIndicesFallBackToPosition() throws {
        let scene = SceneGeometry.build(
            model: themedModel(themeID: nil), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        for (position, childID) in ["branch-0", "branch-1", "branch-2"].enumerated() {
            #expect(try #require(scene.nodes[childID]).level1Index == position)
        }
    }

    @Test func nonRainbowThemeColorsEveryBranchWithPaletteZero() throws {
        let model = themedModel(themeID: "blueprint")
        let scene = SceneGeometry.build(
            model: model, variant: .dark, measurer: SceneRenderer.sharedMeasurer)
        let blueprint = BuiltInThemes.theme(id: "blueprint")
        let ink = try #require(ThemeHex.color(blueprint.dark.palette[0]))
        for edge in scene.branches {
            #expect(PaperTheme.hex(of: try #require(edge.color)) == PaperTheme.hex(of: ink))
        }
    }
}
