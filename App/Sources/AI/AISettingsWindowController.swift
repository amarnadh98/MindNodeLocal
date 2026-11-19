import AppKit
import MapAI
import SwiftUI

/// The Settings ▸ AI model: one `AISettings` value bound to the
/// UserDefaults store, with API keys kept OUT of it — they move
/// directly between the SecureFields and the Keychain (SPEC §12:
/// keys never live in documents, logs or the settings blob).
@MainActor
final class AISettingsModel: ObservableObject {
    @Published var enabled: Bool
    @Published var providerKind: AIProviderDescriptor.Kind
    @Published var anthropicModel: String
    @Published var anthropicKey: String
    @Published var anthropicFallbacks: Bool
    @Published var openAIEndpoint: String
    @Published var openAIModel: String
    @Published var openAIKey: String
    @Published var consentGranted: Bool

    private let store: AISettingsStore
    private let keys: any APIKeyStore

    init(store: AISettingsStore = AISettingsStore(), keys: any APIKeyStore = SystemKeychainStore()) {
        self.store = store
        self.keys = keys
        let settings = store.load()
        enabled = settings.enabled
        providerKind = AIProviderDescriptor.Kind(rawValue: settings.provider) ?? .apple
        anthropicModel = settings.anthropicModel
        anthropicKey = keys.load(account: APIKeyAccount.anthropic) ?? ""
        anthropicFallbacks = settings.anthropicFallbacks
        openAIEndpoint = settings.openAIEndpoint
        openAIModel = settings.openAIModel
        openAIKey = keys.load(account: APIKeyAccount.openAICompatible) ?? ""
        consentGranted = settings.cloudConsentGranted
    }

    /// The provider being configured — for the privacy notice copy.
    var activeCloudDescriptor: AIProviderDescriptor? {
        switch providerKind {
        case .anthropic:
            return AIProviderDescriptor(kind: .anthropic, displayName: "Anthropic", isCloud: true)
        case .openAICompatible:
            let local = URL(string: openAIEndpoint)?.host?.isLocalHost == true
            return AIProviderDescriptor(
                kind: .openAICompatible, displayName: "OpenAI-compatible", isCloud: !local)
        case .apple:
            return nil
        }
    }

    /// Persists settings + keys. Keys are written to the Keychain, and
    /// removed from it when their field is emptied.
    func save() {
        var settings = store.load()
        settings.enabled = enabled
        settings.provider = providerKind.rawValue
        settings.anthropicModel = anthropicModel
        settings.anthropicFallbacks = anthropicFallbacks
        settings.openAIEndpoint = openAIEndpoint
        settings.openAIModel = openAIModel
        settings.cloudConsentGranted = consentGranted
        store.save(settings)

        try? keys.delete(account: APIKeyAccount.anthropic)
        if !anthropicKey.isEmpty {
            try? keys.save(anthropicKey, account: APIKeyAccount.anthropic)
        }
        try? keys.delete(account: APIKeyAccount.openAICompatible)
        if !openAIKey.isEmpty {
            try? keys.save(openAIKey, account: APIKeyAccount.openAICompatible)
        }
    }
}

extension String {
    fileprivate var isLocalHost: Bool {
        self == "localhost" || hasPrefix("127.") || hasPrefix("::1")
    }
}

/// Settings ▸ AI (F-AI-1): master switch, provider picker, model,
/// key (Keychain-backed), endpoint, the refusal-fallback toggle and
/// SPEC §12's privacy notice — "map text is sent to <provider>" for
/// cloud providers.
struct AISettingsView: View {
    @EnvironmentObject private var model: AISettingsModel

    var body: some View {
        Form {
            Toggle("Enable AI features", isOn: $model.enabled)

            Picker("Provider", selection: $model.providerKind) {
                Text("Apple On-Device (default)").tag(AIProviderDescriptor.Kind.apple)
                Text("Anthropic").tag(AIProviderDescriptor.Kind.anthropic)
                Text("OpenAI-compatible…").tag(AIProviderDescriptor.Kind.openAICompatible)
            }

            if model.providerKind == .anthropic {
                TextField("Model", text: $model.anthropicModel)
                SecureField("API Key (stored in Keychain)", text: $model.anthropicKey)
                Toggle("Retry refused requests server-side", isOn: $model.anthropicFallbacks)
            }
            if model.providerKind == .openAICompatible {
                TextField("Endpoint URL (e.g. http://127.0.0.1:11434)", text: $model.openAIEndpoint)
                TextField("Model", text: $model.openAIModel)
                SecureField("API Key (optional, Keychain)", text: $model.openAIKey)
            }

            if let cloud = model.activeCloudDescriptor, cloud.isCloud {
                Label(
                    "Privacy: when you use \(cloud.displayName), the text of this map is sent to \(cloud.displayName) over the network. Nothing is sent without an AI action.",
                    systemImage: "hand.raised"
                )
                .font(.callout)
            } else if model.providerKind == .apple {
                Text("On-device: map text never leaves this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.consentGranted {
                Button("Revoke cloud consent") {
                    model.consentGranted = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 380)
        .onDisappear { model.save() }
    }
}

/// The settings window (⌘,): a small, standard AppKit window hosting
/// the SwiftUI AI pane.
@MainActor
final class AISettingsWindowController: NSWindowController {
    static let settingsWindowIdentifier = "ai-settings"

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.identifier = .init(Self.settingsWindowIdentifier)
        let model = AISettingsModel()
        window.contentViewController = NSHostingController(
            rootView: AISettingsView().environmentObject(model))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AISettingsWindowController is created directly")
    }
}

@MainActor
enum AISettingsPresenter {
    static func present() {
        for window in NSApp.windows
        where window.identifier?.rawValue == AISettingsWindowController.settingsWindowIdentifier {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = AISettingsWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
