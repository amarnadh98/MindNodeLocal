import CoreGraphics
import CoreText
import Foundation
import MapCore
import Testing

@testable import MapRender

/// The default look for new maps: roomy, soft, rounded.
struct StudioThemeTests {
    @Test func studioIsTheNewMapDefaultAndPaperStaysTheEngineFallback() {
        #expect(BuiltInThemes.newDocumentDefaultID == "studio")
        #expect(BuiltInThemes.theme(id: "studio").name == "Studio")
        #expect(BuiltInThemes.defaultID == "paper")
        #expect(BuiltInThemes.theme(id: "no-such-theme").id == "paper")
    }

    @Test func levelOneIsASolidPastelWithDarkTextInBothAppearances() throws {
        let studio = BuiltInThemes.theme(id: "studio")
        for variant in [ThemeVariant.light, .dark] {
            let style = studio.resolvedStyle(level: 1, level1Index: 0, variant: variant)
            let fill = try #require(style.fillColor)
            #expect(fill.alpha == 1, "\(variant): solid, not a faint tint")
            let text = try #require(PaperTheme.hex(of: style.textColor))
            #expect(text < 0x404040, "\(variant): dark text on the pastel fill")
            #expect(style.minWidth == 150, "short siblings share a width")
            #expect(style.cornerRadius >= 14)
            #expect(style.paddingWidth >= 22 && style.paddingHeight >= 12)
        }
    }

    @Test func levelTwoIsAnOutlinedRoundedBoxAndDeeperLevelsUnderline() {
        let studio = BuiltInThemes.theme(id: "studio")
        let two = studio.resolvedStyle(level: 2, level1Index: 0, variant: .dark)
        #expect(two.shape == .roundedRect)
        #expect(two.fillColor == nil)
        #expect(two.borderWidth == 2.5)
        let three = studio.resolvedStyle(level: 3, level1Index: 0, variant: .dark)
        #expect(three.shape == .underline)
    }

    @Test func thePaletteIsEightDistinctMutedColorsPerAppearance() {
        let studio = BuiltInThemes.theme(id: "studio")
        #expect(studio.light.palette.count == 8)
        #expect(Set(studio.dark.palette).count == 8)
    }

    @Test func theRoundedFamilyTokenResolvesToTheRoundedSystemFace() {
        let rounded = FontSpec(size: 18, weight: 0, family: FontSpec.roundedFamily)
        let name = CTFontCopyPostScriptName(rounded.ctFont) as String
        #expect(name.contains("Rounded"), "got \(name)")
        // A weight keeps the face rounded.
        let medium = FontSpec(size: 18, weight: 0.23, family: FontSpec.roundedFamily)
        #expect((CTFontCopyPostScriptName(medium.ctFont) as String).contains("Rounded"))
        // And it measures differently from the plain system face.
        #expect(rounded.ctFont != FontSpec(size: 18).ctFont)
    }

    @Test func branchesAreThickAndTaper() {
        let studio = BuiltInThemes.theme(id: "studio")
        #expect(studio.branchWidth(level: 0) >= 9)
        #expect(studio.branchWidth(level: 8) == 3)
    }
}
