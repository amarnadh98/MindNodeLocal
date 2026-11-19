import AppKit
import MapCore
import MapLibrary

/// The Library's app-side wiring: creates the index (disposable, in
/// Application Support), starts the watcher, observes every document
/// save (F-LIB-3 "updated on save") and owns the one Library window.
@MainActor
final class LibraryCoordinator {
    let service: LibraryService
    let templateStore: TemplateStore
    private(set) var windowController: LibraryWindowController?
    private var model: LibraryModel?

    /// Injectable index/bookmark/template locations for hosted tests.
    init(
        indexURL: URL = LibraryCoordinator.defaultIndexURL(),
        bookmarkStore: AppBookmarkStore = AppBookmarkStore(),
        templateStore: TemplateStore = TemplateStore()
    ) {
        self.templateStore = templateStore
        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-index-\(UUID().uuidString).sqlite")
        let database =
            Self.openDatabase(at: indexURL) ?? Self.openDatabase(at: fallbackURL)
            ?? Self.openInMemoryIndex()
        service = LibraryService(database: database, bookmarkStore: bookmarkStore)
        Task {
            await service.startWatching(eventSource: FSEventsPackageEventSource())
        }
        observeDocumentSaves()
    }

    /// The index is disposable (F-LIB-3): if it won't open, delete it
    /// and recreate from scratch; a genuinely unusable location falls
    /// back to a throwaway file rather than taking the app down.
    private static func openDatabase(at url: URL) -> LibraryDatabase? {
        if let database = try? LibraryDatabase(url: url) { return database }
        try? FileManager.default.removeItem(at: url)
        return try? LibraryDatabase(url: url)
    }

    /// Last resort: an in-memory index (lost on quit, rebuilt next
    /// launch). `sqlite3_open(":memory:")` with no filesystem access
    /// cannot meaningfully fail.
    private static func openInMemoryIndex() -> LibraryDatabase {
        do {
            return try LibraryDatabase(url: URL(fileURLWithPath: ":memory:"))
        } catch {
            preconditionFailure("in-memory SQLite index could not open: \(error)")
        }
    }

    static func defaultIndexURL() -> URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Arbor/Library/LibraryIndex.sqlite")
    }

    /// The Window ▸ Library action (⇧⌘L): creates the window on first
    /// use, orders it front afterwards.
    func showLibrary() {
        if windowController == nil {
            let model = LibraryModel(service: service, templateStore: templateStore)
            self.model = model
            windowController = LibraryWindowController(model: model)
        }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// F-LIB-3: every save of an open document reindexes that package
    /// incrementally. `MapDocument.didSaveNotification` carries the URL.
    private func observeDocumentSaves() {
        NotificationCenter.default.addObserver(
            forName: MapDocument.didSaveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.userInfo?[MapDocument.savedFileURLKey] as? URL else { return }
            let service = self?.service
            Task { await service?.handleDocumentSaved(at: url) }
        }
    }
}
