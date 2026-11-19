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
}

/// One branch connector: parent outgoing anchor to child incoming anchor.
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
    public let tapered: Bool
}

/// A whole map prepared for rendering: laid out in model space (y grows
/// down, matching the canvas and `TreeLayout` conventions).
public struct CanvasScene {
    public let nodes: [String: SceneNode]
    public let branches: [SceneBranch]
    public let canvasColor: CGColor

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
    }

    let theme: Theme
    private let variant: ThemeVariant
    private var styles: [StyleKey: ResolvedNodeStyle] = [:]
    private var branchColors: [Int: CGColor] = [:]

    init(theme: Theme, variant: ThemeVariant) {
        self.theme = theme
        self.variant = variant
    }

    func style(level: Int, level1Index: Int) -> ResolvedNodeStyle {
        let key = StyleKey(level: level, level1Index: level1Index)
        if let cached = styles[key] {
            return cached
        }
        let resolved = theme.resolvedStyle(level: level, level1Index: level1Index, variant: variant)
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
    /// the resolved style), width mode and **decorations** it was derived
    /// from, so a cached size is only ever reused for the exact same
    /// inputs — a decoration change (task mark, badge, pills) makes a new
    /// key and forces a re-measure.
    struct SizeKey: Hashable {
        let id: String
        let title: NodeTitle
        let themeID: String
        let level: Int
        let variant: ThemeVariant
        let width: NodeWidth?
        let decorations: NodeDecorations?
    }

    var roots: [String: RootInfo] = [:]
    var sizes: [SizeKey: CGSize] = [:]
    /// The last-measured decorations per node (M3): recorded whenever the
    /// layout source measures a node, read by the scene assembly. A node
    /// whose decorations changed is always re-measured (every
    /// decorations-affecting command marks it dirty in `dirtyIDs`), so
    /// entries never go stale for a visible node.
    var decorations: [String: NodeDecorations?] = [:]
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
    public static func build(
        model: MapModel,
        variant: ThemeVariant,
        measurer: TextMeasurer,
        spacing: LayoutSpacing = .default,
        showsTagPills: Bool = true,
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> CanvasScene {
        buildCore(
            model: model, variant: variant, measurer: measurer, spacing: spacing,
            showsTagPills: showsTagPills, editingTitle: editingTitle,
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
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> CanvasScene {
        buildCore(
            model: model, variant: variant, measurer: measurer, spacing: spacing,
            showsTagPills: showsTagPills, editingTitle: editingTitle, cache: cache, dirty: nil)
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
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> CanvasScene {
        guard cache.variant == variant, cache.spacing == spacing else {
            return build(
                model: model, variant: variant, measurer: measurer, spacing: spacing,
                editingTitle: editingTitle)
        }
        return buildCore(
            model: model, variant: variant, measurer: measurer, spacing: spacing,
            showsTagPills: showsTagPills, editingTitle: editingTitle, cache: cache, dirty: dirty)
    }

    // MARK: core build

    private static func buildCore(
        model: MapModel,
        variant: ThemeVariant,
        measurer: TextMeasurer,
        spacing: LayoutSpacing,
        showsTagPills: Bool,
        editingTitle: (id: String, title: NodeTitle)?,
        cache: SceneBuildCache,
        dirty: Set<String>?
    ) -> CanvasScene {
        // F-STY-3/F-STY-4: styles resolve from the document's theme
        // selection (default Paper) at the current appearance variant.
        let theme = BuiltInThemes.theme(id: model.theme?.id ?? BuiltInThemes.defaultID)
        var nodes: [String: SceneNode] = [:]
        var branches: [SceneBranch] = []
        var cursorY: CGFloat = 0
        let caches = BuildCaches(theme: theme, variant: variant)
        // F-TSK-2/F-TAG-1: one cached pass each for task ratios and tag
        // definitions, so every node's decorations build in O(1). The
        // emptiness flags keep task-free maps off the per-node ratio
        // lookup entirely (the §11.8 keystroke path).
        let progress = TaskProgress.index(model)
        let tagByID = Dictionary(uniqueKeysWithValues: (model.tags ?? []).map { ($0.id, $0) })
        let hasTagDefinitions = !tagByID.isEmpty

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
                    hasTagDefinitions: hasTagDefinitions, showsTagPills: showsTagPills,
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
            let rootLevel1Index = levelOneIndices(model: model, rootID: rootID, theme: theme)

            var bottom = (frames[rootID]?.maxY ?? 0)
            for (id, frame) in frames {
                guard let node = model.nodes[id] else { continue }
                let info = ancestry[id] ?? AncestryInfo(depth: 0, level1AncestorID: id)
                let offset = offsets[id] ?? .zero
                let translated = frame.offsetBy(dx: offset.x, dy: offsetY + offset.y)
                let level1Index =
                    info.depth == 0 ? 0 : rootLevel1Index[info.level1AncestorID] ?? 0
                let title = id == editingTitle?.id ? editingTitle?.title : node.title
                nodes[id] = SceneNode(
                    id: id,
                    frame: translated,
                    style: caches.theme.applyingOverrides(
                        node.style, to: caches.style(level: info.depth, level1Index: level1Index)),
                    title: title ?? node.title,
                    level: info.depth,
                    level1Index: level1Index,
                    width: node.width,
                    decorations: cache.decorations[id] ?? nil)
                if translated.maxY > bottom {
                    bottom = translated.maxY
                }
            }

            branches.append(
                contentsOf: connectors(
                    model: model, rootID: rootID, nodes: &nodes,
                    caches: caches))

            cursorY = bottom + rootStackGap
        }

        return CanvasScene(
            nodes: nodes,
            branches: branches,
            canvasColor: theme.canvasColor(for: variant))
    }

    /// The structure of a root's tree: the root's own override, else the
    /// document default (SPEC §5.3: structure is inherited until
    /// overridden; the canvas default is the balanced mind map).
    static func rootStructure(_ model: MapModel, rootID: String) -> LayoutStructure {
        guard let raw = model.nodes[rootID]?.structure,
            let structure = LayoutStructure(rawValue: raw)
        else {
            return .mindmapBalanced
        }
        return structure
    }

    /// Depth from the root and the level-1 ancestor that colors this
    /// node's branch, for every node the scene can show (folded subtrees
    /// pruned) — one walk, no ancestor chains per node.
    static func ancestryMap(model: MapModel, rootID: String) -> [String: AncestryInfo] {
        var result: [String: AncestryInfo] = [:]
        func walk(_ id: String, depth: Int, level1: String) {
            guard let node = model.nodes[id] else { return }
            result[id] = AncestryInfo(
                depth: depth,
                // The level-1 ancestor of a root (depth 0) and of a
                // first-level node is the node itself.
                level1AncestorID: depth <= 1 ? id : level1)
            guard !node.folded else { return }
            let childLevel1 = depth == 0 ? id : (depth == 1 ? id : level1)
            for childID in node.children {
                walk(childID, depth: depth + 1, level1: childLevel1)
            }
        }
        walk(rootID, depth: 0, level1: rootID)
        return result
    }

    /// Everything the per-node layout source needs besides the node id
    /// (M3's content facts included): a value, so the closure factory's
    /// signature stays under the lint budgets.
    struct SourceInputs {
        let model: MapModel
        let ancestry: [String: AncestryInfo]
        let variant: ThemeVariant
        let measurer: TextMeasurer
        let caches: BuildCaches
        let progress: [String: TaskRatio]
        let tagByID: [String: Tag]
        let hasTagDefinitions: Bool
        let showsTagPills: Bool
        let editingTitle: (id: String, title: NodeTitle)?
        let cache: SceneBuildCache
    }

    /// The incremental layout source: measured sizes come from the
    /// per-document cache (a miss measures once through the shared
    /// `TextMeasurer` and stores), and children are the folded-pruned
    /// child list. The editing node measures its live draft title so the
    /// node grows while typing (F-EDT-8). M3: each measured node's
    /// decorations are computed once here — recorded into the cache for
    /// the scene assembly, folded into the size key (so a decoration
    /// change never reuses a stale size) and into the size itself
    /// through the shared `NodeRenderer.contentSize`.
    static func layoutSource(_ inputs: SourceInputs) -> (String) -> LayoutSourceNode? {
        { id in
            guard let node: Node = inputs.model.nodes[id] else { return nil }
            let depth = inputs.ancestry[id]?.depth ?? 0
            let style = inputs.caches.style(level: depth, level1Index: 0)
            let title = id == inputs.editingTitle?.id ? inputs.editingTitle?.title : node.title
            // One decoration value per node: recorded for the scene and
            // consumed by the measurement below (never computed twice).
            let nodeDecorations = decoration(
                for: node, ratio: inputs.progress.isEmpty ? nil : inputs.progress[id],
                tagByID: inputs.tagByID, hasTagDefinitions: inputs.hasTagDefinitions,
                showsTagPills: inputs.showsTagPills)
            inputs.cache.decorations[id] = nodeDecorations
            let key = SceneBuildCache.SizeKey(
                id: id, title: title ?? node.title, themeID: inputs.caches.theme.id, level: depth,
                variant: inputs.variant, width: node.width, decorations: nodeDecorations)
            let textSize: CGSize
            if let cached = inputs.cache.sizes[key] {
                textSize = cached
            } else {
                let maxWidth: CGFloat?
                if node.width?.mode == .fixed, let fixed = node.width?.value {
                    maxWidth = fixed
                } else {
                    maxWidth = style.maxWidth
                }
                let measured = inputs.measurer.nodeTitleSize(
                    title ?? node.title, font: style.font, maxWidth: maxWidth)
                inputs.cache.sizes[key] = measured
                textSize = measured
            }
            let contentSize = NodeRenderer.contentSize(
                textSize: textSize, style: style, decorations: nodeDecorations)
            let width = contentSize.width + style.paddingWidth * 2
            let height = contentSize.height + style.paddingHeight * 2
            return LayoutSourceNode(
                id: id,
                size: CGSize(width: width, height: height),
                side: side(of: node),
                childIDs: node.folded ? [] : node.children)
        }
    }

    /// One node's decoration value (M3): the task mark (a checkbox for a
    /// leaf task, F-TSK-1; a progress ring when the subtree holds task
    /// descendants, F-TSK-2), the note/link badges and the tag pills
    /// resolved from the document's tag table.
    static func decoration(
        for node: Node, ratio: TaskRatio?, tagByID: [String: Tag],
        hasTagDefinitions: Bool, showsTagPills: Bool
    ) -> NodeDecorations? {
        var task: TaskMark?
        if let ratio, ratio.total > 0 {
            // Any node (task or not) with task descendants: the ring
            // (F-TSK-2; `TaskProgress.index` holds exactly these).
            task = .progress(completed: ratio.completed, total: ratio.total)
        } else if node.task != nil {
            // A task with no task descendants: its own checkbox
            // (F-TSK-1).
            task = .checkbox(done: node.task?.done ?? false)
        }

        var pills: [TagPill] = []
        if showsTagPills, hasTagDefinitions {
            pills = (node.tags ?? []).compactMap { tagID in
                guard let tag = tagByID[tagID] else { return nil }
                return TagPill(name: tag.name, colorHex: tag.color)
            }
        }

        let value = NodeDecorations(
            task: task, hasNote: node.note != nil, linkURL: node.link, tags: pills)
        return value.isEmpty ? nil : value
    }

    /// A node's manual offset, plus the accumulated offsets of its
    /// ancestors — the translation applied after auto layout (SPEC §9:
    /// "offset is added after auto layout; descendants move with it").
    static func accumulatedOffsets(model: MapModel, rootID: String) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]

        func walk(_ id: String, inherited: CGPoint) {
            var own = inherited
            if let offset = model.nodes[id]?.offset {
                own = CGPoint(x: own.x + offset.x, y: own.y + offset.y)
            }
            result[id] = own
            for childID in model.nodes[id]?.children ?? [] {
                walk(childID, inherited: own)
            }
        }
        walk(rootID, inherited: .zero)
        return result
    }

    private static func side(of node: Node) -> LayoutSide? {
        guard let sidePin = node.side else { return nil }
        return sidePin == .left ? .left : .right
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
    /// rainbow-branches toggle (F-STY-8) collapses it to 0 when off.
    static func levelOneIndices(model: MapModel, rootID: String, theme: Theme) -> [String: Int] {
        var indices: [String: Int] = [:]
        for (position, childID) in (model.nodes[rootID]?.children ?? []).enumerated() {
            let stored = model.nodes[childID]?.paletteIndex ?? position
            indices[childID] = theme.effectivePaletteIndex(stored)
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
        let (axis, directions): (LayoutAxis, (BranchDirection, BranchDirection)) = {
            switch structure {
            case .mindmapBalanced, .mindmapRight:
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
            let children = node.folded ? [] : node.children
            let parentStyle = caches.theme.applyingOverrides(
                node.style, to: caches.style(level: parentInfo.level, level1Index: parentInfo.index))
            for childID in children {
                guard let childScene = nodes[childID] else { continue }
                let direction: BranchDirection
                switch structure {
                case .mindmapBalanced:
                    direction =
                        childScene.frame.midX >= (nodes[id]?.frame.midX ?? 0)
                        ? directions.0 : directions.1
                default:
                    direction = directions.0
                }
                let from = NodeRenderer.outgoingAnchor(
                    style: parentStyle, frame: nodes[id]?.frame ?? .zero, direction: direction)
                let childStyle = childScene.style
                let to = NodeRenderer.incomingAnchor(
                    style: childStyle, frame: childScene.frame, direction: direction)
                let widths = taperedWidths(
                    theme: caches.theme, parentLevel: parentInfo.level, childLevel: childScene.level)
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
                        color: caches.branchColor(level1Index: childScene.level1Index),
                        tapered: caches.theme.branch.lineStyle == .tapered))
                walk(childID, parentInfo: (level: parentInfo.level + 1, index: childScene.level1Index))
            }
        }
        walk(rootID, parentInfo: (level: 0, index: 0))
        return result
    }

    /// Continuous taper from the root to the leaves (§7.2): a branch's
    /// start width is its parent node's width `w(level)`, and it tapers to
    /// `w(level + 1)` — no thickness jump at intermediate nodes. The width
    /// fall-off is theme data (Paper: 6 pt at the root down to 2 pt).
    static func taperedWidths(
        theme: Theme, parentLevel: Int, childLevel: Int
    ) -> (start: CGFloat, end: CGFloat) {
        (start: theme.branchWidth(level: parentLevel), end: theme.branchWidth(level: childLevel))
    }
}
