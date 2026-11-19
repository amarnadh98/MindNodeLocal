import Foundation
import MapCore
import Testing

@testable import MapLibrary

/// Shared fixture helpers: build small models and write real `.arbor`
/// packages into a temp folder. Fixtures live under the home directory
/// (not `temporaryDirectory`), because `/var` → `/private/var` is a
/// firmlink that bookmark resolution and directory enumeration
/// canonicalize differently, and path identity matters to the index.
struct FixtureFactory {
    let folder: URL

    init() throws {
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arbor-test-tmp/maplibrary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A model with a root titled `title` and one child per `childTitles`.
    static func model(
        title: String,
        docID: String = UUID().uuidString,
        children: [(String, String?)] = []
    ) -> MapModel {
        var model = MapModel(docID: docID)
        let rootID = UUID().uuidString
        model.nodes[rootID] = Node(id: rootID, title: NodeTitle(text: title))
        model.roots = [rootID]
        for (childTitle, note) in children {
            let childID = UUID().uuidString
            var child = Node(id: childID, parent: rootID, title: NodeTitle(text: childTitle))
            child.note = note
            model.nodes[childID] = child
            model.nodes[rootID]?.children.append(childID)
        }
        return model
    }

    /// Writes `model` as a real package in `folder`.
    func write(
        _ model: MapModel,
        name: String,
        modified: Date = Date(timeIntervalSinceReferenceDate: 100)
    ) throws -> URL {
        let url = folder.appendingPathComponent("\(name).arbor")
        let meta = PackageMeta(modified: modified, docID: model.docID)
        try ArborPackage.write(model, meta: meta, to: url)
        return url
    }

    /// A fresh database in a temp location.
    static func database() throws -> LibraryDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-\(UUID().uuidString).sqlite")
        return try LibraryDatabase(url: url)
    }
}

@Suite struct SQLiteIndexTests {
    @Test func schemaCreationCreatesEveryTable() async throws {
        let database = try FixtureFactory.database()
        #expect(await database.tableExists("maps"))
        #expect(await database.tableExists("nodes"))
        #expect(await database.tableExists("nodes_fts"))
        #expect(await database.tableExists("links"))
        #expect(await database.tableExists("tags"))
    }
    @Test func indexPackageListsEntryWithTitleAndModifiedDate() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()
        let model = FixtureFactory.model(title: "Roadmap", children: [("Now", nil), ("Later", nil)])
        let url = try fixture.write(model, name: "Roadmap")

        try await database.indexPackage(at: url)

        let entries = try await database.allEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.title == "Roadmap")
        #expect(entries.first?.path == url.path)
        #expect(entries.first?.docID == model.docID)
        #expect(entries.first?.modified == Date(timeIntervalSinceReferenceDate: 100))
        #expect(try await database.entry(at: url)?.docID == model.docID)
    }

    @Test func fullTextSearchHitsUnicodeAndDiacritics() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()
        _ = try fixture.write(
            FixtureFactory.model(title: "Biology", children: [("Café Culture", "strong espresso")]),
            name: "Biology")
        _ = try fixture.write(
            FixtureFactory.model(title: "日本語ノート", children: [("プロジェクト計画", "詳細は後で")]),
            name: "Japanese")

        try await database.indexPackage(at: fixture.folder.appendingPathComponent("Biology.arbor"))
        try await database.indexPackage(at: fixture.folder.appendingPathComponent("Japanese.arbor"))

        // Diacritic fold: "cafe" finds "Café".
        let hitsForCafe = try await database.searchNodes("cafe")
        #expect(hitsForCafe.map(\.title).contains("Café Culture"))
        // Case + width fold: "CAFE" and "ｃａｆｅ" both find it too.
        let hitsForUpper = try await database.searchNodes("CAFE")
        let hitsForWidth = try await database.searchNodes("ｃａｆｅ")
        #expect(!hitsForUpper.isEmpty)
        #expect(!hitsForWidth.isEmpty)
        // CJK full text. unicode61 has no word segmentation, so CJK
        // text is one token per run — prefix search finds it.
        let hitsForPlan = try await database.searchNodes("プロジェクト")
        #expect(hitsForPlan.map(\.title).contains("プロジェクト計画"))
        // Multi-token AND search over title and note.
        let hitsForBoth = try await database.searchNodes("espresso strong")
        #expect(hitsForBoth.count == 1 && hitsForBoth.first?.title == "Café Culture")
        // No hit is a clean empty result, not an error.
        #expect(try await database.searchNodes("nonexistent").isEmpty)
        // The map-level search finds the map that contains the node hit.
        let maps = try await database.search("プロジェクト")
        #expect(maps.map(\.title).contains("日本語ノート"))
    }

    @Test func backlinksResolveXArborTargets() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()

        var targetModel = FixtureFactory.model(title: "Glossary", children: [("Momentum", nil)])
        let targetNodeID = targetModel.roots.first!
        let targetURL = try fixture.write(targetModel, name: "Glossary")

        var sourceModel = FixtureFactory.model(
            title: "Physics",
            children: [("Topic A", nil), ("Topic B", nil)])
        let sourceNodeID = sourceModel.roots.first!
        sourceModel.nodes[sourceNodeID]?.link = MapLibrary.ArborLink.url(
            docID: targetModel.docID, nodeID: targetNodeID)
        _ = try fixture.write(sourceModel, name: "Physics")

        // A web link in another document must NOT resolve as an arbor
        // backlink.
        var webLinkModel = FixtureFactory.model(title: "Web", children: [("Site", nil)])
        webLinkModel.nodes[webLinkModel.roots[0]]?.link = "https://example.com"
        _ = try fixture.write(webLinkModel, name: "WebLinks")

        try await database.indexPackage(at: targetURL)
        try await database.indexPackage(at: fixture.folder.appendingPathComponent("Physics.arbor"))
        try await database.indexPackage(at: fixture.folder.appendingPathComponent("WebLinks.arbor"))

        let links = try await database.backlinks(
            toDocID: targetModel.docID, nodeID: targetNodeID)
        #expect(links.count == 1)
        #expect(links.first?.sourceNodeID == sourceNodeID)
        #expect(links.first?.sourceDocumentTitle == "Physics")
        #expect(links.first?.sourceNodeTitle == "Physics")

        // Parse round trip: format is case-insensitive. (Qualified:
        // MapCore gained its own validated-link `ArborLink` in M3, and
        // this target imports both modules.)
        let parsed = MapLibrary.ArborLink.parse(
            MapLibrary.ArborLink.url(docID: "ABC-123", nodeID: "DEF-456").uppercased()
                .replacingOccurrences(of: "X-ARBOR", with: "x-arbor"))
        #expect(parsed?.docID == "abc-123" && parsed?.nodeID == "def-456")
        #expect(MapLibrary.ArborLink.parse("https://example.com") == nil)
        #expect(MapLibrary.ArborLink.parse("x-arbor://onlydoc") == nil)
    }

    @Test func conceptGroupsNormalizeAcrossMaps() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()
        _ = try fixture.write(
            FixtureFactory.model(title: "One", children: [("Momentum", nil)]), name: "One")
        _ = try fixture.write(
            FixtureFactory.model(title: "Two", children: [("  MOMENTUM ", nil)]), name: "Two")
        _ = try fixture.write(
            FixtureFactory.model(title: "Three", children: [("Momentum elsewhere", nil)]),
            name: "Three")

        for name in ["One", "Two", "Three"] {
            try await database.indexPackage(at: fixture.folder.appendingPathComponent("\(name).arbor"))
        }

        let groups = try await database.conceptGroups(matching: "momentum")
        // Substring match: "Momentum elsewhere" is its own group.
        #expect(groups.count == 2)
        let exact = try await database.conceptGroups(matching: nil)
            .first { $0.normalizedTitle == "momentum" }
        #expect(exact?.occurrences.count == 2)
        #expect(exact?.documentCount == 2)

        let singletons = try await database.conceptGroups(matching: nil)
            .filter { $0.occurrences.count == 1 }
        #expect(singletons.map(\.normalizedTitle).contains("momentum elsewhere"))
    }

    @Test func incrementalReindexReplacesRows() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()
        let model = FixtureFactory.model(title: "Draft", children: [("Alpha", nil), ("Beta", nil)])
        let url = try fixture.write(model, name: "Draft")

        try await database.indexPackage(at: url)
        let alphaHits = try await database.searchNodes("Alpha")
        #expect(!alphaHits.isEmpty)

        // Rewrite with different content (same docID, same path).
        var edited = model
        edited.nodes[edited.roots[0]]?.title = NodeTitle(text: "Draft v2")
        edited.nodes.removeValue(forKey: edited.nodes[edited.roots[0]]!.children[0])
        edited.nodes[edited.roots[0]]?.children.removeFirst()
        try ArborPackage.write(
            edited,
            meta: PackageMeta(modified: Date(timeIntervalSinceReferenceDate: 300), docID: edited.docID),
            to: url)

        try await database.indexPackage(at: url)

        // Old row gone, new row present, exactly one document indexed.
        #expect(try await database.searchNodes("Alpha").isEmpty)
        #expect(try await database.searchNodes("Beta").count == 1)
        #expect(try await database.allEntries().count == 1)
        #expect(try await database.entry(at: url)?.title == "Draft v2")
    }

    @Test func rebuildEqualsIncrementalIndexing() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()

        var linked = FixtureFactory.model(title: "Source", children: [("From", nil)])
        let target = FixtureFactory.model(title: "Target", children: [("To", nil)])
        linked.nodes[linked.roots[0]]?.link = MapLibrary.ArborLink.url(
            docID: target.docID, nodeID: target.roots[0])
        let sourceURL = try fixture.write(linked, name: "Source", modified: Date(timeIntervalSinceReferenceDate: 100))
        let targetURL = try fixture.write(target, name: "Target", modified: Date(timeIntervalSinceReferenceDate: 200))

        try await database.indexPackage(at: sourceURL)
        try await database.indexPackage(at: targetURL)

        func snapshot(
            _ entries: [LibraryEntry], _ groups: [ConceptGroup],
            _ links: [Backlink], _ due: [DueSummary]
        ) -> String {
            String(describing: entries) + String(describing: groups.map(\.occurrences))
                + String(describing: links.map(\.sourceNodeID)) + String(describing: due)
        }
        let incremental = snapshot(
            try await database.allEntries(),
            try await database.conceptGroups(matching: nil),
            try await database.backlinks(toDocID: target.docID, nodeID: target.roots[0]),
            try await database.dueCounts(now: Date(timeIntervalSinceReferenceDate: 0)))

        try await database.rebuild(folders: [fixture.folder])

        let rebuilt = snapshot(
            try await database.allEntries(),
            try await database.conceptGroups(matching: nil),
            try await database.backlinks(toDocID: target.docID, nodeID: target.roots[0]),
            try await database.dueCounts(now: Date(timeIntervalSinceReferenceDate: 0)))
        #expect(incremental == rebuilt)
        #expect(try await database.allEntries().count == 2)
    }

    @Test func removedPackageVanishesFromIndex() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()
        let url = try fixture.write(FixtureFactory.model(title: "Temp", children: [("X", nil)]), name: "Temp")
        try await database.indexPackage(at: url)
        #expect(try await database.allEntries().count == 1)

        try? FileManager.default.removeItem(at: url)
        await database.removePackage(at: url)
        #expect(try await database.allEntries().isEmpty)
        #expect(try await database.searchNodes("X").isEmpty)
    }

    @Test func dueCountsSeparateDueTodayFromNewCards() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()

        let now = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 1_000_000))
        var model = FixtureFactory.model(
            title: "Deck",
            children: [
                ("Due yesterday", nil),
                ("Due tonight", nil),
                ("Due next week", nil),
                ("New card never scheduled", nil),
                ("Not a card", nil),
            ])
        let rootID = model.roots[0]
        let childIDs = model.nodes[rootID]!.children
        let day = 86_400.0
        var dueYesterday = NodeStudy(card: .on)
        dueYesterday.fsrs = FSRSState(due: now.addingTimeInterval(-day), state: .review)
        var dueTonight = NodeStudy(card: .on)
        dueTonight.fsrs = FSRSState(due: now.addingTimeInterval(day / 2), state: .review)
        var dueNextWeek = NodeStudy(card: .on)
        dueNextWeek.fsrs = FSRSState(due: now.addingTimeInterval(5 * day), state: .review)
        let newCard = NodeStudy(card: .on)
        model.nodes[childIDs[0]]?.study = dueYesterday
        model.nodes[childIDs[1]]?.study = dueTonight
        model.nodes[childIDs[2]]?.study = dueNextWeek
        model.nodes[childIDs[3]]?.study = newCard
        // childIDs[4] stays a plain note-less leaf — not a card under auto.

        let url = try fixture.write(model, name: "Deck")
        try await database.indexPackage(at: url)

        let summaries = try await database.dueCounts(now: now)
        #expect(summaries.count == 1)
        #expect(summaries.first?.dueToday == 2)
        // New cards: the explicit .on child, plus the auto rule's root
        // (a parent with children is a card — F-STD-1).
        #expect(summaries.first?.newCards == 2)
        #expect(summaries.first?.docID == model.docID)
    }

    @Test func tagsAreIndexedPerDocument() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()
        var model = FixtureFactory.model(title: "Tagged", children: [("Node", nil)])
        let tagID = UUID().uuidString
        model.tags = [Tag(id: tagID, name: "exam", color: "#E5484D")]
        model.nodes[model.roots[0]]?.tags = [tagID]
        let url = try fixture.write(model, name: "Tagged")
        try await database.indexPackage(at: url)

        let tags = try await database.allTags()
        #expect(tags.count == 1)
        #expect(tags.first?.name == "exam")
        #expect(tags.first?.documents == 1)
    }

    @Test func conceptNormalizationFoldsCaseWidthAndWhitespace() {
        #expect(ConceptText.normalize("  Ｃａｆé ") == "cafe")
        #expect(ConceptText.normalize("Momentum") == ConceptText.normalize("momENTUM"))
        #expect(ConceptText.normalize("a　 b") == "a b")
        #expect(ConceptText.normalize("①") == "1")
    }
}
