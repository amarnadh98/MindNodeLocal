import Foundation
import MapAutomation
import MapCore

/// `arbor-mcp` (F-INT-4, ADR-0030): the bundled stdio MCP helper. Claude
/// Desktop / Claude Code launches it; it answers newline-delimited
/// JSON-RPC 2.0 on stdin/stdout.
///
/// Doc resolution: while Arbor runs, every tool call is forwarded over a
/// Unix-domain socket in the app's container (mode 0600), so open
/// documents edit through their live `MapStore` (stamped `mcp`). When
/// the app is closed, calls run against files directly through
/// `NSFileCoordinator` + `ArborPackage`. Read-only by default; the
/// mutating tools appear only when `mcp-settings.json` says edits are
/// allowed (Settings ▸ Integrations in the app writes that file).
///
/// No dependencies, no TCP, no telemetry (SPEC §11.1, §12).

/// The app's bundle identifier (the container the socket lives in).
let appBundleIdentifier = "com.example.arbor"

let stateDirectory = AutomationPaths.stateDirectory(bundleIdentifier: appBundleIdentifier)
let socketPath = AutomationPaths.helperSocketURL(bundleIdentifier: appBundleIdentifier).path
let policyDirectory = stateDirectory

let localSpace = LocalDocumentSpace(
    directory: FileSystemMapDirectory(
        roots: AutomationPaths.helperScanRoots(bundleIdentifier: appBundleIdentifier)),
    defaultFolder: AutomationPaths.defaultNewMapFolder(bundleIdentifier: appBundleIdentifier),
    policyDirectory: policyDirectory,
    appVersion: "0.1.0"
)
let backend = AppOrLocalBackend(
    socketPath: socketPath,
    policyDirectory: policyDirectory,
    local: MapAutomationEngine(space: localSpace, author: .mcp)
)
let server = MCPServer(backend: backend)

/// A one-slot transfer cell for the synchronous bridge. Written once by
/// the detached task before `signal`, read once after `wait` — the
/// semaphore makes the hand-off ordered, so `@unchecked Sendable` covers
/// exactly that pattern.
final class ResultBox: @unchecked Sendable {
    var value: String?
}

/// Synchronous bridge for the blocking stdin loop: run `operation` on
/// the cooperative pool and wait for it. MCP stdio is sequential, so one
/// in-flight request at a time is the contract; the main thread is free
/// (nothing else runs on it), so waiting here cannot deadlock.
func runSynchronously(_ operation: @escaping @Sendable () async -> String?) -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox()
    Task<Void, Never>.detached {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

/// One message in, zero or one line out. `FileHandle.standardOutput`
/// writes are unbuffered `write(2)` calls, so piped clients see each
/// response immediately (a buffered `print` would stall them).
func handleMessage(_ message: String) {
    guard let response = runSynchronously({ await server.handle(message) }) else { return }
    FileHandle.standardOutput.write(Data((response + "\n").utf8))
}

// The stdio loop: newline-delimited JSON (MCP stdio spec). EOF ends it.
var reader = MessageReader()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    guard let text = String(data: chunk, encoding: .utf8) else { continue }
    for message in reader.feed(text) {
        handleMessage(message)
    }
}
