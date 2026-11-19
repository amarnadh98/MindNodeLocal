import AppKit
import SwiftUI

/// F-ONB-1: the first-launch welcome. Three cards — Think · Present ·
/// Learn, the app's one-line purpose (SPEC §1) — then "Open Sample
/// Map" (the tour map that teaches by doing) or "New Map". The seen
/// flag persists in UserDefaults; Help ▸ "Welcome to Arbor" reopens
/// the window regardless, and closing it counts as seen (a dismissed
/// welcome never nags).
@MainActor
final class WelcomeCoordinator: NSObject, NSWindowDelegate {
    static let seenKey = "OnboardingWelcomeSeen"

    private var window: NSWindow?

    /// Shows the welcome once per user (`force` is Help's reopen).
    func showIfNeeded(force: Bool = false) {
        guard force || !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        show()
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Welcome to Arbor"
        window.isRestorable = false
        // Programmatic windows default to released-when-closed; the
        // coordinator owns the window (and hosted tests close it), so
        // its lifetime must follow the reference, not the close event.
        window.isReleasedWhenClosed = false
        window.center()
        let coordinator = WelcomeActions(
            openSampleMap: { [weak self] in self?.openSampleMap() },
            newMap: { [weak self] in self?.newMap() })
        window.contentView = NSHostingView(rootView: WelcomeView(actions: coordinator))
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// "Open Sample Map": the tour is written fresh and opened as a
    /// real document the user can keep, restyle or throw away.
    private func openSampleMap() {
        markSeenAndClose()
        SampleMap.openTour()
    }

    /// "New Map": the standard untitled document (which starts in the
    /// Settings default theme with its root already editing, F-CAN-3).
    private func newMap() {
        markSeenAndClose()
        NSDocumentController.shared.newDocument(nil)
    }

    /// For hosted tests: the open welcome window, if any.
    var windowForTesting: NSWindow? { window }

    /// For hosted tests: the "New Map" door's coordinator path (the
    /// hosted button calls the same closure).
    func chooseNewMapForTesting() {
        newMap()
    }

    private func markSeenAndClose() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        window?.close()
    }

    // MARK: NSWindowDelegate

    /// Any dismissal (the close button included) marks the welcome
    /// seen — the first-run path happens exactly once per user. The
    /// class is MainActor, AppKit's delegate methods hop here on the
    /// main thread like every other NSWindowDelegate in this app.
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        if let closing = notification.object as? NSWindow, closing === window {
            window = nil
        }
    }
}

/// The welcome's action surface (the SlidesUIActions pattern).
struct WelcomeActions: Sendable {
    var openSampleMap: @MainActor () -> Void = {}
    var newMap: @MainActor () -> Void = {}
}

/// The welcome face: the three cards plus the two doors.
struct WelcomeView: View {
    let actions: WelcomeActions

    private struct Card {
        let title: String
        let symbol: String
        let lines: [String]
    }

    private let cards: [Card] = [
        Card(
            title: "Think",
            symbol: "lightbulb.max",
            lines: [
                "Type one idea, press ⇥, type the next.",
                "The map grows as fast as you think.",
            ]),
        Card(
            title: "Present",
            symbol: "play.circle",
            lines: [
                "Turn any map into a talk — branches",
                "build on screen, one key press at a time.",
            ]),
        Card(
            title: "Learn",
            symbol: "graduationcap",
            lines: [
                "Mark a branch and study it: the map",
                "remembers what you forgot, and when.",
            ]),
    ]

    var body: some View {
        VStack(spacing: 24) {
            Text("Welcome to Arbor")
                .font(.system(size: 26, weight: .bold))
            Text("A quiet place to grow your ideas — then present them, and learn them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                ForEach(cards, id: \.title) { card in
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: card.symbol)
                            .font(.system(size: 30))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(card.title)
                            .font(.title3.weight(.semibold))
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(card.lines, id: \.self) { line in
                                Text(line)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(card.title). \(card.lines.joined(separator: " "))")
                }
            }

            HStack(spacing: 12) {
                Button("Open Sample Map", action: actions.openSampleMap)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("New Map", action: actions.newMap)
                    .controlSize(.large)
            }
            Text("The sample map is a tour — every branch tells you which key to press next.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
