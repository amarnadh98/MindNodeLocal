import Foundation
import MapCore

/// Built-in themes 7–12 of the SPEC §5.8 list: Mono Ink, Chalkboard,
/// Neon, Blueprint, Sakura, Study (ADR-0009: Swift-literal data).
extension BuiltInThemes {
    // MARK: 7. Mono Ink

    /// Mono Ink: black ink on white paper — outlined level-1 boxes,
    /// thin straight branches, no shadows.
    public static let monoInk = Theme(
        id: "mono-ink",
        name: "Mono Ink",
        light: ThemeScheme(
            canvasColor: "#FDFDFB",
            palette: [
                "#0D0D0D", "#1A1A1A", "#262626", "#333333",
                "#404040", "#4D4D4D", "#595959", "#666666",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#0D0D0D"), radius: 6,
                    font: font(20, 0.3), text: "#FFFFFF"),
                one: level(
                    .rectangle, fill: .none, border: ThemeBorder(paint: .palette, width: 1.5),
                    radius: 0, font: font(16, 0.23), text: "#0D0D0D"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 1.5),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#0D0D0D"))),
        dark: ThemeScheme(
            canvasColor: "#0A0A0A",
            palette: [
                "#F5F5F5", "#E8E8E8", "#DBDBDB", "#CFCFCF",
                "#C2C2C2", "#B5B5B5", "#A8A8A8", "#9B9B9B",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#F5F5F5"), radius: 6,
                    font: font(20, 0.3), text: "#0A0A0A"),
                one: level(
                    .rectangle, fill: .none, border: ThemeBorder(paint: .palette, width: 1.5),
                    radius: 0, font: font(16, 0.23), text: "#F5F5F5"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 1.5),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#F5F5F5"))),
        branch: ThemeBranchStyle(lineStyle: .straight, startWidth: 3, endWidth: 1.5),
        rainbowBranches: true,
        connection: connection("#0D0D0D"),
        boundary: boundary("#0D0D0D"))

    // MARK: 8. Chalkboard (dark-first)

    /// Chalkboard: chalk strokes on a green board; the light variant is
    /// the same palette as colored pencil on warm paper.
    public static let chalkboard = Theme(
        id: "chalkboard",
        name: "Chalkboard",
        light: ThemeScheme(
            canvasColor: "#EFEBE0",
            palette: [
                "#2F3E46", "#3D405B", "#5C4D7D", "#264653",
                "#2A9D8F", "#BC6C25", "#936639", "#588157",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#2F3E46"), radius: 12,
                    shadow: softLightShadow, font: font(20, 0.3), text: "#FFFFFF"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.16), radius: 10,
                    font: font(16, 0.23), text: "#2A2E2B"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#2A2E2B"))),
        dark: ThemeScheme(
            canvasColor: "#1E3A34",
            palette: [
                "#F8F9FA", "#FFE066", "#F6BD60", "#FFC2C7",
                "#9EE7FF", "#B5EAD7", "#CDB4DB", "#FFD6A5",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#F4F6F1"), radius: 12,
                    font: font(20, 0.3), text: "#1E3A34"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.14), radius: 10,
                    font: font(16, 0.23), text: "#F4F6F1"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#F4F6F1"))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 5, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))

    // MARK: 9. Neon (dark-first)

    /// Neon: electric hues glowing on a near-black canvas.
    public static let neon = Theme(
        id: "neon",
        name: "Neon",
        light: ThemeScheme(
            canvasColor: "#F3F4FA",
            palette: [
                "#D61694", "#0077B6", "#2FBF41", "#D9A400",
                "#E85D04", "#6247AA", "#E01E5A", "#4E9F3D",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#1A0B2E"), radius: 12,
                    shadow: softLightShadow, font: font(20, 0.3), text: "#F0F3FF"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.14), radius: 10,
                    font: font(16, 0.23), text: "#15121F"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#15121F"))),
        dark: ThemeScheme(
            canvasColor: "#0B0B14",
            palette: [
                "#FF2EC4", "#00F0FF", "#39FF14", "#FFE93B",
                "#FF6B2B", "#7A5CFF", "#FF3D67", "#C6FF00",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#F0F3FF"), radius: 12,
                    font: font(20, 0.3), text: "#0B0B14"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.12), radius: 10,
                    font: font(16, 0.23), text: "#F0F3FF"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#F0F3FF"))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 6, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))

    // MARK: 10. Blueprint (dark-first)

    /// Blueprint: white technical drawing on cyanotype blue; monospace
    /// labels, straight branches, one ink color.
    public static let blueprint = Theme(
        id: "blueprint",
        name: "Blueprint",
        light: ThemeScheme(
            canvasColor: "#F5F9FD",
            palette: [
                "#0F2A4A", "#1D4E89", "#274C77", "#16425B",
                "#3C6E9F", "#5B7C99", "#30597B", "#142F4F",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#16324F"), radius: 4,
                    shadow: softLightShadow, font: font(20, 0.3, monospace: true), text: "#FFFFFF"),
                one: level(
                    .rectangle, fill: .none, border: ThemeBorder(paint: .palette, width: 1.5),
                    radius: 2, font: font(16, 0.23, monospace: true), text: "#16324F"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 1.5),
                    radius: 0, padWidth: 2, padHeight: 2,
                    font: font(14, monospace: true), text: "#16324F"))),
        dark: ThemeScheme(
            canvasColor: "#14385C",
            palette: [
                "#EAF2FF", "#DCEBFF", "#C8DCFF", "#BFD9FF",
                "#A8CBF5", "#9CC2FF", "#8FB4E8", "#DDEBFF",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#EAF2FF"), radius: 4,
                    font: font(20, 0.3, monospace: true), text: "#14385C"),
                one: level(
                    .rectangle, fill: .none, border: ThemeBorder(paint: .palette, width: 1.5),
                    radius: 2, font: font(16, 0.23, monospace: true), text: "#EAF2FF"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 1.5),
                    radius: 0, padWidth: 2, padHeight: 2,
                    font: font(14, monospace: true), text: "#EAF2FF"))),
        branch: ThemeBranchStyle(lineStyle: .straight, startWidth: 3, endWidth: 1.5),
        rainbowBranches: false,
        connection: connection("#274C77"),
        boundary: boundary("#274C77"))

    // MARK: 11. Sakura

    /// Sakura: cherry-blossom pinks with a serif voice.
    public static let sakura = Theme(
        id: "sakura",
        name: "Sakura",
        light: ThemeScheme(
            canvasColor: "#FDF5F6",
            palette: [
                "#C9184A", "#A4133C", "#800F2F", "#FF4D6D",
                "#FF758F", "#F4978E", "#FFB3C1", "#B83B5E",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#801536"), radius: 14,
                    shadow: softLightShadow, font: font(20, 0.3, family: "New York"), text: "#FFFFFF"),
                one: level(
                    .pill, fill: .palette(alpha: 0.18),
                    font: font(16, 0.23, family: "New York"), text: "#3D2024"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2,
                    font: font(14, family: "New York"), text: "#3D2024"))),
        dark: ThemeScheme(
            canvasColor: "#221116",
            palette: [
                "#FF758F", "#FF8FA3", "#FFB3C1", "#FF4D6D",
                "#F4978E", "#FFC2C7", "#FF5D8F", "#FFA1B5",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#FFD9DE"), radius: 14,
                    shadow: raisedDarkShadow, font: font(20, 0.3, family: "New York"), text: "#221116"),
                one: level(
                    .pill, fill: .palette(alpha: 0.16),
                    font: font(16, 0.23, family: "New York"), text: "#FDEEF0"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2,
                    font: font(14, family: "New York"), text: "#FDEEF0"))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 6, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#A4133C"),
        boundary: boundary("#A4133C"))

    // MARK: 12. Study

    /// Study: high contrast, chunky branches and bigger type — built
    /// for learning maps (SPEC §5.8).
    public static let study = Theme(
        id: "study",
        name: "Study",
        light: ThemeScheme(
            canvasColor: "#FFFFFF",
            palette: [
                "#C62828", "#AD1457", "#6A1B9A", "#283593",
                "#0277BD", "#00695C", "#2E7D32", "#E65100",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#111111"), radius: 10,
                    shadow: softLightShadow, font: font(22, 0.3), text: "#FFFFFF", maxWidth: 320),
                one: level(
                    .pill, fill: .palette(alpha: 0.18),
                    border: ThemeBorder(paint: .palette, width: 1.5),
                    font: font(17, 0.23), text: "#111111", maxWidth: 320),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2.5),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(15), text: "#111111",
                    maxWidth: 320))),
        dark: ThemeScheme(
            canvasColor: "#0A0A0A",
            palette: [
                "#EF5350", "#EC407A", "#AB47BC", "#5C6BC0",
                "#29B6F6", "#26A69A", "#66BB6A", "#FFA726",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#FFFFFF"), radius: 10,
                    shadow: raisedDarkShadow, font: font(22, 0.3), text: "#0A0A0A", maxWidth: 320),
                one: level(
                    .pill, fill: .palette(alpha: 0.20),
                    border: ThemeBorder(paint: .palette, width: 1.5),
                    font: font(17, 0.23), text: "#FFFFFF", maxWidth: 320),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2.5),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(15), text: "#FFFFFF",
                    maxWidth: 320))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 6, endWidth: 3),
        rainbowBranches: true,
        connection: connection("#111111"),
        boundary: boundary("#111111"))
}
