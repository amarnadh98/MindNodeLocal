import MapCore

/// The index's mirror of F-STD-1's basic-card rule (see
/// `MapStudy.CardExtractor`): a node is a card when its study policy is
/// explicitly `on`, or — under `auto` — when it has children or a
/// non-empty note. `off` suppresses. Kept local so `MapLibrary` needs
/// only `MapCore`; the study dashboard consumes the aggregated counts
/// through `LibraryDatabase.dueCounts(now:)`.
public enum LibraryCardPolicy {
    public static func isCard(_ node: Node) -> Bool {
        switch node.study?.card {
        case .off:
            return false
        case .on:
            return true
        case .auto, nil:
            let note = node.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !node.children.isEmpty || !note.isEmpty
        }
    }
}
