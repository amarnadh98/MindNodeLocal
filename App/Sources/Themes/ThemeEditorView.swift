import AppKit
import MapCore
import MapRender
import SwiftUI

/// The theme editor sheet (F-STY-5): live preview map on the left, all
/// theme properties on the right, grouped Canvas / Palette / Levels /
/// Branch / Connections / Boundaries. The form edits the preview's
/// shown variant (Light or Dark — every theme is dynamic, F-STY-4);
/// flipping the toggle edits the other scheme. All state lives in
/// `ThemeEditorModel`; actions route through `ThemeEditorActions` to
/// the controller.
struct ThemeEditorView: View {
    @ObservedObject var model: ThemeEditorModel
    let actions: ThemeEditorActions

    var body: some View {
        HStack(spacing: 0) {
            previewColumn
                .frame(width: 540)
                .padding(16)
            Divider()
            ScrollView {
                propertiesForm
                    .padding(16)
            }
            .frame(minWidth: 360, maxWidth: 420)
        }
        .frame(width: 940, height: 580)
    }

    // MARK: preview column

    private var previewColumn: some View {
        VStack(spacing: 12) {
            Picker(
                "Variant",
                selection: Binding(
                    get: { model.previewVariant },
                    set: { model.setVariant($0) }
                )
            ) {
                Text("Light").tag(ThemeVariant.light)
                Text("Dark").tag(ThemeVariant.dark)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Preview appearance")

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.04))
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text("Preview unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Live theme preview")

            TextField(
                "Theme name",
                text: Binding(
                    get: { model.draft.name },
                    set: { model.setName($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Theme name")

            if model.isBuiltInDraft {
                Text(
                    "Saving or applying edits to “\(model.draft.name)” creates a new theme — "
                        + "built-in themes never change."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }

            HStack {
                Button("Apply to Document", action: actions.applyToDocument)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Save", action: actions.save)
            }
            HStack {
                Button("Export…", action: actions.export)
                Button("Duplicate as New Theme", action: actions.duplicate)
                Spacer()
                Button("Done", action: actions.done)
                    .keyboardShortcut(.defaultAction)
            }
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: property form

    private var propertiesForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            canvasGroup
            paletteGroup
            levelsGroup
            branchGroup
            connectionGroup
            boundaryGroup
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
