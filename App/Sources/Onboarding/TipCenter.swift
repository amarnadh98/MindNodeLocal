import AppKit

/// F-ONB-4: contextual tips — at most ONE per session (a launch-scoped
/// claim), each dismissible forever (a per-tip UserDefaults key). The
/// host decides which moment a tip fits; this center owns the "may I
/// show?" rules and the persistence, so the policy is testable
/// headlessly.
@MainActor
enum TipCenter {
    static let dismissedKeyPrefix = "TipDismissed."
    /// Session scope: reset on every launch, claimable once.
    private static var sessionClaimed = false

    /// The built-in tips and their moments. IDs are stable forever —
    /// they are the UserDefaults keys.
    static let keyboardFirstTip = Tip(
        id: "keyboard-first",
        message: "⇥ adds a child, ⏎ a sibling — and typing replaces a selected node.")
    static let freePlacementTip = Tip(
        id: "free-placement",
        message: "Hold ⌥ while dragging to place a node freely, or press D to detach it.")
    static let foldTip = Tip(
        id: "fold-branches",
        message: "A big map stays calm: ⌥. folds the selected branch — its count pill reopens it.")
    static let outlineTip = Tip(
        id: "outline-view",
        message: "⌘3 puts the outline beside the map — edits land in both at once.")

    struct Tip: Equatable, Sendable {
        let id: String
        let message: String
    }

    // MARK: rules

    /// True when `tip` may show NOW: never dismissed before, and this
    /// session has not shown any tip yet — in which case the session
    /// is claimed (the claim is the side effect, so a caller can't
    /// accidentally double-check it away).
    @discardableResult
    static func claimSessionOnce(for tip: Tip) -> Bool {
        guard !sessionClaimed, !isDismissed(tip.id) else { return false }
        sessionClaimed = true
        return true
    }

    static func isDismissed(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: dismissedKeyPrefix + id)
    }

    /// "Got it": this tip goes quiet forever (and this session has
    /// had its one tip either way).
    static func dismissForever(_ id: String) {
        UserDefaults.standard.set(true, forKey: dismissedKeyPrefix + id)
    }

    /// Settings ▸ Advanced ▸ Reset tips: every dismissal goes, so the
    /// tips start teaching again next session.
    static func resetAllDismissed() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(dismissedKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Hosted tests run several "launches" in one process.
    static func resetSessionClaim() {
        sessionClaimed = false
    }
}

/// The tip's face: a small rounded strip pinned to the bottom center of
/// the canvas, with the message and a "Got it" button. VoiceOver reads
/// the whole strip as one static text; the button stays a real button.
@MainActor
final class TipBannerView: NSView {
    static let height: CGFloat = 40
    var onDismiss: (() -> Void)?

    private let tip: TipCenter.Tip
    private var didDismiss = false

    init(tip: TipCenter.Tip) {
        self.tip = tip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let label = NSTextField(labelWithString: tip.message)
        label.font = .controlContentFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let button = NSButton(title: "Got it", target: self, action: #selector(dismissAction(_:)))
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Tip: \(tip.message)")
    }

    required init?(coder: NSCoder) { nil }

    @objc private func dismissAction(_ sender: Any?) {
        guard !didDismiss else { return }
        didDismiss = true
        TipCenter.dismissForever(tip.id)
        onDismiss?()
    }

    /// For hosted tests: the "Got it" path.
    func performDismissForTesting() {
        dismissAction(nil)
    }
}
