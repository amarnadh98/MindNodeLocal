import AppKit
import MapCore
import MapRender
import MapStudy
import SwiftUI
import UserNotifications

/// One document's study dashboard data (F-STD-7): computed eagerly on
/// open so the SwiftUI view stays a dumb render.
///
/// Library seam (per the task): every field here is per document for
/// now. When the Library's "Study Due" lands, its dashboard will feed
/// SEVERAL documents' `(cards, states, reviewLog)` triples through the
/// same `StudyStats` functions — that aggregation is a data-collection
/// change, not a math change.
@MainActor
struct DashboardSnapshot {
    let documentName: String
    let dueToday: Int
    let forecast: [Int]
    let retention: Double?
    let accuracyToday: Double?
    let streak: Int
    let heatmap: [Int]
    let totalCards: Int

    static let forecastDays = 30
    static let heatmapWeeks = 12

    static func snapshot(of document: MapDocument) -> DashboardSnapshot {
        let model = document.model
        let now = Date()
        let cards = CardExtractor.extract(from: model)
        let states = StudyStates.states(for: cards, in: model)
        return DashboardSnapshot(
            documentName: document.displayName ?? "Untitled",
            dueToday: StudyStats.dueCount(cards: cards, states: states, now: now),
            forecast: StudyStats.forecast(
                cards: cards, states: states, now: now, days: forecastDays),
            retention: StudyStats.retention(
                cards: cards, states: states, now: now,
                desiredRetention: model.studySettings?.retention ?? 0.9),
            accuracyToday: StudyStats.accuracyToday(reviews: document.reviewLog, now: now),
            streak: StudyStats.streak(reviews: document.reviewLog, now: now),
            heatmap: StudyStats.dailyReviewCounts(
                reviews: document.reviewLog, now: now, days: heatmapWeeks * 7),
            totalCards: cards.count)
    }
}

/// The dashboard window: hosted SwiftUI (the study UI is one of
/// AppKit's hosted-SwiftUI surfaces per SPEC §11.1).
@MainActor
final class StudyDashboardController: NSWindowController {
    static let shared = StudyDashboardController()

    private var hosting: NSHostingView<StudyDashboardView>?

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(for document: MapDocument, variant: ThemeVariant) {
        let snapshot = DashboardSnapshot.snapshot(of: document)
        if let window {
            hosting?.rootView = StudyDashboardView(snapshot: snapshot)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = StudyDashboardView(snapshot: snapshot)
        let hosting = NSHostingView(rootView: view)
        self.hosting = hosting
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Study Dashboard — \(snapshot.documentName)"
        window.contentView = hosting
        self.window = window
        windowCenterOnScreen()
        showWindow(nil)
    }

    private func windowCenterOnScreen() {
        window?.center()
    }
}

/// The opt-in daily reminder (F-STD-7): a local UserNotifications
/// trigger, authorized ONLY when the user flips the toggle — the
/// permission prompt is a consequence of the opt-in, never a launch
/// side effect (SPEC §12: no un-asked-for anything).
enum StudyReminder {
    static let identifier = "arbor.study.daily-reminder"
    static let hour = 9

    /// Enables or disables the reminder; returns whether it ended up
    /// enabled (a denied permission reads as off).
    @MainActor
    static func setEnabled(_ enabled: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        if !enabled {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            UserDefaults.standard.set(false, forKey: StudyPreferences.dailyReminderKey)
            return false
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            UserDefaults.standard.set(false, forKey: StudyPreferences.dailyReminderKey)
            return false
        }
        UserDefaults.standard.set(true, forKey: StudyPreferences.dailyReminderKey)

        let content = UNMutableNotificationContent()
        content.title = "Arbor"
        content.body = "Time for today's study session."
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
        return true
    }
}
