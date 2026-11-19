import Foundation
import Testing

@testable import MapAI

/// One request the stub saw, with the body reassembled from the stream
/// URLProtocol hands it (`httpBody` is nil there).
struct CapturedRequest {
    var url: URL?
    var method: String?
    var headers: [String: String]
    var body: Data
}

struct StubResponse {
    var status: Int
    var headers: [String: String] = [:]
    /// Delivered in order; chunk boundaries are arbitrary, which is
    /// exactly what streaming parsers must survive.
    var chunks: [Data] = []
    /// A transport failure instead of an HTTP response.
    var transportError: (any Error)?
}

/// Replays recorded SSE streams without any network. State is global
/// (URLProtocol is looked up by class), so every test in the stubbed
/// suites runs under `.serialized` and resets the queue first.
final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var queue: [StubResponse] = []
    nonisolated(unsafe) static var captured: [CapturedRequest] = []

    static func reset() {
        queue = []
        captured = []
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        URLProtocolStub.captured.append(
            CapturedRequest(
                url: request.url,
                method: request.httpMethod,
                headers: (request.allHTTPHeaderFields ?? [:])
                    .reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value },
                body: Self.body(of: request)))

        guard !URLProtocolStub.queue.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = URLProtocolStub.queue.removeFirst()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.local")!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers)

        if let error = stub.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Reassembles `httpBodyStream` (URLProtocol never sees `httpBody`).
    private static func body(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else {
            return request.httpBody ?? Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Records one SSE stream as stub chunks, splitting the payload at
/// arbitrary byte boundaries (mid-line, mid-UTF-8) — the parsers must
/// reassemble whatever the transport hands them.
func sseChunks(_ payload: String, boundaries: [Int] = [7, 23, 5]) -> [Data] {
    let bytes = Data(payload.utf8)
    var chunks: [Data] = []
    var offset = 0
    var cuts = boundaries
    while offset < bytes.count {
        let next = cuts.isEmpty ? bytes.count - offset : cuts.removeFirst()
        let end = min(offset + next, bytes.count)
        chunks.append(bytes.subdata(in: offset..<end))
        offset = end
    }
    return chunks
}
