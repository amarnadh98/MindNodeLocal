import AppKit
import CanvasKit
import MapCore
import SwiftUI

/// One immutable view of the slide-authoring state the sidebar
/// renders; rebuilt by the host after every store change.
struct SlidesSnapshot: Equatable {
    var decks: [Presentation] = []
    var selectedDeck: Int = 0
    var selectedSlide: Int?
    var recordingBuild: [String]?
    var recordingActive: Bool { recordingBuild != nil }

    static let empty = SlidesSnapshot()
}

/// Every authored action the sidebar can perform; the host implements
/// them as single grouped commands (F-PRE-2: one undo step each).
/// The closures are `@MainActor` so the value stays `Sendable` through
/// SwiftUI's bindings under strict concurrency.
struct SlidesUIActions: Sendable {
    var addSlide: @MainActor () -> Void = {}
    var deleteSlide: @MainActor (Int) -> Void = { _ in }
    var duplicateSlide: @MainActor (Int) -> Void = { _ in }
    var renameSlide: @MainActor (Int, String) -> Void = { _, _ in }
    var setNotes: @MainActor (Int, String) -> Void = { _, _ in }
    var moveSlide: @MainActor (Int, Int) -> Void = { _, _ in }
    var revealChildrenOneByOne: @MainActor (Int) -> Void = { _ in }
    var clearBuild: @MainActor (Int) -> Void = { _ in }
    var startRecording: @MainActor () -> Void = {}
    var stopRecording: @MainActor (Bool) -> Void = { _ in }
    var newDeck: @MainActor () -> Void = {}
    var renameDeck: @MainActor (String) -> Void = { _ in }
    var deleteDeck: @MainActor () -> Void = {}
    var selectDeck: @MainActor (Int) -> Void = { _ in }
    var selectSlide: @MainActor (Int?) -> Void = { _ in }
    var presentNow: @MainActor () -> Void = {}
}

/// The Slides sidebar panel (F-PRE-2/3): a left-edge visual-effect
/// panel inside the canvas, hidden by default — the same hosting
/// pattern the minimap uses, so the window's content view is never
/// restructured.
@MainActor
final class SlidesSidebarController {
    static let width: CGFloat = 280

    let panel = NSVisualEffectView()
    private var hosting: NSHostingView<SlidesSidebarView>!
    private(set) var isVisible = false
    private(set) var selectedDeck = 0
    private(set) var selectedSlide: Int?
    /// The in-progress custom build recording (F-PRE-3): node ids in
    /// click order, committed as ONE command.
    private(set) var buildRecording: [String]?

    init() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.material = .sidebar
        panel.blendingMode = .behindWindow
        panel.wantsLayer = true
        hosting = NSHostingView(rootView: SlidesSidebarView(snapshot: .empty, actions: SlidesUIActions()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(hosting)
    }

    /// Pins the panel to the canvas's left edge (collapsed by
    /// default).
    func install(in canvas: NSView) {
        canvas.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            panel.topAnchor.constraint(equalTo: canvas.topAnchor),
            panel.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: Self.width),
            hosting.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: panel.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        panel.isHidden = true
    }

    func toggle() {
        isVisible.toggle()
        panel.isHidden = !isVisible
    }

    /// True when a build-order recording is running (the host forwards
    /// canvas clicks into it).
    var isRecordingBuild: Bool { buildRecording != nil }

    /// A canvas selection during recording (F-PRE-3: "custom build
    /// order chosen by clicking nodes in sequence"). The host refreshes
    /// the snapshot afterwards.
    func recordSelection(_ ids: Set<String>) {
        buildRecording?.append(contentsOf: ids.sorted())
    }

    func startRecording() {
        guard buildRecording == nil else { return }
        buildRecording = []
    }

    /// `commit` finishes the recording into the selected slide's
    /// build list; otherwise the draft is dropped. The host refreshes
    /// and performs the command.
    func stopRecording(commit: Bool) -> [String]? {
        let draft = buildRecording
        buildRecording = nil
        return commit ? draft : nil
    }

    func select(deck: Int) {
        selectedDeck = deck
        selectedSlide = nil
    }

    func selectSlide(_ index: Int?) {
        selectedSlide = index
    }

    /// Rebuilds the snapshot from the model and re-renders.
    func refresh(model: MapModel?, actions: SlidesUIActions) {
        var snapshot = SlidesSnapshot()
        if let model {
            snapshot.decks = model.presentations ?? []
            if snapshot.decks.isEmpty {
                selectedDeck = 0
                selectedSlide = nil
            }
            selectedDeck = min(selectedDeck, max(snapshot.decks.count - 1, 0))
        }
        snapshot.selectedDeck = selectedDeck
        snapshot.selectedSlide = selectedSlide
        snapshot.recordingBuild = buildRecording
        hosting.rootView = SlidesSidebarView(snapshot: snapshot, actions: actions)
    }
}

/// The sidebar's SwiftUI face. Purely presentational: it renders a
/// `SlidesSnapshot` and calls `SlidesUIActions`; all state lives in
/// the host controller so a store change simply rebuilds the
/// snapshot.
struct SlidesSidebarView: View {
    let snapshot: SlidesSnapshot
    let actions: SlidesUIActions

    @State private var notesDraft: String = ""
    @State private var deckNameDraft: String = ""

    private var deck: Presentation? {
        snapshot.decks.indices.contains(snapshot.selectedDeck)
            ? snapshot.decks[snapshot.selectedDeck] : nil
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            if snapshot.decks.indices.contains(snapshot.selectedDeck) {
                // The name commits once on ⏎/focus-loss (one command),
                // not per keystroke.
                TextField(
                    "Deck name",
                    text: Binding(
                        get: { snapshot.decks[snapshot.selectedDeck].name },
                        set: { deckNameDraft = $0 }
                    ),
                    onCommit: { actions.renameDeck(deckNameDraft) }
                )
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Add Slide", action: actions.addSlide)
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Present", action: actions.presentNow)
                    .buttonStyle(.bordered)
            }
            Divider()
            if let deck {
                slideList(deck)
                slideDetail(deck)
            } else {
                emptyState
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            if snapshot.decks.isEmpty {
                Text("No presentations")
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    "Deck",
                    selection: Binding(
                        get: { snapshot.selectedDeck },
                        set: actions.selectDeck
                    )
                ) {
                    ForEach(snapshot.decks.indices, id: \.self) { index in
                        Text(snapshot.decks[index].name).tag(index)
                    }
                }
                .labelsHidden()
            }
            Spacer()
            Button {
                if snapshot.decks.isEmpty {
                    actions.newDeck()
                } else {
                    actions.deleteDeck()
                }
            } label: {
                Image(systemName: snapshot.decks.isEmpty ? "plus" : "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    /// F-ONB-3's Slides empty state: designed — the symbol, the one
    /// sentence of guidance, and the door that fixes it.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No presentations yet")
                .font(.headline)
            Text("Capture the map as slides, then present it with one key per step.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Presentation", action: actions.newDeck)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No presentations yet. New Presentation button.")
    }

    private func slideList(_ deck: Presentation) -> some View {
        List(
            selection: Binding(
                get: { snapshot.selectedSlide },
                set: { actions.selectSlide($0 ?? nil) }
            )
        ) {
            ForEach(deck.slides.indices, id: \.self) { index in
                HStack {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(deck.slides[index].title ?? "Slide \(index + 1)")
                        .lineLimit(1)
                    Spacer()
                    if !(deck.slides[index].build ?? []).isEmpty {
                        Image(systemName: "square.stack")
                            .foregroundStyle(.secondary)
                    }
                    if !(deck.slides[index].notes ?? "").isEmpty {
                        Image(systemName: "text.note")
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(Optional(index))
            }
            .onMove { from, to in
                let fromIndex = from.first ?? 0
                actions.moveSlide(fromIndex, adjustedDestination(fromIndex, to))
            }
        }
        .listStyle(.plain)
        .frame(minHeight: 120)
        .overlay {
            if deck.slides.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "slide")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No slides yet — Add Slide captures the map as it looks now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// List.onMove reports the destination slot *after* removal in
    /// practice; keep single moves stable either way.
    private func adjustedDestination(_ from: Int, _ to: Int) -> Int {
        to > from ? to - 1 : to
    }

    @ViewBuilder
    private func slideDetail(_ deck: Presentation) -> some View {
        if let index = snapshot.selectedSlide, deck.slides.indices.contains(index) {
            let slide = deck.slides[index]
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        "Slide title",
                        text: Binding(
                            get: { slide.title ?? "" },
                            set: { actions.renameSlide(index, $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("Speaker notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(
                        text: Binding(
                            get: { slide.notes ?? "" },
                            set: { notesDraft = $0 }
                        )
                    )
                    .font(.callout)
                    .frame(minHeight: 48)
                    .border(.quaternary)
                    HStack {
                        Button("Save Notes") { actions.setNotes(index, notesDraft) }
                            .disabled((slide.notes ?? "") == notesDraft)
                        Spacer()
                        Button("Duplicate") { actions.duplicateSlide(index) }
                        Button("Delete") { actions.deleteSlide(index) }
                    }
                    Divider()
                    buildSection(index: index, slide: slide)
                }
            }
            .onAppear { notesDraft = slide.notes ?? "" }
        }
    }

    private func buildSection(index: Int, slide: Slide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Reveal children one by one") {
                    actions.revealChildrenOneByOne(index)
                }
                .disabled((slide.focus ?? []).isEmpty)
                Button("Clear") { actions.clearBuild(index) }
                    .disabled((slide.build ?? []).isEmpty)
            }
            if snapshot.recordingActive {
                HStack {
                    Text("Recording: \(snapshot.recordingBuild?.count ?? 0) steps")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Done") { actions.stopRecording(true) }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { actions.stopRecording(false) }
                }
            } else {
                Button("Record Build Order…") { actions.startRecording() }
            }
            if let build = slide.build, !build.isEmpty {
                Text("Builds: \(build.count) step\(build.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
