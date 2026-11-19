import Foundation
import MapCore
import Testing

@testable import MapAutomation

/// F-INT-1 Find Nodes' pure core: title/tag/task queries, outline-order
/// results, and node reference resolution.
struct NodeSearchTests {
    @Test func titleSubstringIsCaseAndDiacriticInsensitive() {
        let hits = NodeSearch.hits(in: FixtureMap.model(), query: .init(text: "PAINT"))
        #expect(hits.map(\.nodeID) == ["paint"])

        var kitchen = FixtureMap.model()
        kitchen.nodes["budget"]?.title = NodeTitle(text: "Büdget")
        #expect(NodeSearch.hits(in: kitchen, query: .init(text: "budget")).count == 1)
    }

    @Test func taskFilterDistinguishesOpenAndDone() {
        let model = FixtureMap.model()
        #expect(
            NodeSearch.hits(in: model, query: .init(task: .done)).map(\.nodeID) == ["paint"])
        #expect(
            NodeSearch.hits(in: model, query: .init(task: .open)).map(\.nodeID) == ["budget"])
    }

    @Test func tagFilterMatchesNames() {
        let model = FixtureMap.model()
        #expect(NodeSearch.hits(in: model, query: .init(tag: "money")).map(\.nodeID) == ["budget"])
        #expect(NodeSearch.hits(in: model, query: .init(tag: "nope")).isEmpty)
    }

    @Test func combinedFiltersIntersect() {
        let hits = NodeSearch.hits(
            in: FixtureMap.model(), query: NodeSearch.Query(text: "colors", task: .done))
        #expect(hits.map(\.nodeID) == ["paint"])
    }

    @Test func breadcrumbCarriesAncestorsRootFirst() {
        let hits = NodeSearch.hits(in: FixtureMap.model(), query: .init(text: "Sage"))
        #expect(hits.count == 1)
        #expect(hits[0].breadcrumb == ["Kitchen Reno", "Paint colors"])
    }

    @Test func resolvePrefersIdThenExactTitle() {
        let model = FixtureMap.model()
        #expect(NodeSearch.resolve(reference: "paint", in: model) == "paint")
        #expect(NodeSearch.resolve(reference: "Paint Colors", in: model) == "paint")
        #expect(NodeSearch.resolve(reference: "  ", in: model) == nil)
        // An id that shadows a title still resolves to itself.
        #expect(NodeSearch.resolve(reference: "root", in: model) == "root")
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(NodeSearch.hits(in: FixtureMap.model(), query: .init()).isEmpty)
    }
}
