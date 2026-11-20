import AppKit
import Foundation
import MapAutomation
import MapCore
import os

/// The app-side socket endpoint (F-INT-4, ADR-0030): while Arbor runs, a
/// Unix-domain socket (mode 0600, inside the app container) answers the
/// helper's tool requests against the live app — mutations on OPEN
/// documents go through their `MapStore` as one undo step, marked
/// `lastModifiedBy: "mcp"` (SPEC §11.3); closed documents are edited
/// headlessly with file coordination. No TCP (SPEC §12).
@MainActor
enum AutomationRuntime {
    /// The running listener, if started.
    private static var server: UnixSocketServer?

    /// Starts listening. Safe to call repeatedly (a second call is a
    /// no-op while the endpoint is up).
    static func start() {
        guard server == nil else { return }
        let directory = AutomationSettings.stateDirectory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let path = AutomationPaths.appSocketURL().path
        let space = AppDocumentSpace()
        let listener = UnixSocketServer(path: path) { request in
            await handle(request, space: space)
        }
        do {
            try listener.start()
            server = listener
        } catch {
            // A busy or unusable socket is not fatal: the helper falls
            // back to direct file access, and the app keeps running.
            runtimeLog.warning("MCP socket unavailable: \(String(describing: error))")
        }
    }

    /// Stops listening (app termination).
    static func stop() {
        server?.stop()
        server = nil
    }

    /// One request: the mutating tools stay behind the Integrations
    /// toggle (defence in depth — the helper checks the same file before
    /// forwarding), then the shared engine runs against the app's space.
    private static func handle(_ request: SocketToolRequest, space: AppDocumentSpace) async
        -> SocketToolResponse
    {
        let engine = MapAutomationEngine(space: space, author: .mcp)
        if let spec = ArborTools.named(request.tool), spec.isMutating,
            !(await space.editsAllowed())
        {
            return .failure(
                ToolFailure(
                    kind: .disabled,
                    message:
                        "\"\(request.tool)\" is disabled: Arbor's MCP server is read-only until you enable edits in Arbor ▸ Settings ▸ Integrations."
                ))
        }
        do {
            let result = try await engine.perform(
                ToolCall(name: request.tool, arguments: request.arguments))
            return .success(result)
        } catch let error as ToolError {
            return .failure(ToolFailure(error))
        } catch {
            return .failure(ToolFailure(kind: .failure, message: "\(error)"))
        }
    }
}

/// The app's `DocumentSpace` (MapAutomation's seam): open documents live
/// in their stores; everything else is headless file access.
@MainActor
final class AppDocumentSpace: DocumentSpace {
    private let directory = AppMapDirectory()
    private let newMapFolder: URL

    init() {
        newMapFolder =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    func editsAllowed() async -> Bool {
        AutomationSettings.mcpEditsAllowed
    }

    func listMaps() async throws -> [MapRecord] {
        try await directory.allMaps()
    }

    func loadMap(reference: String) async throws -> LoadedMap? {
        if let open = AppMapDirectory.openDocument(matching: reference) {
            return LoadedMap(model: open.model, path: open.fileURL?.path)
        }
        guard let record = try await directory.findMap(matching: reference) else { return nil }
        let contents = try HeadlessMapEditor.read(at: URL(fileURLWithPath: record.path))
        return LoadedMap(model: contents.model, path: record.path)
    }

    func applyCommands(
        _ commands: [MapCommand], reference: String, author: AuthorKind
    ) async throws {
        // An OPEN document: through its MapStore, as ONE undo step.
        if let open = AppMapDirectory.openDocument(matching: reference) {
            let single = commands.count == 1 ? commands[0] : MapCommand.group(name: "MCP Edit", commands: commands)
            try open.store.perform(single, author: author)
            return
        }
        // Closed: coordinated read → commands → one atomic write.
        guard let record = try await directory.findMap(matching: reference) else {
            throw ToolError.notFound("no map matches \"\(reference)\"")
        }
        try HeadlessMapEditor.apply(
            commands, at: URL(fileURLWithPath: record.path), author: author)
    }

    func createMap(title: String?, outline: String?, folder: String?) async throws -> MapRecord {
        let model = try LocalDocumentSpace.model(title: title, outline: outline)
        let targetFolder = folder.map { URL(fileURLWithPath: $0) } ?? newMapFolder
        let name = LocalDocumentSpace.fileName(for: title, outline: outline)
        let url = Self.uniqueURL(folder: targetFolder, name: name)
        try HeadlessMapEditor.writeNew(
            model: model, at: url, author: .mcp, appVersion: AppIdentity.appVersion)
        // The app is running: show the new map, like File ▸ New would.
        NSDocumentController.shared.openDocument(
            withContentsOf: url, display: true
        ) { document, _, _ in
            _ = document
        }
        return
            MapRecord(
                docID: model.docID,
                title: FileSystemMapDirectory.title(of: model, fallback: name),
                path: url.path,
                modified: Date()
            )
    }

    /// First free `<base> N.arbor` in `folder`.
    static func uniqueURL(folder: URL, name: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(stem)
            counter += 1
        }
        return candidate
    }
}

private let runtimeLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "arbor", category: "automation")
