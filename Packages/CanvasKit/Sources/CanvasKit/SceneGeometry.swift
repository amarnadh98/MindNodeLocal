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
    /// the resolved style) and width mode it was derived from, so a cached
    /// size is only ever reused for the exact same inputs.
    struct SizeKey: Hashable {
        let id: String
        let title: NodeTitle
        let themeID: String
        let level: Int
        let variant: ThemeVariant
        let width: NodeWidth?
    }

    var roots: [String: RootInfo] = [:]
    var sizes: [SizeKey: CGSize] = [:]
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
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> CanvasScene {
        buildCore(
            model: model, variant: variant, measurer: measurer, spacing: spacing,
            editingTitle: editingTitle,
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
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> CanvasScene {
        buildCore(
            model: model, variant: variant, measurer: measurer, spacing: spacing,
            editingTitle: editingTitle, cache: cache, dirty: nil)
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
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> CanvasScene {
        guard cache.variant == variant, cache.spacing == spacing else {
            return build(
                model: model, variant: variant, measurer: measurer, spacing: spacing,
                editingTitle: editingTitle)
        }
        return buildCore(
            model: model, variant: variant, measurer: measurer, spacing: spacing,
            editingTitle: editingTitle, cache: cache, dirty: dirty)
    }

    /// The layout-dirty node ids for `command` applied to `model` (the
    /// post-command model): every node whose own layout inputs — measured
    /// size, child list, pinned side — changed, plus enough ids for the
    /// incremental walk to find them (a deleted or moved node's stale
    /// parent link still resolves to the parent whose child list
    /// changed). `nil` = unrecognized command; the caller falls back to a
    /// full rebuild. Over-marking is always safe; the engine validates
    /// every reused entry's own size and child ids as a second line.
    public static func dirtyIDs(for command: MapCommand, in model: MapModel) -> Set<String>? {
        func withParent(_ id: String) -> Set<String> {
            var ids = Set<String>([id])
            if let parent = model.nodes[id]?.parent {
                ids.insert(parent)
            }
            return ids
        }
        switch command {
        case .editText(let id, _),
            .setSide(let id, _),
            .setFolded(let id, _),
            // A note can change the node's decorations (note badge), so
            // its own size is re-measured.
            .setNote(let id, _),
            .reorderSibling(let id, _),
            .detach(let id),
            .deleteNodePromotingChildren(let id):
            return [id]
        case .addChild(let parent, _, let node):
            return [parent, node.id]
        case .addSibling(_, _, let node), .insertParent(_, let node):
            return withParent(node.id)
        case .moveNode(let id, _, _), .promote(let id), .demote(let id):
            return withParent(id)
        case .addRoot(_, let node):
            return [node.id]
        case .deleteSubtrees(let ids):
            // The ids are gone from the model; their stale parent links
            // (kept in the layout state) mark the parents that lost them.
            return Set(ids)
        case .insertSubtrees(_, let anchors):
            return anchorDirtyIDs(anchors)
        case .group(_, let commands):
            return groupDirtyIDs(commands, in: model)
        case .setTheme:
            // Every node's font and padding may change: full rebuild.
            return nil
        case .setOffset, .setConnections, .setBoundaries, .setSummaries, .recolorBranches,
            .setPresentations:
            // The layout frames don't move; offsets apply after layout,
            // and the list replacements are not layout inputs.
            return []
        }
    }

    /// Inserted top-level ids plus every parent that gained children.
    private static func anchorDirtyIDs(_ anchors: [InsertionAnchor]) -> Set<String> {
        var ids = Set(anchors.map(\.id))
        for anchor in anchors {
            if let parent = anchor.parent {
                ids.insert(parent)
            }
        }
        return ids
    }

    /// Union of a group's members' dirty sets; nil as soon as one member
    /// is unrecognized.
    private static func groupDirtyIDs(
        _ commands: [MapCommand], in model: MapModel
    ) -> Set<String>? {
        var ids = Set<String>()
        for command in commands {
            guard let child = dirtyIDs(for: command, in: model) else { return nil }
            ids.formUnion(child)
        }
        return ids
    }

    // MARK: core build

    private static func buildCore(
        model: MapModel,
        variant: ThemeVariant,
        measurer: TextMeasurer,
        spacing: LayoutSpacing,
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

        for rootID in model.roots {
            guard model.nodes[rootID] != nil else { continue }
            let structure = rootStructure(model, rootID: rootID)
            // Depth and level-1 ancestry are recorded by one walk honoring
            // folding — the same recording the measuring walk used to do.
            let ancestry = ancestryMap(model: model, rootID: rootID)
            let source = layoutSource(
                model: model, ancestry: ancestry, variant: variant,
                measurer: measurer, caches: caches, editingTitle: editingTitle,
                cache: cache)

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
                    width: node.width)
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

    /// The incremental layout source: measured sizes come from the
    /// per-document cache (a miss measures once through the shared
    /// `TextMeasurer` and stores), and children are the folded-pruned
    /// child list. The editing node measures its live draft title so the
    /// node grows while typing (F-EDT-8).
    static func layoutSource(
        model: MapModel,
        ancestry: [String: AncestryInfo],
        variant: ThemeVariant,
        measurer: TextMeasurer,
        caches: BuildCaches,
        editingTitle: (id: String, title: NodeTitle)?,
        cache: SceneBuildCache
    ) -> (String) -> LayoutSourceNode? {
        { id in
            guard let node: Node = model.nodes[id] else { return nil }
            let depth = ancestry[id]?.depth ?? 0
            let style = caches.style(level: depth, level1Index: 0)
            let title = id == editingTitle?.id ? editingTitle?.title : node.title
            let key = SceneBuildCache.SizeKey(
                id: id, title: title ?? node.title, themeID: caches.theme.id, level: depth,
                variant: variant, width: node.width)
            let textSize: CGSize
            if let cached = cache.sizes[key] {
                textSize = cached
            } else {
                let maxWidth: CGFloat?
                if node.width?.mode == .fixed, let fixed = node.width?.value {
                    maxWidth = fixed
                } else {
                    maxWidth = style.maxWidth
                }
                let measured = measurer.nodeTitleSize(
                    title ?? node.title, font: style.font, maxWidth: maxWidth)
                cache.sizes[key] = measured
                textSize = measured
            }
            let width = textSize.width + style.paddingWidth * 2
            let height = textSize.height + style.paddingHeight * 2
            return LayoutSourceNode(
                id: id,
                size: CGSize(width: width, height: height),
                side: side(of: node),
                childIDs: node.folded ? [] : node.children)
        }
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
