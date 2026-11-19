import CoreGraphics
import MapCore

/// The spatial-grid face of the canvas (SPEC §11.4's 512 pt index): the
/// grid syncs with each new scene — incrementally through the scene diff
/// when one follows another (§11.8's keystroke path: only the cells of
/// added/removed/moved nodes change), fully on the first scene — and
/// answers hit-tests through the camera.
extension CanvasView {
    /// Rebuilds the grid from the whole scene (first scene, cleared
    /// canvas).
    func rebuildGrid() {
        grid = SpatialGrid()
        guard let scene else { return }
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
    }

    /// Brings the spatial grid in line with the new scene, incrementally
    /// when it follows another applied scene: the old→new diff names
    /// every added, removed and moved node, so only their cells change.
    /// Returns the diff for `applyScene` to reuse (one diff per
    /// keystroke, not one for the grid and one for the layer tree).
    func syncGrid(previous: CanvasScene?) -> SceneDiff? {
        guard let scene, let previous else {
            rebuildGrid()
            return nil
        }
        let diff = SceneDiffer.diff(old: previous, new: scene)
        for (id, change) in diff.nodes {
            switch change {
            case .removed:
                grid.remove(id: id)
            case .added:
                if let frame = scene.nodes[id]?.frame {
                    grid.insert(id: id, frame: frame)
                }
            case .moved(_, let to), .restyled(_, let to):
                grid.update(id: id, frame: to)
            }
        }
        return diff
    }

    /// The scene node under a view point, if any.
    public func nodeID(at viewPoint: CGPoint) -> String? {
        grid.id(at: camera.modelPoint(for: viewPoint))
    }
}
