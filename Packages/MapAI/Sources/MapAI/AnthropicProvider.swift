import Foundation

/// The Anthropic Messages API backend (F-AI-1, ADR-0017): a hand-written
/// URLSession client — Swift has no official SDK and SPEC §11.1 caps
/// dependencies — speaking the exact wire contract this milestone was
/// specified against:
///
/// - `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`,
///   `anthropic-version: 2026-10-21`, `content-type: application/json`.
/// - `stream: true`; SSE frames `content_block_delta` carry
///   `text_delta` text. `thinking`/`thinking_delta`/`signature_delta`
///   blocks are IGNORED. `message_delta` carries `stop_reason`; the
///   stream ends at `message_stop`. `event: error` frames throw.
/// - `temperature`/`top_p`/`top_k` are NEVER sent (the model rejects
///   them), and neither is `thinking` (a `disabled` value 400s on this
///   model); instead `"output_config": {"effort": "low"}` keeps these
///   short creative tasks cheap.
/// - `stop_reason: "refusal"` throws `AIError.refused` — partial output
///   is discarded, never inserted. `"max_tokens"` finishes normally with
///   `AIFinish.Reason.maxTokens` so the caller can say it was truncated.
/// - With the fallback toggle on (default), requests carry
///   `anthropic-beta: server-side-fallback-2026-07-01` and
///   `"fallbacks": "default"`, so the API itself retries a refusal.
/// - HTTP 401 → `.unauthorized`; 429 → one retry honoring `retry-after`;
///   5xx/529 → one retry with backoff; transport failures → `.network`.
///
/// The API key is passed in by the host (which reads it from the
/// Keychain, SPEC §12) and is never logged or persisted here.
public struct AnthropicProvider: AIProvider {
    public struct Configuration: Sendable, Hashable {
        /// The default cloud model (SPEC §17 item 4), configurable in
        /// Settings ▸ AI.
        public var model = "claude-sonnet-5-5"
        public var anthropicVersion = "2026-10-21"
        /// Sends the server-side-fallback beta (refusal retry) — on by
        /// default, a Settings toggle.
        public var fallbacksEnabled = true
        /// Backoff between the single allowed retries; injectable so
        /// tests retry instantly.
        public var retryDelay = Duration.seconds(1)
        /// `max_tokens` when the caller passes none (expand: ~4096).
        public var defaultMaxTokens = 4_096

        public init() {}
    }

    public static let endpointURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let fallbacksBetaHeader = "server-side-fallback-2026-07-01"

    public let descriptor = AIProviderDescriptor(kind: .anthropic, displayName: "Anthropic", isCloud: true)
    public let configuration: Configuration
    private let apiKey: String
    private let session: URLSession

    public var isReady: Bool { !apiKey.isEmpty }

    public init(apiKey: String, configuration: Configuration = Configuration(), session: URLSession = .shared) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.session = session
    }

    public func streamText(
        _ request: AIRequest, maxTokens: Int?
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, maxTokens: maxTokens ?? configuration.defaultMaxTokens) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func run(
        _ request: AIRequest, maxTokens: Int, emit: @escaping @Sendable (AIStreamEvent) -> Void
    ) async throws {
        let urlRequest = try Self.makeURLRequest(
            prompt: request.prompt, system: request.system, maxTokens: maxTokens,
            model: configuration.model, apiKey: apiKey,
            anthropicVersion: configuration.anthropicVersion,
            fallbacksEnabled: configuration.fallbacksEnabled)
        let (bytes, _) = try await openStreamWithRetry(urlRequest)
        try Task.checkCancellation()
        try await Self.parseStream(bytes: bytes, emit: emit)
    }

    /// One retry for rate limits and server errors, none for 401
    /// (a bad key stays bad) — the exact policy the task pins down.
    private func openStreamWithRetry(_ urlRequest: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse)
    {
        for attempt in 0...1 {
            do {
                return try await openStream(urlRequest)
            } catch let error as AIError {
                guard attempt == 0 else { throw error }
                switch error {
                case .rateLimited(let retryAfter):
                    let delay = retryAfter.map { Duration.seconds(max(0, $0)) } ?? configuration.retryDelay
                    try await Task.sleep(for: delay)
                case .server:
                    try await Task.sleep(for: configuration.retryDelay)
                default:
                    throw error
                }
            }
        }
        throw AIError.server
    }

    /// Opens the byte stream, mapping transport and status failures to
    /// typed errors. 429 carries the server's `retry-after` hint.
    private func openStream(_ urlRequest: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AIError.network(String(describing: (error as NSError).code))
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIError.invalidResponse("not an HTTP response")
        }
        switch http.statusCode {
        case 200:
            return (bytes, http)
        case 401:
            throw AIError.unauthorized
        case 429:
            throw AIError.rateLimited(retryAfter: Self.retryAfter(from: http))
        case 500...:
            // 529 (overloaded) rides the same one-retry server policy.
            throw AIError.server
        default:
            let body = String(data: await Self.collect(bytes), encoding: .utf8) ?? ""
            throw AIError.invalidResponse("HTTP \(http.statusCode): \(body.prefix(200))")
        }
    }

    /// Drains an error body (bounded: error payloads are small).
    static func collect(_ bytes: URLSession.AsyncBytes) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 16_384 {
                    break
                }
            }
        } catch {
            // The status code is the answer; an unreadable body is fine.
        }
        return data
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after") else { return nil }
        if let seconds = TimeInterval(raw) {
            return seconds
        }
        if let date = HTTPDate.parse(raw) {
            return date.timeIntervalSinceNow
        }
        return nil
    }

    // MARK: request building

    /// The exact wire body (ADR-0017): no `temperature`/`top_p`/`top_k`,
    /// no `thinking`; `output_config.effort = "low"`; `fallbacks` only
    /// when the toggle is on. Snapshot-tested byte for byte.
    static func makeURLRequest(
        prompt: String,
        system: String?,
        maxTokens: Int,
        model: String,
        apiKey: String,
        anthropicVersion: String,
        fallbacksEnabled: Bool
    ) throws -> URLRequest {
        struct OutputConfig: Encodable {
            var effort = "low"
        }

        /// The wire body (snake_case keys per the API contract).
        struct Body: Encodable {
            struct Message: Encodable {
                var role = "user"
                var content: String
            }

            enum CodingKeys: String, CodingKey {
                case model
                case maxTokens = "max_tokens"
                case stream
                case system
                case messages
                case outputConfig = "output_config"
                case fallbacks
            }

            var model: String
            var maxTokens: Int
            var stream = true
            var system: String?
            var messages: [Message]
            var outputConfig = OutputConfig()
            var fallbacks: String?
        }
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if fallbacksEnabled {
            urlRequest.setValue(Self.fallbacksBetaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONEncoder().encode(
            Body(
                model: model,
                maxTokens: maxTokens,
                system: system,
                messages: [Body.Message(content: prompt)],
                fallbacks: fallbacksEnabled ? "default" : nil))
        return urlRequest
    }

    // MARK: stream parsing

    /// Frame shapes the Messages API streams. Unknown fields and frames
    /// decode to nil harmlessly (defensive parsing).
    struct EventData: Decodable {
        struct Delta: Decodable {
            enum CodingKeys: String, CodingKey {
                case type
                case text
                case stopReason = "stop_reason"
            }

            var type: String?
            var text: String?
            /// `message_delta` frames carry the stop reason here.
            var stopReason: String?
        }

        struct APIError: Decodable {
            var type: String?
            var message: String?
        }

        enum CodingKeys: String, CodingKey {
            case type
            case delta
            case stopReason = "stop_reason"
            case error
        }

        var type: String?
        var delta: Delta?
        /// Kept as a fallback: some server spellings hoist it.
        var stopReason: String?
        var error: APIError?
    }

    /// Consumes the SSE byte stream end to end: lines split by hand —
    /// `AsyncBytes.lines` skips the empty separator lines SSE frames
    /// dispatch on — so text deltas emit as they arrive;
    /// thinking/signature deltas are dropped; a refusal throws (partial
    /// output discarded); the finish carries the mapped stop reason.
    static func parseStream(
        bytes: URLSession.AsyncBytes, emit: @escaping @Sendable (AIStreamEvent) -> Void
    ) async throws {
        var parser = SSEStreamParser()
        var finishEmitted = false
        var buffer = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                var line = String(decoding: buffer, as: UTF8.self)
                if line.hasSuffix("\r") {
                    line.removeLast()
                }
                buffer.removeAll(keepingCapacity: true)
                guard let frame = parser.feed(line: line) else { continue }
                if let event = try handle(frame: frame, isFinished: &finishEmitted) {
                    emit(event)
                }
            } else {
                buffer.append(byte)
            }
        }
        if !buffer.isEmpty {
            var line = String(decoding: buffer, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            if let frame = parser.feed(line: line),
                let event = try handle(frame: frame, isFinished: &finishEmitted)
            {
                emit(event)
            }
        }
        if let frame = parser.finish(), let event = try handle(frame: frame, isFinished: &finishEmitted) {
            emit(event)
        }
    }

    private static func handle(frame: SSEFrame, isFinished: inout Bool) throws -> AIStreamEvent? {
        let data = SSEJSON.decode(EventData.self, from: frame)
        switch frame.event ?? data?.type {
        case "content_block_delta":
            guard let delta = data?.delta else { return nil }
            // Only text deltas surface; thinking_delta and
            // signature_delta blocks are ignored by design.
            if delta.type == "text_delta", let text = delta.text, !text.isEmpty {
                return .textDelta(text)
            }
            return nil
        case "message_delta":
            if let reason = data?.delta?.stopReason ?? data?.stopReason {
                switch reason {
                case "refusal":
                    // The provider declined: no partial output may be
                    // inserted (the stream throws, the caller drops it).
                    throw AIError.refused
                case "max_tokens":
                    if !isFinished {
                        isFinished = true
                        return .finished(AIFinish(reason: .maxTokens))
                    }
                default:
                    if !isFinished {
                        isFinished = true
                        return .finished(AIFinish(reason: .endTurn))
                    }
                }
            }
            return nil
        case "message_stop":
            if !isFinished {
                isFinished = true
                return .finished(AIFinish(reason: .endTurn))
            }
            return nil
        case "error":
            throw AIError.invalidResponse(data?.error?.message ?? "stream error")
        default:
            // message_start, content_block_start/stop, ping, anything
            // unrecognized: ignored.
            return nil
        }
    }
}

/// Minimal RFC 7231 HTTP-date parsing for `retry-after` hints.
enum HTTPDate {
    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]

    static func parse(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }
}
