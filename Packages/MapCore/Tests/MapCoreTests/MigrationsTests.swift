import Foundation
import Testing

@testable import MapCore

/// SPEC §8.4: a fixture-backed migration test for every version step
/// ever shipped. v1 → v2 back-fills the persistent branch palette index
/// positionally (ADR-0009) so pre-v2 files keep their on-screen colors.
/// v2 → v3 only stamps the version: the v3 schema additions
/// (`MapModel.ai`, `Node.note` editing) are optional.
struct MigrationsTests {
    @Test func v1FixtureMigratesExactlyToTheV2Fixture() throws {
        let v1 = try decodeFixture("map-v1")
        let migrated = Migrations.v1ToV2(v1)
        let v2 = try decodeFixture("map-v2")
        #expect(migrated == v2)
        #expect(migrated.formatVersion == 2)
    }

    @Test func v2FixtureMigratesExactlyToTheV3Fixture() throws {
        let v2 = try decodeFixture("map-v2")
        let migrated = try Migrations.migrate(v2, from: 2)
        let v3 = try decodeFixture("map-v3")
        // `migrate` always lands on the current version: the chain is
        // v2 → v3 (stamp) → v4 (stamp, ADR-0028), so the expected value
        // is the v3 fixture plus the v4 stamp.
        var expected = v3
        expected.formatVersion = ArborFormat.formatVersion
        #expect(migrated == expected)
        #expect(migrated.formatVersion == ArborFormat.formatVersion)
        // The optional AI policy stays unset: old files carry no
        // restriction (SPEC §12).
        #expect(migrated.ai == nil)
    }

    @Test func v1MigratesThroughEveryStepToCurrent() throws {
        let v1 = try decodeFixture("map-v1")
        let migrated = try Migrations.migrate(v1, from: 1)
        #expect(migrated.formatVersion == ArborFormat.formatVersion)
        // Compose the steps by hand: the result must be identical.
        let composed = Migrations.v3ToV4(Migrations.v2ToV3(Migrations.v1ToV2(v1)))
        #expect(migrated == composed)
    }

    @Test func v3FixtureMigratesToV4ByStampingOnly() throws {
        // v3 → v4 (ADR-0028): the new fields (`NodeStylePatch.fontWeight`
        // / `fontItalic` / `minWidth`, `ThemePatch.rainbowBranches`) are
        // optional, so a v3 file migrates to itself plus the version.
        let v3 = try decodeFixture("map-v3-ai-policy")
        let migrated = try Migrations.migrate(v3, from: 3)
        var expected = v3
        expected.formatVersion = 4
        #expect(migrated == expected)
        #expect(migrated.formatVersion == ArborFormat.formatVersion)
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

    @Test func v3AIPolicyFixtureDecodesAndRoundTrips() throws {
        let fixture = try decodeFixture("map-v3-ai-policy")
        #expect(fixture.formatVersion == 3)
        #expect(fixture.ai?.neverSendToCloud == true)
        let roundTripped = try MapDocumentCoder.roundTrip(fixture)
        #expect(roundTripped == fixture)
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
