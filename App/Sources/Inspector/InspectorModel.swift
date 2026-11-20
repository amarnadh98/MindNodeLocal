import AppKit
import Combine
import Foundation
import MapCore
import MapRender

/// The inspector's observable state (F-STY-2/3/4/6/8, F-LAY-12): a
/// snapshot of the selection's stored style patches, the selection's
/// root-tree structure, plus document-level theme and app-level
/// spacing/canvas state, refreshed after every model or selection
/// change. Mutations never touch the model here — they go out through
/// the pane controller's closures as one `MapStore` command each (SPEC
/// §11.3).
@MainActor
final class InspectorModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case style
        case layout
        case theme
        case canvas
    }

    struct SelectedNode: Identifiable, Hashable {
        let id: String
        let level: Int
        let storedPatch: NodeStylePatch?
    }

    // MARK: selection snapshot

    @Published var tab: Tab = .style
    @Published var selectedNodes: [SelectedNode] = []

    // MARK: layout state (F-LAY-12, the selection's root tree)

    /// The id of the selected node's root (the tree a structure choice
    /// applies to — the canvas resolves structure per root).
    @Published var structureRootID: String?
    /// The root's stored structure override; `nil` = the default
    /// balanced mind map.
    @Published var structureOverride: String?

    // MARK: theme state

    @Published var themeID: String = BuiltInThemes.defaultID
    @Published var appearance: AppearanceMode = .auto
    /// `nil` = the theme's own rainbow setting (F-STY-8).
    @Published var rainbowOverride: Bool?
    /// The document's stored canvas-color override, if any (the Canvas
    /// pane's picker; `nil` = the theme's color).
    @Published var canvasColorOverride: String?
    /// The id currently hovered in the theme grid (view-only preview).
    @Published var previewedThemeID: String?
    @Published var defaultThemeID: String = BuiltInThemes.newDocumentDefaultID

    // MARK: app-level rows the Canvas pane mirrors

    @Published var showsTagPills = true
    @Published var showsMinimap = true
    @Published var showsContextualBar = true

    // MARK: spacing (F-LAY-12, user-level)

    @Published var spacingPreset = 1
    @Published var customSiblingGap: Double?
    @Published var customLevelGap: Double?

    var selectedIDs: [String] { selectedNodes.map(\.id) }
    var hasSelection: Bool { !selectedNodes.isEmpty }
    var selectionIncludesRoot: Bool { selectedNodes.contains { $0.level == 0 } }
    var selectionCount: Int { selectedNodes.count }

    /// One patch for a single-node selection; nil for none/multi (the
    /// Style tab reads per-field values through `value/mixed` below).
    var singlePatch: NodeStylePatch? {
        selectedNodes.count == 1 ? selectedNodes[0].storedPatch : nil
    }

    /// The shared stored value for `key`, or nil when no selected node
    /// carries it (or the selection is empty).
    func value<T: Equatable>(_ key: NodeStyleKey, _ pick: (NodeStylePatch) -> T?) -> T? {
        var shared: T?
        var seen = false
        for node in selectedNodes {
            guard let patch = node.storedPatch, let value = pick(patch) else { return nil }
            if seen, value != shared { return nil }
            shared = value
            seen = true
        }
        return shared
    }

    /// True when the selected nodes carry *different* stored values for
    /// `key` — the inspector shows the field as "Mixed".
    func isMixed<T: Equatable>(_ key: NodeStyleKey, _ pick: (NodeStylePatch) -> T?) -> Bool {
        var values: [T?] = []
        for node in selectedNodes {
            values.append(node.storedPatch.flatMap(pick))
        }
        let set = Set(values.map { $0.map { "\($0)" } ?? "<nil>" })
        return set.count > 1
    }

    /// True when some selected nodes carry the override and others do
    /// not (presence mixing, no values needed).
    func isPresenceMixed(_ key: NodeStyleKey) -> Bool {
        let flags = selectedNodes.map { $0.storedPatch?.hasOverride(key) == true }
        return Set(flags).count > 1
    }

    /// True when every selected node carries an override for `key`
    /// (the dot + "Reset to theme" affordance, F-STY-3).
    func isOverridden(_ key: NodeStyleKey) -> Bool {
        guard !selectedNodes.isEmpty else { return false }
        return selectedNodes.allSatisfy { $0.storedPatch?.hasOverride(key) == true }
    }

    // MARK: mutation closures (wired by the pane controller)

    var onStylePatch: ((NodeStylePatch) -> Void)?
    var onResetKeys: (([NodeStyleKey]?) -> Void)?
    var onStructure: ((String?) -> Void)?
    var onApplyTheme: ((String) -> Void)?
    var onPreviewTheme: ((String?) -> Void)?
    var onRainbowToggle: ((Bool) -> Void)?
    var onRecolorBranches: (() -> Void)?
    var onAppearance: ((AppearanceMode?) -> Void)?
    var onDefaultTheme: ((String) -> Void)?
    var onCanvasColor: ((String?) -> Void)?
    var onSpacingPreset: ((Int) -> Void)?
    var onCustomGaps: ((Double?, Double?) -> Void)?
    var onShowsTagPills: ((Bool) -> Void)?
    var onShowsMinimap: ((Bool) -> Void)?
    var onShowsContextualBar: ((Bool) -> Void)?
}
