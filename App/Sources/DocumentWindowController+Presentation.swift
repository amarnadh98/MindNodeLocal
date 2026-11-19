import AppKit
import CanvasKit
import MapCore

/// Presentation authoring + flow (M6, F-PRE-1…7): the ⌥⌘⏎ present
/// action, the Slides sidebar wiring, and every authored change —
/// each ONE grouped `setPresentations` command through the document's
/// store, so each is exactly one undo step with a meaningful undo
/// name. Presenting itself performs no commands: the document is never
/// dirtied by a run.
extension DocumentWindowController {
    private var slidesStore: MapStore? {
        (document as? MapDocument)?.store
    }

    // MARK: flow actions

    /// ⌥⌘⏎ / toolbar ▶︎ (F-PRE-1): present. If a run is paused into
    /// live edit, ⌥⌘⏎ also resumes — one key, both directions of the
    /// same feature.
    @objc func presentAction(_ sender: Any?) {
        if presentationCoordinatorBox?.isLiveEditPaused == true {
            presentationCoordinatorBox?.resumeFromLiveEdit()
            return
        }
        let store = (document as? MapDocument)?.store
        guard let store else { return }
        let coordinator =
            presentationCoordinatorBox
            ?? PresentationCoordinator(windowController: self, store: store)
        presentationCoordinatorBox = coordinator
        coordinator.startPresenting()
    }

    /// ⌥⌘⏎'s live-edit counterpart (F-PRE-6): ⌘⏎ resumes presenting.
    /// Its menu item validates only while a run is paused, so ⌘⏎
    /// keeps its editing meaning (F-EDT-2) at every other time.
    @objc func resumePresentationAction(_ sender: Any?) {
        guard presentationCoordinatorBox?.isLiveEditPaused == true else { return }
        presentationCoordinatorBox?.resumeFromLiveEdit()
    }

    /// ⌃⌘S / the toolbar's Slides item (F-PRE-2): show or hide the
    /// Slides sidebar.
    @objc func toggleSlidesSidebarAction(_ sender: Any?) {
        guard slidesSidebarBox != nil || slidesStore != nil else { return }
        if slidesSidebarBox == nil {
            let sidebar = SlidesSidebarController()
            sidebar.install(in: canvas)
            slidesSidebarBox = sidebar
            refreshSlidesSidebar()
        }
        slidesSidebarBox?.toggle()
    }

    // MARK: authored changes — one command, one undo step each

    private func performSlidesEdit(_ name: String, _ mutate: (inout [Presentation]) -> Void) {
        guard let store = slidesStore else { return }
        var list = store.model.presentations ?? []
        mutate(&list)
        let command = MapCommand.group(
            name: name, commands: [.setPresentations(list.isEmpty ? nil : list)])
        try? store.perform(command)
        refreshSlidesSidebar()
    }

    /// The sidebar's index of the deck being edited (mirrors the
    /// sidebar's own selection).
    var selectedSlidesDeck: Int {
        get { slidesSidebarBox?.selectedDeck ?? 0 }
        set { slidesSidebarBox?.select(deck: newValue) }
    }

    func addSlideForSidebar() {
        // F-PRE-2: Add Slide captures the current camera rect, fold
        // state, focus set (the selection) and build steps (empty).
        let camera = canvas.camera
        let model = slidesStore?.model
        let folded = (model?.nodes ?? [:]).compactMap { id, node in node.folded ? id : nil }
        let selection = canvas.selection.sorted()
        let slide = Slide(
            id: UUID().uuidString,
            title: nil,
            camera: SlideCamera(x: camera.origin.x, y: camera.origin.y, scale: camera.scale),
            folded: folded,
            focus: selection,
            dimOthers: true,
            build: [],
            notes: "")
        performSlidesEdit("Add Slide") { list in
            if list.isEmpty {
                list.append(
                    Presentation(
                        id: UUID().uuidString, name: "Presentation", slides: [slide]))
            } else if list.indices.contains(selectedSlidesDeck) {
                list[selectedSlidesDeck].slides.append(slide)
            }
        }
    }

    func deleteSlideFromSidebar(_ index: Int) {
        performSlidesEdit("Delete Slide") { list in
            guard list.indices.contains(selectedSlidesDeck),
                list[selectedSlidesDeck].slides.indices.contains(index)
            else { return }
            list[selectedSlidesDeck].slides.remove(at: index)
        }
        slidesSidebarBox?.selectSlide(nil)
    }

    func duplicateSlideFromSidebar(_ index: Int) {
        performSlidesEdit("Duplicate Slide") { list in
            guard list.indices.contains(selectedSlidesDeck),
                list[selectedSlidesDeck].slides.indices.contains(index)
            else { return }
            var copy = list[selectedSlidesDeck].slides[index]
            copy.id = UUID().uuidString
            list[selectedSlidesDeck].slides.insert(copy, at: index + 1)
        }
    }

    func renameSlideFromSidebar(_ index: Int, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        performSlidesEdit("Rename Slide") { list in
            guard list.indices.contains(selectedSlidesDeck),
                list[selectedSlidesDeck].slides.indices.contains(index)
            else { return }
            list[selectedSlidesDeck].slides[index].title = trimmed.isEmpty ? nil : trimmed
        }
    }

    func setSlideNotesFromSidebar(_ index: Int, _ notes: String) {
        performSlidesEdit("Set Slide Notes") { list in
            guard list.indices.contains(selectedSlidesDeck),
                list[selectedSlidesDeck].slides.indices.contains(index)
            else { return }
            list[selectedSlidesDeck].slides[index].notes = notes
        }
    }

    /// Drag-reorder in the sidebar's list.
    func moveSlideFromSidebar(_ from: Int, _ to: Int) {
        performSlidesEdit("Reorder Slide") { list in
            guard list.indices.contains(selectedSlidesDeck),
                list[selectedSlidesDeck].slides.indices.contains(from)
            else { return }
            let slide = list[selectedSlidesDeck].slides.remove(at: from)
            let target = min(max(to, 0), list[selectedSlidesDeck].slides.count)
            list[selectedSlidesDeck].slides.insert(slide, at: target)
        }
        slidesSidebarBox?.selectSlide(nil)
    }

    /// F-PRE-3 "Reveal children one by one": the slide's primary focus
    /// node's children become the build order, in sibling order.
    func revealChildrenOneByOne(_ index: Int) {
        guard let model = slidesStore?.model else { return }
        performSlidesEdit("Set Build Order") { list in
            guard list.indices.contains(selectedSlidesDeck),
                list[selectedSlidesDeck].slides.indices.contains(index)
            else { return }
            let focus = list[selectedSlidesDeck].slides[index].focus ?? []
            guard let primary = focus.first, let children = model.nodes[primary]?.children,
                !children.isEmpty
            else { return }
            list[selectedSlidesDeck].slides[index].build = children
        }
    }

    func clearSlideBuild(_ index: Int) {
        performSlidesEdit("Clear Build Order") { list in
            guard list.indices.contains(selectedSlidesDeck),
                list[selectedSlidesDeck].slides.indices.contains(index)
            else { return }
            list[selectedSlidesDeck].slides[index].build = []
        }
    }

    /// F-PRE-3 custom build order: the recording committed as one
    /// command.
    func commitBuildRecording(_ ids: [String]) {
        guard let index = slidesSidebarBox?.selectedSlide else { return }
        performSlidesEdit("Set Build Order") { list in
            guard list.indices.contains(selectedSlidesDeck),
                list[selectedSlidesDeck].slides.indices.contains(index)
            else { return }
            list[selectedSlidesDeck].slides[index].build = ids
        }
    }

    func newPresentationDeck() {
        performSlidesEdit("New Presentation") { list in
            list.append(
                Presentation(
                    id: UUID().uuidString, name: "Presentation \(list.count + 1)", slides: []))
        }
        slidesSidebarBox?.select(deck: ((slidesStore?.model.presentations ?? []).count - 1))
    }

    func renamePresentationDeck(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSlidesEdit("Rename Presentation") { list in
            guard list.indices.contains(selectedSlidesDeck) else { return }
            list[selectedSlidesDeck].name = trimmed
        }
    }

    func deletePresentationDeck() {
        performSlidesEdit("Delete Presentation") { list in
            guard list.indices.contains(selectedSlidesDeck) else { return }
            list.remove(at: selectedSlidesDeck)
        }
        let remaining = (slidesStore?.model.presentations ?? []).count
        selectedSlidesDeck = min(selectedSlidesDeck, max(remaining - 1, 0))
    }

    func selectPresentationDeck(_ index: Int) {
        selectedSlidesDeck = index
        refreshSlidesSidebar()
    }

    func selectSidebarSlide(_ index: Int?) {
        slidesSidebarBox?.selectSlide(index)
        refreshSlidesSidebar()
    }

    // MARK: sidebar refresh

    /// Rebuilds the sidebar snapshot from the store (after every
    /// model change and sidebar action).
    func refreshSlidesSidebar() {
        guard let sidebar = slidesSidebarBox else { return }
        sidebar.refresh(model: slidesStore?.model, actions: sidebarActions)
    }

    /// A canvas selection while a build recording runs appends to the
    /// draft (F-PRE-3: click nodes in sequence).
    func slidesRecordSelectionChange(_ selection: Set<String>) {
        guard let sidebar = slidesSidebarBox, sidebar.isRecordingBuild, !selection.isEmpty else {
            return
        }
        sidebar.recordSelection(selection)
        refreshSlidesSidebar()
    }

    func stopSlidesRecording(commit: Bool) {
        guard let sidebar = slidesSidebarBox else { return }
        if let ids = sidebar.stopRecording(commit: commit) {
            commitBuildRecording(ids)
        } else {
            refreshSlidesSidebar()
        }
    }

    private var sidebarActions: SlidesUIActions {
        SlidesUIActions(
            addSlide: { [weak self] in self?.addSlideForSidebar() },
            deleteSlide: { [weak self] in self?.deleteSlideFromSidebar($0) },
            duplicateSlide: { [weak self] in self?.duplicateSlideFromSidebar($0) },
            renameSlide: { [weak self] in self?.renameSlideFromSidebar($0, $1) },
            setNotes: { [weak self] in self?.setSlideNotesFromSidebar($0, $1) },
            moveSlide: { [weak self] in self?.moveSlideFromSidebar($0, $1) },
            revealChildrenOneByOne: { [weak self] in self?.revealChildrenOneByOne($0) },
            clearBuild: { [weak self] in self?.clearSlideBuild($0) },
            startRecording: { [weak self] in self?.startBuildRecording() },
            stopRecording: { [weak self] in self?.stopSlidesRecording(commit: $0) },
            newDeck: { [weak self] in self?.newPresentationDeck() },
            renameDeck: { [weak self] in self?.renamePresentationDeck($0) },
            deleteDeck: { [weak self] in self?.deletePresentationDeck() },
            selectDeck: { [weak self] in self?.selectPresentationDeck($0) },
            selectSlide: { [weak self] in self?.selectSidebarSlide($0) },
            presentNow: { [weak self] in self?.presentAction(nil) }
        )
    }

    func startBuildRecording() {
        slidesSidebarBox?.startRecording()
        refreshSlidesSidebar()
    }
    // MARK: export (M6 exit list)

    /// File ▸ Export Slides as PDF…: save panel, then the shared
    /// renderer writes the deck (one page per slide, or per build
    /// step; optional notes pages).
    @objc func exportSlidesPDFAction(_ sender: Any?) {
        let store = (document as? MapDocument)?.store
        guard let store else { return }
        let coordinator =
            presentationCoordinatorBox
            ?? PresentationCoordinator(windowController: self, store: store)
        presentationCoordinatorBox = coordinator
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Slides"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            _ = try? coordinator.exportSlidesPDF(to: url, pagePerBuildStep: false, includeNotes: true)
        }
    }
}
