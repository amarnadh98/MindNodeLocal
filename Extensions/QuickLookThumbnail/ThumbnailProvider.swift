import Foundation
import QuickLookThumbnailing
import SystemIntegration

/// F-INT-3: the Quick Look thumbnail app extension for `.arbor`
/// packages. Uses the `QuickLook/Thumbnail.png` the app writes on
/// every save when it is fresh and covers the requested size, and
/// re-renders through the shared scene exporters otherwise (headless —
/// this target links `SystemIntegration`/`SceneExport`, never the app's
/// canvas code; ADR-0027).
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        guard request.fileURL.pathExtension.caseInsensitiveCompare("arbor") == .orderedSame,
            let image = ArborPreviewRenderer.thumbnailImage(
                at: request.fileURL,
                maximumPixelSize: request.maximumSize,
                scale: request.scale)
        else {
            handler(nil, QuickLookThumbnailError.renderFailed)
            return
        }
        // The reply draws the image into the system-provided bitmap
        // context; the context size keeps the image's aspect ratio
        // inside the requested box.
        let aspect = CGFloat(image.width) / max(1, CGFloat(image.height))
        var contextSize = request.maximumSize
        if contextSize.width / max(1, contextSize.height) > aspect {
            contextSize.width = max(1, contextSize.height * aspect)
        } else {
            contextSize.height = max(1, contextSize.width / aspect)
        }
        handler(
            QLThumbnailReply(
                contextSize: contextSize,
                drawing: { context in
                    context.interpolationQuality = .high
                    context.draw(image, in: CGRect(origin: .zero, size: contextSize))
                    return true
                }),
            nil)
    }
}

enum QuickLookThumbnailError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: "The map package has no renderable content."
        }
    }
}
