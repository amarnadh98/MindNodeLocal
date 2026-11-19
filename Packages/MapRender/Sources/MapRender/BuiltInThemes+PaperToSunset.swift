import Foundation
import MapCore

/// Built-in themes 1–6 of the SPEC §5.8 list: Paper, Graphite, Pastel,
/// Ocean, Forest, Sunset (ADR-0009: Swift-literal data).
extension BuiltInThemes {
    // MARK: 1. Paper — the reference theme (SPEC §7.2)

    /// Paper: the SPEC §7.2 reference. Its values mirror `PaperTheme`
    /// exactly (see `PaperThemeEquivalenceTests`); the dark palette is
    /// the §7.2 "same hues, +8% lightness" set, precomputed so the data
    /// theme renders pixel-identically to the reference implementation.
    public static let paper = Theme(
        id: "paper",
        name: "Paper",
        light: ThemeScheme(
            canvasColor: "#FAF9F7",
            palette: [
                "#E5484D", "#F76B15", "#FFC53D", "#46A758",
                "#12A594", "#0090FF", "#8E4EC6", "#D6409F",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#2C2C2E"), radius: 10,
                    shadow: raisedLightShadow, font: font(20, 0.3), text: "#FFFFFF"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.16), radius: 10,
                    font: font(16, 0.23), text: "#1C1C1E"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#1C1C1E"))),
        dark: ThemeScheme(
            canvasColor: "#1C1C1E",
            palette: [
                "#E85D62", "#F8782A", "#FFCD56", "#4CB45F",
                "#13B2A0", "#1499FF", "#995FCB", "#DA52A8",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#F2F2F7"), radius: 10,
                    shadow: raisedDarkShadow, font: font(20, 0.3), text: "#1C1C1E"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.24), radius: 10,
                    font: font(16, 0.23), text: "#F2F2F7"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#F2F2F7"))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 6, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))

    // MARK: 2. Graphite

    /// Graphite: monochrome grays, quiet ink-on-white with charcoal
    /// branches cycling through gray steps.
    public static let graphite = Theme(
        id: "graphite",
        name: "Graphite",
        light: ThemeScheme(
            canvasColor: "#FFFFFF",
            palette: [
                "#2C2C2E", "#3A3A3C", "#48484A", "#5B5B60",
                "#6E6E73", "#7C7C82", "#8E8E93", "#1D1D1F",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#1D1D1F"), radius: 10,
                    shadow: raisedLightShadow, font: font(20, 0.3), text: "#FFFFFF"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.10), radius: 8,
                    font: font(16, 0.23), text: "#1D1D1F"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#1D1D1F"))),
        dark: ThemeScheme(
            canvasColor: "#161618",
            palette: [
                "#E5E5EA", "#D1D1D6", "#C7C7CC", "#AEAEB2",
                "#98989D", "#8E8E93", "#7C7C82", "#F2F2F7",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#F2F2F7"), radius: 10,
                    shadow: raisedDarkShadow, font: font(20, 0.3), text: "#1C1C1E"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.16), radius: 8,
                    font: font(16, 0.23), text: "#F2F2F7"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#F2F2F7"))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 5, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))

    // MARK: 3. Pastel

    /// Pastel: soft candy colors, pill-shaped level-1 nodes.
    public static let pastel = Theme(
        id: "pastel",
        name: "Pastel",
        light: ThemeScheme(
            canvasColor: "#FDFCF8",
            palette: [
                "#EFA9B8", "#F5C26B", "#F0E6A5", "#A3D9A5",
                "#9FD8D0", "#A9C7EE", "#C3B1E1", "#F0B6D0",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#6B5B7B"), radius: 14,
                    shadow: softLightShadow, font: font(20, 0.3), text: "#FFFFFF"),
                one: level(
                    .pill, fill: .palette(alpha: 0.35),
                    font: font(16, 0.23), text: "#3A3140"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#3A3140"))),
        dark: ThemeScheme(
            canvasColor: "#26222B",
            palette: [
                "#D98CA0", "#D9A45B", "#CBBF7A", "#7FBF8E",
                "#6FBFB4", "#7FA3D9", "#A98FC9", "#C98FB0",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#F2EDE4"), radius: 14,
                    shadow: raisedDarkShadow, font: font(20, 0.3), text: "#26222B"),
                one: level(
                    .pill, fill: .palette(alpha: 0.22),
                    font: font(16, 0.23), text: "#F2EDE4"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#F2EDE4"))),
        branch: ThemeBranchStyle(lineStyle: .curved, startWidth: 5, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))

    // MARK: 4. Ocean

    /// Ocean: blues and teals, calm and cool.
    public static let ocean = Theme(
        id: "ocean",
        name: "Ocean",
        light: ThemeScheme(
            canvasColor: "#F4F9FC",
            palette: [
                "#0F5E8C", "#117A8B", "#12A594", "#2E86AB",
                "#3F7CB8", "#5FA8D3", "#277DA1", "#6BB8CC",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#0D3B54"), radius: 12,
                    shadow: raisedLightShadow, font: font(20, 0.3), text: "#FFFFFF"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.18), radius: 10,
                    font: font(16, 0.23), text: "#14232E"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#14232E"))),
        dark: ThemeScheme(
            canvasColor: "#0C1A24",
            palette: [
                "#4FC3F7", "#46B5D6", "#3DDAD7", "#5FA8D3",
                "#74C0E3", "#2FB4A8", "#89D4F0", "#6EC9B8",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#DCEFF9"), radius: 12,
                    shadow: raisedDarkShadow, font: font(20, 0.3), text: "#0C1A24"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.20), radius: 10,
                    font: font(16, 0.23), text: "#EAF4FA"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#EAF4FA"))),
        branch: ThemeBranchStyle(lineStyle: .curved, startWidth: 5, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))

    // MARK: 5. Forest

    /// Forest: greens with bark and moss accents.
    public static let forest = Theme(
        id: "forest",
        name: "Forest",
        light: ThemeScheme(
            canvasColor: "#F6FAF3",
            palette: [
                "#1B4332", "#2D6A4F", "#40916C", "#52B788",
                "#6A994E", "#8AB17D", "#936639", "#B7A16A",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#1B4332"), radius: 12,
                    shadow: raisedLightShadow, font: font(20, 0.3), text: "#FFFFFF"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.16), radius: 10,
                    font: font(16, 0.23), text: "#1B241C"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#1B241C"))),
        dark: ThemeScheme(
            canvasColor: "#0F1712",
            palette: [
                "#74C69D", "#95D5B2", "#52B788", "#B7E4C7",
                "#6A994E", "#A3B18A", "#BCA37E", "#8FCB9B",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#E9F2E4"), radius: 12,
                    shadow: raisedDarkShadow, font: font(20, 0.3), text: "#101710"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.15), radius: 10,
                    font: font(16, 0.23), text: "#EDF5EA"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#EDF5EA"))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 5, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))

    // MARK: 6. Sunset

    /// Sunset: warm horizon colors, coral to dusk purple.
    public static let sunset = Theme(
        id: "sunset",
        name: "Sunset",
        light: ThemeScheme(
            canvasColor: "#FFF7F0",
            palette: [
                "#E63946", "#F77F00", "#FCBF49", "#FCA311",
                "#E76F51", "#D64550", "#9B5D77", "#6D597A",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#6D2E46"), radius: 12,
                    shadow: raisedLightShadow, font: font(20, 0.3), text: "#FFFFFF"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.16), radius: 10,
                    font: font(16, 0.23), text: "#33272A"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#33272A"))),
        dark: ThemeScheme(
            canvasColor: "#1F1215",
            palette: [
                "#FF6B6B", "#FF8E72", "#FFB86B", "#FFD166",
                "#F4978E", "#E5989B", "#C77DAA", "#9D6B8D",
            ],
            levels: levels(
                root: level(
                    .roundedRect, fill: .solid("#FFE8D6"), radius: 12,
                    shadow: raisedDarkShadow, font: font(20, 0.3), text: "#1F1215"),
                one: level(
                    .roundedRect, fill: .palette(alpha: 0.15), radius: 10,
                    font: font(16, 0.23), text: "#FFF1E6"),
                two: level(
                    .underline, fill: .none, border: ThemeBorder(paint: .palette, width: 2),
                    radius: 0, padWidth: 2, padHeight: 2, font: font(14), text: "#FFF1E6"))),
        branch: ThemeBranchStyle(lineStyle: .tapered, startWidth: 6, endWidth: 2),
        rainbowBranches: true,
        connection: connection("#8E8E93"),
        boundary: boundary("#8E8E93"))
}
