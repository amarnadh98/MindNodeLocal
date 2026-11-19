import Foundation

/// A node's completed/total ratio over its **leaf tasks** (F-TSK-2): a
/// leaf task is a task node with no task descendants, and a parent's
/// ring fills to that ratio. Pure value; `TaskProgress.index` computes
/// the whole document in one pass.
public struct TaskRatio: Sendable, Equatable, Hashable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    /// Completed/total, 0 when there are no tasks.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    /// The ring's hover text (F-TSK-2): "7 of 12 · 58%".
    public var tooltip: String {
        let percent = Int((fraction * 100).rounded())
        return "\(completed) of \(total) · \(percent)%"
    }
}

/// Task progress over a whole map (F-TSK-2): one post-order pass per
/// root aggregates each node's leaf tasks into a completed/total ratio.
/// The index holds exactly the **ring** nodes — nodes with task
/// descendants; a leaf task (a task with no task descendants) renders a
/// checkbox instead (F-TSK-1) and never appears here. Pure and
/// `Sendable` — the canvas, outline and export all share it.
public enum TaskProgress {
    /// Per-node ratios for nodes whose subtree holds at least one leaf
    /// task that is NOT the node itself (i.e. nodes with task
    /// descendants — the progress-ring set of F-TSK-2).
    public static func index(_ model: MapModel) -> [String: TaskRatio] {
        // A task-free map skips the whole walk (the common case keeps
        // the §11.8 keystroke budget).
        var hasTask = false
        for node in model.nodes.values {
            if node.task != nil {
                hasTask = true
                break
            }
        }
        guard hasTask else { return [:] }
        var ratios: [String: TaskRatio] = [:]
        // Iterative post-order: fold each child's aggregate into its
        // parent, tracking whether the node itself is a *leaf* task
        // (a task with no task descendants contributes 1 to the count).
        struct Frame {
            let id: String
            var childIndex: Int
            var aggregate: TaskRatio
            var hasTaskDescendant: Bool
        }

        for rootID in model.roots {
            var stack: [Frame] = []
            if model.nodes[rootID] != nil {
                stack.append(
                    Frame(
                        id: rootID, childIndex: 0, aggregate: TaskRatio(completed: 0, total: 0),
                        hasTaskDescendant: false))
            }
            while var frame = stack.popLast() {
                let node = model.nodes[frame.id]
                let children = node?.children ?? []
                if frame.childIndex < children.count {
                    let childID = children[frame.childIndex]
                    frame.childIndex += 1
                    stack.append(frame)
                    if model.nodes[childID] != nil {
                        stack.append(
                            Frame(
                                id: childID, childIndex: 0,
                                aggregate: TaskRatio(completed: 0, total: 0), hasTaskDescendant: false))
                    }
                    continue
                }

                // The node's own contribution: a leaf task counts one
                // bucket, done or open.
                if let task = node?.task, !frame.hasTaskDescendant {
                    frame.aggregate = TaskRatio(
                        completed: frame.aggregate.completed + (task.done ? 1 : 0),
                        total: frame.aggregate.total + 1)
                }
                // Only ring nodes (with task descendants) are indexed —
                // a leaf task is a checkbox, not a ring (F-TSK-1/2).
                if frame.hasTaskDescendant, frame.aggregate.total > 0 {
                    ratios[frame.id] = frame.aggregate
                }

                // Fold into the parent.
                if !stack.isEmpty {
                    let isTask = node?.task != nil
                    if isTask || frame.aggregate.total > 0 {
                        stack[stack.count - 1].hasTaskDescendant = true
                    }
                    stack[stack.count - 1].aggregate = TaskRatio(
                        completed: stack[stack.count - 1].aggregate.completed + frame.aggregate.completed,
                        total: stack[stack.count - 1].aggregate.total + frame.aggregate.total)
                }
            }
        }
        return ratios
    }

    /// The leaf tasks in `id`'s subtree (F-TSK-2's complete-all /
    /// reopen-all targets): task nodes with **no** task descendants.
    /// Sorted for deterministic command order.
    public static func leafTaskIDs(of id: String, in model: MapModel) -> [String] {
        // hasTaskDescendant per node, computed by post-order (a node
        // inherits the flag from any child that is a task or already
        // carries one).
        var flags: [String: Bool] = [:]
        var result: [String] = []
        struct Frame {
            let id: String
            var childIndex: Int
        }
        var stack = [Frame(id: id, childIndex: 0)]
        while var frame = stack.popLast() {
            let children = model.nodes[frame.id]?.children ?? []
            if frame.childIndex < children.count {
                let childID = children[frame.childIndex]
                frame.childIndex += 1
                stack.append(frame)
                if model.nodes[childID] != nil {
                    stack.append(Frame(id: childID, childIndex: 0))
                }
                continue
            }
            var hasTaskDescendant = false
            for childID in children {
                if model.nodes[childID]?.task != nil || flags[childID] == true {
                    hasTaskDescendant = true
                }
            }
            flags[frame.id] = hasTaskDescendant
            if model.nodes[frame.id]?.task != nil, !hasTaskDescendant {
                result.append(frame.id)
            }
        }
        return result.sorted()
    }
}
