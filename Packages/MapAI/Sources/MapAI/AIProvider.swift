import Foundation

/// A request to an AI backend: a prompt, an optional system prompt, and
/// optional map-context lines. `AIRequest` never carries API keys — the
/// provider owns credentials (SPEC §12: keys live in the Keychain).
public struct AIRequest: Sendable, Equatable {
    public let prompt: String
    public let system: String?
    public let context: [String]

    public init(prompt: String, system: String? = nil, context: [String] = []) {
        self.prompt = prompt
        self.system = system
        self.context = context
    }
}

/// One streamed completion event (F-AI-1/F-AI-2): text arrives in
/// `textDelta`s, then exactly one `finished` event closes the stream.
public enum AIStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case finished(AIFinish)
}

/// How a completion ended; providers map their wire stop reasons onto
/// these. A refusal never finishes normally — it throws
/// `AIError.refused` so the caller discards any partial output.
public struct AIFinish: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case endTurn
        case maxTokens
    }

    /// `nil` when the provider reports no explicit stop reason.
    public let reason: Reason?

    public init(reason: Reason? = nil) {
        self.reason = reason
    }
}

/// Identity + privacy facts about a provider, for settings UI and
/// consent copy (SPEC §12: "map text is sent to <provider>").
public struct AIProviderDescriptor: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case apple
        case anthropic
        case openAICompatible
    }

    public let kind: Kind
    public let displayName: String
    /// True when prompts leave the machine (Anthropic, remote
    /// OpenAI-compatible endpoints). False for the on-device model and
    /// local endpoints (Ollama/LM Studio) — the caller decides via
    /// `isLocalEndpoint` for the OpenAI-compatible kind.
    public let isCloud: Bool

    public init(kind: Kind, displayName: String, isCloud: Bool) {
        self.kind = kind
        self.displayName = displayName
        self.isCloud = isCloud
    }
}

/// Every AI failure the app surfaces (F-AI-1): typed, so the UI can
/// show the right friendly message instead of raw transport errors.
public enum AIError: Error, Equatable, Sendable {
    /// The AI master switch (Settings ▸ AI) is off.
    case notEnabled
    /// No configured provider can serve requests right now.
    case noUsableProvider
    /// The document is marked "Never send to cloud AI" and only a cloud
    /// provider is usable (SPEC §12).
    case cloudBlockedByDocument
    /// The first cloud call needs the user's explicit consent.
    case consentRequired(AIProviderDescriptor)
    /// The provider declined the request (`stop_reason: refusal`).
    /// Partial output must be discarded, never inserted.
    case refused
    /// `max_tokens` reached: the text parsed so far is kept, but the
    /// user should be told it was cut short.
    case truncated
    /// HTTP 401: the stored API key is missing or bad.
    case unauthorized
    /// HTTP 429 even after the one allowed retry; `retryAfter` carries
    /// the server's hint when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// HTTP 5xx / 529 even after the one allowed retry.
    case server
    /// The transport failed (offline, DNS, TLS).
    case network(String)
    /// The response could not be parsed at all.
    case invalidResponse(String)
    /// The on-device model is unavailable on this Mac.
    case unavailable(String)
}

/// A pluggable AI backend (SPEC §11.1, F-AI-1): async, streaming and
/// cancellable. Cancelling the consuming `Task` terminates the request
/// (the stream's `onTermination` cancels the transport).
public protocol AIProvider: Sendable {
    /// Identity and privacy facts of this backend.
    var descriptor: AIProviderDescriptor { get }

    /// True when this backend can serve a request right now (key
    /// present, endpoint set, model available). When false for every
    /// provider, the app hides all AI UI (F-AI-1).
    var isReady: Bool { get }

    /// Streams a plain-text completion for `request`. Text arrives as
    /// deltas; the stream always ends with exactly one `finished` event
    /// (or throws). `maxTokens` bounds the completion length; providers
    /// substitute a sensible default when nil.
    func streamText(_ request: AIRequest, maxTokens: Int?) -> AsyncThrowingStream<AIStreamEvent, Error>
}

extension AIProvider {
    /// Collects a stream into its full text plus finish reason — the
    /// convenience non-streaming callers (tests, generation steps) use.
    public func completeText(_ request: AIRequest, maxTokens: Int? = nil) async throws -> (
        text: String, finish: AIFinish
    ) {
        var text = ""
        var finish = AIFinish()
        for try await event in streamText(request, maxTokens: maxTokens) {
            switch event {
            case .textDelta(let delta):
                text += delta
            case .finished(let resolved):
                finish = resolved
            }
        }
        return (text, finish)
    }
}
