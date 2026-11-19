import CoreGraphics
import Foundation
import MapCore

/// The F-PRE-1 auto presentation: slides generated from the tree.
/// Slide 1 = the whole-map overview; then one slide per level-1
/// branch in **clockwise order** — the right side top→bottom, then the
/// left side bottom→top, the same visual order the outline view uses —
/// with everything else ghosted at 15%; a sub-slide per level-2 child
/// when the branch has more than `subSlideThreshold` nodes (default
/// 12); a final overview closes the deck. Each slide's camera rect is
/// the fit of its focus set (margin applied at present time, so the
/// aspect matches whatever screen presents).
public enum AutoPresentation {
    /// The one generator setting (SPEC F-PRE-1: "if the branch has > N
    /// nodes", N = 12 by default).
    public struct Options: Sendable, Equatable {
        /// Branches with more nodes than this get level-2 sub-slides.
        public var subSlideThreshold: Int

        public init(subSlideThreshold: Int = 12) {
            self.subSlideThreshold = subSlideThreshold
        }

        public static let `default` = Options()
    }

    public static func slides(
        model: MapModel, scene: CanvasScene, options: Options = .default
    ) -> [ResolvedSlide] {
        guard !scene.nodes.isEmpty else { return [] }
        var result: [ResolvedSlide] = []
        result.append(
            ResolvedSlide(
                kind: .overview, title: "Overview", cameraFit: scene.bounds, notes: ""))
        for rootID in model.roots where scene.nodes[rootID] != nil {
            for branchID in clockwiseLevelOneIDs(model: model, scene: scene, rootID: rootID) {
                let subtree = presentIDs(of: branchID, in: model, scene: scene)
                let focus: Set<String> = Set(subtree).union([rootID])
                result.append(
                    ResolvedSlide(
                        kind: .branch,
                        title: nodeTitle(branchID, in: model),
                        cameraFit: union(of: focus, in: scene),
                        focus: focus,
                        dimOthers: true,
                        notes: model.nodes[branchID]?.note ?? ""))
                guard subtree.count > options.subSlideThreshold else { continue }
                for childID in (model.nodes[branchID]?.children ?? [])
                where scene.nodes[childID] != nil {
                    let childTree = presentIDs(of: childID, in: model, scene: scene)
                    let childFocus: Set<String> = Set(childTree).union([rootID, branchID])
                    result.append(
                        ResolvedSlide(
                            kind: .sub,
                            title: "\(nodeTitle(branchID, in: model)) · \(nodeTitle(childID, in: model))",
                            cameraFit: union(of: childFocus, in: scene),
                            focus: childFocus,
                            dimOthers: true,
                            notes: model.nodes[childID]?.note ?? ""))
                }
            }
        }
        // The closing overview (F-PRE-1: "Final slide = overview again").
        result.append(
            ResolvedSlide(
                kind: .overview, title: "Overview", cameraFit: scene.bounds, notes: ""))
        return result
    }

    /// The level-1 children of `rootID` in clockwise visual order:
    /// the right side top→bottom (ascending Y), then the left side
    /// bottom→top (descending Y). The outline view's first-level order
    /// (F-OUT-2) follows the same rule, so both views walk branches
    /// identically.
    public static func clockwiseLevelOneIDs(
        model: MapModel, scene: CanvasScene, rootID: String
    ) -> [String] {
        guard let rootFrame = scene.nodes[rootID]?.frame else { return [] }
        var right: [(id: String, minY: CGFloat)] = []
        var left: [(id: String, minY: CGFloat)] = []
        for childID in model.nodes[rootID]?.children ?? [] {
            guard let frame = scene.nodes[childID]?.frame else { continue }
            if frame.midX >= rootFrame.midX {
                right.append((childID, frame.minY))
            } else {
                left.append((childID, frame.minY))
            }
        }
        // Clockwise: right side from the top down, left side from the
        // bottom up.
        let rightOrdered = right.sorted { $0.minY < $1.minY }.map(\.id)
        let leftOrdered = left.sorted { $0.minY > $1.minY }.map(\.id)
        return rightOrdered + leftOrdered
    }

    /// The ids of `id`'s subtree that the scene currently shows (a
    /// folded descendant stays hidden and out of the focus set).
    static func presentIDs(of id: String, in model: MapModel, scene: CanvasScene) -> [String] {
        var result: [String] = []
        var stack = [id]
        while let current = stack.popLast() {
            guard scene.nodes[current] != nil else { continue }
            result.append(current)
            for childID in model.nodes[current]?.children ?? [] {
                stack.append(childID)
            }
        }
        return result
    }

    /// The union of `ids`' frames — the camera-fit rect of a focus set.
    static func union(of ids: Set<String>, in scene: CanvasScene) -> CGRect? {
        var rect: CGRect = .null
        for id in ids {
            if let frame = scene.nodes[id]?.frame {
                rect = rect.union(frame)
            }
        }
        return rect.isNull ? nil : rect
    }

    /// A slide title from the node's text: first line, capped.
    static func nodeTitle(_ id: String, in model: MapModel) -> String {
        let text = model.nodes[id]?.title.text ?? ""
        let firstLine =
            text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).first.map(
                String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Slide" : String(trimmed.prefix(80))
    }
}
