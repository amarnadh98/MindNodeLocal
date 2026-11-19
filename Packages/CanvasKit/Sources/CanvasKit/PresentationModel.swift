import CoreGraphics
import Foundation
import MapCore

/// One slide ready to present or export (M6): a `MapCore.Slide`
/// resolved against reality — geometry for the camera, the managed
/// focus/build sets for the reveal overlay, and the notes the
/// presenter view shows. Auto slides (F-PRE-1) and authored slides
/// (F-PRE-2/3) both resolve into this one shape, so presenting and
/// PDF export never care which authoring model produced them.
public struct ResolvedSlide: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The whole map, everything visible.
        case overview
        /// One level-1 branch (auto presentation), others ghosted.
        case branch
        /// One level-2 child of a large branch (auto presentation).
        case sub
        /// Captured by hand in the Slides sidebar.
        case authored
    }

    public var kind: Kind
    public var title: String
    /// The stored camera (authored slides). Used as-is: it is exactly
    /// what the author captured.
    public var camera: SlideCamera?
    /// When set, the camera fits this model-space rect into the target
    /// viewport at apply time (auto slides, and any slide whose focus
    /// frames are known). Aspect-correct for whatever screen presents.
    public var cameraFit: CGRect?
    /// The nodes folded for this slide (the complete fold state; see
    /// `MapModel.applyingSlideFold`).
    public var folded: [String]
    /// Nodes fully visible whatever the build state.
    public var focus: Set<String>
    /// True when everything outside focus+build ghosts at 15%.
    public var dimOthers: Bool
    /// The build order (F-PRE-3): each entry is one reveal step.
    public var build: [String]
    /// Speaker notes (F-PRE-5).
    public var notes: String

    public init(
        kind: Kind,
        title: String,
        camera: SlideCamera? = nil,
        cameraFit: CGRect? = nil,
        folded: [String] = [],
        focus: Set<String> = [],
        dimOthers: Bool = false,
        build: [String] = [],
        notes: String = ""
    ) {
        self.kind = kind
        self.title = title
        self.camera = camera
        self.cameraFit = cameraFit
        self.folded = folded
        self.focus = focus
        self.dimOthers = dimOthers
        self.build = build
        self.notes = notes
    }

    /// The camera this slide presents at, resolved for a concrete
    /// viewport. A camera-fit rect wins (aspect-correct for any
    /// screen); else the stored camera; else the whole-scene fit.
    public func camera(for viewport: CGSize, scene: CanvasScene, margin: CGFloat) -> Camera {
        if let fit = cameraFit {
            return CameraFit.camera(fitting: fit, in: viewport, margin: margin)
        }
        if let stored = camera {
            return Camera(origin: CGPoint(x: stored.x, y: stored.y), scale: stored.scale)
        }
        return CameraFit.camera(fitting: scene.bounds, in: viewport, margin: margin)
    }
}

/// Aspect-correct fit of a model-space rect into a viewport — the one
/// camera computation auto slides, the canvas fit commands and slide
/// PDF pages all share.
public enum CameraFit {
    /// The camera that shows `rect` filling `viewport` with `margin`
    /// points of air on every side (clamped 0.1…4×, like the canvas).
    public static func camera(fitting rect: CGRect, in viewport: CGSize, margin: CGFloat) -> Camera {
        guard !rect.isNull, rect.width > 0, rect.height > 0,
            viewport.width > margin * 2, viewport.height > margin * 2
        else {
            return Camera(origin: CGPoint(x: rect.midX, y: rect.midY), scale: 1)
        }
        let content = rect.insetBy(dx: -margin, dy: -margin)
        let scale = min(
            max(
                min(viewport.width / content.width, viewport.height / content.height), 0.1), 4)
        return Camera(
            origin: CGPoint(
                x: content.midX - viewport.width / scale / 2,
                y: content.midY - viewport.height / scale / 2),
            scale: scale)
    }
}

/// Authoring-model resolution and the pure scene preparation the
/// presenting window runs (M6). Presentation never mutates the
/// document: the fold state of a slide is applied to a **derived**
/// model for the scene build.
public enum PresentationGeometry {
    /// The model a slide's scene builds from: every node unfolded,
    /// then exactly the slide's fold list folded — reproducing the
    /// fold state the author captured, whatever the live map looks
    /// like now. Pure; the document is never touched.
    public static func applyingFoldState(_ foldedIDs: [String], to model: MapModel) -> MapModel {
        var derived = model
        let folded = Set(foldedIDs)
        for (id, node) in model.nodes {
            let shouldFold = folded.contains(id)
            if node.folded != shouldFold {
                derived.nodes[id]?.folded = shouldFold
            }
        }
        return derived
    }

    /// Resolves an authored presentation (F-PRE-2) into presentable
    /// slides. Slides keep their captured camera; a missing focus or
    /// camera falls back to the whole-scene fit. Slide ids referencing
    /// nodes that no longer exist resolve to empty sets — a deleted
    /// branch degrades gracefully instead of breaking the deck.
    public static func resolve(presentation: Presentation, scene: CanvasScene) -> [ResolvedSlide] {
        presentation.slides.enumerated().map { index, slide in
            let focus = Set((slide.focus ?? []).filter { scene.nodes[$0] != nil })
            let build = (slide.build ?? []).filter { scene.nodes[$0] != nil }
            return ResolvedSlide(
                kind: .authored,
                title: slide.title ?? "Slide \(index + 1)",
                camera: slide.camera,
                cameraFit: nil,
                folded: slide.folded ?? [],
                focus: focus,
                dimOthers: slide.dimOthers ?? true,
                build: build,
                notes: slide.notes ?? "")
        }
    }

    /// The universe a slide's reveal engine manages: its focus set
    /// plus its build ids. Everything else stays unmanaged (fully
    /// visible, or ghosted when `dimOthers`).
    public static func managedIDs(of slide: ResolvedSlide) -> Set<String> {
        slide.focus.union(slide.build)
    }

    /// The ghost set of a focus slide (F-PRE-1: others at 15%): every
    /// scene node outside the managed set. Empty unless `dimOthers`.
    public static func dimmedIDs(of slide: ResolvedSlide, scene: CanvasScene) -> Set<String> {
        guard slide.dimOthers else { return [] }
        return Set(scene.nodes.keys).subtracting(managedIDs(of: slide))
    }
}
