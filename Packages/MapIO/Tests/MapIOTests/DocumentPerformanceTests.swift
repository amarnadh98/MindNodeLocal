import Foundation
import MapCore
import Testing

@testable import MapIO

/// SPEC §11.8-style budget check for the document importers/exporters:
/// export + import across all four bidirectional formats must grow
/// linearly with node count (2k nodes, SPEC §14 IO row). The doubling
/// ratio bound is deliberately generous (4×) so shared CI runners don't
/// flake; the point is to catch quadratic blowups, not to measure
/// absolute speed.
@Suite
struct DocumentPerformanceTests {
    @Test func documentIORoundTripGrowsLinearly() throws {
        var timings: [Int: Double] = [:]
        for count in [500, 1_000, 2_000] {
            timings[count] = try bestRoundTripTime(nodeCount: count)
        }
        #expect(try ratio(timings, doubling: 1_000) < 4.0)
        #expect(try ratio(timings, doubling: 2_000) < 4.0)
        #expect(
            (timings[2_000] ?? 0) < 3.0,
            "2k-node full round trip should stay well under a few seconds")
    }

    /// Best of 3: export + re-import of every bidirectional format.
    private func bestRoundTripTime(nodeCount: Int) throws -> Double {
        let model = IOSamples.bigTree(nodeCount: nodeCount)
        var best: Double?
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let opml = try OPMLDocumentIO.importDocument(OPMLDocumentIO.exportDocument(model))
            let markdown = try MarkdownDocumentIO.importDocument(
                MarkdownDocumentIO.exportDocument(model))
            let plainText = try PlainTextOutlineIO.importDocument(
                PlainTextOutlineIO.exportDocument(model))
            let freemind = try FreeMindIO.importDocument(FreeMindIO.exportDocument(model))
            let elapsed = start.duration(to: .now)
            for roundTripped in [opml, markdown, plainText, freemind] {
                #expect(roundTripped.nodes.count == nodeCount)
                #expect(MapValidator.validate(roundTripped).isEmpty)
            }
            let seconds =
                Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            best = min(best ?? seconds, seconds)
        }
        let result = try #require(best)
        print("document IO round trip of \(nodeCount) nodes (best of 3): \(String(format: "%.3f", result)) s")
        return result
    }

    /// `timings[2×n] / timings[n]`.
    private func ratio(_ timings: [Int: Double], doubling larger: Int) throws -> Double {
        let largerTime = try #require(timings[larger])
        let smallerTime = try #require(timings[larger / 2])
        return largerTime / max(smallerTime, 0.001)
    }
}
