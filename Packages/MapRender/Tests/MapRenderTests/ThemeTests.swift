import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// The `.arbortheme` JSON contract (F-STY-5): every built-in theme round
/// trips through the same `Codable` schema the theme editor will use for
/// import/export, and a hand-written theme file decodes.
struct ThemeTests {
    @Test func builtInThemesRoundTripThroughThemeJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for theme in BuiltInThemes.all {
            let data = try encoder.encode(theme)
            let decoded = try JSONDecoder().decode(Theme.self, from: data)
            #expect(decoded == theme, "theme \(theme.id) must survive a JSON round trip")
        }
    }

    @Test func decodesHandWrittenArborThemeJSON() throws {
        let json = """
            {
              "id" : "workshop",
              "name" : "Workshop",
              "light" : {
                "canvasColor" : "#FEFDFB",
                "palette" : ["#B4412F", "#C67A3B", "#8A6F3D", "#57704A",
                             "#456F73", "#505F8A", "#6A4E8C", "#8C4A75"],
                "levels" : {
                  "root" : {
                    "shape" : "roundedRect", "fill" : "#3F2E20",
                    "cornerRadius" : 8, "paddingWidth" : 18, "paddingHeight" : 12,
                    "shadow" : [ { "offsetY" : 2, "blur" : 6, "color" : "#000000", "alpha" : 0.12 } ],
                    "font" : { "size" : 21, "weight" : 0.3, "family" : null,
                               "italic" : false, "monospace" : false },
                    "textColor" : "#FFF8F0", "maxWidth" : 300
                  },
                  "level1" : {
                    "shape" : "pill", "fill" : { "palette" : 0.18 },
                    "border" : { "paint" : "palette", "width" : 1.5, "dash" : false },
                    "cornerRadius" : 20, "paddingWidth" : 16, "paddingHeight" : 10,
                    "shadow" : [ ], "font" : { "size" : 16, "weight" : 0.23, "family" : null,
                                               "italic" : false, "monospace" : false },
                    "textColor" : "#2E241B", "maxWidth" : 280
                  },
                  "level2" : {
                    "shape" : "underline", "fill" : "none",
                    "border" : { "paint" : "palette", "width" : 2, "dash" : false },
                    "cornerRadius" : 0, "paddingWidth" : 2, "paddingHeight" : 2,
                    "shadow" : [ ], "font" : { "size" : 14, "weight" : 0.0, "family" : null,
                                               "italic" : false, "monospace" : false },
                    "textColor" : "#2E241B", "maxWidth" : 280
                  },
                  "level3Plus" : {
                    "shape" : "underline", "fill" : "none",
                    "border" : { "paint" : "palette", "width" : 2, "dash" : false },
                    "cornerRadius" : 0, "paddingWidth" : 2, "paddingHeight" : 2,
                    "shadow" : [ ], "font" : { "size" : 13, "weight" : 0.0, "family" : null,
                                               "italic" : false, "monospace" : false },
                    "textColor" : "#2E241B", "maxWidth" : 280
                  }
                }
              },
              "dark" : {
                "canvasColor" : "#221D18",
                "palette" : ["#E08A6D", "#D9B076", "#C7B98A", "#A6C29A",
                             "#8FC3C7", "#9DABD3", "#BFA6DE", "#D9A0C4"],
                "levels" : {
                  "root" : {
                    "shape" : "roundedRect", "fill" : "#F5EBDD",
                    "cornerRadius" : 8, "paddingWidth" : 18, "paddingHeight" : 12,
                    "shadow" : [ { "offsetY" : 4, "blur" : 12, "color" : "#000000", "alpha" : 0.4 } ],
                    "font" : { "size" : 21, "weight" : 0.3, "family" : null,
                               "italic" : false, "monospace" : false },
                    "textColor" : "#221D18", "maxWidth" : 300
                  },
                  "level1" : {
                    "shape" : "pill", "fill" : { "palette" : 0.18 },
                    "border" : { "paint" : "palette", "width" : 1.5, "dash" : false },
                    "cornerRadius" : 20, "paddingWidth" : 16, "paddingHeight" : 10,
                    "shadow" : [ ], "font" : { "size" : 16, "weight" : 0.23, "family" : null,
                                               "italic" : false, "monospace" : false },
                    "textColor" : "#F5EBDD", "maxWidth" : 280
                  },
                  "level2" : {
                    "shape" : "underline", "fill" : "none",
                    "border" : { "paint" : "palette", "width" : 2, "dash" : false },
                    "cornerRadius" : 0, "paddingWidth" : 2, "paddingHeight" : 2,
                    "shadow" : [ ], "font" : { "size" : 14, "weight" : 0.0, "family" : null,
                                               "italic" : false, "monospace" : false },
                    "textColor" : "#F5EBDD", "maxWidth" : 280
                  },
                  "level3Plus" : {
                    "shape" : "underline", "fill" : "none",
                    "border" : { "paint" : "palette", "width" : 2, "dash" : false },
                    "cornerRadius" : 0, "paddingWidth" : 2, "paddingHeight" : 2,
                    "shadow" : [ ], "font" : { "size" : 13, "weight" : 0.0, "family" : null,
                                               "italic" : false, "monospace" : false },
                    "textColor" : "#F5EBDD", "maxWidth" : 280
                  }
                }
              },
              "branch" : { "lineStyle" : "tapered", "startWidth" : 6, "endWidth" : 2 },
              "rainbowBranches" : true,
              "connection" : { "color" : "#8E8E93", "width" : 1.5, "dash" : true, "arrowEnd" : true },
              "boundary" : { "strokeColor" : "#8E8E93", "fillColor" : "#8E8E93",
                             "cornerRadius" : 16, "padding" : 14 }
            }
            """
        let theme = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        #expect(theme.id == "workshop")
        #expect(theme.name == "Workshop")
        #expect(theme.light.palette.count == 8)
        #expect(theme.dark.levels.style(forLevel: 9).shape == .underline)
        #expect(theme.branchWidth(level: 0) == 6)
        #expect(theme.branchWidth(level: 9) == 2)
        let style = theme.resolvedStyle(level: 1, level1Index: 3, variant: .dark)
        #expect(style.shape == .pill)
        #expect(try #require(style.fillColor).alpha == 0.18)
    }

    @Test func hexStringsParseAndFormat() {
        #expect(ThemeHex.color("#E5484D") != nil)
        #expect(ThemeHex.color("E5484D") != nil)
        #expect(ThemeHex.color("#E548") == nil)
        #expect(ThemeHex.color("nope") == nil)
        #expect(ThemeHex.string(0xE5484D) == "#E5484D")
    }
}
