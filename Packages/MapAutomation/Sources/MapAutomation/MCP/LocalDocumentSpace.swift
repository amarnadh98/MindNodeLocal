import Foundation
import MapCore

/// The `DocumentSpace` the `arbor-mcp` helper uses when Arbor is not
/// running (F-INT-4): every map comes from the filesystem via
/// `NSFileCoordinator` + `ArborPackage`, every mutation is one atomic
/// write through `MapCommand`s. When the app IS running the helper
/// prefers the socket (`AppOrLocalBackend`), so open documents edit
/// through their live `MapStore` instead.
public struct LocalDocumentSpace: DocumentSpace {
    public let directory: MapDirectory
    public let defaultFolder: URL
    public let appVersion: String
    /// Fail closed: read-only unless the settings file says otherwise.
    public let policyDirectory: URL

    public init(
        directory: MapDirectory, defaultFolder: URL, policyDirectory: URL, appVersion: String
    ) {
        self.directory = directory
        self.defaultFolder = defaultFolder
        self.policyDirectory = policyDirectory
        self.appVersion = appVersion
    }

    public func editsAllowed() async -> Bool {
        MCPEditPolicy.load(directory: policyDirectory).allowEdits
    }

    public func listMaps() async throws -> [MapRecord] {
        try await directory.allMaps()
    }

    public func loadMap(reference: String) async throws -> LoadedMap? {
        guard let record = try await directory.findMap(matching: reference) else { return nil }
        let contents = try HeadlessMapEditor.read(at: URL(fileURLWithPath: record.path))
        return LoadedMap(model: contents.model, path: record.path)
    }

    public func applyCommands(
        _ commands: [MapCommand], reference: String, author: AuthorKind
    ) async throws {
        guard let record = try await directory.findMap(matching: reference) else {
            throw ToolError.notFound("no map matches \"\(reference)\"")
        }
        try HeadlessMapEditor.apply(
            commands, at: URL(fileURLWithPath: record.path), author: author)
    }

    public func createMap(title: String?, outline: String?, folder: String?) async throws
        -> MapRecord
    {
        let model = try Self.model(title: title, outline: outline)
        let targetFolder =
            folder.map { URL(fileURLWithPath: $0) } ?? defaultFolder
        let name = Self.fileName(for: title, outline: outline)
        let url = Self.uniqueURL(folder: targetFolder, name: name)
        try HeadlessMapEditor.writeNew(
            model: model, at: url, author: .mcp, appVersion: appVersion)
        return
            MapRecord(
                docID: model.docID,
                title: FileSystemMapDirectory.title(of: model, fallback: name),
                path: url.path,
                modified: Date()
            )
    }

    // MARK: creation helpers (pure; intent tests reuse them)

    /// Title + outline → one model. A bare title still yields a map whose
    /// root carries it, so `create_map {title: "Reading list"}` is useful.
    public static func model(title: String?, outline: String?) throws -> MapModel {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var model: MapModel
        if let outline, !outline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model = try OutlineConversion.importModel(from: outline)
        } else {
            model = MapModel.emptyDocument()
        }
        if trimmedTitle.isEmpty {
            if model.roots.isEmpty, model.nodes.isEmpty {
                let root = Node(id: UUID().uuidString, title: NodeTitle(text: "Untitled Map"))
                model.nodes[root.id] = root
                model.roots = [root.id]
            }
        } else {
            model.title = trimmedTitle
            if let rootID = model.roots.first, let root = model.nodes[rootID],
                root.title.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                model.nodes[rootID]?.title = NodeTitle(text: trimmedTitle)
            }
        }
        return model
    }

    /// A filesystem-safe package name for the created map.
    public static func fileName(for title: String?, outline: String?) -> String {
        var base = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.isEmpty, let outline {
            base =
                outline
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map { line in
                    String(line)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#-*- [ ]"))
                        .trimmingCharacters(in: .whitespaces)
                } ?? ""
        }
        var name = ""
        for scalar in base.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            if "/:\\".unicodeScalars.contains(scalar) {
                name.unicodeScalars.append("-")
            } else {
                name.unicodeScalars.append(scalar)
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (name.isEmpty ? "Untitled Map" : String(name.prefix(80))) + ".arbor"
    }

    static func uniqueURL(folder: URL, name: String) -> URL {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while manager.fileExists(atPath: candidate.path) {
            let stem = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(stem)
            counter += 1
        }
        return candidate
    }
}

/// The helper's `ToolBackend` (F-INT-4, ADR-0012): when the app is
/// running, forward the call over the Unix socket so edits hit the live
/// document's `MapStore`; otherwise run it against files directly.
/// The edit policy file gates both paths, so read-only mode holds no
/// matter which side executes.
public struct AppOrLocalBackend: ToolBackend {
    public let socketPath: String
    public let local: MapAutomationEngine
    public let policyDirectory: URL

    public init(
        socketPath: String, policyDirectory: URL, local: MapAutomationEngine
    ) {
        self.socketPath = socketPath
        self.policyDirectory = policyDirectory
        self.local = local
    }

    public func editsAllowed() async -> Bool {
        MCPEditPolicy.load(directory: policyDirectory).allowEdits
    }

    public func perform(_ call: ToolCall) async throws -> JSONValue {
        let client = SocketToolClient(path: socketPath)
        if let response = try? client.perform(SocketToolRequest(tool: call.name, arguments: call.arguments)) {
            if let result = response.result {
                return result
            }
            throw (response.failure ?? ToolFailure(kind: .failure, message: "the app refused the call"))
                .error
        }
        return try await local.perform(call)
    }
}
