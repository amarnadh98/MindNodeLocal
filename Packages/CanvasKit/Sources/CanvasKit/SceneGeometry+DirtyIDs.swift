import MapCore

/// The command → layout-dirty mapping for the incremental scene path
/// (SPEC §11.3), split out of `SceneGeometry` to keep each file under
/// the lint budgets. The exhaustive switch is deliberately flat —
/// every command kind reads in one place.
extension SceneGeometry {
    /// The layout-dirty node ids for `command` applied to `model` (the
    /// post-command model): every node whose own layout inputs — measured
    /// size, child list, pinned side — changed, plus enough ids for the
    /// incremental walk to find them (a deleted or moved node's stale
    /// parent link still resolves to the parent whose child list
    /// changed). `nil` = unrecognized command (or one whose exact dirty
    /// set is the whole map, like a tag-definition edit); the caller
    /// falls back to a full rebuild. Over-marking is always safe; the
    /// engine validates every reused entry's own size and child ids as
    /// a second line.
    // swiftlint:disable:next cyclomatic_complexity
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
            // A study deck/card change may add a badge: re-measure.
            .setStudy(_, let id, _),
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
        case .setStyle, .resetStyle, .setTheme, .setThemeSelection, .setThemeOverrides,
            .setAppearance, .setStructure:
            // The M2 style/theme/structure commands share one arm so
            // this dispatcher stays under the lint budget; the mapping
            // itself lives one function down.
            return styleCommandDirtyIDs(command, in: model)
        case .setOffset, .setConnections, .setBoundaries, .setSummaries, .recolorBranches,
            .setPresentations, .setAIPolicy, .setTitle,
            // F-REL-1/2/3: the fine-grained relation edits are post-layout
            // overlays — `RelationGeometry.build` recomputes them from the
            // placed frames on every scene build, so no node's layout
            // inputs change. A summary's node is added through the grouped
            // `addChild` its command carries, which dirties on its own.
            .addConnection, .removeConnection, .editConnection,
            .addBoundary, .removeBoundary, .editBoundary,
            .addSummary, .removeSummary:
            // The layout frames don't move; offsets apply after layout,
            // and the list replacements are not layout inputs.
            return []
        case .setLink(let id, _):
            // A link badge is a decoration (M3): the node's own size is
            // re-measured.
            return [id]
        case .setTask(let ids, _), .setTaskDone(let ids, _):
            // A task change re-marks the node (checkbox) and every
            // ancestor's progress ring (F-TSK-2) — the ring is a leading
            // decoration, so each ring node's own size is an input.
            return withAncestors(ids, in: model)
        case .setTaskValue(let id, _):
            return withAncestors([id], in: model)
        case .setTaskDetails(let id, _, _, _):
            return [id]
        case .setTags:
            // Definition edits (rename/recolor/delete) can touch every
            // node that carries the tag; the exact dirty set is the whole
            // map, so the caller takes the full-rebuild fallback.
            return nil
        case .toggleTag(let ids, _, _):
            // Pills are decorations of exactly these nodes.
            return Set(ids)
        case .setNodeTags(let id, _):
            return [id]
        case .setImage(let id, _):
            // The image block is a layout input (its stored display
            // size joins `contentSize`), so the node re-measures.
            return [id]
        case .setMarkers(let id, _):
            // The marker row is a leading decoration: the node's own
            // size is re-measured.
            return [id]
        case .setAttachments(let id, _):
            // An attachment badge is a trailing decoration.
            return [id]
        case .setSource(let id, _):
            // The citation chip is a trailing decoration.
            return [id]
        case .setMath(let id, _):
            // The rendered math image replaces the title's measured
            // size (falling back to the source text when absent).
            return [id]
        case .setFilters:
            // Saved-filter definitions are not a layout input; the
            // active filter itself is view state the host rebuilds
            // through when it changes.
            return []
        }
    }

    /// The style/theme/structure commands' dirty sets (ADR-0028),
    /// split from the dispatcher to keep each function under the
    /// complexity budget.
    ///
    /// - `setStyle`: only size-affecting fields can move a frame
    ///   (`NodeStylePatch.affectsMeasuredSize` — font/padding/width,
    ///   and `shape`, whose Box|Line class flips resolve through a
    ///   donor level's padding, ADR-0037); colors, borders and branch
    ///   styling repaint only.
    /// - `resetStyle`: the post-command model can't tell which fields
    ///   left (the dirty set is derived after apply), so a reset
    ///   touching any size-affecting key — or a wholesale clear —
    ///   re-measures the node; over-marking is safe and cheap.
    /// - Theme selection/overrides, appearance and structure changes
    ///   re-resolve the whole canvas: the full-rebuild fallback (nil).
    private static func styleCommandDirtyIDs(
        _ command: MapCommand, in model: MapModel
    ) -> Set<String>? {
        switch command {
        case .setStyle(let ids, let patch):
            return patch.affectsMeasuredSize ? Set(ids) : []
        case .resetStyle(let ids, let keys):
            if keys == nil || !Set(keys ?? []).isDisjoint(with: NodeStylePatch.sizeAffectingKeys) {
                return Set(ids)
            }
            return []
        case .setTheme, .setThemeSelection, .setThemeOverrides, .setAppearance, .setStructure:
            return nil
        default:
            // The dispatcher only routes these commands here.
            return []
        }
    }

    /// `ids` plus their whole ancestor chains: every node whose progress
    /// ring (a leading decoration, F-TSK-2) may have changed.
    private static func withAncestors(_ ids: [String], in model: MapModel) -> Set<String> {
        var result = Set<String>()
        for id in ids {
            var current: String? = id
            while let nodeID = current {
                result.insert(nodeID)
                current = model.nodes[nodeID]?.parent
            }
        }
        return result
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
}
