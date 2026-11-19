import Foundation

/// The persisted AI configuration (F-AI-1, SPEC §12): everything
/// Settings ▸ AI edits. Stored as one JSON blob under a single
/// UserDefaults key via `AISettingsStore`; API keys are NOT here —
/// they live in the Keychain (`APIKeyStore`), only this toggle records
/// whether one is stored.
public struct AISettings: Sendable, Equatable, Codable {
    /// The master off switch: AI is disabled by default (M8 exit
    /// criterion — every feature usable with AI off).
    public var enabled = false
    /// Which provider serves requests; on-device is the default and
    /// wins automatically when available (F-AI-1).
    public var provider: AIProviderDescriptor.Kind.RawValue = AIProviderDescriptor.Kind.apple.rawValue
    /// Anthropic: model id (default SPEC §17 item 4) and the
    /// server-side-fallback toggle (ADR-0017).
    public var anthropicModel = "claude-sonnet-5-5"
    public var anthropicFallbacks = true
    /// OpenAI-compatible endpoint: base URL + model, key optional
    /// (Ollama/LM Studio).
    public var openAIEndpoint = ""
    public var openAIModel = ""
    /// Whether a key for the given provider exists in the Keychain —
    /// display state, not the secret itself.
    public var hasAnthropicKey = false
    public var hasOpenAIKey = false
    /// The user has seen and accepted the privacy notice ("map text is
    /// sent to <provider>") for cloud providers — SPEC §12's
    /// before-the-first-cloud-call consent. Per-document opt-outs live
    /// in the document (`MapModel.ai`), not here.
    public var cloudConsentGranted = false

    public init() {}
}

/// Reads and writes `AISettings` from/to UserDefaults (injectable, so
/// tests use a suite-isolated instance). Not `Sendable` —
/// `UserDefaults` is thread-safe but not Sendable-annotated; the host
/// confines one instance to the main actor, exactly like every other
/// AppKit-adjacent store. Fails soft: a corrupt blob reads as
/// defaults, never blocks the app.
public struct AISettingsStore {
    public static let settingsKey = "com.arbor.ai.settings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AISettings {
        guard let data = defaults.data(forKey: Self.settingsKey) else {
            return AISettings()
        }
        guard let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return AISettings()
        }
        return settings
    }

    public func save(_ settings: AISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }
}

/// Resolves the configured provider (F-AI-1): on-device first when
/// available, else the configured cloud/local HTTP provider. Returns
/// nil when nothing is usable — the host then hides all AI UI.
public enum AIProviderFactory {
    /// The provider the settings select, given live readiness.
    public static func resolve(
        settings: AISettings,
        keys: any APIKeyStore,
        apple: (any AIProvider)? = AppleOnDeviceProvider(),
        session: URLSession = .shared
    ) -> (any AIProvider)? {
        guard settings.enabled else { return nil }
        switch AIProviderDescriptor.Kind(rawValue: settings.provider) ?? .apple {
        case .apple:
            return apple?.isReady == true ? apple : nil
        case .anthropic:
            guard let key = keys.load(account: APIKeyAccount.anthropic), !key.isEmpty else { return nil }
            var configuration = AnthropicProvider.Configuration()
            configuration.model = settings.anthropicModel
            configuration.fallbacksEnabled = settings.anthropicFallbacks
            return AnthropicProvider(apiKey: key, configuration: configuration, session: session)
        case .openAICompatible:
            guard
                let url = URL(string: settings.openAIEndpoint),
                !settings.openAIModel.isEmpty
            else { return nil }
            let key = keys.load(account: APIKeyAccount.openAICompatible)
            let configuration = OpenAICompatibleProvider.Configuration(
                baseURL: url, apiKey: key, model: settings.openAIModel)
            return OpenAICompatibleProvider(configuration: configuration, session: session)
        }
    }
}
