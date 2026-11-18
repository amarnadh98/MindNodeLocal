import CoreGraphics
import Testing

@testable import MapLayout

@Test func defaultSpacingMatchesSpec() {
    let spacing = LayoutSpacing.default
    #expect(spacing.levelGap == 56)
    #expect(spacing.siblingGap == 12)
    #expect(spacing.subtreeGap == 24)
    #expect(spacing.rootGap == 72)
}

@Test func narrowPresetIsSevenTenthsOfDefault() {
    let narrow = LayoutSpacing.narrow
    let base = LayoutSpacing.default
    #expect(narrow.levelGap == base.levelGap * 0.7)
    #expect(narrow.siblingGap == base.siblingGap * 0.7)
    #expect(narrow.subtreeGap == base.subtreeGap * 0.7)
    #expect(narrow.rootGap == base.rootGap * 0.7)
}

@Test func widePresetIsFourteenTenthsOfDefault() {
    let wide = LayoutSpacing.wide
    let base = LayoutSpacing.default
    #expect(wide.levelGap == base.levelGap * 1.4)
    #expect(wide.siblingGap == base.siblingGap * 1.4)
    #expect(wide.subtreeGap == base.subtreeGap * 1.4)
    #expect(wide.rootGap == base.rootGap * 1.4)
}

@Test func layoutResultCarriesNodeFrames() {
    let result: LayoutResult = [
        "root": CGRect(x: 0, y: 0, width: 120, height: 40),
        "child-1": CGRect(x: 192, y: -14, width: 80, height: 28),
    ]
    #expect(result.count == 2)
    #expect(result["root"]?.width == 120)
    #expect(result["child-1"]?.minX == 192)
}
