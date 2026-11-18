import Testing

@testable import MapAI

private struct EchoProvider: AIProvider {
    func complete(_ request: AIRequest) async throws -> AIResponse {
        AIResponse(text: request.prompt)
    }
}

@Test func providerStubConformsAndResponds() async throws {
    let provider: any AIProvider = EchoProvider()
    let response = try await provider.complete(AIRequest(prompt: "expand", context: ["root", "child"]))
    #expect(response == AIResponse(text: "expand"))
}

@Test func requestDefaultsToEmptyContext() {
    let request = AIRequest(prompt: "summarize")
    #expect(request.context.isEmpty)
}
