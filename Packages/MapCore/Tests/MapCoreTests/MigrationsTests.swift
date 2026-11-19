import Foundation
import Testing

@testable import MapCore

/// SPEC §8.4: a fixture-backed migration test for every version step
/// ever shipped. v1 → v2 back-fills the persistent branch palette index
/// positionally (ADR-0009) so pre-v2 files keep their on-screen colors.
struct MigrationsTests {
    @Test func v1FixtureMigratesExactlyToTheV2Fixture() throws {
        let legacy = try decodeFixture("map-v1")
        // The v1→v2 step itself still lands exactly on the v2 fixture.
        let stepped = Migrations.v1ToV2(legacy)
        let versionTwo = try decodeFixture("map-v2")
        #expect(stepped == versionTwo)
        #expect(stepped.formatVersion == 2)
        // A full migration from v1 walks every step to the current
        // format; the v2→v3 step changes nothing but the version stamp.
        let migrated = try Migrations.migrate(legacy, from: 1)
        #expect(migrated.formatVersion == ArborFormat.formatVersion)
        var expected = versionTwo
        expected.formatVersion = ArborFormat.formatVersion
        #expect(migrated == expected)
    }

    @Test func v2FixtureMigratesExactlyToTheV3Fixture() throws {
        let versionTwo = try decodeFixture("map-v2")
        let migrated = try Migrations.migrate(versionTwo, from: 2)
        let versionThree = try decodeFixture("map-v3")
        #expect(migrated == versionThree)
        #expect(migrated.formatVersion == 3)
        // The v3 step adds only optional fields: nothing is back-filled.
        for (id, node) in versionTwo.nodes {
            #expect(migrated.nodes[id]?.style == node.style)
        }
        #expect(migrated.theme == versionTwo.theme)
    }

    @Test func v3OptionalStyleAndThemeFieldsRoundTrip() throws {
        var model = try decodeFixture("map-v3")
        model.nodes["branch-a"]?.style = NodeStylePatch(
            shape: .pill, fill: "#0090FF", fontWeight: 0.4, minWidth: 60)
        model.theme = ThemeSelection(
            id: "ocean", overrides: ThemePatch(rainbowBranches: false))
        model.appearance = .dark

        let restored = try MapDocumentCoder.roundTrip(model)
        #expect(restored == model)
        #expect(restored.nodes["branch-a"]?.style?.fontWeight == 0.4)
        #expect(restored.nodes["branch-a"]?.style?.minWidth == 60)
        #expect(restored.theme?.overrides?.rainbowBranches == false)
        #expect(restored.appearance == .dark)
    }

    @Test func migrationIsIdempotent() throws {
        let legacy = try decodeFixture("map-v1")
        let once = try Migrations.migrate(legacy, from: 1)
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
