import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// Paper is the first **data** theme (ADR-0009): its `Theme` values must
/// resolve exactly what the reference `PaperTheme` implementation
/// resolves, so the M1 canvas renders pixel-identically through the new
/// theme engine. Every style field is compared; colors compare through
/// the same sRGB round trip the renderer sees (hex + alpha).
struct PaperThemeEquivalenceTests {
    @Test func dataPaperMatchesReferenceResolutionEverywhere() throws {
        let paper = BuiltInThemes.theme(id: "paper")
        for variant in [ThemeVariant.light, .dark] {
            for level in 0...4 {
                for index in 0..<16 {
                    let data = paper.resolvedStyle(level: level, level1Index: index, variant: variant)
                    let reference = PaperTheme.resolvedStyle(
                        level: level, level1Index: index, variant: variant)
                    #expect(data.shape == reference.shape, "level \(level)")
                    #expect(data.borderWidth == reference.borderWidth, "level \(level)")
                    #expect(data.cornerRadius == reference.cornerRadius, "level \(level)")
                    #expect(data.paddingWidth == reference.paddingWidth, "level \(level)")
                    #expect(data.paddingHeight == reference.paddingHeight, "level \(level)")
                    #expect(data.underlineWidth == reference.underlineWidth, "level \(level)")
                    #expect(data.font == reference.font, "level \(level)")
                    #expect(data.maxWidth == reference.maxWidth, "level \(level)")
                    try expectSameColor(data.fillColor, reference.fillColor, "fill")
                    try expectSameColor(data.borderColor, reference.borderColor, "border")
                    try expectSameColor(data.textColor, reference.textColor, "text")
                    try expectSameShadows(data.shadows, reference.shadows)
                }
            }
        }
    }

    @Test func dataPaperMatchesReferenceBranchesAndCanvas() throws {
        let paper = BuiltInThemes.theme(id: "paper")
        for variant in [ThemeVariant.light, .dark] {
            for index in 0..<16 {
                try expectSameColor(
                    paper.branchColor(level1Index: index, variant: variant),
                    PaperTheme.branchColor(level1Index: index, variant: variant),
                    "branch \(index)")
            }
            try expectSameColor(
                paper.canvasColor(for: variant),
                variant == .light ? PaperTheme.canvasLight : PaperTheme.canvasDark,
                "canvas")
            // The taper the canvas actually draws (SceneGeometry's former
            // formula): 6 pt at the root, 2 pt floor.
            for level in 0...9 {
                #expect(paper.branchWidth(level: level) == max(2, 6 - CGFloat(level)), "level \(level)")
            }
        }
    }

    /// Colors compare as the renderer consumes them: sRGB hex plus the
    /// alpha channel. (The reference shadow layers are grayscale
    /// `CGColor`s, the data theme's are sRGB — identical after the
    /// conversion every consumer applies.)
    private func expectSameColor(
        _ data: CGColor?, _ reference: CGColor?, _ label: String
    ) throws {
        if data == nil || reference == nil {
            #expect(data == nil && reference == nil, "\(label): nil mismatch")
            return
        }
        let dataColor = try #require(data)
        let referenceColor = try #require(reference)
        #expect(
            PaperTheme.hex(of: dataColor) == PaperTheme.hex(of: referenceColor),
            "\(label): hex mismatch")
        #expect(dataColor.alpha == referenceColor.alpha, "\(label): alpha")
    }

    private func expectSameShadows(_ data: [ShadowLayer], _ reference: [ShadowLayer]) throws {
        #expect(data.count == reference.count)
        for (dataLayer, referenceLayer) in zip(data, reference) {
            #expect(dataLayer.offsetY == referenceLayer.offsetY)
            #expect(dataLayer.blur == referenceLayer.blur)
            try expectSameColor(dataLayer.color, referenceLayer.color, "shadow")
        }
    }
}
