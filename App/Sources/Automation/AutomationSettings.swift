import Foundation
import MapAutomation

/// Persisted automation settings (Settings ▸ Integrations, SPEC §5.20).
/// The MCP edit policy file is written here (the helper reads it from its
/// side of the same path — ADR-0030); the inbox document is a
/// security-scoped bookmark (the sandbox keeps access across launches).
enum AutomationSettings {
    static let inboxBookmarkKey = "ArborAutomationInboxBookmark"

    static var stateDirectory: URL {
        AutomationPaths.appStateDirectory()
    }

    /// Whether MCP edits are currently allowed. Missing/corrupt file =
    /// read-only (fail closed, SPEC §12).
    static var mcpEditsAllowed: Bool {
        MCPEditPolicy.load(directory: stateDirectory).allowEdits
    }

    static func setMCPEditsAllowed(_ allowed: Bool) {
        try? MCPEditPolicy.save(MCPEditPolicy.Settings(allowEdits: allowed), directory: stateDirectory)
    }

    // MARK: inbox document (F-INT-6 "Add Selection to Arbor Inbox")

    /// The configured inbox document, resolving its security-scoped
    /// bookmark (stale bookmarks refresh). `nil` when none is configured
    /// or the bookmark no longer resolves.
    @discardableResult
    static func inboxURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: inboxBookmarkKey) else { return nil }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
        else { return nil }
        if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(refreshed, forKey: inboxBookmarkKey)
        }
        return url
    }

    static func setInbox(url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(data, forKey: inboxBookmarkKey)
        }
    }

    static func clearInbox() {
        UserDefaults.standard.removeObject(forKey: inboxBookmarkKey)
    }

    // MARK: MCP client config snippets (F-INT-4)

    /// The bundled helper's absolute path inside the app bundle.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/arbor-mcp").path
    }

    /// The `mcpServers` JSON snippet Claude Desktop's config wants, with
    /// this install's absolute helper path.
    static func claudeDesktopConfig() -> String {
        let command = JSONValue.string(helperPath)
        let payload = JSONValue.object([
            (
                "mcpServers",
                .object([
                    ("arbor", .object([("command", command), ("args", .array([])), ("env", .object([:]))]))
                ])
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The `claude mcp add` command line for Claude Code, pointing at the
    /// same helper.
    static func claudeCodeCommand() -> String {
        "claude mcp add arbor -- '\(helperPath)'"
    }
}
