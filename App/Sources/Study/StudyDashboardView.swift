import Charts
import SwiftUI

/// The study dashboard surface (F-STD-7): due today, a 30-day forecast
/// (Swift Charts), retention stats, the streak, a heatmap calendar and
/// the opt-in daily reminder. All values come precomputed in the
/// `DashboardSnapshot` — this view renders, it never computes.
struct StudyDashboardView: View {
    let snapshot: DashboardSnapshot

    @State private var reminderOn =
        UserDefaults.standard.object(forKey: StudyPreferences.dailyReminderKey) as? Bool ?? false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statRow
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
                Text("A local notification at 9:00 each morning. Nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
