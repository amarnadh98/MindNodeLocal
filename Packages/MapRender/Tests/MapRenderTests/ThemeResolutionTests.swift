import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

struct ThemeResolutionTests {
    @Test func paletteCyclesByLevelOneIndex() {
        #expect(PaperTheme.hex(of: PaperTheme.branchColor(level1Index: 0)) == 0xE5484D)
        #expect(PaperTheme.hex(of: PaperTheme.branchColor(level1Index: 8)) == 0xE5484D)
        #expect(PaperTheme.hex(of: PaperTheme.branchColor(level1Index: -1)) == 0xD6409F)
        #expect(PaperTheme.hex(of: PaperTheme.branchColor(level1Index: 3)) == 0x46A758)
    }

    @Test func rootStyleMatchesPaperTokens() throws {
        let light = PaperTheme.resolvedStyle(level: 0, level1Index: 0, variant: .light)
        #expect(light.shape == .roundedRect)
        #expect(PaperTheme.hex(of: try #require(light.fillColor)) == PaperTheme.rootFillLightHex)
        #expect(light.cornerRadius == 10)
        #expect(light.shadow == .raised)
        #expect(light.font.size == 20)
        #expect(light.font.weight == 0.4)
        #expect(PaperTheme.hex(of: light.textColor) == 0xFFFFFF)

        let dark = PaperTheme.resolvedStyle(level: 0, level1Index: 0, variant: .dark)
        #expect(PaperTheme.hex(of: try #require(dark.fillColor)) == PaperTheme.rootFillDarkHex)
        #expect(PaperTheme.hex(of: dark.textColor) == 0x1C1C1E)
    }

    @Test func levelOneTintsTheBranchPalette() throws {
        let light = PaperTheme.resolvedStyle(level: 1, level1Index: 2, variant: .light)
        #expect(light.shape == .roundedRect)
        #expect(light.font.size == 16)
        let fill = try #require(light.fillColor)
        #expect(fill.alpha == 0.16)
        #expect(PaperTheme.hex(of: fill) == 0xFFC53D)

        let dark = PaperTheme.resolvedStyle(level: 1, level1Index: 2, variant: .dark)
        #expect(try #require(dark.fillColor).alpha == 0.24)
    }

    @Test func levelTwoPlusIsTextOnAnUnderline() throws {
        let style = PaperTheme.resolvedStyle(level: 4, level1Index: 5, variant: .light)
        #expect(style.shape == .underline)
        #expect(style.fillColor == nil)
        #expect(style.font.size == 14)
        #expect(style.underlineWidth == 2)
        #expect(PaperTheme.hex(of: try #require(style.borderColor)) == 0x0090FF)
    }

    @Test func branchWidthsTaperFromRootToLeaves() {
        #expect(PaperTheme.branchWidths(level: 0) == (start: 6, end: 2))
        #expect(PaperTheme.branchWidths(level: 4).start == 2)
        #expect(PaperTheme.branchWidths(level: 9) == (start: 2, end: 2))
    }

    @Test func typographyFollowsTheSpec() {
        let typography = ThemeTypography()
        #expect(typography.root.size == 20)
        #expect(typography.level1.size == 16)
        #expect(typography.level2Plus.size == 14)
        #expect(typography.lineHeight == 1.25)
        #expect(typography.font(forLevel: 3).size == 14)
    }
}
