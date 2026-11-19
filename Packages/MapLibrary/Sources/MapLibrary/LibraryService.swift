import Foundation

/// The app-facing library façade: watched folders (bookmarked via the
/// injected store), the SQLite index, and the watcher — all off the
/// main actor. The app's coordinator observes document saves and calls
/// `handleDocumentSaved(at:)`; the watcher's debounced batches funnel
/// into `handleWatchedEvents(_:)`.
public actor LibraryService {
    public let database: LibraryDatabase
    private let watcher: LibraryWatcher
    private var folderList: WatchedFolderList
    private let bookmarkStore: any BookmarkStoring

    public init(
        database: LibraryDatabase,
        bookmarkStore: any BookmarkStoring,
        watcher: LibraryWatcher = LibraryWatcher()
    ) {
        self.database = database
        self.watcher = watcher
        self.bookmarkStore = bookmarkStore
        self.folderList = WatchedFolderList(store: bookmarkStore)
    }

    /// Wires the debounced watcher batches into incremental reindexes.
    /// Call once after init; the closure hops off the source's queue.
    public func startWatching(eventSource: any PackageEventSource) async {
        await watcher.attach(to: eventSource)
        await watcher.onBatch { [weak self] urls in
            guard let self else { return }
            Task { await self.handleWatchedEvents(urls) }
        }
        for folder in folderList.resolvedURLs() {
            await watcher.watch(folder: folder)
        }
    }

    // MARK: folders

    /// The watched folders' paths as last persisted (display only).
    public func watchedFolderPaths() -> [String] {
        folderList.folders.map(\.path)
    }

    /// Adds a watched folder and indexes it immediately. The folder
    /// must already exist (F-LIB-1: suggest, never create).
    public func addWatchedFolder(_ url: URL) async throws {
        try folderList.add(url)
        await watcher.watch(folder: url)
        await indexFolder(url)
    }

    public func removeWatchedFolder(_ url: URL) async throws {
        try folderList.remove(url)
        await watcher.unwatch(folder: url)
    }

    /// Scans and indexes every package under one folder.
    public func indexFolder(_ folder: URL) async {
        for package in PackageScanner.packages(in: folder) {
            try? await database.indexPackage(at: package)
        }
    }

    /// The F-LIB-1 default suggestion (iCloud ▸ Arbor, else
    /// ~/Documents/Arbor), nil when neither exists.
    public static func suggestedDefault() -> URL? {
        WatchedFolderList.suggestedDefault()
    }

    // MARK: change handling

    /// A document save: incremental reindex of that one package
    /// (F-LIB-3 "updated on save").
    public func handleDocumentSaved(at url: URL) async {
        try? await database.indexPackage(at: url)
    }

    /// A debounced watcher batch: index packages that still exist,
    /// drop ones that vanished (F-LIB-3 external changes).
    public func handleWatchedEvents(_ urls: [URL]) async {
        for package in Self.packageURLs(from: urls) {
            if FileManager.default.fileExists(atPath: package.path) {
                try? await database.indexPackage(at: package)
            } else {
                await database.removePackage(at: package)
            }
        }
    }

    /// Maps raw event paths (often a file *inside* a package, e.g.
    /// `Foo.arbor/map.json`) to the enclosing `.arbor` package URLs,
    /// deduplicated by path.
    public static func packageURLs(from eventURLs: [URL]) -> [URL] {
        var found: Set<String> = []
        for url in eventURLs {
            let path = Self.normalizedPath(url)
            guard path != "/" else { continue }
            if url.pathExtension.lowercased() == "arbor" {
                found.insert(path)
                continue
            }
            let components = url.pathComponents
            for index in components.indices.reversed() where index > 0 {
                if components[index].lowercased().hasSuffix(".arbor") {
                    found.insert("/" + components[1...index].joined(separator: "/"))
                    break
                }
            }
        }
        return
            found
            .map { URL(fileURLWithPath: $0) }
            .sorted { $0.path < $1.path }
    }

    /// A POSIX path with any trailing slash removed, so identity
    /// comparisons don't split on `/x/` vs `/x`.
    static func normalizedPath(_ url: URL) -> String {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// "Rebuild Index" (F-LIB-3): wipe and rescan every watched folder.
    @discardableResult
    public func rebuildIndex() async throws -> Int {
        try await database.rebuild(folders: folderList.resolvedURLs())
    }
}
