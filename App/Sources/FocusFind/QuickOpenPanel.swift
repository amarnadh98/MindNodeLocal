import AppKit
import CanvasKit
import MapCore
import SwiftUI

/// One row of the palette: what it shows and what committing it does.
struct QuickOpenItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Jump to a node of the current document (⇧⌘O).
        case node(id: String)
        /// Run a menu command (⇧⌘P).
        case command(MenuCommandListing.Entry)
    }

    let id: String
    /// The primary text (node title / command path tail).
    let title: String
    /// Secondary text (breadcrumb / full menu path).
    let subtitle: String
    /// The shortcut the command already has, for a ⌘-hint on the row.
    let shortcut: String
    let kind: Kind

    var isNode: Bool {
        if case .node = kind { return true }
        return false
    }
}

/// The palette's state: the query, the ranked results, and the
/// selected row. Pure list manipulation; the fuzzy ranking is
/// CanvasKit's `FuzzyMatcher`. An empty query lists every candidate in
/// its natural order (document order for nodes, menu order for
/// commands).
@MainActor
final class QuickOpenModel: ObservableObject {
    @Published private(set) var results: [QuickOpenItem] = []
    @Published private(set) var selectedIndex = 0
    @Published var query = "" {
        didSet { recompute() }
    }

    private let allItems: [QuickOpenItem]
    var onCommit: ((QuickOpenItem) -> Void)?
    var onCancel: (() -> Void)?

    init(items: [QuickOpenItem]) {
        allItems = items
        recompute()
    }

    /// Fuzzy-filtered candidates for `query`, ranked by score; an
    /// empty query keeps the natural order.
    private func recompute() {
        if query.isEmpty {
            results = allItems
        } else {
            results = FuzzyMatcher.ranked(query: query, candidates: allItems) { item in
                item.isNode ? "\(item.title) \(item.subtitle)" : item.subtitle
            }.map(\.candidate)
        }
        selectedIndex = 0
    }

    /// The row the selection is on, if any.
    var selected: QuickOpenItem? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Moves the selection to `index` (clamped) — the tap and arrow
    /// paths share this.
    func select(_ index: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(index, 0), results.count - 1)
    }

    func moveSelection(delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    func commitSelected() {
        guard let selected else { return }
        onCommit?(selected)
    }

    func cancel() {
        onCancel?()
    }
}

/// The floating palette window (F-FOC-4): a borderless, key-accepting
/// `NSPanel` hosting the SwiftUI list. Plain ⏎/↑/↓/⎋ are claimed at
/// the panel level — before the menu's bare-⏎ "Add Sibling Below"
/// equivalent can fire — and routed to the model.
@MainActor
final class QuickOpenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var keyRouter: ((_ key: String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers, key.count == 1,
            !event.modifierFlags.contains(.command),
            let keyRouter
        else { return super.performKeyEquivalent(with: event) }
        return keyRouter(key) || super.performKeyEquivalent(with: event)
    }
}

/// Owns the panel and its model; the coordinator builds one per open.
@MainActor
final class QuickOpenPanelController {
    let panel: QuickOpenPanel
    let model: QuickOpenModel

    init(mode: QuickOpenMode, items: [QuickOpenItem]) {
        model = QuickOpenModel(items: items)
        panel = QuickOpenPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.isOpaque = false
        panel.title = mode == .nodes ? "Quick Open" : "Command Palette"

        let content = QuickOpenContentView(model: model, mode: mode)
            .frame(width: 560, height: 420)
        panel.contentView = NSHostingView(rootView: content)

        // Plain key routing: ⏎ commits, ↑/↓ move, ⎋ cancels; ⌘ keys
        // stay with the menu.
        panel.keyRouter = { [weak model] key in
            guard let model else { return false }
            switch key {
            case "\r":
                model.commitSelected()
                return true
            case "\u{f700}":
                model.moveSelection(delta: -1)
                return true
            case "\u{f701}":
                model.moveSelection(delta: 1)
                return true
            case "\u{1b}":
                model.cancel()
                return true
            default:
                return false
            }
        }
    }

    /// Shows the panel near the top of `window` (or centered on the
    /// main screen without one) and focuses the query field.
    func show(relativeTo window: NSWindow?) {
        if let window {
            let windowFrame = window.frame
            let width = panel.frame.width
            let x = windowFrame.midX - width / 2
            let y = windowFrame.maxY - 120 - panel.frame.height
            panel.setFrameOrigin(NSPoint(x: x, y: max(y, windowFrame.minY + 20)))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }
}

/// Which flavor of the palette opened (⇧⌘O nodes / ⇧⌘P commands).
enum QuickOpenMode {
    case nodes
    case commands
}

/// The hosted SwiftUI content (SPEC §11.1: hosted SwiftUI is allowed
/// for panels). A query field on top, the ranked list below.
private struct QuickOpenContentView: View {
    @ObservedObject var model: QuickOpenModel
    let mode: QuickOpenMode

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                mode == .nodes ? "Jump to node…" : "Run a command…", text: $model.query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .regular))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityLabel("Quick Open query")
            .defaultFocus()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.select(index)
                                model.commitSelected()
                            }
                            .id(index)
                    }
                }
            }
            if model.results.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .nodes ? "Quick Open nodes" : "Command Palette")
    }

    private func row(_ item: QuickOpenItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if !item.shortcut.isEmpty {
                Text(item.shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            item.id == model.selected?.id
                ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                : AnyShapeStyle(.clear))
    }
}

/// Auto-focuses the field when the panel appears (the panel is
/// rebuilt on every open, so `onAppear` fires each time).
struct DefaultFocusModifier: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onAppear { focused = true }
    }
}

extension View {
    func defaultFocus() -> some View {
        modifier(DefaultFocusModifier())
    }
}
