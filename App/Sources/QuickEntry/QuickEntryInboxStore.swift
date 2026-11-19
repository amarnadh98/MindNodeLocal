import AppKit
import Foundation
import UniformTypeIdentifiers

/// The designated inbox document (F-QEN-2 "Append to Inbox map"):
/// the one `.arbor` file every Quick Entry capture can be filed into
/// without picking anything. The choice persists in UserDefaults as a
/// security-scoped bookmark (the sandbox keeps working across relaunches)
/// with the plain path as a fallback — which is also what makes the
/// flow deterministic in hosted tests, where the bookmark mints from a
/// temp URL inside the app's own writable containers.
@MainActor
final class QuickEntryInboxStore {
    static let shared = QuickEntryInboxStore()

    static let bookmarkKey = "QuickEntryInboxBookmark"
    static let pathKey = "QuickEntryInboxPath"
    static let nameKey = "QuickEntryInboxName"

    /// The URLs whose security scope this store has started and keeps
    /// alive for the process (one inbox at a time; releasing would close
    /// the sandbox door while the user may still be capturing).
    private var scopedURLs: [URL] = []

    init() {}

    /// The inbox URL, or nil before the user designates one. Resolves
    /// the bookmark (security-scoped first, plain second) and falls back
    /// to the stored path — a missing or moved file yields a URL the
    /// open path reports as an error, never a crash here.
    func resolve(defaults: UserDefaults = .standard) -> URL? {
        if let data = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            {
                return startScope(url)
            }
            if let url = try? URL(
                resolvingBookmarkData: data, options: [],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            {
                return startScope(url)
            }
        }
        guard let path = defaults.string(forKey: Self.pathKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The inbox's file name for buttons and settings copy.
    func displayName(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: Self.nameKey)
    }

    /// Records `url` as the inbox (an NSOpenPanel result): bookmark plus
    /// path plus name. In a sandboxed app a plain `bookmarkData()` on a
    /// user-selected URL is security-scoped already.
    func setInbox(_ url: URL, defaults: UserDefaults = .standard) {
        if let bookmark = try? url.bookmarkData() {
            defaults.set(bookmark, forKey: Self.bookmarkKey)
        } else if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            defaults.set(bookmark, forKey: Self.bookmarkKey)
        }
        defaults.set(url.path, forKey: Self.pathKey)
        defaults.set(url.lastPathComponent, forKey: Self.nameKey)
    }

    /// Forgets the inbox (Settings ▸ Shortcuts ▸ Inbox: "None").
    func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.pathKey)
        defaults.removeObject(forKey: Self.nameKey)
    }

    /// Runs the designation panel (modal, once per call): pick any
    /// `.arbor` file; cancel yields nil. The result is also recorded, so
    /// the next capture needs no panel at all.
    func chooseInboxMap() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.arborContentType]
        panel.message = "Choose the document Quick Entry appends to."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setInbox(url)
        return url
    }

    /// The `.arbor` package content type for open panels.
    private static let arborContentType =
        UTType(AppIdentity.documentUTI)
        ?? UTType(filenameExtension: AppIdentity.documentExtension)
        ?? .package

    /// Starts (once) the bookmark's security scope and remembers the URL.
    private func startScope(_ url: URL) -> URL {
        if !scopedURLs.contains(url) {
            _ = url.startAccessingSecurityScopedResource()
            scopedURLs.append(url)
        }
        return url
    }
}
