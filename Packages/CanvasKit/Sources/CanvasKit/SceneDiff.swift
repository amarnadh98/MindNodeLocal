import CoreGraphics
import Foundation
import MapCore
import MapRender

/// Identifies one branch connector across scene rebuilds: the
/// parent→child pair is stable while frames, anchors and widths move.
public struct BranchKey: Hashable, Sendable {
    public let parentID: String
    public let childID: String

    public init(parentID: String, childID: String) {
        self.parentID = parentID
        self.childID = childID
    }
}

/// One branch's two versions, for `CABasicAnimation` on `path` (SPEC
/// §11.4: both paths carry the identical element structure — the tapered
/// builder samples a fixed 16 points — so path interpolation is legal).
public struct BranchMorph: Equatable {
    public let old: SceneBranch
    public let new: SceneBranch
}

/// What changed between two scenes, keyed by node id. A node is
/// `.moved` when only its frame changed (position animation, no
/// re-raster) and `.restyled` when its content or style changed
/// (re-raster, and a position animation only if the frame moved too).
public struct SceneDiff {
    public enum NodeChange: Equatable {
        case added
        case removed
        case moved(fromFrame: CGRect, toFrame: CGRect)
        case restyled(fromFrame: CGRect, toFrame: CGRect)
    }

    public let nodes: [String: NodeChange]
    public let branchesAdded: [SceneBranch]
    public let branchesRemoved: [SceneBranch]
    public let branchMorphs: [BranchMorph]

    public var addedNodeIDs: Set<String> {
        nodes.compactMap { $0.value == .added ? $0.key : nil }.sorted().reduce(into: Set<String>()) {
            $0.insert($1)
        }
    }

    public var removedNodeIDs: Set<String> {
        nodes.compactMap { $0.value == .removed ? $0.key : nil }.sorted().reduce(into: Set<String>()) {
            $0.insert($1)
        }
    }
}

/// Diffs two scenes by node id — added/removed/moved/restyled — and by
/// branch key. Pure: usable headlessly from tests and the animator.
public enum SceneDiffer {
    public static func diff(old: CanvasScene?, new: CanvasScene) -> SceneDiff {
        var nodes: [String: SceneDiff.NodeChange] = [:]
        if let old {
            for (id, oldNode) in old.nodes {
                guard let newNode = new.nodes[id] else {
                    nodes[id] = .removed
                    continue
                }
                if oldNode.frame != newNode.frame {
                    nodes[id] =
                        sameContent(oldNode, newNode)
                        ? .moved(fromFrame: oldNode.frame, toFrame: newNode.frame)
                        : .restyled(fromFrame: oldNode.frame, toFrame: newNode.frame)
                } else if !sameContent(oldNode, newNode) {
                    nodes[id] = .restyled(fromFrame: oldNode.frame, toFrame: newNode.frame)
                }
            }
        }
        for id in new.nodes.keys where old?.nodes[id] == nil {
            nodes[id] = .added
        }

        var oldBranches: [BranchKey: SceneBranch] = [:]
        for branch in old?.branches ?? [] {
            oldBranches[BranchKey(parentID: branch.parentID, childID: branch.childID)] = branch
        }
        var newBranches: [BranchKey: SceneBranch] = [:]
        for branch in new.branches {
            newBranches[BranchKey(parentID: branch.parentID, childID: branch.childID)] = branch
        }

        var added: [SceneBranch] = []
        var morphs: [BranchMorph] = []
        for (key, newBranch) in newBranches {
            if let oldBranch = oldBranches.removeValue(forKey: key) {
                if oldBranch != newBranch {
                    morphs.append(BranchMorph(old: oldBranch, new: newBranch))
                }
            } else {
                added.append(newBranch)
            }
        }
        let removed = oldBranches.values.sorted { ($0.parentID, $0.childID) < ($1.parentID, $1.childID) }

        return SceneDiff(
            nodes: nodes,
            branchesAdded: added,
            branchesRemoved: removed,
            branchMorphs: morphs)
    }

    /// Same title, style, level, level-1 index, decorations and media
    /// revision — i.e. re-rastering the layer would produce identical
    /// pixels.
    static func sameContent(_ oldNode: SceneNode, _ newNode: SceneNode) -> Bool {
        oldNode.title == newNode.title
            && oldNode.level == newNode.level
            && oldNode.level1Index == newNode.level1Index
            && oldNode.decorations == newNode.decorations
            && oldNode.media?.revision == newNode.media?.revision
            && sameStyle(oldNode.style, newNode.style)
    }

    static func sameStyle(_ lhs: ResolvedNodeStyle, _ rhs: ResolvedNodeStyle) -> Bool {
        lhs.shape == rhs.shape
            && sameColor(lhs.fillColor, rhs.fillColor)
            && sameColor(lhs.borderColor, rhs.borderColor)
            && lhs.borderWidth == rhs.borderWidth
            && lhs.cornerRadius == rhs.cornerRadius
            && lhs.paddingWidth == rhs.paddingWidth
            && lhs.paddingHeight == rhs.paddingHeight
            && sameColor(lhs.textColor, rhs.textColor)
            && lhs.font == rhs.font
            && lhs.underlineWidth == rhs.underlineWidth
            && lhs.shadows.count == rhs.shadows.count
            && zip(lhs.shadows, rhs.shadows).allSatisfy { sameShadow($0, $1) }
            && lhs.maxWidth == rhs.maxWidth
    }

    static func sameShadow(_ lhs: ShadowLayer, _ rhs: ShadowLayer) -> Bool {
        lhs.offsetY == rhs.offsetY && lhs.blur == rhs.blur && sameColor(lhs.color, rhs.color)
    }

    /// Color equality without per-compare allocations: `CFEqual` covers
    /// theme colors (all sRGB) and short-circuits instance identity.
    static func sameColor(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let left?, let right?):
            if left === right {
                return true
            }
            guard left.numberOfComponents == right.numberOfComponents else { return false }
            return CFEqual(left, right)
        default:
            return false
        }
    }
}

extension SceneBranch: Equatable {
    /// Geometry equality: anchors, direction, axis, widths and taper.
    /// Color is deliberately excluded — a palette change repaints the
    /// fill without being a morph (§11.4 path animation stays for
    /// geometry only, since `path` doesn't carry color).
    public static func == (lhs: SceneBranch, rhs: SceneBranch) -> Bool {
        lhs.parentID == rhs.parentID
            && lhs.childID == rhs.childID
            && lhs.from == rhs.from
            && lhs.to == rhs.to
            && lhs.direction == rhs.direction
            && lhs.axis == rhs.axis
            && lhs.startWidth == rhs.startWidth
            && lhs.endWidth == rhs.endWidth
            && lhs.tapered == rhs.tapered
    }

    /// Full equality including the fill color.
    static func isSameColor(_ lhs: SceneBranch, _ rhs: SceneBranch) -> Bool {
        SceneDiffer.sameColor(lhs.color, rhs.color)
    }
}
