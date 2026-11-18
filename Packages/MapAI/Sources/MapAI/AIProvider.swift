import Foundation

/// A request to an AI backend: a prompt plus optional map context lines.
public struct AIRequest: Sendable, Equatable {
    public let prompt: String
    public let context: [String]

    public init(prompt: String, context: [String] = []) {
        self.prompt = prompt
        self.context = context
    }
}

/// An AI backend's completion.
public struct AIResponse: Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// A pluggable AI backend (SPEC §11.1: FoundationModels, Anthropic, OpenAI-compatible).
public protocol AIProvider: Sendable {
    func complete(_ request: AIRequest) async throws -> AIResponse
}
