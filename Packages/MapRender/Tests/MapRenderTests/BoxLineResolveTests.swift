import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// ADR-0034: the Box|Line control stores only a `shape`, so the
/// resolver carries the class-flip look. For every level 0–3 in both
/// appearances: "Line" is text on a line in the branch color (no
/// fill), and "Box" on an underline level is the theme's own box look
/// (level-1 fill/border/radius/padding), while a same-class shape
/// pick keeps the level style.
struct BoxLineResolveTests {
    private let studio = BuiltInThemes.theme(id: BuiltInThemes.newDocumentDefaultID)
    private let paper = BuiltInThemes.theme(id: "paper")

    private let levels = 0...3
    private let variants: [ThemeVariant] = [.light, .dark]

    // MARK: donor classification

    @Test func donorClassification() {
        // Studio: 0–2 draw boxes, 3+ underlines.
        for level in levels {
            for variant in variants {
                #expect(studio.shapeDonor(override: nil, level: level, variant: variant) == .none)
                #expect(
                    studio.shapeDonor(override: .underline, level: level, variant: variant)
                        == (level < 3 ? .line : .none))
                #expect(
                    studio.shapeDonor(override: .roundedRect, level: level, variant: variant)
                        == (level < 3 ? .none : .box))
                // Another box shape stays in the level's class.
                #expect(
                    studio.shapeDonor(override: .circle, level: level, variant: variant)
                        == (level < 3 ? .none : .box))
                // Text-only is its own look, not a flip (NodeShape.none,
                // spelled out so it never reads as Optional.none).
                #expect(
                    studio.shapeDonor(override: NodeShape.none, level: level, variant: variant) == .none)
            }
        }
    }

    // MARK: Line (text on a line in the branch color)

    @Test func lineOnBoxLevelsIsTextOnABranchColoredLine() throws {
        for level in 0...2 {
            for variant in variants {
                let theme = studio
                let branch = theme.branchColor(level1Index: 1, variant: variant)
                let line = theme.resolvedStyle(
                    level: level, level1Index: 1, variant: variant,
                    overrides: NodeStylePatch(shape: .underline))
                #expect(line.shape == .underline, "level \(level), \(variant)")
                #expect(line.fillColor == nil, "a Line never carries a fill")
                #expect(line.borderWidth == 0, "the border draws AS the underline")
                // The underline look is the theme's own (Studio's
                // level-3+ style: 2.5 pt in the branch color).
                #expect(line.underlineWidth == 2.5)
                let stroke = try #require(line.borderColor)
                #expect(
                    PaperTheme.hex(of: stroke) == PaperTheme.hex(of: branch),
                    "the line is in the branch color")
                #expect(line.paddingWidth == 2 && line.paddingHeight == 3)
            }
        }
    }

    @Test func lineOnPaperLevelOneDropsTheTintFill() throws {
        for variant in variants {
            let line = paper.resolvedStyle(
                level: 1, level1Index: 2, variant: variant,
                overrides: NodeStylePatch(shape: .underline))
            #expect(line.shape == .underline)
            #expect(line.fillColor == nil, "Paper level 1's tinted fill must not survive")
            #expect(line.underlineWidth == 2)
            #expect(line.borderWidth == 0)
        }
    }

    // MARK: Box on underline levels (the theme's own box look)

    @Test func boxOnStudioLevelThreeIsTheLevelOneBoxLook() throws {
        for variant in variants {
            let box = studio.resolvedStyle(
                level: 3, level1Index: 1, variant: variant,
                overrides: NodeStylePatch(shape: .roundedRect))
            #expect(box.shape == .roundedRect)
            // Studio level 1: solid branch-color fill, no border,
            // radius 16, padding 24×14 (ADR-0031).
            let branch = studio.branchColor(level1Index: 1, variant: variant)
            let fill = try #require(box.fillColor)
            #expect(PaperTheme.hex(of: fill) == PaperTheme.hex(of: branch))
            #expect(fill.alpha == 1)
            #expect(box.borderColor == nil)
            #expect(box.borderWidth == 0)
            #expect(box.underlineWidth == 0)
            #expect(box.cornerRadius == 16)
            #expect(box.paddingWidth == 24 && box.paddingHeight == 14)
            // The node's OWN level keeps its typography and widths.
            let own = studio.resolvedStyle(level: 3, level1Index: 1, variant: variant)
            #expect(box.font.size == own.font.size)
            #expect(box.minWidth == own.minWidth)
            #expect(box.maxWidth == own.maxWidth)
        }
    }

    @Test func boxOnPaperLevelTwoIsTheTintedLevelOneBox() throws {
        for variant in variants {
            let box = paper.resolvedStyle(
                level: 2, level1Index: 2, variant: variant,
                overrides: NodeStylePatch(shape: .roundedRect))
            #expect(box.shape == .roundedRect)
            // Paper level 1 tints the branch color (0.16 light, 0.24
            // dark) — the donor look, resolved per appearance.
            let tint = try #require(box.fillColor)
            #expect(tint.alpha == (variant == .light ? 0.16 : 0.24))
            #expect(
                PaperTheme.hex(of: tint)
                    == PaperTheme.hex(
                        of: paper.branchColor(
                            level1Index: 2, variant: variant)))
            #expect(box.cornerRadius == 10)
            #expect(box.paddingWidth == 16 && box.paddingHeight == 10)
            #expect(box.underlineWidth == 0)
        }
    }

    // MARK: same-class and explicit fields

    @Test func sameClassShapePickKeepsTheLevelLook() throws {
        for variant in variants {
            let hexagon = studio.resolvedStyle(
                level: 1, level1Index: 0, variant: variant,
                overrides: NodeStylePatch(shape: .hexagon))
            #expect(hexagon.shape == .hexagon)
            #expect(hexagon.fillColor != nil, "the level's own fill stays")

            // Underline on an underline level: unchanged.
            let line = studio.resolvedStyle(
                level: 3, level1Index: 0, variant: variant,
                overrides: NodeStylePatch(shape: .underline))
            let plain = studio.resolvedStyle(level: 3, level1Index: 0, variant: variant)
            #expect(line.shape == plain.shape)
            #expect(line.underlineWidth == plain.underlineWidth)
        }
    }

    @Test func explicitPatchFieldsBeatTheDonorLook() throws {
        // An explicit fill survives a Box flip (the donor only fills
        // in what the patch leaves alone).
        let custom = paper.resolvedStyle(
            level: 2, level1Index: 2, variant: .light,
            overrides: NodeStylePatch(shape: .roundedRect, fill: "#46A758"))
        #expect(PaperTheme.hex(of: try #require(custom.fillColor)) == 0x46A758)
        #expect(custom.cornerRadius == 10, "the donor's radius still applies")
    }

    // MARK: the plain level styles are untouched

    @Test func noOverrideStillResolvesTheThemeLevelStyle() {
        for theme in [studio, paper] {
            for level in levels {
                for variant in variants {
                    let style = theme.resolvedStyle(level: level, level1Index: 0, variant: variant)
                    #expect(style.shape == theme.scheme(for: variant).levels.style(forLevel: level).shape)
                }
            }
        }
    }
}
