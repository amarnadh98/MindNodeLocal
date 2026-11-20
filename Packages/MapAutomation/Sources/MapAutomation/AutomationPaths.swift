import Foundation

/// Shared filesystem locations for the automation surfaces (F-INT-4,
/// ADR-0030). The sandboxed app and the unsandboxed helper must agree on
/// these paths, so they are computed the same way from the app's bundle
/// identifier:
///
/// `<home>/Library/Containers/<bundle-id>/Data/Library/Application Support/Arbor/`
///
/// which is exactly where the sandboxed app's
/// `.applicationSupportDirectory` points inside its container. The
/// socket alone lives one level up, in the container's home (see
/// `appSocketURL()`). An
/// environment override (`ARBOR_MCP_STATE_DIR`) exists for tests and
/// development builds.
public enum AutomationPaths {
    public static let stateDirectoryOverride = "ARBOR_MCP_STATE_DIR"
    /// Extra scan roots for the helper's local (app-closed) mode.
    public static let mapsDirectoryOverride = "ARBOR_MCP_MAP_DIRS"

    public static let directoryName = "Arbor"
    public static let socketName = "arbor-mcp.sock"
    public static let settingsName = "mcp-settings.json"

    /// The helper's view of the state directory (home-relative, since the
    /// helper is not sandboxed).
    public static func stateDirectory(bundleIdentifier: String) -> URL {
        if let override = ProcessInfo.processInfo.environment[stateDirectoryOverride], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return
            FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/\(directoryName)")
    }

    /// The app's view of the same directory (container-relative; inside
    /// the sandbox this is the container's Application Support).
    public static func appStateDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment[stateDirectoryOverride], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName)
    }

    public static func socketURL(directory: URL) -> URL {
        directory.appendingPathComponent(socketName)
    }

    /// The app's socket. It sits in the container's home (`…/Data/`),
    /// not the state directory: `sun_path` holds 104 bytes, and
    /// `…/Data/Library/Application Support/Arbor/arbor-mcp.sock` overflows
    /// it for any home path longer than about 13 characters, so the app
    /// could never bind. An unsandboxed (development) app keeps it in its
    /// state directory rather than the user's real home.
    public static func appSocketURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[stateDirectoryOverride], !override.isEmpty {
            return socketURL(directory: URL(fileURLWithPath: override))
        }
        guard environment["APP_SANDBOX_CONTAINER_ID"] != nil else {
            return socketURL(directory: appStateDirectory())
        }
        return socketURL(directory: URL(fileURLWithPath: NSHomeDirectory()))
    }

    /// The helper's view of `appSocketURL()` for a sandboxed app.
    public static func helperSocketURL(bundleIdentifier: String) -> URL {
        if let override = ProcessInfo.processInfo.environment[stateDirectoryOverride], !override.isEmpty {
            return socketURL(directory: URL(fileURLWithPath: override))
        }
        return socketURL(directory: containerHome(bundleIdentifier: bundleIdentifier))
    }

    static func containerHome(bundleIdentifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data")
    }

    public static func settingsURL(directory: URL) -> URL {
        directory.appendingPathComponent(settingsName)
    }

    /// Scan roots for the helper's local mode: the override if set, else
    /// the user's Documents (an unsandboxed helper may read it) plus the
    /// app container's Documents (where sandboxed Arbor writes new maps).
    public static func helperScanRoots(bundleIdentifier: String) -> [URL] {
        if let override = ProcessInfo.processInfo.environment[mapsDirectoryOverride],
            !override.isEmpty
        {
            return override.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents"),
            home
                .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Documents"),
        ]
    }

    /// Default folder for MCP-created maps when the app is closed.
    public static func defaultNewMapFolder(bundleIdentifier: String) -> URL {
        if let override = ProcessInfo.processInfo.environment[mapsDirectoryOverride],
            let first = override.split(separator: ":").first, !first.isEmpty
        {
            return URL(fileURLWithPath: String(first))
        }
        return
            FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Documents")
    }
}

/// The Integrations settings file the helper reads (SPEC §12: MCP is
/// read-only by default). The app writes it; the helper reads it fresh on
/// every request so a toggle takes effect without restarts.
public enum MCPEditPolicy {
    public struct Settings: Sendable, Equatable, Codable {
        public var allowEdits: Bool

        public init(allowEdits: Bool) {
            self.allowEdits = allowEdits
        }
    }

    public static let fileName = "mcp-settings.json"

    /// Missing or corrupt file means read-only — fail closed (SPEC §12).
    public static func load(directory: URL) -> Settings {
        let url = AutomationPaths.settingsURL(directory: directory)
        guard
            let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings(allowEdits: false) }
        return settings
    }

    public static func save(_ settings: Settings, directory: URL) throws {
        let url = AutomationPaths.settingsURL(directory: directory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: [.atomic])
        // 0600: only the local user (and the unsandboxed helper) reads it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
