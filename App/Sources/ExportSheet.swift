import AppKit
import CanvasKit
import Foundation
import MapCore
import MapIO
import SceneExport
import SwiftUI

/// The File ▸ Export… sheet (⌥⌘E, SPEC §5.17): format picker for every
/// exportable `DocumentFormats` entry, per-format options, and a live
/// thumbnail/text preview. SwiftUI-hosted per AGENTS (sheets are an
/// allowed hosting surface); all rendering happens through the shared
/// `SceneExport` path.
struct ExportSheetView: View {
    @State private var choice: ExportChoice
    @State private var preview: ExportPreview = .failed("")

    let formats: [DocumentFormat]
    private let hasSelection: Bool
    private let renderPreview: (ExportChoice) -> ExportPreview
    private let onExport: (ExportChoice) -> Void
    private let onCancel: () -> Void

    init(
        initialChoice: ExportChoice,
        hasSelection: Bool,
        formats: [DocumentFormat],
        renderPreview: @escaping (ExportChoice) -> ExportPreview,
        onExport: @escaping (ExportChoice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        choice = initialChoice
        self.hasSelection = hasSelection
        self.formats = formats
        self.renderPreview = renderPreview
        self.onExport = onExport
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.headline)
            HStack(alignment: .top, spacing: 16) {
                optionsPane
                previewPane
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    onExport(choice)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ExportCoordinator.format(for: choice) == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 320)
        .onAppear {
            preview = renderPreview(choice)
        }
        // Any option flip refreshes the preview: every control above
        // binds into `choice`.
        .onChange(of: choice) { _, newChoice in
            preview = renderPreview(newChoice)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export document")
    }

    private var optionsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: $choice.formatID) {
                ForEach(formats, id: \.id) { format in
                    Text(format.displayName).tag(format.id)
                }
            }
            .accessibilityLabel("Export format")
            Divider()
            formatOptions
            Spacer()
        }
        .frame(width: 240, alignment: .leading)
    }

    @ViewBuilder private var formatOptions: some View {
        switch choice.formatID {
        case DocumentFormats.pdf.id:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Content", selection: $choice.pdfContent) {
                    Text("Whole Map").tag("wholeMap")
                    Text(selectionTagTitle).tag("selection")
                    Text("Outline").tag("outline")
                }
                Toggle("Draw background", isOn: $choice.pdfBackground)
                Toggle("Include bookmarks", isOn: $choice.pdfBookmarks)
            }
        case DocumentFormats.png.id, DocumentFormats.jpeg.id, DocumentFormats.heic.id:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Scale", selection: $choice.imageScale) {
                    Text("1×").tag(1)
                    Text("2×").tag(2)
                    Text("3×").tag(3)
                }
                if choice.formatID != DocumentFormats.jpeg.id {
                    Toggle("Transparent background", isOn: $choice.imageTransparent)
                }
            }
        case DocumentFormats.svg.id:
            Toggle("Text as outlines", isOn: $choice.svgTextAsOutlines)
        case DocumentFormats.markdown.id:
            Stepper(
                "Heading depth: \(choice.markdownHeadingDepth == 0 ? "none" : String(choice.markdownHeadingDepth))",
                value: $choice.markdownHeadingDepth, in: 0...6
            )
            .accessibilityLabel("Markdown heading depth")
        case DocumentFormats.plainText.id:
            Picker("Indent", selection: $choice.textIndent) {
                Text("Tabs").tag("tab")
                Text("2 spaces").tag("two")
                Text("4 spaces").tag("four")
            }
        default:
            Text("\(selectedFormat?.displayName ?? "") export has no options.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var previewPane: some View {
        Group {
            switch preview {
            case .image(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .accessibilityLabel("Export preview")
                } else {
                    failedPreview()
                }
            case .text(let text):
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
                        .textSelection(.enabled)
                }
                .accessibilityLabel("Exported text preview")
            case .failed(let message):
                failedPreview(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func failedPreview(_ message: String = "Nothing to preview.") -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionTagTitle: String {
        hasSelection ? "Selection Subtree" : "Selection (nothing selected)"
    }

    private var selectedFormat: DocumentFormat? {
        formats.first { $0.id == choice.formatID }
    }
}
