import Foundation
import MapCore

/// The library index (F-LIB-3): a disposable, fully rebuildable SQLite
/// store (ADR-0016: the system SQLite3 C library with FTS5 — no
/// third-party dependency). All access is serialized through this actor
/// and every result is `Sendable`, so the UI and the study dashboard
/// query it from anywhere without touching the main thread.
///
/// Schema (version 1):
/// - `maps` — one row per indexed `.arbor` package (title + normalized
///   title, modified, node count).
/// - `nodes` — one row per node: title, normalized title, card flag,
///   FSRS due date.
/// - `nodes_fts` — FTS5 over normalized title + note; text is
///   case/diacritic-folded at insert (ConceptText), so searching
///   "cafe" hits "Café" and CJK text matches directly.
/// - `links` — external node links, with `x-arbor://` targets parsed
///   into (targetDoc, targetNode) for backlinks.
/// - `tags` — document tag names (the model's `Tag` list).
public actor LibraryDatabase {
    let store: SQLite3Store

    /// Opens (creating if needed) the index at `url` and ensures the
    /// schema exists. The index is disposable: no migrations — delete
    /// the file and rebuild.
    public init(url: URL) throws {
        store = try SQLite3Store(url: url)
        try store.execute("PRAGMA journal_mode = WAL")
        try store.execute("PRAGMA synchronous = NORMAL")
        try store.execute(
            """
            CREATE TABLE IF NOT EXISTS maps(
                docID TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                title TEXT NOT NULL,
                normTitle TEXT NOT NULL,
                modified REAL NOT NULL,
                nodeCount INTEGER NOT NULL,
                indexedAt REAL NOT NULL
            )
            """)
        try store.execute("CREATE UNIQUE INDEX IF NOT EXISTS mapsByPath ON maps(path)")
        try store.execute(
            """
            CREATE TABLE IF NOT EXISTS nodes(
                docID TEXT NOT NULL,
                nodeID TEXT NOT NULL,
                title TEXT NOT NULL,
                normTitle TEXT NOT NULL,
                isCard INTEGER NOT NULL DEFAULT 0,
                due REAL,
                PRIMARY KEY(docID, nodeID)
            )
            """)
        try store.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
                docID UNINDEXED, nodeID UNINDEXED, title, note
            )
            """)
        try store.execute(
            """
            CREATE TABLE IF NOT EXISTS links(
                docID TEXT NOT NULL,
                nodeID TEXT NOT NULL,
                target TEXT NOT NULL,
                targetDoc TEXT,
                targetNode TEXT,
                PRIMARY KEY(docID, nodeID, target)
            )
            """)
        try store.execute(
            """
            CREATE TABLE IF NOT EXISTS tags(
                docID TEXT NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY(docID, name)
            )
            """)
    }

    // MARK: indexing

    /// Incrementally reindexes one package: removes every row the file
    /// previously owned (by docID, and by path when its docID changed)
    /// and inserts the current content. A package that no longer reads
    /// is dropped from the index instead of failing the operation.
    /// Paths are stored symlink-resolved so scanner output, document
    /// URLs and watched-folder prefixes all agree on identity.
    public func indexPackage(at rawURL: URL) throws {
        let url = rawURL.resolvingSymlinksInPath()
        guard let contents = try? ArborPackage.read(at: url) else {
            removePackage(at: url)
            return
        }
        try reindex(model: contents.model, meta: contents.meta, path: url)
    }

    /// The shared body of incremental indexing and full rebuild.
    func reindex(model: MapModel, meta: PackageMeta, path: URL) throws {
        let docID = meta.docID
        var previousOwners: Set<String> = [docID]
        let ownerStatement = try store.prepare("SELECT docID FROM maps WHERE path = ?")
        ownerStatement.bind(1, path.path)
        if try ownerStatement.step() {
            let previous = ownerStatement.textColumn(0)
            previousOwners.insert(previous)
        }

        try store.transaction {
            for owner in previousOwners {
                try removeRows(docID: owner)
            }
            let mapInsert = try store.prepare(
                """
                INSERT INTO maps(docID, path, title, normTitle, modified, nodeCount, indexedAt)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """)
            let title = Self.documentTitle(of: model, fallback: path)
            mapInsert.bind(1, docID)
            mapInsert.bind(2, path.path)
            mapInsert.bind(3, title)
            mapInsert.bind(4, ConceptText.normalize(title))
            mapInsert.bind(5, meta.modified.timeIntervalSince1970)
            mapInsert.bind(6, model.nodes.count)
            mapInsert.bind(7, Date().timeIntervalSince1970)
            _ = try mapInsert.step()

            let nodeInsert = try store.prepare(
                "INSERT INTO nodes(docID, nodeID, title, normTitle, isCard, due) VALUES(?, ?, ?, ?, ?, ?)")
            let ftsInsert = try store.prepare(
                "INSERT INTO nodes_fts(docID, nodeID, title, note) VALUES(?, ?, ?, ?)")
            let linkInsert = try store.prepare(
                "INSERT OR REPLACE INTO links(docID, nodeID, target, targetDoc, targetNode) VALUES(?, ?, ?, ?, ?)")
            let tagInsert = try store.prepare("INSERT OR IGNORE INTO tags(docID, name) VALUES(?, ?)")

            for (nodeID, node) in model.nodes {
                let normalizedTitle = ConceptText.normalize(node.title.text)
                nodeInsert.bind(1, docID)
                nodeInsert.bind(2, nodeID)
                nodeInsert.bind(3, node.title.text)
                nodeInsert.bind(4, normalizedTitle)
                nodeInsert.bind(5, LibraryCardPolicy.isCard(node) ? 1 : 0)
                nodeInsert.bind(6, node.study?.fsrs?.due.timeIntervalSince1970)
                _ = try nodeInsert.step()
                nodeInsert.reset()

                ftsInsert.bind(1, docID)
                ftsInsert.bind(2, nodeID)
                ftsInsert.bind(3, normalizedTitle)
                ftsInsert.bind(4, ConceptText.normalize(node.note ?? ""))
                _ = try ftsInsert.step()
                ftsInsert.reset()

                if let link = node.link {
                    let parsed = ArborLink.parse(link)
                    linkInsert.bind(1, docID)
                    linkInsert.bind(2, nodeID)
                    linkInsert.bind(3, link)
                    linkInsert.bind(4, parsed?.docID)
                    linkInsert.bind(5, parsed?.nodeID)
                    _ = try linkInsert.step()
                    linkInsert.reset()
                }
            }
            for tag in model.tags ?? [] {
                tagInsert.bind(1, docID)
                tagInsert.bind(2, tag.name)
                _ = try tagInsert.step()
                tagInsert.reset()
            }
        }
    }

    private func removeRows(docID: String) throws {
        let statements = [
            "DELETE FROM nodes WHERE docID = ?",
            "DELETE FROM nodes_fts WHERE docID = ?",
            "DELETE FROM links WHERE docID = ?",
            "DELETE FROM tags WHERE docID = ?",
            "DELETE FROM maps WHERE docID = ?",
        ]
        for sql in statements {
            let statement = try store.prepare(sql)
            statement.bind(1, docID)
            _ = try statement.step()
        }
    }

    /// Drops a package from the index (moved to Trash, renamed, unreadable).
    public func removePackage(at rawURL: URL) {
        let url = rawURL.resolvingSymlinksInPath()
        let path = url.path
        try? store.transaction {
            let ownerStatement = try store.prepare("SELECT docID FROM maps WHERE path = ?")
            ownerStatement.bind(1, path)
            var owners: [String] = []
            while try ownerStatement.step() {
                owners.append(ownerStatement.textColumn(0))
            }
            for owner in owners {
                try removeRows(docID: owner)
            }
        }
    }

    /// Wipes and rebuilds the whole index from the given folders
    /// ("Rebuild Index", F-LIB-3). Returns how many packages indexed.
    @discardableResult
    public func rebuild(folders: [URL]) throws -> Int {
        try store.transaction {
            try store.execute("DELETE FROM maps")
            try store.execute("DELETE FROM nodes")
            try store.execute("DELETE FROM nodes_fts")
            try store.execute("DELETE FROM links")
            try store.execute("DELETE FROM tags")
        }
        var indexed = 0
        for folder in folders {
            for package in PackageScanner.packages(in: folder) {
                guard let contents = try? ArborPackage.read(at: package) else { continue }
                try reindex(model: contents.model, meta: contents.meta, path: package)
                indexed += 1
            }
        }
        return indexed
    }

    /// True when a table (or virtual table) exists — schema inspection.
    public func tableExists(_ name: String) -> Bool {
        store.tableExists(name)
    }

    /// The document title: explicit model title, else the first root's
    /// first line, else the file name — mirroring F-EDT-14's derivation
    /// closely enough for listing.
    static func documentTitle(of model: MapModel, fallback path: URL) -> String {
        if let explicit = model.title?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let rootID = model.roots.first, let root = model.nodes[rootID],
            let firstLine = root.title.text.split(whereSeparator: \.isNewline).first,
            !firstLine.isEmpty
        {
            return String(firstLine)
        }
        return path.deletingPathExtension().lastPathComponent
    }
}
