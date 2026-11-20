import AppKit
import CoreGraphics
import Foundation
import MapLayout
import MapRender
import QuartzCore

/// Which edge of a node an add-handle sits on.
public enum AddHandleSide: String, Sendable, Hashable, CaseIterable {
    case left
    case right
    case above
    case below
}

/// The Node Well "+" (SPEC §6.2): a small round button on the outer edge
/// of the selected node. Clicking it adds a child on that side. `anchor`
/// is the node-edge midpoint in model space; the button itself is drawn a
/// fixed distance outside it in screen space, so it keeps its size at any
/// zoom.
public struct AddHandle: Equatable, Sendable {
    public let nodeID: String
    public let side: AddHandleSide
    public let anchor: CGPoint

    public static let radius: CGFloat = 10
    /// Screen distance from the node edge to the button's center.
    public static let offset: CGFloat = 18

    /// The button's center for `camera`, in screen space.
    public func center(camera: Camera) -> CGPoint {
        let edge = camera.screenPoint(for: anchor)
        switch side {
        case .left: return CGPoint(x: edge.x - Self.offset, y: edge.y)
        case .right: return CGPoint(x: edge.x + Self.offset, y: edge.y)
        case .above: return CGPoint(x: edge.x, y: edge.y - Self.offset)
        case .below: return CGPoint(x: edge.x, y: edge.y + Self.offset)
        }
    }

    var key: String { "\(nodeID)|\(side.rawValue)" }
}

/// Where a node offers "+" buttons — pure, from the scene and the
/// model. A child node grows its branches away from its parent, so a
/// child gets one handle on its outer edge. A root's sides come from
/// its *declared* structure (nil or `mindmap.balanced` = balanced): a
/// balanced root always offers both sides, no matter where its current
/// children happen to sit — a left child stays legal even when every
/// existing child is pinned right. Only an explicitly one-sided
/// structure (`mindmap.right`/`mindmap.left`/`logic.right`) or a
/// vertical org chart restricts the sides.
public enum AddHandleResolver {
    public static func handles(
        for id: String, in scene: CanvasScene, rootStructure: LayoutStructure? = nil
    ) -> [AddHandle] {
        guard let node = scene.nodes[id] else { return [] }
        let frame = node.frame
        let sides: [AddHandleSide]
        if let incoming = scene.branches.first(where: { $0.childID == id }),
            let parentFrame = scene.nodes[incoming.parentID]?.frame
        {
            sides = [side(of: frame, relativeTo: parentFrame, axis: incoming.axis)]
        } else {
            sides = rootSides(structure: rootStructure ?? .mindmapBalanced)
        }
        return sides.map { AddHandle(nodeID: id, side: $0, anchor: edgeMidpoint(of: frame, side: $0)) }
    }

    static func side(of child: CGRect, relativeTo parent: CGRect, axis: LayoutAxis) -> AddHandleSide {
        switch axis {
        case .horizontal: return child.midX >= parent.midX ? .right : .left
        case .vertical: return child.midY >= parent.midY ? .below : .above
        }
    }

    /// A root's sides from its declared structure: both horizontal
    /// sides unless the structure is explicitly one-sided or vertical.
    public static func rootSides(structure: LayoutStructure) -> [AddHandleSide] {
        switch structure {
        case .mindmapBalanced:
            return [.left, .right]
        case .mindmapRight, .logicChartRight:
            return [.right]
        case .mindmapLeft:
            return [.left]
        case .orgDown:
            return [.below]
        case .orgUp:
            return [.above]
        }
    }

    private static func edgeMidpoint(of frame: CGRect, side: AddHandleSide) -> CGPoint {
        switch side {
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .above: return CGPoint(x: frame.midX, y: frame.minY)
        case .below: return CGPoint(x: frame.midX, y: frame.maxY)
        }
    }
}

/// The "+" layers and the handles they stand for, kept off the layer
/// tree itself. Screen-space layers inside the tree's `content`, so they
/// keep their size at any zoom.
@MainActor
final class AddHandleOverlay {
    var layers: [String: CAShapeLayer] = [:]
    var handles: [AddHandle] = []

    /// Shows exactly these buttons — the canvas view resolves which
    /// nodes offer them (the single selected node plus the hovered
    /// one, SPEC §6.2) and gates on editing/dragging — or removes them.
    func set(_ wanted: [AddHandle], in tree: CanvasLayerTree, camera: Camera, color: CGColor) {
        handles = wanted
        let keys = Set(wanted.map(\.key))
        for (key, layer) in layers where !keys.contains(key) {
            layer.removeFromSuperlayer()
            layers.removeValue(forKey: key)
        }
        for handle in wanted {
            let layer: CAShapeLayer
            if let existing = layers[handle.key] {
                layer = existing
            } else {
                layer = Self.makeLayer(color: color)
                tree.content.addSublayer(layer)
                layers[handle.key] = layer
            }
            layer.position = handle.center(camera: camera)
        }
    }

    func reposition(camera: Camera) {
        for handle in handles {
            layers[handle.key]?.position = handle.center(camera: camera)
        }
    }

    func clear() {
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers.removeAll()
        handles.removeAll()
    }

    private static func makeLayer(color: CGColor) -> CAShapeLayer {
        let radius = AddHandle.radius
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
        layer.fillColor = color
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = 1.5
        layer.zPosition = 3
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: -1)
        let plus = CAShapeLayer()
        let arm: CGFloat = 4.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius - arm, y: radius))
        path.addLine(to: CGPoint(x: radius + arm, y: radius))
        path.move(to: CGPoint(x: radius, y: radius - arm))
        path.addLine(to: CGPoint(x: radius, y: radius + arm))
        plus.path = path
        plus.strokeColor = NSColor.white.cgColor
        plus.lineWidth = 2
        plus.lineCap = .round
        plus.fillColor = nil
        layer.addSublayer(plus)
        return layer
    }
}

extension CanvasLayerTree {
    var addHandles: [AddHandle] { addHandleOverlay.handles }
    var addHandleLayers: [String: CAShapeLayer] { addHandleOverlay.layers }

    /// Shows exactly these Node Well buttons; the canvas view resolves
    /// the node set (selection + hover) and the edit/drag gates, so
    /// this stays a plain presentation call.
    func setAddHandles(_ handles: [AddHandle], camera: Camera, color: CGColor) {
        addHandleOverlay.set(handles, in: self, camera: camera, color: color)
    }
}
