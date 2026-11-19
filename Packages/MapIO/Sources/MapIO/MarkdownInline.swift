import Foundation
import MapCore

/// Renders and parses the §8.3 Markdown inline allow-list for node titles:
/// bold, italic, code, strikethrough and link. This is a small purpose-built
/// scanner, not a CommonMark implementation — the full Markdown importer
/// (M5, F-IO) switches to swift-markdown. Ranges are in UTF-16 units, the
/// unit `Run.range` and the platform text APIs use.
enum MarkdownInline {
    /// The active inline styles while scanning a title.
    private struct StyleState: Equatable {
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var link: String?
    }

    /// A run clamped to the title's UTF-16 bounds, ready for segmentation.
    private struct BoundedRun {
        var start: Int
        var end: Int
        var run: Run
    }

    /// A `[label](url)` match opening at a known index.
    private struct LinkMatch {
        var inner: Substring
        var url: String
        var indexAfter: Substring.Index
    }

    /// A `marker + inner + marker` match opening at a known index.
    private struct DelimitedMatch {
        var inner: Substring
        var indexAfter: Substring.Index
    }

    /// Renders a title as Markdown, preserving the allow-listed styles of
    /// overlapping runs. The link (outermost marker) wraps its whole span
    /// once; bold/italic/strike/code inside are split at run boundaries.
    static func render(_ title: NodeTitle) -> String {
        let text = flatTitle(title)
        guard !title.runs.isEmpty else { return text }
        let units = Array(text.utf16)
        let count = units.count
        let bounded = boundedRuns(title.runs, count: count)
        guard !bounded.isEmpty else { return text }

        if let linkRun = bounded.first(where: { !($0.run.link?.isEmpty ?? true) }), let url = linkRun.run.link {
            // A label the parser split into several runs (plain + struck,
            // say) is one link span: merge the contiguous runs that share
            // its URL, so the link wraps once.
            let start = linkRun.start
            var end = linkRun.end
            for entry in bounded where entry.run.link == url && entry.start <= end {
                end = max(end, entry.end)
            }
            return segmentText(bounded, units: units, in: 0..<start)
                + "[" + segmentText(bounded, units: units, in: start..<end, applyLink: false) + "]"
                + "(" + url + ")"
                + segmentText(bounded, units: units, in: end..<count)
        }
        return segmentText(bounded, units: units, in: 0..<count)
    }

    /// One-line title text: multi-line titles export as a single line in
    /// every line-based paste format.
    static func flatTitle(_ title: NodeTitle) -> String {
        title.text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func boundedRuns(_ runs: [Run], count: Int) -> [BoundedRun] {
        runs.compactMap { run in
            guard run.range.count >= 2 else { return nil }
            let start = min(max(run.range[0], 0), count)
            let end = min(max(run.range[0] + run.range[1], start), count)
            guard end > start else { return nil }
            return BoundedRun(start: start, end: end, run: run)
        }
    }

    private static func segmentText(
        _ bounded: [BoundedRun], units: [UInt16], in range: Range<Int>, applyLink: Bool = true
    ) -> String {
        var boundaries: Set<Int> = [range.lowerBound, range.upperBound]
        for entry in bounded {
            if range.contains(entry.start) { boundaries.insert(entry.start) }
            if range.contains(entry.end) { boundaries.insert(entry.end) }
        }
        let points = boundaries.sorted()
        var out = ""
        for (start, end) in zip(points, points.dropFirst()) {
            let segment = String(decoding: units[start..<end], as: UTF16.self)
            let active = bounded.filter { $0.start <= start && $0.end >= end }.map(\.run)
            if active.isEmpty {
                out += segment
            } else {
                out += wrap(segment, runs: active, applyLink: applyLink)
            }
        }
        return out
    }

    private static func wrap(_ segment: String, runs: [Run], applyLink: Bool = true) -> String {
        var wrapped = segment
        if runs.contains(where: { $0.code == true }) {
            let fence = wrapped.contains("`") ? "``" : "`"
            wrapped = fence + wrapped + fence
        }
        if runs.contains(where: { $0.strike == true }) {
            wrapped = "~~" + wrapped + "~~"
        }
        if runs.contains(where: { $0.italic == true }) {
            wrapped = "*" + wrapped + "*"
        }
        if runs.contains(where: { $0.bold == true }) {
            wrapped = "**" + wrapped + "**"
        }
        if applyLink, let url = runs.compactMap(\.link).first, !url.isEmpty {
            wrapped = "[" + wrapped + "](" + url + ")"
        }
        return wrapped
    }

    /// Parses inline Markdown into a `NodeTitle`: `**bold**`/`__bold__`,
    /// `*italic*`/`_italic_`, `` `code` ``, `~~strike~~` and `[label](url)`.
    /// Nesting works inside link labels; code spans are literal. Unmatched
    /// markers stay literal. Adjacent runs with equal attributes coalesce.
    static func parse(_ raw: String) -> NodeTitle {
        var text = ""
        var runs: [Run] = []
        append(raw[...], state: StyleState(), text: &text, runs: &runs)
        return NodeTitle(text: text, runs: runs)
    }

    private static func append(_ content: Substring, state: StyleState, text: inout String, runs: inout [Run]) {
        var index = content.startIndex
        while index < content.endIndex {
            let rest = content[index...]

            // Code spans first: their content is literal, nothing nests.
            if rest.hasPrefix("`"), let match = delimited(content, at: index, marker: "`") {
                appendPlain(match.inner, state: StyleState(code: true), text: &text, runs: &runs)
                index = match.indexAfter
                continue
            }
            // Bold before italic: "**" would otherwise open and close an italic.
            if let marker = boldMarker(rest), let match = delimited(content, at: index, marker: marker) {
                append(match.inner, state: with(state, bold: true), text: &text, runs: &runs)
                index = match.indexAfter
                continue
            }
            if let marker = italicMarker(rest), let match = delimited(content, at: index, marker: marker) {
                append(match.inner, state: with(state, italic: true), text: &text, runs: &runs)
                index = match.indexAfter
                continue
            }
            if rest.hasPrefix("~~"), let match = delimited(content, at: index, marker: "~~") {
                append(match.inner, state: with(state, strike: true), text: &text, runs: &runs)
                index = match.indexAfter
                continue
            }
            if state.link == nil, rest.hasPrefix("["), let match = linkLabel(content, at: index) {
                append(match.inner, state: with(state, link: match.url), text: &text, runs: &runs)
                index = match.indexAfter
                continue
            }

            // Literal character.
            appendPlain(
                rest[..<rest.index(after: rest.startIndex)], state: state, text: &text, runs: &runs)
            index = content.index(after: index)
        }
    }

    private static func with(
        _ state: StyleState,
        bold: Bool = false,
        italic: Bool = false,
        strike: Bool = false,
        code: Bool = false,
        link: String? = nil
    ) -> StyleState {
        StyleState(
            bold: state.bold || bold,
            italic: state.italic || italic,
            strike: state.strike || strike,
            code: state.code || code,
            link: link ?? state.link
        )
    }

    private static func appendPlain(_ chunk: Substring, state: StyleState, text: inout String, runs: inout [Run]) {
        guard !chunk.isEmpty else { return }
        let start = text.utf16.count
        text += chunk
        guard state.bold || state.italic || state.strike || state.code || state.link != nil else { return }
        if let last = runs.last, canCoalesce(last, with: state, at: start) {
            runs[runs.count - 1].range[1] += chunk.utf16.count
            return
        }
        runs.append(
            Run(
                range: [start, chunk.utf16.count],
                bold: state.bold ? true : nil,
                italic: state.italic ? true : nil,
                strike: state.strike ? true : nil,
                code: state.code ? true : nil,
                link: state.link
            )
        )
    }

    /// `true` when `last` is adjacent to `start` and carries exactly the
    /// attributes of `state`, so the plain chunk extends it instead of
    /// opening a new run.
    private static func canCoalesce(_ last: Run, with state: StyleState, at start: Int) -> Bool {
        last.range.count >= 2
            && last.range[0] + last.range[1] == start
            && (last.bold == true) == state.bold
            && (last.italic == true) == state.italic
            && (last.strike == true) == state.strike
            && (last.code == true) == state.code
            && last.link == state.link
    }

    /// Matches `marker` + inner + `marker` opening at `index`; the inner
    /// slice and the index just past the closing marker, or `nil` when the
    /// marker never closes (then it stays literal).
    private static func delimited(
        _ content: Substring, at index: Substring.Index, marker: String
    ) -> DelimitedMatch? {
        let openerEnd = content.index(index, offsetBy: marker.count)
        guard openerEnd < content.endIndex else { return nil }
        guard let close = content.range(of: marker, range: openerEnd..<content.endIndex) else { return nil }
        return DelimitedMatch(inner: content[openerEnd..<close.lowerBound], indexAfter: close.upperBound)
    }

    private static func boldMarker(_ rest: Substring) -> String? {
        if rest.hasPrefix("**") || rest.hasPrefix("__") { return String(rest.prefix(2)) }
        return nil
    }

    private static func italicMarker(_ rest: Substring) -> String? {
        if rest.hasPrefix("*") || rest.hasPrefix("_") { return String(rest.prefix(1)) }
        return nil
    }

    /// Matches `[label](url)` opening at `index`.
    private static func linkLabel(_ content: Substring, at index: Substring.Index) -> LinkMatch? {
        let labelStart = content.index(after: index)
        guard let labelEnd = find("]", in: content, from: labelStart) else { return nil }
        let urlStart = content.index(after: labelEnd)
        guard urlStart < content.endIndex, content[urlStart] == "(" else { return nil }
        let urlOpen = content.index(after: urlStart)
        guard let urlEnd = find(")", in: content, from: urlOpen) else { return nil }
        return LinkMatch(
            inner: content[labelStart..<labelEnd],
            url: String(content[urlOpen..<urlEnd]),
            indexAfter: content.index(after: urlEnd)
        )
    }

    private static func find(
        _ needle: Character, in content: Substring, from: Substring.Index
    ) -> Substring.Index? {
        var position = from
        while position < content.endIndex {
            if content[position] == needle { return position }
            position = content.index(after: position)
        }
        return nil
    }
}
