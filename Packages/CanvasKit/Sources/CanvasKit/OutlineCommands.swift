import Foundation
import MapCore

/// One user action in the outline as a single undo step: the command
/// to perform (already grouped where the gesture needs it) plus what
/// the UI does afterwards — the row to keep selected, and an optional
/// UTF-16 caret position for the rows that end inside an editing
/// session (merge puts the caret at the junction).
public struct OutlineAction: Sendable, Equatable {
    public let command: MapCommand
    public let focus: String
    public let caret: Int?

    public init(command: MapCommand, focus: String, caret: Int? = nil) {
        self.command = command
        self.focus = focus
        self.caret = caret
    }
}

/// Pure outline command builders (F-OUT-3/4): every keyboard and
/// drag-and-drop gesture maps to exactly ONE `MapCommand` — a bare
/// command, or a `.group` when the gesture combines several — so the
/// store registers exactly one undo step. No-op states return nil, so
/// no phantom undo steps register. Everything is computed from the
/// pre-command model; nothing here mutates it.
public enum OutlineCommands {
    // MARK: title surgery (UTF-16 units, the Run range convention)

    /// Splits `title` at `caret` (UTF-16 units, clamped): the head
    /// keeps the runs that intersect the prefix, the tail shifts its
    /// runs to start at zero.
    public static func split(title: NodeTitle, at caret: Int) -> (head: NodeTitle, tail: NodeTitle) {
        let length = (title.text as NSString).length
        let cut = min(max(caret, 0), length)
        let headText = (title.text as NSString).substring(to: cut)
        let tailText = (title.text as NSString).substring(from: cut)
        var headRuns: [Run] = []
        var tailRuns: [Run] = []
        for run in title.runs {
            if let clippedHead = clipped(run, in: 0..<cut) {
                headRuns.append(clippedHead)
            }
            if let clippedTail = clipped(run, in: cut..<length) {
                var tailRun = clippedTail
                tailRun.range = [tailRun.range[0] - cut, tailRun.range[1]]
                tailRuns.append(tailRun)
            }
        }
        return (NodeTitle(text: headText, runs: headRuns), NodeTitle(text: tailText, runs: tailRuns))
    }

    /// `lhs` + `rhs` with `rhs`'s runs shifted past `lhs`'s text —
    /// merge appends the deleted row's (draft) title to the row above.
    public static func appended(_ lhs: NodeTitle, _ rhs: NodeTitle) -> NodeTitle {
        let shift = (lhs.text as NSString).length
        let shifted = rhs.runs.map { run -> Run in
            var copy = run
            if !copy.range.isEmpty { copy.range[0] += shift }
            return copy
        }
        return NodeTitle(text: lhs.text + rhs.text, runs: lhs.runs + shifted)
    }

    /// `run` clipped to `window`, or nil when they do not intersect.
    private static func clipped(_ run: Run, in window: Range<Int>) -> Run? {
        guard let start = run.range.first, run.range.count > 1 else { return nil }
        let end = start + run.range[1]
        let overlapStart = max(start, window.lowerBound)
        let overlapEnd = min(end, window.upperBound)
        guard overlapEnd > overlapStart else { return nil }
        var copy = run
        copy.range = [overlapStart, overlapEnd - overlapStart]
        return copy
    }

    // MARK: ⏎ new row / split (F-OUT-3)

    /// ⏎: one grouped step that turns the current draft into the
    /// head, and inserts a fresh row below carrying the tail (an empty
    /// tail when the caret sits at the end — the plain "new row" case
    /// when not editing). A root splits into the next root section.
    /// The fresh row is the focus, in edit mode.
    public static func splitCommand(
        id: String, caret: Int, draft: NodeTitle, in model: MapModel
    ) -> OutlineAction? {
        guard let node = model.nodes[id] else { return nil }
        let (head, tail) = split(title: draft, at: caret)
        let fresh = Node(id: UUID().uuidString, title: tail)
        var commands: [MapCommand] = []
        if head != node.title {
            commands.append(.editText(id: id, title: head))
        }
        if node.parent == nil {
            let slot = model.roots.firstIndex(of: id) ?? model.roots.count
            commands.append(.addRoot(index: slot + 1, node: fresh))
        } else {
            commands.append(.addSibling(anchor: id, before: false, node: fresh))
        }
        return OutlineAction(command: grouped("Split Row", commands), focus: fresh.id)
    }

    // MARK: ⌫ merge with previous row (F-OUT-3)

    /// ⌫ at the start: the row joins the row displayed above — its
    /// (draft) title is appended to that row's title, its children
    /// become that row's children, and the row itself is deleted. One
    /// grouped step; nil when there is no row above (the very first
    /// row). The focus is the merged row with the caret at the text
    /// junction.
    public static func mergeCommand(
        id: String, draft: NodeTitle, in model: MapModel, sideOf: (String) -> SidePin?
    ) -> OutlineAction? {
        guard let node = model.nodes[id] else { return nil }
        guard
            let previous = OutlineModel.previousRow(before: id, in: model, sideOf: sideOf)?.id,
            let target = model.nodes[previous]
        else { return nil }
        let merged = appended(target.title, draft)
        var commands: [MapCommand] = []
        if merged != target.title {
            commands.append(.editText(id: previous, title: merged))
        }
        // Children of the merged row land under the merge target, in
        // order, appended after the target's own children.
        for (offset, child) in node.children.enumerated() {
            commands.append(.moveNode(id: child, parent: previous, index: target.children.count + offset))
        }
        // The row is now childless: deleting it promotes nothing.
        commands.append(.deleteNodePromotingChildren(id: id))
        let junction = (target.title.text as NSString).length
        return OutlineAction(command: grouped("Merge Rows", commands), focus: previous, caret: junction)
    }

    // MARK: ⇥ / ⇧⇥ indent & outdent (F-OUT-3)

    /// ⇥: the row becomes the last child of its previous **displayed**
    /// sibling (nil when it is the first of its group) — one level
    /// deeper, always. A folded target unfolds in the same step, so
    /// the indented row stays visible.
    public static func indentCommand(
        id: String, in model: MapModel, sideOf: (String) -> SidePin?
    ) -> OutlineAction? {
        guard model.nodes[id] != nil else { return nil }
        guard
            let sibling = OutlineModel.previousDisplayedSibling(of: id, in: model, sideOf: sideOf)
        else { return nil }
        let end = model.nodes[sibling]?.children.count ?? 0
        var commands: [MapCommand] = [.moveNode(id: id, parent: sibling, index: end)]
        if model.nodes[sibling]?.folded == true {
            commands.append(.setFolded(id: sibling, folded: false))
        }
        return OutlineAction(command: grouped("Indent Row", commands), focus: id)
    }

    /// ⇧⇥: one level shallower — the model's `promote` (the same
    /// command the map's ⌘← performs), which makes the row the sibling
    /// after its parent. A root has nothing to outdent from.
    public static func outdentCommand(id: String, in model: MapModel) -> OutlineAction? {
        guard model.nodes[id]?.parent != nil else { return nil }
        return OutlineAction(command: .promote(id: id), focus: id)
    }

    // MARK: ⌘↑ / ⌘↓ move (F-OUT-3)

    /// ⌘↑/⌘↓: one displayed slot up/down among the row's group. On a
    /// balanced root's first level the two sides are traversed in the
    /// clockwise display order (see `OutlineModel.displayedChildren`);
    /// crossing the left/right boundary pins the row to the target's
    /// side (one grouped step), exactly like dragging the branch to
    /// the other side of the map. nil at the edges of the group.
    public static func moveCommand(
        id: String, downward: Bool, in model: MapModel, sideOf: (String) -> SidePin?
    ) -> OutlineAction? {
        guard let node = model.nodes[id] else { return nil }
        let parent = node.parent
        // First-level rows (children of a root) display permuted.
        let permuted = parent != nil && model.nodes[parent ?? ""]?.parent == nil
        let siblings = parent.flatMap { model.nodes[$0]?.children } ?? model.roots
        guard let slot = siblings.firstIndex(of: id) else { return nil }
        let displayed = OutlineModel.displayedChildren(of: parent, in: model, sideOf: sideOf)
        guard let displayedSlot = displayed.firstIndex(of: id) else { return nil }
        let targetDisplayed = displayedSlot + (downward ? 1 : -1)
        guard displayed.indices.contains(targetDisplayed) else { return nil }
        let target = displayed[targetDisplayed]
        let targetLeft = permuted && sideOf(target) == .left

        var arranged = siblings
        arranged.remove(at: slot)
        guard let arrangedSlot = arranged.firstIndex(of: target) else { return nil }
        // Model insertion index that lands the row in the target's
        // displayed slot: right-region slots sit after the target in
        // the children array, left-region (reversed) slots before it.
        let insert =
            downward
            ? (targetLeft ? arrangedSlot : arrangedSlot + 1)
            : (targetLeft ? arrangedSlot + 1 : arrangedSlot)
        let crossing = permuted && (sideOf(id) == .left) != targetLeft
        if insert == slot && !crossing { return nil }

        var commands: [MapCommand] = []
        if crossing {
            commands.append(.setSide(id: id, side: targetLeft ? .left : .right))
        }
        commands.append(.moveNode(id: id, parent: parent, index: insert))
        return OutlineAction(command: grouped("Move Node", commands), focus: id)
    }

    // MARK: ⌥⌘← / ⌥⌘→ fold & unfold (F-OUT-3, F-LAY-14)

    /// One `setFolded` step; nil for leaves and no-op states.
    public static func foldCommand(id: String, folded: Bool, in model: MapModel) -> OutlineAction? {
        guard let node = model.nodes[id], !node.children.isEmpty, node.folded != folded else {
            return nil
        }
        return OutlineAction(command: .setFolded(id: id, folded: folded), focus: id)
    }

    // MARK: drag & drop (F-OUT-4)

    /// A finished row drag: `asChild` drops the subtree as the target's
    /// last child (a folded target unfolds in the same step); otherwise
    /// the row lands as the sibling directly **below** the target in
    /// displayed order (the gap the insertion line drew), following
    /// the same side-aware insertion as ⌘↑/⌘↓. One command either way,
    /// or nil for a drop onto itself / into its own subtree / a no-op.
    public static func dropCommand(
        dragged: String,
        target: String,
        asChild: Bool,
        in model: MapModel,
        sideOf: (String) -> SidePin?
    ) -> OutlineAction? {
        guard dragged != target,
            let draggedNode = model.nodes[dragged],
            let targetNode = model.nodes[target]
        else { return nil }
        guard !OutlineModel.descendantIDs(of: [dragged], in: model).contains(target) else { return nil }

        if asChild {
            var commands: [MapCommand] = [
                .moveNode(id: dragged, parent: target, index: targetNode.children.count)
            ]
            if targetNode.folded {
                commands.append(.setFolded(id: target, folded: false))
            }
            return OutlineAction(command: grouped("Move Node", commands), focus: dragged)
        }

        // Sibling below the target, within its group.
        guard let parent = targetNode.parent else {
            // The target is a root: the dragged row becomes the next
            // root section (a root dragged onto another root).
            guard let slot = model.roots.firstIndex(of: target) else { return nil }
            let insert = slot + 1
            if draggedNode.parent == nil, insert == model.roots.firstIndex(of: dragged) {
                return nil
            }
            return OutlineAction(
                command: .moveNode(id: dragged, parent: nil, index: insert), focus: dragged)
        }
        let permuted = model.nodes[parent]?.parent == nil
        guard let siblings = model.nodes[parent]?.children else { return nil }
        let targetLeft = permuted && sideOf(target) == .left
        var arranged = siblings
        if let draggedSlot = arranged.firstIndex(of: dragged) {
            arranged.remove(at: draggedSlot)
        }
        guard let arrangedSlot = arranged.firstIndex(of: target) else { return nil }
        let insert = targetLeft ? arrangedSlot : arrangedSlot + 1
        let crossing = permuted && (sideOf(dragged) == .left) != targetLeft
        // No-op: the dragged row is already the sibling displayed
        // directly below the target (compared in DISPLAYED order — on
        // the left side a different model slot can display identically).
        if !crossing {
            let displayed = OutlineModel.displayedChildren(of: parent, in: model, sideOf: sideOf)
            if let draggedAt = displayed.firstIndex(of: dragged),
                let targetAt = displayed.firstIndex(of: target), draggedAt == targetAt + 1
            {
                return nil
            }
        }

        var commands: [MapCommand] = []
        if crossing {
            commands.append(.setSide(id: dragged, side: targetLeft ? .left : .right))
        }
        commands.append(.moveNode(id: dragged, parent: parent, index: insert))
        return OutlineAction(command: grouped("Move Node", commands), focus: dragged)
    }

    // MARK: grouping

    /// One grouped command (or the bare command when there is only
    /// one), so each gesture is exactly one undo step.
    private static func grouped(_ name: String, _ commands: [MapCommand]) -> MapCommand {
        commands.count == 1 ? commands[0] : .group(name: name, commands: commands)
    }
}
