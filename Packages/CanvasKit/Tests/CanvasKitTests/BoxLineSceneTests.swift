import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

/// ADR-0037 at the scene level: a stored Box|Line flip resolves
/// through the theme's donor look in `SceneGeometry` (the recast base
/// is memoized per donor), in both appearances, for levels 0–3 — and
/// the donor's padding reaches the measured frame.
@MainActor
struct BoxLineSceneTests {
    private let studio = BuiltInThemes.theme(id: BuiltInThemes.newDocumentDefaultID)

    /// root → one → two → three (levels 0–3).
    private func model() -> MapModel {
        var model = MapModel.emptyDocument(docID: "box-line")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var parent: String?
        for id in ["root", "one", "two", "three"] {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: id), created: date, modified: date)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots = [id]
            }
            parent = id
        }
        return model
    }

    private func build(_ model: MapModel, variant: ThemeVariant) -> CanvasScene {
        SceneGeometry.build(
            model: model, variant: variant, measurer: SceneRenderer.sharedMeasurer, theme: studio)
    }

    @Test func lineFlipsResolveIntoTheScene() throws {
        for variant in [ThemeVariant.light, .dark] {
            var model = model()
            // Levels 0–2 draw boxes in Studio; Line flips each.
            for id in ["root", "one", "two"] {
                model.nodes[id]?.style = NodeStylePatch(shape: .underline)
            }
            let scene = build(model, variant: variant)
            for id in ["root", "one", "two"] {
                let style = try #require(scene.nodes[id]).style
                #expect(style.shape == .underline)
                #expect(style.fillColor == nil, "\(id): a Line never carries a fill")
                #expect(style.borderWidth == 0)
                #expect(style.underlineWidth == 2.5)
                #expect(style.borderColor != nil, "the line itself")
            }
        }
    }

    @Test func boxFlipOnTheUnderlineLevelResolvesTheDonorLook() throws {
        for variant in [ThemeVariant.light, .dark] {
            var model = model()
            model.nodes["three"]?.style = NodeStylePatch(shape: .roundedRect)
            let scene = build(model, variant: variant)

            let box = try #require(scene.nodes["three"]).style
            #expect(box.shape == .roundedRect)
            let branch = studio.branchColor(level1Index: 0, variant: variant)
            #expect(
                PaperTheme.hex(of: try #require(box.fillColor)) == PaperTheme.hex(of: branch))
            #expect(box.cornerRadius == 16, "Studio's level-1 radius")
            #expect(box.paddingWidth == 24 && box.paddingHeight == 14)
            #expect(box.borderColor == nil && box.borderWidth == 0)
            // Level 3's own typography survives the flip.
            #expect(box.font.size == 15)
        }
    }

    @Test func sameClassOverridesStayAtTheLevelLook() throws {
        for variant in [ThemeVariant.light, .dark] {
            var model = model()
            model.nodes["one"]?.style = NodeStylePatch(shape: .pill)
            let scene = build(model, variant: variant)
            let style = try #require(scene.nodes["one"]).style
            #expect(style.shape == .pill)
            #expect(style.fillColor != nil, "the level's own fill")
            #expect(style.paddingWidth == 24, "the level's own padding")
        }
    }

    @Test func donorPaddingReachesTheMeasuredFrame() throws {
        for variant in [ThemeVariant.light, .dark] {
            let plain = build(model(), variant: variant)
            let plainFrame = try #require(plain.nodes["three"]?.frame)

            var model = model()
            model.nodes["three"]?.style = NodeStylePatch(shape: .roundedRect)
            let boxScene = build(model, variant: variant)
            let boxFrame = try #require(boxScene.nodes["three"]?.frame)

            // The underline level's padding is 2×3; the box donor's is
            // 24×14 — the flip MUST have re-measured, not repainted.
            #expect(boxFrame.width > plainFrame.width + 30)
            #expect(boxFrame.height > plainFrame.height + 12)
        }
    }
}
