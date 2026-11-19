import AppKit
import CanvasKit
import Combine
import MapCore
import MapRender
import SwiftUI

/// The inspector pane (SPEC §4.1, F-STY-2/3/4/6/7/8): a trailing,
/// inspector-style `NSSplitViewItem` hosting SwiftUI (allowed for the
/// inspector per the stack rules), hidden by default with its
/// visibility persisted in `UserDefaults`. It owns no model state —
/// every mutation routes through the host document's `MapStore` as one
/// `MapCommand` (one undo step), and hover previews are view-only.
@MainActor
final class InspectorPaneController {
    let splitController = NSSplitViewController()
    let model = InspectorModel()
    private var hosting: NSHostingController<InspectorView>?

    private(set) var inspectorItem: NSSplitViewItem?

    /// The window hosting this pane; weak — the window controller owns
    /// the pane, never the other way around.
    weak var host: DocumentWindowController?

    var isVisible: Bool {
        inspectorItem?.isCollapsed == false
    }

    // MARK: split view (SPEC §4.1: Inspector right, hidden by default)

    /// Builds the window's content: the canvas as the main split item,
    /// this pane as a trailing inspector item.
    func install(canvas: NSView, in window: NSWindow) {
        let canvasController = NSViewController()
        canvasController.view = canvas
        let canvasItem = NSSplitViewItem(viewController: canvasController)
        canvasItem.canCollapse = false
        canvasItem.holdingPriority = .init(999)
        splitController.addSplitViewItem(canvasItem)

        let content = InspectorView(model: model)
        let hosting = NSHostingController(rootView: content)
        self.hosting = hosting
        hosting.preferredContentSize = NSSize(width: 300, height: 600)
        let inspector = NSSplitViewItem(inspectorWithViewController: hosting)
        inspector.minimumThickness = 260
        inspector.maximumThickness = 400
        inspector.canCollapse = true
        // SPEC §4.1: hidden by default; setting `collapsed` before the
        // item joins the controller keeps it collapsed on first layout.
        inspector.isCollapsed = !DocumentPreferences.inspectorVisible
        splitController.addSplitViewItem(inspector)
        inspectorItem = inspector

        window.contentViewController = splitController
    }

    /// ⌥⌘I: shows/hides the pane, persisting the choice. Routed through
    /// `NSSplitViewController.toggleInspector(_:)` (macOS 14+), the
    /// sanctioned inspector toggle — the standard collapse animation
    /// included.
    @objc func toggleVisibility() {
        let wasCollapsed = inspectorItem?.isCollapsed ?? true
        splitController.toggleInspector(nil)
        DocumentPreferences.inspectorVisible = wasCollapsed
    }

    // MARK: refresh (after every model or selection change)

    func refresh() {
        guard let host, let store = host.inspectorStore else { return }
        let canvasSelection = host.canvas.selection.sorted()
        var nodes: [InspectorModel.SelectedNode] = []
        for id in canvasSelection {
            guard let node = store.model.nodes[id] else { continue }
            let level = Self.level(of: id, in: store.model)
            nodes.append(
                InspectorModel.SelectedNode(id: id, level: level, storedPatch: node.style))
        }
        model.selectedNodes = nodes

        model.themeID = store.model.theme?.id ?? BuiltInThemes.defaultID
        model.appearance = store.model.appearance ?? .auto
        model.rainbowOverride = store.model.theme?.overrides?.rainbowBranches
        model.defaultThemeID = DocumentPreferences.defaultThemeID
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
            guard let self, let store = self.host?.inspectorStore else { return }
            // An explicit document override either way (F-STY-8's
            // "toggle in the theme" — built-in themes are immutable
            // data, so the toggle persists as a stored override).
            var patch = store.model.theme?.overrides ?? ThemePatch()
            patch.rainbowBranches = on
            self.perform(.setThemeOverrides(overrides: patch))
        }
        model.onRecolorBranches = { [weak self] in
            guard let self, let store = self.host?.inspectorStore else { return }
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
    }

    /// Keeps every other stored theme override (canvas color, palette)
    /// intact when the rainbow toggle lands.
    private func merged(patch: ThemePatch, into model: MapModel) -> ThemePatch {
        var result = model.theme?.overrides ?? ThemePatch()
        result.rainbowBranches = patch.rainbowBranches
        return result
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
        guard let store = host?.inspectorStore else { return }
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
}

/// The store every inspector mutation goes through (SPEC §11.3).
@MainActor
extension DocumentWindowController {
    var inspectorStore: MapStore? {
        (document as? MapDocument)?.store
    }
}
