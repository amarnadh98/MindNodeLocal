import Foundation

/// Marker tokens (F-CNT-3, SPEC §8.2's `markers` list): the three
/// kinds a token can be, parsed from the stored string.
///
/// - `sf:<name>` — an SF Symbol (rendered by the AppKit-side host,
///   tintable).
/// - `emoji:<char>` — an emoji, drawn as text.
/// - `sticker:<id>` — one of Arbor's original vector stickers
///   (authored in code, MapRender).
public enum MarkerKind: Sendable, Equatable {
    case sfSymbol(String)
    case emoji(String)
    case sticker(String)

    public static func parse(_ token: String) -> MarkerKind? {
        if token.hasPrefix("sf:"), token.count > 3 {
            return .sfSymbol(String(token.dropFirst(3)))
        }
        if token.hasPrefix("emoji:"), token.count > 6 {
            return .emoji(String(token.dropFirst(6)))
        }
        if token.hasPrefix("sticker:"), token.count > 8 {
            return .sticker(String(token.dropFirst(8)))
        }
        return nil
    }

    /// The stored token string (the round-trip of `parse`).
    public var token: String {
        switch self {
        case .sfSymbol(let name): "sf:\(name)"
        case .emoji(let char): "emoji:\(char)"
        case .sticker(let id): "sticker:\(id)"
        }
    }
}

/// The cycling families (F-CNT-3: "clicking a priority/progress
/// marker cycles it"). Pure; the click path builds one `setMarkers`
/// from the result.
public enum MarkerCycler {
    /// `sticker:priority-1` … `sticker:priority-5`.
    public static let priorities = (1...5).map { "sticker:priority-\($0)" }
    /// `sticker:progress-0` … `sticker:progress-8` — eighths of a
    /// ring, MindNode's quarter set extended one notch.
    public static let progress = (0...8).map { "sticker:progress-\($0)" }

    private static func next(in family: [String], current: String) -> String? {
        guard let slot = family.firstIndex(of: current) else { return nil }
        let next = slot + 1
        return next < family.count ? family[next] : nil
    }

    /// The marker list after clicking the `family` marker: the family
    /// member advances one step (the last step clears it, the
    /// MindNode convention). A family member not present inserts the
    /// first one; nil family markers leave the list untouched.
    public static func cycled(
        _ markers: [String]?, in family: [String]
    ) -> [String]? {
        guard !family.isEmpty else { return markers }
        var list = markers ?? []
        if let next = list.compactMap({ next(in: family, current: $0) }).first {
            // Replace every family member with the advanced one
            // (only one can be present by convention).
            list = list.filter { !family.contains($0) }
            list.append(next)
            return list
        }
        if list.contains(where: { family.contains($0) }) {
            // The member was the family's last step: clicking clears.
            return list.filter { !family.contains($0) }
        }
        list.append(family[0])
        return list
    }
}
