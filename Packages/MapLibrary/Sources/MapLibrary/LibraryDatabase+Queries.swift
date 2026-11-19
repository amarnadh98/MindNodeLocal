import Foundation
import MapCore

/// The query surface of the library index (F-LIB-2/3/4, F-STD-7):
/// FTS search, backlinks, the Concept Index and Study-Due
/// aggregation — one extension of the `LibraryDatabase` actor, so
/// every access stays serialized through the same executor.
extension LibraryDatabase {
    // MARK: queries

    /// F-LIB-2 search: maps whose (normalized) title or file name
    /// contains the query, unioned with maps containing node hits
    /// (FTS over folded title+note). Newest first.
    public func search(_ query: String) throws -> [LibraryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try allEntries() }
        let like = "%" + Self.escapeLike(ConceptText.normalize(trimmed)) + "%"
        let match = Self.ftsMatchExpression(trimmed)
        let ftsArm =
            match.map { _ in
                """
                UNION
                SELECT m.docID, m.path, m.title, m.modified FROM maps m
                WHERE m.docID IN (SELECT docID FROM nodes_fts WHERE nodes_fts MATCH ?)
                """
            } ?? ""
        var entries: [LibraryEntry] = []
        let statement = try store.prepare(
            """
            SELECT docID, path, title, modified FROM maps
            WHERE normTitle LIKE ? ESCAPE '\\' OR path LIKE ? ESCAPE '\\'
            \(ftsArm)
            ORDER BY modified DESC
            """)
        statement.bind(1, like)
        statement.bind(2, like)
        statement.bind(3, match)
        while try statement.step() {
            entries.append(entryFrom(statement))
        }
        return entries
    }

    /// The FTS5 node matches themselves (Concept Index search and the
    /// library's hit details), ranked by bm25. The returned title is
    /// the node's raw title (joined from `nodes`); the note snippet is
    /// the normalized indexed note.
    public func searchNodes(_ query: String, limit: Int = 50) throws -> [NodeSearchHit] {
        guard let match = Self.ftsMatchExpression(query) else { return [] }
        var hits: [NodeSearchHit] = []
        let statement = try store.prepare(
            """
            SELECT f.docID, m.path, m.title, f.nodeID, IFNULL(n.title, f.title), f.note
            FROM nodes_fts f
            JOIN maps m ON m.docID = f.docID
            LEFT JOIN nodes n ON n.docID = f.docID AND n.nodeID = f.nodeID
            WHERE nodes_fts MATCH ?
            ORDER BY bm25(nodes_fts), m.modified DESC
            LIMIT ?
            """)
        statement.bind(1, match)
        statement.bind(2, limit)
        while try statement.step() {
            hits.append(
                NodeSearchHit(
                    docID: statement.textColumn(0), path: statement.textColumn(1),
                    documentTitle: statement.textColumn(2), nodeID: statement.textColumn(3),
                    title: statement.textColumn(4), note: statement.textColumn(5)))
        }
        return hits
    }

    /// Every external reference to `(docID, nodeID)` across the library
    /// (F-LIB-3 backlinks).
    public func backlinks(toDocID docID: String, nodeID: String) throws -> [Backlink] {
        let target = docID.lowercased()
        let targetNode = nodeID.lowercased()
        var links: [Backlink] = []
        let statement = try store.prepare(
            """
            SELECT l.docID, m.path, m.title, l.nodeID, IFNULL(n.title, ''),
                   l.targetDoc, l.targetNode
            FROM links l
            JOIN maps m ON m.docID = l.docID
            LEFT JOIN nodes n ON n.docID = l.docID AND n.nodeID = l.nodeID
            WHERE l.targetDoc = ? AND l.targetNode = ?
            ORDER BY m.modified DESC
            """)
        statement.bind(1, target)
        statement.bind(2, targetNode)
        while try statement.step() {
            links.append(
                Backlink(
                    sourceDocID: statement.textColumn(0), sourcePath: statement.textColumn(1),
                    sourceDocumentTitle: statement.textColumn(2), sourceNodeID: statement.textColumn(3),
                    sourceNodeTitle: statement.textColumn(4), targetDocID: target,
                    targetNodeID: targetNode))
        }
        return links
    }

    /// The Concept Index (F-LIB-4): node titles across maps grouped by
    /// normalized text. `query` filters on the normalized title (prefix
    /// contains); nil returns every group.
    public func conceptGroups(matching query: String?) throws -> [ConceptGroup] {
        let filter = query.map { ConceptText.normalize($0) }
        let statement = try store.prepare(
            """
            SELECT n.normTitle, n.docID, m.path, m.title, n.nodeID, n.title
            FROM nodes n JOIN maps m ON m.docID = n.docID
            WHERE n.normTitle != ''
            ORDER BY n.normTitle, m.modified DESC
            """)
        var grouped: [String: [ConceptOccurrence]] = [:]
        while try statement.step() {
            let normalized = statement.textColumn(0)
            if let filter, !filter.isEmpty, !normalized.contains(filter) { continue }
            grouped[normalized, default: []].append(
                ConceptOccurrence(
                    docID: statement.textColumn(1), path: statement.textColumn(2),
                    documentTitle: statement.textColumn(3), nodeID: statement.textColumn(4),
                    title: statement.textColumn(5)))
        }
        return
            grouped
            .map { ConceptGroup(normalizedTitle: $0.key, occurrences: $0.value) }
            .sorted { $0.normalizedTitle < $1.normalizedTitle }
    }

    /// F-STD-7's aggregation API: due-today and never-scheduled card
    /// counts per map; the study dashboard consumes this. "Due today"
    /// is an FSRS due date before the end of `now`'s local day.
    public func dueCounts(now: Date = Date()) throws -> [DueSummary] {
        let calendar = Calendar.current
        let startOfTomorrow =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let endOfDay = startOfTomorrow.timeIntervalSince1970
        var summaries: [DueSummary] = []
        let statement = try store.prepare(
            """
            SELECT m.docID, m.path, m.title,
                SUM(CASE WHEN n.due IS NOT NULL AND n.due <= ? AND n.isCard = 1 THEN 1 ELSE 0 END),
                SUM(CASE WHEN n.due IS NULL AND n.isCard = 1 THEN 1 ELSE 0 END)
            FROM maps m LEFT JOIN nodes n ON n.docID = m.docID
            GROUP BY m.docID
            ORDER BY m.title
            """)
        statement.bind(1, endOfDay)
        while try statement.step() {
            summaries.append(
                DueSummary(
                    docID: statement.textColumn(0), path: statement.textColumn(1),
                    title: statement.textColumn(2), dueToday: statement.intColumn(3),
                    newCards: statement.intColumn(4)))
        }
        return summaries
    }

    /// All indexed maps, newest first.
    public func allEntries() throws -> [LibraryEntry] {
        var entries: [LibraryEntry] = []
        let statement = try store.prepare(
            "SELECT docID, path, title, modified FROM maps ORDER BY modified DESC")
        while try statement.step() {
            entries.append(entryFrom(statement))
        }
        return entries
    }

    /// Maps whose package sits under `folder` (the watched-folder rows).
    public func entries(inFolder folder: URL) throws -> [LibraryEntry] {
        let prefix = Self.escapeLike(folder.path) + "/%"
        var entries: [LibraryEntry] = []
        let statement = try store.prepare(
            """
            SELECT docID, path, title, modified FROM maps
            WHERE path LIKE ? ESCAPE '\\' ORDER BY modified DESC
            """)
        statement.bind(1, prefix)
        while try statement.step() {
            entries.append(entryFrom(statement))
        }
        return entries
    }

    /// Model tag names across the library with their document counts.
    public func allTags() throws -> [(name: String, documents: Int)] {
        var tags: [(name: String, documents: Int)] = []
        let statement = try store.prepare(
            "SELECT name, count(DISTINCT docID) FROM tags GROUP BY name ORDER BY name")
        while try statement.step() {
            tags.append((statement.textColumn(0), statement.intColumn(1)))
        }
        return tags
    }

    /// The indexed entry for one path, when present.
    public func entry(at rawURL: URL) throws -> LibraryEntry? {
        let statement = try store.prepare(
            "SELECT docID, path, title, modified FROM maps WHERE path = ?")
        statement.bind(1, rawURL.resolvingSymlinksInPath().path)
        guard try statement.step() else { return nil }
        return entryFrom(statement)
    }

    // MARK: helpers

    private func entryFrom(_ statement: SQLite3Statement) -> LibraryEntry {
        LibraryEntry(
            docID: statement.textColumn(0), path: statement.textColumn(1),
            title: statement.textColumn(2),
            modified: Date(timeIntervalSince1970: statement.doubleColumn(3)))
    }

    /// Escapes `\`, `%` and `_` for a LIKE … ESCAPE '\' pattern.
    static func escapeLike(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "\\", "%", "_":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    /// Builds the FTS5 MATCH expression: each normalized token becomes
    /// a quoted prefix phrase, AND-combined; nil when the query has no
    /// usable tokens. Tokens are pre-folded to match the folded index.
    static func ftsMatchExpression(_ query: String) -> String? {
        let tokens = ConceptText.normalize(query)
            .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }
        return
            tokens
            .map { token in
                let clean = token.filter { $0 != "\"" }
                return "\"\(clean)\"*"
            }
            .joined(separator: " ")
    }
}
