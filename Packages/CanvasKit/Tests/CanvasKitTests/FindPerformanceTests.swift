import Foundation
import MapCore
import Testing

@testable import CanvasKit

/// F-FOC-3's find budget: a full scan of the 5,000-node fixture stays
/// under 16 ms (SPEC §11.8 measurement discipline — best of 10; the
/// assertion only bites in release and local runs, CI prints).
struct FindPerformanceTests {
    private func bigMap(nodeCount: Int) -> MapModel {
        var model = MapModel.emptyDocument(docID: "find-perf")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<nodeCount {
            let id = "n\(index)"
            model.nodes[id] = Node(
                id: id,
                title: NodeTitle(text: "Node \(index) with a title of some length"),
                note: index % 3 == 0 ? "A note mentioning beta \(index) occasionally" : nil,
                created: date, modified: date)
        }
        var childrenOf: [String: [String]] = [:]
        var frontier = 0
        var nextChild = 1
        model.roots = ["n0"]
        while nextChild < nodeCount {
            let childCount = min(7, nodeCount - nextChild)
            childrenOf["n\(frontier)"] = (nextChild..<(nextChild + childCount)).map { "n\($0)" }
            nextChild += childCount
            frontier += 1
        }
        for (parent, children) in childrenOf {
            model.nodes[parent]?.children = children
            for child in children {
                model.nodes[child]?.parent = parent
            }
        }
        return model
    }

    @Test func findOverFiveThousandNodes() {
        let model = bigMap(nodeCount: 5_000)
        // One cold run (cache priming) then best of 10.
        _ = FindEngine.matches(query: "beta", options: FindOptions(includeTags: true), in: model)
        var best: Double?
        for _ in 0..<10 {
            let start = DispatchTime.now()
            let matches = FindEngine.matches(
                query: "beta", options: FindOptions(includeTags: true), in: model)
            let elapsed = elapsed(since: start)
            best = min(best ?? elapsed, elapsed)
            if matches.isEmpty {
                Issue.record("the fixture must produce matches")
                return
            }
        }
        let seconds = best ?? 0
        print("perf find (5k, best of 10): \(format(seconds)) — titles + notes + tags")

        #if !DEBUG
            // §11.8-style gate: enforce locally, print-only on CI
            // (shared runners measure 2–3× slower than an M1).
            if ProcessInfo.processInfo.environment["CI"] == nil {
                #expect(
                    seconds < 0.016,
                    "find over the 5k fixture exceeds its 16 ms budget: \(format(seconds))")
            }
        #endif
    }

    @Test func replaceAllScanOverFiveThousandNodes() {
        let model = bigMap(nodeCount: 5_000)
        _ = FindEngine.replaceAllCommand(query: "beta", replacement: "zeta", options: FindOptions(), in: model)
        var best: Double?
        for _ in 0..<10 {
            let start = DispatchTime.now()
            _ = FindEngine.replaceAllCommand(query: "beta", replacement: "zeta", options: FindOptions(), in: model)
            best = min(best ?? elapsed(since: start), elapsed(since: start))
        }
        let seconds = best ?? 0
        print("perf replace-all scan (5k, best of 10): \(format(seconds))")
        #if !DEBUG
            if ProcessInfo.processInfo.environment["CI"] == nil {
                #expect(seconds < 0.016, "replace-all scan exceeds the 16 ms budget: \(format(seconds))")
            }
        #endif
    }

    private func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }
}
