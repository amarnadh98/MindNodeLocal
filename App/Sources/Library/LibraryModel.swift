import AppKit
import MapCore
import MapLibrary

/// One map shown in the Library's grid/list (F-LIB-2).
struct LibraryMapEntry: Identifiable {
    let id: String
    let docID: String?
    let path: String
    let title: String
    let modified: Date
    var finderTags: [String] = []
    var dueToday: Int = 0
    var newCards: Int = 0

    var url: URL { URL(fileURLWithPath: path) }
    var displayTitle: String {
        title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
    }
}

/// The Library window's UI-observable state (F-LIB-1/2/4). All index
/// queries hop to the `LibraryService` actor; results land back here as
/// `Sendable` records and never block the main actor.
@MainActor
final class LibraryModel: ObservableObject {
    enum SidebarSection: Hashable {
        case recents
        case favorites
        case conceptIndex
        case studyDue
        case templates
        case folder(path: String)
        case finderTag(String)
    }

    @Published var section: SidebarSection = .recents
    @Published var entries: [LibraryMapEntry] = []
    @Published var folderPaths: [String] = []
    @Published var finderTags: [String] = []
    @Published var conceptGroups: [ConceptGroup] = []
    @Published var conceptSearch = ""
    @Published var dueSummaries: [DueSummary] = []
    @Published var templates: [TemplateCatalog.Template] = []
    @Published var searchQuery = ""
    @Published var showsGrid = true
    @Published var statusMessage = ""
    @Published var suggestedFolder: URL?

    /// Sort state for the list view's columns.
    @Published var sortOrder = [KeyPathComparator(\LibraryMapEntry.modified, order: .reverse)]

    private let service: LibraryService
    private let templateStore: TemplateStore
    private var favorites: Set<String>
    /// path → docID for entries the index knows (favorites for files
    /// that are only listed as Recents resolve through this).
    private var docIDsByPath: [String: String] = [:]

    init(service: LibraryService, templateStore: TemplateStore) {
        self.service = service
        self.templateStore = templateStore
        favorites = Set(UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [])
        suggestedFolder = LibraryService.suggestedDefault()
    }

    // MARK: loading

    /// Reloads the state for the current section (and the sidebar's
    /// shared lists). Runs whole after every mutation — the queries are
    /// cheap index reads.
    func reload() async {
        folderPaths = await service.watchedFolderPaths()
        templates = templateStore.allTemplates()
        dueSummaries = (try? await service.database.dueCounts()) ?? []

        let indexed = (try? await service.database.allEntries()) ?? []
        docIDsByPath = Dictionary(uniqueKeysWithValues: indexed.map { ($0.path, $0.docID) })
        finderTags = collectFinderTags(from: indexed.map(Self.entry(from:)))

        let searchText = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchText.isEmpty {
            var seen = Set<String>()
            let records = (try? await service.database.search(searchText)) ?? []
            let recents = recentEntries().filter { record in records.contains(where: { $0.path == record.path }) }
            entries = (records.map(Self.entry(from:)) + recents).filter { seen.insert($0.id).inserted }
            return
        }

        switch section {
        case .recents:
            entries = recentEntries()
        case .favorites:
            var seen = Set<String>()
            let indexedFavorites = indexed.map(Self.entry(from:)).filter { isFavorite($0) }
            let recentFavorites = recentEntries().filter { isFavorite($0) }
            entries = (recentFavorites + indexedFavorites).filter { seen.insert($0.id).inserted }
        case .folder(let path):
            entries =
                (try? await service.database.entries(inFolder: URL(fileURLWithPath: path)))?
                .map(Self.entry(from:)) ?? []
        case .finderTag(let tag):
            entries = indexed.map(Self.entry(from:)).filter { $0.finderTags.contains(tag) }
        case .studyDue:
            entries = indexed.compactMap { record in
                guard let summary = dueSummaries.first(where: { $0.docID == record.docID }),
                    summary.dueToday > 0 || summary.newCards > 0
                else { return nil }
                var entry = Self.entry(from: record)
                entry.dueToday = summary.dueToday
                entry.newCards = summary.newCards
                return entry
            }
        case .templates, .conceptIndex:
            entries = []
        }

        if case .conceptIndex = section {
            conceptGroups = (try? await service.database.conceptGroups(matching: conceptSearch)) ?? []
        }
    }

    /// Recents straight from NSDocumentController (F-LIB-1).
    private func recentEntries() -> [LibraryMapEntry] {
        NSDocumentController.shared.recentDocumentURLs.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return LibraryMapEntry(
                id: "recent:\(url.path)", docID: docIDsByPath[url.path], path: url.path,
                title: url.deletingPathExtension().lastPathComponent,
                modified: values?.contentModificationDate ?? .distantPast,
                finderTags: Self.finderTags(at: url))
        }
    }

    /// Maps an index record, decorated with Finder tags.
    static func entry(from record: LibraryEntry) -> LibraryMapEntry {
        let url = URL(fileURLWithPath: record.path)
        return LibraryMapEntry(
            id: record.docID, docID: record.docID, path: record.path, title: record.title,
            modified: record.modified, finderTags: finderTags(at: url))
    }

    static func finderTags(at url: URL) -> [String] {
        let values = try? url.resourceValues(forKeys: [.tagNamesKey])
        return (values?.tagNames ?? []).map { $0.lowercased() }.sorted()
    }

    /// The Finder tags present across everything listed — the sidebar's
    /// Tags section (F-LIB-2 "Finder tags shown").
    private func collectFinderTags(from entries: [LibraryMapEntry]) -> [String] {
        var seen = Set<String>()
        for entry in entries {
            seen.formUnion(entry.finderTags)
        }
        for url in NSDocumentController.shared.recentDocumentURLs {
            seen.formUnion(Self.finderTags(at: url))
        }
        return seen.sorted()
    }

    var sortedEntries: [LibraryMapEntry] {
        entries.sorted(using: sortOrder)
    }

    var favoritesCount: Int { favorites.count }

    // MARK: actions (F-LIB-2)

    func toggleFavorite(_ entry: LibraryMapEntry) {
        guard let docID = entry.docID ?? docIDsByPath[entry.path] else {
            statusMessage = "Open the map once, then you can favorite it"
            return
        }
        if favorites.contains(docID) {
            favorites.remove(docID)
        } else {
            favorites.insert(docID)
        }
        UserDefaults.standard.set(Array(favorites), forKey: Self.favoritesKey)
    }

    func isFavorite(_ entry: LibraryMapEntry) -> Bool {
        guard let docID = entry.docID ?? docIDsByPath[entry.path] else { return false }
        return favorites.contains(docID)
    }

    func open(_ entry: LibraryMapEntry) {
        NSDocumentController.shared.openDocument(withContentsOf: entry.url, display: true) { _, _, _ in }
    }

    func revealInFinder(_ entry: LibraryMapEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    /// Duplicate: copies the whole package next to the original, then
    /// indexes the copy.
    func duplicate(_ entry: LibraryMapEntry) async {
        let source = entry.url
        let folder = source.deletingLastPathComponent()
        let name = source.deletingPathExtension().lastPathComponent
        var target = folder.appending(path: "\(name) copy.arbor", directoryHint: .isDirectory)
        var attempt = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appending(path: "\(name) copy \(attempt).arbor", directoryHint: .isDirectory)
            attempt += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            try? await service.database.indexPackage(at: target)
            statusMessage = "Duplicated as \(target.deletingPathExtension().lastPathComponent)"
        } catch {
            statusMessage = "Couldn't duplicate: \(error.localizedDescription)"
        }
        await reload()
    }

    /// Move to Trash via the Finder (recoverable, F-LIB-2).
    func moveToTrash(_ entry: LibraryMapEntry) async {
        do {
            _ = try await NSWorkspace.shared.recycle([entry.url])
            await service.database.removePackage(at: entry.url)
            statusMessage = "Moved to Trash (recoverable in Finder)"
        } catch {
            statusMessage = "Couldn't move to Trash: \(error.localizedDescription)"
        }
        await reload()
    }

    func newMap() {
        NSDocumentController.shared.newDocument(nil)
    }

    func newFromTemplate(_ template: TemplateCatalog.Template) {
        do {
            _ = try templateStore.newDocument(from: template)
            statusMessage = "New map from “\(template.name)”"
        } catch {
            statusMessage = "Couldn't create from template: \(error.localizedDescription)"
        }
    }

    // MARK: folders (F-LIB-1)

    /// Adds a watched folder the user picked in the open panel. The
    /// folder must already exist — nothing is ever created silently.
    func addWatchedFolder(at url: URL) async {
        do {
            try await service.addWatchedFolder(url)
        } catch {
            statusMessage = "Couldn't watch \(url.lastPathComponent): \(error.localizedDescription)"
        }
        await reload()
    }

    func removeWatchedFolder(at path: String) async {
        try? await service.removeWatchedFolder(URL(fileURLWithPath: path))
        await reload()
    }

    // MARK: index maintenance (F-LIB-3)

    func rebuildIndex() async {
        let count = (try? await service.rebuildIndex()) ?? 0
        statusMessage = "Rebuilt index: \(count) maps"
        await reload()
    }

    // MARK: Concept Index "Link these" (F-LIB-4)

    /// Links a concept group's occurrences together: the first
    /// occurrence becomes the target; every other occurrence's node (in
    /// its OPEN document, via one undoable `setLink` command) gains an
    /// `x-arbor://` deep link to the target. Documents that are not
    /// open are NEVER written behind the user's back — they are
    /// reported back as deferred.
    func linkConcepts(in group: ConceptGroup) {
        guard let target = group.occurrences.first else { return }
        // Qualified: MapCore gained its own validated-link `ArborLink`
        // in M3, and this file imports both modules.
        let link = MapLibrary.ArborLink.url(docID: target.docID, nodeID: target.nodeID)
        let openDocuments = NSDocumentController.shared.documents.compactMap { $0 as? MapDocument }
        var linkedTitles: [String] = []
        var deferredTitles: [String] = []
        for occurrence in group.occurrences.dropFirst() {
            if let document = openDocuments.first(where: { $0.model.docID == occurrence.docID }) {
                try? document.store.perform(.setLink(id: occurrence.nodeID, link: link))
                linkedTitles.append(occurrence.documentTitle)
            } else {
                deferredTitles.append(occurrence.documentTitle)
            }
        }
        var message = "Linked \(linkedTitles.count) node(s) in open maps"
        if !deferredTitles.isEmpty {
            message += "; open \(deferredTitles.joined(separator: ", ")) to link the rest"
        }
        statusMessage = message
    }

    // MARK: favorites persistence

    private static let favoritesKey = "LibraryFavoriteDocIDs"
}
