import Foundation
import MapCore

/// One occurrence range in a node's text, in UTF-16 units — the
/// coordinates `Run` ranges (SPEC §8.3) and `NSAttributedString` use.
public struct MatchRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }
}

/// Which of a node's searchable texts matched (F-FOC-3: titles, notes,
/// and — behind a toggle — tags).
public enum FindField: String, Equatable, Sendable {
    case title
    case note
    case tag
}

/// What the user can search (F-FOC-3). Tags are opt-in so a tag
/// doesn't drown out title hits by default.
public struct FindOptions: Equatable, Sendable {
    /// Match tag names too (the find bar's toggle).
    public var includeTags: Bool = false

    public init(includeTags: Bool = false) {
        self.includeTags = includeTags
    }
}

/// One node × field pair that matched, with every occurrence inside
/// that field's text, in order.
public struct FindMatch: Equatable, Sendable {
    public let nodeID: String
    public let field: FindField
    /// The field's raw text (title text, note body, tag name).
    public let text: String
    /// Every occurrence of the query inside `text`, in UTF-16 units.
    public let ranges: [MatchRange]

    public init(nodeID: String, field: FindField, text: String, ranges: [MatchRange]) {
        self.nodeID = nodeID
        self.field = field
        self.text = text
        self.ranges = ranges
    }
}

/// Pure, headless find & replace over a `MapModel` (F-FOC-3).
/// Case-, diacritic- and width-insensitive; results in document order
/// (depth-first over `roots`, children in `children` order — the
/// outline's creation order); next/previous wrap around.
///
/// Replace-all is ONE grouped `MapCommand` (titles via `editText`,
/// notes via `setNote`) — one undo step through the `MapStore` — and
/// rewrites `NodeTitle` style runs correctly around the replaced
/// ranges: the replacement inherits the run active where the match
/// started, and the runs after it shift by the length delta.
public enum FindEngine {
    /// Every match in the model, in document order.
    public static func matches(query: String, options: FindOptions, in model: MapModel) -> [FindMatch] {
        var cache = FoldCache()
        let needle = FoldedNeedle(query, cache: &cache)
        guard !needle.isEmpty else { return [] }
        var haystack = FoldedHaystack()
        var tagNameCache: [String: String] = [:]
        var results: [FindMatch] = []

        for nodeID in documentOrder(in: model) {
            guard let node = model.nodes[nodeID] else { continue }
            haystack.load(node.title.text, cache: &cache)
            let titleRanges = haystack.ranges(of: needle)
            if !titleRanges.isEmpty {
                results.append(
                    FindMatch(nodeID: nodeID, field: .title, text: node.title.text, ranges: titleRanges))
            }
            if let note = node.note, !note.isEmpty {
                haystack.load(note, cache: &cache)
                let noteRanges = haystack.ranges(of: needle)
                if !noteRanges.isEmpty {
                    results.append(FindMatch(nodeID: nodeID, field: .note, text: note, ranges: noteRanges))
                }
            }
            if options.includeTags {
                for tagID in node.tags ?? [] {
                    guard let name = tagName(model: model, tagID: tagID, cache: &tagNameCache) else {
                        continue
                    }
                    haystack.load(name, cache: &cache)
                    if !haystack.ranges(of: needle).isEmpty {
                        results.append(FindMatch(nodeID: nodeID, field: .tag, text: name, ranges: []))
                        break
                    }
                }
            }
        }
        return results
    }

    /// The next (or previous) match index with wrap-around; nil when
    /// there is nothing to step through.
    public static func step(index: Int?, count: Int, forwards: Bool) -> Int? {
        guard count > 0 else { return nil }
        let base = index ?? (forwards ? -1 : 0)
        return forwards ? (base + 1) % count : (base - 1 + count) % count
    }

    /// ONE command that replaces every occurrence of `query` in every
    /// title and note (F-FOC-3: replace-all = one undo step), or nil
    /// when nothing matches. Tag matches are skipped — replace acts on
    /// titles and notes only.
    public static func replaceAllCommand(
        query: String,
        replacement: String,
        options: FindOptions,
        in model: MapModel
    ) -> MapCommand? {
        guard !query.isEmpty else { return nil }
        var cache = FoldCache()
        let needle = FoldedNeedle(query, cache: &cache)
        var commands: [MapCommand] = []
        var haystack = FoldedHaystack()

        for nodeID in documentOrder(in: model) {
            guard let node = model.nodes[nodeID] else { continue }
            haystack.load(node.title.text, cache: &cache)
            let titleRanges = haystack.ranges(of: needle)
            if !titleRanges.isEmpty {
                let replaced = replacedTitle(node.title, replacing: titleRanges, with: replacement)
                if replaced != node.title {
                    commands.append(.editText(id: nodeID, title: replaced))
                }
            }
            if let note = node.note, !note.isEmpty {
                haystack.load(note, cache: &cache)
                let noteRanges = haystack.ranges(of: needle)
                if !noteRanges.isEmpty {
                    let replaced = FindEngine.replacedNote(
                        note, replacing: noteRanges, with: replacement)
                    if replaced != note {
                        commands.append(.setNote(id: nodeID, note: replaced))
                    }
                }
            }
        }
        switch commands.count {
        case 0:
            return nil
        case 1:
            return commands[0]
        default:
            return .group(name: "Replace All", commands: commands)
        }
    }

    /// The title after replacing `ranges` (sorted, non-overlapping) with
    /// `replacement`, preserving the §8.3 style runs around each range:
    /// runs before the range are untouched, runs after it shift by the
    /// length delta, a run straddling the range keeps its prefix and
    /// suffix, and the inserted text inherits the run active where the
    /// replaced range started (like typing at the caret in the editor).
    public static func replacedTitle(
        _ title: NodeTitle, replacing ranges: [MatchRange], with replacement: String
    ) -> NodeTitle {
        guard !ranges.isEmpty else { return title }
        let source = title.text as NSString
        let sortedRanges = ranges.sorted { $0.location < $1.location }
        // Text: apply right-to-left so earlier ranges stay valid.
        var newText = title.text
        for range in sortedRanges.reversed() {
            let location = min(max(range.location, 0), source.length)
            let clamped = NSRange(location: location, length: min(max(range.length, 0), source.length - location))
            newText = (newText as NSString).replacingCharacters(in: clamped, with: replacement)
        }
        let newRuns = remapRuns(
            title.runs, replacing: sortedRanges, sourceLength: source.length,
            replacementLength: (replacement as NSString).length)
        return NodeTitle(text: newText, runs: coalesced(newRuns))
    }

    /// A copy of `model` with every folded ancestor of `id` unfolded —
    /// the VIEW-LEVEL temporary unfold of F-FOC-3: the scene built from
    /// this copy shows a match hidden behind a fold, while the real
    /// model (the document, the undo stack) is never touched.
    public static func modelUnfoldingAncestors(of id: String, in model: MapModel) -> MapModel {
        var copy = model
        var current = model.nodes[id]?.parent
        var guardSet = Set([id])
        while let ancestorID = current, guardSet.insert(ancestorID).inserted {
            if copy.nodes[ancestorID]?.folded == true {
                copy.nodes[ancestorID]?.folded = false
            }
            current = model.nodes[ancestorID]?.parent
        }
        return copy
    }

    /// Every folded ancestor of `id`, nearest first (used to build the
    /// temporary-unfold copy and to reason about reveal costs).
    public static func foldedAncestors(of id: String, in model: MapModel) -> [String] {
        var result: [String] = []
        var current = model.nodes[id]?.parent
        var guardSet = Set([id])
        while let ancestorID = current, guardSet.insert(ancestorID).inserted {
            if model.nodes[ancestorID]?.folded == true {
                result.append(ancestorID)
            }
            current = model.nodes[ancestorID]?.parent
        }
        return result
    }

    // MARK: internals

    /// Depth-first pre-order over the roots — the outline's creation
    /// order, which is the document's visual order for the find bar
    /// and the Quick Open list.
    public static func documentOrder(in model: MapModel) -> [String] {
        var order: [String] = []
        var stack: [String] = []
        for rootID in model.roots.reversed() {
            stack.append(rootID)
        }
        while let id = stack.popLast() {
            guard model.nodes[id] != nil else { continue }
            order.append(id)
            for childID in (model.nodes[id]?.children ?? []).reversed() {
                stack.append(childID)
            }
        }
        return order
    }

    private static func tagName(model: MapModel, tagID: String, cache: inout [String: String]) -> String? {
        if let cached = cache[tagID] {
            return cached.isEmpty ? nil : cached
        }
        let name = model.tags?.first { $0.id == tagID }?.name
        cache[tagID] = name ?? ""
        return name
    }

    /// Plain-text replace-all inside one note (notes have no runs),
    /// applied right-to-left over the folded match ranges so it is as
    /// case/diacritic-insensitive as the find itself.
    public static func replacedNote(
        _ note: String, replacing ranges: [MatchRange], with replacement: String
    ) -> String {
        let source = note as NSString
        var result = note
        for range in ranges.reversed() {
            let location = min(max(range.location, 0), source.length)
            let clamped = NSRange(location: location, length: min(max(range.length, 0), source.length - location))
            result = (result as NSString).replacingCharacters(in: clamped, with: replacement)
        }
        return result
    }

    /// A run's stored length (its `range` is `[start, length]`).
    private static func runLength(_ run: Run) -> Int {
        run.range.count > 1 ? run.range[1] : 0
    }

    /// Run adjustment around sorted, non-overlapping replaced ranges.
    private static func remapRuns(
        _ runs: [Run],
        replacing ranges: [MatchRange],
        sourceLength: Int,
        replacementLength: Int
    ) -> [Run] {
        guard !runs.isEmpty else { return [] }
        var result: [Run] = []
        var shift = 0
        var cursor = 0
        var runIndex = 0

        func emit(_ run: Run, from originalStart: Int, to originalEnd: Int) {
            guard originalEnd > originalStart, originalStart >= cursor else { return }
            var copy = run
            copy.range = [originalStart + shift, originalEnd - originalStart]
            result.append(copy)
        }

        func activeRun(at position: Int) -> Run? {
            runs.last { run in
                let start = run.range.first ?? 0
                return start <= position && position < start + runLength(run)
            }
        }

        for range in ranges {
            let rangeStart = min(max(range.location, 0), sourceLength)
            let rangeEnd = min(max(range.location + range.length, rangeStart), sourceLength)
            // Runs (or run prefixes) that end before the replaced range.
            while runIndex < runs.count {
                let run = runs[runIndex]
                let runStart = run.range.first ?? 0
                let runEnd = runStart + runLength(run)
                if runStart >= rangeStart { break }
                let pieceStart = max(runStart, cursor)
                let pieceEnd = min(runEnd, rangeStart)
                if pieceEnd > pieceStart {
                    emit(run, from: pieceStart, to: pieceEnd)
                }
                if runEnd <= rangeStart {
                    runIndex += 1
                    cursor = max(cursor, runEnd)
                } else {
                    cursor = max(cursor, rangeStart)
                    break
                }
            }
            cursor = max(cursor, rangeStart)
            // The replacement inherits the run active at the range start.
            if replacementLength > 0, rangeEnd > rangeStart, let active = activeRun(at: rangeStart) {
                var inherited = active
                inherited.range = [rangeStart + shift, replacementLength]
                result.append(inherited)
            }
            shift += replacementLength - (rangeEnd - rangeStart)
            cursor = rangeEnd
        }
        // Whatever follows the last replaced range.
        while runIndex < runs.count {
            let run = runs[runIndex]
            let runStart = run.range.first ?? 0
            let runEnd = runStart + runLength(run)
            let pieceStart = max(runStart, cursor)
            if runEnd > pieceStart {
                emit(run, from: pieceStart, to: runEnd)
            }
            runIndex += 1
            cursor = max(cursor, runEnd)
        }
        return result
    }

    /// Merges adjacent runs with identical attributes and drops the
    /// empty-length ones, so the stored runs stay canonical (the
    /// editor's extraction produces the same shape).
    private static func coalesced(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs where (run.range.count > 1 ? run.range[1] : 0) > 0 {
            if let last = result.last,
                last.range.first! + (last.range.count > 1 ? last.range[1] : 0) == run.range.first,
                sameAttributes(last, run)
            {
                result[result.count - 1].range[1] += run.range.count > 1 ? run.range[1] : 0
            } else {
                result.append(run)
            }
        }
        return result
    }

    private static func sameAttributes(_ lhs: Run, _ rhs: Run) -> Bool {
        lhs.bold == rhs.bold && lhs.italic == rhs.italic && lhs.underline == rhs.underline
            && lhs.strike == rhs.strike && lhs.code == rhs.code && lhs.color == rhs.color
            && lhs.highlight == rhs.highlight && lhs.link == rhs.link && lhs.font == rhs.font
            && lhs.size == rhs.size
    }
}
