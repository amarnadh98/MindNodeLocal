import AppKit
import Combine
import Foundation
import MapCore
import MapRender

/// The inspector's observable state (F-STY-2/3/4/6): a snapshot of the
/// selection's stored style patches plus document-level theme state,
/// refreshed after every model or selection change. Mutations never
/// touch the model here — they go out through the pane controller's
/// closures as one `MapStore` command each (SPEC §11.3).
@MainActor
final class InspectorModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case style
        case theme
        case layout
    }

    struct SelectedNode: Identifiable, Hashable {
        let id: String
        let level: Int
        let storedPatch: NodeStylePatch?
    }

    // MARK: selection snapshot

    @Published var tab: Tab = .style
    @Published var selectedNodes: [SelectedNode] = []

    // MARK: theme state

    @Published var themeID: String = BuiltInThemes.defaultID
    @Published var appearance: AppearanceMode = .auto
    /// `nil` = the theme's own rainbow setting (F-STY-8).
    @Published var rainbowOverride: Bool?
    /// The id currently hovered in the theme grid (view-only preview).
    @Published var previewedThemeID: String?
    @Published var defaultThemeID: String = "paper"

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
    var onApplyTheme: ((String) -> Void)?
    var onPreviewTheme: ((String?) -> Void)?
    var onRainbowToggle: ((Bool) -> Void)?
    var onRecolorBranches: (() -> Void)?
    var onAppearance: ((AppearanceMode?) -> Void)?
    var onDefaultTheme: ((String) -> Void)?
}
