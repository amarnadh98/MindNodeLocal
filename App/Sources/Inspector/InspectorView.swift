import MapCore
import MapRender
import SwiftUI

/// The inspector (SPEC §4.1, §7.1): SwiftUI `Form`, grouped sections,
/// 11–13 pt controls, secondary section headers. Tabs: Style
/// (context-aware, F-STY-2), Theme (F-STY-4/6/8) and Layout (a
/// placeholder for the later layout slice).
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
                case .theme: InspectorThemeTab(model: model)
                case .layout: InspectorLayoutTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .controlBackgroundColor))
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

/// The Layout tab placeholder: reachable, labelled, honest about its
/// state (the layout slice follows per the M2 plan).
struct InspectorLayoutTab: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        Form {
            Section("Layout") {
                Text(
                    "Layout options arrive with the layout slice: structure per branch, spacing presets, and pinned sides."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
