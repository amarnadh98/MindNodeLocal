import CoreGraphics
import Foundation
import MapCore
import MapRender
import QuartzCore

// MARK: - layer subclasses

/// A pooled node layer. `nodeID` moves with the layer through the
/// pool; a recycled layer never keeps the previous node's raster
/// (the raster key is dropped on recycle).
final class NodeVisualLayer: CALayer {
    var nodeID: String
    var rasterKey: NodeRasterKey?

    init(nodeID: String) {
        self.nodeID = nodeID
        super.init()
        anchorPoint = .zero
        contentsGravity = .resize
        magnificationFilter = .linear
    }

    /// Core Animation copies a layer this way for its presentation
    /// layer whenever an animation runs; without it a relayout
    /// animation traps.
    override init(layer: Any) {
        let source = layer as? NodeVisualLayer
        nodeID = source?.nodeID ?? ""
        rasterKey = source?.rasterKey
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NodeVisualLayer is created directly, never decoded")
    }

    func reset(for id: String) {
        nodeID = id
    }
}

/// A pooled branch shape layer.
final class BranchVisualLayer: CAShapeLayer {
    var key: BranchKey
    var branch: SceneBranch?

    init(key: BranchKey) {
        self.key = key
        super.init()
        lineJoin = .round
        opacity = 1
    }

    /// The presentation-layer copy Core Animation makes for every
    /// running animation (see `NodeVisualLayer.init(layer:)`).
    override init(layer: Any) {
        let source = layer as? BranchVisualLayer
        key = source?.key ?? BranchKey(parentID: "", childID: "")
        branch = source?.branch
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BranchVisualLayer is created directly, never decoded")
    }

    func reset(for newKey: BranchKey) {
        key = newKey
    }
}

/// When a node layer must re-raster: title, frame size, style, LOD
/// mode, editing state, raster sharpness or **decoration state** (M3:
/// task, note, link, tags) changed (pan and pure position moves never
/// repaint — §11.4).
struct NodeRasterKey: Equatable {
    let title: NodeTitle
    let size: CGSize
    let style: ResolvedNodeStyle
    let lod: Bool
    let hidesTitle: Bool
    let rasterScale: CGFloat
    let decorations: NodeDecorations?

    static func == (lhs: NodeRasterKey, rhs: NodeRasterKey) -> Bool {
        lhs.title == rhs.title
            && lhs.size == rhs.size
            && lhs.lod == rhs.lod
            && lhs.hidesTitle == rhs.hidesTitle
            && lhs.decorations == rhs.decorations
            && abs(lhs.rasterScale - rhs.rasterScale) < 0.001
            && SceneDiffer.sameStyle(lhs.style, rhs.style)
    }
}

/// Rasters one node into a `CGContext` through the shared
/// `NodeRenderer` — the same drawing path export uses — and hands the
/// layer the resulting image.
@MainActor
enum NodeRasterizer {
    static func image(
        node: SceneNode,
        hidesTitle: Bool,
        lod: Bool,
        rasterScale: CGFloat,
        measurer: TextMeasurer
    ) -> CGImage? {
        let size = node.frame.size
        guard size.width >= 0.5, size.height >= 0.5 else { return nil }
        let scale = min(max(rasterScale, 1), CanvasLayerTree.maxRasterScale)
        let width = max(1, Int((size.width * scale).rounded(.up)))
        let height = max(1, Int((size.height * scale).rounded(.up)))
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The renderer's convention: flipped, top-left origin.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        if lod {
            drawCapsule(style: node.style, in: context, frame: CGRect(origin: .zero, size: size))
        } else {
            NodeRenderer.draw(
                style: node.style,
                title: hidesTitle ? NodeTitle(text: "", runs: []) : node.title,
                decorations: node.decorations,
                measurer: measurer,
                in: context,
                frame: CGRect(origin: .zero, size: size))
        }
        return context.makeImage()
    }

    /// §11.4 LOD: a colored capsule without text at very low zoom.
    private static func drawCapsule(style: ResolvedNodeStyle, in context: CGContext, frame: CGRect) {
        let color = style.fillColor ?? style.textColor
        context.setFillColor(color)
        let radius = frame.height / 2
        context.addPath(
            CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }
}
