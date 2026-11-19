import AppKit
import MapCore
import MapRender
import SwiftUI

/// F-STY-7 color picking, in order: the theme's branch palette first,
/// then recently used colors, then the system color panel. Selecting a
/// swatch performs the caller's `onPick` (one `MapStore` command); the
/// current value shows a ring, an override shows the dot, and a
/// "Mixed" selection keeps the placeholder until the user picks.
struct ColorPickerRow: View {
    let title: String
    let currentHex: String?
    let overridden: Bool
    let mixed: Bool
    let palette: [String]
    let noneAllowed: Bool
    let onPick: (String?) -> Void
    let onReset: () -> Void

    @State private var panelProxy: ColorPanelProxy?

    /// F-STY-7: the recent list, minus colors the palette already
    /// offers (newest first, capped for the row's width).
    private var recents: [String] {
        var seen = Set(palette.map { $0.lowercased() })
        var result: [String] = []
        for hex in DocumentPreferences.recentColors where !seen.contains(hex.lowercased()) {
            seen.insert(hex.lowercased())
            result.append(hex)
            if result.count == 6 { break }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(spacing: 4) {
                if noneAllowed {
                    noFillButton
                }
                ForEach(Array(palette.enumerated()), id: \.offset) { _, hex in
                    swatch(hex)
                }
                if let current = currentHex, !palette.contains(current) {
                    swatch(current)
                }
                if !recents.isEmpty {
                    Rectangle()
                        .fill(Color.black.opacity(0.15))
                        .frame(width: 1, height: 14)
                        .accessibilityHidden(true)
                    ForEach(Array(recents.enumerated()), id: \.offset) { _, hex in
                        swatch(hex, recent: true)
                    }
                }
                otherButton
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) color picker")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if overridden {
                OverrideDot()
            } else if mixed {
                Text("Mixed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if overridden {
                Button("Reset to theme", action: onReset)
                    .controlSize(.small)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func swatch(_ hex: String, recent: Bool = false) -> some View {
        let selected = currentHex?.lowercased() == hex.lowercased()
        return Button {
            onPick(hex)
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: hex))
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            selected ? Color.accentColor : Color.black.opacity(0.2),
                            lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recent ? "Recent color \(hex)" : "Color \(hex)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var noFillButton: some View {
        Button {
            onPick(nil)
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.clear)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.black.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("No fill")
    }

    private var otherButton: some View {
        Button("Other…") {
            openColorPanel()
        }
        .controlSize(.small)
        .buttonStyle(.link)
        .font(.caption)
        .accessibilityLabel("Other colors, system color panel")
    }

    /// The system color panel (last resort per F-STY-7), kept open and
    /// observed while this row lives.
    private func openColorPanel() {
        let panel = NSColorPanel.shared
        let proxy = ColorPanelProxy { hex in
            onPick(hex)
        }
        panel.setTarget(proxy)
        panel.setAction(#selector(ColorPanelProxy.colorDidChange(_:)))
        panelProxy = proxy
        panel.orderFront(nil)
    }
}

/// Bridges `NSColorPanel`'s target-action to a closure, converting the
/// picked color back into the model's `#RRGGBB` notation.
@MainActor
private final class ColorPanelProxy: NSObject {
    private let onPick: (String) -> Void

    init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        super.init()
    }

    @objc func colorDidChange(_ sender: NSColorPanel) {
        guard let hex = sender.color.hexString else { return }
        onPick(hex)
    }
}

/// The F-STY-3 override marker: a small dot next to every property the
/// selection overrides, plus the row's "Reset to theme" affordance.
struct OverrideDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 5, height: 5)
            .accessibilityLabel("Overridden, theme value differs")
    }
}

/// A labeled inspector row with the override dot and per-row reset.
struct InspectorRow<Control: View>: View {
    let title: String
    let key: NodeStyleKey
    let overridden: Bool
    let mixed: Bool
    let onReset: () -> Void
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if overridden {
                OverrideDot()
            } else if mixed {
                Text("Mixed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            control()
            if overridden {
                Button("Reset", action: onReset)
                    .controlSize(.small)
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityLabel("Reset \(title) to theme")
            }
        }
    }
}

extension Color {
    /// `#RRGGBB` (or `RRGGBB`) → SwiftUI color; unparsable strings
    /// render as the placeholder gray.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self.init(NSColor.systemGray)
            return
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

extension NSColor {
    /// The `#RRGGBB` notation for a picked panel color.
    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let red = UInt32(min(max(rgb.redComponent, 0), 1) * 255)
        let green = UInt32(min(max(rgb.greenComponent, 0), 1) * 255)
        let blue = UInt32(min(max(rgb.blueComponent, 0), 1) * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
