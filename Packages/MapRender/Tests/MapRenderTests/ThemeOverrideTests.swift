import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

infix operator ~~

/// F-STY-3 per-node override resolution (`Theme.applyingOverrides`):
/// every `NodeStylePatch` field folds in after the theme's level style
/// and branch color; unknown values are ignored one field at a time;
/// nodes without overrides resolve to the pure theme value.
struct ThemeOverrideTests {
    private let paper = BuiltInThemes.theme(id: "paper")

    private func base(level: Int = 1, variant: ThemeVariant = .light) -> ResolvedNodeStyle {
        paper.resolvedStyle(level: level, level1Index: 2, variant: variant)
    }

    // MARK: identity fast path

    @Test func nilAndEmptyPatchesResolveToTheThemeStyle() {
        let themeStyle = base()
        #expect(paper.applyingOverrides(nil, to: themeStyle, variant: .light) ~~ themeStyle)
        #expect(
            paper.applyingOverrides(NodeStylePatch(), to: themeStyle, variant: .light) ~~ themeStyle)
    }

    // MARK: shape / fill

    @Test func shapeOverrideChangesTheShape() {
        let resolved = paper.applyingOverrides(
            NodeStylePatch(shape: .hexagon), to: base(), variant: .light)
        #expect(resolved.shape == .hexagon)
    }

    @Test func fillOverrideTakesHexOrNone() throws {
        let solid = paper.applyingOverrides(
            NodeStylePatch(fill: "#0090FF"), to: base(), variant: .light)
        #expect(PaperTheme.hex(of: try #require(solid.fillColor)) == 0x0090FF)

        let none = paper.applyingOverrides(
            NodeStylePatch(fill: "none"), to: base(), variant: .light)
        #expect(none.fillColor == nil)

        let caseInsensitive = paper.applyingOverrides(
            NodeStylePatch(fill: "None"), to: base(), variant: .light)
        #expect(caseInsensitive.fillColor == nil)
    }

    @Test func inheritanceOrderThemeLevelBranchColorOverride() throws {
        // Theme → level style: level 1 tints the palette color.
        let themeStyle = try #require(base().fillColor)
        #expect(themeStyle.alpha == 0.16)
        #expect(PaperTheme.hex(of: themeStyle) == 0xFFC53D)

        // Override wins over everything below it in the chain…
        let overridden = try #require(
            paper.applyingOverrides(
                NodeStylePatch(fill: "#46A758"), to: base(), variant: .light
            ).fillColor)
        #expect(PaperTheme.hex(of: overridden) == 0x46A758)
        #expect(overridden.alpha == 1)

        // …and leaves the branch-color resolution of other fields alone:
        // a sibling node without the patch still tints the palette.
        let sibling = base()
        #expect(PaperTheme.hex(of: try #require(sibling.fillColor)) == 0xFFC53D)
    }

    // MARK: border

    @Test func borderOverridesCoverWidthColorAndDash() throws {
        let resolved = paper.applyingOverrides(
            NodeStylePatch(borderColor: "#E5484D", borderWidth: 3, borderDash: true),
            to: base(), variant: .light)
        #expect(PaperTheme.hex(of: try #require(resolved.borderColor)) == 0xE5484D)
        #expect(resolved.borderWidth == 3)
        #expect(resolved.borderDash)
    }

    @Test func underlineShapeOverrideMovesTheBorderIntoTheLine() throws {
        // Level 2+ is already an underline in Paper; a level-1 node
        // overridden to underline must draw its border as the line.
        let resolved = paper.applyingOverrides(
            NodeStylePatch(shape: .underline, borderColor: "#D6409F", borderWidth: 2),
            to: base(), variant: .light)
        #expect(resolved.shape == .underline)
        #expect(resolved.underlineWidth == 2)
        #expect(resolved.borderWidth == 0, "the underline IS the border (§7.2)")
        #expect(PaperTheme.hex(of: try #require(resolved.borderColor)) == 0xD6409F)
    }

    // MARK: geometry fields

    @Test func cornerRadiusPaddingAndWidthsOverride() {
        let resolved = paper.applyingOverrides(
            NodeStylePatch(cornerRadius: 18, padding: 24, minWidth: 90, maxWidth: 120),
            to: base(), variant: .light)
        #expect(resolved.cornerRadius == 18)
        #expect(resolved.paddingWidth == 24)
        #expect(resolved.paddingHeight == 24)
        #expect(resolved.minWidth == 90)
        #expect(resolved.maxWidth == 120)
    }

    // MARK: shadow presets

    @Test func shadowPresetsFollowTheReferenceDefinition() throws {
        let none = paper.applyingOverrides(
            NodeStylePatch(shadow: .none), to: base(), variant: .light)
        #expect(none.shadows.isEmpty)

        let soft = paper.applyingOverrides(
            NodeStylePatch(shadow: .soft), to: base(), variant: .light)
        #expect(soft.shadows.count == 1)
        #expect(soft.shadows.first?.offsetY == 2)
        #expect(soft.shadows.first?.blur == 6)

        let raisedLight = paper.applyingOverrides(
            NodeStylePatch(shadow: .raised), to: base(), variant: .light)
        #expect(raisedLight.shadows.count == 2, "raised is two layers in light (§7.2)")

        let raisedDark = paper.applyingOverrides(
            NodeStylePatch(shadow: .raised), to: base(), variant: .dark)
        #expect(raisedDark.shadows.count == 1, "raised compresses to one layer in dark (§7.2)")
        #expect(raisedDark.shadows.first?.offsetY == 4)
    }

    // MARK: typography

    @Test func fontOverridesCoverNameSizeAndWeight() {
        let resolved = paper.applyingOverrides(
            NodeStylePatch(fontName: "New York", fontSize: 21, fontWeight: 0.4),
            to: base(), variant: .light)
        #expect(resolved.font.size == 21)
        #expect(resolved.font.weight == 0.4)
        #expect(resolved.font.family == "New York")
        // An override of one typography field leaves the others' theme
        // values standing.
        let sizeOnly = paper.applyingOverrides(
            NodeStylePatch(fontSize: 21), to: base(), variant: .light)
        #expect(sizeOnly.font.weight == base().font.weight)
        #expect(sizeOnly.font.family == base().font.family)
    }

    @Test func emptyFontNameReturnsToTheSystemFamily() {
        let resolved = paper.applyingOverrides(
            NodeStylePatch(fontName: ""), to: base(), variant: .light)
        #expect(resolved.font.family == nil)
    }

    @Test func textColorAndAlignmentOverride() throws {
        let resolved = paper.applyingOverrides(
            NodeStylePatch(textColor: "#FFFFFF", alignment: "left"), to: base(), variant: .light)
        #expect(PaperTheme.hex(of: try #require(resolved.textColor)) == 0xFFFFFF)
        #expect(resolved.textAlignment == .leading)

        #expect(
            paper.applyingOverrides(
                NodeStylePatch(alignment: "right"), to: base(), variant: .light
            ).textAlignment == .trailing)
        #expect(
            paper.applyingOverrides(
                NodeStylePatch(alignment: "center"), to: base(), variant: .light
            ).textAlignment == .center)
        #expect(
            // An unrecognized string is ignored, not fatal.
            paper.applyingOverrides(
                NodeStylePatch(alignment: "sideways"), to: base(), variant: .light
            ).textAlignment == .center)
    }

    // MARK: robustness

    @Test func unknownValuesAreIgnoredPerField() throws {
        let resolved = paper.applyingOverrides(
            NodeStylePatch(fill: "not-a-hex", borderColor: "#zzzzzz", alignment: "diagonal"),
            to: base(), variant: .light)
        // The theme values stand for every unparseable field.
        #expect(
            PaperTheme.hex(of: resolved.fillColor ?? CGColor.black)
                == PaperTheme.hex(of: base().fillColor ?? CGColor.black))
        #expect(resolved.borderColor == base().borderColor)
        #expect(resolved.textAlignment == .center)
    }

    @Test func overridesResolveForEveryBuiltInThemeAndVariant() {
        // No theme's level styles can make an override explode.
        for theme in BuiltInThemes.all {
            for variant in [ThemeVariant.light, .dark] {
                for level in 0...3 {
                    let style = theme.resolvedStyle(level: level, level1Index: 3, variant: variant)
                    let resolved = theme.applyingOverrides(
                        NodeStylePatch(
                            shape: .cloud, fill: "none", padding: 12, shadow: .raised),
                        to: style, variant: variant)
                    #expect(resolved.shape == .cloud)
                    #expect(resolved.fillColor == nil)
                    #expect(!resolved.shadows.isEmpty)
                }
            }
        }
    }
}

/// Field-by-field structural equality (CGColor components compared; the
/// swift-testing `#expect(==)` needs `ResolvedNodeStyle` Equatable,
/// which the render types deliberately avoid).
private func ~~ (lhs: ResolvedNodeStyle, rhs: ResolvedNodeStyle) -> Bool {
    lhs.shape == rhs.shape
        && PaperTheme.hex(of: lhs.fillColor ?? CGColor.black) == PaperTheme.hex(of: rhs.fillColor ?? CGColor.black)
        && lhs.fillColor?.alpha == rhs.fillColor?.alpha
        && PaperTheme.hex(of: lhs.textColor) == PaperTheme.hex(of: rhs.textColor)
        && lhs.font == rhs.font
        && lhs.borderWidth == rhs.borderWidth
        && lhs.borderDash == rhs.borderDash
        && lhs.cornerRadius == rhs.cornerRadius
        && lhs.paddingWidth == rhs.paddingWidth
        && lhs.paddingHeight == rhs.paddingHeight
        && lhs.textAlignment == rhs.textAlignment
        && lhs.underlineWidth == rhs.underlineWidth
        && lhs.minWidth == rhs.minWidth
        && lhs.maxWidth == rhs.maxWidth
        && lhs.shadows.count == rhs.shadows.count
        && zip(lhs.shadows, rhs.shadows).allSatisfy { $0.offsetY == $1.offsetY && $0.blur == $1.blur }
}
