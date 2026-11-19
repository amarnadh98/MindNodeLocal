import Foundation
import Testing

@testable import MapCore

/// SPEC §8.4: a fixture-backed migration test for every version step
/// ever shipped. v1 → v2 back-fills the persistent branch palette index
/// positionally (ADR-0009) so pre-v2 files keep their on-screen colors.
struct MigrationsTests {
    @Test func v1FixtureMigratesExactlyToTheV2Fixture() throws {
        let v1 = try decodeFixture("map-v1")
        let migrated = try Migrations.migrate(v1, from: 1)
        let v2 = try decodeFixture("map-v2")
        #expect(migrated == v2)
        #expect(migrated.formatVersion == 2)
    }

    @Test func migrationIsIdempotent() throws {
        let v1 = try decodeFixture("map-v1")
        let once = try Migrations.migrate(v1, from: 1)
        let twice = try Migrations.migrate(once, from: 1)
        #expect(once == twice)
    }

    @Test func v1MigrationTouchesOnlyLevelOneNodes() throws {
        var model = try decodeFixture("map-v1")
        let before = model
        model = Migrations.v1ToV2(model)

        #expect(model.formatVersion == 2)
        #expect(before.formatVersion == 1)
        for (id, beforeNode) in before.nodes {
            let afterNode = model.nodes[id]
            if let parentID = beforeNode.parent, model.roots.contains(parentID) {
                #expect(afterNode?.paletteIndex == model.nodes[parentID]?.children.firstIndex(of: id))
            } else {
                #expect(afterNode?.paletteIndex == nil, "\(id) must not gain an index")
            }
            // No other field changes.
            var expected = beforeNode
            expected.paletteIndex = afterNode?.paletteIndex
            #expect(afterNode == expected, "\(id) must otherwise be untouched")
        }
    }

    @Test func versionZeroOrNegativeIsRefused() throws {
        let model = MapModel.emptyDocument()
        #expect(throws: ArborError.self) {
            _ = try Migrations.migrate(model, from: 0)
        }
    }

    private func decodeFixture(_ name: String) throws -> MapModel {
        let bundle = Bundle.module
        let url =
            bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        let data = try Data(contentsOf: try #require(url))
        return try MapDocumentCoder.decode(data)
    }
}
