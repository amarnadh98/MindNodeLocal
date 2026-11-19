import AppKit
import CanvasKit
import MapCore
import MapRender
import SwiftUI

/// ⇧⌘M's Media picker (F-CNT-2/3, SPEC §6.1): one popover with the
/// tabs **Image** (choose a file), **SF Symbols** (searchable,
/// tintable), **Emoji** and **Stickers** (the ~120 original Arbor
/// vector set). Every pick is ONE grouped `MapCommand` over the whole
/// selection via the host's closure (SPEC §11.3); SwiftUI hosted per
/// §11.1.
@MainActor
final class MediaPickerController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model = MediaPickerModel()

    /// Presents the picker anchored to the selection.
    func present(
        anchor: NSRect, of view: NSView, tags: [Tag],
        onPickImage: @escaping () -> Void,
        onToggleMarker: @escaping (String) -> Void,
        onClearMarkers: @escaping () -> Void
    ) {
        model.onPickImage = onPickImage
        model.onToggleMarker = onToggleMarker
        model.onClearMarkers = onClearMarkers
        model.symbols = SFSymbolGlyphCache.catalog
        model.stickers = Stickers.all
        model.emoji = Self.emojiCatalog
        popover.contentViewController = NSHostingController(
            rootView: MediaPickerView(model: model))
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    /// The emoji tab: the everyday set, ordered for scanning.
    static let emojiCatalog: [String] = [
        "💡", "❓", "⚠️", "📌", "🔁", "🔥", "⭐️", "✅", "❌", "❗️",
        "🎯", "🏆", "🚀", "🌟", "💎", "🔒", "🔑", "🔖", "📈", "📉",
        "⏰", "📅", "🔔", "📎", "✂️", "📝", "📚", "🎓", "🧠", "🧩",
        "💬", "❤️", "👍", "👎", "😄", "🙁", "😮", "😢", "😡", "🤔",
        "👀", "🙌", "🤝", "💪", "☕️", "🍕", "🍰", "🍎", "🌱", "🌸",
        "🌈", "☀️", "🌙", "⛅️", "🌧", "❄️", "🌍", "🎒", "✈️", "🏠",
        "💻", "📱", "🎧", "🎵", "🎬", "📷", "🔍", "⚙️", "🛠", "🧪",
    ]

    /// The emoji token form stored in the model (`emoji:💡`).
    static func token(forEmoji emoji: String) -> String {
        let trimmed = emoji.trimmingCharacters(in: CharacterSet(charactersIn: "\u{fe0f}"))
        return "emoji:" + trimmed
    }

    /// The emoji a stored token carries, for the toggle state.
    static func emoji(ofToken token: String) -> String? {
        guard token.hasPrefix("emoji:") else { return nil }
        return String(token.dropFirst(6))
    }
}

@MainActor
private final class MediaPickerModel: ObservableObject {
    @Published var selectedTab = 0
    @Published var symbolQuery = ""
    var symbols: [String] = []
    var stickers: [Sticker] = []
    var emoji: [String] = []
    var onPickImage: (() -> Void)?
    var onToggleMarker: ((String) -> Void)?
    var onClearMarkers: (() -> Void)?
}

private struct MediaPickerView: View {
    @ObservedObject var model: MediaPickerModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.selectedTab) {
                Text("Image").tag(0)
                Text("SF Symbols").tag(1)
                Text("Emoji").tag(2)
                Text("Stickers").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
            Divider()
            Group {
                switch model.selectedTab {
                case 0: imageTab
                case 1: symbolsTab
                case 2: emojiTab
                default: stickersTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Remove Markers") { model.onClearMarkers?() }
                    .accessibilityLabel(Text("Remove all markers from the selection"))
                    .padding(EdgeInsets(top: 8, leading: 0, bottom: 10, trailing: 12))
            }
        }
        .frame(width: 420, height: 320)
    }

    private var imageTab: some View {
        VStack(spacing: 14) {
            Spacer()
            Button("Choose Image…") { model.onPickImage?() }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(Text("Choose an image file for the selected nodes"))
            Text("Or drag & drop / paste an image onto a node.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }

    private var symbolsTab: some View {
        VStack(spacing: 6) {
            TextField("Search symbols", text: $model.symbolQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .accessibilityLabel(Text("Search SF Symbols"))
            ScrollView {
                let filtered = model.symbols.filter {
                    model.symbolQuery.isEmpty || $0.localizedCaseInsensitiveContains(model.symbolQuery)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(filtered, id: \.self) { name in
                        SFSymbolCell(name: name) {
                            model.onToggleMarker?("sf:" + name)
                        }
                    }
                }
                .padding(12)
            }
        }
        .padding(.vertical, 8)
    }

    private var emojiTab: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.emoji, id: \.self) { emoji in
                    Text(emoji)
                        .font(.system(size: 22))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .onTapGesture { model.onToggleMarker?(MediaPickerController.token(forEmoji: emoji)) }
                        .accessibilityLabel(Text("Emoji \(emoji)"))
                }
            }
            .padding(12)
        }
    }

    private var stickersTab: some View {
        ScrollView {
            let grouped = Dictionary(grouping: model.stickers, by: \.category)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Stickers.categoryOrder, id: \.self) { category in
                    if let items = grouped[category] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(items, id: \.id) { sticker in
                                    StickerCell(sticker: sticker) {
                                        model.onToggleMarker?("sticker:" + sticker.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)
    }
}

private struct SFSymbolCell: View {
    let name: String
    let onTap: () -> Void
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityLabel(Text("Marker \(name)"))
    }
}

private struct StickerCell: View {
    let sticker: Sticker
    let onTap: () -> Void
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(nsImage: stickerImage)
            .interpolation(.high)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityLabel(Text("Sticker \(sticker.id.replacingOccurrences(of: "-", with: " "))"))
    }

    /// The preview draws through the SAME `NodeRenderer.drawSticker`
    /// the canvas uses — the grid shows exactly what lands on the node.
    private var stickerImage: NSImage {
        let edge: CGFloat = 72
        let size = CGSize(width: edge, height: edge)
        let image = NSImage(size: size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            let tint = NSColor.labelColor.cgColor
            NodeRenderer.drawSticker(
                sticker, in: CGRect(origin: .zero, size: size), color: tint, in: context)
        }
        image.unlockFocus()
        return image
    }
}
