import Foundation

/// The MCP server core (F-INT-4): one `initialize` handshake, `tools/list`
/// and `tools/call`, over any line-oriented transport. Pure — the helper
/// wires it to stdin/stdout, tests wire it to strings.
///
/// Read-only by default (SPEC §12): mutating tools are absent from
/// `tools/list` and refused by `tools/call` until the user enables edits
/// in Settings ▸ Integrations.
public struct MCPServer: Sendable {
    /// The protocol versions this build speaks; the client's requested
    /// version is echoed when it is one of these, else the newest.
    public static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    public static let latestVersion = "2025-06-18"

    public struct Info: Sendable {
        public var name = "arbor"
        public var version = "0.1.0"
        public var instructions =
            "Arbor mind maps. list_maps finds documents; read_map returns an outline. Read-only unless edits are enabled in Arbor's Integrations settings."

        public init() {}
    }

    public var info = Info()
    public let backend: ToolBackend

    public init(backend: ToolBackend, info: Info = Info()) {
        self.backend = backend
        self.info = info
    }

    /// Handles one incoming message line. Returns the response line to
    /// send back, or nil for notifications (no response, per JSON-RPC).
    public func handle(_ message: String) async -> String? {
        let request: JSONRPCRequest
        do {
            guard let payload = try JSONLine.decode(message).object else {
                return try? JSONRPCResponse.parseError("the message is not a JSON object").encoded()
            }
            guard (payload["jsonrpc"]?.string ?? "") == JSONRPC.version else {
                return try? respond(id: .null, error: .invalidRequest, "not a JSON-RPC 2.0 message").encoded()
            }
            guard let method = payload["method"]?.string, !method.isEmpty else {
                return try? respond(id: .null, error: .invalidRequest, "the message has no method").encoded()
            }
            request = JSONRPCRequest(id: payload["id"].flatMap(decodeID), method: method, params: payload["params"])
        } catch {
            return try? JSONRPCResponse.parseError("malformed JSON: \(error)").encoded()
        }

        // Notifications never get a response.
        guard let id = request.id, !id.isNull else { return nil }

        switch request.method {
        case "initialize":
            return try? await initialize(id: id, request).encoded()
        case "tools/list":
            return try? await toolsList(id: id).encoded()
        case "tools/call":
            return try? await toolsCall(id: id, request).encoded()
        case "ping":
            return try? respond(id: id, result: .object([:])).encoded()
        default:
            return try? respond(
                id: id, error: .methodNotFound, "unknown method \"\(request.method)\""
            ).encoded()
        }
    }

    // MARK: methods

    private func initialize(id: JSONRPCID, _ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        let requested = request.params?["protocolVersion"]?.string
        let version = Self.supportedVersions.contains(requested ?? "") ? requested! : Self.latestVersion
        let result = JSONValue.object([
            ("protocolVersion", .string(version)),
            (
                "capabilities",
                .object([("tools", .object([("listChanged", .bool(false))]))])
            ),
            (
                "serverInfo",
                .object([("name", .string(info.name)), ("version", .string(info.version))])
            ),
            ("instructions", .string(info.instructions)),
        ])
        return JSONRPCResponse(id: id, result: result)
    }

    private func toolsList(id: JSONRPCID) async throws -> JSONRPCResponse {
        let editsAllowed = await backend.editsAllowed()
        let tools = ArborTools.all
            .filter { !$0.isMutating || editsAllowed }
            .map(\.listEntry)
        return JSONRPCResponse(
            id: id, result: .object([("tools", .array(tools))]))
    }

    private func toolsCall(id: JSONRPCID, _ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = request.params?.object ?? [:]
        guard let name = params["name"]?.string, !name.isEmpty else {
            return respond(id: id, error: .invalidParams, "tools/call needs a tool name")
        }
        let arguments = params["arguments"]?.object ?? [:]
        guard let spec = ArborTools.named(name) else {
            return respond(
                id: id, error: .invalidParams, "unknown tool \"\(name)\" — try tools/list")
        }
        if spec.isMutating, !(await backend.editsAllowed()) {
            return toolFailure(
                id: id, name: name,
                message:
                    "\"\(name)\" is disabled: Arbor's MCP server is read-only until you enable edits in Arbor ▸ Settings ▸ Integrations."
            )
        }
        do {
            let value = try await backend.perform(ToolCall(name: name, arguments: .object(arguments)))
            return toolResult(id: id, name: name, value: value, isError: false)
        } catch let error as ToolError {
            switch error {
            case .badInput(let message):
                return respond(id: id, error: .invalidParams, message)
            case .notFound(let message):
                return toolFailure(id: id, name: name, message: message)
            case .disabled(let message):
                return toolFailure(id: id, name: name, message: message)
            }
        } catch {
            return toolFailure(id: id, name: name, message: "\(name) failed: \(error)")
        }
    }

    // MARK: response shaping

    private func respond(
        id: JSONRPCID, result: JSONValue? = nil, error: JSONRPC.Code? = nil, _ message: String = ""
    ) -> JSONRPCResponse {
        JSONRPCResponse(
            id: id,
            result: result,
            error: error.map {
                JSONRPCErrorPayload(code: $0.rawValue, message: message.isEmpty ? "\($0)" : message)
            })
    }

    /// The MCP tool-result envelope: text content always (clients show
    /// it), `structuredContent` when the result is an object, `isError`
    /// for failures reported in-band per the spec.
    private func toolResult(id: JSONRPCID, name: String, value: JSONValue, isError: Bool)
        -> JSONRPCResponse
    {
        let text = pretty(value)
        var pairs: [(String, JSONValue?)] = [
            ("content", .array([.object([("type", .string("text")), ("text", .string(text))])]))
        ]
        if case .object = value {
            pairs.append(("structuredContent", value))
        }
        pairs.append(("isError", .bool(isError)))
        return JSONRPCResponse(id: id, result: .object(pairs), error: nil)
    }

    private func toolFailure(id: JSONRPCID, name: String, message: String) -> JSONRPCResponse {
        toolResult(
            id: id, name: name,
            value: .object([("error", .string(message))]), isError: true)
    }

    private func decodeID(_ value: JSONValue) -> JSONRPCID? {
        switch value {
        case .null: .null
        case .number(let number): .number(number)
        case .string(let string): .string(string)
        default: nil
        }
    }

    private func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard
            let data = try? encoder.encode(value),
            let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return text
    }
}

/// A `JSONRPCID` that is not the `null` case.
extension JSONRPCID {
    fileprivate var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
