import Foundation

/// An OpenAI-compatible chat-completions backend (F-AI-1 option 3):
/// user-supplied base URL + optional key + model — which also covers
/// local servers such as Ollama and LM Studio (`http://127.0.0.1:11434`
/// etc.). Streaming via `/v1/chat/completions` SSE, the one wire format
/// every compatible server speaks.
///
/// Cloud classification (SPEC §12): a loopback/`localhost` endpoint is
/// treated as local (no map text leaves the machine); everything else
/// is cloud and needs consent. The privacy copy in Settings says so.
public struct OpenAICompatibleProvider: AIProvider {
    public struct Configuration: Sendable, Hashable {
        /// Base URL, e.g. `https://api.openai.com` or
        /// `http://127.0.0.1:11434`. The client appends
        /// `/v1/chat/completions`.
        public var baseURL: URL
        /// Optional bearer key — local servers usually need none.
        public var apiKey: String?
        public var model: String
        public var defaultMaxTokens = 4_096
        public var retryDelay = Duration.seconds(1)

        public init(baseURL: URL, apiKey: String? = nil, model: String) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
        }
    }

    public let descriptor: AIProviderDescriptor
    public let configuration: Configuration
    public var isReady: Bool { !configuration.model.isEmpty }
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.descriptor = AIProviderDescriptor(
            kind: .openAICompatible,
            displayName: "OpenAI-compatible",
            isCloud: Self.isCloudEndpoint(configuration.baseURL))
    }

    /// Loopback endpoints stay on the machine (SPEC §12): they are not
    /// cloud for consent purposes.
    static func isCloudEndpoint(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return !host.isLoopbackHost
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
            baseURL: configuration.baseURL, apiKey: configuration.apiKey,
            model: configuration.model, prompt: request.prompt, system: request.system,
            maxTokens: maxTokens)
        let (bytes, _) = try await openStreamWithRetry(urlRequest)
        try Task.checkCancellation()
        try await Self.parseStream(bytes: bytes, emit: emit)
    }

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
            throw AIError.rateLimited(retryAfter: AnthropicProvider.retryAfter(from: http))
        case 500...:
            throw AIError.server
        default:
            let body = String(data: await AnthropicProvider.collect(bytes), encoding: .utf8) ?? ""
            throw AIError.invalidResponse("HTTP \(http.statusCode): \(body.prefix(200))")
        }
    }

    // MARK: request building

    static func makeURLRequest(
        baseURL: URL, apiKey: String?, model: String, prompt: String, system: String?, maxTokens: Int
    ) throws -> URLRequest {
        /// The wire body (snake_case keys per the API contract).
        struct Body: Encodable {
            struct Message: Encodable {
                var role: String
                var content: String
            }

            enum CodingKeys: String, CodingKey {
                case model
                case stream
                case maxTokens = "max_tokens"
                case messages
            }

            var model: String
            var stream = true
            var maxTokens: Int
            var messages: [Message]
        }
        guard
            let url = URL(
                string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    + "/v1/chat/completions")
        else {
            throw AIError.invalidResponse("bad endpoint URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        var messages: [Body.Message] = []
        if let system, !system.isEmpty {
            messages.append(Body.Message(role: "system", content: system))
        }
        messages.append(Body.Message(role: "user", content: prompt))
        urlRequest.httpBody = try JSONEncoder().encode(
            Body(model: model, maxTokens: maxTokens, messages: messages))
        return urlRequest
    }

    // MARK: stream parsing

    struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var role: String?
                var content: String?
            }

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }

            var delta: Delta?
            var finishReason: String?
        }

        var choices: [Choice]?
    }

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
        // The OpenAI wire format has no `event:` lines; [DONE] closes.
        if frame.data == "[DONE]" {
            if !isFinished {
                isFinished = true
                return .finished(AIFinish(reason: .endTurn))
            }
            return nil
        }
        guard let chunk = SSEJSON.decode(StreamChunk.self, from: frame) else { return nil }
        guard let choice = chunk.choices?.first else { return nil }
        if let text = choice.delta?.content, !text.isEmpty {
            return .textDelta(text)
        }
        if let reason = choice.finishReason, !isFinished {
            isFinished = true
            switch reason {
            case "length":
                return .finished(AIFinish(reason: .maxTokens))
            case "content_filter":
                // The provider declined this content.
                throw AIError.refused
            default:
                return .finished(AIFinish(reason: .endTurn))
            }
        }
        return nil
    }
}

extension String {
    /// True for `localhost`, `127.x.x.x`, `::1` and other loopback
    /// spellings.
    fileprivate var isLoopbackHost: Bool {
        if self == "localhost" || hasSuffix(".localhost") {
            return true
        }
        if hasPrefix("127.") || hasPrefix("::1") {
            return true
        }
        return false
    }
}
