import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import QuartzCore

/// One scene application to the layer tree: the scene and its grid,
/// where the camera looks, and the presentation state that rides
/// along. `animated: false` opts out of §7.6 relayout motion (initial
/// load, live typing growth); Reduce Motion is the caller's to pass.
/// `diff` may carry a precomputed old→new diff (the canvas view computes
/// it once to update its spatial grid before applying); nil recomputes
/// it here.
@MainActor
public struct ApplyContext {
    public let scene: CanvasScene
    public let grid: SpatialGrid
    public let camera: Camera
    public let viewport: CGSize
    public var backingScale: CGFloat = 1
    public var animated = true
    public var reduceMotion = false
    public var selection: Set<String> = []
    public var selectionColor: CGColor = CGColor(gray: 0, alpha: 1)
    /// F-REL-1: the selected connections (rendered with a halo).
    public var selectedConnections: Set<String> = []
    public var editingNodeID: String?
    public var diff: SceneDiff? = nil
    /// F-TAG-2 / F-TSK-5 highlight mode: the ids that stay at full
    /// opacity; every other node layer dims to 25%. `nil` = no
    /// highlight (view state, never a model mutation).
    public var highlightedIDs: Set<String>? = nil

    public init(scene: CanvasScene, grid: SpatialGrid, camera: Camera, viewport: CGSize) {
        self.scene = scene
        self.grid = grid
        self.camera = camera
        self.viewport = viewport
    }
}

/// The virtualized layer tree behind the canvas (SPEC §11.4): one
/// pooled `CALayer` per *visible* node (visible rect + 50% margin
/// through the `SpatialGrid`), its contents rasterized by the shared
/// `NodeRenderer`, and one `CAShapeLayer` per visible branch (tapered =
/// filled path). Layers re-raster only on content/style change; a
/// relayout springs nodes to their new frames and morphs branch paths
/// (identical element structure, so animating `path` is legal).
///
/// The camera is applied per layer rather than as one
/// `sublayerTransform`: on this toolchain a shared sublayer transform
/// mis-composes layer contents (rasters land cropped and displaced
/// under any inherited scale), while each layer's own transform
/// composes them pixel-perfectly. The §11.4 invariant is unchanged —
/// pan and zoom rewrite placements and transforms only, never a
/// raster; the 120 ms post-settle pass restores sharpness.
///
/// The tree never needs a window: everything except the implicit
/// animation clock is headless, which is what the pool, culling and
/// budget tests drive directly.
@MainActor
public final class CanvasLayerTree {
    /// §11.4: below this zoom, nodes render as colored capsules
    /// without text.
    public static let lodThreshold: CGFloat = 0.35
    /// §11.4: the visible rect grows by 50% of the viewport per edge
    /// before culling.
    public static let marginFraction: CGFloat = 0.5
    /// Raster sharpness ceiling (§11.4: contentsScale clamp 1…8).
    public static let maxRasterScale: CGFloat = 8
    /// §11.4: after a zoom gesture settles, wait 120 ms before
    /// re-rasterizing the visible layers.
    public static let zoomSettleDelay: Duration = .milliseconds(120)
    /// Pool caps keep recycled layers bounded while panning across a
    /// huge map.
    public static let nodePoolCap = 512
    public static let branchPoolCap = 1_024
    /// How long a faded-out layer may linger before the sweep
    /// recycles it (the 160 ms delete fade plus slack).
    static let dyingSweepDelay: Duration = .milliseconds(240)

    var scene: CanvasScene?
    private var grid = SpatialGrid()
    private var editingID: String?
    var lastScale: CGFloat = 1

    /// The tree's root: paints the canvas background and hosts the
    /// camera-transformed content. Added to the view's backing layer;
    /// `isGeometryFlipped` mirrors the flipped view (AppKit does not
    /// propagate flippedness to sublayers) so model space (y-down)
    /// maps straight onto layer positions.
    public let root = CALayer()
    let content = CALayer()
    /// F-STD-6: the mastery overlay rides the content layer above node
    /// rasters; the host assigns its marks table.
    public let mastery = MasteryOverlay()
    var masteryMarks: [String: MasteryMark]?
    /// M6 (F-PRE/§10): the presentation/recall overlay. Stored on the
    /// tree so layers realized later by culling pick their state up in
    /// `configureLayer`/`configureBranchLayer`; applied and animated by
    /// CanvasLayerTree+Reveal.swift.
    var revealOverlay: RevealOverlay?
    /// F-TAG-2/F-TSK-5: ids kept at full opacity while highlight mode
    /// dims every other layer to 25% (nil = no highlight).
    var highlightedIDs: Set<String>?

    var nodeLayers: [String: NodeVisualLayer] = [:]
    var branchLayers: [BranchKey: BranchVisualLayer] = [:]
    var nodePool: [NodeVisualLayer] = []
    var branchPool: [BranchVisualLayer] = []
    /// Relation overlay layers (F-REL-1/2/3), keyed by overlay id.
    var relationLayers: [String: RelationVisualLayer] = [:]
    var relationPool: [RelationVisualLayer] = []
    /// The connection ids the apply marked selected — carried through
    /// camera updates so relation re-rasters keep their halos.
    var selectedConnections: Set<String> = []
    /// F-LAY-14: the folded-count pills of the visible folded nodes
    /// (model-space frames for hit-testing, layers for drawing — the
    /// same realize/recycle contract the rings use).
    var foldedPillLayers: [String: FoldedPillLayer] = [:]
    var foldedPillFrames: [String: CGRect] = [:]
    /// Fading-out layers of removed nodes/branches, recycled when their
    /// 160 ms window closes (or on the next apply at the latest).
    var dyingNodes: [String: NodeVisualLayer] = [:]
    var dyingBranches: [BranchVisualLayer] = []
    private var selectionRings: [String: CAShapeLayer] = [:]
    let addHandleOverlay = AddHandleOverlay()
    var settleTask: Task<Void, Never>?
    var dyingSweepTask: Task<Void, Never>?

    public var measurer: TextMeasurer = SceneRenderer.sharedMeasurer

    /// Test instrumentation: layers ever allocated, so pool reuse is
    /// observable while panning.
    var allocatedNodeLayers = 0
    var allocatedBranchLayers = 0
    var allocatedRelationLayers = 0
    var pooledNodeLayerReuses = 0
    var pooledRelationLayerReuses = 0

    public var activeNodeLayerIDs: Set<String> { Set(nodeLayers.keys) }
    public var pooledNodeLayerCount: Int { nodePool.count }

    init() {
        root.isGeometryFlipped = true
        root.masksToBounds = false
        content.isGeometryFlipped = true
        root.addSublayer(content)
        mastery.attach(to: content)
    }

    // MARK: camera

    /// §11.4's camera transform, applied per layer (see `applyCamera`):
    /// model → screen is `screenPoint` + a pure scale on nodes, and the
    /// full matrix on path layers.
    static func sublayerTransform(for camera: Camera) -> CATransform3D {
        CATransform3DTranslate(
            CATransform3DMakeScale(camera.scale, camera.scale, 1),
            -camera.origin.x, -camera.origin.y, 0)
    }

    /// The transform a path-carrying layer (branch, ring) needs: its
    /// geometry lives in model space.
    static func modelSpaceTransform(for camera: Camera) -> CATransform3D {
        sublayerTransform(for: camera)
    }

    /// The transform a node layer needs: pure scale about its anchor
    /// (the screen point of its model origin), so its raster contents
    /// compose pixel-perfectly at every zoom.
    static func nodeTransform(for camera: Camera) -> CATransform3D {
        CATransform3DMakeScale(camera.scale, camera.scale, 1)
    }

    /// The visible rect expanded by the culling margin (§11.4: 50% of
    /// the viewport per edge).
    public static func expandedVisibleRect(camera: Camera, viewport: CGSize) -> CGRect {
        let visible = camera.visibleRect(viewportSize: viewport)
        guard viewport.width > 0, viewport.height > 0, camera.scale > 0 else { return visible }
        let marginX = viewport.width / camera.scale * marginFraction
        let marginY = viewport.height / camera.scale * marginFraction
        return visible.insetBy(dx: -marginX, dy: -marginY)
    }

    /// The ids whose frames intersect the expanded visible rect.
    public static func visibleNodeIDs(
        grid: SpatialGrid, camera: Camera, viewport: CGSize
    ) -> Set<String> {
        grid.ids(intersecting: expandedVisibleRect(camera: camera, viewport: viewport))
    }

    // MARK: scene application

    /// Applies a new scene: diffs it against the previous one, recycles
    /// layers that left the visible set, re-rasters only content/style
    /// changes, and (unless `animated` is false or Reduce Motion is on)
    /// springs nodes to their new frames, fades new nodes in from the
    /// parent anchor, fades deleted ones out, and morphs branch paths.
    /// Returns the applied diff (the caller may have passed one in;
    /// either way it describes exactly what this apply changed — the
    /// canvas view feeds it to its spatial grid).
    @discardableResult
    public func apply(_ context: ApplyContext) -> SceneDiff {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let camera = context.camera
        let viewport = context.viewport
        let backingScale = context.backingScale

        // Fades from a previous apply have had their window; ids that
        // came back (e.g. an undo) lose the ghost immediately.
        for id in Array(dyingNodes.keys) {
            finishDyingNode(id)
        }
        for layer in dyingBranches {
            recycleBranchLayer(layer)
        }
        dyingBranches.removeAll()

        let oldScene = scene
        let diff = context.diff ?? SceneDiffer.diff(old: oldScene, new: context.scene)
        let plan =
            context.animated
            ? RelayoutPlanner.plan(
                old: oldScene, new: context.scene, diff: diff,
                reduceMotion: context.reduceMotion)
            : RelayoutPlan(moves: [:], branchMorphs: [])

        scene = context.scene
        grid = context.grid
        root.backgroundColor = context.scene.canvasColor
        editingID = context.editingNodeID
        highlightedIDs = context.highlightedIDs
        selectedConnections = context.selectedConnections
        // CA culls sublayers of a zero-bounds layer: the content layer
        // must cover the viewport even though its own content is empty.
        content.frame = CGRect(origin: .zero, size: viewport)

        // Deleted nodes and their branches fade out from their layers;
        // instant applies let the realize pass recycle them instead.
        for (id, move) in plan.moves {
            guard case .disappear = move, let layer = nodeLayers.removeValue(forKey: id) else {
                continue
            }
            startNodeDisappear(layer, camera: camera)
        }
        for branch in diff.branchesRemoved {
            let key = BranchKey(parentID: branch.parentID, childID: branch.childID)
            if let layer = branchLayers.removeValue(forKey: key) {
                startBranchDisappear(layer)
            }
        }
        if !dyingNodes.isEmpty || !dyingBranches.isEmpty {
            scheduleDyingSweep()
        }

        realizeVisible(
            camera: camera, viewport: viewport, backingScale: backingScale,
            plan: plan, reduceMotion: context.reduceMotion)
        syncFoldedPills(camera: camera, backingScale: backingScale)
        updateSelection(context.selection, color: context.selectionColor, camera: camera)
        mastery.update(masteryMarks, scene: context.scene, camera: camera)
        scheduleSettleIfNeeded(camera: camera, backingScale: backingScale)
        lastScale = camera.scale
        return diff
    }

    /// Pan/zoom: re-pins every visible layer at its new screen point and
    /// scale (a transform/placement write per layer — never a re-raster),
    /// re-culls the visible set (layers are pooled, never rebuilt from
    /// scratch) and schedules the 120 ms post-settle re-rasterize when
    /// the scale changed.
    public func updateCamera(camera: Camera, viewport: CGSize, backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        content.frame = CGRect(origin: .zero, size: viewport)
        realizeVisible(
            camera: camera, viewport: viewport, backingScale: backingScale,
            plan: nil, reduceMotion: true)
        syncFoldedPills(camera: camera, backingScale: backingScale)
        for ring in selectionRings.values {
            ring.transform = Self.modelSpaceTransform(for: camera)
            ring.lineWidth = 2.5 / camera.scale
        }
        addHandleOverlay.reposition(camera: camera)
        mastery.updateCamera(camera: camera)
        scheduleSettleIfNeeded(camera: camera, backingScale: backingScale)
        lastScale = camera.scale
    }

    /// The 120 ms post-settle pass (§11.4): re-rasterizes the visible
    /// layers at `contentsScale = backingScale × camera.scale`
    /// (clamped 1…8).
    public func rerasterizeVisible(camera: Camera, backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for layer in nodeLayers.values {
            guard let node = scene?.nodes[layer.nodeID] else { continue }
            configureContents(layer, node: node, camera: camera, backingScale: backingScale)
        }
        for layer in relationLayers.values {
            guard let overlay = layer.overlay else { continue }
            configureRelationContents(
                layer, overlay: overlay, camera: camera, backingScale: backingScale)
        }
    }

    /// Selection rings for the visible selected ids (§7.6's 120 ms
    /// fade rides CA's default action; ring geometry lives in model
    /// space so the camera transform carries it).
    public func updateSelection(_ selection: Set<String>, color: CGColor, camera: Camera) {
        let stale = selectionRings.filter { !selection.contains($0.key) || scene?.nodes[$0.key] == nil }
        for (id, ring) in stale {
            ring.removeFromSuperlayer()
            selectionRings.removeValue(forKey: id)
        }
        for id in selection.sorted() {
            guard let node = scene?.nodes[id], nodeLayers[id] != nil else { continue }
            let ring: CAShapeLayer
            if let existing = selectionRings[id] {
                ring = existing
            } else {
                ring = CAShapeLayer()
                ring.fillColor = nil
                ring.strokeColor = color
                ring.zPosition = 2
                ring.lineWidth = 2.5 / camera.scale
                ring.transform = Self.modelSpaceTransform(for: camera)
                content.addSublayer(ring)
                selectionRings[id] = ring
            }
            ring.path = Self.ringPath(node: node)
            ring.lineWidth = 2.5 / camera.scale
        }
        addHandleOverlay.update(selection: selection, in: self, camera: camera, color: color)
    }

    static func ringPath(node: SceneNode) -> CGPath {
        let ring = node.frame.insetBy(dx: -3, dy: -3)
        let radius: CGFloat = node.style.shape == .underline ? 4 : min(10, node.style.cornerRadius + 3)
        return CGPath(
            roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// The editing node hides its title (SPEC §11.4: the overlay draws
    /// the live text); re-rasters only the two layers involved, inside
    /// a disabled-actions transaction — a bare `contents` write rides
    /// CA's default 250 ms crossfade, leaving a stray animation on the
    /// layer through the session's first keystrokes.
    public func setEditingNode(_ id: String?, camera: Camera, backingScale: CGFloat) {
        guard id != editingID else { return }
        let previous = editingID
        editingID = id
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rerasterNode(previous, camera: camera, backingScale: backingScale)
        rerasterNode(id, camera: camera, backingScale: backingScale)
        CATransaction.commit()
    }

    /// Drops everything back into the pools (the scene was cleared).
    public func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for id in Array(dyingNodes.keys) {
            finishDyingNode(id)
        }
        dyingBranches.forEach(recycleBranchLayer)
        dyingBranches.removeAll()
        for (id, layer) in Array(nodeLayers) {
            nodeLayers.removeValue(forKey: id)
            recycleNodeLayer(layer)
        }
        for (key, layer) in Array(branchLayers) {
            branchLayers.removeValue(forKey: key)
            recycleBranchLayer(layer)
        }
        for (id, layer) in Array(relationLayers) {
            relationLayers.removeValue(forKey: id)
            recycleRelationLayer(layer)
        }
        for (id, ring) in Array(selectionRings) {
            ring.removeFromSuperlayer()
            selectionRings.removeValue(forKey: id)
        }
        addHandleOverlay.clear()
        for pill in foldedPillLayers.values {
            pill.removeFromSuperlayer()
        }
        foldedPillLayers.removeAll()
        foldedPillFrames.removeAll()
        mastery.clear()
        scene = nil
    }

    // MARK: realizing the visible set

    /// Brings the layer set in line with the expanded visible rect:
    /// recycles layers that left it, realizes new ones (from the
    /// pool), re-rasters only when the raster key changed, and
    /// attaches the relayout plan's animations.
    private func realizeVisible(
        camera: Camera,
        viewport: CGSize,
        backingScale: CGFloat,
        plan: RelayoutPlan?,
        reduceMotion: Bool
    ) {
        guard let scene else { return }
        let visibleIDs = Self.visibleNodeIDs(grid: grid, camera: camera, viewport: viewport)

        let left = nodeLayers.filter { !visibleIDs.contains($0.key) }
        for (id, layer) in left {
            nodeLayers.removeValue(forKey: id)
            recycleNodeLayer(layer)
        }

        for id in visibleIDs.sorted() {
            guard let node = scene.nodes[id] else { continue }
            if let existing = nodeLayers[id] {
                configureLayer(
                    existing, node: node, camera: camera, backingScale: backingScale,
                    plan: plan?.moves[id], reduceMotion: reduceMotion)
            } else {
                let layer = dequeueNodeLayer(id: id)
                nodeLayers[id] = layer
                content.addSublayer(layer)
                layer.zPosition = 1
                configureLayer(
                    layer, node: node, camera: camera, backingScale: backingScale,
                    plan: plan?.moves[id], reduceMotion: reduceMotion)
            }
        }

        let expanded = Self.expandedVisibleRect(camera: camera, viewport: viewport)
        var visibleBranches: [BranchKey: SceneBranch] = [:]
        for branch in scene.branches where expanded.intersects(Self.branchBounds(branch)) {
            visibleBranches[BranchKey(parentID: branch.parentID, childID: branch.childID)] = branch
        }

        let leftBranches = branchLayers.filter { visibleBranches[$0.key] == nil }
        for (key, layer) in leftBranches {
            branchLayers.removeValue(forKey: key)
            recycleBranchLayer(layer)
        }
        for key in visibleBranches.keys.sorted(by: { ($0.parentID, $0.childID) < ($1.parentID, $1.childID) }) {
            guard let branch = visibleBranches[key] else { continue }
            if let existing = branchLayers[key] {
                configureBranchLayer(existing, branch: branch, camera: camera, reduceMotion: reduceMotion)
            } else {
                let layer = dequeueBranchLayer(key: key)
                branchLayers[key] = layer
                content.addSublayer(layer)
                layer.zPosition = 0
                configureBranchLayer(layer, branch: branch, camera: camera, reduceMotion: reduceMotion)
            }
        }

        // F-REL-1/2/3: one pooled overlay layer per visible connection,
        // boundary or brace, culled by the same expanded rect (§11.4).
        realizeRelations(camera: camera, viewport: viewport, backingScale: backingScale)
    }

    /// Final geometry + contents for one node layer, plus its move
    /// animation when the plan says it moved.
    private func configureLayer(
        _ layer: NodeVisualLayer,
        node: SceneNode,
        camera: Camera,
        backingScale: CGFloat,
        plan move: RelayoutPlan.Move?,
        reduceMotion: Bool
    ) {
        let frame = node.frame
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        // F-TAG-2/F-TSK-5: outside the highlight set, the layer dims to
        // 25% (the base opacity CA animations settle back onto).
        layer.opacity = highlightedIDs.map { $0.contains(node.id) ? 1 : 0.25 } ?? 1
        // The camera per layer: the node's model origin pinned at its
        // screen point, scaled by the zoom. Pan and zoom change these
        // placements without ever re-rastering (§11.4).
        layer.transform = Self.nodeTransform(for: camera)

        switch move {
        case .appear(let fromAnchor, _):
            layer.position = camera.screenPoint(for: frame.origin)
            if !reduceMotion {
                for (index, animation) in RelayoutAnimator.appearAnimations(
                    camera: camera, frame: frame, fromAnchor: fromAnchor
                ).enumerated() {
                    layer.add(animation, forKey: "appear-\(index)")
                }
            }
        case .spring(let fromOrigin, let toOrigin):
            layer.position = camera.screenPoint(for: toOrigin)
            if !reduceMotion {
                let spring = RelayoutAnimator.relayoutSpring(
                    keyPath: "position",
                    from: NSValue(point: camera.screenPoint(for: fromOrigin)),
                    to: NSValue(point: camera.screenPoint(for: toOrigin)))
                layer.add(spring, forKey: "relayout-position")
            }
        case .disappear:
            break  // handled by the dying pass in apply
        case nil:
            layer.position = camera.screenPoint(for: frame.origin)
        }

        configureContents(layer, node: node, camera: camera, backingScale: backingScale)
        // M6 (F-PRE/§10): the reveal overlay wins over the default
        // opacity — ghosted, hidden and placeholder nodes ride
        // opacity only, never a re-raster. M7: placeholders carry the
        // F-STD-5 blur effect the same way (see +Reveal.swift).
        if let overlay = revealOverlay {
            layer.opacity = Float(overlay.nodeOpacity(node.id))
            applyRevealState(to: layer, id: node.id, overlay: overlay)
        }
    }

    /// Rasters the node through the shared `NodeRenderer` only when
    /// its raster key changed — pan/zoom and pure moves never repaint.
    func configureContents(
        _ layer: NodeVisualLayer, node: SceneNode, camera: Camera, backingScale: CGFloat
    ) {
        let lod = camera.scale < Self.lodThreshold
        let rasterScale = Self.clampedRasterScale(backingScale: backingScale, camera: camera)
        let key = NodeRasterKey(
            title: node.title, size: node.frame.size, style: node.style,
            lod: lod, hidesTitle: node.id == editingID, rasterScale: rasterScale,
            decorations: node.decorations, mediaRevision: node.media?.revision)
        guard layer.rasterKey != key else { return }
        layer.rasterKey = key
        // §11.4: re-rasterize at contentsScale = backingScale × zoom
        // (clamped 1…8; the settle pass drives this after zoom).
        layer.contentsScale = rasterScale
        layer.contents = NodeRasterizer.image(
            node: node, hidesTitle: node.id == editingID, lod: lod,
            rasterScale: rasterScale, measurer: measurer)
    }

    static func clampedRasterScale(backingScale: CGFloat, camera: Camera) -> CGFloat {
        min(max(backingScale * camera.scale, 1), maxRasterScale)
    }
}

// MARK: test seams (headless introspection) — an extension so the class
// body stays inside the lint type_body_length budget.
extension CanvasLayerTree {
    func nodeLayerContents(_ id: String) -> Any? { nodeLayers[id]?.contents }
    func nodeLayerContentsScale(_ id: String) -> CGFloat { nodeLayers[id]?.contentsScale ?? 0 }
    func nodeRasterKey(_ id: String) -> NodeRasterKey? { nodeLayers[id]?.rasterKey }
    /// The selection ring's model-space path bounds.
    func selectionRingBounds(_ id: String) -> CGRect? { selectionRings[id]?.path?.boundingBox }
    /// The layer's base opacity — what highlight mode (F-TAG-2) set.
    func nodeLayerOpacity(_ id: String) -> Float { nodeLayers[id]?.opacity ?? 0 }
}
