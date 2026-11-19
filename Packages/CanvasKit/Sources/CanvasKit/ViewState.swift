import CoreGraphics
import Foundation
import MapCore

/// Per-document canvas view state — zoom scale, camera origin,
/// selection ids and the active view — restored on reopen (F-CAN-8).
/// It lives OUTSIDE the document package (ADR-0005) so a pan or zoom
/// never dirties the map file; folded flags are map content and stay
/// on `node.folded` in `map.json` (F-LAY-14), not here.
///
/// `MapCore` declares its own schema-level `ViewState` for the
/// `map.json` `view` field (SPEC §8.2); this is the live per-user copy
/// the canvas reads and writes.
public struct ViewState: Codable, Sendable, Equatable {
    public var scale: CGFloat
    public var origin: CGPoint
    public var selection: [String]
    public var activeView: ViewMode

    public init(
        scale: CGFloat = 1,
        origin: CGPoint = .zero,
        selection: [String] = [],
        activeView: ViewMode = .map
    ) {
        self.scale = scale
        self.origin = origin
        self.selection = selection
        self.activeView = activeView
    }

    public init(
        camera: Camera,
        selection: [String] = [],
        activeView: ViewMode = .map
    ) {
        self.init(
            scale: camera.scale, origin: camera.origin, selection: selection,
            activeView: activeView)
    }

    /// The canvas camera this state represents.
    public var camera: Camera {
        Camera(origin: origin, scale: scale)
    }

    /// F-CAN-8 restore hygiene: selection ids that no longer exist in
    /// the scene (deleted, or folded away since the last session) are
    /// dropped; order is preserved.
    public func sanitized(for scene: CanvasScene) -> ViewState {
        var copy = self
        copy.selection = selection.filter { scene.nodes[$0] != nil }
        return copy
    }
}
