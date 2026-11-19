import Foundation
import Testing

@testable import MapAI

/// Keychain wrapper (SPEC §12) against the in-memory double — the
/// system Keychain itself is only touched by the running app.
struct KeychainStoreTests {
    @Test func inMemoryRoundTrip() throws {
        let store = InMemoryKeyStore()
        #expect(store.load(account: APIKeyAccount.anthropic) == nil)
        try store.save("sk-abc", account: APIKeyAccount.anthropic)
        #expect(store.load(account: APIKeyAccount.anthropic) == "sk-abc")
        // Overwrite semantics.
        try store.save("sk-new", account: APIKeyAccount.anthropic)
        #expect(store.load(account: APIKeyAccount.anthropic) == "sk-new")
        try store.delete(account: APIKeyAccount.anthropic)
        #expect(store.load(account: APIKeyAccount.anthropic) == nil)
    }

    @Test func accountsAreIsolated() throws {
        let store = InMemoryKeyStore()
        try store.save("a", account: APIKeyAccount.anthropic)
        try store.save("b", account: APIKeyAccount.openAICompatible)
        #expect(store.load(account: APIKeyAccount.anthropic) == "a")
        #expect(store.load(account: APIKeyAccount.openAICompatible) == "b")
    }

    @Test func deletingAnAbsentKeyIsNotAnError() throws {
        let store = InMemoryKeyStore()
        try store.delete(account: "never-stored")
    }
}

/// Settings persistence + provider resolution (F-AI-1).
struct AISettingsTests {
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsAreDisabledAndOnDevice() {
        let settings = AISettings()
        #expect(settings.enabled == false)
        #expect(settings.provider == AIProviderDescriptor.Kind.apple.rawValue)
        #expect(settings.anthropicModel == "claude-sonnet-5-5")
        #expect(settings.anthropicFallbacks == true)
        #expect(settings.cloudConsentGranted == false)
    }

    @Test func roundTripsThroughTheStore() throws {
        let defaults = try isolatedDefaults()
        let store = AISettingsStore(defaults: defaults)
        var settings = AISettings()
        settings.enabled = true
        settings.provider = AIProviderDescriptor.Kind.anthropic.rawValue
        settings.openAIEndpoint = "http://127.0.0.1:11434"
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func corruptBlobReadsAsDefaults() throws {
        let defaults = try isolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: AISettingsStore.settingsKey)
        #expect(AISettingsStore(defaults: defaults).load() == AISettings())
    }

    @Test func disabledSettingsResolveNoProvider() {
        let keys = InMemoryKeyStore()
        var settings = AISettings()
        settings.enabled = false
        #expect(AIProviderFactory.resolve(settings: settings, keys: keys, apple: nil) == nil)
    }

    @Test func anthropicNeedsAKey() {
        let keys = InMemoryKeyStore()
        var settings = AISettings()
        settings.enabled = true
        settings.provider = AIProviderDescriptor.Kind.anthropic.rawValue
        #expect(AIProviderFactory.resolve(settings: settings, keys: keys, apple: nil) == nil)
        try? keys.save("sk-live", account: APIKeyAccount.anthropic)
        let provider = AIProviderFactory.resolve(settings: settings, keys: keys, apple: nil)
        #expect(provider?.descriptor.kind == .anthropic)
        #expect(provider?.isReady == true)
    }

    @Test func openAICompatibleEndpointResolves() throws {
        let keys = InMemoryKeyStore()
        var settings = AISettings()
        settings.enabled = true
        settings.provider = AIProviderDescriptor.Kind.openAICompatible.rawValue
        settings.openAIEndpoint = "http://127.0.0.1:11434"
        settings.openAIModel = "llama3"
        let provider = try #require(
            AIProviderFactory.resolve(settings: settings, keys: keys, apple: nil))
        #expect(provider.descriptor.kind == .openAICompatible)
        #expect(provider.descriptor.isCloud == false)
    }

    @Test func appleProviderResolvesWhenAvailable() {
        let keys = InMemoryKeyStore()
        var settings = AISettings()
        settings.enabled = true
        let apple = ScriptedProvider(
            descriptor: AIProviderDescriptor(kind: .apple, displayName: "Apple On-Device", isCloud: false),
            deltas: ["hi"])
        #expect(AIProviderFactory.resolve(settings: settings, keys: keys, apple: apple) != nil)
    }

    @Test func appleUnavailableFallsThroughToNil() {
        let keys = InMemoryKeyStore()
        var settings = AISettings()
        settings.enabled = true
        let offline = OfflineAppleProvider()
        #expect(AIProviderFactory.resolve(settings: settings, keys: keys, apple: offline) == nil)
    }
}

/// An Apple-provider stand-in that reports not-ready: the real
/// `AppleOnDeviceProvider` checks `SystemLanguageModel` availability,
/// which tests must never depend on.
struct OfflineAppleProvider: AIProvider {
    let descriptor = AIProviderDescriptor(kind: .apple, displayName: "Apple On-Device", isCloud: false)
    var isReady: Bool { false }

    func streamText(_ request: AIRequest, maxTokens: Int?) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIError.unavailable("offline in tests")) }
    }
}
