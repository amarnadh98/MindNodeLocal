import MapCore
import MapRender
import SwiftUI

/// F-STY-2/F-STY-3: the context-aware Style tab. Sections: Node (shape,
/// fill, border, corner radius, padding, shadow, width), Text (font
/// size/weight/color, alignment) and Branch (the connector into the
/// node, ADR-0011 — disabled for a selection that includes a root);
/// Connection and Boundary are placeholders until those objects exist
/// (M3). Overridden properties carry the dot + "Reset to theme";
/// multi-selection edits apply to every selected node in one undo step,
/// with mixed values shown as such.
struct InspectorStyleTab: View {
    @ObservedObject var model: InspectorModel

    private var palette: [String] {
        BuiltInThemes.theme(id: model.themeID).light.palette
    }

    private var branchControlsDisabled: Bool {
        !model.hasSelection || model.selectionIncludesRoot
    }

    var body: some View {
        if !model.hasSelection {
            emptyState
        } else {
            Form {
                nodeSection
                textSection
                branchSection
                widthSection
                placeholderSections
            }
            .formStyle(.grouped)
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Select a node to style it")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Select a node to style it")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: node section (F-STY-1 shapes)

    private var nodeSection: some View {
        Section("Node") {
            shapeRow
            ColorPickerRow(
                title: "Fill",
                currentHex: model.value(.fill) { $0.fill == "none" ? nil : $0.fill },
                overridden: model.isOverridden(.fill),
                mixed: model.isMixed(.fill) { $0.fill },
                palette: palette,
                noneAllowed: true,
                onPick: { hex in
                    recordColor(hex)
                    apply(.fill, hex ?? "none")
                },
                onReset: { reset(.fill) })
            ColorPickerRow(
                title: "Border",
                currentHex: model.value(.borderColor) { $0.borderColor },
                overridden: model.isOverridden(.borderColor),
                mixed: model.isMixed(.borderColor) { $0.borderColor },
                palette: palette,
                noneAllowed: false,
                onPick: { hex in
                    recordColor(hex)
                    if let hex { apply(.borderColor, hex) }
                },
                onReset: { reset(.borderColor) })
            numberRow("Border Width", key: .borderWidth, range: 0...20) { apply(.borderWidth, $0) }
            toggleRow("Dashed Border", key: .borderDash) { apply(.borderDash, $0) }
            numberRow("Corner Radius", key: .cornerRadius, range: 0...40) { apply(.cornerRadius, $0) }
            numberRow("Padding", key: .padding, range: 0...40) { apply(.padding, $0) }
            pickerRow(
                "Shadow", key: .shadow,
                selection: model.value(.shadow) { $0.shadow },
                all: MapCore.ShadowStyle.allCases,
                label: { $0.rawValue.capitalized },
                set: { apply(.shadow, $0) })
        }
    }

    private var shapeRow: some View {
        pickerRow(
            "Shape", key: .shape,
            selection: model.value(.shape) { $0.shape },
            all: NodeShape.allCases,
            label: { Self.shapeName($0) },
            set: { apply(.shape, $0) })
    }

    static func shapeName(_ shape: NodeShape) -> String {
        switch shape {
        case .roundedRect: "Rounded Rect"
        case .underline: "Underline"
        case .none: "Text Only"
        default: shape.rawValue.capitalized
        }
    }

    // MARK: text section

    private var textSection: some View {
        Section("Text") {
            numberRow("Font Size", key: .fontSize, range: 8...72) { apply(.fontSize, $0) }
            pickerRow(
                "Weight", key: .fontWeight,
                selection: model.value(.fontWeight) { $0.fontWeight },
                all: [0.0, 0.23, 0.3, 0.4],
                label: { Self.weightName($0) },
                set: { apply(.fontWeight, $0) })
            ColorPickerRow(
                title: "Text Color",
                currentHex: model.value(.textColor) { $0.textColor },
                overridden: model.isOverridden(.textColor),
                mixed: model.isMixed(.textColor) { $0.textColor },
                palette: palette,
                noneAllowed: false,
                onPick: { hex in
                    recordColor(hex)
                    if let hex { apply(.textColor, hex) }
                },
                onReset: { reset(.textColor) })
            pickerRow(
                "Alignment", key: .alignment,
                selection: model.value(.alignment) { $0.alignment },
                all: ["left", "center", "right"],
                label: { $0.capitalized },
                set: { apply(.alignment, $0) })
        }
    }

    static func weightName(_ weight: Double) -> String {
        switch weight {
        case ..<0.1: "Regular"
        case ..<0.27: "Medium"
        case ..<0.35: "Semibold"
        default: "Bold"
        }
    }

    // MARK: branch section (ADR-0011: the connector INTO the node)

    private var branchSection: some View {
        Section("Branch") {
            if branchControlsDisabled {
                Text(
                    model.selectionIncludesRoot
                        ? "Roots have no incoming branch." : "Select a node to style its branch."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ColorPickerRow(
                    title: "Branch Color",
                    currentHex: model.value(.branchColor) { $0.branchColor },
                    overridden: model.isOverridden(.branchColor),
                    mixed: model.isMixed(.branchColor) { $0.branchColor },
                    palette: palette,
                    noneAllowed: false,
                    onPick: { hex in
                        recordColor(hex)
                        if let hex { apply(.branchColor, hex) }
                    },
                    onReset: { reset(.branchColor) })
                numberRow("Branch Width", key: .branchWidth, range: 0.5...24) { apply(.branchWidth, $0) }
                numberRow("Taper", key: .branchTaper, range: 0...12) { apply(.branchTaper, $0) }
                pickerRow(
                    "Line Style", key: .branchLineStyle,
                    selection: model.value(.branchLineStyle) { $0.branchLineStyle },
                    all: BranchLineStyle.allCases.map(\.rawValue),
                    label: { $0.capitalized },
                    set: { apply(.branchLineStyle, $0) })
            }
        }
    }

    // MARK: width section

    private var widthSection: some View {
        Section("Node Width") {
            numberRow("Minimum", key: .minWidth, range: 0...400) { apply(.minWidth, $0) }
            numberRow("Maximum", key: .maxWidth, range: 40...800) { apply(.maxWidth, $0) }
        }
    }

    /// Placeholders until connections and boundaries exist in the
    /// editor (M3, F-REL-1/F-REL-3) — shown labelled and disabled so the
    /// context-aware contract is visible.
    private var placeholderSections: some View {
        Section("Connection & Boundary") {
            Text("Connection and boundary styles appear here when those objects can be selected (M3).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: generic rows

    /// A picker row: shows the shared value, or "Mixed" when the
    /// selection disagrees. Picking performs one command for all
    /// selected nodes.
    private func pickerRow<T: Equatable>(
        _ title: String, key: NodeStyleKey,
        selection: T?, all: [T], label: @escaping (T) -> String, set: @escaping (T) -> Void
    ) -> some View {
        let mixed = model.isPresenceMixed(key) || selection == nil && model.hasSelection
        return InspectorRow(
            title: title, key: key,
            overridden: model.isOverridden(key),
            mixed: mixed,
            onReset: { reset(key) },
            control: {
                Menu {
                    ForEach(Array(all.enumerated()), id: \.offset) { _, value in
                        Button(label(value)) { set(value) }
                    }
                } label: {
                    HStack {
                        Text(selection.map(label) ?? "—")
                            .foregroundStyle(selection == nil ? Color.secondary : Color.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityValue(selection.map(label) ?? "Mixed")
            }
        )
    }

    private func numberRow(
        _ title: String, key: NodeStyleKey, range: ClosedRange<Double>, set: @escaping (Double) -> Void
    ) -> some View {
        let current = model.value(key) { $0.number(forKey: key) }
        return InspectorRow(
            title: title, key: key,
            overridden: model.isOverridden(key),
            mixed: current == nil,
            onReset: { reset(key) },
            control: {
                Stepper(
                    value: Binding(
                        get: { current ?? range.lowerBound },
                        set: { set($0) }),
                    in: range
                ) {
                    Text(current.map { String(format: "%.0f", $0) } ?? "Mixed")
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                }
                .accessibilityLabel(title)
                .accessibilityValue(current.map { String(format: "%.0f", $0) } ?? "Mixed")
            }
        )
    }

    private func toggleRow(
        _ title: String, key: NodeStyleKey, set: @escaping (Bool) -> Void
    ) -> some View {
        InspectorRow(
            title: title, key: key,
            overridden: model.isOverridden(key),
            mixed: model.isPresenceMixed(key),
            onReset: { reset(key) },
            control: {
                Toggle(
                    title,
                    isOn: Binding(
                        get: { model.value(key) { $0.borderDash } ?? false },
                        set: { set($0) })
                )
                .labelsHidden()
                .accessibilityLabel(title)
            }
        )
    }

    // MARK: command routing (one MapStore command per interaction)

    private func apply(_ key: NodeStyleKey, _ raw: String) {
        model.onStylePatch?(NodeStylePatch(field: key, string: raw))
    }

    private func apply(_ key: NodeStyleKey, _ value: Double) {
        model.onStylePatch?(NodeStylePatch(field: key, number: value))
    }

    private func apply(_ key: NodeStyleKey, _ value: Bool) {
        model.onStylePatch?(NodeStylePatch(field: key, bool: value))
    }

    private func apply(_ key: NodeStyleKey, _ shape: NodeShape) {
        model.onStylePatch?(NodeStylePatch(shape: shape))
    }

    private func apply(_ key: NodeStyleKey, _ shadow: MapCore.ShadowStyle) {
        model.onStylePatch?(NodeStylePatch(shadow: shadow))
    }

    private func reset(_ key: NodeStyleKey) {
        model.onResetKeys?([key])
    }

    private func recordColor(_ hex: String?) {
        if let hex {
            DocumentPreferences.noteColorPick(hex)
        }
    }
}

extension NodeStylePatch {
    fileprivate init(field: NodeStyleKey, string: String) {
        self.init()
        switch field {
        case .fill: fill = string
        case .borderColor: borderColor = string
        case .textColor: textColor = string
        case .branchColor: branchColor = string
        case .alignment: alignment = string
        case .branchLineStyle: branchLineStyle = string
        default: break
        }
    }

    fileprivate init(field: NodeStyleKey, number: Double) {
        self.init()
        switch field {
        case .borderWidth: borderWidth = number
        case .cornerRadius: cornerRadius = number
        case .padding: padding = number
        case .fontSize: fontSize = number
        case .fontWeight: fontWeight = number
        case .branchWidth: branchWidth = number
        case .branchTaper: branchTaper = number
        case .minWidth: minWidth = number
        case .maxWidth: maxWidth = number
        default: break
        }
    }

    fileprivate init(field: NodeStyleKey, bool: Bool) {
        self.init()
        switch field {
        case .borderDash: borderDash = bool
        default: break
        }
    }

    fileprivate func number(forKey key: NodeStyleKey) -> Double? {
        switch key {
        case .borderWidth: borderWidth
        case .cornerRadius: cornerRadius
        case .padding: padding
        case .fontSize: fontSize
        case .fontWeight: fontWeight
        case .branchWidth: branchWidth
        case .branchTaper: branchTaper
        case .minWidth: minWidth
        case .maxWidth: maxWidth
        default: nil
        }
    }
}
