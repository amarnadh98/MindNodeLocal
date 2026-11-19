import Foundation
import MapCore
import Testing

@testable import MapLibrary

/// Indexing performance (print-only timing; the full-text budget is
/// asserted locally and print-only when `CI` is set, matching the
/// repo's perf-test convention).
@Suite struct IndexPerformanceTests {
    /// Index a 5k-node package: prints the wall time.
    @Test func indexFiveThousandNodePackage() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()

        let model = Self.largeModel(nodeCount: 5_000)
        let url = try fixture.write(model, name: "Large")

        let start = ContinuousClock.now
        try await database.indexPackage(at: url)
        let elapsed = ContinuousClock.now - start
        print(String(format: "index 5k-node package: %.0f ms", elapsed.milliseconds))

        let entries = try await database.allEntries()
        #expect(entries.first?.title == "Large Map")
    }

    /// Full-text query over that 5k-node index stays under 50 ms.
    @Test func fullTextQueryUnder50ms() async throws {
        let fixture = try FixtureFactory()
        defer { fixture.cleanup() }
        let database = try FixtureFactory.database()
        let model = Self.largeModel(nodeCount: 5_000)
        try await database.indexPackage(at: try fixture.write(model, name: "Large"))

        // Warm one query (page cache), then measure.
        _ = try await database.searchNodes("needle 4999")

        let start = ContinuousClock.now
        let hits = try await database.searchNodes("needle 4999")
        let elapsed = ContinuousClock.now - start
        print(String(format: "full-text query on 5k nodes: %.1f ms", elapsed.milliseconds))
        #expect(hits.count == 1)

        // Shared CI runners only print the timing; local runs assert.
        if ProcessInfo.processInfo.environment["CI"] == nil {
            #expect(elapsed < .milliseconds(50))
        }
    }

    /// A wide, two-level map: one root, `nodeCount` children with
    /// notes, one carrying a distinct "needle" title.
    static func largeModel(nodeCount: Int) -> MapModel {
        var model = MapModel(docID: UUID().uuidString)
        let rootID = UUID().uuidString
        model.nodes[rootID] = Node(id: rootID, title: NodeTitle(text: "Large Map"))
        model.roots = [rootID]
        for index in 0..<nodeCount {
            let childID = UUID().uuidString
            var child = Node(
                id: childID, parent: rootID,
                title: NodeTitle(text: "Topic \(index)"),
                note: "Notes about topic \(index)")
            if index == nodeCount - 1 {
                child.title = NodeTitle(text: "needle \(index)")
            }
            child.created = Date(timeIntervalSince1970: 0)
            child.modified = Date(timeIntervalSince1970: 0)
            model.nodes[childID] = child
            model.nodes[rootID]?.children.append(childID)
        }
        return model
    }
}

extension Duration {
    /// Whole milliseconds as a Double, for printed timings.
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
