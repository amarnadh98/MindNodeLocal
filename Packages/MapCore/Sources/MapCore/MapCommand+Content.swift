import Foundation

extension MapCommand {
    /// F-TAG-1: appends a document tag definition. The inverse (the
    /// pre-state's whole list) is exact.
    public static func addTag(_ tag: Tag, in model: MapModel) -> MapCommand {
        .setTags((model.tags ?? []) + [tag])
    }

    /// F-TAG-1 rename/recolor: replaces the definition with the same
    /// id; a missing id is a no-op append (ids are host-generated).
    public static func updateTag(_ tag: Tag, in model: MapModel) -> MapCommand {
        var tags = model.tags ?? []
        guard let slot = tags.firstIndex(where: { $0.id == tag.id }) else {
            return .setTags(tags + [tag])
        }
        tags[slot] = tag
        return .setTags(tags)
    }

    /// F-TAG-1 delete: removes the definition **and** unassigns it
    /// from every node — one grouped step, and its inverse restores
    /// both the list and every node's assignment (nil when the tag is
    /// referenced nowhere).
    public static func deleteTag(id: String, in model: MapModel) throws -> MapCommand {
        guard (model.tags ?? []).contains(where: { $0.id == id }) else {
            throw ArborError.commandFailure("missing tag \(id)")
        }
        let remaining = (model.tags ?? []).filter { $0.id != id }
        var commands: [MapCommand] = [.setTags(remaining.isEmpty ? nil : remaining)]
        let assigned = model.nodes.values.filter { $0.tags?.contains(id) == true }.map(\.id).sorted()
        if !assigned.isEmpty {
            commands.append(.toggleTag(ids: assigned, tagID: id, assigned: false))
        }
        return .group(name: "Delete Tag", commands: commands)
    }

    /// F-TSK-2 ring click: completes (or, ⌥-clicked, reopens) every
    /// leaf task in `id`'s subtree — one grouped undo step. Nil when
    /// the subtree holds no leaf tasks (no phantom undo step).
    public static func setLeafTasksDone(parent id: String, done: Bool, in model: MapModel) -> MapCommand? {
        let leaves = TaskProgress.leafTaskIDs(of: id, in: model)
        guard !leaves.isEmpty else { return nil }
        return .setTaskDone(ids: leaves, done: done)
    }

    /// F-EDT-10 smart typing on title commit: ONE grouped step that
    /// renames `id` to the stripped title, creates any missing tag
    /// definitions and assigns them. Empty `names` returns a plain
    /// `editText`.
    public static func smartTagCommit(
        id: String, title: NodeTitle, names: [String], in model: MapModel
    ) -> MapCommand {
        var commands: [MapCommand] = [.editText(id: id, title: title)]
        var known = model.tags ?? []
        for name in names {
            if let existing = known.first(where: { $0.name == name }) {
                commands.append(.toggleTag(ids: [id], tagID: existing.id, assigned: true))
                continue
            }
            let tag = Tag(id: UUID().uuidString, name: name, color: Self.defaultTagColor(name))
            known.append(tag)
            commands.append(.setTags(known))
            commands.append(.toggleTag(ids: [id], tagID: tag.id, assigned: true))
        }
        guard commands.count > 1 else { return commands[0] }
        return .group(name: "Tag", commands: commands)
    }

    /// A stable color for a smart-typed tag: the palette position of
    /// the name's UTF-8 bytes over the built-in tag palette, so the
    /// same name always lands on the same pill color.
    public static func defaultTagColor(_ name: String) -> String {
        let palette = [
            "#E5484D", "#F5A524", "#46A758", "#00B4D8",
            "#7C5CFC", "#E66FB3", "#0F9960", "#B8860B",
        ]
        var hash: UInt64 = 5_381
        for byte in name.utf8 {
            hash = (hash &<< 5) &+ hash &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// F-EDT-10 smart typing on title commit: ONE grouped step for
    /// the whole parse — the renamed (stripped) title, the task
    /// prefix, the math flag, the `--` note split and any missing
    /// tag definitions with their assignments. The one-command
    /// no-op case returns a plain `editText`.
    public static func smartCommit(
        id: String, parse: SmartTyping.CommitParse, in model: MapModel
    ) -> MapCommand {
        var commands: [MapCommand] = [.editText(id: id, title: parse.title)]
        if let task = parse.task {
            // The prefix said "task" — the completion state rides a
            // wholesale task value so `[x] ` commits done in the same
            // step (and `[ ] ` on a done task reopens it).
            let current = model.nodes[id]?.task
            commands.append(
                .setTaskValue(
                    id: id,
                    task: NodeTask(
                        done: parse.taskDone ?? current?.done ?? false,
                        due: current?.due, priority: current?.priority,
                        repeat: current?.repeat, reminderID: current?.reminderID)))
        }
        if parse.math {
            commands.append(.setMath(id: id, math: true))
        }
        if let note = parse.note {
            let existing = model.nodes[id]?.note
            let merged = existing.map { $0.isEmpty ? note : $0 + "\n" + note } ?? note
            commands.append(.setNote(id: id, note: merged))
        }
        var known = model.tags ?? []
        for name in parse.tags {
            if let existing = known.first(where: { $0.name == name }) {
                commands.append(.toggleTag(ids: [id], tagID: existing.id, assigned: true))
                continue
            }
            let tag = Tag(id: UUID().uuidString, name: name, color: Self.defaultTagColor(name))
            known.append(tag)
            commands.append(.setTags(known))
            commands.append(.toggleTag(ids: [id], tagID: tag.id, assigned: true))
        }
        guard commands.count > 1 else { return commands[0] }
        return .group(name: "Edit Node", commands: commands)
    }
}
