import Sparkle

/// Sparkle wiring (SPEC §13 "In-app updates", ADR-0021).
///
/// Privacy (SPEC §12): a plain launch performs **no network call**.
/// - `registerPrivacyDefaults()` runs before anything can construct
///   this class and registers automatic checks OFF.
/// - The Sparkle controller is created lazily — building the menu never
///   loads it — so the feed is only contacted when the user clicks
///   Check for Updates… or enables automatic checks themselves.
/// - `SUEnableSystemProfiling` is NO in the Info.plist, so Sparkle
///   never sends a system profile (SPEC §12 bans telemetry).
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// Sparkle's persisted preference key for automatic checks.
    static let automaticChecksKey = "SUEnableAutomaticChecksKey"

    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
    }

    /// Runs at launch, before the menu (or anything else) can touch the
    /// shared instance. The registration domain only fills in the key
    /// when the user has never made a choice, so an opt-in always wins.
    static func registerPrivacyDefaults() {
        UserDefaults.standard.register(defaults: [automaticChecksKey: false])
    }

    /// Whether the user has opted into automatic checks. Read straight
    /// from Sparkle's defaults key so menu validation never has to load
    /// the controller.
    var automaticallyChecks: Bool {
        UserDefaults.standard.bool(forKey: Self.automaticChecksKey)
    }

    /// The SPEC §12 opt-in switch. Sparkle persists the value under the
    /// same defaults key; the controller is started (and reads the key)
    /// on first use.
    func setAutomaticallyChecks(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.automaticChecksKey)
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    /// Whether Sparkle's controller has been started. Only the manual
    /// Check for Updates… action needs it; menu validation and the
    /// automatic-checks toggle read/write the defaults key directly.
    var isUpdaterRunning: Bool {
        controller != nil
    }

    /// The menu's Check for Updates… action — the manual,
    /// user-initiated feed check.
    func checkForUpdates() {
        startIfNeeded().updater.checkForUpdates()
    }

    private func startIfNeeded() -> SPUStandardUpdaterController {
        if let controller { return controller }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        return controller
    }
}
