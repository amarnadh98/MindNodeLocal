import CoreGraphics
import Foundation
import MapCore
import MapRender
import QuartzCore

/// A ghost-suggestion overlay (F-AI-2): AI-proposed children rendered
/// on the canvas BEFORE they become model nodes. Pure view state —
/// nothing here is in the `MapModel`, the spatial grid, the undo stack
/// or the accessibility tree, so presenting ghosts can never dirty the
/// document or cost the keystroke path a millisecond.
///
/// The presentation is built by the host from a probe scene (the model
/// plus the suggested children laid out hypothetically): each `Item`
/// wraps the probe's `SceneNode`, `branches` its connectors. Dashed
/// borders, dashed connectors and 50% opacity mark the items as
/// suggestions; ⇥ accepts, Esc dismisses, a click accepts one.
@MainActor
public struct GhostPresentation {
    public struct Item {
        /// Ephemeral id — shared with the acceptance command's node ids,
        /// never a live model id while ghosted.
        public let id: String
        public let node: SceneNode

        public init(id: String, node: SceneNode) {
            self.id = id
            self.node = node
        }
    }

    /// The node the suggestions would attach to.
    public let parentID: String
    public let items: [Item]
    /// The probe scene's parent→ghost connectors (model space).
    public let branches: [SceneBranch]

    public init(parentID: String, items: [Item], branches: [SceneBranch]) {
        self.parentID = parentID
        self.items = items
        self.branches = branches
    }

    public static let ghostOpacity: Float = 0.5

    /// Cheap identity for change detection (SceneNode carries
    /// non-Equatable CGColor state): parent, item ids and titles.
    public var fingerprint: String {
        parentID + "|" + items.map { "\($0.id)=\($0.node.title.text)" }.joined(separator: ",")
    }
}

/// The ghost overlay's layer plumbing: one container layer (opacity 0.5)
/// per suggestion holding the node raster plus a dashed border, and one
/// dashed connector per branch — camera-applied exactly like real
/// nodes/branches (placements and transforms on pan/zoom, never a
/// re-raster). Headless: it never needs a window.
@MainActor
final class GhostOverlay {
    let container = CALayer()
    private var itemLayers: [String: GhostItemLayer] = [:]
    private var branchLayers: [CAShapeLayer] = []
    private var current: GhostPresentation?

    init() {
        container.zPosition = 2.5
        container.opacity = GhostPresentation.ghostOpacity
    }

    var presentedIDs: Set<String> {
        Set(itemLayers.keys)
    }

    var isPresented: Bool {
        !itemLayers.isEmpty
    }

    /// Replaces the overlay wholesale: ghosts are few (≤ 8) and rebuilt
    /// as the stream grows, so a flat rebuild beats diffing.
    func update(
        _ presentation: GhostPresentation?,
        camera: Camera,
        backingScale: CGFloat,
        measurer: TextMeasurer
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for layer in itemLayers.values {
            layer.removeFromSuperlayer()
        }
        itemLayers.removeAll()
        for layer in branchLayers {
            layer.removeFromSuperlayer()
        }
        branchLayers.removeAll()
        current = presentation

        guard let presented = presentation else { return }
        for branch in presented.branches {
            let shape = CAShapeLayer()
            shape.zPosition = 0
            shape.transform = CanvasLayerTree.modelSpaceTransform(for: camera)
            shape.path = CanvasLayerTree.branchPath(branch)
            shape.fillColor = nil
            shape.strokeColor = branch.color
            shape.lineWidth = max(branch.startWidth, branch.endWidth)
            shape.lineDashPattern = Self.dashPattern(4, 3, camera: camera)
            container.addSublayer(shape)
            branchLayers.append(shape)
        }

        for item in presented.items {
            let layer = GhostItemLayer()
            layer.nodeID = item.id
            layer.zPosition = 1
            layer.anchorPoint = .zero
            layer.bounds = CGRect(origin: .zero, size: item.node.frame.size)
            layer.transform = CanvasLayerTree.nodeTransform(for: camera)
            layer.position = camera.screenPoint(for: item.node.frame.origin)
            let rasterScale = CanvasLayerTree.clampedRasterScale(
                backingScale: backingScale, camera: camera)
            layer.contents = NodeRasterizer.image(
                node: item.node, hidesTitle: false, lod: false,
                rasterScale: rasterScale, measurer: measurer)
            layer.contentsScale = rasterScale
            layer.contentsGravity = .resize
            layer.border = dashedBorder(item: item, camera: camera)
            container.addSublayer(layer)
            itemLayers[item.id] = layer
        }
    }

    private func dashedBorder(item: GhostPresentation.Item, camera: Camera) -> CAShapeLayer {
        let border = CAShapeLayer()
        let frame = item.node.frame
        let radius: CGFloat =
            item.node.style.shape == .underline ? 4 : min(10, item.node.style.cornerRadius + 2)
        border.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerWidth: radius, cornerHeight: radius, transform: nil)
        border.transform = CanvasLayerTree.nodeTransform(for: camera)
        border.fillColor = nil
        border.strokeColor = item.node.style.borderColor ?? item.node.style.textColor
        border.lineWidth = 1.5 / camera.scale
        border.lineDashPattern = Self.dashPattern(5, 4, camera: camera)
        return border
    }

    /// A dash pattern kept visually constant across zoom (model-space
    /// dash lengths divided by the camera scale).
    private static func dashPattern(_ on: CGFloat, _ off: CGFloat, camera: Camera) -> [NSNumber] {
        [NSNumber(value: Double(on / camera.scale)), NSNumber(value: Double(off / camera.scale))]
    }

    /// Pan/zoom: re-pin the ghost placements (never a re-raster).
    func updateCamera(camera: Camera) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let presentation = current else { return }
        for item in presentation.items {
            guard let layer = itemLayers[item.id] else { continue }
            layer.transform = CanvasLayerTree.nodeTransform(for: camera)
            layer.position = camera.screenPoint(for: item.node.frame.origin)
            if let border = layer.border {
                border.transform = CanvasLayerTree.nodeTransform(for: camera)
            }
        }
        for shape in branchLayers {
            shape.transform = CanvasLayerTree.modelSpaceTransform(for: camera)
        }
    }

    /// The ghost whose frame contains `modelPoint`, innermost first.
    func ghostID(at modelPoint: CGPoint) -> String? {
        guard let presentation = current else { return nil }
        var best: (String, CGFloat)?
        for item in presentation.items {
            guard item.node.frame.contains(modelPoint) else { continue }
            let area = item.node.frame.width * item.node.frame.height
            if best == nil || area < best!.1 {
                best = (item.id, area)
            }
        }
        return best?.0
    }
}

/// One ghost suggestion: the node raster plus its dashed border.
final class GhostItemLayer: CALayer {
    var nodeID: String = ""
    var border: CAShapeLayer?

    override init() {
        super.init()
        anchorPoint = .zero
    }

    override init(layer: Any) {
        let source = layer as? GhostItemLayer
        nodeID = source?.nodeID ?? ""
        border = source?.border
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GhostItemLayer is created directly, never decoded")
    }
}
