import AppIntents
import Foundation

/// A few App Shortcuts phrases (F-INT-1). Siri/Shortcuts requires the
/// app name inside every phrase, hence `\(AppShortcutPhraseToken.applicationName)`.
struct ArborShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateMapIntent(),
            phrases: [
                "Make a map with \(AppShortcutPhraseToken.applicationName)",
                "Create a mind map in \(AppShortcutPhraseToken.applicationName)",
            ],
            shortTitle: "Create Map",
            systemImageName: "point.3.filled.connected.trianglepath.dotted"
        )
        AppShortcut(
            intent: GetDueCardsCountIntent(),
            phrases: [
                "How many cards are due in \(AppShortcutPhraseToken.applicationName)",
                "Ask \(AppShortcutPhraseToken.applicationName) for due cards",
            ],
            shortTitle: "Due Cards",
            systemImageName: "rectangle.stack.badge.clock"
        )
        AppShortcut(
            intent: StartStudySessionIntent(),
            phrases: [
                "Start studying with \(AppShortcutPhraseToken.applicationName)",
                "Study in \(AppShortcutPhraseToken.applicationName)",
            ],
            shortTitle: "Study",
            systemImageName: "book.fill"
        )
        AppShortcut(
            intent: FindNodesIntent(),
            phrases: ["Find nodes in \(AppShortcutPhraseToken.applicationName)"],
            shortTitle: "Find Nodes",
            systemImageName: "magnifyingglass"
        )
    }
}
