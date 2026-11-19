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
/// bullets, quotes, **code blocks** (F-CNT-6: monospaced,
/// theme-aware, fenced blocks render as one shaded block),
/// **LaTeX** (`$$…$$` blocks render through SwiftMath, F-CNT-5), and
/// inline styles via `AttributedString(markdown:)` (inline-only, per
/// §8.3's allow-list).
private struct NotePreview: View {
    let markdown: String

    var body: some View {
        // Fenced code blocks and $$ math blocks swallow their span;
        // everything else renders line by line.
        let blocks = NoteBlocks.parse(markdown)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .line(let raw):
                    noteLine(raw)
                case .code(let body):
                    codeBlock(body)
                case .math(let latex):
                    mathBlock(latex)
                }
            }
        }
    }

    /// F-CNT-6: a fenced block renders as one monospaced, shaded,
    /// theme-aware block (syntax-agnostic styling — SPEC allows a
    /// tokenizer later).
    private func codeBlock(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(body.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                Text(String(raw.isEmpty ? " " : raw))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.6), lineWidth: 0.5))
        .accessibilityLabel(Text("Code block"))
    }

    /// F-CNT-5: `$$…$$` renders through SwiftMath (ADR-0027); a parse
    /// error falls back to the source text.
    private func mathBlock(_ latex: String) -> some View {
        Group {
            if let image = MathImageCache.image(
                latex: latex, fontSize: 14, color: .labelColor)
            {
                Image(nsImage: image)
                    .interpolation(.high)
            } else {
                Text("$$\(latex)$$")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text("Math block \(latex)"))
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

/// The note's block structure (F-CNT-5/6): fenced code and `$$` math
/// spans lift out of the line flow; pure — the preview's parse.
private enum NoteBlocks {
    enum Block {
        case line(String)
        case code(String)
        case math(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var lines = Array(markdown.split(separator: "\n", omittingEmptySubsequences: false)[...])
        while let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            if index > 0 {
                blocks.append(contentsOf: lines[..<index].map { .line(String($0)) })
            }
            let afterFence = lines[(index + 1)...]
            if let end = afterFence.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
                blocks.append(.code(afterFence[..<end].joined(separator: "\n")))
                lines = Array(afterFence[(end + 1)...])
            } else {
                blocks.append(.code(afterFence.joined(separator: "\n")))
                lines = []
            }
        }
        var rest = Array(lines)
        while let index = rest.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "$$" }) {
            let after = rest[(index + 1)...]
            if let end = after.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "$$" }) {
                if index > 0 {
                    blocks.append(contentsOf: rest[..<index].map { .line(String($0)) })
                }
                blocks.append(.math(after[..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                rest = Array(after[(end + 1)...])
            } else {
                break
            }
        }
        blocks.append(contentsOf: rest.map { .line(String($0)) })
        return blocks
    }
}
