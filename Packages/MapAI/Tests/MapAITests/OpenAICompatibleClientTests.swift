import Foundation
import Testing

@testable import MapAI

/// The OpenAI-compatible client's tests — members of the shared
/// serialized `NetworkClientTests` suite (the stub queue is global).
extension NetworkClientTests {
    private static let openAIStream = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":" world"}}]}

        data: {"choices":[{"finish_reason":"stop"}]}

        data: [DONE]

        """

    private func openAIProvider(
        base: String = "https://api.openai.com", key: String? = "sk-test"
    ) -> OpenAICompatibleProvider {
        var configuration = OpenAICompatibleProvider.Configuration(
            baseURL: URL(string: base)!, apiKey: key, model: "gpt-test")
        configuration.retryDelay = .seconds(0)
        return OpenAICompatibleProvider(configuration: configuration, session: URLProtocolStub.makeSession())
    }

    @Test func openAIStreamsDeltasAndFinishReason() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(Self.openAIStream))]
        let (text, finish) = try await openAIProvider().completeText(AIRequest(prompt: "hi"))
        #expect(text == "Hello world")
        #expect(finish.reason == .endTurn)
    }

    @Test func openAIRequestTargetsChatCompletionsWithBearerAndSystem() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(Self.openAIStream))]
        _ = try await openAIProvider().completeText(AIRequest(prompt: "hi", system: "be brief"))

        let captured = try #require(URLProtocolStub.captured.first)
        #expect(captured.method == "POST")
        #expect(captured.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(captured.headers["authorization"] == "Bearer sk-test")
        #expect(captured.headers["content-type"] == "application/json")
        let body = try #require(
            try JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        #expect(body["model"] as? String == "gpt-test")
        #expect(body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.last?["role"] as? String == "user")
    }

    @Test func openAINoKeySendsNoAuthorizationHeader() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(Self.openAIStream))]
        _ = try await openAIProvider(key: nil).completeText(AIRequest(prompt: "hi"))
        #expect(URLProtocolStub.captured[0].headers["authorization"] == nil)
    }

    @Test func openAILengthFinishMapsToTruncation() async throws {
        URLProtocolStub.reset()
        let stream = """
            data: {"choices":[{"delta":{"content":"partial"}}]}

            data: {"choices":[{"finish_reason":"length"}]}

            data: [DONE]

            """
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(stream))]
        let (_, finish) = try await openAIProvider().completeText(AIRequest(prompt: "p"))
        #expect(finish.reason == .maxTokens)
    }

    @Test func openAIContentFilterMapsToRefusal() async throws {
        URLProtocolStub.reset()
        let stream = """
            data: {"choices":[{"finish_reason":"content_filter"}]}

            data: [DONE]

            """
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(stream))]
        do {
            _ = try await openAIProvider().completeText(AIRequest(prompt: "p"))
            Issue.record("expected a refusal error")
        } catch let error as AIError {
            #expect(error == .refused)
        }
    }

    @Test func openAIMalformedFramesAreSkipped() async throws {
        URLProtocolStub.reset()
        let stream = """
            : keep-alive comment
            data: not json

            data: {"choices":[{"delta":{"content":"ok"}}]}

            data: [DONE]

            """
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(stream))]
        let (text, _) = try await openAIProvider().completeText(AIRequest(prompt: "p"))
        #expect(text == "ok")
    }

    @Test func openAIUnauthorizedMapsToTypedError() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [StubResponse(status: 401)]
        do {
            _ = try await openAIProvider().completeText(AIRequest(prompt: "p"))
            Issue.record("expected an unauthorized error")
        } catch let error as AIError {
            #expect(error == .unauthorized)
        }
    }

    @Test func openAIRateLimitRetriesOnce() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 429, headers: ["retry-after": "0"]),
            StubResponse(status: 200, chunks: sseChunks(Self.openAIStream)),
        ]
        let (text, _) = try await openAIProvider().completeText(AIRequest(prompt: "p"))
        #expect(text == "Hello world")
        #expect(URLProtocolStub.captured.count == 2)
    }

    @Test func localEndpointsAreNotCloud() throws {
        let local = OpenAICompatibleProvider(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "llama"))
        #expect(local.descriptor.isCloud == false)
        let remote = OpenAICompatibleProvider(
            configuration: .init(baseURL: URL(string: "https://api.openai.com")!, model: "gpt"))
        #expect(remote.descriptor.isCloud == true)
    }
}
