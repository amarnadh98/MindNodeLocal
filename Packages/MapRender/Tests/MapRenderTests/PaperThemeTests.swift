import CoreGraphics
import Testing

@testable import MapRender

@Test func paletteHasEightColors() {
    #expect(PaperTheme.paletteHexes.count == 8)
    #expect(Set(PaperTheme.paletteHexes).count == 8)
}

@Test func paletteHexRoundTripsThroughCGColor() {
    for hex in PaperTheme.paletteHexes {
        let color = PaperTheme.color(fromHex: hex)
        #expect(PaperTheme.hex(of: color) == hex)
    }
}

@Test func canvasAndRootHexesRoundTrip() {
    for hex in [
        PaperTheme.canvasLightHex,
        PaperTheme.canvasDarkHex,
        PaperTheme.rootFillLightHex,
        PaperTheme.rootFillDarkHex,
    ] {
        #expect(PaperTheme.hex(of: PaperTheme.color(fromHex: hex)) == hex)
    }
}

@Test func colorsAreOpaqueSRGB() {
    let canvas = PaperTheme.canvasLight
    #expect(canvas.alpha == 1.0)
    #expect(canvas.colorSpace?.name == CGColorSpace.sRGB)
}
