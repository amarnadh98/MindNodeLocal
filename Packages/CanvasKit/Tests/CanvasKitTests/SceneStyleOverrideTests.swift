import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

/// F-STY-2/F-STY-3 at the scene level: per-node style overrides resolve
/// through `Theme.applyingOverrides` in `SceneGeometry` (measured sizes
/// included — the size key carries the stored patch), branch overrides
/// act on the connector from the node's parent to it (ADR-0027), the
/// rainbow-branches document override collapses the palette, the
/// document's theme overrides fold in, and nodes without overrides stay
/// exactly at their theme-resolved values. The incremental suite proves
/// a `setStyle`/`resetStyle` round equals a full rebuild.
@MainActor
struct SceneStyleOverrideTests {
    private func model() -> MapModel {
        var model = MapModel.emptyDocument(docID: "overrides")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "root"), created: date, modified: date)
        model.roots = [rootID]
        for id in ["one", "two"] {
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
        #expect(styled.style.font.size == 30)
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

    // MARK: branch overrides (ADR-0027: the connector INTO the node)

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
        #expect(PaperTheme.hex(of: branchTwo.color) == PaperTheme.paletteHexes[0])
    }

    // MARK: document theme overrides

    @Test func documentOverridesReachTheSceneCanvasAndPalette() throws {
        var model = model()
        model.theme = ThemeSelection(
            id: "paper",
            overrides: ThemePatch(canvasColor: "#102A43", paletteColors: ["#0090FF"]))

        let scene = build(model)
        #expect(PaperTheme.hex(of: scene.canvasColor) == 0x102A43)
        let branchOne = try #require(scene.branches.first { $0.childID == "one" })
        #expect(PaperTheme.hex(of: branchOne.color) == 0x0090FF)
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

    // MARK: dirty sets (SPEC §11.3)

    @Test func styleDirtySetsFollowTheMeasuredFields() {
        let edited = model()
        #expect(
            SceneGeometry.dirtyIDs(
                for: .setStyle(ids: ["one"], patch: NodeStylePatch(fill: "#0090FF")), in: edited)
                == [])
        #expect(
            SceneGeometry.dirtyIDs(
                for: .setStyle(ids: ["one", "two"], patch: NodeStylePatch(padding: 20)),
                in: edited)
                == Set(["one", "two"]))
        #expect(
            SceneGeometry.dirtyIDs(
                for: .resetStyle(ids: ["one"], keys: [.fill]), in: edited) == [])
        #expect(
            SceneGeometry.dirtyIDs(for: .resetStyle(ids: ["one"], keys: nil), in: edited)
                == Set(["one"]))
        // The wholesale document flips take the full-rebuild fallback.
        #expect(
            SceneGeometry.dirtyIDs(for: .setTheme(id: "ocean"), in: edited) == nil)
        #expect(
            SceneGeometry.dirtyIDs(
                for: .setThemeOverrides(overrides: ThemePatch(rainbowBranches: false)), in: edited)
                == nil)
        #expect(
            SceneGeometry.dirtyIDs(for: .setAppearance(.dark), in: edited) == nil)
        #expect(
            SceneGeometry.dirtyIDs(
                for: .setStructure(id: "root", structure: "mindmap.right"), in: edited)
                == nil)
    }

    // MARK: incremental == full rebuild

    @Test func updateEqualsFullRebuildAfterStyleEdits() throws {
        let measurer = TextMeasurer()
        var model = model()
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)

        /// One round: apply, take the command-derived dirty set, compare
        /// frames and resolved styles against a full rebuild.
        func round(_ command: MapCommand, _ comment: String) throws {
            var edited = model
            try command.apply(to: &edited)
            let dirty = try #require(SceneGeometry.dirtyIDs(for: command, in: edited))
            let full = SceneGeometry.build(model: edited, variant: .light, measurer: measurer)
            let incremental = SceneGeometry.update(
                model: edited, cache: cache, variant: .light, measurer: measurer, dirty: dirty)
            #expect(incremental.nodes.count == full.nodes.count, "\(comment)")
            for (id, left) in incremental.nodes {
                guard let right = full.nodes[id] else {
                    Issue.record("\(comment): id \(id) missing in full")
                    continue
                }
                #expect(left.frame == right.frame, "\(comment): frame \(id)")
                #expect(
                    SceneDiffer.sameStyle(left.style, right.style), "\(comment): style \(id)")
            }
            model = edited
        }

        // A measured-field change (padding/fontSize) through setStyle…
        try round(
            .setStyle(ids: ["one"], patch: NodeStylePatch(padding: 20, fontSize: 26)),
            "setStyle with measured fields")
        // …a repaint-only change (fill/shape)…
        try round(
            .setStyle(ids: ["one-leaf"], patch: NodeStylePatch(shape: .cloud, fill: "#46A758")),
            "setStyle repaint-only")
        // …and the per-key reset back toward the theme.
        try round(
            .resetStyle(ids: ["one"], keys: [.fontSize]), "resetStyle of a measured key")
        try round(
            .resetStyle(ids: ["one"], keys: [.padding]), "resetStyle clears the last key")
    }

    // MARK: folded-count pills (F-LAY-14)

    @Test func foldedNodesCarryTheirHiddenDescendantCount() throws {
        var model = model()
        model.nodes["one"]?.folded = true
        model.nodes["one-leaf"]?.children = ["deep"]
        model.nodes["deep"] = Node(
            id: "deep", parent: "one-leaf", title: NodeTitle(text: "deep"),
            created: Date(timeIntervalSince1970: 1), modified: Date(timeIntervalSince1970: 1))

        let scene = build(model)
        #expect(scene.nodes["one"]?.foldedCount == 2, "one-leaf and deep hide behind the fold")
        #expect(scene.nodes["two"]?.foldedCount == nil)
        #expect(scene.nodes["two-leaf"]?.foldedCount == nil)
        // Folded descendants leave the scene; the count keeps them
        // addressable.
        #expect(scene.nodes["one-leaf"] == nil)
    }

    @Test func pillLayersSyncAndHitTest() throws {
        var model = model()
        model.nodes["one"]?.folded = true

        let scene = build(model)
        let viewport = CGSize(width: 1_400, height: 900)
        let camera = Camera(origin: CGPoint(x: -400, y: -200), scale: 1)
        let tree = CanvasLayerTree()
        var grid = SpatialGrid()
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
        let context = ApplyContext(
            scene: scene, grid: grid, camera: camera, viewport: viewport)
        tree.apply(context)

        let folded = try #require(scene.nodes["one"])
        let pillFrame = try #require(tree.foldedPillFrames["one"])
        // The pill hugs the folded node on the side its children emerge
        // from (the incoming branch's direction decides), vertically
        // centered.
        let growsRight =
            (scene.branches.first { $0.childID == "one" })?.direction == .right
        #expect(
            growsRight
                ? pillFrame.minX == folded.frame.maxX + 8
                : pillFrame.maxX == folded.frame.minX - 8)
        #expect(abs(pillFrame.midY - folded.frame.midY) < 0.01)
        #expect(tree.foldedPillLayers["one"] != nil)

        // The hit test lands inside (and near) the pill only.
        #expect(tree.foldedPillID(atModel: pillFrame.center()) == "one")
        #expect(tree.foldedPillID(atModel: CGPoint(x: pillFrame.maxX + 3, y: pillFrame.midY)) == "one")
        #expect(tree.foldedPillID(atModel: CGPoint(x: pillFrame.maxX + 60, y: pillFrame.midY)) == nil)
        #expect(tree.foldedPillID(atModel: CGPoint(x: pillFrame.minX - 60, y: pillFrame.midY)) == nil)

        // Unfolding drops the pill with the node.
        var unfolded = model
        unfolded.nodes["one"]?.folded = false
        let unfoldedScene = build(unfolded)
        var unfoldedGrid = SpatialGrid()
        for node in unfoldedScene.nodes.values {
            unfoldedGrid.insert(id: node.id, frame: node.frame)
        }
        tree.apply(
            ApplyContext(
                scene: unfoldedScene, grid: unfoldedGrid, camera: camera, viewport: viewport))
        #expect(tree.foldedPillLayers.isEmpty)
        #expect(tree.foldedPillFrames.isEmpty)
    }
}

private extension CGRect {
    func center() -> CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
