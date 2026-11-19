import Foundation

/// One structured item the AI streams as a JSON line, e.g.
/// `{"text": "Mindful breathing", "parentIndex": 0}` (F-AI-2/F-AI-3).
public struct AIListItem: Sendable, Equatable, Codable {
    public var text: String
    public var parentIndex: Int?

    public init(text: String, parentIndex: Int? = nil) {
        self.text = text
        self.parentIndex = parentIndex
    }
}

private struct ListLine: Decodable {
    var text: String?
    var title: String?
    var parentIndex: Int?
}

/// Incremental JSON-lines parsing (F-AI-1's documented structured-list
/// wire format). Feed streamed text as it arrives; every complete line
/// returns one decoded item. Parsing is defensive on purpose (SPEC:
/// "parse defensively"):
///
/// - malformed JSON lines are dropped, the rest keeps flowing;
/// - a fenced block (```) or a stray preamble line is skipped;
/// - a plain-text line that is not JSON at all still yields an item —
///   leading list markers (`-`, `*`, `1.`) and surrounding quotes are
///   stripped — so a model that ignores the format degrades gracefully;
/// - text is trimmed and empty items dropped.
public struct JSONLinesStreamParser: Sendable {
    private var buffer = ""
    private var insideCodeFence = false

    public init() {}

    /// Feeds a text delta; returns every item whose line just closed.
    public mutating func feed(_ delta: String) -> [AIListItem] {
        buffer += delta
        var items: [AIListItem] = []
        while let newline = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if let item = Self.parse(line: line, insideFence: &insideCodeFence) {
                items.append(item)
            }
        }
        return items
    }

    /// Flushes the final (unterminated) line at end of stream.
    public mutating func finish() -> [AIListItem] {
        defer { buffer = "" }
        var fence = insideCodeFence
        guard !buffer.isEmpty else { return [] }
        return Self.parse(line: buffer, insideFence: &fence).map { [$0] } ?? []
    }

    /// Parses one complete line. `insideFence` toggles on ``` so a
    /// model that wraps its output in a JSON block degrades to plain
    /// JSON lines.
    static func parse(line rawLine: String, insideFence: inout Bool) -> AIListItem? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            return nil
        }
        if line.hasPrefix("```") {
            insideFence.toggle()
            return nil
        }
        if insideFence && !line.hasPrefix("{") {
            return nil
        }
        if let data = line.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(ListLine.self, from: data),
            let text = decoded.text ?? decoded.title,
            !text.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return AIListItem(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), parentIndex: decoded.parentIndex)
        }
        // Not valid JSON: treat the line as plain text, stripped of
        // common list markers and quotes.
        return plainTextItem(from: line)
    }

    private static func plainTextItem(from line: String) -> AIListItem? {
        var text = line
        for marker in ["-", "*", "•", "·"] where text.hasPrefix(marker) {
            if text.dropFirst(marker.count).hasPrefix(" ") {
                text = String(text.dropFirst(marker.count + 1))
                break
            }
        }
        if let digit = text.first?.isNumber, digit,
            let period = text.firstIndex(of: "."),
            text[..<period].allSatisfy(\.isNumber)
        {
            text = String(text[text.index(after: period)...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("{") else { return nil }
        return AIListItem(text: text)
    }
}

/// Parses a whole (non-streaming) JSON-lines block into items — the
/// level-by-level generator uses this on each completed request.
public enum JSONLinesParser {
    public static func parse(_ block: String) -> [AIListItem] {
        var stream = JSONLinesStreamParser()
        var items = stream.feed(block)
        items += stream.finish()
        return items
    }
}
