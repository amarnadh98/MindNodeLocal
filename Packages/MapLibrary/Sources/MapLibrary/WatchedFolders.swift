import Foundation

/// One watched folder (F-LIB-1), persisted as a security-scoped bookmark
/// so sandboxed relaunches keep access. The raw bookmark data lives in
/// an injected `BookmarkStoring` — the app supplies the real store
/// (Application Support); tests use in-memory fakes.
public struct WatchedFolder: Sendable, Equatable, Codable {
    /// The folder's path as last seen (display only; the bookmark is
    /// the source of truth).
    public let path: String
    public let bookmarkData: Data

    public init(path: String, bookmarkData: Data) {
        self.path = path
        self.bookmarkData = bookmarkData
    }

    /// Captures `url` as a security-scoped bookmark. The path is stored
    /// symlink-resolved so it matches what the bookmark resolves back
    /// to (e.g. `/var` → `/private/var`) — paths are the folder's
    /// identity in the index and watcher.
    public static func make(url: URL) throws -> WatchedFolder {
        let resolved = url.resolvingSymlinksInPath()
        let data = try resolved.bookmarkData(options: .withSecurityScope)
        return WatchedFolder(path: resolved.path, bookmarkData: data)
    }

    /// Resolves the bookmark back to a URL; nil when the data is stale
    /// or corrupt (the folder was deleted or moved off-volume).
    public func resolvedURL() -> URL? {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
        else { return nil }
        return url
    }

    /// Runs `body` with the folder's security scope started, always
    /// stopping it again. Outside a sandbox `startAccessing…` simply
    /// returns false and no balancing stop happens.
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url = resolvedURL() else {
            throw WatchedFolderError.unresolvableBookmark(path)
        }
        let gained = url.startAccessingSecurityScopedResource()
        defer {
            if gained { url.stopAccessingSecurityScopedResource() }
        }
        return try body(url)
    }
}

public enum WatchedFolderError: Error, Equatable {
    case unresolvableBookmark(String)
}

/// Where watched-folder bookmarks persist. The app supplies the real
/// implementation (a JSON file under Application Support); MapLibrary
/// tests supply fakes.
public protocol BookmarkStoring: Sendable {
    func loadFolders() throws -> [WatchedFolder]
    func saveFolders(_ folders: [WatchedFolder]) throws
}

/// The watched-folder list on top of a `BookmarkStoring`: load once,
/// mutate (each mutation persists), and resolve for scanning.
public struct WatchedFolderList: Sendable {
    public private(set) var folders: [WatchedFolder]
    private let store: any BookmarkStoring

    public init(store: any BookmarkStoring) {
        self.store = store
        folders = (try? store.loadFolders()) ?? []
    }

    /// Adds a folder, resolving duplicates by path. The folder must
    /// exist — the UI only offers existing locations, never creating
    /// one silently (F-LIB-1).
    public mutating func add(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WatchedFolderError.unresolvableBookmark(url.path)
        }
        let resolved = url.resolvingSymlinksInPath()
        guard !folders.contains(where: { $0.path == resolved.path }) else { return }
        folders.append(try WatchedFolder.make(url: url))
        try store.saveFolders(folders)
    }

    public mutating func remove(_ url: URL) throws {
        let before = folders.count
        folders.removeAll { $0.path == url.path }
        guard folders.count != before else { return }
        try store.saveFolders(folders)
    }

    /// Resolves every bookmark to a live URL (dropping stale ones — a
    /// deleted folder quietly disappears from the watch list).
    public func resolvedURLs() -> [URL] {
        folders.compactMap { $0.resolvedURL() }
    }

    /// Default watch-location suggestion (F-LIB-1): the iCloud Drive
    /// Arbor folder when it exists, else ~/Documents/Arbor. Suggest,
    /// never create — nil when neither exists.
    public static func suggestedDefault() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud =
            home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Arbor")
        if FileManager.default.fileExists(atPath: iCloud.path) { return iCloud }
        let documents = home.appendingPathComponent("Documents/Arbor")
        if FileManager.default.fileExists(atPath: documents.path) { return documents }
        return nil
    }
}
