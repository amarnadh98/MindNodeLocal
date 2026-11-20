import CoreGraphics
import Foundation
import MapCore
import MapRender

/// Where a drag would land, resolved from the model, the scene, the
/// dragged ids and the model-space cursor point (F-EDT-5). Pure: the
/// same inputs always give the same target, so drop behaviour is
/// headless-testable. The dragged node's own subtree is never a target.
public enum DropTarget: Equatable, Sendable {
    /// Hovering a node: it becomes the drop parent, and `index` is the
    /// slot among its children the subtree takes — the index of the child
    /// to insert **before** in the pre-drop `children` array (equal to the
    /// child count to append). Side-aware for balanced maps: the slot
    /// anchors on the children of the cursor's side of the parent.
    case reparent(parent: String, index: Int)
    /// Hovering the corridor between two siblings under `parent`: land
    /// before the later sibling (`index`, same pre-drop semantics as
    /// `.reparent`), with the model-space segment to draw as the
    /// insertion line.
    case insertBetween(parent: String, index: Int, line: DropLine)
    /// Empty canvas: the dragged nodes become new roots at `point`
    /// (advisory — the stacked-roots layout places them, F-CAN-5).
    case newRoot(at: CGPoint)
    /// Not a valid landing spot (over the dragged subtree itself).
    case none
}

/// A model-space segment to draw as the drag's insertion indicator.
public struct DropLine: Equatable, Sendable {
    public let start: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }
}

/// Resolves the drop target of a node drag (F-EDT-5): hovering a node
/// makes it the drop parent, hovering the corridor between two siblings
/// inserts between them, and empty canvas makes the dragged nodes new
/// roots. The dragged subtrees are excluded everywhere.
///
/// Index semantics: `.reparent` and `.insertBetween` carry the pre-drop
/// `children`-array index of the child to insert before; the
/// command-building half of this file turns that into `moveNode`'s
/// post-removal index.
public enum DropTargetResolver {
    /// How far past the children's outer edge the gap corridor still
    /// accepts a hover.
    public static let corridorPad: CGFloat = 24
    /// Half the default sibling gap (§7.3), the offset of a first/last
    /// slot's insertion line from the neighbouring child.
    static let halfSiblingGap: CGFloat = 6

    public static func resolve(
        model: MapModel,
        scene: CanvasScene,
        dragged: Set<String>,
        point: CGPoint
    ) -> DropTarget {
        guard !dragged.isEmpty, !scene.nodes.isEmpty else { return .newRoot(at: point) }
        let excluded = excludedIDs(dragged: dragged, model: model)

        // Over the dragged subtree itself: never a target (F-EDT-5).
        for id in excluded {
            if let frame = scene.nodes[id]?.frame, frame.contains(point) {
                return .none
            }
        }

        // Hovering a node: it becomes the drop parent.
        if let hit = hitNode(at: point, in: scene, excluding: excluded) {
            return .reparent(
                parent: hit,
                index: slotIndex(
                    model: model, scene: scene, parent: hit, point: point, excluded: excluded))
        }

        // Hovering the corridor between two siblings of some parent.
        if let gap = nearestGap(model: model, scene: scene, point: point, excluded: excluded) {
            return .insertBetween(parent: gap.parent, index: gap.index, line: gap.line)
        }

        // Dragging a child around its own siblings reorders them, wherever
        // along the column the cursor is — above the first and below the
        // last included — instead of tearing it out of its branch.
        if let reorder = ownSiblingTarget(
            model: model, scene: scene, dragged: dragged, point: point)
        {
            return reorder
        }

        return .newRoot(at: point)
    }

    /// How far outside the siblings' column (and the corridor back to
    /// the parent) the cursor still counts as "beside the siblings".
    static let siblingBandPad: CGFloat = 40

    /// The reorder target when every dragged node shares one parent and
    /// the cursor is beside that parent's other children. Nil when the
    /// dragged nodes don't share a parent, there are no other children
    /// to order against, or the cursor is outside the band.
    static func ownSiblingTarget(
        model: MapModel, scene: CanvasScene, dragged: Set<String>, point: CGPoint
    ) -> DropTarget? {
        let parents = Set(dragged.map { model.nodes[$0]?.parent })
        guard parents.count == 1, let optionalParent = parents.first, let parent = optionalParent,
            let parentFrame = scene.nodes[parent]?.frame
        else { return nil }
        let excluded = excludedIDs(dragged: dragged, model: model)
        let anchors = anchorList(model: model, scene: scene, parent: parent, excluded: excluded)
        guard !anchors.isEmpty else { return nil }
        let stack = siblingStacking(of: parent, in: scene)
        let column = sideAnchors(
            anchors: anchors, parentFrame: parentFrame, point: point, stack: stack)
        var band = parentFrame
        for anchor in column { band = band.union(anchor.frame) }
        band = band.insetBy(dx: -siblingBandPad, dy: -siblingBandPad)
        // Along the stacking axis the band is unbounded: any height
        // beside the column reorders.
        let inBand =
            stack == .vertical
            ? point.x >= band.minX && point.x <= band.maxX
            : point.y >= band.minY && point.y <= band.maxY
        guard inBand else { return nil }
        let slot = slotIndex(
            model: model, scene: scene, parent: parent, point: point, excluded: excluded)
        guard
            let line = slotLine(
                model: model, scene: scene, parent: parent, index: slot, dragged: dragged)
        else { return nil }
        return .insertBetween(parent: parent, index: slot, line: line)
    }

    // MARK: hover slots

    /// The axis siblings stack along: mind-map branches run horizontally
    /// so their siblings stack vertically; org-chart branches run
    /// vertically so their siblings stack horizontally. A parent with no
    /// branch in the scene (childless or folded) takes the mind-map
    /// default.
    public static func siblingStacking(of parent: String, in scene: CanvasScene) -> SiblingStack {
        for branch in scene.branches where branch.parentID == parent {
            return branch.axis == .horizontal ? .vertical : .horizontal
        }
        return .vertical
    }

    /// The slot `point` picks among `parent`'s children: the pre-drop
    /// index of the first child the cursor precedes along the stacking
    /// axis, appending when it follows them all. Anchors skip invisible
    /// and dragged children; a balanced root anchors on the cursor's side.
    static func slotIndex(
        model: MapModel,
        scene: CanvasScene,
        parent: String,
        point: CGPoint,
        excluded: Set<String>
    ) -> Int {
        let children = model.nodes[parent]?.children ?? []
        let anchors = anchorList(model: model, scene: scene, parent: parent, excluded: excluded)
        guard !anchors.isEmpty else { return children.count }
        let stack = siblingStacking(of: parent, in: scene)
        let candidates = sideAnchors(
            anchors: anchors, parentFrame: scene.nodes[parent]?.frame, point: point, stack: stack)
        let anchorCoordinate: (Anchor) -> CGFloat =
            stack == .vertical ? { $0.frame.midY } : { $0.frame.midX }
        let cursor = stack == .vertical ? point.y : point.x
        for anchor in candidates where cursor < anchorCoordinate(anchor) {
            return anchor.index
        }
        return children.count
    }

    /// The insertion line to draw for landing at `index` under `parent`
    /// (the `.reparent` placeholder; `.insertBetween` carries its own).
    /// Nil when there is no corridor to draw in (childless/folded parent).
    public static func slotLine(
        model: MapModel,
        scene: CanvasScene,
        parent: String,
        index: Int,
        dragged: Set<String>
    ) -> DropLine? {
        let children = model.nodes[parent]?.children ?? []
        let anchors = anchorList(model: model, scene: scene, parent: parent, excluded: dragged)
        guard let parentFrame = scene.nodes[parent]?.frame, let last = anchors.last else {
            return nil
        }
        let stack = siblingStacking(of: parent, in: scene)
        let boundary: CGFloat
        if index < children.count, let later = anchors.first(where: { $0.index == index }) {
            if let previous = anchors.last(where: { $0.index < index }) {
                boundary =
                    stack == .vertical
                    ? (previous.frame.maxY + later.frame.minY) / 2
                    : (previous.frame.maxX + later.frame.minX) / 2
            } else {
                boundary =
                    stack == .vertical
                    ? later.frame.minY - halfSiblingGap
                    : later.frame.minX - halfSiblingGap
            }
        } else {
            boundary =
                stack == .vertical
                ? last.frame.maxY + halfSiblingGap
                : last.frame.maxX + halfSiblingGap
        }
        return insertionLine(parentFrame: parentFrame, anchors: anchors, stack: stack, boundary: boundary)
    }

    // MARK: sibling anchors

    /// A visible, non-excluded child of a parent, with its pre-drop index.
    struct Anchor {
        let id: String
        let index: Int
        let frame: CGRect
    }

    /// The parent's anchor children in model order — which is the
    /// stacking order of every current layout (each side of a balanced
    /// root preserves model order top-to-bottom).
    static func anchorList(
        model: MapModel, scene: CanvasScene, parent: String, excluded: Set<String>
    ) -> [Anchor] {
        var result: [Anchor] = []
        for (index, childID) in (model.nodes[parent]?.children ?? []).enumerated() {
            guard let frame = scene.nodes[childID]?.frame, !excluded.contains(childID) else {
                continue
            }
            result.append(Anchor(id: childID, index: index, frame: frame))
        }
        return result
    }

    /// A balanced root fans both sides: anchors stay on the cursor's side
    /// of the parent. Any other parent (or a one-sided root) keeps all.
    static func sideAnchors(
        anchors: [Anchor], parentFrame: CGRect?, point: CGPoint, stack: SiblingStack
    ) -> [Anchor] {
        let columns = splitBySide(anchors: anchors, parentFrame: parentFrame, stack: stack)
        guard columns.count > 1 else { return columns.first ?? anchors }
        let center = stack == .vertical ? parentFrame?.midX ?? 0 : parentFrame?.midY ?? 0
        let cursor = stack == .vertical ? point.x : point.y
        let side = cursor < center ? columns[0] : columns[1]
        return side.isEmpty ? anchors : side
    }

    /// Splits anchors into the parent's two sides when it fans both ways
    /// (a balanced root); otherwise one column.
    static func splitBySide(
        anchors: [Anchor], parentFrame: CGRect?, stack: SiblingStack
    ) -> [[Anchor]] {
        guard let parentFrame, anchors.count > 1 else { return [anchors] }
        let coordinate: (CGRect) -> CGFloat = stack == .vertical ? { $0.midX } : { $0.midY }
        let center = stack == .vertical ? parentFrame.midX : parentFrame.midY
        let before = anchors.filter { coordinate($0.frame) < center }
        let after = anchors.filter { coordinate($0.frame) >= center }
        return before.isEmpty || after.isEmpty ? [anchors] : [before, after]
    }

    // MARK: gap corridors

    struct GapCandidate {
        let parent: String
        let index: Int
        let line: DropLine
        let distance: CGFloat
    }

    /// The gap corridor containing `point`, nearest to it. Corridors of
    /// nested subtrees can overlap; distance to the insertion line
    /// resolves the tie, then parent and index for determinism.
    static func nearestGap(
        model: MapModel, scene: CanvasScene, point: CGPoint, excluded: Set<String>
    ) -> GapCandidate? {
        var best: GapCandidate?
        for parent in scene.nodes.keys.sorted() {
            guard let parentFrame = scene.nodes[parent]?.frame else { continue }
            let anchors = anchorList(
                model: model, scene: scene, parent: parent, excluded: excluded)
            guard anchors.count > 1 else { continue }
            let stack = siblingStacking(of: parent, in: scene)
            for column in splitBySide(anchors: anchors, parentFrame: parentFrame, stack: stack) {
                for position in column.indices.dropLast() {
                    let before = column[position]
                    let after = column[position + 1]
                    guard let zone = gapZone(parentFrame: parentFrame, before: before, after: after, stack: stack),
                        zone.contains(point)
                    else { continue }
                    let boundary =
                        stack == .vertical
                        ? (before.frame.maxY + after.frame.minY) / 2
                        : (before.frame.maxX + after.frame.minX) / 2
                    guard
                        let line = insertionLine(
                            parentFrame: parentFrame, anchors: column, stack: stack, boundary: boundary)
                    else { continue }
                    let candidate = GapCandidate(
                        parent: parent, index: after.index, line: line,
                        distance: distance(from: point, to: line))
                    if let current = best {
                        let currentKey = (current.distance, current.parent, current.index)
                        let candidateKey = (candidate.distance, candidate.parent, candidate.index)
                        guard candidateKey < currentKey else { continue }
                    }
                    best = candidate
                }
            }
        }
        return best
    }

    /// The hover-accepting rect between stacked siblings `a` (before) and
    /// `after`, spanning the branch corridor from the parent's edge to just
    /// past the children's outer edge.
    static func gapZone(
        parentFrame: CGRect, before: Anchor, after: Anchor, stack: SiblingStack
    ) -> CGRect? {
        switch stack {
        case .vertical:
            let childrenRight = before.frame.midX >= parentFrame.midX
            let xMin =
                childrenRight
                ? parentFrame.maxX
                : min(before.frame.minX, after.frame.minX) - corridorPad
            let xMax =
                childrenRight
                ? max(before.frame.maxX, after.frame.maxX) + corridorPad
                : parentFrame.minX
            return validRect(xMin: xMin, yMin: before.frame.maxY, xMax: xMax, yMax: after.frame.minY)
        case .horizontal:
            let childrenBelow = before.frame.midY >= parentFrame.midY
            let yMin =
                childrenBelow
                ? parentFrame.maxY
                : min(before.frame.minY, after.frame.minY) - corridorPad
            let yMax =
                childrenBelow
                ? max(before.frame.maxY, after.frame.maxY) + corridorPad
                : parentFrame.minY
            return validRect(xMin: before.frame.maxX, yMin: yMin, xMax: after.frame.minX, yMax: yMax)
        }
    }

    /// The insertion-line segment at stacking coordinate `boundary`,
    /// spanning the corridor from the parent's edge to the children
    /// column's inner edge.
    static func insertionLine(
        parentFrame: CGRect, anchors: [Anchor], stack: SiblingStack, boundary: CGFloat
    ) -> DropLine? {
        guard let first = anchors.first, let last = anchors.last else { return nil }
        switch stack {
        case .vertical:
            let childrenRight = first.frame.midX >= parentFrame.midX
            let parentEdge = childrenRight ? parentFrame.maxX : parentFrame.minX
            let innerEdge =
                childrenRight
                ? min(first.frame.minX, last.frame.minX)
                : max(first.frame.maxX, last.frame.maxX)
            guard parentEdge != innerEdge else { return nil }
            return DropLine(
                start: CGPoint(x: parentEdge, y: boundary),
                end: CGPoint(x: innerEdge, y: boundary))
        case .horizontal:
            let childrenBelow = first.frame.midY >= parentFrame.midY
            let parentEdge = childrenBelow ? parentFrame.maxY : parentFrame.minY
            let innerEdge =
                childrenBelow
                ? min(first.frame.minY, last.frame.minY)
                : max(first.frame.maxY, last.frame.maxY)
            guard parentEdge != innerEdge else { return nil }
            return DropLine(
                start: CGPoint(x: boundary, y: parentEdge),
                end: CGPoint(x: boundary, y: innerEdge))
        }
    }

    // MARK: geometry helpers

    /// The dragged ids plus every descendant: all excluded as targets.
    static func excludedIDs(dragged: Set<String>, model: MapModel) -> Set<String> {
        var excluded = Set<String>()
        var stack = Array(dragged)
        while let id = stack.popLast() {
            guard excluded.insert(id).inserted else { continue }
            for childID in model.nodes[id]?.children ?? [] {
                stack.append(childID)
            }
        }
        return excluded
    }

    /// The smallest scene node whose frame contains `point` (the most
    /// specific target when frames are defensive overlaps), ids breaking
    /// area ties so the result is deterministic.
    static func hitNode(
        at point: CGPoint, in scene: CanvasScene, excluding excluded: Set<String>
    ) -> String? {
        var best: (id: String, area: CGFloat)?
        for (id, node) in scene.nodes where !excluded.contains(id) {
            guard node.frame.contains(point) else { continue }
            let area = node.frame.width * node.frame.height
            if let current = best, current.area < area || (current.area == area && current.id < id) {
                continue
            }
            best = (id, area)
        }
        return best?.id
    }

    /// Euclidean distance from `point` to the closest point on `line`.
    static func distance(from point: CGPoint, to line: DropLine) -> CGFloat {
        let dx = line.end.x - line.start.x
        let dy = line.end.y - line.start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - line.start.x, point.y - line.start.y)
        }
        let projection = ((point.x - line.start.x) * dx + (point.y - line.start.y) * dy) / lengthSquared
        let clamped = min(max(projection, 0), 1)
        return hypot(
            point.x - line.start.x - clamped * dx,
            point.y - line.start.y - clamped * dy)
    }

    static func validRect(xMin: CGFloat, yMin: CGFloat, xMax: CGFloat, yMax: CGFloat) -> CGRect? {
        guard xMax > xMin, yMax > yMin else { return nil }
        return CGRect(x: xMin, y: yMin, width: xMax - xMin, height: yMax - yMin)
    }
}

/// The axis siblings stack along (perpendicular to their branches).
public enum SiblingStack {
    case vertical
    case horizontal
}

// MARK: - commands

/// Builds the one command a finished drag performs (F-EDT-5: a drag is
/// one undo step). All builders are pure over the pre-drop model.
///
/// Index mapping: the resolver's slot is "insert before child `k`" in
/// the pre-drop array, but `moveNode` removes the dragged node before
/// inserting, so its index counts the survivors that precede the slot.
/// Moving the dragged ids in order, each lands at
/// `survivorsBefore + position` and the whole group reproduces the
/// intended visual order exactly.
public enum DragCommands {
    /// F-LAY-11: releasing within this distance of the auto slot snaps
    /// back (the offset clears instead of being set).
    public static let snapBackDistance: CGFloat = 24

    /// The selected ids no other selected id is an ancestor of — those
    /// move; their descendants travel along inside their subtrees.
    public static func topmost(_ selected: Set<String>, in model: MapModel) -> [String] {
        selected.filter { id in
            var parent = model.nodes[id]?.parent
            while let parentID = parent {
                if selected.contains(parentID) { return false }
                parent = model.nodes[parentID]?.parent
            }
            return true
        }.sorted()
    }

    /// The dragged ids in their landing order under `parent`: along the
    /// parent's sibling stacking axis so a multi-drag keeps its visual
    /// order (ids without frames sort last, then by id).
    public static func orderedByStacking(
        _ ids: [String], in scene: CanvasScene, parent: String
    ) -> [String] {
        let stack = DropTargetResolver.siblingStacking(of: parent, in: scene)
        func coordinate(_ id: String) -> CGFloat {
            guard let frame = scene.nodes[id]?.frame else { return .greatestFiniteMagnitude }
            return stack == .vertical ? frame.midY : frame.midX
        }
        return ids.sorted { coordinate($0) == coordinate($1) ? $0 < $1 : coordinate($0) < coordinate($1) }
    }

    /// Moves `dragged` (topmost ids in intended landing order) under
    /// `parent` at the resolver's pre-drop `slot`, as one command.
    public static func reparent(
        model: MapModel, dragged: [String], parent: String, slot: Int
    ) -> MapCommand? {
        let children = model.nodes[parent]?.children ?? []
        let clamped = min(max(slot, 0), children.count)
        let draggedSet = Set(dragged)
        let survivorsBefore = children[0..<clamped].filter { !draggedSet.contains($0) }.count
        var commands: [MapCommand] = []
        for (position, id) in dragged.enumerated() where id != parent {
            commands.append(.moveNode(id: id, parent: parent, index: survivorsBefore + position))
        }
        return grouped(commands)
    }

    /// Drops `dragged` as new roots (empty canvas), appended after the
    /// surviving roots in their current order.
    public static func newRoots(model: MapModel, dragged: [String]) -> MapCommand? {
        let survivors = model.roots.filter { !dragged.contains($0) }.count
        var commands: [MapCommand] = []
        for (position, id) in dragged.enumerated() {
            commands.append(.moveNode(id: id, parent: nil, index: survivors + position))
        }
        return grouped(commands)
    }

    /// Detaches each dragged node into a new root (roots have nothing to
    /// detach from and are skipped).
    public static func detach(model: MapModel, dragged: [String]) -> MapCommand? {
        let commands = dragged.compactMap { id in
            model.nodes[id]?.parent != nil ? MapCommand.detach(id: id) : nil
        }
        return grouped(commands)
    }

    /// ⌥ drop (F-LAY-11): keeps the parent and free-positions via a
    /// manual offset. The ghost's delta accumulates onto any existing
    /// offset; a resulting position within `snapBackDistance` of the auto
    /// slot clears the offset instead.
    public static func offsets(
        model: MapModel, dragged: [String], delta: CGPoint
    ) -> MapCommand? {
        var commands: [MapCommand] = []
        for id in dragged {
            let current = model.nodes[id]?.offset
            let x = (current?.x ?? 0) + delta.x
            let y = (current?.y ?? 0) + delta.y
            let offset = hypot(x, y) < snapBackDistance ? nil : ModelOffset(x: x, y: y)
            commands.append(.setOffset(id: id, offset: offset))
        }
        return grouped(commands)
    }

    /// True when performing `command` would leave the model unchanged
    /// (dropped straight back into its own slot), so the drag should
    /// register no undo step.
    public static func isNoOp(_ command: MapCommand, in model: MapModel) -> Bool {
        switch command {
        case .moveNode(let id, let parent, let index):
            guard model.nodes[id]?.parent == parent else { return false }
            let siblings = parent.flatMap { model.nodes[$0]?.children } ?? model.roots
            return siblings.firstIndex(of: id) == index
        case .group(_, let commands):
            return !commands.isEmpty && commands.allSatisfy { isNoOp($0, in: model) }
        default:
            return false
        }
    }

    /// One command (or nil), grouping when the drag moves several nodes.
    static func grouped(_ commands: [MapCommand]) -> MapCommand? {
        switch commands.count {
        case 0:
            nil
        case 1:
            commands[0]
        default:
            .group(name: "Move Node", commands: commands)
        }
    }
}
