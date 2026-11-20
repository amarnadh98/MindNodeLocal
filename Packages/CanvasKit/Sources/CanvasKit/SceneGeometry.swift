import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender

/// One node prepared for rendering: its laid-out frame, resolved style and
/// title. Not `Sendable` (`CGColor`); a scene lives with the view/store
/// that built it.
public struct SceneNode {
    public let id: String
    public let frame: CGRect
    public let style: ResolvedNodeStyle
    public let title: NodeTitle
    public let level: Int
    public let level1Index: Int
    /// The node's width mode/value, so the editing overlay can wrap at the
    /// width the measurer used (F-EDT-8).
    public var width: NodeWidth? = nil
    /// The decorations drawn around the title (M3: task checkbox /
    /// progress ring, note and link badges, tag pills). `nil` = plain
    /// node; part of the raster key, so decoration changes re-raster.
    public var decorations: NodeDecorations? = nil
    /// The resolved drawing-time media (F-CNT-2/3/5): the decoded
    /// image thumbnail, SF Symbol glyph rasters and the rendered math
    /// glyph. `nil` when the node has nothing media-backed; the
    /// raster/diff comparison uses its `revision`.
    public var media: NodeMedia? = nil
    /// F-LAY-14: the number of hidden descendants of a folded node —
    /// the folded-count pill's label; `nil` on unfolded/leaf nodes.
    /// Canvas-only (the pill is an interactive affordance, like the
    /// selection ring); export never draws it.
    public var foldedCount: Int? = nil
}

/// One branch connector: parent outgoing anchor to child incoming anchor.
/// `lineStyle` is how the connector draws (§7.4: curved/tapered/straight/
/// elbow/none); `tapered` is the fill-vs-stroke convenience that follows
/// from it.
public struct SceneBranch {
    public let parentID: String
    public let childID: String
    public let from: CGPoint
    public let to: CGPoint
    public let direction: BranchDirection
    public let axis: LayoutAxis
    public let startWidth: CGFloat
    public let endWidth: CGFloat
    public let color: CGColor
    /// The effective line style after the child node's branch overrides
    /// (F-STY-2 branch line style; ADR-0028: a node's branch overrides
    /// act on the connector from its parent to it).
    public let lineStyle: BranchLineStyle

    public var tapered: Bool { lineStyle == .tapered }
}

/// A whole map prepared for rendering: laid out in model space (y grows
/// down, matching the canvas and `TreeLayout` conventions), plus the
/// cross-node relation overlays (F-REL-1/2/3) derived from the same
/// frames.
public struct CanvasScene {
    public let nodes: [String: SceneNode]
    public let branches: [SceneBranch]
    public let canvasColor: CGColor
    /// Cross-links (F-REL-1), between node-edge anchors.
    public let connections: [SceneConnection]
    /// Grouping outlines (F-REL-2), around member subtrees.
    public let boundaries: [SceneBoundary]
    /// Summary braces (F-REL-3); the summary node itself is an ordinary
    /// scene node.
    public let summaries: [SceneSummary]
    /// The ids of nodes carrying a folded-count pill (F-LAY-14) — the
    /// pill sync's O(1) fast path: a map with no folded node pays one
    /// `isEmpty` check per scene apply, never a scan (§11.8).
    public var foldedIDs: Set<String> = []

    public init(
        nodes: [String: SceneNode],
        branches: [SceneBranch],
        canvasColor: CGColor,
        connections: [SceneConnection] = [],
        boundaries: [SceneBoundary] = [],
        summaries: [SceneSummary] = [],
        foldedIDs: Set<String> = []
    ) {
        self.nodes = nodes
        self.branches = branches
        self.canvasColor = canvasColor
        self.connections = connections
        self.boundaries = boundaries
        self.summaries = summaries
        self.foldedIDs = foldedIDs
    }

    public var bounds: CGRect {
        var result: CGRect = .null
        for node in nodes.values {
            result = result.union(node.frame)
        }
        return result
    }
}

/// Per-build memoization. A scene rebuild resolves every node's style
/// again; styles and branch colors are level-indexed (few dozen
/// distinct values for thousands of nodes), so resolving them once per
/// build keeps the keystroke → relayout path inside its §11.8 budget.
final class BuildCaches {
    struct StyleKey: Hashable {
        let level: Int
        let level1Index: Int
        /// ADR-0037: a stored Box|Line shape override that flips the
        /// class the level draws resolves through a donor level; the
        /// donor is part of the key so at most two extra styles per
        /// level-index pair get resolved and memoized.
        let donor: ShapeDonor
    }

    let theme: Theme
    let variant: ThemeVariant
    private var styles: [StyleKey: ResolvedNodeStyle] = [:]
    private var branchColors: [Int: CGColor] = [:]

    init(theme: Theme, variant: ThemeVariant) {
        self.theme = theme
        self.variant = variant
    }

    /// The resolved level style (F-STY-3), memoized per
    /// level/branch-index — and per ADR-0037 donor when a node's
    /// stored shape override flips the Box|Line class, so the recast
    /// base (the theme's own box/line look) is resolved once too.
    func style(level: Int, level1Index: Int, shapeOverride: NodeShape? = nil) -> ResolvedNodeStyle {
        let donor = theme.shapeDonor(override: shapeOverride, level: level, variant: variant)
        let key = StyleKey(level: level, level1Index: level1Index, donor: donor)
        if let cached = styles[key] {
            return cached
        }
        let resolved = theme.resolvedStyle(
            level: level, level1Index: level1Index, variant: variant,
            overrides: donor == .none ? nil : NodeStylePatch(shape: shapeOverride))
        styles[key] = resolved
        return resolved
    }

    func branchColor(level1Index: Int) -> CGColor {
        if let cached = branchColors[level1Index] {
            return cached
        }
        let resolved = theme.branchColor(level1Index: level1Index, variant: variant)
        branchColors[level1Index] = resolved
        return resolved
    }
}

/// Per-document scene build caches for the incremental path (SPEC §11.3's
/// `Layout.update(dirty:)`): measured node sizes keyed by id + title +
/// style + width, and one incremental layout state per root. Main-actor
/// confined, like the scene it serves — `SceneGeometry` is synchronous, so
/// the cache never crosses an isolation boundary.
///
/// The cache is variant- and spacing-tagged: `update` only reuses a cache
/// built for the same pair, and the host replaces it when the appearance
/// flips (sizes are keyed per variant, so a new cache re-measures).
public final class SceneBuildCache {
    struct RootInfo {
        let structure: LayoutStructure
        var state: LayoutState
    }

    /// A measured node size: the id, title, theme and level (which select
    /// the resolved style), the node's **style fingerprint** (F-STY-2:
    /// only the patch's size-affecting fields — font, padding, width
    /// floors — change the measured size, and the full patch is a large
    /// value this key must not carry), width mode and **decorations** it
    /// was derived from, so a cached size is only ever reused for the
    /// exact same inputs — a decoration change (task mark, badge, pills)
    /// or a style edit makes a new key and forces a re-measure.
    struct SizeKey: Hashable {
        let id: String
        let title: NodeTitle
        let themeID: String
        let level: Int
        let variant: ThemeVariant
        let style: StyleFingerprint
        let width: NodeWidth?
        let decorations: NodeDecorations?
    }

    /// The size-affecting face of a `NodeStylePatch` (ADR-0028): the
    /// fields measurement consumes directly, plus `shape` — a Box|Line
    /// flip resolves through a donor level whose padding changes the
    /// measured size (ADR-0037) — small enough to live inside `SizeKey`
    /// on the §11.8 path. `nil` fields inherit from the theme.
    struct StyleFingerprint: Hashable {
        let shape: NodeShape?
        let padding: Double?
        let fontName: String?
        let fontSize: Double?
        let fontWeight: Double?
        let fontItalic: Bool?
        let minWidth: Double?
        let maxWidth: Double?

        init(_ patch: NodeStylePatch?) {
            self.shape = patch?.shape
            self.padding = patch?.padding
            self.fontName = patch?.fontName
            self.fontSize = patch?.fontSize
            self.fontWeight = patch?.fontWeight
            self.fontItalic = patch?.fontItalic
            self.minWidth = patch?.minWidth
            self.maxWidth = patch?.maxWidth
        }
    }

    var roots: [String: RootInfo] = [:]
    var sizes: [SizeKey: CGSize] = [:]
    /// The last-measured decorations per node (M3): recorded whenever the
    /// layout source measures a node, read by the scene assembly. A node
    /// whose decorations changed is always re-measured (every
    /// decorations-affecting command marks it dirty in `dirtyIDs`), so
    /// entries never go stale for a visible node.
    var decorations: [String: NodeDecorations?] = [:]
    /// The host's resolved-media lookup (F-CNT-2/3/5): image
    /// thumbnails, SF Symbol glyphs and rendered math. Async caches
    /// live behind it; lookups are dictionary hits.
    public var media: SceneMediaProvider?
    public let variant: ThemeVariant
    public let spacing: LayoutSpacing

    public init(variant: ThemeVariant, spacing: LayoutSpacing = .default) {
        self.variant = variant
        self.spacing = spacing
    }
}

/// Builds a `CanvasScene` from a `MapModel`: measures every visible node
/// once through the shared `TextMeasurer`, lays out each root's tree with
/// `TreeLayout` (stacking multiple roots), resolves the document's theme
/// (F-STY-3: theme → level style → branch color from the level-1
/// ancestor's stored palette index) per level and branch, and derives
/// branch connectors with the theme's branch widths. Folded subtrees are
/// skipped (F-LAY-14).
///
/// `update` is the incremental path (SPEC §11.3): with the per-document
/// caches from a previous build it re-measures only the dirty nodes'
/// titles, relayouts only the changed chain through
/// `IncrementalLayout.update`, and rebuilds the scene — producing exactly
/// the scene a full rebuild would (both share this file's assembly and
/// the same layout core).
public enum SceneGeometry {
    /// Gap between the stacked root trees of a multi-root document.
    public static let rootStackGap: CGFloat = 120

    /// Full rebuild, keeping no caches (tests, probes, one-shot callers).
    /// `theme` overrides the model's theme selection — the theme editor's
    /// live preview renders a draft theme no document stores yet, and the
    /// app resolves user themes (`.arbortheme` files) through its catalog
    /// before handing the value here.
    public static func build(
        model: MapModel,
        variant: ThemeVariant,
        measurer: TextMeasurer,
        spacing: LayoutSpacing = .default,
        showsTagPills: Bool = true,
        prunedIDs: Set<String>? = nil,
        editingTitle: (id: String, title: NodeTitle)? = nil,
        theme: Theme? = nil
    ) -> CanvasScene {
        buildCore(
            BuildRequest(
                model: model, variant: variant, measurer: measurer, spacing: spacing,
                showsTagPills: showsTagPills, prunedIDs: prunedIDs, editingTitle: editingTitle, theme: theme),
            cache: SceneBuildCache(variant: variant, spacing: spacing), dirty: nil)
    }

    /// Full rebuild that also fills `cache`, so later small changes can
    /// go through `update`.
    public static func build(
        model: MapModel,
        cache: SceneBuildCache,
        variant: ThemeVariant,
        measurer: TextMeasurer,
        spacing: LayoutSpacing = .default,
        showsTagPills: Bool = true,
        prunedIDs: Set<String>? = nil,
        editingTitle: (id: String, title: NodeTitle)? = nil,
        theme: Theme? = nil
    ) -> CanvasScene {
        buildCore(
            BuildRequest(
                model: model, variant: variant, measurer: measurer, spacing: spacing,
                showsTagPills: showsTagPills, prunedIDs: prunedIDs, editingTitle: editingTitle, theme: theme),
            cache: cache, dirty: nil)
    }

    /// Incremental rebuild after a small change (SPEC §11.3): reuses the
    /// cache's measured sizes and per-root layout state, relayouts only
    /// `dirty`'s chain through `IncrementalLayout.update`, and emits the
    /// same scene a full rebuild would. `dirty` names the nodes whose own
    /// layout inputs changed (`dirtyIDs(for:in:)` derives them from a
    /// command); ancestors are closed inside the layout engine.
    ///
    /// The cache must have been built for the same variant and spacing —
    /// otherwise this falls back to a full build without touching it
    /// (the host owns the cache's lifetime).
    public static func update(
        model: MapModel,
        cache: SceneBuildCache,
        variant: ThemeVariant,
        measurer: TextMeasurer,
        spacing: LayoutSpacing = .default,
        dirty: Set<String>,
        showsTagPills: Bool = true,
        prunedIDs: Set<String>? = nil,
        editingTitle: (id: String, title: NodeTitle)? = nil,
        theme: Theme? = nil
    ) -> CanvasScene {
        guard cache.variant == variant, cache.spacing == spacing else {
            return build(
                model: model, variant: variant, measurer: measurer, spacing: spacing,
                showsTagPills: showsTagPills, prunedIDs: prunedIDs, editingTitle: editingTitle,
                theme: theme)
        }
        return buildCore(
            BuildRequest(
                model: model, variant: variant, measurer: measurer, spacing: spacing,
                showsTagPills: showsTagPills, prunedIDs: prunedIDs, editingTitle: editingTitle, theme: theme),
            cache: cache, dirty: dirty)
    }

    // MARK: core build

    /// Everything one build needs besides the cache and the dirty set —
    /// a value so `buildCore` stays under the lint parameter budget.
    struct BuildRequest {
        let model: MapModel
        let variant: ThemeVariant
        let measurer: TextMeasurer
        let spacing: LayoutSpacing
        let showsTagPills: Bool
        let prunedIDs: Set<String>?
        let editingTitle: (id: String, title: NodeTitle)?
        /// F-STY-5: an explicit theme (the editor's draft or a user
        /// theme) wins over the document's built-in selection.
        let theme: Theme?
    }

    private static func buildCore(
        _ request: BuildRequest, cache: SceneBuildCache, dirty: Set<String>?
    ) -> CanvasScene {
        let model = request.model
        let variant = request.variant
        let measurer = request.measurer
        let spacing = request.spacing
        let prunedIDs = request.prunedIDs
        let editingTitle = request.editingTitle
        // F-STY-3/F-STY-4: styles resolve from the document's theme
        // selection (default Paper) at the current appearance variant,
        // with the document's stored overrides (canvas color, palette,
        // base font, rainbow toggle) folded in — the seam the
        // inspector's Theme pane writes. F-STY-5: an explicit theme (the
        // theme editor's draft, the user-theme catalog) replaces the
        // built-in lookup; the document overrides still apply on top.
        let theme = (request.theme ?? BuiltInThemes.theme(id: model.theme?.id ?? BuiltInThemes.defaultID))
            .applyingDocumentOverrides(model.theme?.overrides)
        var nodes: [String: SceneNode] = [:]
        var branches: [SceneBranch] = []
        var foldedIDs: Set<String> = []
        var cursorY: CGFloat = 0
        let caches = BuildCaches(theme: theme, variant: variant)
        // F-TSK-2/F-TAG-1: one cached pass each for task ratios and tag
        // definitions, so every node's decorations build in O(1). The
        // emptiness flags keep task-free maps off the per-node ratio
        // lookup entirely (the §11.8 keystroke path).
        let progress = TaskProgress.index(model)
        let tagByID = Dictionary(uniqueKeysWithValues: (model.tags ?? []).map { ($0.id, $0) })
        let hasTagDefinitions = !tagByID.isEmpty
        // The overlays (F-REL) need each node's root and that root's
        // layout axis: summary braces go right (below for org charts).
        var rootAxes: [String: LayoutAxis] = [:]
        var rootOf: [String: String] = [:]

        for rootID in model.roots {
            guard model.nodes[rootID] != nil else { continue }
            let structure = rootStructure(model, rootID: rootID)
            // Depth and level-1 ancestry are recorded by one walk honoring
            // folding — the same recording the measuring walk used to do.
            let ancestry = ancestryMap(model: model, rootID: rootID)
            let source = layoutSource(
                SourceInputs(
                    model: model, ancestry: ancestry, variant: variant,
                    measurer: measurer, caches: caches,
                    progress: progress, tagByID: tagByID,
                    hasTagDefinitions: hasTagDefinitions,
                    showsTagPills: request.showsTagPills,
                    pruned: prunedIDs,
                    editingTitle: editingTitle, cache: cache))

            // Full pass: a fresh state, everything recomputed and recorded.
            // Incremental: the root's cached state plus the dirty set —
            // unfiltered on purpose: an id that moved OUT of this root
            // still has a stale parent link in this state, and that link
            // is what marks the parent whose child list changed. Foreign
            // ids (no link here) close to nothing and are harmless.
            let rootState =
                dirty == nil
                ? LayoutState()
                : (cache.roots[rootID]?.state ?? LayoutState())
            let (frames, state) = IncrementalLayout.update(
                rootID: rootID, structure: structure, spacing: spacing,
                state: rootState, dirty: dirty, source: source)
            cache.roots[rootID] = SceneBuildCache.RootInfo(
                structure: structure, state: state)

            // Flexible positioning (F-LAY-11): a node's manual offset moves
            // it and its descendants after auto layout (also how a
            // floating root lands where it was created, F-CAN-5).
            let offsets = accumulatedOffsets(model: model, rootID: rootID)
            let treeMinY = frames.values.map(\.minY).min() ?? (frames[rootID]?.minY ?? 0)
            let offsetY = cursorY - treeMinY
            let rootLevel1Index = levelOneIndices(
                model: model, rootID: rootID, theme: theme,
                rainbowOverride: model.theme?.overrides?.rainbowBranches)
            let axis: LayoutAxis =
                structure == .orgDown || structure == .orgUp ? .vertical : .horizontal
            rootAxes[rootID] = axis

            // Final placed frames: auto layout + root stacking + manual
            // offsets. The summary placement (F-REL-3, ADR-0026) reads
            // the range frames from here and nudges the summary node
            // beyond the brace; the node pass below folds the nudge in.
            var placed: [String: CGRect] = [:]
            // Manual offsets are rare: skip the per-node lookup when none.
            let hasOffsets = !offsets.isEmpty
            for (id, frame) in frames {
                let offset = hasOffsets ? offsets[id] ?? .zero : .zero
                placed[id] = frame.offsetBy(dx: offset.x, dy: offsetY + offset.y)
                rootOf[id] = rootID
            }
            let adjustments = summaryAdjustments(
                model: model, placed: placed, axis: axis)

            var bottom = (frames[rootID]?.maxY ?? 0)
            var rootFoldedIDs: Set<String> = []
            // Summary nudges and decorations are the exception, not the
            // rule: skip their per-node lookups when the maps are empty.
            let hasAdjustments = !adjustments.isEmpty
            let hasDecorations = !cache.decorations.isEmpty
            for (id, frame) in placed {
                guard let node = model.nodes[id] else { continue }
                let info = ancestry[id] ?? AncestryInfo(depth: 0, level1AncestorID: id)
                let level1Index =
                    info.depth == 0 ? 0 : rootLevel1Index[info.level1AncestorID] ?? 0
                let title = id == editingTitle?.id ? editingTitle?.title : node.title
                let adjust = hasAdjustments ? adjustments[id] ?? .zero : .zero
                let translated = frame.offsetBy(dx: adjust.x, dy: adjust.y)
                // F-STY-2/F-STY-3: the override seam. Nil-patch nodes
                // (the overwhelming majority) resolve to the memoized
                // level style directly — keeping the cross-module call
                // off the §11.8 fast path. The recast base carries the
                // Box|Line donor look (ADR-0037) before the patch's own
                // fields land.
                let baseStyle =
                    caches.style(level: info.depth, level1Index: level1Index, shapeOverride: node.style?.shape)
                let resolvedStyle =
                    node.style == nil
                    ? baseStyle
                    : caches.theme.applyingOverrides(
                        node.style, to: baseStyle, variant: caches.variant)
                let folded: Int? =
                    node.folded && !node.children.isEmpty
                    ? foldedDescendantCount(ofChildren: node.children, in: model)
                    : nil
                if folded != nil {
                    rootFoldedIDs.insert(id)
                }
                let nodeDecorations = hasDecorations ? cache.decorations[id] ?? nil : nil
                nodes[id] = SceneNode(
                    id: id,
                    frame: translated,
                    style: resolvedStyle,
                    title: title ?? node.title,
                    level: info.depth,
                    level1Index: level1Index,
                    width: node.width,
                    decorations: nodeDecorations,
                    media: cache.media?.media(
                        for: nodeDecorations, title: (title ?? node.title).text, style: resolvedStyle),
                    foldedCount: folded)
                if translated.maxY > bottom {
                    bottom = translated.maxY
                }
            }
            foldedIDs.formUnion(rootFoldedIDs)

            branches.append(
                contentsOf: connectors(
                    model: model, rootID: rootID, nodes: &nodes,
                    caches: caches))

            cursorY = bottom + rootStackGap
        }

        // The relation overlays (F-REL-1/2/3): pure functions of the
        // placed frames — recomputed on every build, so boundaries
        // follow layout and braces track their ranges through folds,
        // moves and undos alike.
        let overlays = RelationGeometry.build(
            model: model, theme: theme, variant: variant, nodes: nodes,
            rootAxes: rootAxes, rootOf: rootOf, measurer: measurer)

        return CanvasScene(
            nodes: nodes,
            branches: branches,
            canvasColor: theme.canvasColor(for: variant),
            connections: overlays.connections,
            boundaries: overlays.boundaries,
            summaries: overlays.summaries,
            foldedIDs: foldedIDs)
    }

    /// Depth from the root and the level-1 ancestor that colors this
    /// node's branch — recorded by the same recursion that measures
    /// (`layoutTree`), so a rebuild never walks ancestor chains again.
    struct AncestryInfo {
        let depth: Int
        let level1AncestorID: String
    }

    /// The palette index each of `rootID`'s children colors its branch
    /// with (ADR-0009): the stored persistent index, falling back to
    /// the child's position when none is stored; the theme's
    /// rainbow-branches toggle (F-STY-8) collapses it to 0 when off —
    /// the document's stored override of that toggle wins over the
    /// theme's own value.
    static func levelOneIndices(
        model: MapModel, rootID: String, theme: Theme, rainbowOverride: Bool?
    ) -> [String: Int] {
        let rainbow = rainbowOverride ?? theme.rainbowBranches
        var indices: [String: Int] = [:]
        for (position, childID) in (model.nodes[rootID]?.children ?? []).enumerated() {
            let stored = model.nodes[childID]?.paletteIndex ?? position
            indices[childID] = rainbow ? stored : 0
        }
        return indices
    }

    /// Branch connectors for one root's tree, in model space.
    static func connectors(
        model: MapModel,
        rootID: String,
        nodes: inout [String: SceneNode],
        caches: BuildCaches
    ) -> [SceneBranch] {
        var result: [SceneBranch] = []
        let structure = rootStructure(model, rootID: rootID)
        // Hoisted per root: the theme's line style, re-read per branch
        // otherwise (§11.8).
        let themeLineStyle = caches.theme.branch.lineStyle
        let (axis, directions): (LayoutAxis, (BranchDirection, BranchDirection)) = {
            switch structure {
            case .mindmapBalanced, .mindmapRight, .logicChartRight:
                (.horizontal, (.right, .left))
            case .mindmapLeft:
                (.horizontal, (.left, .right))
            case .orgDown:
                (.vertical, (.down, .down))
            case .orgUp:
                (.vertical, (.up, .up))
            }
        }()

        func walk(_ id: String, parentInfo: (level: Int, index: Int)) {
            guard let node = model.nodes[id] else { return }
            // A leaf has no outgoing connector: its style resolution is
            // skipped entirely (§11.8 — half the nodes of a big map).
            let children = node.folded ? [] : node.children
            guard !children.isEmpty else { return }
            // Same nil-patch fast path as the assembly loop, with the
            // ADR-0037 recast base for a Box|Line flip.
            let parentBaseStyle =
                caches.style(level: parentInfo.level, level1Index: parentInfo.index, shapeOverride: node.style?.shape)
            let parentStyle =
                node.style == nil
                ? parentBaseStyle
                : caches.theme.applyingOverrides(
                    node.style, to: parentBaseStyle, variant: caches.variant)
            // One dictionary read per parent, not two per child.
            let parentFrame = nodes[id]?.frame ?? .zero
            for childID in children {
                guard let childScene = nodes[childID] else { continue }
                let direction: BranchDirection
                switch structure {
                case .mindmapBalanced:
                    direction = childScene.frame.midX >= parentFrame.midX ? directions.0 : directions.1
                default:
                    direction = directions.0
                }
                let from = NodeRenderer.outgoingAnchor(
                    style: parentStyle, frame: parentFrame, direction: direction)
                let childStyle = childScene.style
                let to = NodeRenderer.incomingAnchor(
                    style: childStyle, frame: childScene.frame, direction: direction)
                // ADR-0028: the child node's branch overrides color the
                // connector from its parent to it (each node owns exactly
                // one incoming branch; roots have none).
                let childPatch = model.nodes[childID]?.style
                let lineStyle =
                    childPatch?.branchLineStyle.flatMap {
                        BranchLineStyle(rawValue: $0.lowercased())
                    }
                    ?? themeLineStyle
                let color =
                    childPatch?.branchColor.flatMap { ThemeHex.color($0) }
                    ?? caches.branchColor(level1Index: childScene.level1Index)
                let widths = overrideWidths(
                    parentWidth: caches.theme.branchWidth(level: parentInfo.level),
                    childWidth: caches.theme.branchWidth(level: childScene.level),
                    patch: childPatch, lineStyle: lineStyle)
                result.append(
                    SceneBranch(
                        parentID: id,
                        childID: childID,
                        from: from,
                        to: to,
                        direction: direction,
                        axis: axis,
                        startWidth: widths.start,
                        endWidth: widths.end,
                        color: color,
                        lineStyle: lineStyle))
                walk(childID, parentInfo: (level: parentInfo.level + 1, index: childScene.level1Index))
            }
        }
        walk(rootID, parentInfo: (level: 0, index: 0))
        return result
    }
}
