import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// F-STY-2/F-STY-3 at the scene level: per-node style overrides resolve
/// through `Theme.applyingOverrides` in `SceneGeometry` (measured sizes
/// included), branch overrides act on the connector from the node's
/// parent to it (ADR-0011), the rainbow-branches document override
/// collapses the palette, and nodes without overrides stay exactly at
/// their theme-resolved values.
@MainActor
struct SceneStyleOverrideTests {
    private func model() -> MapModel {
        var model = MapModel.emptyDocument(docID: "overrides")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "root"), created: date, modified: date)
        model.roots = [rootID]
        for (index, id) in ["one", "two"].enumerated() {
            model.nodes[id] = Node(
                id: id, parent: rootID, title: NodeTitle(text: id),
                created: date, modified: date)
            model.nodes[rootID]?.children.append(id)
            model.nodes["\(id)-leaf"] = Node(
                id: "\(id)-leaf", parent: id, title: NodeTitle(text: "leaf"),
                created: date, modified: date)
            model.nodes[id]?.children.append("\(id)-leaf")
        }
        return model
    }

    private func build(_ model: MapModel) -> CanvasScene {
        SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
    }

    @Test func nodeOverridesResolveIntoTheScene() throws {
        var model = model()
        model.nodes["one"]?.style = NodeStylePatch(
            shape: .diamond, fill: "#0090FF", padding: 20, shadow: .none, fontSize: 30)

        let scene = build(model)
        let styled = try #require(scene.nodes["one"])
        #expect(styled.style.shape == .diamond)
        #expect(PaperTheme.hex(of: try #require(styled.style.fillColor)) == 0x0090FF)
        #expect(styled.style.fontSizeEquals(30))
        #expect(styled.style.paddingWidth == 20)
        #expect(styled.style.shadows.isEmpty)

        // Siblings and the rest of the tree stay on the theme.
        let untouched = try #require(scene.nodes["two"])
        let paper = BuiltInThemes.theme(id: "paper")
        let themeStyle = paper.resolvedStyle(level: 1, level1Index: 1, variant: .light)
        #expect(untouched.style.shape == themeStyle.shape)
        #expect(untouched.style.font == themeStyle.font)
        #expect(untouched.style.paddingWidth == themeStyle.paddingWidth)
        #expect(
            PaperTheme.hex(of: untouched.style.fillColor ?? CGColor.black)
                == PaperTheme.hex(of: themeStyle.fillColor ?? CGColor.black))
    }

    @Test func overrideFontsGrowTheMeasuredFrame() throws {
        var plain = model()
        let plainScene = build(plain)
        let plainFrame = try #require(plainScene.nodes["one-leaf"]?.frame)

        plain.nodes["one-leaf"]?.style = NodeStylePatch(padding: 14, fontSize: 28)
        let styledScene = build(plain)
        let styledFrame = try #require(styledScene.nodes["one-leaf"]?.frame)
        #expect(styledFrame.width > plainFrame.width + 8, "a 28 pt leaf must measure wider")
        #expect(styledFrame.height > plainFrame.height + 8, "a 28 pt leaf must measure taller")

        // And the override is gone after resetStyle clears it.
        plain.nodes["one-leaf"]?.style = nil
        let resetScene = build(plain)
        #expect(try #require(resetScene.nodes["one-leaf"]?.frame) == plainFrame)
    }

    @Test func minWidthFloorsTheAutoWidth() throws {
        var model = model()
        let autoScene = build(model)
        let autoWidth = try #require(autoScene.nodes["one"]?.frame.width)

        model.nodes["one"]?.style = NodeStylePatch(minWidth: autoWidth + 120)
        let flooredScene = build(model)
        let flooredWidth = try #require(flooredScene.nodes["one"]?.frame.width)
        #expect(abs(flooredWidth - (autoWidth + 120)) < 0.01)
    }

    // MARK: branch overrides (ADR-0011: the connector INTO the node)

    @Test func branchOverridesActOnTheIncomingConnector() throws {
        var model = model()
        // The root's child "one": the branch root → one is "one"'s.
        model.nodes["one"]?.style = NodeStylePatch(
            branchColor: "#D6409F", branchWidth: 9, branchTaper: 5)
        // The sibling takes a line-style override: straight, constant.
        model.nodes["two"]?.style = NodeStylePatch(
            branchColor: "#46A758", branchWidth: 3, branchLineStyle: "straight")

        let scene = build(model)
        let branch = try #require(scene.branches.first { $0.childID == "one" })
        #expect(PaperTheme.hex(of: branch.color) == 0xD6409F)
        #expect(branch.lineStyle == .tapered, "the theme's tapered style stands")
        #expect(branch.startWidth == 9)
        #expect(branch.endWidth == 4, "taper 5 falls off toward the leaf (max(2, 9-5))")

        let straight = try #require(scene.branches.first { $0.childID == "two" })
        #expect(PaperTheme.hex(of: straight.color) == 0x46A758)
        #expect(straight.lineStyle == .straight)
        #expect(straight.startWidth == 3)
        #expect(straight.endWidth == 3, "a constant line style ignores the taper")

        // Deeper: the leaf's own connector is untouched.
        let leafBranch = try #require(scene.branches.first { $0.childID == "one-leaf" })
        #expect(leafBranch.lineStyle == .tapered)
        #expect(PaperTheme.hex(of: leafBranch.color) != 0xD6409F)
    }

    @Test func branchLineStyleNoneDropsTheConnectorVisual() throws {
        var model = model()
        model.nodes["two"]?.style = NodeStylePatch(branchLineStyle: "none")

        let scene = build(model)
        let branch = try #require(scene.branches.first { $0.childID == "two" })
        #expect(branch.lineStyle == .none)
        #expect(branch.startWidth == 0)
        let path = CanvasLayerTree.branchPath(branch)
        #expect(path.isEmpty, "a .none branch draws nothing")
    }

    @Test func branchWidthOverrideOnConstantStylesSetsBothEnds() throws {
        var model = model()
        model.nodes["one"]?.style = NodeStylePatch(branchWidth: 3, branchLineStyle: "curved")

        let scene = build(model)
        let branch = try #require(scene.branches.first { $0.childID == "one" })
        #expect(branch.lineStyle == .curved)
        #expect(branch.startWidth == 3)
        #expect(branch.endWidth == 3)
    }

    // MARK: rainbow override (F-STY-8)

    @Test func rainbowOffCollapsesEveryBranchToPaletteZero() throws {
        var model = model()
        model.theme = ThemeSelection(id: "paper", overrides: ThemePatch(rainbowBranches: false))

        let scene = build(model)
        let branchOne = try #require(scene.branches.first { $0.childID == "one" })
        let branchTwo = try #require(scene.branches.first { $0.childID == "two" })
        #expect(
            PaperTheme.hex(of: branchOne.color) == PaperTheme.hex(of: branchTwo.color),
            "with rainbow off every branch uses palette color 0")
        #expect(
            PaperTheme.hex(of: branchTwo.color) == PaperTheme.paletteHexes[0])
    }

    // MARK: fast path honesty

    @Test func nodesWithoutOverridesMatchThePureThemeResolution() throws {
        let scene = build(model())
        let paper = BuiltInThemes.theme(id: "paper")
        // Level 1, palette index 1 ("two" is the second child).
        let themeStyle = paper.resolvedStyle(level: 1, level1Index: 1, variant: .light)
        let sceneStyle = try #require(scene.nodes["two"]).style
        #expect(sceneStyle.shape == themeStyle.shape)
        #expect(
            PaperTheme.hex(of: sceneStyle.fillColor ?? CGColor.black)
                == PaperTheme.hex(of: themeStyle.fillColor ?? CGColor.black))
        #expect(sceneStyle.font == themeStyle.font)
        #expect(sceneStyle.paddingWidth == themeStyle.paddingWidth)
    }
}

extension ResolvedNodeStyle {
    fileprivate func fontSizeEquals(_ size: CGFloat) -> Bool {
        font.size == size
    }

    fileprivate var fontSize: CGFloat { font.size }
}
