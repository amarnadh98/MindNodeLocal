import AppKit
import CanvasKit

/// Document-window chrome (SPEC §4.1/§7.1): the customizable
/// unified-compact toolbar — every item routes to the SAME
/// first-responder actions the menus and keyboard use (§14.1) and
/// validates by selection — plus the F-CAN-6 minimap wiring and the
/// ⌥⌘M toggle persisted in UserDefaults.
extension NSToolbarItem.Identifier {
    /// §4.1 editing group.
    static let addChild = NSToolbarItem.Identifier("ArborToolbarAddChild")
    /// Always creates a sibling below (VoiceOver's semantics — ⏎'s
    /// enter-edit rule is keyboard-only).
    static let addSibling = NSToolbarItem.Identifier("ArborToolbarAddSibling")
    static let deleteSelection = NSToolbarItem.Identifier("ArborToolbarDelete")
    static let foldUnfold = NSToolbarItem.Identifier("ArborToolbarFoldUnfold")
    /// F-CAN-2 zoom group.
    static let zoomOut = NSToolbarItem.Identifier("ArborToolbarZoomOut")
    static let zoomPercent = NSToolbarItem.Identifier("ArborToolbarZoomPercent")
    static let zoomIn = NSToolbarItem.Identifier("ArborToolbarZoomIn")
    static let zoomToFit = NSToolbarItem.Identifier("ArborToolbarZoomToFit")
    /// F-CAN-6.
    static let minimap = NSToolbarItem.Identifier("ArborToolbarMinimap")
    /// M6 (F-PRE-1): the ▶︎ Present item (§4.1 toolbar order).
    static let present = NSToolbarItem.Identifier("ArborToolbarPresent")
    /// M6 (F-PRE-2): the Slides sidebar toggle.
    static let slidesSidebar = NSToolbarItem.Identifier("ArborToolbarSlidesSidebar")
}

@MainActor
extension DocumentWindowController {
    /// ⌥⌘M's persisted preference (per user, not per document).
    static let minimapDefaultsKey = "ShowsMinimap"
    /// The toolbar's identifier — also the UserDefaults key its
    /// customization autosave lives under.
    static let toolbarAutosaveName = "ArborDocumentToolbar"

    /// The default item order (§4.1: editing left, zoom + minimap right
    /// of the flexible space).
    static let defaultToolbarItemOrder: [NSToolbarItem.Identifier] = [
        .addChild, .addSibling, .deleteSelection, .foldUnfold,
        .flexibleSpace,
        .present, .slidesSidebar,
        .zoomOut, .zoomPercent, .zoomIn, .zoomToFit, .minimap,
    ]

    // MARK: install (called from init)

    func installChrome() {
        installToolbar()
        installMinimap()
    }

    private func installToolbar() {
        guard let window else { return }
        // Capture the designed content size before the toolbar exists.
        let designed = window.contentView?.frame.size ?? .zero
        let toolbar = NSToolbar(identifier: Self.toolbarAutosaveName)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        // Persisted per user under the identifier (§14.1).
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        documentToolbar = toolbar
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        // A unified-compact toolbar rides in the title bar, but AppKit
        // still grows the content view when one is assigned; re-pin the
        // designed content size (frameRect prices in the new chrome) so
        // the canvas keeps its 900×600 area instead of silently
        // resizing under the camera math.
        if designed.width > 0, designed.height > 0 {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: designed))
            frame.origin = window.frame.origin
            window.setFrame(frame, display: false)
        }
    }

    private func installMinimap() {
        // Anchored bottom-right of the flipped canvas; the autoresizing
        // margins pin it to the max edges.
        let frame = NSRect(
            x: canvas.bounds.maxX - MinimapView.defaultSize.width - MinimapView.canvasMargin,
            y: canvas.bounds.maxY - MinimapView.defaultSize.height - MinimapView.canvasMargin,
            width: MinimapView.defaultSize.width,
            height: MinimapView.defaultSize.height)
        let minimap = MinimapView(frame: frame)
        minimap.autoresizingMask = [.minXMargin, .minYMargin]
        canvas.addSubview(minimap)
        self.minimap = minimap
        minimap.preferredVisible =
            (UserDefaults.standard.object(forKey: Self.minimapDefaultsKey) as? Bool) ?? true
        minimap.onCameraChange = { [weak self] camera in
            self?.canvas.camera = camera
        }
    }

    // MARK: camera/zoom sync (chained into canvas.onCameraChange)

    /// Camera moves: the minimap re-strokes its viewport rect and the
    /// toolbar's zoom % follows.
    func syncMinimapCamera() {
        minimap?.camera = canvas.camera
        syncZoomPercentage()
    }

    /// The zoom item's accessory (§4.1): the pull-down's live percentage.
    func syncZoomPercentage() {
        let percent = Self.zoomPercent(of: canvas.camera.scale)
        zoomPopupButton?.title = "\(percent)%"
        zoomPopupButton?.menu?.items.first?.title = "\(percent)%"
    }

    static func zoomPercent(of scale: CGFloat) -> Int {
        Int((min(max(scale, 0.1), 4) * 100).rounded())
    }

    // MARK: actions

    /// ⌥⌘M (View ▸ Minimap, F-CAN-6): flips the persisted preference
    /// and applies it to this window's minimap. Each frontmost window's
    /// controller handles its own toggle; the preference is global.
    @objc func toggleMinimapAction(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let current = (defaults.object(forKey: Self.minimapDefaultsKey) as? Bool) ?? true
        let updated = !current
        defaults.set(updated, forKey: Self.minimapDefaultsKey)
        minimap?.preferredVisible = updated
    }

    /// The zoom % menu's steps (F-CAN-2): pans-free zoom around the
    /// viewport centre through the canvas's existing zoom path.
    @objc func zoomStepAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        canvas.zoomToScale(CGFloat(menuItem.tag) / 100)
    }

    // MARK: item construction

    private func borderedItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        tooltip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = nil
        item.action = action
        return item
    }

    private func zoomPopupItem() -> NSToolbarItem {
        // A pull-down popup whose face shows the live zoom %; its own
        // title is the display (usesItemFromMenu = false), so camera
        // moves only rewrite the title, never the menu.
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.usesItemFromMenu = false
        popup.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // The first item rides along at the top of the pulled-down menu
        // (disabled, showing the current zoom) — standard pull-down form.
        let current = NSMenuItem(title: "100%", action: nil, keyEquivalent: "")
        current.isEnabled = false
        let menu = NSMenu(title: "Zoom")
        menu.addItem(current)
        menu.addItem(.separator())
        for step in CanvasView.zoomSteps {
            let percent = Self.zoomPercent(of: step)
            let stepItem = NSMenuItem(
                title: "\(percent)%", action: #selector(zoomStepAction(_:)), keyEquivalent: "")
            stepItem.tag = percent
            menu.addItem(stepItem)
        }
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Fit", action: #selector(CanvasView.zoomToFitAction(_:)),
                keyEquivalent: ""))
        popup.menu = menu

        let item = NSToolbarItem(itemIdentifier: .zoomPercent)
        item.label = "Zoom"
        item.paletteLabel = "Zoom"
        item.toolTip = "Choose the zoom level"
        item.view = popup
        zoomPopupButton = popup
        syncZoomPercentage()
        return item
    }

    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .addChild:
            return borderedItem(
                identifier: .addChild, label: "Add Child", symbol: "plus.circle",
                tooltip: "Add a child node (⇥)",
                action: #selector(addChildAction(_:)))
        case .addSibling:
            return borderedItem(
                identifier: .addSibling, label: "Add Sibling", symbol: "plus.square.on.square",
                tooltip: "Add a sibling below (⏎)",
                action: #selector(addSiblingBelow(_:)))
        case .deleteSelection:
            return borderedItem(
                identifier: .deleteSelection, label: "Delete", symbol: "trash",
                tooltip: "Delete the selection (⌫)",
                action: #selector(deleteSubtreeAction(_:)))
        case .foldUnfold:
            return borderedItem(
                identifier: .foldUnfold, label: "Fold/Unfold", symbol: "chevron.down.circle",
                tooltip: "Fold or unfold the selection (⌥.)",
                action: #selector(toggleFoldAction(_:)))
        case .zoomOut:
            return borderedItem(
                identifier: .zoomOut, label: "Zoom Out", symbol: "minus.magnifyingglass",
                tooltip: "Zoom Out (⌘−)",
                action: #selector(CanvasView.zoomOutAction(_:)))
        case .zoomIn:
            return borderedItem(
                identifier: .zoomIn, label: "Zoom In", symbol: "plus.magnifyingglass",
                tooltip: "Zoom In (⌘+)",
                action: #selector(CanvasView.zoomInAction(_:)))
        case .zoomToFit:
            return borderedItem(
                identifier: .zoomToFit, label: "Zoom to Fit",
                symbol: "arrow.up.and.down.and.arrow.left.and.right",
                tooltip: "Zoom to Fit (⌘9)",
                action: #selector(CanvasView.zoomToFitAction(_:)))
        case .minimap:
            return borderedItem(
                identifier: .minimap, label: "Minimap", symbol: "map",
                tooltip: "Show or hide the minimap (⌥⌘M)",
                action: #selector(toggleMinimapAction(_:)))
        case .present:
            return borderedItem(
                identifier: .present, label: "Present", symbol: "play.fill",
                tooltip: "Present this map (⌥⌘⏎)",
                action: #selector(presentAction(_:)))
        case .slidesSidebar:
            return borderedItem(
                identifier: .slidesSidebar, label: "Slides", symbol: "rectangle.stack.badge.play",
                tooltip: "Show or hide the Slides sidebar (⌃⌘S)",
                action: #selector(toggleSlidesSidebarAction(_:)))
        case .zoomPercent:
            return zoomPopupItem()
        default:
            return nil
        }
    }

    // MARK: validation (by selection — §14.1)

    /// The first selected node with children, and whether it is folded —
    /// the Fold item's target state. Nil while editing (the keys belong
    /// to the overlay then) or with no foldable selection.
    private func foldSelectionState() -> (id: String, folded: Bool)? {
        guard !canvas.isEditing, let model = (document as? MapDocument)?.store.model else {
            return nil
        }
        for id in canvas.selection.sorted() {
            guard let node = model.nodes[id], !node.children.isEmpty else { continue }
            return (id, node.folded)
        }
        return nil
    }

    /// NSToolbarItemValidation: nil-target items validate through the
    /// responder chain, which lands here (the window controller).
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .addChild, .addSibling, .deleteSelection:
            // The actions commit-and-create (or edit text) while a node
            // is being edited, so editing keeps them live.
            return canvas.isEditing || !canvas.selection.isEmpty
        case .foldUnfold:
            if let state = foldSelectionState() {
                item.label = state.folded ? "Unfold" : "Fold"
                item.image = NSImage(
                    systemSymbolName: state.folded ? "chevron.right.circle" : "chevron.down.circle",
                    accessibilityDescription: item.label)
            } else {
                item.label = "Fold/Unfold"
            }
            return canvas.isEditing || foldSelectionState() != nil
        default:
            // Zoom and minimap work with nothing selected.
            return true
        }
    }

    /// NSMenuItemValidation: the View ▸ Minimap checkmark, the zoom
    /// menu's step marks, the AI menu's availability (F-AI-1) and the
    /// per-document cloud flag's state (SPEC §12); editing actions
    /// disable with no selection.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMinimapAction(_:)):
            menuItem.state =
                ((UserDefaults.standard.object(forKey: Self.minimapDefaultsKey) as? Bool) ?? true)
                ? .on : .off
            return true
        case #selector(zoomStepAction(_:)):
            menuItem.state =
                menuItem.tag == Self.zoomPercent(of: canvas.camera.scale) ? .on : .off
            return true
        case #selector(resumePresentationAction(_:)):
            // ⌘⏎ (F-PRE-6) only means "resume" while a run is paused
            // into live edit; otherwise ⌘⏎ keeps its editing meaning.
            return presentationCoordinatorBox?.isLiveEditPaused == true
        case #selector(toggleSlidesSidebarAction(_:)):
            menuItem.state = slidesSidebarBox?.isVisible == true ? .on : .off
        case #selector(aiExpandAction(_:)), #selector(generateMapAction(_:)),
            #selector(aiSummarizeBranchAction(_:)), #selector(aiRewriteTitlesAction(_:)),
            #selector(aiSuggestTitleAction(_:)):
            // F-AI-1: with AI off entirely the items hide, not just
            // disable — see AIController.menuAvailable and the AI
            // menu's delegate in AppDelegate.
            menuItem.isHidden = !ai.menuAvailable
            return ai.menuAvailable
        case #selector(aiToggleNeverSendToCloudAction(_:)):
            menuItem.state = ai.neverSendToCloud ? .on : .off
            return true
        case #selector(deleteSubtreeAction(_:)), #selector(deleteNodeOnlyAction(_:)),
            #selector(addChildAction(_:)), #selector(addSiblingBelow(_:)),
            #selector(addSiblingAboveAction(_:)), #selector(insertParentAction(_:)):
            return canvas.isEditing || !canvas.selection.isEmpty
        case #selector(toggleFoldAction(_:)):
            return canvas.isEditing || foldSelectionState() != nil
        case #selector(makeStudyDeckAction(_:)), #selector(setCardPolicyAction(_:)),
            #selector(makeClozeAction(_:)), #selector(studyBranchAction(_:)),
            #selector(studyDocumentAction(_:)), #selector(studyDueAction(_:)),
            #selector(studyWeakestBranchAction(_:)), #selector(toggleMasteryOverlayAction(_:)),
            #selector(showStudyDashboardAction(_:)):
            // F-STD: the study menu's own validation (checkmark states,
            // editing-sensitive enabling) lives with the actions.
            return validateStudyMenuItem(menuItem)
        default:
            return validateFocusFindMenuItem(menuItem) ?? true
        }
    }
}

/// The customization surface (§4.1: allowsUserCustomization) and the
/// item factory.
extension DocumentWindowController: NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultToolbarItemOrder
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + Self.defaultToolbarItemOrder.filter { $0 != .flexibleSpace }
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        toolbarItem(for: identifier)
    }
}
