import Foundation
import Testing

@testable import MapAI

/// F-AI-1: the streaming HTTP clients' wire behaviour, replayed through
/// the `URLProtocol` stub — no network, ever. Both provider families
/// live in ONE serialized suite because the stub's queue is global.
@Suite(.serialized)
struct NetworkClientTests {
    private static let textStream = """
        event: message_start
        data: {"type":"message_start","message":{}}

        event: content_block_start
        data: {"type":"content_block_start","index":0}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Mindful"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"internal"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" breathing"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" drills"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}

        """

    private func provider(fallbacks: Bool = true) -> AnthropicProvider {
        var configuration = AnthropicProvider.Configuration()
        configuration.fallbacksEnabled = fallbacks
        configuration.retryDelay = .seconds(0)
        return AnthropicProvider(
            apiKey: "test-key", configuration: configuration, session: URLProtocolStub.makeSession())
    }

    private func dequeueBody() throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: URLProtocolStub.captured[0].body) as? [String: Any])
    }

    @Test func streamsTextDeltasAndIgnoresThinkingBlocks() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 200, chunks: sseChunks(Self.textStream))
        ]
        let (text, finish) = try await provider().completeText(AIRequest(prompt: "expand"))
        #expect(text == "Mindful breathing drills")
        #expect(finish.reason == .endTurn)
    }

    @Test func requestCarriesTheExactWireContract() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 200, chunks: sseChunks(Self.textStream))
        ]
        _ = try await provider().completeText(
            AIRequest(prompt: "p", system: "s"), maxTokens: 4_096)

        let captured = try #require(URLProtocolStub.captured.first)
        #expect(captured.method == "POST")
        #expect(captured.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(captured.headers["x-api-key"] == "test-key")
        #expect(captured.headers["anthropic-version"] == "2026-10-21")
        #expect(captured.headers["content-type"] == "application/json")
        #expect(captured.headers["anthropic-beta"] == AnthropicProvider.fallbacksBetaHeader)

        let body = try dequeueBody()
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == 4_096)
        #expect(body["stream"] as? Bool == true)
        #expect((body["system"] as? String) == "s")
        #expect(body["fallbacks"] as? String == "default")
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "low")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")

        // The rejected and forbidden fields never ship (ADR-0017).
        #expect(body["temperature"] == nil)
        #expect(body["top_p"] == nil)
        #expect(body["top_k"] == nil)
        #expect(body["thinking"] == nil)
    }

    @Test func fallbacksToggleRemovesBetaHeaderAndBodyField() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 200, chunks: sseChunks(Self.textStream))
        ]
        _ = try await provider(fallbacks: false).completeText(AIRequest(prompt: "p"))
        let captured = try #require(URLProtocolStub.captured.first)
        #expect(captured.headers["anthropic-beta"] == nil)
        let body = try dequeueBody()
        #expect(body["fallbacks"] == nil)
    }

    @Test func refusalThrowsAndDiscardsPartialOutput() async throws {
        URLProtocolStub.reset()
        let stream = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}

            """
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(stream))]
        do {
            _ = try await provider().completeText(AIRequest(prompt: "p"))
            Issue.record("expected a refusal error")
        } catch let error as AIError {
            #expect(error == .refused)
        }
    }

    @Test func maxTokensFinishesWithTruncationReason() async throws {
        URLProtocolStub.reset()
        let stream = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"cut short"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}

            """
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(stream))]
        let (text, finish) = try await provider().completeText(AIRequest(prompt: "p"))
        #expect(text == "cut short")
        #expect(finish.reason == .maxTokens)
    }

    @Test func malformedLinesAreIgnoredNotFatal() async throws {
        URLProtocolStub.reset()
        let stream = """
            garbage without any SSE shape
            event: content_block_delta
            data: {not json at all}
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"survived"}}

            id: 42
            event: message_stop
            data: {"type":"message_stop"}

            """
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(stream))]
        let (text, finish) = try await provider().completeText(AIRequest(prompt: "p"))
        #expect(text == "survived")
        #expect(finish.reason == .endTurn)
    }

    @Test func unterminatedFinalFrameStillFlushes() async throws {
        URLProtocolStub.reset()
        // Ends without the blank line after message_stop.
        let stream = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"tail"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
            """
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(stream))]
        let (text, finish) = try await provider().completeText(AIRequest(prompt: "p"))
        #expect(text == "tail")
        #expect(finish.reason == .endTurn)
    }

    @Test func errorFrameThrowsInvalidResponse() async throws {
        URLProtocolStub.reset()
        let stream = """
            event: error
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

            """
        URLProtocolStub.queue = [StubResponse(status: 200, chunks: sseChunks(stream))]
        do {
            _ = try await provider().completeText(AIRequest(prompt: "p"))
            Issue.record("expected an error")
        } catch let error as AIError {
            #expect(error == .invalidResponse("Overloaded"))
        }
    }

    @Test func unauthorizedIsTypedAndNeverRetried() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 401, chunks: [Data("{\"type\":\"error\"}".utf8)])
        ]
        do {
            _ = try await provider().completeText(AIRequest(prompt: "p"))
            Issue.record("expected an unauthorized error")
        } catch let error as AIError {
            #expect(error == .unauthorized)
        }
        #expect(URLProtocolStub.captured.count == 1)
    }

    @Test func rateLimitRetriesOnceHonoringRetryAfter() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 429, headers: ["retry-after": "0"]),
            StubResponse(status: 200, chunks: sseChunks(Self.textStream)),
        ]
        let (text, _) = try await provider().completeText(AIRequest(prompt: "p"))
        #expect(text == "Mindful breathing drills")
        #expect(URLProtocolStub.captured.count == 2)
    }

    @Test func rateLimitTwiceGivesUpWithTheHint() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 429, headers: ["retry-after": "0"]),
            StubResponse(status: 429, headers: ["retry-after": "0"]),
        ]
        do {
            _ = try await provider().completeText(AIRequest(prompt: "p"))
            Issue.record("expected a rate-limit error")
        } catch let error as AIError {
            #expect(error == .rateLimited(retryAfter: 0))
        }
        #expect(URLProtocolStub.captured.count == 2)
    }

    @Test func overloadedRetriesOnceThenSucceeds() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 529),
            StubResponse(status: 200, chunks: sseChunks(Self.textStream)),
        ]
        let (text, _) = try await provider().completeText(AIRequest(prompt: "p"))
        #expect(text == "Mindful breathing drills")
        #expect(URLProtocolStub.captured.count == 2)
    }

    @Test func serverErrorTwiceThrowsServer() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 500),
            StubResponse(status: 503),
        ]
        do {
            _ = try await provider().completeText(AIRequest(prompt: "p"))
            Issue.record("expected a server error")
        } catch let error as AIError {
            #expect(error == .server)
        }
    }

    @Test func transportFailureIsATypedNetworkError() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.queue = [
            StubResponse(status: 0, transportError: URLError(.notConnectedToInternet))
        ]
        do {
            _ = try await provider().completeText(AIRequest(prompt: "p"))
            Issue.record("expected a network error")
        } catch let error as AIError {
            guard case .network = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func emptyKeyMeansNotReady() {
        let provider = AnthropicProvider(apiKey: "", session: URLProtocolStub.makeSession())
        #expect(provider.isReady == false)
    }
}
