import AppKit
import CanvasKit
import Combine
import MapCore
import MapRender
import SwiftUI

/// The inspector pane (SPEC §4.1, F-STY-2/3/4/6/7/8, F-LAY-12): a
/// trailing, inspector-style split item hosting SwiftUI (allowed for
/// the inspector per the stack rules), hidden by default with its
/// visibility persisted in `DocumentPreferences`. It owns no model
/// state — every mutation routes through the host document's
/// `MapStore` as one `MapCommand` (one undo step), and hover previews
/// are view-only.
///
/// Window integration: the pane installs lazily — a window without it
/// keeps `window.contentView` exactly as the view modes built it (map,
/// outline, side-by-side); toggling wraps the CURRENT main view as the
/// split's main item, so ⌘1/⌘2/⌘3 keep working through the host's
/// `setMainContentView` and the canvas instance never rebuilds.
@MainActor
final class InspectorPaneController {
    let model = InspectorModel()
    private var hosting: NSHostingController<InspectorView>?
    private(set) var inspectorItem: NSSplitViewItem?
    private(set) var splitController: NSSplitViewController?
    private(set) var mainController: NSViewController?

    /// The window hosting this pane; weak — the window controller owns
    /// the pane, never the other way around.
    weak var host: DocumentWindowController?

    var isInstalled: Bool { splitController != nil }
    var isVisible: Bool { isInstalled && inspectorItem?.isCollapsed == false }

    // MARK: install / removal (SPEC §4.1: Inspector right, hidden by default)

    /// ⌥⌘I: shows/hides the pane, persisting the choice. Showing always
    /// expands the item (the toggle's own semantics — the stored
    /// preference only decides the window-open state).
    @objc func toggleVisibility() {
        guard let host, let window = host.window else { return }
        if isInstalled {
            uninstall(from: window)
        } else {
            install(in: window, collapsed: false)
        }
        DocumentPreferences.inspectorVisible = isVisible
        host.documentToolbar?.validateVisibleItems()
    }

    /// The first-show path for windows opened with the persisted
    /// preference on (`showWindow` calls this).
    func installIfNeeded() {
        guard !isInstalled, DocumentPreferences.inspectorVisible,
            let window = host?.window
        else { return }
        install(in: window, collapsed: false)
    }

    private func install(in window: NSWindow, collapsed: Bool) {
        guard splitController == nil else { return }
        let main = NSViewController()
        main.view = window.contentView ?? NSView()
        let mainItem = NSSplitViewItem(viewController: main)
        mainItem.canCollapse = false
        mainItem.holdingPriority = .init(999)
        mainController = main

        let content = InspectorView(model: model)
        let hosting = NSHostingController(rootView: content)
        self.hosting = hosting
        hosting.preferredContentSize = NSSize(width: 300, height: 600)
        let inspector = NSSplitViewItem(inspectorWithViewController: hosting)
        inspector.minimumThickness = 260
        inspector.maximumThickness = 420
        inspector.canCollapse = true
        // Setting `collapsed` before the item joins the controller pins
        // its first layout (SPEC §4.1: hidden unless toggled on).
        inspector.isCollapsed = collapsed
        inspectorItem = inspector

        let split = NSSplitViewController()
        split.addSplitViewItem(mainItem)
        split.addSplitViewItem(inspector)
        splitController = split
        window.contentViewController = split
    }

    private func uninstall(from window: NSWindow) {
        guard let split = splitController else { return }
        let mainView = mainController?.view
        window.contentViewController = nil
        if let mainView {
            window.contentView = mainView
        }
        splitController = nil
        inspectorItem = nil
        mainController = nil
        hosting = nil
        _ = split
    }

    /// The view-mode swap's landing pad (⌘1/⌘2/⌘3): with the pane
    /// installed the main item's view changes in place; without it the
    /// host assigns `window.contentView` directly.
    func setMainView(_ view: NSView) {
        mainController?.view = view
    }

    // MARK: refresh (after every model or selection change)

    func refresh() {
        guard let host, let store = host.store else { return }
        let canvasSelection = host.canvas.selection.sorted()
        var nodes: [InspectorModel.SelectedNode] = []
        for id in canvasSelection {
            guard let node = store.model.nodes[id] else { continue }
            let level = Self.level(of: id, in: store.model)
            nodes.append(
                InspectorModel.SelectedNode(id: id, level: level, storedPatch: node.style))
        }
        model.selectedNodes = nodes

        // F-LAY-3/4: structure is a root-tree property — the selection's
        // root carries it.
        let structureRoot = Self.rootID(
            of: canvasSelection.first ?? store.model.roots.first, in: store.model)
        model.structureRootID = structureRoot
        model.structureOverride = structureRoot.flatMap { store.model.nodes[$0]?.structure }

        model.themeID = store.model.theme?.id ?? BuiltInThemes.defaultID
        model.appearance = store.model.appearance ?? .auto
        model.rainbowOverride = store.model.theme?.overrides?.rainbowBranches
        model.canvasColorOverride = store.model.theme?.overrides?.canvasColor
        model.defaultThemeID = DocumentPreferences.defaultThemeID
        model.showsTagPills = host.showsTagPills
        model.showsMinimap =
            (UserDefaults.standard.object(forKey: DocumentWindowController.minimapDefaultsKey)
                as? Bool) ?? true
        model.showsContextualBar = ContextualBarController.isEnabled
        model.spacingPreset = DocumentPreferences.spacingPreset
        model.customSiblingGap = DocumentPreferences.customSiblingGap
        model.customLevelGap = DocumentPreferences.customLevelGap
        wireActions()
    }

    /// (Re)binds the model's mutation closures; called on refresh so
    /// every command runs against the current store.
    private func wireActions() {
        model.onStylePatch = { [weak self] patch in
            self?.performStyleCommand { .setStyle(ids: $0, patch: patch) }
        }
        model.onResetKeys = { [weak self] keys in
            self?.performStyleCommand { .resetStyle(ids: $0, keys: keys) }
        }
        model.onStructure = { [weak self] structure in
            guard let self, let rootID = self.model.structureRootID else { return }
            self.perform(.setStructure(id: rootID, structure: structure))
        }
        model.onApplyTheme = { [weak self] id in
            self?.perform(.setTheme(id: id))
        }
        model.onPreviewTheme = { [weak self] id in
            guard let self, let host = self.host else { return }
            host.previewThemeID = id
            self.model.previewedThemeID = id
            host.updateScene(preserveCamera: true)
        }
        model.onRainbowToggle = { [weak self] on in
            guard let self, let store = self.host?.store else { return }
            // An explicit document override either way (F-STY-8's
            // "toggle in the theme" — built-in themes are immutable
            // data, so the toggle persists as a stored override).
            var patch = store.model.theme?.overrides ?? ThemePatch()
            patch.rainbowBranches = on
            self.perform(.setThemeOverrides(overrides: patch))
        }
        model.onCanvasColor = { [weak self] hex in
            guard let self, let store = self.host?.store else { return }
            var patch = store.model.theme?.overrides ?? ThemePatch()
            patch.canvasColor = hex
            self.perform(.setThemeOverrides(overrides: patch))
        }
        model.onRecolorBranches = { [weak self] in
            guard let self, let store = self.host?.store else { return }
            let commands = store.model.roots.map { MapCommand.recolorBranches(rootID: $0, in: store.model) }
            if let grouped = self.grouped("Recolor Branches", commands) {
                self.perform(grouped)
            }
        }
        model.onAppearance = { [weak self] mode in
            self?.perform(.setAppearance(mode))
        }
        model.onDefaultTheme = { id in
            DocumentPreferences.defaultThemeID = id
        }
        model.onSpacingPreset = { [weak self] preset in
            DocumentPreferences.spacingPreset = preset
            self?.model.spacingPreset = preset
            self?.host?.updateScene(preserveCamera: true)
        }
        model.onCustomGaps = { [weak self] sibling, level in
            DocumentPreferences.customSiblingGap = sibling
            DocumentPreferences.customLevelGap = level
            self?.model.customSiblingGap = sibling
            self?.model.customLevelGap = level
            self?.host?.updateScene(preserveCamera: true)
        }
        model.onShowsTagPills = { [weak self] on in
            guard let self, on != self.host?.showsTagPills else { return }
            self.host?.showTagPillsAction(nil)
            self.model.showsTagPills = on
        }
        model.onShowsMinimap = { [weak self] on in
            guard let self else { return }
            let defaults = UserDefaults.standard
            let key = DocumentWindowController.minimapDefaultsKey
            if (defaults.object(forKey: key) as? Bool ?? true) != on {
                defaults.set(on, forKey: key)
                self.host?.minimap?.preferredVisible = on
            }
            self.model.showsMinimap = on
        }
        model.onShowsContextualBar = { [weak self] on in
            UserDefaults.standard.set(on, forKey: DocumentPreferences.contextualBarKey)
            self?.model.showsContextualBar = on
            guard let self else { return }
            if on {
                self.host?.contextualBar.selectionDidChange()
            } else {
                self.host?.contextualBar.dismiss()
            }
        }
    }

    private func grouped(_ name: String, _ commands: [MapCommand]) -> MapCommand? {
        switch commands.count {
        case 0:
            nil
        case 1:
            commands[0]
        default:
            .group(name: name, commands: commands)
        }
    }

    private func performStyleCommand(_ make: ([String]) -> MapCommand) {
        guard !model.selectedIDs.isEmpty else { return }
        perform(make(model.selectedIDs))
    }

    /// One `MapStore.perform` = one undo step; after it the host
    /// rebuilds the scene through its own change pipeline.
    func perform(_ command: MapCommand) {
        guard let store = host?.store else { return }
        try? store.perform(command)
    }

    // MARK: helpers

    private static func level(of id: String, in model: MapModel) -> Int {
        var level = 0
        var current = id
        while let parent = model.nodes[current]?.parent, parent != current {
            level += 1
            current = parent
        }
        return level
    }

    private static func rootID(of id: String?, in model: MapModel) -> String? {
        guard let id, model.nodes[id] != nil else { return nil }
        var current = id
        while let parent = model.nodes[current]?.parent {
            current = parent
        }
        return current
    }
}
