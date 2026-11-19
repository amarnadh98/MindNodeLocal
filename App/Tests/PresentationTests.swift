import AppKit
import CanvasKit
import MapCore
import PDFKit
import Testing

@testable import Arbor

/// Hosted M6 presentation tests: the ⌥⌘⏎ flow, builds, slide
/// authoring as single undo steps, PDF export page counts, and golden
/// scenario 4 (SPEC §3 item 4) as far as one display can take it —
/// the two-display presenter path runs against an injected fake screen
/// list (the seam `PresentationCoordinator.availableScreens`).
@MainActor
struct PresentationTests {
    /// root ─ a, b, c with notes (an auto-deckable map).
    private static func presentationModel(docID: String = "presentation-doc") -> MapModel {
        var model = MapModel.emptyDocument(docID: docID)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for (id, parent) in [("root", nil as String?), ("a", "root"), ("b", "root"), ("c", "root")] {
            var node = Node(
                id: id, parent: parent, title: NodeTitle(text: "node \(id)"),
                created: date, modified: date)
            if id == "a" {
                node.note = "speaker notes for a"
            }
            model.nodes[id] = node
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        return model
    }

    private func openShownDocument(_ model: MapModel) throws -> MapDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("present-\(UUID().uuidString).arbor")
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        controller.viewStateStore = ViewStateStore(
            baseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("present-\(UUID().uuidString)"))
        controller.showWindow(nil)
        return document
    }

    private func coordinator(of controller: DocumentWindowController) throws -> PresentationCoordinator {
        let store = try #require((controller.document as? MapDocument)?.store)
        let coordinator =
            controller.presentationCoordinatorBox
            ?? PresentationCoordinator(windowController: controller, store: store)
        controller.presentationCoordinatorBox = coordinator
        return coordinator
    }

    private var fakeSingleScreen: () -> [PresentationCoordinator.ScreenSpec] {
        {
            [
                PresentationCoordinator.ScreenSpec(
                    id: "only", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true)
            ]
        }
    }

    /// Main covers the document window's origin; the "projector" is a
    /// second display to the right.
    private func fakeTwoScreens(windowOrigin: CGPoint) -> () -> [PresentationCoordinator.ScreenSpec] {
        {
            [
                PresentationCoordinator.ScreenSpec(
                    id: "main",
                    frame: CGRect(
                        x: windowOrigin.x - 1000, y: windowOrigin.y - 1000, width: 3000, height: 3000),
                    isMain: true),
                PresentationCoordinator.ScreenSpec(
                    id: "projector",
                    frame: CGRect(x: 2000, y: 0, width: 1920, height: 1080), isMain: false),
            ]
        }
    }

    // MARK: F-PRE-4 — presenting never dirties the document

    @Test func presentEntersAndEscExitsWithoutDirtyingTheDocument() throws {
        let document = try openShownDocument(Self.presentationModel())
        defer { document.close() }
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let coordinator = try coordinator(of: controller)
        coordinator.availableScreens = fakeSingleScreen
        let wasEdited = document.isDocumentEdited

        // ⌥⌘⏎ / toolbar ▶︎.
        controller.presentAction(nil)
        #expect(coordinator.isPresenting)
        #expect(coordinator.presentationView != nil)
        #expect(coordinator.slides.first?.kind == .overview)

        // Advance through the whole deck and blank the screen — none
        // of it touches the model.
        for _ in 0..<(coordinator.slides.count + 4) {
            coordinator.handleEvent(.keyDown(.rightArrow))
        }
        coordinator.handleEvent(.keyDown(.blackKey))
        coordinator.handleEvent(.keyDown(.blackKey))
        #expect(document.isDocumentEdited == wasEdited)

        // Esc exits.
        coordinator.handleEvent(.keyDown(.escape))
        #expect(!coordinator.isPresenting)
        #expect(document.isDocumentEdited == wasEdited)
    }

    // MARK: F-PRE-3 — next advances builds, then slides

    @Test func nextAdvancesBuildsThenSlides() throws {
        var model = Self.presentationModel(docID: "builds-doc")
        model.presentations = [
            Presentation(
                id: "deck", name: "Talk",
                slides: [
                    Slide(
                        id: "s1", title: "One", focus: ["root"], dimOthers: true,
                        build: ["a", "b"]),
                    Slide(id: "s2", title: "Two", focus: ["root", "c"], dimOthers: true),
                ])
        ]
        let document = try openShownDocument(model)
        defer { document.close() }
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let coordinator = try coordinator(of: controller)
        coordinator.availableScreens = fakeSingleScreen

        controller.presentAction(nil)
        #expect(coordinator.slides.count == 2)
        #expect(coordinator.session.slideIndex == 0)
        #expect(coordinator.session.buildCursor == -1)

        // Authored deck wins over the auto one, builds included.
        coordinator.handleEvent(.keyDown(.space))
        #expect(coordinator.session.buildCursor == 0)
        coordinator.handleEvent(.keyDown(.rightArrow))
        #expect(coordinator.session.buildCursor == 1)

        // The next press crosses into slide 2, fresh.
        coordinator.handleEvent(.keyDown(.space))
        #expect(coordinator.session.slideIndex == 1)
        #expect(coordinator.session.buildCursor == -1)

        // Back: ← lands on slide 1 COMPLETED (its last build applied).
        coordinator.handleEvent(.keyDown(.leftArrow))
        #expect(coordinator.session.slideIndex == 0)
        #expect(coordinator.session.buildCursor == 1)
        coordinator.handleEvent(.keyDown(.escape))
    }

    // MARK: F-PRE-2 — authored changes are single undo steps

    @Test func addingAndReorderingSlidesAreOneUndoStepEach() throws {
        let document = try openShownDocument(Self.presentationModel(docID: "authoring-doc"))
        defer { document.close() }
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let store = try #require((controller.document as? MapDocument)?.store)
        let undoManager = try #require(document.undoManager)
        // One long run-loop pass in a test would merge the store's undo
        // groups by event; the app closes one event group per user
        // action (the same pattern as the golden-scenario tests).
        undoManager.groupsByEvent = false

        // The sidebar installs on its first toggle.
        controller.toggleSlidesSidebarAction(nil)
        controller.toggleSlidesSidebarAction(nil)

        // Add Slide (captures camera, fold state, focus, build steps).
        controller.canvas.setSelection(["a"])
        controller.addSlideForSidebar()
        #expect(store.model.presentations?.first?.slides.count == 1)
        #expect(store.model.presentations?.first?.slides.first?.focus == ["a"])
        // One undo step: undo removes the whole first slide.
        #expect(undoManager.canUndo)
        try #require(document.undoManager).undo()
        #expect(store.model.presentations?.first?.slides.isEmpty ?? true)

        // Two more adds, then a reorder: three more single steps.
        controller.addSlideForSidebar()
        controller.addSlideForSidebar()
        let deck = try #require(store.model.presentations?.first)
        let firstAdded = deck.slides[0].id
        controller.moveSlideFromSidebar(0, 2)
        let moved = try #require(store.model.presentations?.first)
        #expect(moved.slides.map(\.id) == [deck.slides[1].id, firstAdded])

        // Undo: the reorder goes back first (one step)…
        try #require(document.undoManager).undo()
        #expect(store.model.presentations?.first?.slides.map(\.id) == deck.slides.map(\.id))
        // …then the two adds, one at a time.
        try #require(document.undoManager).undo()
        #expect(store.model.presentations?.first?.slides.count == 1)
        try #require(document.undoManager).undo()
        #expect(store.model.presentations?.first?.slides.isEmpty ?? true)
    }

    // MARK: F-PRE-2/3 — reveal-children builds and the recorder

    @Test func revealChildrenOneByOneFillsTheBuildOrder() throws {
        let document = try openShownDocument(Self.presentationModel(docID: "build-order-doc"))
        defer { document.close() }
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let store = try #require((controller.document as? MapDocument)?.store)
        // The sidebar hosts the recording state; install it first.
        controller.toggleSlidesSidebarAction(nil)

        controller.canvas.setSelection(["root"])
        controller.addSlideForSidebar()
        controller.selectSidebarSlide(0)
        controller.revealChildrenOneByOne(0)
        #expect(store.model.presentations?.first?.slides.first?.build == ["a", "b", "c"])

        // The recorder: clicks append in sequence, Done commits ONE
        // command.
        controller.startBuildRecording()
        controller.slidesRecordSelectionChange(["b"])
        controller.slidesRecordSelectionChange(["root"])
        controller.stopSlidesRecording(commit: true)
        #expect(store.model.presentations?.first?.slides.first?.build == ["b", "root"])

        // Cancel drops the draft without a command.
        controller.startBuildRecording()
        controller.slidesRecordSelectionChange(["a"])
        controller.stopSlidesRecording(commit: false)
        #expect(store.model.presentations?.first?.slides.first?.build == ["b", "root"])
    }

    // MARK: F-PRE-6 — live edit pauses at the current camera

    @Test func liveEditPausesAndResumesFromWhereItLeft() throws {
        var model = Self.presentationModel(docID: "liveedit-doc")
        model.presentations = [
            Presentation(
                id: "deck", name: "Talk",
                slides: [
                    Slide(id: "s1", title: "One", focus: ["root"], dimOthers: true, build: ["a"])
                ])
        ]
        let document = try openShownDocument(model)
        defer { document.close() }
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let coordinator = try coordinator(of: controller)
        coordinator.availableScreens = fakeSingleScreen

        controller.presentAction(nil)
        let presentingCamera = coordinator.presentationView?.canvas.camera
        coordinator.handleEvent(.keyDown(.space))  // one build in

        // E: leave the audience surface, edit at the current camera.
        coordinator.handleEvent(.keyDown(.liveEdit))
        #expect(!coordinator.isPresenting)
        #expect(coordinator.isLiveEditPaused)
        #expect(controller.canvas.camera == presentingCamera)

        // ⌘⏎ (the resume action) rebuilds the surface with the deck
        // and cursor preserved.
        controller.resumePresentationAction(nil)
        #expect(coordinator.isPresenting)
        #expect(coordinator.session.slideIndex == 0)
        #expect(coordinator.session.buildCursor == 0)
        coordinator.handleEvent(.keyDown(.escape))
    }

    // MARK: M6 exit list — slides PDF

    @Test func slidesPDFHasTheExpectedPageCount() throws {
        let document = try openShownDocument(Self.presentationModel(docID: "pdf-doc"))
        defer { document.close() }
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let coordinator = try coordinator(of: controller)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slides-\(UUID().uuidString).pdf")
        let deckCount = PresentationCoordinator.resolveDeck(
            model: (document as? MapDocument)!.store.model, variant: controller.currentVariant()
        ).count
        let pages = try coordinator.exportSlidesPDF(
            to: url, pagePerBuildStep: false, includeNotes: true)
        defer { try? FileManager.default.removeItem(at: url) }

        // One page per slide plus one notes page per slide.
        #expect(pages == deckCount * 2)
        let pdf = PDFDocument(url: url)
        #expect(pdf?.pageCount == pages)
    }

    // MARK: F-PRE-5 — the presenter view on a second (fake) display

    @Test func presenterViewOpensOnTheSecondDisplay() throws {
        let document = try openShownDocument(Self.presentationModel(docID: "twoscreen-doc"))
        defer { document.close() }
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let windowOrigin = controller.window?.frame.origin ?? .zero
        let coordinator = try coordinator(of: controller)
        coordinator.availableScreens = fakeTwoScreens(windowOrigin: windowOrigin)

        controller.presentAction(nil)
        // The audience window sits on the projector.
        #expect(coordinator.presentationView?.window?.frame == CGRect(x: 2000, y: 0, width: 1920, height: 1080))
        // The presenter view opened on the display holding the
        // document, with the live state pushed into it.
        let presenter = coordinator.presenterWindowControllerForTests
        #expect(presenter != nil)
        let dashboard = try #require(presenter?.model)
        #expect(dashboard.slideCount == coordinator.slides.count)
        #expect(dashboard.notes.isEmpty)  // the opening overview has no notes
        #expect(!dashboard.screenBlanked)

        // Advancing pushes the build/slide state through.
        coordinator.handleEvent(.keyDown(.blackKey))
        #expect(dashboard.screenBlanked)
        coordinator.handleEvent(.keyDown(.blackKey))
        coordinator.handleEvent(.keyDown(.space))  // onto the first branch slide
        #expect(dashboard.slideIndex == 1)
        #expect(dashboard.slideCount == coordinator.slides.count)

        coordinator.handleEvent(.keyDown(.escape))
        #expect(coordinator.presenterWindowControllerForTests == nil)
    }

    // MARK: golden scenario 4 (SPEC §3 item 4), one display

    @Test func goldenScenarioFourPresentsAutoSlidesAndAdvances() throws {
        // "Present → auto-generated slides → advance with arrow keys and
        // a clicker → presenter notes appear on the second display."
        // On one display the audience run is driven end to end; the
        // second-display half is the fake-screen test above.
        var model = Self.presentationModel(docID: "golden4-doc")
        for (id, _) in model.nodes where id != "root" {
            model.nodes[id]?.note = "notes \(id)"
        }
        let document = try openShownDocument(model)
        defer { document.close() }
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let coordinator = try coordinator(of: controller)
        coordinator.availableScreens = fakeSingleScreen
        let wasEdited = document.isDocumentEdited

        controller.presentAction(nil)
        // Auto deck: overview, one slide per level-1 branch in
        // clockwise order, closing overview.
        #expect(coordinator.slides.first?.kind == .overview)
        #expect(coordinator.slides.count >= 5)
        let branchSlide = coordinator.slides[1]
        #expect(branchSlide.notes.hasPrefix("notes "))

        // A clicker: → advances; ← backs up.
        var clicks = 0
        while coordinator.session.slideIndex < coordinator.slides.count - 1 {
            coordinator.handleEvent(.keyDown(.rightArrow))
            clicks += 1
            if clicks > 100 {
                Issue.record("deck never advanced")
                break
            }
        }
        #expect(coordinator.session.slideIndex == coordinator.slides.count - 1)
        coordinator.handleEvent(.keyDown(.leftArrow))
        #expect(coordinator.session.slideIndex < coordinator.slides.count - 1)

        // Esc: out, and the document was never dirtied.
        coordinator.handleEvent(.keyDown(.escape))
        #expect(!coordinator.isPresenting)
        #expect(document.isDocumentEdited == wasEdited)
    }
}
