import AppKit
import CoreGraphics
import Foundation
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

/// Where a node offers "+" buttons — pure, from the scene alone. A node
/// grows its branches away from its parent, so a child node gets one
/// handle on its outer edge. A root gets both horizontal sides — unless
/// its children already fan out one way (a one-sided layout), or it is a
/// vertical chart, where children only go one way.
public enum AddHandleResolver {
    public static func handles(for id: String, in scene: CanvasScene) -> [AddHandle] {
        guard let node = scene.nodes[id] else { return [] }
        let frame = node.frame
        let sides: [AddHandleSide]
        if let incoming = scene.branches.first(where: { $0.childID == id }),
            let parentFrame = scene.nodes[incoming.parentID]?.frame
        {
            sides = [side(of: frame, relativeTo: parentFrame, axis: incoming.axis)]
        } else {
            sides = rootSides(id: id, frame: frame, scene: scene)
        }
        return sides.map { AddHandle(nodeID: id, side: $0, anchor: edgeMidpoint(of: frame, side: $0)) }
    }

    static func side(of child: CGRect, relativeTo parent: CGRect, axis: LayoutAxis) -> AddHandleSide {
        switch axis {
        case .horizontal: return child.midX >= parent.midX ? .right : .left
        case .vertical: return child.midY >= parent.midY ? .below : .above
        }
    }

    private static func rootSides(id: String, frame: CGRect, scene: CanvasScene) -> [AddHandleSide] {
        let outgoing = scene.branches.filter { $0.parentID == id }
        guard let first = outgoing.first else { return [.left, .right] }
        let childSides = Set(
            outgoing.compactMap { branch -> AddHandleSide? in
                guard let childFrame = scene.nodes[branch.childID]?.frame else { return nil }
                return side(of: childFrame, relativeTo: frame, axis: branch.axis)
            })
        if first.axis == .vertical { return AddHandleSide.allCases.filter(childSides.contains) }
        // A balanced root alternates its first children, so one occupied
        // side with two or more children means a one-sided layout.
        if childSides.count == 1, outgoing.count >= 2 {
            return AddHandleSide.allCases.filter(childSides.contains)
        }
        return [.left, .right]
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
    /// Off while editing, dragging or picking a connection target.
    var isEnabled = false

    /// Shows the buttons for a single selected node, or removes them.
    func update(selection: Set<String>, in tree: CanvasLayerTree, camera: Camera, color: CGColor) {
        var wanted: [AddHandle] = []
        if isEnabled, selection.count == 1, let id = selection.first, let scene = tree.scene,
            tree.nodeLayers[id] != nil
        {
            wanted = AddHandleResolver.handles(for: id, in: scene)
        }
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
    var addHandlesEnabled: Bool {
        get { addHandleOverlay.isEnabled }
        set { addHandleOverlay.isEnabled = newValue }
    }
}
