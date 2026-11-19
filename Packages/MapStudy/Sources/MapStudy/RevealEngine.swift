import Foundation
import MapCore

/// One node's progressive-disclosure state (SPEC §10): the canvas
/// renderer reads exactly this overlay, so presentation builds and
/// study recall share one vocabulary.
public enum RevealState: String, Sendable, Codable, CaseIterable {
    /// Not shown at this point of the sequence.
    case hidden
    /// Shown as a dimmed placeholder (the branch is present but its
    /// content is withheld — study recall; presentations never emit it).
    case placeholder
    /// Fully drawn.
    case visible
}

/// One step of a reveal sequence: applying it makes every id in `ids`
/// (and each id's subtree) visible. Steps are ordered; a cursor counts
/// how many have applied.
public struct RevealStep: Sendable, Equatable, Hashable, Codable {
    public let ids: [String]

    public init(ids: [String]) {
        self.ids = ids
    }
}

/// The pure progressive-disclosure state machine behind presentation
/// builds and study recall (SPEC §10 "Reveal Engine", F-PRE-3,
/// F-STD-5). Headless and deterministic: an ordered list of steps over
/// a hierarchy, evaluated into a `RevealState` per node for any cursor.
///
/// The engine is a value: callers own the cursor (`startCursor` before
/// the first step, one index per applied step) and move it with
/// `next(after:)` / `back(from:)` / `jump(_:)`. Revealing an id reveals
/// its whole subtree, so a build step that names a branch shows the
/// branch's children with it.
public struct RevealEngine: Sendable, Equatable {
    /// The cursor value before any step has applied.
    public static let startCursor = -1

    /// The steps, in presentation order.
    public let steps: [RevealStep]
    /// The id hierarchy (`id` → children) used for subtree inclusion.
    public let children: [String: [String]]
    /// Ids that render as placeholders until their step reveals them.
    public let placeholders: Set<String>
    /// Ids fully visible regardless of progress (a slide's focus set).
    public let baseVisible: Set<String>

    public init(
        steps: [RevealStep] = [],
        children: [String: [String]] = [:],
        placeholders: Set<String> = [],
        baseVisible: Set<String> = []
    ) {
        self.steps = steps
        self.children = children
        self.placeholders = placeholders
        self.baseVisible = baseVisible
    }

    /// Builds the engine over a document: the hierarchy comes from the
    /// model, so revealed ids carry their subtrees.
    public init(
        model: MapModel,
        steps: [RevealStep],
        placeholders: Set<String> = [],
        baseVisible: Set<String>
    ) {
        var children: [String: [String]] = [:]
        children.reserveCapacity(model.nodes.count)
        for (id, node) in model.nodes {
            children[id] = node.children
        }
        self.init(steps: steps, children: children, placeholders: placeholders, baseVisible: baseVisible)
    }

    // MARK: navigation (pure — the caller owns the cursor)

    /// The cursor after applying step `cursor + 1`, or nil when every
    /// step has applied.
    public func next(after cursor: Int) -> Int? {
        let candidate = cursor + 1
        return candidate <= lastCursor ? candidate : nil
    }

    /// The cursor after un-applying step `cursor`, or nil at the start.
    public func back(from cursor: Int) -> Int? {
        cursor > Self.startCursor ? cursor - 1 : nil
    }

    /// A cursor clamped into the valid range (jump targets and
    /// hand-written cursors stay safe).
    public func clamped(_ cursor: Int) -> Int {
        min(max(cursor, Self.startCursor), lastCursor)
    }

    public var lastCursor: Int { steps.count - 1 }
    public var startCursor: Int { Self.startCursor }

    // MARK: evaluation

    /// The ids visible once steps `0...cursor` applied: every step's
    /// ids plus their subtrees, plus `baseVisible`.
    public func revealedIDs(at cursor: Int) -> Set<String> {
        let applied = clamped(cursor)
        var revealed = baseVisible
        guard applied >= 0 else { return revealed }
        var visited = Set<String>()
        for step in steps[0...applied] {
            for id in step.ids {
                collect(id, into: &revealed, visited: &visited)
            }
        }
        return revealed
    }

    /// The per-node state at `cursor` for every id in `universe`. Ids
    /// outside the engine's knowledge are `.hidden` unless they are
    /// base-visible; callers that want "unmanaged = visible" pass a
    /// universe limited to the ids they manage (see the canvas overlay).
    public func states(at cursor: Int, universe: Set<String>) -> [String: RevealState] {
        let revealed = revealedIDs(at: cursor)
        var result: [String: RevealState] = [:]
        result.reserveCapacity(universe.count)
        for id in universe {
            if revealed.contains(id) {
                result[id] = .visible
            } else if placeholders.contains(id) {
                result[id] = .placeholder
            } else {
                result[id] = .hidden
            }
        }
        return result
    }

    /// The state of one id at `cursor`.
    public func state(of id: String, at cursor: Int) -> RevealState {
        let revealed = revealedIDs(at: cursor)
        if revealed.contains(id) {
            return .visible
        }
        return placeholders.contains(id) ? .placeholder : .hidden
    }

    /// Includes `id` and everything below it. An id already visible
    /// still reveals its subtree (a base-visible focus node's children
    /// can be build steps of their own), and cycles in a corrupt
    /// hierarchy cannot loop: each id recurses once.
    private func collect(_ id: String, into revealed: inout Set<String>, visited: inout Set<String>) {
        revealed.insert(id)
        guard visited.insert(id).inserted else { return }
        for child in children[id] ?? [] {
            collect(child, into: &revealed, visited: &visited)
        }
    }
}
