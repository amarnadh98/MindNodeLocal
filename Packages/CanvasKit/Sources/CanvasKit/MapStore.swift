import Foundation
import MapCore

/// A @MainActor box holding the latest forward command of a coalesced
/// edit session. The registered undo closure captures the box (not the
/// command value), so undo still restores the session's first pre-state
/// while redo replays the session's *newest* edit.
@MainActor
private final class EditSession {
    var forward: MapCommand

    init(forward: MapCommand) {
        self.forward = forward
    }
}

/// The single editing gateway (SPEC §11.3): every mutation of the
/// current `MapModel` goes through `perform`, which computes the exact
/// inverse against the pre-state, applies all-or-nothing, registers the
/// inverse with the undo manager, stamps authorship on the touched
/// nodes and notifies the host.
///
/// Undo and redo replay through the same all-or-nothing apply path, so
/// undo∘redo is exact. Consecutive `editText`s on the same node coalesce
/// into one undo step (`MapCommand.continuesEdit`): the session's first
/// inverse stays registered and redo points at the newest edit.
///
/// `modified`/`modifiedBy` are journal fields — commands never stamp
/// them, this layer does — and undo does not rewind them (like a file's
/// mtime), so equality checks compare models modulo those fields.
@MainActor
public final class MapStore {
    /// What caused a model change, handed to `onChange`.
    public enum ChangeOrigin: Equatable, Sendable {
        /// A forward `perform` (the host marks the document dirty).
        case perform(MapCommand)
        /// The undo manager replayed a registered inverse.
        case undo(MapCommand)
        /// The undo manager replayed a forward command.
        case redo(MapCommand)
        /// A `performWithoutUndo` write (ADR-0015): the model changed and
        /// the host must mark the document dirty itself — review grading
        /// is history, not an edit, so no undo step exists for it.
        case nonUndoable(MapCommand)
    }

    /// The current model; owned here, never mutated by views.
    public private(set) var model: MapModel

    /// The undo manager the store registers with. The host must also
    /// install it as its document's undo manager so Edit ▸ Undo and the
    /// document's change-count integration see the same stacks.
    public let undoManager: UndoManager

    /// Called after every model change (perform, undo, redo), so the
    /// host can rebuild the scene, update the change count and fix the
    /// selection. The command is the one that just ran.
    public var onChange: ((ChangeOrigin) -> Void)?

    /// The most recent forward command; the coalescing anchor.
    private var lastForward: MapCommand?
    /// The session of the most recent undo registration, when it is an
    /// open coalesced `editText` session.
    private var lastSession: EditSession?
    /// Who authored the most recent change (F-AI-5): `.user`, or `.ai`
    /// for AI mutations. The host copies this into the document
    /// metadata on save.
    public private(set) var lastAuthor: AuthorKind = .user

    public init(model: MapModel, undoManager: UndoManager = UndoManager()) {
        self.model = model
        self.undoManager = undoManager
    }

    /// Replaces the whole model (initial load, revert). Not undoable:
    /// clears the undo stacks and any open edit session.
    public func replaceModel(_ newModel: MapModel) {
        model = newModel
        endSession()
        undoManager.removeAllActions()
    }

    /// Applies `command` as one undoable step (author = user). The
    /// inverse is computed against the pre-state **before** applying; a
    /// throwing command leaves the model and the undo stacks untouched.
    public func perform(_ command: MapCommand) throws {
        try perform(command, author: .user)
    }

    /// Applies `command` as one undoable step stamped with `author`
    /// (F-AI-5): an AI mutation is ONE undo group — a grouped command
    /// performed with `.ai` — and every node it touched records
    /// `modifiedBy = .ai`, surfaced in the document metadata as
    /// `lastModifiedBy: "ai"`.
    public func perform(_ command: MapCommand, author: AuthorKind) throws {
        let inverse = try command.inverse(in: model)
        var working = model
        try command.apply(to: &working)
        stampTouchedNodes(previous: model, in: &working, author: author)
        model = working
        lastAuthor = author

        if let lastForward, MapCommand.continuesEdit(previousForward: lastForward, nextForward: command) {
            // Typing continues the session: the registered inverse
            // already restores the session's first pre-state; point redo
            // at the newest edit instead of registering another step.
            lastSession?.forward = command
        } else {
            let session = EditSession(forward: command)
            lastSession = session
            // One explicit group per step: the undo manager otherwise
            // groups by run-loop event, which would merge independent
            // performs (and never group in headless tests).
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { store in
                store.undoStep(inverse, session: session)
            }
            undoManager.setActionName(command.displayName)
            undoManager.endUndoGrouping()
        }
        lastForward = command
        onChange?(.perform(command))
    }

    /// Applies `command` as a deliberate NON-undoable write (ADR-0015).
    /// The model changes, `onChange` fires with `.nonUndoable` (the host
    /// marks the document dirty and the next autosave persists it), but
    /// nothing registers with the undo manager: grading a flashcard is
    /// recorded history — the review log entry it produced can never be
    /// undone — so a grading must not leave an undo step that would
    /// desync card state from the log. The command still goes through
    /// the same all-or-nothing apply path; a throw leaves the model
    /// untouched.
    public func performWithoutUndo(_ command: MapCommand) throws {
        var working = model
        try command.apply(to: &working)
        stampTouchedNodes(previous: model, in: &working)
        model = working
        endSession()
        onChange?(.nonUndoable(command))
    }

    /// Runs when the undo manager undoes: applies `inverse` and
    /// registers the session's latest forward command as the redo step.
    private func undoStep(_ inverse: MapCommand, session: EditSession) {
        endSession()
        guard applyRelaxed(inverse) else { return }
        undoManager.registerUndo(withTarget: self) { store in
            store.redoStep(session)
        }
        undoManager.setActionName(session.forward.displayName)
        onChange?(.undo(inverse))
    }

    /// Runs when the undo manager redoes: applies the session's latest
    /// forward command and registers its inverse as the next undo step.
    private func redoStep(_ session: EditSession) {
        let forward = session.forward
        endSession()
        guard let inverse = try? forward.inverse(in: model), applyRelaxed(forward) else { return }
        undoManager.registerUndo(withTarget: self) { store in
            store.undoStep(inverse, session: session)
        }
        undoManager.setActionName(forward.displayName)
        onChange?(.redo(forward))
    }

    /// Ends the open typing session, so the next `editText` opens a new
    /// undo step. The host calls this after a save: a coalesced edit
    /// registers no undo group, and NSDocument only marks a saved
    /// document dirty again when a new group closes.
    public func closeEditSession() {
        endSession()
    }

    /// Closes any open edit session: undo/redo navigation must never
    /// coalesce the next perform with the pre-navigation session.
    private func endSession() {
        lastForward = nil
        lastSession = nil
    }

    /// Applies a replayed (undo/redo) command. Inverses are exact, so a
    /// failure here means corrupted state; rather than throw through
    /// the undo manager, the change is dropped.
    private func applyRelaxed(_ command: MapCommand) -> Bool {
        var working = model
        do {
            try command.apply(to: &working)
        } catch {
            return false
        }
        stampTouchedNodes(previous: model, in: &working, author: .user)
        model = working
        return true
    }

    /// Records authorship (`MapCommand` docs: commands never stamp, the
    /// applying layer does): every node that differs from the
    /// pre-command state — created, re-parented or edited — gets
    /// `modified` = now, `modifiedBy` = `author`. Journal-only fields;
    /// undo does not rewind them (see class docs).
    private func stampTouchedNodes(
        previous: MapModel, in working: inout MapModel, author: AuthorKind
    ) {
        let now = Date()
        for (id, node) in working.nodes where previous.nodes[id] != node {
            working.nodes[id]?.modified = now
            working.nodes[id]?.modifiedBy = author
        }
    }

    // MARK: selection repair

    /// The selection to keep after the subtrees rooted at `deletedIDs`
    /// are removed: survivors stay; each deleted selected node falls
    /// back to its nearest surviving sibling, else its nearest
    /// surviving ancestor — a deleted root falls back to the nearest
    /// surviving root (SPEC: after a delete, select the parent or the
    /// nearest sibling). Pure over the pre-delete model.
    public static func selectionAfterDelete(
        model: MapModel, deletedIDs: [String], selection: Set<String>
    ) -> Set<String> {
        let deleted = Set(deletedIDs)

        func isDeleted(_ id: String) -> Bool {
            var current = id
            while true {
                if deleted.contains(current) { return true }
                guard let parent = model.nodes[current]?.parent, parent != current else { return false }
                current = parent
            }
        }

        func survives(_ id: String) -> Bool {
            model.nodes[id] != nil && !isDeleted(id)
        }

        /// The nearest surviving entry of `list` around `slot`,
        /// preferring the previous one on ties.
        func nearestSurvivor(in list: [String], around slot: Int) -> String? {
            var distance = 1
            while slot - distance >= 0 || slot + distance < list.count {
                let previous = slot - distance
                let next = slot + distance
                if previous >= 0, survives(list[previous]) { return list[previous] }
                if next < list.count, survives(list[next]) { return list[next] }
                distance += 1
            }
            return nil
        }

        func replacement(for id: String) -> String? {
            // The topmost deleted ancestor owns the slot logic.
            var top = id
            while let parent = model.nodes[top]?.parent, deleted.contains(parent) {
                top = parent
            }
            var current = top
            while let parentID = model.nodes[current]?.parent {
                let siblings = model.nodes[parentID]?.children ?? []
                if let sibling = siblingReplacement(of: current, in: siblings) {
                    return sibling
                }
                if survives(parentID) {
                    return parentID
                }
                current = parentID
            }
            // `current` is a deleted root: fall back to a surviving one.
            if let slot = model.roots.firstIndex(of: current) {
                return nearestSurvivor(in: model.roots, around: slot)
            }
            return nil
        }

        /// The nearest surviving sibling of `id`, if any.
        func siblingReplacement(of id: String, in siblings: [String]) -> String? {
            guard let slot = siblings.firstIndex(of: id) else { return nil }
            return nearestSurvivor(in: siblings, around: slot)
        }

        var result: Set<String> = []
        for id in selection {
            guard model.nodes[id] != nil else { continue }
            if survives(id) {
                result.insert(id)
            } else if let replacement = replacement(for: id) {
                result.insert(replacement)
            }
        }
        return result
    }
}
