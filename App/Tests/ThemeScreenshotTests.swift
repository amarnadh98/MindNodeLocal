import AppKit
import Foundation
import MapCore
import MapRender
import Testing

@testable import Arbor

/// The M2 exit-criterion screenshot set (SPEC §16): every built-in
/// theme, light and dark, rendered through the REAL app surface —
/// `SceneGeometry` + `SceneRenderer`, the same shared pair the canvas,
/// export and Quick Look draw with (the theme editor's preview
/// renderer, `ThemeEditorModel.renderPreview`). Rendering in a test
/// (not a hand-made mock) is the point: the PNGs can only exist if the
/// shared path draws the theme correctly.
///
/// The test host runs under the app sandbox, so the files land in the
/// container's Application Support and the path is printed; the repo
/// copy under `docs/design/themes/` (the committed set) is a one-line
/// `cp` from there — see ADR-0024. When the renderer or a theme
/// changes, re-running this test refreshes the set: that is the drift
/// check the exit criterion wants.
@MainActor
struct ThemeScreenshotTests {
    /// Where the sandboxed test host may write.
    static var screenshotDirectory: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "ArborScreenshots", directoryHint: .isDirectory)
    }

    @Test func writesEveryBuiltInThemeInBothVariants() throws {
        // The tour map is the showcase: a root, eight palette-colored
        // level-1 branches, underlined deeper levels, notes.
        let map = SampleMap.buildModel()
        let size = CGSize(width: 1000, height: 700)

        let directory = Self.screenshotDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [URL] = []
        for theme in BuiltInThemes.all {
            for variant in [ThemeVariant.light, .dark] {
                let name = "\(theme.id)-\(variant == .light ? "light" : "dark").png"
                guard
                    let image = ThemeEditorModel.renderPreview(
                        theme: theme, map: map, variant: variant, size: size)
                else {
                    Issue.record("no preview rendered for \(theme.id) \(variant)")
                    continue
                }
                guard let tiff = image.tiffRepresentation,
                    let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                else {
                    Issue.record("no PNG bytes for \(theme.id) \(variant)")
                    continue
                }
                let url = directory.appending(path: name)
                try png.write(to: url)
                written.append(url)
            }
        }

        #expect(written.count == BuiltInThemes.all.count * 2)
        // Every file carries real pixels (non-trivial size).
        for url in written {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            #expect(size > 20_000, "\(url.lastPathComponent) looks empty (\(size) bytes)")
        }
        // The copy step's source path, visible in the test log.
        print("THEME SCREENSHOTS: \(directory.path)")
    }
}
