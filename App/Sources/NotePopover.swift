import AppKit
import SwiftUI

/// The note editor model (F-CNT-1): the live text plus the
/// preview-toggle state. Observable so the hosted SwiftUI view follows.
@MainActor
final class NoteEditorModel: ObservableObject {
    @Published var text: String
    @Published var showsPreview = false
    let initialText: String

    init(text: String) {
        self.text = text
        self.initialText = text
    }

    var changed: Bool { text != initialText }
}

/// ⇧⌘K's note popover (F-CNT-1): a SwiftUI-hosted Markdown editor with
/// a live-rendered preview toggle (SwiftUI hosted per SPEC §11.1).
/// One editing session commits ONE `setNote` on close — never per
/// keystroke (F-DOC-2).
@MainActor
final class NotePopoverHolder: NSObject, NSPopoverDelegate {
    private let model: NoteEditorModel
    private let nodeID: String
    private let onCommit: (String, String) -> Void
    private let popover = NSPopover()

    init(nodeID: String, note: String?, onCommit: @escaping (String, String) -> Void) {
        self.nodeID = nodeID
        self.model = NoteEditorModel(text: note ?? "")
        self.onCommit = onCommit
        super.init()
        popover.contentViewController = NSHostingController(
            rootView: NoteEditorView(model: model))
        popover.behavior = .transient
        popover.delegate = self
    }

    func present(anchor: NSRect, of view: NSView) {
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }

    /// The session's live text (test seam; the popover commits it once
    /// on close).
    var text: String {
        get { model.text }
        set { model.text = newValue }
    }

    var showsPreview: Bool {
        get { model.showsPreview }
        set { model.showsPreview = newValue }
    }

    /// Ends the session — the popover's own close runs the delegate
    /// path, committing the single `setNote`.
    func close() {
        popover.close()
    }

    /// The popover closes (click-away, Esc, button): the whole session
    /// is one `setNote`.
    func popoverWillClose(_ notification: Notification) {
        if model.changed {
            onCommit(nodeID, model.text)
        }
    }
}

/// The note editor UI: an editing `TextEditor` or the live-rendered
/// Markdown preview, switched by the toolbar toggle (F-CNT-1).
private struct NoteEditorView: View {
    @ObservedObject var model: NoteEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Note")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Preview", isOn: $model.showsPreview)
                    .toggleStyle(.button)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            Divider()
            if model.showsPreview {
                ScrollView {
                    NotePreview(markdown: model.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                TextEditor(text: $model.text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        }
        .frame(width: 340, height: 300)
    }
}

/// A small live Markdown renderer for the preview toggle: headings,
/// bullets, quotes, code lines, and inline styles via
/// `AttributedString(markdown:)` (inline-only, per §8.3's allow-list).
private struct NotePreview: View {
    let markdown: String

    var body: some View {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                noteLine(String(raw))
            }
        }
    }

    @ViewBuilder
    private func noteLine(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            EmptyView()
        } else if line.hasPrefix("## ") {
            Text(inline(line.dropFirst(3))).font(.headline)
        } else if line.hasPrefix("# ") {
            Text(inline(line.dropFirst(2))).font(.title3).bold()
        } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
            HStack(spacing: 4) {
                Image(systemName: line.hasPrefix("- [x] ") ? "checkmark.square" : "square")
                    .font(.footnote)
                Text(inline(line.dropFirst(6)))
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(line.dropFirst(2)))
            }
        } else if line.hasPrefix("> ") {
            Text(inline(line.dropFirst(2))).italic().padding(.leading, 8)
        } else if line.hasPrefix("```") {
            Text(line.hasPrefix("```") && line.count == 3 ? "" : String(line.dropFirst(3)))
                .font(.system(size: 12, design: .monospaced))
        } else {
            Text(inline(Substring(line)))
        }
    }

    /// Inline Markdown (bold/italic/code/links) through the system
    /// parser; unparseable text falls back to plain.
    private func inline(_ text: Substring) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: String(text),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            return parsed
        }
        return AttributedString(String(text))
    }
}
