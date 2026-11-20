import AppKit
import MapCore
import MapRender
import SwiftUI

/// One level's style controls (F-STY-5's "Root / Level 1 / Level 2 /
/// Level 3+" rows): shape, fill, typography, text color, corner
/// radius. Internal so `ThemeEditorView`'s groups can host it.
struct LevelStyleForm: View {
    let title: String
    let style: ThemeLevelStyle
    let onStyle: (ThemeLevelStyle) -> Void

    private var weightName: String {
        Self.weightNames.first { abs(style.font.weight - $0.value) < 0.01 }?.name ?? "Regular"
    }

    private static let weightNames: [(name: String, value: Double)] = [
        ("Regular", 0.0), ("Medium", 0.23), ("Semibold", 0.3), ("Bold", 0.4),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Picker(
                "Shape",
                selection: Binding(
                    get: { style.shape },
                    set: { onStyle(style.with(shape: $0)) }
                )
            ) {
                ForEach(NodeShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            HStack {
                Picker(
                    "Fill",
                    selection: Binding(
                        get: { style.fill.kind },
                        set: { onStyle(style.with(fill: ThemeFill(kind: $0, previous: style.fill))) }
                    )
                ) {
                    Text("None").tag(ThemeFill.FillKind.none)
                    Text("Solid").tag(ThemeFill.FillKind.solid)
                    Text("Palette").tag(ThemeFill.FillKind.palette)
                }
                .frame(width: 150)
                if case .palette(let alpha) = style.fill {
                    Slider(
                        value: Binding(
                            get: { alpha },
                            set: { onStyle(style.with(fill: .palette(alpha: $0))) }
                        ),
                        in: 0.05...1
                    ) {
                        Text("Palette alpha")
                    }
                    .accessibilityLabel("Palette alpha for \(title)")
                    Text("\(Int((alpha * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40)
                } else if case .solid(let hex) = style.fill {
                    ColorField(
                        label: "Fill color", hex: hex,
                        onHex: {
                            onStyle(style.with(fill: .solid($0)))
                        })
                }
            }
            HStack {
                Stepper(
                    value: Binding(
                        get: { style.font.size },
                        set: { onStyle(style.with(font: style.font.with(size: $0))) }
                    ),
                    in: 8...48,
                    step: 1
                ) {
                    LabeledContent("Font size", value: style.font.size.formatted())
                }
                Picker(
                    "Weight",
                    selection: Binding(
                        get: { weightName },
                        set: { name in
                            if let match = Self.weightNames.first(where: { $0.name == name }) {
                                onStyle(style.with(font: style.font.with(weight: match.value)))
                            }
                        }
                    )
                ) {
                    ForEach(Self.weightNames, id: \.name) { entry in
                        Text(entry.name).tag(entry.name)
                    }
                }
                .frame(width: 120)
                ColorField(
                    label: "Text color", hex: style.textColor,
                    onHex: { onStyle(style.with(textColor: $0)) })
            }
            Stepper(
                value: Binding(
                    get: { style.cornerRadius },
                    set: { onStyle(style.with(cornerRadius: $0)) }
                ),
                in: 0...40,
                step: 1
            ) {
                LabeledContent("Corner radius", value: Int(style.cornerRadius).formatted())
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A hex color row: a `ColorWell` plus the `#RRGGBB` text — the well
/// writes back through the same on-hex path as typing, so the two can
/// never disagree.
struct ColorField: View {
    let label: String
    let hex: String
    let onHex: (String) -> Void

    @State private var wellColor = Color.white

    var body: some View {
        HStack {
            ColorPicker(
                "",
                selection: Binding(
                    get: { ColorField.color(fromHex: hex) ?? wellColor },
                    set: { newValue in
                        wellColor = newValue
                        if let updated = ColorField.hex(from: newValue) {
                            onHex(updated)
                        }
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .accessibilityLabel(label)
            TextField(
                label,
                text: Binding(
                    get: { hex },
                    set: { updated in
                        let trimmed = updated.trimmingCharacters(in: .whitespaces)
                        if ThemeHex.color(trimmed) != nil {
                            onHex(trimmed.hasPrefix("#") ? trimmed : "#" + trimmed)
                        }
                    }
                )
            )
            .frame(width: 90)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: NSFont.smallSystemFontSize, design: .monospaced))
            .onChange(of: hex) { _, newValue in
                wellColor = ColorField.color(fromHex: newValue) ?? wellColor
            }
        }
    }

    /// `#RRGGBB` → SwiftUI `Color` (through the theme's own parser).
    static func color(fromHex raw: String) -> Color? {
        guard let resolved = ThemeHex.color(raw) else { return nil }
        return Color(cgColor: resolved)
    }

    /// SwiftUI `Color` → `#RRGGBB`, or nil for anything non-sRGB.
    static func hex(from color: Color) -> String? {
        guard let converted = try? NSColor(color) else { return nil }
        let inSRGB = converted.usingColorSpace(.sRGB) ?? converted
        let red = min(max(inSRGB.redComponent, 0), 1) * 255
        let green = min(max(inSRGB.greenComponent, 0), 1) * 255
        let blue = min(max(inSRGB.blueComponent, 0), 1) * 255
        return ThemeHex.string(
            (UInt32(red.rounded()) << 16) | (UInt32(green.rounded()) << 8) | UInt32(blue.rounded()))
    }
}
