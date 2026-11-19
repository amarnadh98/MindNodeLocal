import AppKit
import CanvasKit
import MapCore
import SwiftUI

/// ⌥⌘T's tag popover (F-TAG-1): type-ahead over the document's tags
/// with create-new, assigning/unassigning on the whole selection (one
/// command per click). The same UI serves F-TAG-2's highlight picker —
/// the mode only changes what a click does.
@MainActor
final class TagPopoverHolder: NSObject, NSPopoverDelegate {
    static let shared = TagPopoverHolder()

    private var popover: NSPopover?

    func presentAssign(
        model: MapModel, anchor: NSRect, of view: NSView,
        onCommand: @escaping (MapCommand) -> Void
    ) {
        let ids = viewSelection(of: view)
        let assigned = Set(
            (model.nodes[ids.sorted().first ?? ""]?.tags ?? []).map { $0 })
        let host = NSHostingController(
            rootView: TagPickerView(
                mode: .assign,
                tags: model.tags ?? [],
                assigned: assigned,
                onPick: { name, id in
                    guard let id else {
                        onCommand(Self.createTagCommand(name: name, ids: ids, in: model))
                        return
                    }
                    let all = ids.allSatisfy { model.nodes[$0]?.tags?.contains(id) == true }
                    onCommand(.toggleTag(ids: ids.sorted(), tagID: id, assigned: !all))
                })
        )
        present(host, anchor: anchor, of: view)
    }

    func presentHighlight(
        model: MapModel, anchor: NSRect, of view: NSView,
        onHighlight: @escaping ([String]) -> Void
    ) {
        let host = NSHostingController(
            rootView: TagPickerView(
                mode: .highlight,
                tags: model.tags ?? [],
                assigned: [],
                onPick: nil,
                onHighlight: onHighlight)
        )
        present(host, anchor: anchor, of: view)
    }

    private func present(_ host: NSHostingController<TagPickerView>, anchor: NSRect, of view: NSView) {
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        self.popover = popover
    }

    func popoverWillClose(_ notification: Notification) {
        popover = nil
    }

    /// The popover's anchor view is the canvas; its selection is the
    /// command target.
    private func viewSelection(of view: NSView) -> [String] {
        (view as? CanvasSelectionProvider)?.currentSelection ?? []
    }

    /// One grouped create-and-assign (or assign-only, when the name
    /// already exists).
    static func createTagCommand(name: String, ids: [String], in model: MapModel) -> MapCommand {
        if let existing = (model.tags ?? []).first(where: { $0.name == name }) {
            return .toggleTag(ids: ids, tagID: existing.id, assigned: true)
        }
        let tag = Tag(id: UUID().uuidString, name: name, color: MapCommand.defaultTagColor(name))
        return .group(
            name: "Tag",
            commands: [
                .setTags((model.tags ?? []) + [tag]),
                .toggleTag(ids: ids, tagID: tag.id, assigned: true),
            ])
    }
}

/// The canvas's selection, for the popover's command targets (the
/// popover hosts SwiftUI, which can't see the CanvasView type).
@MainActor
protocol CanvasSelectionProvider: NSView {
    var currentSelection: [String] { get }
}

extension CanvasView: CanvasSelectionProvider {
    var currentSelection: [String] { selection.sorted() }
}

/// The tag picker UI: a type-ahead field, the matching tags (click to
/// assign/unassign, or check for highlight mode) and a create row.
private struct TagPickerView: View {
    enum Mode {
        case assign
        case highlight
    }

    let mode: Mode
    let tags: [Tag]
    let assigned: Set<String>
    var onPick: ((String, String?) -> Void)?
    var onHighlight: (([String]) -> Void)?

    @State private var query = ""
    @State private var highlighted: Set<String> = []

    private var matches: [Tag] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return tags }
        return tags.filter { $0.name.lowercased().contains(needle) }
    }

    private var canCreate: Bool {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return !tags.contains { $0.name == name }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a tag…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(matches, id: \.id) { tag in
                        row(tag)
                    }
                    if canCreate {
                        Button {
                            onPick?(query.trimmingCharacters(in: .whitespaces), nil)
                            query = ""
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle")
                                Text("Create “\(query.trimmingCharacters(in: .whitespaces))”")
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                    if matches.isEmpty && !canCreate {
                        Text(tags.isEmpty ? "No tags yet" : "No matches")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
            }
            if mode == .highlight {
                Divider()
                Button("Highlight") {
                    onHighlight?(Array(highlighted))
                }
                .keyboardShortcut(.defaultAction)
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
                .disabled(highlighted.isEmpty)
            }
        }
        .frame(width: 260, height: 280)
    }

    @ViewBuilder
    private func row(_ tag: Tag) -> some View {
        let isAssigned = assigned.contains(tag.id)
        Button {
            switch mode {
            case .assign:
                onPick?(tag.name, tag.id)
            case .highlight:
                if highlighted.contains(tag.id) {
                    highlighted.remove(tag.id)
                } else {
                    highlighted.insert(tag.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if mode == .assign {
                    Image(systemName: isAssigned ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isAssigned ? Color.accentColor : .secondary)
                } else {
                    Image(systemName: highlighted.contains(tag.id) ? "checkmark.square" : "square")
                }
                Circle()
                    .fill(Color(fromHex: tag.color))
                    .frame(width: 9, height: 9)
                Text(tag.name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }
}

extension Color {
    /// `#RRGGBB` → SwiftUI color (MapCore's ThemeHex does the parse).
    fileprivate init(fromHex hex: String) {
        if let color = MapCoreColorBridge.color(fromHex: hex) {
            self = Color(nsColor: color)
        } else {
            self = .gray
        }
    }
}

/// Tiny bridge so SwiftUI never depends on MapRender directly.
enum MapCoreColorBridge {
    static func color(fromHex hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
