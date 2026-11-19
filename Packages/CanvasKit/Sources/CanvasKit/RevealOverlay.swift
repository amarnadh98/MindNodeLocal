import CoreGraphics
import Foundation
import MapStudy

/// The reveal overlay the canvas layer tree renders on top of the
/// scene (SPEC §10: "the canvas renderer reads a `RevealState`
/// overlay"). Pure data; `CanvasLayerTree.setRevealOverlay` applies it
/// by writing layer opacity alone — never a re-raster.
///
/// Two channels, deliberately separate:
/// - `states`: per-id reveal states from the `RevealEngine`, covering
///   only the ids a slide *manages* (its focus + build ids). Ids with
///   no entry are untouched — an overview slide manages nothing.
/// - `dimmed`: the ghost set of focus slides (F-PRE-1: everything
///   outside the branch, at 15% opacity).
public struct RevealOverlay: Equatable, Sendable {
    /// The ghost opacity of focus slides' background (SPEC F-PRE-1:
    /// "others ghosted at 15%").
    public static let ghostOpacity: CGFloat = 0.15
    /// Placeholder bodies render faintly until revealed (study recall,
    /// F-STD-5; refined with a true blurred outline in M7).
    public static let placeholderOpacity: CGFloat = 0.35

    public var states: [String: RevealState]
    public var dimmed: Set<String>

    public init(states: [String: RevealState] = [:], dimmed: Set<String> = []) {
        self.states = states
        self.dimmed = dimmed
    }

    public static func == (lhs: RevealOverlay, rhs: RevealOverlay) -> Bool {
        lhs.states == rhs.states && lhs.dimmed == rhs.dimmed
    }

    /// The opacity a node layer renders at under this overlay.
    /// Unmanaged ids are fully visible unless dimmed.
    public func nodeOpacity(_ id: String) -> CGFloat {
        if let state = states[id] {
            switch state {
            case .visible: return dimmed.contains(id) ? dimmedOpacity(id) : 1
            case .placeholder: return Self.placeholderOpacity
            case .hidden: return 0
            }
        }
        return dimmed.contains(id) ? Self.ghostOpacity : 1
    }

    /// The opacity a branch layer (towards `childID`) renders at: the
    /// weaker of the two ends, so a hidden child never dangles off a
    /// visible parent and a ghosted branch never outshines its nodes.
    public func branchOpacity(parentID: String, childID: String) -> CGFloat {
        min(nodeOpacity(parentID), nodeOpacity(childID))
    }

    private func dimmedOpacity(_ id: String) -> CGFloat {
        dimmed.contains(id) ? Self.ghostOpacity : 1
    }
}
