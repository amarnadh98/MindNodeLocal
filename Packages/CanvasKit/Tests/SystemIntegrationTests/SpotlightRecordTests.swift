import Foundation
import MapCore
import SystemIntegration
import Testing

/// F-INT-2: the Spotlight record extracted from a package's model and
/// meta — titles, notes, tags and unicode all land where the importer
/// extension puts them.
@Suite
struct SpotlightRecordTests {
    /// A model exercising every extraction path: explicit title, unicode
    /// titles (CJK + emoji), notes, used/unused/unknown tags, nesting.
    private func fixtureModel() -> MapModel {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var model = MapModel(title: "京都 Study Plan")
        model.tags = [
            Tag(id: "t-trip", name: "trip", color: "#FF0000"),
            Tag(id: "t-work", name: "work", color: "#00FF00"),
            Tag(id: "t-unused", name: "unused", color: "#0000FF"),
        ]
        func add(
            _ id: String, _ text: String, parent: String? = nil, note: String? = nil,
            tags: [String]? = nil
        ) {
            var node = Node(id: id, title: NodeTitle(text: text), created: date, modified: date)
            node.parent = parent
            node.note = note
            node.tags = tags
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
            model.nodes[id] = node
        }
        add("root", "Trip to Kyoto 🍁", note: "Cherry blossom season notes")
        add("alpha", "Temples", parent: "root", tags: ["t-trip"])
        add("alpha-child", "清水寺", parent: "alpha", note: "Go early, gates open at 6am")
        add("alpha-child-2", "金閣寺", parent: "alpha", tags: ["t-trip", "t-work"])
        add("beta", "Budget 🧾", parent: "root", tags: ["t-work", "t-ghost"])
        return model
    }

    @Test func recordIndexesTitlesNotesTagsAndUnicode() {
        let model = fixtureModel()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_800_000_100)
        let meta = PackageMeta(
            formatVersion: ArborFormat.formatVersion, appVersion: "0.1.0-test",
            created: created, modified: modified, docID: model.docID)
        let record = SpotlightMetadata.record(
            model: model, meta: meta, fileModificationDate: Date())

        // Title: the explicit document title.
        #expect(record.title == "京都 Study Plan")
        // The format has no author field — the record leaves authors
        // unset rather than fabricating one.
        #expect(record.authors == nil)
        // Dates come from the package meta.
        #expect(record.contentCreationDate == created)
        #expect(record.contentModificationDate == modified)

        // textContent: the title first, then every title and note in
        // document order (root, depth-first).
        let expectedLines = [
            "京都 Study Plan",
            "Trip to Kyoto 🍁",
            "Cherry blossom season notes",
            "Temples",
            "清水寺",
            "Go early, gates open at 6am",
            "金閣寺",
            "Budget 🧾",
        ]
        #expect(record.textContent == expectedLines.joined(separator: "\n"))

        // Keywords: the used tag names in first-use order; the unused
        // and the unknown id are skipped.
        #expect(record.keywords == ["trip", "work"])
    }

    @Test func recordFallsBackToFileDatesAndRootTitle() {
        var model = fixtureModel()
        model.title = nil
        let fileDate = Date(timeIntervalSince1970: 1_900_000_000)
        let record = SpotlightMetadata.record(
            model: model, meta: nil, fileModificationDate: fileDate)
        // No explicit title: the root's first line stands in.
        #expect(record.title == "Trip to Kyoto 🍁")
        // No meta: the package's filesystem date backs both dates.
        #expect(record.contentCreationDate == fileDate)
        #expect(record.contentModificationDate == fileDate)
    }

    @Test func textContentIsCappedAndEmptyNotesAreSkipped() {
        var model = MapModel.emptyDocument()
        var root = Node(id: "root", title: NodeTitle(text: "Root"))
        root.note = "   "
        model.nodes["root"] = root
        model.roots = ["root"]
        let record = SpotlightMetadata.record(model: model, meta: nil, fileModificationDate: nil)
        // The whitespace-only note contributes nothing.
        #expect(record.textContent == "Root\nRoot")

        // A runaway map cannot flood the index: textContent is capped.
        var wide = MapModel.emptyDocument()
        let bigRoot = Node(id: "root", title: NodeTitle(text: String(repeating: "字", count: 500)))
        wide.nodes["root"] = bigRoot
        wide.roots = ["root"]
        for index in 0..<200 {
            var child = Node(id: "c\(index)", title: NodeTitle(text: String(repeating: "字", count: 500)))
            child.parent = "root"
            wide.nodes["c\(index)"] = child
            wide.nodes["root"]?.children.append("c\(index)")
        }
        let capped = SpotlightMetadata.record(model: wide, meta: nil, fileModificationDate: nil)
        #expect(capped.textContent.count == SpotlightMetadata.textContentLimit)
    }
}
