import Foundation
import MapCore
import MapStudy

/// F-TAG-3's filter (SPEC §5.7): one combined predicate over tags,
/// task state, content flags, node type, mastery level, due date and
/// free text. A term is one token of the saved-filter query string
/// (`SavedFilter.query`, SPEC §8.2); terms AND together.
///
/// Grammar (whitespace-separated, order-free, canonical serialization
/// in `query`):
///
/// - bare words — substring match on the title and note,
///   case- and diacritic-insensitive (several words AND)
/// - `tag:<id>` — carries any of the ids (`|` inside one token: OR)
/// - `is:task` / `is:open` / `is:done` / `is:notask`
/// - `has:note` / `no:note`, `has:image` / `no:image`,
///   `has:attachment` / `no:attachment`
/// - `type:<name>` — the node's lightweight type field
/// - `mastery:strong|good|fading|forgotten|fresh` — the node's own
///   bucket, or the subtree aggregate for a branch (F-STD-6 vocabulary)
/// - `due:overdue|today|week|any` — the task's due date
public struct NodeFilter: Sendable, Equatable {
    public enum TaskState: String, Sendable, Equatable, CaseIterable {
        case task
        case open
        case done
        case notask
    }

    public enum Due: String, Sendable, Equatable, CaseIterable {
        case any
        case overdue
        case today
        case week
    }

    public var tagIDs: Set<String>
    public var taskState: TaskState?
    public var hasNote: Bool?
    public var hasImage: Bool?
    public var hasAttachment: Bool?
    public var nodeType: String?
    public var mastery: MasteryBucket?
    public var due: Due?
    public var text: String?

    public init(
        tagIDs: Set<String> = [],
        taskState: TaskState? = nil,
        hasNote: Bool? = nil,
        hasImage: Bool? = nil,
        hasAttachment: Bool? = nil,
        nodeType: String? = nil,
        mastery: MasteryBucket? = nil,
        due: Due? = nil,
        text: String? = nil
    ) {
        self.tagIDs = tagIDs
        self.taskState = taskState
        self.hasNote = hasNote
        self.hasImage = hasImage
        self.hasAttachment = hasAttachment
        self.nodeType = nodeType
        self.mastery = mastery
        self.due = due
        self.text = text
    }

    public var isEmpty: Bool {
        tagIDs.isEmpty && taskState == nil && hasNote == nil && hasImage == nil
            && hasAttachment == nil && nodeType == nil && mastery == nil && due == nil
            && (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The saved-filter query string (SPEC §8.2 `filters[].query`),
    /// canonical: flags first, then single-value terms, then the text.
    public var query: String {
        var tokens: [String] = []
        if !tagIDs.isEmpty {
            tokens.append("tag:" + tagIDs.sorted().joined(separator: "|"))
        }
        if let taskState {
            tokens.append("is:\(taskState.rawValue)")
        }
        if let hasNote {
            tokens.append(hasNote ? "has:note" : "no:note")
        }
        if let hasImage {
            tokens.append(hasImage ? "has:image" : "no:image")
        }
        if let hasAttachment {
            tokens.append(hasAttachment ? "has:attachment" : "no:attachment")
        }
        if let nodeType, !nodeType.isEmpty {
            tokens.append("type:\(nodeType)")
        }
        if let mastery {
            tokens.append("mastery:\(mastery.rawValue)")
        }
        if let due {
            tokens.append("due:\(due.rawValue)")
        }
        if let words = text?.trimmingCharacters(in: .whitespaces), !words.isEmpty {
            tokens.append("text:\(words)")
        }
        return tokens.joined(separator: " ")
    }

    /// Parses a saved query; unknown tokens read as text terms (a
    /// saved filter never fails to load).
    public init(query: String) {
        self.init()
        var words: [String] = []
        for token in query.split(separator: " ") {
            let raw = String(token)
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                words.append(raw)
                continue
            }
            let (key, value) = (String(parts[0]).lowercased(), String(parts[1]))
            switch key {
            case "tag":
                tagIDs = Set(value.split(separator: "|").map(String.init))
            case "is":
                taskState = TaskState(rawValue: value.lowercased())
            case "has", "no":
                let on = key == "has"
                switch value.lowercased() {
                case "note": hasNote = on
                case "image": hasImage = on
                case "attachment": hasAttachment = on
                default: words.append(raw)
                }
            case "type":
                nodeType = value.lowercased()
            case "mastery":
                mastery = MasteryBucket(rawValue: value.lowercased())
            case "due":
                due = Due(rawValue: value.lowercased())
            case "text":
                words.append(value)
            default:
                words.append(raw)
            }
        }
        if !words.isEmpty {
            text = words.joined(separator: " ")
        }
    }

    /// Round-trip through the query string is identity.
    public var normalized: NodeFilter {
        NodeFilter(query: query)
    }
}

/// Evaluates a `NodeFilter` over a model (F-TAG-3). Pure — the bar's
/// dim and hide modes are view state, so the engine owns no state of
/// its own.
public enum FilterEngine {
    /// True when `node` satisfies `filter`.
    ///
    /// `mastery` is the document's `MasteryReport` at the host's pinned
    /// `now` (F-STD-6 vocabulary); a branch node matches a mastery term
    /// through its subtree aggregate. Pass nil to make every mastery
    /// term match nothing.
    public static func matches(
        _ filter: NodeFilter, nodeID: String, node: Node, mastery: MasteryReport?, now: Date
    ) -> Bool {
        guard tagMatches(filter, node), taskMatches(filter, node),
            contentMatches(filter, node), typeMatches(filter, node),
            masteryMatches(filter, nodeID: nodeID, node: node, mastery: mastery),
            dueMatches(filter, node, now: now), textMatches(filter, node)
        else {
            return false
        }
        return true
    }

    /// `tag:` — any-of the carried ids (F-TAG-1 vocabulary).
    static func tagMatches(_ filter: NodeFilter, _ node: Node) -> Bool {
        guard !filter.tagIDs.isEmpty else { return true }
        return !(Set(node.tags ?? []).isDisjoint(with: filter.tagIDs))
    }

    /// `is:` — the task states (F-TSK).
    static func taskMatches(_ filter: NodeFilter, _ node: Node) -> Bool {
        switch filter.taskState {
        case nil:
            return true
        case .task:
            return node.task != nil
        case .open:
            return node.task != nil && node.task?.done != true
        case .done:
            return node.task?.done == true
        case .notask:
            return node.task == nil
        }
    }

    /// `has:`/`no:` — the content flags (F-CNT-1/2/7).
    static func contentMatches(_ filter: NodeFilter, _ node: Node) -> Bool {
        if let wanted = filter.hasNote {
            let hasNonEmptyNote =
                node.note?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if hasNonEmptyNote != wanted {
                return false
            }
        }
        if let wanted = filter.hasImage, (node.image != nil) != wanted {
            return false
        }
        if let wanted = filter.hasAttachment,
            ((node.attachments?.isEmpty ?? true) == false) != wanted
        {
            return false
        }
        return true
    }

    /// `type:` — the node's lightweight type field.
    static func typeMatches(_ filter: NodeFilter, _ node: Node) -> Bool {
        guard let wanted = filter.nodeType?.lowercased() else { return true }
        return (node.type ?? "").lowercased() == wanted
    }

    /// `mastery:` — the node's own bucket, or the subtree aggregate for
    /// a branch (F-STD-6).
    static func masteryMatches(
        _ filter: NodeFilter, nodeID: String, node: Node, mastery: MasteryReport?
    ) -> Bool {
        guard let bucket = filter.mastery else { return true }
        let own = mastery?.nodes[nodeID]?.bucket
        let aggregate = mastery?.aggregates[nodeID]
        let nodeBucket = own ?? (aggregate != nil ? MasteryBucket.bucket(retrievability: aggregate) : nil)
        return nodeBucket == bucket
    }

    /// `due:` — the task's due day against `now`.
    static func dueMatches(_ filter: NodeFilter, _ node: Node, now: Date) -> Bool {
        guard let due = filter.due else { return true }
        guard let raw = node.task?.due else { return false }
        let day = dueDay(raw, now: now)
        switch due {
        case .any:
            return true
        case .overdue:
            return day < 0
        case .today:
            return day == 0
        case .week:
            return day >= 0 && day <= 7
        }
    }

    /// The free text — every word a substring of the folded title+note.
    static func textMatches(_ filter: NodeFilter, _ node: Node) -> Bool {
        guard let words = filter.text?.trimmingCharacters(in: .whitespaces), !words.isEmpty
        else {
            return true
        }
        let haystack = folded(node.title.text + "\n" + (node.note ?? ""))
        return words.split(separator: " ").allSatisfy { haystack.contains(folded(String($0))) }
    }

    /// The matching node ids of the whole model.
    public static func matchingIDs(
        model: MapModel, filter: NodeFilter, mastery: MasteryReport?, now: Date
    ) -> Set<String> {
        guard !filter.isEmpty else { return Set(model.nodes.keys) }
        var result: Set<String> = []
        for (id, node) in model.nodes
        where matches(filter, nodeID: id, node: node, mastery: mastery, now: now) {
            result.insert(id)
        }
        return result
    }

    /// F-TAG-3 hide mode: everything that is NOT a match, minus the
    /// ancestors of matches (they stay visible so the tree reads). The
    /// host prunes these ids from the scene build.
    public static func hiddenIDs(
        model: MapModel, filter: NodeFilter, mastery: MasteryReport?, now: Date
    ) -> Set<String> {
        let matched = matchingIDs(model: model, filter: filter, mastery: mastery, now: now)
        guard !matched.isEmpty else {
            // Nothing matches: hiding everything is the honest result,
            // but the roots stay so the canvas is not a void.
            return Set(model.nodes.keys).subtracting(model.roots)
        }
        var visible = matched
        for match in matched {
            var current = model.nodes[match]?.parent
            while let id = current {
                if !visible.insert(id).inserted { break }
                current = model.nodes[id]?.parent
            }
        }
        return Set(model.nodes.keys).subtracting(visible)
    }

    /// Days from `now`'s calendar day to a `YYYY-MM-DD` due string
    /// (negative = overdue). An unparsable due date reads as "no due
    /// date" (`Int.max` sentinel — never matches a window).
    static func dueDay(_ raw: String, now: Date) -> Int {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return Int.max }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        guard let due = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return Int.max }
        let startOfNow = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: startOfNow, to: due).day ?? Int.max
    }

    /// Case- and diacritic-folded comparison key.
    static func folded(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale.current)
    }
}
