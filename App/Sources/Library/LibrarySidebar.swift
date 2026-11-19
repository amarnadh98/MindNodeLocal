import AppKit
import MapLibrary
import SwiftUI

/// The hosted Library window's full layout: sidebar (Recents ·
/// Favorites · Folders · Tags · Study Due · Templates · Concept Index,
/// SPEC §4) + the detail view, with the F-LIB-2 toolbar (search, grid
/// or list, New Map, Rebuild Index).
struct LibrarySplitView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Section {
                    label("Recents", "clock", .recents)
                    label("Favorites", "star", .favorites)
                }
                Section("Folders") {
                    ForEach(model.folderPaths, id: \.self) { path in
                        label(
                            URL(fileURLWithPath: path).lastPathComponent, "folder",
                            .folder(path: path))
                    }
                    if let suggestion = model.suggestedFolder, model.folderPaths.isEmpty {
                        Button {
                            Task { await model.addWatchedFolder(at: suggestion) }
                        } label: {
                            Label("Watch suggested folder", systemImage: "plus")
                        }
                        .help("Suggested: \(suggestion.path) — never created without you")
                    }
                    Button {
                        addFolderPanel()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                }
                Section("Tags") {
                    ForEach(model.finderTags, id: \.self) { tag in
                        label(tag, "tag", .finderTag(tag))
                    }
                }
                Section {
                    label("Study Due", "book", .studyDue)
                    label("Concept Index", "link", .conceptIndex)
                    label("Templates", "square.stack.3d.up", .templates)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            LibraryView()
                .toolbar { libraryToolbar }
        }
        .navigationTitle("Library")
    }

    private func label(_ title: String, _ icon: String, _ section: LibraryModel.SidebarSection) -> some View {
        Label(title, systemImage: icon)
            .tag(section)
            .accessibilityLabel(title)
    }

    /// F-LIB-2 toolbar: search (filename + full text), view switcher,
    /// New Map, New from Template (jumps to Templates), Advanced ▸
    /// Rebuild Index (F-LIB-3).
    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem {
            TextField("Search", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityLabel("Search maps and their contents")
        }
        ToolbarItem {
            Toggle(isOn: $model.showsGrid) {
                Label(model.showsGrid ? "List View" : "Grid View", systemImage: "list.bullet")
            }
            .help("Switch between grid and list")
        }
        ToolbarItemGroup {
            Button {
                model.newMap()
            } label: {
                Label("New Map", systemImage: "plus")
            }
            .help("Create an empty map")
            Menu("New from Template", systemImage: "square.stack.3d.up") {
                ForEach(model.templates) { template in
                    Button(template.name) {
                        model.newFromTemplate(template)
                    }
                }
            }
            .accessibilityLabel("New from Template")
        }
        ToolbarItem {
            Menu("Advanced", systemImage: "gearshape") {
                Button("Rebuild Index") {
                    Task { await model.rebuildIndex() }
                }
                .help("Discard and rebuild the library index from all watched folders")
            }
            .accessibilityLabel("Advanced")
        }
    }

    /// F-LIB-1: the user picks an existing folder; nothing is created
    /// silently.
    private func addFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "Choose a folder of Arbor maps to watch"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.addWatchedFolder(at: url) }
        }
    }
}

/// The Templates section (F-LIB-5): the twelve built-ins plus the
/// user's saved ones; double-click creates an untitled copy.
struct TemplateListView: View {
    @EnvironmentObject private var model: LibraryModel

    var body: some View {
        List(model.templates) { template in
            HStack {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                Text(template.name)
                Spacer()
                Button("New Map") {
                    model.newFromTemplate(template)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("New map from \(template.name)")
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .accessibilityLabel("Templates")
    }
}
