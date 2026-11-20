import AppKit
import CoreGraphics
import MapCore
import MapRender
import MapStudy

/// The layer-tree-facing surface of the canvas (SPEC §11.4): hosting,
/// scene application, the selection rings and the rubber-band overlay,
/// plus the CA-compositor pixel capture the hosted tests use.
extension CanvasView {
    /// The appearance variant the canvas currently renders for (the
    /// host resolves the document theme against this).
    public var effectiveVariant: ThemeVariant {
        let names = [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua]
        let best = effectiveAppearance.bestMatch(from: names) ?? .aqua
        return best == .darkAqua ? .dark : .light
    }
    /// Captures the view's current appearance through CA's own
    /// compositor. Layer-hosting views can't rely on AppKit's legacy
    /// caching path: it composes camera-scaled contents displaced and
    /// mirrored, so the view renders its actual layer tree into the
    /// bitmap instead.
    public override func cacheDisplay(in rect: NSRect, to bitmap: NSBitmapImageRep) {
        guard let nsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            super.cacheDisplay(in: rect, to: bitmap)
            return
        }
        let context = nsContext.cgContext
        context.saveGState()
        // The layer tree carries its own flipped geometry; CA's
        // compositor maps it straight into the rep's y-up context.
        layerTree.root.render(in: context)
        context.restoreGState()
    }

    /// The display scale backing this view (1× headless).
    var backingScale: CGFloat {
        window?.backingScaleFactor ?? 1
    }

    /// Hosts the layer tree under the view's backing layer once one
    /// exists (layer-backed NSViews create it at the first display
    /// pass; until then `needsLayout` keeps the request alive).
    func ensureTreeHosted() {
        if layerTree.root.superlayer == nil {
            guard let backing = layer else {
                needsLayout = true
                return
            }
            layerTree.root.frame = CGRect(origin: .zero, size: bounds.size)
            backing.addSublayer(layerTree.root)
        }
        if ghostOverlay.container.superlayer == nil {
            layerTree.root.addSublayer(ghostOverlay.container)
        }
    }

    /// Applies the current scene to the layer tree (diffing against
    /// the tree's previous scene and animating per §7.6 when allowed).
    /// `precomputedDiff` skips the differ when the caller already ran
    /// it (the grid sync).
    func applyScene(animated: Bool, precomputedDiff: SceneDiff? = nil) {
        ensureTreeHosted()
        guard let scene else {
            layerTree.clear()
            return
        }
        var context = ApplyContext(
            scene: scene, grid: grid, camera: camera, viewport: bounds.size)
        context.backingScale = backingScale
        context.animated = animated
        context.reduceMotion = MotionPreferences.reduceMotion
        context.selection = selection
        context.selectionColor = selectionColor
        context.selectedConnections = selectedConnectionIDs
        context.editingNodeID = nodeTextEditor.editingNodeID
        context.diff = precomputedDiff
        context.highlightedIDs = highlightedIDs()
        layerTree.apply(context)
        // F-FOC: rings follow the new frames and dimming re-applies
        // (freshly realized layers start at full opacity).
        overlays.sceneDidApply(self)
    }

    /// The ids kept at full opacity in highlight mode (F-TAG-2/F-TSK-5);
    /// nil when no mode is active.
    func highlightedIDs() -> Set<String>? {
        switch highlight {
        case .tags(let tagIDs):
            guard let model = dragModel else { return nil }
            let wanted = tagIDs
            var matches: Set<String> = []
            for (id, node) in model.nodes {
                if let tags = node.tags, tags.contains(where: { wanted.contains($0) }) {
                    matches.insert(id)
                }
            }
            return matches
        case .tasks:
            guard let model = dragModel else { return nil }
            var matches: Set<String> = []
            for (id, node) in model.nodes where node.task != nil {
                matches.insert(id)
            }
            return matches
        case .filter(let filter):
            guard let model = dragModel else { return nil }
            return FilterEngine.matchingIDs(
                model: model, filter: filter, mastery: filterMastery, now: filterNow)
        case nil:
            return nil
        }
    }

    /// F-TAG-3's dim mode needs the document's mastery report pinned at
    /// one instant (a `mastery:` term stays deterministic through a
    /// rebuild). Host-owned view state; nil disables mastery terms.
    public var filterMastery: MasteryReport? {
        get { decorationActions.filterMastery }
        set { decorationActions.filterMastery = newValue }
    }

    /// The `now` the filter's mastery and due terms evaluate at
    /// (host-pinned; defaults to the build moment).
    public var filterNow: Date {
        get { decorationActions.filterNow }
        set { decorationActions.filterNow = newValue }
    }

    /// Selection rings follow every selection mutation (they live in
    /// the layer tree, not in the view's drawing).
    func syncSelectionRings() {
        layerTree.updateSelection(selection, color: selectionColor, camera: camera)
    }

    /// The editing target changed (NodeTextEditor hook): hide or
    /// reveal the affected node's title in its raster (SPEC §11.4).
    func editingTargetDidChange() {
        layerTree.setEditingNode(
            nodeTextEditor.editingNodeID, camera: camera, backingScale: backingScale)
    }

    func updateRubberBandLayer() {
        if let rect = rubberBandRect {
            rubberBandLayer.path = CGPath(rect: rect, transform: nil)
            rubberBandLayer.isHidden = false
        } else {
            rubberBandLayer.path = nil
            rubberBandLayer.isHidden = true
        }
    }

    var selectionColor: CGColor {
        NSColor.controlAccentColor.cgColor
    }
}
