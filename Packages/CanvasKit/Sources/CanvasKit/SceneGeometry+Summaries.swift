import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender

extension SceneGeometry {
    /// The post-layout placement of summary nodes (F-REL-3, ADR-0026):
    /// a summary node keeps its auto slot in the tree (a real child of
    /// the range's parent, so outline order and undo stay ordinary),
    /// then a corrective translation puts it just beyond its brace,
    /// aligned with the range's center — and its descendants move with
    /// it, like any manual offset (F-LAY-11).
    static func summaryAdjustments(
        model: MapModel, placed: [String: CGRect], axis: LayoutAxis
    ) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for summary in model.summaries ?? [] {
            guard let parentFrame = placed[summary.parent], let autoFrame = placed[summary.node]
            else { continue }
            var rangeUnion = CGRect.null
            var complete = true
            for rangeID in summary.range {
                guard let frame = placed[rangeID] else {
                    complete = false
                    break
                }
                rangeUnion = rangeUnion.union(frame)
            }
            guard complete, !rangeUnion.isNull else { continue }
            let mirrored = RelationGeometry.mirrored(
                range: rangeUnion, parent: parentFrame, axis: axis)
            let target = RelationPath.summaryNodeFrame(
                range: rangeUnion, axis: axis, mirrored: mirrored, size: autoFrame.size)
            let delta = CGPoint(x: target.minX - autoFrame.minX, y: target.minY - autoFrame.minY)
            if delta.x != 0 || delta.y != 0 {
                result[summary.node] = delta
            }
            var stack = model.nodes[summary.node]?.children ?? []
            while let id = stack.popLast() {
                if placed[id] != nil {
                    result[id] = delta
                }
                stack.append(contentsOf: model.nodes[id]?.children ?? [])
            }
        }
        return result
    }
}
