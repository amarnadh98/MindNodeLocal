import Darwin
import Foundation

/// The request/response pair that crosses the helper ↔ app Unix socket
/// (F-INT-4, ADR-0030): one JSON line each way. The helper is a socket
/// *client*; the running app listens. No TCP anywhere (SPEC §12).
public struct SocketToolRequest: Sendable, Equatable, Codable {
    public let tool: String
    public let arguments: JSONValue

    public init(tool: String, arguments: JSONValue) {
        self.tool = tool
        self.arguments = arguments
    }
}

public struct SocketToolResponse: Sendable, Equatable, Codable {
    public let result: JSONValue?
    public let failure: ToolFailure?

    public init(result: JSONValue?, failure: ToolFailure?) {
        self.result = result
        self.failure = failure
    }

    public static func success(_ result: JSONValue) -> SocketToolResponse {
        SocketToolResponse(result: result, failure: nil)
    }

    public static func failure(_ failure: ToolFailure) -> SocketToolResponse {
        SocketToolResponse(result: nil, failure: failure)
    }
}

/// POSIX Unix-domain-socket plumbing (`AF_UNIX`, mode 0600). No TCP
/// (SPEC §12).
enum UnixSocket {
    /// `sun_path`'s capacity on Darwin.
    static let pathLimit = 104

    static func makeAddress(for path: String) -> sockaddr_un? {
        guard path.utf8.count < pathLimit else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cString in
            _ = strncpy(&address.sun_path.0, cString, pathLimit - 1)
        }
        return address
    }

    /// Reads until the next newline (`\n`, tolerating `\r\n`); `nil` on
    /// EOF, error or a message over 1 MiB.
    static func readLine(from descriptor: Int32) -> String? {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = recv(descriptor, &chunk, chunk.count, 0)
            guard received > 0 else { return nil }
            let slice = chunk[0..<received]
            if let newline = slice.firstIndex(of: 0x0A) {
                buffer.append(contentsOf: slice[0..<newline])
                if buffer.last == 0x0D { buffer.removeLast() }
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(contentsOf: slice)
            if buffer.count > 1 << 20 { return nil }
        }
    }

    /// Writes one message plus its newline.
    static func write(_ message: String, to descriptor: Int32) -> Bool {
        var data = Data((message + "\n").utf8)
        while !data.isEmpty {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return send(descriptor, base, data.count, 0)
            }
            guard written > 0 else { return false }
            data.removeFirst(written)
        }
        return true
    }
}

/// The app-side listener. One dedicated thread blocks in `accept`; each
/// accepted connection is handled on the cooperative pool (the request
/// handler hops to its own isolation), so one slow request never blocks
/// the accept loop. The socket file is created with mode 0600 — only the
/// local user can connect (SPEC §12).
///
/// `@unchecked Sendable`: the descriptor is created once, then confined
/// to the accept thread; `state` is only touched from start/stop on the
/// owning thread.
public final class UnixSocketServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable, Sendable {
        case bindFailed(String)
        case listenFailed(String)
    }

    private let path: String
    private let handler: @Sendable (SocketToolRequest) async -> SocketToolResponse
    private var thread: Thread?
    private var listenDescriptor: Int32 = -1

    public init(
        path: String, handler: @escaping @Sendable (SocketToolRequest) async -> SocketToolResponse
    ) {
        self.path = path
        self.handler = handler
    }

    /// Creates (or replaces a stale) socket file and starts accepting.
    /// Safe to call again after `stop`.
    public func start() throws {
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        guard let address = UnixSocket.makeAddress(for: path) else {
            throw ServerError.bindFailed("socket path too long: \(path)")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ServerError.bindFailed("socket() failed: \(String(cString: strerror(errno)))")
        }
        let size = MemoryLayout<sockaddr_un>.size(ofValue: address)
        let bound = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw ServerError.bindFailed("bind() failed: \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        guard listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw ServerError.listenFailed("listen() failed: \(String(cString: strerror(errno)))")
        }
        listenDescriptor = descriptor

        let acceptedDescriptor = descriptor
        let handler = handler
        let thread = Thread {
            self.acceptLoop(listenDescriptor: acceptedDescriptor, handler: handler)
        }
        thread.name = "arbor-mcp-socket"
        thread.start()
        self.thread = thread
    }

    /// Closes the listener; in-flight connections finish their current
    /// exchange. The socket file is left in place for the next start.
    public func stop() {
        guard listenDescriptor >= 0 else { return }
        close(listenDescriptor)
        listenDescriptor = -1
        thread = nil
    }

    private func acceptLoop(
        listenDescriptor: Int32, handler: @escaping @Sendable (SocketToolRequest) async -> SocketToolResponse
    ) {
        while true {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    accept(listenDescriptor, socketAddress, &length)
                }
            }
            guard client >= 0 else { return }
            // Each connection: read one request, answer, close.
            Task<Void, Never>.detached {
                defer { close(client) }
                guard let line = UnixSocket.readLine(from: client) else { return }
                guard let request = try? JSONLine.decode(line, as: SocketToolRequest.self) else {
                    if let encoded = try? JSONLine.encode(
                        SocketToolResponse.failure(
                            ToolFailure(kind: .badInput, message: "malformed request")))
                    {
                        _ = UnixSocket.write(encoded, to: client)
                    }
                    return
                }
                let response = await handler(request)
                if let line = try? JSONLine.encode(response) {
                    _ = UnixSocket.write(line, to: client)
                }
            }
        }
    }
}

/// The helper-side client: connect, one request, one response, close.
/// A refused/stale connection (app not running) is a plain `nil` — the
/// caller falls back to local file mode. A `receive` timeout keeps a
/// wedged app from wedging the helper.
public struct SocketToolClient: Sendable {
    public enum ClientError: Error, Equatable, Sendable {
        case unreachable
        case timeout
        case malformedResponse
    }

    public let path: String
    public let timeout: TimeInterval

    public init(path: String, timeout: TimeInterval = 10) {
        self.path = path
        self.timeout = timeout
    }

    /// `nil` when no app is listening on `path`.
    public func perform(_ request: SocketToolRequest) throws -> SocketToolResponse? {
        guard let address = UnixSocket.makeAddress(for: path) else {
            throw ClientError.unreachable
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        let seconds = Int(timeout)
        var receiveTimeout = timeval(
            tv_sec: seconds,
            tv_usec: __darwin_suseconds_t((timeout - Double(seconds)) * 1_000_000))
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size))

        let size = MemoryLayout<sockaddr_un>.size(ofValue: address)
        let connected = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(size))
            }
        }
        // No listener (app closed) or a stale socket file: unreachable,
        // which the caller treats as "fall back to local file mode".
        guard connected == 0 else { return nil }

        guard let requestLine = try? JSONLine.encode(request) else { throw ClientError.malformedResponse }
        guard UnixSocket.write(requestLine, to: descriptor) else { throw ClientError.timeout }
        guard let responseLine = UnixSocket.readLine(from: descriptor) else {
            throw ClientError.timeout
        }
        guard let response = try? JSONLine.decode(responseLine, as: SocketToolResponse.self) else {
            throw ClientError.malformedResponse
        }
        return response
    }
}
