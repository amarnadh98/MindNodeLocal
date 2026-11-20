import Foundation

/// JSON-RPC 2.0 plumbing for the MCP stdio transport (F-INT-4). Message
/// framing is newline-delimited JSON per the MCP stdio spec — one JSON
/// document per line, no embedded newlines — which `JSONLine`'s compact
/// encoder guarantees.
public enum JSONRPC {
    public static let version = "2.0"

    /// JSON-RPC error codes the server emits.
    public enum Code: Int, Sendable {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
    }
}

/// A request id: `null`, a number, or a string — echoed verbatim in the
/// response. `null` marks a notification (no response is expected).
public enum JSONRPCID: Sendable, Hashable, Codable {
    case null
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .number(let value):
            // Echo integral ids without a decimal point.
            if value.rounded() == value && abs(value) < 9.007199254740992e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        }
    }
}

/// One decoded request (or notification): `{"jsonrpc":"2.0","id":…,
/// "method":…,"params":…}`.
public struct JSONRPCRequest: Sendable, Equatable {
    public let id: JSONRPCID?
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCID?, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// The wire error payload (`code` + `message`).
public struct JSONRPCErrorPayload: Sendable, Equatable, Codable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// The wire response: `result` XOR `error`, plus the echoed id.
public struct JSONRPCResponse: Sendable, Equatable {
    public let id: JSONRPCID
    public let result: JSONValue?
    public let error: JSONRPCErrorPayload?

    public init(id: JSONRPCID, result: JSONValue?, error: JSONRPCErrorPayload? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    /// The wire line, ready for the transport.
    public func encoded() throws -> String {
        let payload: JSONValue
        if let error {
            payload = .object([
                ("jsonrpc", .string(JSONRPC.version)),
                ("id", encodedID),
                (
                    "error",
                    .object([
                        ("code", .number(Double(error.code))),
                        ("message", .string(error.message)),
                    ])
                ),
            ])
        } else {
            payload = .object([
                ("jsonrpc", .string(JSONRPC.version)),
                ("id", encodedID),
                ("result", result ?? .null),
            ])
        }
        return try JSONLine.encode(payload)
    }

    private var encodedID: JSONValue {
        switch id {
        case .null: .null
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        }
    }

    public static func parseError(_ message: String) -> JSONRPCResponse {
        JSONRPCResponse(
            id: .null, result: nil,
            error: JSONRPCErrorPayload(code: JSONRPC.Code.parseError.rawValue, message: message))
    }
}

/// Incremental newline-delimited message framing: feed raw text chunks,
/// get complete messages back. `\r\n` ends a message too (tolerant of
/// CRLF pipes); embedded newlines are impossible because every encoder
/// in the stack emits compact single-line JSON.
public struct MessageReader: Sendable {
    private var buffer = ""

    public init() {}

    /// Returns every complete message in `chunk`, in order. Line breaks
    /// are `\n` or `\r\n` — and on Swift strings a CRLF pair is ONE
    /// `Character`, so the scan uses `Character.isNewline`, which covers
    /// both spellings.
    public mutating func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var messages: [String] = []
        while let end = buffer.firstIndex(where: \.isNewline) {
            let line = String(buffer[buffer.startIndex..<end]).trimmingCharacters(in: .whitespaces)
            // Removing through `end` consumes the whole break — a CRLF
            // pair is a single character, both scalars go together.
            buffer.removeSubrange(buffer.startIndex...end)
            if !line.isEmpty {
                messages.append(line)
            }
        }
        return messages
    }
}
