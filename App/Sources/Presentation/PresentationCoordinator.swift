import AppKit
import CanvasKit
import MapCore
import MapRender
import MapStudy
import SwiftUI

/// Owns one presentation run (M6, F-PRE-4…7): resolves the deck
/// (authored slides when the document has any, the F-PRE-1 auto deck
/// otherwise), drives the pure `PresenterInput` machine over real key
/// events, and materializes its effects onto the audience window and
/// the presenter view.
///
/// Presenting never performs a `MapCommand`: slides change cameras,
/// fold state (applied to a **derived** model) and reveal overlays —
/// all view state, none of it document state (F-PRE-4: the document
/// is never dirtied by presenting).
@MainActor
final class PresentationCoordinator {
    /// One display, as the coordinator sees it. `availableScreens` is
    /// a seam: tests inject fake screen lists (the two-display
    /// presenter path never needs real hardware).
    struct ScreenSpec: Equatable, Sendable {
        let id: String
        let frame: CGRect
        let isMain: Bool

        init(id: String, frame: CGRect, isMain: Bool) {
            self.id = id
            self.frame = frame
            self.isMain = isMain
        }

        init(screen: NSScreen) {
            id = screen.localizedName
            frame = screen.frame
            isMain = screen == NSScreen.main
        }
    }

    private unowned let windowController: DocumentWindowController
    private let store: MapStore

    /// The screens presenting can use; injectable for tests.
    var availableScreens: () -> [ScreenSpec] = {
        NSScreen.screens.map(ScreenSpec.init(screen:))
    }

    /// Motion preference at present time (SPEC §7.6).
    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: presentation state

    private(set) var slides: [ResolvedSlide] = []
    private(set) var session = PresenterSession()
    private var deck = PresenterDeck(slidesBuildCounts: [])
    private(set) var isPresenting = false
    private(set) var startedAt: Date?
    private var presentationWindow: NSWindow?
    private var presenterWindowController: PresenterWindowController?
    private(set) var presentationView: PresentationView?
    /// True when the audience window is open but live-edit-paused
    /// (F-PRE-6: E closes the full-screen surface; ⌘⏎ rebuilds it).
    private(set) var isLiveEditPaused = false
    /// The ⌥P presenter-view preference for the single-display case.
    private var presenterManuallyVisible = false

    /// A fresh coordinator per document window controller.
    init(windowController: DocumentWindowController, store: MapStore) {
        self.windowController = windowController
        self.store = store
    }

    // MARK: deck resolution

    /// The deck a Present run uses: the first authored presentation
    /// with slides (F-PRE-2), else the F-PRE-1 auto-generated deck.
    static func resolveDeck(model: MapModel, variant: ThemeVariant) -> [ResolvedSlide] {
        let unfolded = PresentationGeometry.applyingFoldState([], to: model)
        let scene = SceneGeometry.build(
            model: unfolded, variant: variant, measurer: SceneRenderer.sharedMeasurer,
            theme: ThemeCatalog.shared.theme(for: model))
        if let authored = (model.presentations ?? []).first(where: { !$0.slides.isEmpty }) {
            return PresentationGeometry.resolve(presentation: authored, scene: scene)
        }
        return AutoPresentation.slides(model: model, scene: scene)
    }

    /// The audience screen (F-PRE-4: full screen on the *selected*
    /// display): with two or more, the first screen that is not the
    /// one holding the document window — the projector; with one, that
    /// screen. Pure over the injected list, so the choice is testable.
    static func audienceScreen(from screens: [ScreenSpec], documentScreenID: String?) -> ScreenSpec? {
        guard let first = screens.first else { return nil }
        guard screens.count > 1 else { return first }
        return screens.first { $0.id != documentScreenID } ?? first
    }

    /// The screen the presenter view opens on: where the document
    /// window lives, when that is not the audience screen (F-PRE-5:
    /// "presenter view on the second display").
    static func presenterScreen(
        from screens: [ScreenSpec], audience: ScreenSpec, documentScreenID: String?
    ) -> ScreenSpec? {
        if let documentScreenID {
            let onDocument = screens.first { $0.id == documentScreenID }
            if let onDocument, onDocument != audience {
                return onDocument
            }
        }
        return screens.first { $0 != audience } ?? nil
    }

    private func documentScreenID() -> String? {
        guard let window = windowController.window else { return nil }
        return availableScreens().first { screen in
            screen.frame.contains(window.frame.origin)
        }?.id
    }

    // MARK: start / stop

    /// ⌥⌘⏎ / toolbar ▶︎: builds the deck and opens the audience window
    /// (plus the presenter view when there is a second display).
    func startPresenting() {
        guard !isPresenting else { return }
        let model = store.model
        slides = Self.resolveDeck(model: model, variant: windowController.currentVariant())
        guard !slides.isEmpty else { return }
        deck = PresenterDeck(slidesBuildCounts: slides.map(\.build.count))
        session = PresenterSession()
        session.liveEditPaused = false
        isLiveEditPaused = false
        startedAt = Date()

        let screens = availableScreens()
        let audience = Self.audienceScreen(from: screens, documentScreenID: documentScreenID())
        let view = PresentationView(frame: NSRect(origin: .zero, size: audience?.frame.size ?? .zero))
        view.reduceMotion = reduceMotion
        view.onEvent = { [weak self] event in self?.handleEvent(event) }

        let window = NSWindow(
            contentRect: audience?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.contentView = view
        presentationWindow = window
        presentationView = view
        isPresenting = true
        window.makeKeyAndOrderFront(nil)
        view.makeShieldFirstResponder()
        applySlide(session.slideIndex, buildCursor: session.buildCursor, animated: false)

        // F-PRE-5: with a second display the presenter view rides it;
        // ⌥P toggles it on one display.
        if let audience,
            let presenter = Self.presenterScreen(
                from: screens, audience: audience, documentScreenID: documentScreenID())
        {
            openPresenterWindow(on: presenter)
        } else if presenterManuallyVisible, let screen = screens.first {
            openPresenterWindow(on: screen)
        }
    }

    /// F-PRE-6 ⌘⏎: rebuild the audience surface where presenting
    /// paused and keep going.
    func resumeFromLiveEdit() {
        guard !isPresenting, isLiveEditPaused else { return }
        isLiveEditPaused = false
        session.liveEditPaused = false
        isPresenting = true
        startedAt = startedAt ?? Date()
        startPresentingWindows()
        applySlide(session.slideIndex, buildCursor: session.buildCursor, animated: false)
    }

    /// (Re)creates the audience window for a resume; the deck and the
    /// session state were kept.
    private func startPresentingWindows() {
        let screens = availableScreens()
        let audience = Self.audienceScreen(from: screens, documentScreenID: documentScreenID())
        let view = PresentationView(frame: NSRect(origin: .zero, size: audience?.frame.size ?? .zero))
        view.reduceMotion = reduceMotion
        view.onEvent = { [weak self] event in self?.handleEvent(event) }
        let window = NSWindow(
            contentRect: audience?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.contentView = view
        presentationWindow = window
        presentationView = view
        window.makeKeyAndOrderFront(nil)
        view.makeShieldFirstResponder()
    }

    /// Test seam: the live presenter dashboard controller (nil when
    /// the presenter view is closed).
    var presenterWindowControllerForTests: PresenterWindowController? {
        presenterWindowController
    }

    /// Esc: closes both windows. Nothing was ever written to the
    /// document.
    func endPresenting() {
        presentationWindow?.orderOut(nil)
        presentationWindow = nil
        presentationView = nil
        presenterWindowController?.close()
        presenterWindowController = nil
        isPresenting = false
        isLiveEditPaused = false
        session.liveEditPaused = false
        presenterManuallyVisible = false
    }

    // MARK: events → machine → effects

    func handleEvent(_ event: PresenterEvent) {
        let result = PresenterInput.update(session, deck: deck, event: event)
        session = result.session
        for effect in result.effects {
            applyEffect(effect)
        }
    }

    private func applyEffect(_ effect: PresenterEffect) {
        switch effect {
        case .revealNextBuild:
            revealBuildStep()
        case .unrevealLastBuild:
            applySlide(session.slideIndex, buildCursor: session.buildCursor, animated: false)
        case .showSlide(let index, let buildCursor):
            applySlide(index, buildCursor: buildCursor, animated: true)
        case .setScreen(let screen):
            presentationView?.setScreen(screen)
            refreshPresenter()
        case .exitPresentation:
            endPresenting()
        case .togglePresenterView:
            togglePresenterView()
        case .pauseForLiveEdit:
            pauseForLiveEdit()
        case .resumeFromLiveEdit:
            resumeFromLiveEdit()
        case .laserActive(let active):
            presentationView?.setLaser(active: active)
        case .spotlightActive(let active):
            presentationView?.setSpotlight(active: active)
        }
    }

    // MARK: slide application

    /// Materializes slide `index` at `buildCursor`: fold state applied
    /// to a derived model, scene built, reveal overlay from the engine,
    /// camera per §7.6 (600 ms tween after the first slide).
    private func applySlide(_ index: Int, buildCursor: Int, animated: Bool) {
        guard let view = presentationView, slides.indices.contains(index) else { return }
        session.slideIndex = index
        session.buildCursor = buildCursor
        let slide = slides[index]

        let derived = PresentationGeometry.applyingFoldState(slide.folded, to: store.model)
        let scene = SceneGeometry.build(
            model: derived, variant: windowController.currentVariant(),
            measurer: SceneRenderer.sharedMeasurer,
            theme: ThemeCatalog.shared.theme(for: store.model))
        let camera = slide.camera(
            for: view.bounds.size, scene: scene, margin: Self.presentationCameraMargin)
        let engine = RevealEngine(
            model: derived, steps: slide.build.map { RevealStep(ids: [$0]) },
            baseVisible: slide.focus)
        let states = engine.states(at: buildCursor, universe: PresentationGeometry.managedIDs(of: slide))
        let overlay = RevealOverlay(
            states: states, dimmed: PresentationGeometry.dimmedIDs(of: slide, scene: scene))
        view.load(scene: scene, overlay: overlay, camera: camera, animated: animated)
        refreshPresenter()
    }

    /// The audience camera margin (F-PRE-1: "fit of the slide's focus
    /// set with margin").
    static let presentationCameraMargin: CGFloat = 80

    /// One build step forward (F-PRE-3): the overlay already shows the
    /// step's ids; the fade + 8 pt slide animation rides on top.
    private func revealBuildStep() {
        guard let view = presentationView, slides.indices.contains(session.slideIndex) else { return }
        let slide = slides[session.slideIndex]
        guard session.buildCursor >= 0, session.buildCursor < slide.build.count else { return }
        view.reveal(ids: [slide.build[session.buildCursor]])
    }

    // MARK: live edit (F-PRE-6)

    /// E: leave the full-screen surface and edit — the document window
    /// sits at the presentation camera, so typing happens at the exact
    /// place the audience was looking. The deck and cursor are kept for
    /// ⌘⏎.
    private func pauseForLiveEdit() {
        guard isPresenting else { return }
        let camera = presentationView?.canvas.camera
        presentationWindow?.orderOut(nil)
        presentationWindow = nil
        presentationView = nil
        isPresenting = false
        isLiveEditPaused = true
        session.liveEditPaused = true
        if let camera {
            windowController.canvas.camera = camera
        }
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.window?.makeFirstResponder(windowController.canvas)
    }

    // MARK: presenter view (F-PRE-5)

    private func openPresenterWindow(on screen: ScreenSpec) {
        let controller = PresenterWindowController(coordinator: self, screen: screen)
        presenterWindowController = controller
        controller.showWindow(nil)
        refreshPresenter()
    }

    /// ⌥P: toggle the presenter view (the one-display case; with two
    /// displays it stays open for the whole run).
    private func togglePresenterView() {
        if let presenterWindowController {
            presenterWindowController.close()
            self.presenterWindowController = nil
            presenterManuallyVisible = false
        } else {
            presenterManuallyVisible = true
            if let screen = availableScreens().first {
                openPresenterWindow(on: screen)
            }
        }
    }

    /// Pushes the current state into the presenter dashboard (and
    /// nothing when it is closed).
    private func refreshPresenter() {
        guard let presenterWindowController else { return }
        let variant = windowController.currentVariant()
        let slide = slides.indices.contains(session.slideIndex) ? slides[session.slideIndex] : nil
        let next =
            slides.indices.contains(session.slideIndex + 1)
            ? slides[session.slideIndex + 1] : nil
        let camera = presentationView?.canvas.camera
        guard let slide, let camera else { return }
        let scene = SceneGeometry.build(
            model: PresentationGeometry.applyingFoldState(slide.folded, to: store.model),
            variant: variant, measurer: SceneRenderer.sharedMeasurer,
            theme: ThemeCatalog.shared.theme(for: store.model))
        var nextScene: CanvasScene?
        var nextCamera: Camera?
        if let next {
            let scene2 = SceneGeometry.build(
                model: PresentationGeometry.applyingFoldState(next.folded, to: store.model),
                variant: variant, measurer: SceneRenderer.sharedMeasurer,
                theme: ThemeCatalog.shared.theme(for: store.model))
            nextScene = scene2
            nextCamera = next.camera(
                for: CGSize(width: 320, height: 180), scene: scene2, margin: Self.presentationCameraMargin)
        }
        var update = PresenterDashboardModel.Update()
        update.slideIndex = session.slideIndex
        update.slideCount = slides.count
        update.buildCursor = session.buildCursor
        update.buildCount = slide.build.count
        update.notes = slide.notes
        update.nextNotes = next?.notes ?? ""
        update.scene = scene
        update.camera = camera
        update.nextScene = nextScene
        update.nextCamera = nextCamera
        update.startedAt = startedAt ?? Date()
        update.screenBlanked = session.screen != .normal
        presenterWindowController.update(update)
    }

    /// The presenter window closed itself (its close button): the
    /// coordinator forgets it; ⌥P reopens.
    func presenterWindowDidClose() {
        presenterWindowController = nil
        presenterManuallyVisible = false
    }

    // MARK: export (M6 exit list)

    /// File ▸ Export Slides as PDF: the same deck resolution, written
    /// with the shared renderer (F-PRE-8's PDF half).
    func exportSlidesPDF(to url: URL, pagePerBuildStep: Bool, includeNotes: Bool) throws -> Int {
        let model = store.model
        let slides = Self.resolveDeck(model: model, variant: windowController.currentVariant())
        var options = SlidesPDFWriter.Options()
        options.pagePerBuildStep = pagePerBuildStep
        options.includeNotes = includeNotes
        return try SlidesPDFWriter.write(
            model: model, variant: windowController.currentVariant(), slides: slides,
            options: options, to: url)
    }
}
