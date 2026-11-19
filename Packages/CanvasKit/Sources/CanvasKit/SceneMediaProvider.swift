import CoreGraphics
import MapRender

/// The host's resolved-media lookup (F-CNT-2/3/5): thumbnails for
/// package assets, tinted rasters for SF Symbol markers, and rendered
/// LaTeX glyphs. Kept on the per-document `SceneBuildCache`, so the
/// scene builder reaches it without new signatures anywhere.
///
/// Everything is dictionary/cache lookup — the heavy work (image
/// decode, math typesetting) happens behind the caches, never on the
/// keystroke path. A missing value is a
/// first-class state: the renderer draws the image placeholder and
/// falls back to the LaTeX source text, and the host bumps `revision`
/// when an async decode lands so exactly the media-carrying nodes
/// re-raster.
///
/// Like `SceneBuildCache`, main-actor confined by construction but
/// not annotated: `SceneGeometry` is a synchronous, nonisolated
/// pipeline the main actor drives (SPEC §11.5).
public struct SceneMediaProvider {
    /// `assets/` filename → decoded thumbnail (F-CNT-2).
    public var image: ((_ asset: String) -> CGImage?)?
    /// SF Symbol marker token → tinted glyph (F-CNT-3).
    public var marker: ((_ token: String, _ tint: CGColor) -> CGImage?)?
    /// LaTeX source → rendered glyph (F-CNT-5); nil renders the source
    /// text.
    public var math: ((_ latex: String, _ font: FontSpec, _ tint: CGColor) -> MathGlyph?)?
    /// Bumped when any cached raster behind these closures was
    /// replaced (async decode completion) — media-carrying nodes
    /// re-raster.
    public var revision: Int

    public init(
        image: ((_ asset: String) -> CGImage?)? = nil,
        marker: ((_ token: String, _ tint: CGColor) -> CGImage?)? = nil,
        math: ((_ latex: String, _ font: FontSpec, _ tint: CGColor) -> MathGlyph?)? = nil,
        revision: Int = 0
    ) {
        self.image = image
        self.marker = marker
        self.math = math
        self.revision = revision
    }

    public var isEmpty: Bool { image == nil && marker == nil && math == nil }

    /// Composes one node's drawing-time media (nil when the node has
    /// nothing media-backed: no image, no SF markers, no math).
    public func media(
        for decorations: MapRender.NodeDecorations?, title: String, style: ResolvedNodeStyle
    ) -> NodeMedia? {
        guard let decorations else { return nil }
        let tint = style.borderColor ?? style.textColor
        var media = NodeMedia()
        var carries = false

        if let block = decorations.image {
            media.image = image?(block.asset)
            carries = true
        }
        if !decorations.markers.isEmpty {
            for marker in decorations.markers where marker.token.hasPrefix("sf:") {
                if let glyph = self.marker?(marker.token, tint) {
                    media.markerImages[marker.token] = glyph
                }
            }
            carries = carries || !media.markerImages.isEmpty
        }
        if decorations.math {
            media.math = math?(title, style.font, tint)
            carries = carries || media.math != nil
        }
        guard carries else { return nil }
        media.revision = revision
        return media
    }
}
