import Foundation
import MapLibrary

/// The app's real `BookmarkStoring` (F-LIB-1): watched-folder bookmarks
/// persisted as JSON under Application Support, so sandboxed relaunches
/// keep access to the folders the user added.
final class AppBookmarkStore: BookmarkStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(baseURL: URL = AppBookmarkStore.defaultBaseURL()) {
        fileURL = baseURL.appending(path: "WatchedFolders.json")
    }

    static func defaultBaseURL() -> URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Arbor/Library", directoryHint: .isDirectory)
    }

    func loadFolders() throws -> [WatchedFolder] {
        lock.lock()
        let data = try? Data(contentsOf: fileURL)
        lock.unlock()
        guard let data else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([WatchedFolder].self, from: data)) ?? []
    }

    func saveFolders(_ folders: [WatchedFolder]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(folders)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
