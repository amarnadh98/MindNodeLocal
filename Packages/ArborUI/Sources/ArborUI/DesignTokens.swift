import CoreGraphics
import SwiftUI

/// Shared design tokens for hosted SwiftUI views (SPEC §7.2–§7.3).
public enum DesignTokens {
    /// Canvas background, light appearance (SPEC §7.2).
    public static let canvasLight = Color(
        red: 0xFA / 255.0,
        green: 0xF9 / 255.0,
        blue: 0xF7 / 255.0
    )

    /// Canvas background, dark appearance (SPEC §7.2).
    public static let canvasDark = Color(
        red: 0x1C / 255.0,
        green: 0x1C / 255.0,
        blue: 0x1E / 255.0
    )

    /// Level gap in the default spacing preset (SPEC §7.3).
    public static let levelGap: CGFloat = 56

    /// Sibling gap in the default spacing preset (SPEC §7.3).
    public static let siblingGap: CGFloat = 12

    /// Gap between subtrees of different first-level branches (SPEC §7.3).
    public static let subtreeGap: CGFloat = 24

    /// Root-to-level-1 gap in the default spacing preset (SPEC §7.3).
    public static let rootGap: CGFloat = 72
}
