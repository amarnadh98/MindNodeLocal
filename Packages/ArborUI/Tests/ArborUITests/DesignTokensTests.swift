import CoreGraphics
import SwiftUI
import Testing

@testable import ArborUI

@Test func spacingTokensMatchSpec() {
    #expect(DesignTokens.levelGap == 56)
    #expect(DesignTokens.siblingGap == 12)
    #expect(DesignTokens.subtreeGap == 24)
    #expect(DesignTokens.rootGap == 72)
}

@Test func canvasColorsAreDistinct() {
    #expect(DesignTokens.canvasLight != DesignTokens.canvasDark)
}
