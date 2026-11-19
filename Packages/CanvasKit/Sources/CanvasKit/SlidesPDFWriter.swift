import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import MapStudy

/// Exports a presentation as PDF (M6 exit list, F-PRE-8's PDF half):
/// one page per slide — or, with `pagePerBuildStep`, one page per
/// build state, base state first — plus optional notes pages after
/// each slide. Every page draws through the shared `SceneRenderer`
/// (the same `NodeRenderer`/`TextMeasurer` path as the canvas), with
/// the slide's fold state applied to a derived model and the reveal
/// overlay honored, so a page is exactly what the audience saw.
public enum SlidesPDFWriter {
    public struct Options: Sendable, Equatable {
        /// One page per build state instead of one per slide.
        public var pagePerBuildStep: Bool
        /// A notes page after every slide.
        public var includeNotes: Bool
        /// The page size in points (16:9 like a presentation screen).
        public var pageSize: CGSize
        /// Camera margin on every page.
        public var margin: CGFloat

        public init(pagePerBuildStep: Bool = false, includeNotes: Bool = false) {
            self.pagePerBuildStep = pagePerBuildStep
            self.includeNotes = includeNotes
            self.pageSize = CGSize(width: 1024, height: 576)
            self.margin = 48
        }
    }

    public enum PDFError: Error, Equatable {
        case cannotCreateContext
        case emptyDeck
    }

    /// Writes the deck to `url` and returns the page count.
    @discardableResult
    public static func write(
        model: MapModel,
        variant: ThemeVariant,
        slides: [ResolvedSlide],
        options: Options = Options(),
        to url: URL
    ) throws -> Int {
        guard !slides.isEmpty else { throw PDFError.emptyDeck }
        var mediaBox = CGRect(origin: .zero, size: options.pageSize)
        let auxiliary: [CFString: Any] = [kCGPDFContextTitle: "Arbor Presentation"]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, auxiliary as CFDictionary)
        else {
            throw PDFError.cannotCreateContext
        }

        var pages = 0
        for slide in slides {
            // The slide's fold state, applied to a derived model: the
            // document itself is never touched.
            let derived = PresentationGeometry.applyingFoldState(slide.folded, to: model)
            let scene = SceneGeometry.build(
                model: derived, variant: variant, measurer: SceneRenderer.sharedMeasurer)
            let camera = slide.camera(for: options.pageSize, scene: scene, margin: options.margin)
            let engine = RevealEngine(
                model: derived, steps: slide.build.map { RevealStep(ids: [$0]) },
                baseVisible: slide.focus)
            let overlayAtCursor = { (cursor: Int) -> RevealOverlay in
                let states = engine.states(at: cursor, universe: PresentationGeometry.managedIDs(of: slide))
                return RevealOverlay(
                    states: states, dimmed: PresentationGeometry.dimmedIDs(of: slide, scene: scene))
            }
            if options.pagePerBuildStep {
                for cursor in RevealEngine.startCursor...max(RevealEngine.startCursor, slide.build.count - 1) {
                    drawSlidePage(
                        scene: scene, camera: camera, overlay: overlayAtCursor(cursor),
                        context: context, options: options)
                    pages += 1
                }
            } else {
                drawSlidePage(
                    scene: scene, camera: camera, overlay: overlayAtCursor(RevealEngine.startCursor),
                    context: context, options: options)
                pages += 1
            }
            if options.includeNotes {
                drawNotesPage(slide: slide, context: context, options: options)
                pages += 1
            }
        }
        context.closePDF()
        return pages
    }

    /// Draws one slide page through the shared `SceneRenderer` — the
    /// same drawing path as the canvas (SPEC §11: one renderer behind
    /// everything).
    static func drawSlidePage(
        scene: CanvasScene,
        camera: Camera,
        overlay: RevealOverlay,
        context: CGContext,
        options: Options
    ) {
        context.beginPDFPage(nil)
        // SceneRenderer draws into a flipped (y-down) context; flip the
        // y-up PDF page once per page.
        context.translateBy(x: 0, y: options.pageSize.height)
        context.scaleBy(x: 1, y: -1)
        SceneRenderer.draw(
            scene: scene, camera: camera, selectionColor: NSColor.controlAccentColor.cgColor,
            revealOverlay: overlay, in: context, viewport: options.pageSize)
        context.endPDFPage()
    }

    static func drawNotesPage(
        slide: ResolvedSlide, context: CGContext, options: Options
    ) {
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: options.pageSize.height)
        context.scaleBy(x: 1, y: -1)

        let inset = options.margin
        let textRect = CGRect(
            origin: CGPoint(x: inset, y: inset),
            size: CGSize(width: options.pageSize.width - inset * 2, height: options.pageSize.height - inset * 2))
        let title = NSAttributedString(
            string: slide.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: NSColor.textColor,
            ])
        let notes = NSAttributedString(
            string: slide.notes.isEmpty ? "No notes." : slide.notes,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.textColor,
            ])

        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        title.draw(in: CGRect(origin: textRect.origin, size: textRect.size))
        let notesOrigin = CGPoint(x: textRect.minX, y: textRect.minY + 44)
        notes.draw(
            in: CGRect(
                origin: notesOrigin,
                size: CGSize(width: textRect.width, height: textRect.height - 44)))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
}
