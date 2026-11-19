import Foundation

/// The "Good · 4d" next-interval label (F-STD-4): the delay until a
/// card comes back, as the scheduler computed it, in the short form the
/// grade buttons show. Pure formatting, so the labels are testable
/// without a scheduler.
public enum IntervalLabel {
    /// The label for a delay of `seconds`:
    /// - under a minute: "<1m" (a learning step can round to 0),
    /// - under a day: whole minutes ("10m"),
    /// - under 31 days: whole days ("4d"),
    /// - under a year: whole months ("2mo"),
    /// - beyond: whole years ("3y").
    public static func text(forSeconds seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        if minutes < 1 { return "<1m" }
        if minutes < 60 * 24 { return "\(Int(minutes.rounded()))m" }
        let days = minutes / (60 * 24)
        if days < 31 { return "\(Int(days.rounded()))d" }
        if days < 365 { return "\(Int((days / 30.4375).rounded()))mo" }
        return "\(Int((days / 365.25).rounded()))y"
    }

    /// The label for the delay between `due` and `from` (negative
    /// delays — an overdue learning step — read as "<1m").
    public static func text(from due: Date, now: Date) -> String {
        text(forSeconds: due.timeIntervalSince(now))
    }
}
