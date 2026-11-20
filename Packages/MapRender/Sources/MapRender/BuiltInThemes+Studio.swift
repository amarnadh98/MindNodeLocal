import Foundation
import MapCore

/// The default theme for new maps. Roomier and softer than Paper: solid
/// pastel level-1 fills with dark text in both appearances, outlined
/// rounded leaves, thick tapered branches that tuck behind their nodes,
/// and the rounded system face. Paper stays as the classic reference.
extension BuiltInThemes {
    private static let rounded = FontSpec.roundedFamily

    public static let studio = Theme(
        id: "studio",
        name: "Studio",
        light: ThemeScheme(
            canvasColor: "#FBFAF8",
            palette: [
                "#E9868B", "#F0A367", "#E6C463", "#85BD92",
                "#6FB3B0", "#8BA6DE", "#A58FD0", "#D88DB8",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#2E2A2D"), radius: 18, padWidth: 30, padHeight: 20,
                    shadow: softLightShadow, font: font(26, 0.1, family: rounded), text: "#FBF4F8",
                    maxWidth: 340),
                one: level(
                    .roundedRect, fill: .palette(alpha: 1), radius: 16, padWidth: 24, padHeight: 14,
                    font: font(18, 0.0, family: rounded), text: "#1F1D20", maxWidth: 320, minWidth: 150),
                two: level(
                    .roundedRect, fill: .none, border: ThemeBorder(paint: .palette, width: 2.5),
                    radius: 14, padWidth: 16, padHeight: 9,
                    font: font(16, 0.0, family: rounded), text: "#1F1D20", maxWidth: 300, minWidth: 56),
                threePlus: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2.5),
                    radius: 0, padWidth: 2, padHeight: 3,
                    font: font(15, 0.0, family: rounded), text: "#1F1D20"))),
        dark: ThemeScheme(
            canvasColor: "#1B1B1D",
            palette: [
                "#E7969A", "#EDAE80", "#E4CB82", "#98C7A3",
                "#86BEBA", "#9DB4E2", "#B3A2D6", "#DDA0C3",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#3C353A"), radius: 18, padWidth: 30, padHeight: 20,
                    shadow: [], font: font(26, 0.1, family: rounded), text: "#F6EEF3",
                    maxWidth: 340),
                one: level(
                    .roundedRect, fill: .palette(alpha: 1), radius: 16, padWidth: 24, padHeight: 14,
                    font: font(18, 0.0, family: rounded), text: "#1B1B1D", maxWidth: 320, minWidth: 150),
                two: level(
                    .roundedRect, fill: .none, border: ThemeBorder(paint: .palette, width: 2.5),
                    radius: 14, padWidth: 16, padHeight: 9,
                    font: font(16, 0.0, family: rounded), text: "#F4F1F3", maxWidth: 300, minWidth: 56),
                threePlus: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2.5),
                    radius: 0, padWidth: 2, padHeight: 3,
                    font: font(15, 0.0, family: rounded), text: "#F4F1F3"))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 9, endWidth: 3),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))
}
