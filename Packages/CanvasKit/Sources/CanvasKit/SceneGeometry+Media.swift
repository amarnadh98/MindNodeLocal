import CoreGraphics
import MapCore
import MapLayout
import MapRender

/// The scene build's media/decoration half (M3 content), split out of
/// `SceneGeometry` to keep each file under the lint budgets: the
/// layout source (measured sizes, math measurement through the host
/// glyph, decoration recording) and the per-node decoration value.
extension SceneGeometry {
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
        /// F-TAG-3 hide mode: ids kept out of the scene. The host must
        /// rebuild fully when the pruned set changes (child lists are
        /// layout inputs — the dirty path can't see filter flips).
        let pruned: Set<String>?
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
            // F-STY-2/F-STY-3: a node with overrides measures with them
            // (font, padding, width floors change the frame); nil-patch
            // nodes (the incremental walk's overwhelming majority)
            // resolve the memoized level style directly. The palette
            // index is irrelevant to measurement, so the base style
            // resolves at index 0.
            let baseStyle = inputs.caches.style(level: depth, level1Index: 0)
            let style =
                node.style == nil
                ? baseStyle
                : inputs.caches.theme.applyingOverrides(
                    node.style, to: baseStyle, variant: inputs.variant)
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
                variant: inputs.variant, style: SceneBuildCache.StyleFingerprint(node.style),
                width: node.width, decorations: nodeDecorations)
            let textSize: CGSize
            if let cached = inputs.cache.sizes[key] {
                textSize = cached
            } else if node.math == true,
                let glyph = inputs.cache.media?.math?((title ?? node.title).text, style.font, style.textColor)
            {
                // F-CNT-5: a math node measures through the rendered
                // glyph (the host's cache; a parse error never reaches
                // here — the provider returns nil and the source text
                // measures below).
                inputs.cache.sizes[key] = glyph.size
                textSize = glyph.size
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
                childIDs: node.folded
                    ? []
                    : node.children.filter { inputs.pruned?.contains($0) != true })
        }
    }

    /// One node's decoration value (M3): the task mark (a checkbox for a
    /// leaf task, F-TSK-1; a progress ring when the subtree holds task
    /// descendants, F-TSK-2), the note/link badges, the marker row, the
    /// image block, the citation chip, the attachment badge and the tag
    /// pills resolved from the document's tag table.
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

        // F-CNT-3: the marker row before the title.
        let markers = (node.markers ?? []).map { MarkerBadge(token: $0) }
        // F-CNT-2: the image block (its display size is a layout input).
        var image: ImageBlock?
        if let stored = node.image, stored.size.count >= 2 {
            image = ImageBlock(
                asset: stored.asset,
                size: CGSize(width: stored.size[0], height: stored.size[1]),
                placement: stored.placement)
        }

        let value = NodeDecorations(
            task: task,
            hasNote: node.note != nil,
            linkURL: node.link,
            tags: pills,
            markers: markers,
            image: image,
            math: node.math == true,
            source: node.source?.url,
            attachmentCount: node.attachments?.count ?? 0)
        return value.isEmpty ? nil : value
    }
}
