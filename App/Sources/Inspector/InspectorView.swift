import MapCore
import MapLayout
import MapRender
import SwiftUI

/// The inspector (SPEC §4.1, §7.1): SwiftUI `Form`, grouped sections,
/// 11–13 pt controls, secondary section headers. Tabs: Style
/// (context-aware, F-STY-2), Layout (F-LAY-3/4/12 — the selection's
/// root-tree structure and the spacing rhythm), Theme (F-STY-4/6/8)
/// and Canvas.
struct InspectorView: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector pane", selection: $model.tab) {
                ForEach(InspectorModel.Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue.capitalized).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel("Inspector pane")

            Divider()

            Group {
                switch model.tab {
                case .style: InspectorStyleTab(model: model)
                case .layout: InspectorLayoutTab(model: model)
                case .theme: InspectorThemeTab(model: model)
                case .canvas: InspectorCanvasTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// F-LAY-3/4/12: the structure of the selection's root tree and the
/// spacing rhythm. Structure is one undoable `setStructure` on the
/// root; spacing is a user-level preference (SPEC F-SET Editing's
/// "default spacing" — the inspector is its editor), applied live to
/// the frontmost document.
struct InspectorLayoutTab: View {
    @ObservedObject var model: InspectorModel

    /// The structures the canvas resolves (SPEC §5.3; F-LAY-9/10 land
    /// post-1.0 and are not offered).
    private static let structures: [(id: String, name: String)] = [
        (LayoutStructure.mindmapBalanced.rawValue, "Mind Map, Balanced"),
        (LayoutStructure.mindmapRight.rawValue, "Mind Map, Right"),
        (LayoutStructure.mindmapLeft.rawValue, "Mind Map, Left"),
        (LayoutStructure.orgDown.rawValue, "Org Chart, Down"),
        (LayoutStructure.orgUp.rawValue, "Org Chart, Up"),
        (LayoutStructure.logicChartRight.rawValue, "Logic Chart, Right"),
    ]

    private var selectedStructure: String? {
        model.structureOverride.flatMap { raw in
            Self.structures.contains { $0.id == raw } ? raw : nil
        }
    }

    var body: some View {
        Form {
            Section("Structure") {
                if model.structureRootID == nil {
                    Text("Select a node to change its tree's structure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "Structure",
                        selection: Binding(
                            get: { selectedStructure ?? LayoutStructure.mindmapBalanced.rawValue },
                            set: {
                                model.onStructure?(
                                    $0 == LayoutStructure.mindmapBalanced.rawValue && model.structureOverride == nil
                                        ? nil
                                        : $0)
                            })
                    ) {
                        ForEach(Self.structures, id: \.id) { entry in
                            Text(entry.name).tag(entry.id)
                        }
                    }
                    .accessibilityHint("Rearranges the whole tree of the selected node's root")
                }
            }

            Section("Spacing") {
                Picker(
                    "Preset",
                    selection: Binding(
                        get: { model.spacingPreset },
                        set: { model.onSpacingPreset?($0) })
                ) {
                    Text("Narrow").tag(0)
                    Text("Default").tag(1)
                    Text("Wide").tag(2)
                }
                .accessibilityHint("Narrow and Wide are ×0.7 and ×1.4 of the default gaps")
                gapRow(
                    "Sibling Gap", current: model.customSiblingGap,
                    presetValue: presetSibling(model.spacingPreset),
                    set: { model.onCustomGaps?($0, model.customLevelGap) },
                    reset: { model.onCustomGaps?(nil, model.customLevelGap) })
                gapRow(
                    "Level Gap", current: model.customLevelGap,
                    presetValue: presetLevel(model.spacingPreset),
                    set: { model.onCustomGaps?(model.customSiblingGap, $0) },
                    reset: { model.onCustomGaps?(model.customSiblingGap, nil) })
            }
        }
        .formStyle(.grouped)
    }

    private func presetSibling(_ preset: Int) -> Double {
        switch preset {
        case 0: Double(LayoutSpacing.narrow.siblingGap)
        case 2: Double(LayoutSpacing.wide.siblingGap)
        default: Double(LayoutSpacing.default.siblingGap)
        }
    }

    private func presetLevel(_ preset: Int) -> Double {
        switch preset {
        case 0: Double(LayoutSpacing.narrow.levelGap)
        case 2: Double(LayoutSpacing.wide.levelGap)
        default: Double(LayoutSpacing.default.levelGap)
        }
    }

    /// A gap row: the preset value until the user drags, then the
    /// custom value (with a reset back to the preset).
    private func gapRow(
        _ title: String, current: Double?, presetValue: Double,
        set: @escaping (Double?) -> Void, reset: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if current != nil {
                OverrideDot()
            }
            Spacer()
            Stepper(
                value: Binding(
                    get: { current ?? presetValue },
                    set: { set($0) }),
                in: 2...120
            ) {
                Text(String(format: "%.0f pt", current ?? presetValue))
                    .frame(width: 64, alignment: .trailing)
            }
            .accessibilityLabel(title)
            if current != nil {
                Button("Reset", action: reset)
                    .controlSize(.small)
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityLabel("Reset \(title) to the preset")
            }
        }
    }
}

/// F-STY-4/6/8: the theme grid with live hover preview (view-only — no
/// command, the document never dirties), one-click apply (one undo
/// step), the rainbow-branches toggle, Recolor Branches, the
/// per-document appearance override and the default theme for new
/// documents.
struct InspectorThemeTab: View {
    @ObservedObject var model: InspectorModel

    private var effectiveRainbow: Bool {
        model.rainbowOverride ?? BuiltInThemes.theme(id: model.themeID).rainbowBranches
    }

    var body: some View {
        Form {
            Section("Themes") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 8) {
                    ForEach(BuiltInThemes.all, id: \.id) { theme in
                        ThemeTile(
                            theme: theme,
                            isSelected: theme.id == model.themeID,
                            isPreviewed: model.previewedThemeID == theme.id,
                            onHover: { inside in
                                model.onPreviewTheme?(inside ? theme.id : nil)
                            },
                            onApply: {
                                model.onPreviewTheme?(nil)
                                model.onApplyTheme?(theme.id)
                            })
                    }
                }
                .accessibilityLabel("Theme picker, \(BuiltInThemes.all.count) built-in themes")
            }

            Section("Branches") {
                Toggle(
                    "Rainbow Branches",
                    isOn: Binding(
                        get: { effectiveRainbow },
                        set: { model.onRainbowToggle?($0) })
                )
                .accessibilityHint(
                    "Each first-level branch takes the next palette color; off uses one color for every branch")
                Button("Recolor Branches") {
                    model.onRecolorBranches?()
                }
                .accessibilityHint("Rotates the persistent palette colors of every root")
            }

            Section("Appearance") {
                Picker(
                    "Appearance",
                    selection: Binding(
                        get: { model.appearance },
                        set: { model.onAppearance?($0) })
                ) {
                    Text("Auto").tag(AppearanceMode.auto)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .accessibilityHint("Overrides the system look for this document")
            }

            Section("New Documents") {
                Picker(
                    "Default theme",
                    selection: Binding(
                        get: { model.defaultThemeID },
                        set: { model.onDefaultTheme?($0) })
                ) {
                    ForEach(BuiltInThemes.all, id: \.id) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .accessibilityHint("Applied when creating a new document")
            }
        }
        .formStyle(.grouped)
    }
}

/// The Canvas pane: the document's canvas-color override (stored with
/// the theme overrides — F-STY-2's theme patch seam) and the
/// user-level view toggles the menus also carry.
struct InspectorCanvasTab: View {
    @ObservedObject var model: InspectorModel

    private var palette: [String] {
        BuiltInThemes.theme(id: model.themeID).light.palette
    }

    var body: some View {
        Form {
            Section("Background") {
                ColorPickerRow(
                    title: "Canvas Color",
                    currentHex: model.canvasColorOverride,
                    overridden: model.canvasColorOverride != nil,
                    mixed: false,
                    palette: palette,
                    noneAllowed: false,
                    onPick: { hex in
                        if let hex {
                            DocumentPreferences.noteColorPick(hex)
                        }
                        model.onCanvasColor?(hex)
                    },
                    onReset: { model.onCanvasColor?(nil) })
            }

            Section("View") {
                Toggle(
                    "Show Tag Pills",
                    isOn: Binding(
                        get: { model.showsTagPills },
                        set: { model.onShowsTagPills?($0) })
                )
                Toggle(
                    "Show Minimap",
                    isOn: Binding(
                        get: { model.showsMinimap },
                        set: { model.onShowsMinimap?($0) })
                )
                Toggle(
                    "Show Contextual Bar",
                    isOn: Binding(
                        get: { model.showsContextualBar },
                        set: { model.onShowsContextualBar?($0) })
                )
                .accessibilityHint("The floating bar above a settled selection")
            }
        }
        .formStyle(.grouped)
    }
}

/// One theme tile: name over a canvas swatch and the branch palette —
/// enough to recognize the theme at a glance. Hover previews, click
/// applies.
private struct ThemeTile: View {
    let theme: Theme
    let isSelected: Bool
    let isPreviewed: Bool
    let onHover: (Bool) -> Void
    let onApply: () -> Void

    var body: some View {
        Button(action: onApply) {
            VStack(spacing: 4) {
                Text(theme.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: theme.light.canvasColor))
                    .frame(height: 26)
                    .overlay(
                        HStack(spacing: 2) {
                            ForEach(Array(theme.light.palette.prefix(6).enumerated()), id: \.offset) { _, hex in
                                Circle().fill(Color(hex: hex)).frame(width: 6, height: 6)
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                isSelected || isPreviewed ? Color.accentColor : Color.black.opacity(0.15),
                                lineWidth: isSelected ? 2 : 1))
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            onHover(inside)
        }
        .accessibilityLabel("Theme \(theme.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Hovering previews; applying is one undo step")
    }
}
