import CoreGraphics

/// The canvas camera. `origin` is the model-space point at the viewport's top-left corner;
/// `scale` is the zoom factor applied from model space to screen space.
public struct Camera: Sendable, Equatable {
    public var origin: CGPoint
    public var scale: CGFloat

    public init(origin: CGPoint = .zero, scale: CGFloat = 1.0) {
        self.origin = origin
        self.scale = scale
    }

    /// Converts a model-space point to screen (viewport) coordinates.
    public func screenPoint(for modelPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (modelPoint.x - origin.x) * scale,
            y: (modelPoint.y - origin.y) * scale
        )
    }

    /// Converts a screen (viewport) point back to model space.
    public func modelPoint(for screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x / scale + origin.x,
            y: screenPoint.y / scale + origin.y
        )
    }

    /// The model-space rectangle visible in a viewport of the given size.
    public func visibleRect(viewportSize: CGSize) -> CGRect {
        CGRect(
            x: origin.x,
            y: origin.y,
            width: viewportSize.width / scale,
            height: viewportSize.height / scale
        )
    }
}
