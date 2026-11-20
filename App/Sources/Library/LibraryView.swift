import AppKit
import MapLibrary
import SwiftUI

/// The Library window (F-LIB-1/2): sidebar sections, map grid/list with
/// live thumbnails, search, and the Concept Index (F-LIB-4). Hosted
/// SwiftUI per SPEC §4 — a thin window hosts this view.
struct LibraryView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        Group {
            if case .conceptIndex = model.section {
                ConceptIndexView()
            } else if case .templates = model.section {
                TemplateListView()
            } else {
                mapList
            }
        }
        .safeAreaInset(edge: .bottom) { statusFooter }
        .frame(minWidth: 720, minHeight: 420)
        .task { await model.reload() }
        .onChange(of: model.section) { _, _ in
            Task { await model.reload() }
        }
        .onChange(of: model.searchQuery) { _, _ in
            Task { await model.reload() }
        }
    }

    /// The Library's map browser: a search-driven list or the current
    /// section's grid.
    private var mapList: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                emptyState
            } else if model.showsGrid {
                LibraryGridView(model: model)
            } else {
                LibraryTableView(model: model)
            }
        }
    }

    /// F-ONB-3's Library empty state: designed, not defaulted — the
    /// two doors out of an empty library (new map / template) plus the
    /// watch-folder suggestion.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "map")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            if model.section == .recents && model.folderPaths.isEmpty {
                Text("No recent maps yet.")
                    .font(.title3)
                Text("Start a new map, or add a folder to watch the maps you already keep there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("New Map") { model.newMap() }
                        .buttonStyle(.borderedProminent)
                    Button("New from Template…") { model.section = .templates }
                    if let suggestion = model.suggestedFolder {
                        Button("Watch \(suggestion.lastPathComponent)") {
                            Task { await model.addWatchedFolder(at: suggestion) }
                        }
                    }
                }
            } else {
                Text("Nothing here")
                    .font(.title3)
                Text("Maps in this section will appear as you create and save them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("New Map") { model.newMap() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("No maps")
    }

    private var statusFooter: some View {
        HStack {
            if model.statusMessage.isEmpty {
                Text("\(model.entries.count) maps")
            } else {
                Text(model.statusMessage)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityLabel("Library status")
    }
}

/// One map cell: live thumbnail (the package's QuickLook/Thumbnail.png,
/// written on save; a placeholder when absent), title, modified date,
/// favorite star (F-LIB-2).
struct LibraryMapCell: View {
    let entry: LibraryMapEntry
    let isFavorite: Bool
    let model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ThumbnailView(path: entry.path)
                    .frame(width: 150, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button {
                    model.toggleFavorite(entry)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            Text(entry.displayTitle)
                .lineLimit(1)
                .font(.headline)
            HStack(spacing: 4) {
                if entry.dueToday > 0 || entry.newCards > 0 {
                    Label("\(entry.dueToday + entry.newCards)", systemImage: "book")
                        .font(.caption)
                        .help("Cards to review")
                }
                Text(entry.modified, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .contentShape(.rect)
        .onTapGesture(count: 2) { model.open(entry) }
        .contextMenu { LibraryContextMenu.menu(for: entry, in: model) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.displayTitle), modified \(entry.modified.formatted(date: .abbreviated, time: .omitted))")
    }
}

/// Reads the package's `QuickLook/Thumbnail.png` off the main actor;
/// falls back to a document placeholder (the save path writes the real
/// one — another agent's slice — so the Library must tolerate its
/// absence, F-LIB-2). Only `Data` crosses the detached task; the image
/// is constructed on the main actor.
struct ThumbnailView: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 32))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .task(id: path) {
            let url = URL(fileURLWithPath: path)
                .appendingPathComponent("QuickLook/Thumbnail.png")
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url)
            }.value
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}

/// The grid of maps (F-LIB-2's default view).
struct LibraryGridView: View {
    let model: LibraryModel

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 170), spacing: 8)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.sortedEntries) { entry in
                    LibraryMapCell(entry: entry, isFavorite: model.isFavorite(entry), model: model)
                }
            }
            .padding(12)
        }
    }
}

/// The list view with sortable columns (F-LIB-2).
struct LibraryTableView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        Table(model.sortedEntries, sortOrder: $model.sortOrder) {
            TableColumn("Title", value: \.title) { entry in
                HStack {
                    Button {
                        model.open(entry)
                    } label: {
                        Text(entry.displayTitle).lineLimit(1)
                    }
                    .buttonStyle(.link)
                    if model.isFavorite(entry) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
                .contextMenu { LibraryContextMenu.menu(for: entry, in: model) }
            }
            TableColumn("Modified", value: \.modified) { entry in
                Text(entry.modified, style: .date)
            }
            TableColumn("Where", value: \.path) { entry in
                Text(entry.url.deletingLastPathComponent().lastPathComponent)
                    .lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .tableStyle(.bordered)
    }
}

/// The F-LIB-2 context menu, shared by grid and list.
enum LibraryContextMenu {
    @MainActor
    static func menu(for entry: LibraryMapEntry, in model: LibraryModel) -> some View {
        Group {
            Button("Open") { model.open(entry) }
            Divider()
            Button("Reveal in Finder") { model.revealInFinder(entry) }
            Button("Duplicate") { Task { await model.duplicate(entry) } }
            Button("Move to Trash") { Task { await model.moveToTrash(entry) } }
                .foregroundStyle(Color(nsColor: .systemRed))
        }
    }
}
