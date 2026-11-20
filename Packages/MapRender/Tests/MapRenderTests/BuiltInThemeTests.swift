import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// F-STY-4: the twelve built-in themes, their identity, palettes and
/// resolution in both appearance variants.
struct BuiltInThemeTests {
    @Test func twelveThemesInSpecOrder() {
        #expect(
            BuiltInThemes.all.map(\.id)
                == [
                    "studio", "paper", "graphite", "pastel", "ocean", "forest", "sunset",
                    "mono-ink", "chalkboard", "neon", "blueprint", "sakura", "study",
                ])
        #expect(
            BuiltInThemes.all.map(\.name)
                == [
                    "Studio", "Paper", "Graphite", "Pastel", "Ocean", "Forest", "Sunset",
                    "Mono Ink", "Chalkboard", "Neon", "Blueprint", "Sakura", "Study",
                ])
        #expect(Set(BuiltInThemes.all.map(\.id)).count == BuiltInThemes.all.count)
    }

    @Test func palettesHoldEightToTwelveColors() {
        for theme in BuiltInThemes.all {
            for scheme in [theme.light, theme.dark] {
                #expect((8...12).contains(scheme.palette.count), "\(theme.id) palette size")
                #expect(Set(scheme.palette).count == scheme.palette.count, "\(theme.id) duplicate colors")
            }
        }
    }

    @Test func everyColorStringParses() {
        for theme in BuiltInThemes.all {
            for scheme in [theme.light, theme.dark] {
                #expect(ThemeHex.color(scheme.canvasColor) != nil, "\(theme.id) canvas")
                for raw in scheme.palette {
                    #expect(ThemeHex.color(raw) != nil, "\(theme.id) palette \(raw)")
                }
                for level in [
                    scheme.levels.root, scheme.levels.level1, scheme.levels.level2, scheme.levels.level3Plus,
                ] {
                    #expect(ThemeHex.color(level.textColor) != nil, "\(theme.id) level text")
                    if case .solid(let raw) = level.fill {
                        #expect(ThemeHex.color(raw) != nil, "\(theme.id) level fill")
                    }
                    if case .solid(let raw) = level.border?.paint {
                        #expect(ThemeHex.color(raw) != nil, "\(theme.id) level border")
                    }
                    for shadow in level.shadow {
                        #expect(ThemeHex.color(shadow.color) != nil, "\(theme.id) shadow")
                    }
                }
            }
        }
    }

    @Test func everyThemeResolvesLevelsZeroThroughFourInBothVariants() throws {
        for theme in BuiltInThemes.all {
            for variant in [ThemeVariant.light, .dark] {
                for level in 0...4 {
                    let style = theme.resolvedStyle(level: level, level1Index: 3, variant: variant)
                    #expect(style.font.size > 0, "\(theme.id) level \(level)")
                    #expect(try #require(style.textColor.components, "\(theme.id)").count >= 3)
                    if style.fillColor != nil {
                        #expect(
                            PaperTheme.hex(of: try #require(style.fillColor)) != nil,
                            "\(theme.id) level \(level) fill must be a plain sRGB color")
                    }
                    if let borderColor = style.borderColor {
                        #expect(
                            PaperTheme.hex(of: borderColor) != nil,
                            "\(theme.id) level \(level) border must be a plain sRGB color")
                    }
                    // Level mapping: root, 1, 2, then 3+ repeats.
                    let scheme = theme.scheme(for: variant)
                    #expect(style.shape == scheme.levels.style(forLevel: level).shape)
                    #expect(style.font == theme.fontSpec(forLevel: level, variant: variant))
                }
                #expect(PaperTheme.hex(of: theme.canvasColor(for: variant)) != nil, "\(theme.id) canvas")
            }
        }
    }

    @Test func levelThreePlusAppliesFromLevelThree() {
        let study = BuiltInThemes.theme(id: "study")
        #expect(study.resolvedStyle(level: 2, level1Index: 0, variant: .light).font.size == 15)
        #expect(study.resolvedStyle(level: 3, level1Index: 0, variant: .light).font.size == 15)
        #expect(study.resolvedStyle(level: 99, level1Index: 0, variant: .light).font.size == 15)
    }

    @Test func branchColorsWrapAroundThePalette() throws {
        for theme in BuiltInThemes.all {
            let count = theme.light.palette.count
            let first = try #require(PaperTheme.hex(of: theme.branchColor(level1Index: 0, variant: .light)))
            let wrapped = try #require(
                PaperTheme.hex(of: theme.branchColor(level1Index: count, variant: .light)))
            let negative = try #require(
                PaperTheme.hex(of: theme.branchColor(level1Index: -1, variant: .light)))
            let last = try #require(
                PaperTheme.hex(of: theme.branchColor(level1Index: count - 1, variant: .light)))
            #expect(wrapped == first, "\(theme.id) wraps forward")
            #expect(negative == last, "\(theme.id) wraps backward")
        }
    }

    @Test func unknownThemeIdFallsBackToPaper() {
        #expect(BuiltInThemes.theme(id: "no-such-theme") == BuiltInThemes.theme(id: "paper"))
        #expect(BuiltInThemes.theme(id: BuiltInThemes.defaultID).id == "paper")
    }

    @Test func rainbowToggleControlsEffectivePaletteIndex() {
        #expect(BuiltInThemes.theme(id: "paper").effectivePaletteIndex(5) == 5)
        #expect(BuiltInThemes.theme(id: "blueprint").effectivePaletteIndex(5) == 0)
    }

    @Test func branchWidthsFollowTheThemeData() {
        let paper = BuiltInThemes.theme(id: "paper")
        #expect(paper.branchWidth(level: 0) == 6)
        #expect(paper.branchWidth(level: 1) == 5)
        #expect(paper.branchWidth(level: 9) == 2)
        let monoInk = BuiltInThemes.theme(id: "mono-ink")
        #expect(monoInk.branchWidth(level: 0) == 3)
        #expect(monoInk.branchWidth(level: 9) == 3)
    }
}

extension Theme {
    /// Test helper: the `FontSpec` of one level (bypassing color work).
    func fontSpec(forLevel level: Int, variant: ThemeVariant) -> FontSpec {
        let levelStyle = scheme(for: variant).levels.style(forLevel: level)
        let font = levelStyle.font
        return FontSpec(
            size: CGFloat(font.size), weight: CGFloat(font.weight), family: font.family,
            italic: font.italic, monospace: font.monospace)
    }
}
