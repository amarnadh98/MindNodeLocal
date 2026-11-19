import Foundation
import Testing

@testable import MapLibrary

@Suite struct WatchedFoldersTests {
    @Test func bookmarkStoreRoundTrip() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arbor-test-tmp/watched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = InMemoryBookmarkStore()
        var list = WatchedFolderList(store: store)
        try list.add(folder)

        // A fresh list over the same store reloads the same folder and
        // resolves its bookmark back to the same URL (symlink-resolved,
        // matching what the bookmark itself resolves to).
        let reloaded = WatchedFolderList(store: store)
        #expect(reloaded.folders.count == 1)
        #expect(reloaded.resolvedURLs() == [folder])
        #expect(reloaded.folders.first?.resolvedURL() == folder)

        var editing = reloaded
        try editing.remove(folder)
        #expect(WatchedFolderList(store: store).folders.isEmpty)
    }

    @Test func withAccessRunsBodyAgainstTheResolvedFolder() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arbor-test-tmp/watched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let watched = try WatchedFolder.make(url: folder)
        let seen: String = try watched.withAccess { url in url.lastPathComponent }
        #expect(seen == folder.lastPathComponent)
    }

    @Test func addingDuplicateOrMissingFolderIsSafe() throws {
        let store = InMemoryBookmarkStore()
        var list = WatchedFolderList(store: store)
        let existing = FileManager.default.homeDirectoryForCurrentUser
        try list.add(existing)
        try list.add(existing)
        #expect(list.folders.count == 1)

        var failing = WatchedFolderList(store: store)
        #expect(throws: WatchedFolderError.unresolvableBookmark("/no/such/place")) {
            try failing.add(URL(fileURLWithPath: "/no/such/place"))
        }
    }
}

/// A dictionary-backed `BookmarkStoring` for tests; the app's real store
/// is a JSON file under Application Support.
private final class InMemoryBookmarkStore: BookmarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [WatchedFolder] = []

    func loadFolders() throws -> [WatchedFolder] {
        lock.lock()
        defer { lock.unlock() }
        return folders
    }

    func saveFolders(_ folders: [WatchedFolder]) throws {
        lock.lock()
        self.folders = folders
        lock.unlock()
    }
}
