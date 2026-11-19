import CoreGraphics
import MapCore
import MapRender

/// The four spatial selection-move directions of F-CAN-4's arrow keys.
public enum Direction: String, Sendable, CaseIterable {
    case up
    case down
    case left
    case right
}

/// Spatial arrow navigation over a laid-out scene (F-CAN-4): pure
/// functions, no state, so the canvas, menus and future consumers
/// (outline sync, VoiceOver focus) share one semantic.
///
/// Structure is read from the scene's own branch geometry, which
/// `SceneGeometry` already classifies per edge: mind-map children leave
/// left/right of the parent, org-chart children below/above. Folded
/// children are absent from the scene, so they are never targets.
public enum SpatialNavigator {
    /// How strongly off-axis candidates are penalized in the pure
    /// geometry fallback: the frame-centre distance is scaled by
    /// `1 + conePenalty × perpendicular / parallel`, so a candidate
    /// straight in the pressed direction beats an equally distant one
    /// far off-axis.
    public static let conePenalty: CGFloat = 1.5

    /// Centre displacement (points) that doesn't count as being "in" a
    /// direction. Layout never aligns distinct nodes this closely; the
    /// epsilon only guards float noise.
    private static let alignmentEpsilon: CGFloat = 0.5

    // MARK: target

    /// The node the arrow key `direction` should select from `id`, or
    /// nil at the edge of the map.
    ///
    /// Mind maps (branches leave left/right): the pressed direction
    /// dives into the subtree on that side — the child nearest
    /// vertically — and the opposite direction climbs to the parent;
    /// on the left side of a balanced map these mirror, so ← descends
    /// and → climbs (F-CAN-4). Up/down move to the nearest sibling,
    /// falling back to the nearest node by geometry. Org charts mirror
    /// this on the vertical axis: ↓/↑ dive and climb, ←/→ step between
    /// siblings.
    public static func target(
        from id: String,
        direction: Direction,
        scene: CanvasScene,
        model: MapModel
    ) -> String? {
        guard let node = scene.nodes[id] else { return nil }
        let outgoing = scene.branches.filter { $0.parentID == id }
        let incoming = scene.branches.first { $0.childID == id }

        // Dive: the pressed direction follows branches leaving on that
        // side (mind map →/←, org chart ↓/↑).
        let outward = outwardBranchDirection(of: direction)
        let dives = outgoing.filter { $0.direction == outward }
        if let dive = nearestDive(among: dives, of: id, in: scene, direction: direction) {
            return dive
        }

        // Climb: this node's own incoming branch enters from the
        // opposite side, so the pressed direction returns to the parent.
        if let incoming, incoming.direction == opposite(of: outward) {
            return incoming.parentID
        }

        // ←/→ inside an org-chart row step between siblings rather than
        // falling straight to geometry; mind-map ↑/↓ always prefer the
        // nearest sibling branch. Roots have no siblings.
        if let sibling = nearestSibling(
            of: id, towards: direction, scene: scene, model: model)
        {
            if isVerticalLayout(outgoing: outgoing, incoming: incoming) {
                return sibling
            }
            if direction == .up || direction == .down {
                return sibling
            }
        }

        // No structural step applies: the nearest node by geometry in
        // the pressed direction (a right-side leaf's → lands on the
        // sibling subtree beyond it, a root's ↓ on the branch below).
        return nearestByGeometry(
            from: node.frame, direction: direction, scene: scene, excluding: [id])
    }

    /// ⇧-arrow (§6.1 Select): the navigation target joins the
    /// selection. Returns the selection unchanged at the map edge.
    public static func extendSelection(
        _ selection: Set<String>,
        from id: String,
        direction: Direction,
        scene: CanvasScene,
        model: MapModel
    ) -> Set<String> {
        guard
            let target = target(from: id, direction: direction, scene: scene, model: model)
        else { return selection }
        var result = selection
        result.insert(target)
        return result
    }

    // MARK: roots

    /// ⌃⌥N: the next root in creation (outline) order after `id`'s
    /// tree, or nil at the last root. Works from any node in the tree.
    public static func nextRoot(after id: String, model: MapModel) -> String? {
        root(offset: 1, from: id, model: model)
    }

    /// ⌃⌥P: the previous root before `id`'s tree, or nil at the first.
    public static func previousRoot(before id: String, model: MapModel) -> String? {
        root(offset: -1, from: id, model: model)
    }

    private static func root(offset: Int, from id: String, model: MapModel) -> String? {
        // Walk up to the containing root; the chain is short (tree
        // depth) and the cycle guard is only defensive (the validator
        // already rejects cycles).
        var current = id
        var seen: Set<String> = [id]
        while let parent = model.nodes[current]?.parent, parent != current,
            !seen.contains(parent)
        {
            seen.insert(parent)
            current = parent
        }
        guard let index = model.roots.firstIndex(of: current) else { return nil }
        let target = index + offset
        guard model.roots.indices.contains(target) else { return nil }
        return model.roots[target]
    }

    // MARK: scroll-into-view

    /// F-CAN-7: the minimal camera that makes `frame` fully visible
    /// with `margin` screen points of breathing room. A frame already
    /// fully inside the viewport is left untouched, so arrows never
    /// jitter the camera while the user navigates within the view;
    /// otherwise only the axes that overflow move, each by exactly its
    /// deficit plus the margin. A frame too large for the viewport
    /// aligns its leading edge.
    public static func scrollIntoView(
        camera: Camera,
        viewport: CGSize,
        frame: CGRect,
        margin: CGFloat = 40
    ) -> Camera {
        guard viewport.width > 0, viewport.height > 0, camera.scale > 0, !frame.isNull else {
            return camera
        }
        let visible = camera.visibleRect(viewportSize: viewport)
        guard !visible.contains(frame) else { return camera }
        // The margin lives in screen points: shrink the model-space
        // rect by its scaled equivalent, so the moved frame ends up
        // `margin` from the viewport edge at any zoom.
        let target = visible.insetBy(dx: margin / camera.scale, dy: margin / camera.scale)
        var origin = camera.origin
        if frame.minX < target.minX {
            origin.x -= target.minX - frame.minX
        } else if frame.maxX > target.maxX {
            origin.x += frame.maxX - target.maxX
        }
        if frame.minY < target.minY {
            origin.y -= target.minY - frame.minY
        } else if frame.maxY > target.maxY {
            origin.y += frame.maxY - target.maxY
        }
        return Camera(origin: origin, scale: camera.scale)
    }

    // MARK: scoring

    /// The child the pressed direction dives to: the one nearest
    /// vertically for horizontal layouts, nearest horizontally for
    /// vertical ones. Ties keep the first branch (child order).
    private static func nearestDive(
        among dives: [SceneBranch], of id: String, in scene: CanvasScene, direction: Direction
    ) -> String? {
        guard let reference = scene.nodes[id]?.frame else { return nil }
        var best: (id: String, delta: CGFloat)?
        for branch in dives {
            guard let frame = scene.nodes[branch.childID]?.frame else { continue }
            let delta: CGFloat
            switch direction {
            case .left, .right: delta = abs(frame.midY - reference.midY)
            case .up, .down: delta = abs(frame.midX - reference.midX)
            }
            if best == nil || delta < best!.delta {
                best = (branch.childID, delta)
            }
        }
        return best?.id
    }

    /// The nearest sibling whose frame lies in `direction`: mind-map
    /// ↓/↑ steps and org-chart ←/→ steps. Roots have no siblings.
    /// Hidden (folded) siblings are absent from the scene and skipped.
    private static func nearestSibling(
        of id: String, towards direction: Direction, scene: CanvasScene, model: MapModel
    ) -> String? {
        guard let node = scene.nodes[id] else { return nil }
        guard let parentID = model.nodes[id]?.parent,
            let siblings = model.nodes[parentID]?.children
        else { return nil }
        var best: (id: String, delta: CGFloat, cross: CGFloat)?
        for siblingID in siblings where siblingID != id {
            guard let frame = scene.nodes[siblingID]?.frame else { continue }
            let (delta, cross) = displacement(from: node.frame, to: frame, direction: direction)
            guard delta > alignmentEpsilon else { continue }
            if best == nil || delta < best!.delta
                || (delta == best!.delta && cross < best!.cross)
            {
                best = (siblingID, delta, cross)
            }
        }
        return best?.id
    }

    /// Pure-geometry fallback: the scene node whose frame centre is
    /// nearest to `frame`'s centre in `direction`, scored by centre
    /// distance weighted with the angular cone penalty.
    static func nearestByGeometry(
        from frame: CGRect,
        direction: Direction,
        scene: CanvasScene,
        excluding: Set<String>
    ) -> String? {
        var best: (id: String, score: CGFloat)?
        for (candidateID, candidate) in scene.nodes where !excluding.contains(candidateID) {
            let (parallel, cross) = displacement(
                from: frame, to: candidate.frame, direction: direction)
            guard parallel > alignmentEpsilon else { continue }
            let distance = hypot(parallel, cross)
            let score = distance * (1 + conePenalty * cross / parallel)
            if best == nil || score < best!.score
                || (score == best!.score && candidateID < best!.id)
            {
                best = (candidateID, score)
            }
        }
        return best?.id
    }

    /// Signed displacement along the pressed axis (positive = in that
    /// direction) and the absolute displacement across it.
    private static func displacement(
        from base: CGRect, to other: CGRect, direction: Direction
    ) -> (parallel: CGFloat, cross: CGFloat) {
        switch direction {
        case .right: (other.midX - base.midX, abs(other.midY - base.midY))
        case .left: (base.midX - other.midX, abs(other.midY - base.midY))
        case .down: (other.midY - base.midY, abs(other.midX - base.midX))
        case .up: (base.midY - other.midY, abs(other.midX - base.midX))
        }
    }

    /// The branch direction that leaves a node towards the pressed
    /// direction: → follows right-pointing branches, ↓ the down ones.
    private static func outwardBranchDirection(of direction: Direction) -> BranchDirection {
        switch direction {
        case .right: .right
        case .left: .left
        case .down: .down
        case .up: .up
        }
    }

    private static func opposite(of direction: BranchDirection) -> BranchDirection {
        switch direction {
        case .right: .left
        case .left: .right
        case .down: .up
        case .up: .down
        }
    }

    /// Whether this node's own edges are org-chart verticals.
    private static func isVerticalLayout(
        outgoing: [SceneBranch], incoming: SceneBranch?
    ) -> Bool {
        let vertical: (BranchDirection) -> Bool = { $0 == .up || $0 == .down }
        return outgoing.contains { vertical($0.direction) }
            || incoming.map { vertical($0.direction) } == true
    }
}
