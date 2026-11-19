import Charts
import SwiftUI

/// The study dashboard surface (F-STD-7): due today, due per deck, a
/// 30-day forecast (Swift Charts), retention stats, the streak, a
/// heatmap calendar and the opt-in daily reminder with its time. All
/// values come precomputed in the `DashboardSnapshot` — this view
/// renders, it never computes.
struct StudyDashboardView: View {
    let snapshot: DashboardSnapshot

    @State private var reminderOn =
        UserDefaults.standard.object(forKey: StudyPreferences.dailyReminderKey) as? Bool ?? false
    @State private var reminderTime = StudyPreferences.reminderTime()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statRow
                decksSection
                forecastSection
                heatmapSection
                reminderSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Study Dashboard")
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            statTile("Due Today", "\(snapshot.dueToday)", highlight: snapshot.dueToday > 0)
            statTile(
                "Retention", snapshot.retention.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            statTile(
                "Today's Accuracy", snapshot.accuracyToday.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            statTile("Streak", "\(snapshot.streak)-day")
            statTile("Cards", "\(snapshot.totalCards)")
        }
    }

    private func statTile(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(highlight ? Color.accentColor : Color.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: F-STD-7 "cards due today per deck": every Study-marked
    // branch (F-STD-1) with its due and total card counts.
    @ViewBuilder
    private var decksSection: some View {
        if !snapshot.decks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Due by Deck")
                    .font(.headline)
                ForEach(snapshot.decks) { deck in
                    HStack {
                        Text(deck.name.isEmpty ? "Deck" : deck.name)
                            .lineLimit(1)
                        Spacer()
                        if deck.due > 0 {
                            Text("\(deck.due) of \(deck.total) due")
                                .font(.callout)
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text(deck.total == 0 ? "no cards" : "none due of \(deck.total)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("30-Day Forecast")
                .font(.headline)
            Chart {
                ForEach(Array(snapshot.forecast.enumerated()), id: \.offset) { day, count in
                    BarMark(
                        x: .value("Day", day),
                        y: .value("Cards", count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                }
            }
            .chartXAxis {
                AxisMarks(values: [0, 7, 14, 21, 29]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let day = value.as(Int.self) {
                            Text(day == 0 ? "Today" : "+\(day)d")
                        }
                    }
                }
            }
            .frame(height: 160)
        }
        .accessibilityLabel(
            "30 day forecast: \(snapshot.forecast.reduce(0, +)) reviews coming up, \(snapshot.dueToday) due today.")
    }

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review Activity")
                .font(.headline)
            HeatmapCalendar(counts: snapshot.heatmap)
                .accessibilityLabel("Review activity for the last \(snapshot.heatmap.count) days.")
        }
    }

    private var reminderSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily Reminder")
                    .font(.headline)
                Text(
                    "A local notification each morning. Nothing is sent anywhere."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            DatePicker(
                "",
                selection: Binding(
                    get: { reminderTime },
                    set: { date in
                        reminderTime = date
                        UserDefaults.standard.set(date, forKey: StudyPreferences.dailyReminderTimeKey)
                        // A time change while enabled reschedules the
                        // pending request at the new hour (F-STD-7).
                        if reminderOn {
                            Task { @MainActor in
                                reminderOn = await StudyReminder.setEnabled(true)
                            }
                        }
                    }),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .frame(width: 84)
            .disabled(!reminderOn)
            .accessibilityLabel("Reminder time")
            Toggle(
                "",
                isOn: Binding(
                    get: { reminderOn },
                    set: { enabled in
                        reminderOn = enabled
                        Task { @MainActor in
                            // A denied permission flips the toggle back off.
                            reminderOn = await StudyReminder.setEnabled(enabled)
                        }
                    })
            )
            .labelsHidden()
            .accessibilityLabel("Daily reminder")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The GitHub-style heatmap calendar: trailing `counts.count` days, the
/// last cell is today, color intensity by review count.
struct HeatmapCalendar: View {
    let counts: [Int]

    private func intensity(_ count: Int) -> Color {
        switch count {
        case 0: Color(nsColor: .quaternaryLabelColor)
        case 1: Color.green.opacity(0.35)
        case 2...4: Color.green.opacity(0.6)
        default: Color.green.opacity(0.85)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(0..<DashboardSnapshot.heatmapWeeks, id: \.self) { week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        let index = week * 7 + day
                        if index < counts.count {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(intensity(counts[index]))
                                .frame(width: 14, height: 14)
                        }
                    }
                }
            }
        }
    }
}
