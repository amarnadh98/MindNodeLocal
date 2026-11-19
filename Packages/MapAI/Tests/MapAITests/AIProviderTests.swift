import Foundation
import Testing

@testable import MapAI

/// A provider whose streamed answers are scripted ahead of time — the
/// backbone of every no-network test (the real clients are exercised
/// through the URLProtocol stub instead). A class so successive
/// requests can pop successive scripts (multi-step generation).
public final class ScriptedProvider: AIProvider, @unchecked Sendable {
    public let descriptor: AIProviderDescriptor
    public var isReady = true
    /// Each request consumes one script entry (repeating the last when
    /// exhausted).
    private let lock = NSLock()
    private var script: [[String]]
    /// Thrown instead of streaming, when set.
    public var failure: (any Error)?
    /// Every request the provider served (for call assertions).
    public var servedRequests: [AIRequest] = []

    public init(
        descriptor: AIProviderDescriptor = AIProviderDescriptor(
            kind: .anthropic, displayName: "Scripted", isCloud: true),
        script: [[String]],
        failure: (any Error)? = nil
    ) {
        self.descriptor = descriptor
        self.script = script
        self.failure = failure
    }

    public convenience init(
        descriptor: AIProviderDescriptor = AIProviderDescriptor(
            kind: .anthropic, displayName: "Scripted", isCloud: true),
        deltas: [String],
        failure: (any Error)? = nil
    ) {
        self.init(descriptor: descriptor, script: [deltas], failure: failure)
    }

    private func nextDeltas() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !script.isEmpty else { return [] }
        if script.count > 1 {
            return script.removeFirst()
        }
        return script[0]
    }

    public func streamText(
        _ request: AIRequest, maxTokens: Int?
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        lock.lock()
        servedRequests.append(request)
        lock.unlock()
        let deltas = nextDeltas()
        let failure = failure
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                for delta in deltas {
                    await Task.yield()
                    continuation.yield(.textDelta(delta))
                }
                continuation.yield(.finished(AIFinish(reason: .endTurn)))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct EchoProvider: AIProvider {
    let descriptor = AIProviderDescriptor(kind: .apple, displayName: "Echo", isCloud: false)
    var isReady: Bool { true }

    func streamText(_ request: AIRequest, maxTokens: Int?) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(request.prompt))
            continuation.yield(.finished(AIFinish(reason: .endTurn)))
            continuation.finish()
        }
    }
}

@Test func providerStubConformsAndResponds() async throws {
    let provider: any AIProvider = EchoProvider()
    let (text, finish) = try await provider.completeText(AIRequest(prompt: "expand", context: ["root", "child"]))
    #expect(text == "expand")
    #expect(finish.reason == .endTurn)
}

@Test func requestDefaultsToEmptyContext() {
    let request = AIRequest(prompt: "summarize")
    #expect(request.context.isEmpty)
    #expect(request.system == nil)
}

@Test func scriptedProviderStreamsItsDeltasInOrder() async throws {
    let provider = ScriptedProvider(deltas: ["one", "two"])
    var collected = ""
    for try await event in provider.streamText(AIRequest(prompt: "p"), maxTokens: nil) {
        if case .textDelta(let delta) = event {
            collected += delta
        }
    }
    #expect(collected == "onetwo")
}

@Test func scriptedProviderThrowsItsFailure() async throws {
    let provider = ScriptedProvider(deltas: [], failure: AIError.refused)
    do {
        for try await _ in provider.streamText(AIRequest(prompt: "p"), maxTokens: nil) {}
        Issue.record("expected AIError.refused")
    } catch let error as AIError {
        #expect(error == .refused)
    }
}
