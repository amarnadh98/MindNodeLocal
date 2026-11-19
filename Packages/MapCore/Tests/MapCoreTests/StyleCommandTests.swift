import Foundation
import Testing

@testable import MapCore

/// F-STY-2/F-STY-3/F-STY-6 commands: `setStyle` merges (multi-selection
/// = one undo step), `resetStyle` restores theme values, `setThemeOverrides`
/// and `setAppearance` snapshot their pre-state exactly, and
/// `setStructure` (F-LAY, SPEC §5.3) carries a subtree's structure
/// override with its exact pre-state inverse.
struct StyleCommandTests {
    private func styledModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "style")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "root"), created: date, modified: date)
        model.roots = [rootID]
        for id in ["a", "b"] {
            model.nodes[id] = Node(
                id: id, parent: rootID, title: NodeTitle(text: id), created: date, modified: date)
            model.nodes[rootID]?.children.append(id)
        }
        return model
    }

    // MARK: setStyle

    @Test func setStyleMergesIntoTheStoredPatch() throws {
        var model = styledModel()
        model.nodes["a"]?.style = NodeStylePatch(fill: "#E5484D")

        let command = MapCommand.setStyle(
            ids: ["a"], patch: NodeStylePatch(shape: .pill, fontSize: 18))
        try command.apply(to: &model)

        let style = try #require(model.nodes["a"]?.style)
        #expect(style.fill == "#E5484D", "an untouched field must survive the merge")
        #expect(style.shape == .pill)
        #expect(style.fontSize == 18)
    }

    @Test func setStyleOverASelectionIsOneCommandForAllNodes() throws {
        var model = styledModel()
        try MapCommand.setStyle(ids: ["a", "b"], patch: NodeStylePatch(fill: "#0090FF"))
            .apply(to: &model)
        #expect(model.nodes["a"]?.style?.fill == "#0090FF")
        #expect(model.nodes["b"]?.style?.fill == "#0090FF")
    }

    @Test func emptyPatchStaysNil() throws {
        var model = styledModel()
        try MapCommand.setStyle(ids: ["a"], patch: NodeStylePatch())
            .apply(to: &model)
        #expect(model.nodes["a"]?.style == nil)
    }

    @Test func setStyleInverseRestoresEachNodesExactPreState() throws {
        var model = styledModel()
        // Different pre-states per node: only an exact per-node inverse
        // can restore both.
        model.nodes["a"]?.style = NodeStylePatch(shape: .diamond, fill: "#E5484D")
        model.nodes["b"]?.style = nil

        let command = MapCommand.setStyle(
            ids: ["a", "b"], patch: NodeStylePatch(fill: "#46A758", padding: 8))
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        try inverse.apply(to: &model)

        #expect(model.nodes["a"]?.style == NodeStylePatch(shape: .diamond, fill: "#E5484D"))
        #expect(model.nodes["b"]?.style == nil)
    }

    @Test func setStyleIsAllOrNothingOnMissingNodes() throws {
        var model = styledModel()
        let before = model
        #expect(throws: ArborError.self) {
            try MapCommand.setStyle(ids: ["a", "ghost"], patch: NodeStylePatch(fill: "#FFC53D"))
                .apply(to: &model)
        }
        #expect(model == before)
    }

    // MARK: resetStyle

    @Test func resetStyleRestoresThemeValues() throws {
        var model = styledModel()
        model.nodes["a"]?.style = NodeStylePatch(shape: .pill, fill: "#E5484D", fontSize: 30)

        try MapCommand.resetStyle(ids: ["a"], keys: [.fill, .shape]).apply(to: &model)
        let style = try #require(model.nodes["a"]?.style)
        #expect(style.fill == nil, "the reset key returns to the theme")
        #expect(style.shape == nil)
        #expect(style.fontSize == 30, "keys not listed survive the reset")

        // `nil` keys clear the whole patch back to the theme.
        try MapCommand.resetStyle(ids: ["a"], keys: nil).apply(to: &model)
        #expect(model.nodes["a"]?.style == nil)
    }

    @Test func resetStyleInverseRestoresTheOverrides() throws {
        var model = styledModel()
        model.nodes["a"]?.style = NodeStylePatch(fill: "#E5484D", cornerRadius: 4)
        model.nodes["b"]?.style = NodeStylePatch(fontSize: 20)

        let command = MapCommand.resetStyle(ids: ["a", "b"], keys: [.fill, .fontSize])
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        try inverse.apply(to: &model)

        #expect(model.nodes["a"]?.style == NodeStylePatch(fill: "#E5484D", cornerRadius: 4))
        #expect(model.nodes["b"]?.style == NodeStylePatch(fontSize: 20))
    }

    @Test func resetStyleOnAnUnstyledNodeIsANoOp() throws {
        var model = styledModel()
        let before = model
        try MapCommand.resetStyle(ids: ["a"], keys: nil).apply(to: &model)
        #expect(model == before)
    }

    // MARK: setStructure

    @Test func setStructureRoundTripsThroughItsInverse() throws {
        var model = styledModel()
        #expect(model.nodes["root"]?.structure == nil)

        let command = MapCommand.setStructure(id: "root", structure: "mindmap.right")
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        #expect(model.nodes["root"]?.structure == "mindmap.right")

        try inverse.apply(to: &model)
        #expect(model.nodes["root"]?.structure == nil)
    }

    @Test func setStructureReplacesThePreviousOverride() throws {
        var model = styledModel()
        model.nodes["root"]?.structure = "orgchart.down"

        try MapCommand.setStructure(id: "root", structure: "mindmap.balanced").apply(to: &model)
        #expect(model.nodes["root"]?.structure == "mindmap.balanced")
    }

    @Test func setStructureThrowsOnAMissingNode() throws {
        var model = styledModel()
        let before = model
        #expect(throws: ArborError.self) {
            try MapCommand.setStructure(id: "ghost", structure: "mindmap.right").apply(to: &model)
        }
        #expect(model == before)
    }

    // MARK: setThemeOverrides / setAppearance

    @Test func setThemeOverridesRoundTripsThroughItsInverse() throws {
        var model = styledModel()
        model.theme = ThemeSelection(id: "ocean", overrides: ThemePatch(rainbowBranches: true))

        let command = MapCommand.setThemeOverrides(overrides: ThemePatch(rainbowBranches: false))
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        #expect(model.theme?.id == "ocean", "the theme id is preserved")
        #expect(model.theme?.overrides?.rainbowBranches == false)

        try inverse.apply(to: &model)
        #expect(model.theme == ThemeSelection(id: "ocean", overrides: ThemePatch(rainbowBranches: true)))
    }

    @Test func setThemeOverridesPinsTheDefaultThemeOnUnstyledDocuments() throws {
        var model = styledModel()
        #expect(model.theme == nil)

        let command = MapCommand.setThemeOverrides(overrides: ThemePatch(rainbowBranches: false))
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        // `ThemeSelection`'s own default id (the built-in default theme).
        #expect(model.theme?.id == "paper")
        #expect(model.theme?.overrides?.rainbowBranches == false)

        // Undo restores "no selection at all", not just nil overrides.
        try inverse.apply(to: &model)
        #expect(model.theme == nil)
    }

    @Test func clearingTheThemeUndoesWithItsOverridesIntact() throws {
        var model = styledModel()
        model.theme = ThemeSelection(id: "ocean", overrides: ThemePatch(rainbowBranches: false))

        let command = MapCommand.setTheme(id: nil)
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        #expect(model.theme == nil)

        try inverse.apply(to: &model)
        #expect(model.theme == ThemeSelection(id: "ocean", overrides: ThemePatch(rainbowBranches: false)))
    }

    @Test func setThemeSelectionRoundTripsThroughItsInverse() throws {
        var model = styledModel()
        model.theme = ThemeSelection(id: "ocean", overrides: ThemePatch(rainbowBranches: true))

        let command = MapCommand.setThemeSelection(
            ThemeSelection(id: "sakura", overrides: ThemePatch(rainbowBranches: false)))
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        #expect(model.theme?.id == "sakura")

        try inverse.apply(to: &model)
        #expect(model.theme == ThemeSelection(id: "ocean", overrides: ThemePatch(rainbowBranches: true)))
    }

    @Test func setAppearanceRoundTripsThroughItsInverse() throws {
        var model = styledModel()
        model.appearance = .light

        let command = MapCommand.setAppearance(mode: .dark)
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        #expect(model.appearance == .dark)
        try inverse.apply(to: &model)
        #expect(model.appearance == .light)
    }

    // MARK: patch key helpers

    @Test func patchKeysTrackEveryField() {
        var patch = NodeStylePatch(shape: .cloud, fill: "none")
        #expect(patch.overriddenKeys == [.shape, .fill])
        #expect(patch.hasOverride(.shape))
        #expect(!patch.hasOverride(.shadow))

        patch.clear(.shape)
        #expect(patch.overriddenKeys == [.fill])
        #expect(!patch.isEmpty)

        patch.clear(.fill)
        #expect(patch.isEmpty)
    }

    @Test func sizeAffectingFieldsAreExactlyTheMeasuredInputs() {
        // The layout-dirty contract (SPEC §11.3): only font/padding/
        // width fields can move a node's frame.
        #expect(!NodeStylePatch(shape: .cloud, fill: "#E5484D").affectsMeasuredSize)
        #expect(!NodeStylePatch(branchColor: "#E5484D", branchWidth: 4).affectsMeasuredSize)
        #expect(NodeStylePatch(padding: 12).affectsMeasuredSize)
        #expect(NodeStylePatch(fontSize: 20).affectsMeasuredSize)
        #expect(NodeStylePatch(fontWeight: 0.4).affectsMeasuredSize)
        #expect(NodeStylePatch(fontItalic: true).affectsMeasuredSize)
        #expect(NodeStylePatch(minWidth: 120).affectsMeasuredSize)
        #expect(NodeStylePatch(maxWidth: 400).affectsMeasuredSize)
        #expect(NodeStylePatch(fontName: "Georgia").affectsMeasuredSize)
    }
}
