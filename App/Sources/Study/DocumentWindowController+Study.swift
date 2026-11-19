import AppKit
import CanvasKit
import MapCore
import MapRender
import MapStudy

/// The study actions on the document window (F-STD-1/4/6/7): deck and
/// card marking (undoable `setStudy` commands), Make Cloze, session
/// start, the mastery overlay and the dashboard. Kept in one
/// App/Sources/Study file so the window controller itself stays thin.
@MainActor
extension DocumentWindowController {
    private var studyDocument: MapDocument? { document as? MapDocument }

    /// The mastery overlay's persisted preference (View ▸ Mastery
    /// Overlay, ⌥⌘H — per user, like the minimap's; F-STD-6).
    static let masteryDefaultsKey = "ShowsMasteryOverlay"

    // MARK: F-STD-1 — decks and card marking

    /// ⌥⌘S (Study ▸ Make Study Deck): toggles the deck flag on the
    /// selected branch — ONE undoable `setStudy` command whose inverse
    /// snapshots the previous section.
    @objc func makeStudyDeckAction(_ sender: Any?) {
        guard let mapDocument = studyDocument, !canvas.isEditing, !canvas.selection.isEmpty else { return }
        for id in canvas.selection.sorted() {
            guard let node = mapDocument.store.model.nodes[id] else { continue }
            let next = StudyStates.togglingDeck(in: node.study)
            let isDeck = next.deck ?? false
            try? mapDocument.store.perform(
                .setStudy(name: isDeck ? "Make Study Deck" : "Remove Study Deck", id: id, study: next))
        }
    }

    /// Study ▸ Card / Not a Card / Auto (F-STD-1): the menu item's tag
    /// picks the policy (1 on, 2 off, 3 auto).
    @objc func setCardPolicyAction(_ sender: Any?) {
        guard let mapDocument = studyDocument, !canvas.isEditing, !canvas.selection.isEmpty else { return }
        let policy: CardPolicy
        switch (sender as? NSMenuItem)?.tag {
        case 1: policy = .on
        case 2: policy = .off
        default: policy = .auto
        }
        for id in canvas.selection.sorted() {
            guard let node = mapDocument.store.model.nodes[id] else { continue }
            let next = StudyStates.settingPolicy(policy, in: node.study)
            try? mapDocument.store.perform(.setStudy(name: "Mark Card", id: id, study: next))
        }
    }

    /// ⇧⌘C (Study ▸ Make Cloze, F-STD-2): inside the title editor,
    /// wraps the selected text in `{{cN::…}}` with the next free N
    /// across the node's title AND note, commits it as one undoable
    /// (named) edit and keeps the editing session open. Outside the
    /// editor it is a no-op — the menu item disables.
    @objc func makeClozeAction(_ sender: Any?) {
        guard let mapDocument = studyDocument, canvas.isEditing,
            let id = canvas.nodeTextEditor.editingNodeID,
            let title = canvas.nodeTextEditor.currentTitle(),
            let selection = canvas.nodeTextEditor.selectedTitleRange()
        else { return }
        let note = mapDocument.store.model.nodes[id]?.note
        guard
            let wrapped = ClozeMaker.wrapped(
                title: title, note: note, location: selection.location, length: selection.length)
        else { return }
        let command = MapCommand.group(
            name: "Make Cloze",
            commands: [.editText(id: id, title: wrapped)])
        do {
            try mapDocument.store.perform(command)
        } catch {
            return
        }
        // Keep the session alive: the overlay now shows the wrapped
        // title with the freshly wrapped text still selected.
        let prefixLength = "{{c\(ClozeMaker.nextFreeIndex(title: title.text, note: note))::".utf16.count
        let shifted = NSRange(location: selection.location + prefixLength, length: selection.length)
        canvas.nodeTextEditor.applyTitle(wrapped, selecting: shifted)
    }

    // MARK: F-STD-4 — sessions

    /// Study ▸ Study Branch: a session over the selected branch's
    /// subtree (an implicit deck, ADR-0015's scope rule).
    @objc func studyBranchAction(_ sender: Any?) {
        guard let mapDocument = studyDocument, !canvas.isEditing else { return }
        guard let root = canvas.selection.sorted().first ?? mapDocument.model.roots.first else { return }
        startSession(
            cards: CardExtractor.extract(from: mapDocument.model, subtreeRoot: root),
            scopeTitle: mapDocument.model.nodes[root]?.title.text ?? "Branch")
    }

    /// Study ▸ Study Document: every eligible card in the map.
    @objc func studyDocumentAction(_ sender: Any?) {
        guard let mapDocument = studyDocument else { return }
        startSession(
            cards: CardExtractor.extractAll(from: mapDocument.model),
            scopeTitle: mapDocument.displayName ?? "Document")
    }

    /// Study ▸ Study Due (⌃⌘⏎): only learning and due-review cards, the
    /// document's deck-gated card set.
    @objc func studyDueAction(_ sender: Any?) {
        guard let mapDocument = studyDocument else { return }
        startSession(
            cards: CardExtractor.extract(from: mapDocument.model),
            scopeTitle: mapDocument.displayName ?? "Due",
            dueOnly: true)
    }

    /// Study ▸ Study Weakest Branch (F-STD-6): the subtree with the
    /// lowest mean retrievability.
    @objc func studyWeakestBranchAction(_ sender: Any?) {
        guard let mapDocument = studyDocument else { return }
        let report = MasteryReport.compute(map: mapDocument.model, now: Date())
        guard let weakest = report.weakestBranchID,
            let title = mapDocument.model.nodes[weakest]?.title.text
        else { return }
        startSession(
            cards: CardExtractor.extract(from: mapDocument.model, subtreeRoot: weakest),
            scopeTitle: title)
    }

    /// Builds the daily-limited queue (F-STD-4: new 20 / reviews 200,
    /// UserDefaults-overridable) and opens the session window.
    private func startSession(cards: [Card], scopeTitle: String, dueOnly: Bool = false) {
        guard let mapDocument = studyDocument else { return }
        let now = Date()
        let states = StudyStates.states(for: cards, in: mapDocument.model)
        let settings = StudySettings(
            newPerDay: StudyPreferences.newPerDay(model: mapDocument.model),
            retention: mapDocument.model.studySettings?.retention ?? 0.9)
        var queue = StudyQueue.build(
            cards: cards, states: states, reviews: mapDocument.reviewLog, now: now,
            studySettings: settings, reviewsPerDay: StudyPreferences.reviewsPerDay())
        if dueOnly {
            queue = queue.filter { $0.reason != .new }
        }
        let scene = canvas.scene
        let controller = StudySessionController(
            document: mapDocument, scopeTitle: scopeTitle, entries: queue,
            variant: currentVariant(), scene: scene)
        activeStudySession = controller
        controller.showWindow(nil)
    }

    // MARK: F-STD-6 — mastery overlay

    /// ⌥⌘H (View ▸ Mastery Overlay): flips the persisted preference and
    /// re-applies. Pure view state — no model change, no dirtying.
    @objc func toggleMasteryOverlayAction(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let updated = !((defaults.object(forKey: Self.masteryDefaultsKey) as? Bool) ?? false)
        defaults.set(updated, forKey: Self.masteryDefaultsKey)
        applyMasteryOverlay()
    }

    var masteryOverlayEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.masteryDefaultsKey) as? Bool) ?? false
    }

    /// Recomputes the mastery report and pushes its marks to the canvas
    /// (a layer tint/outline per card node, an aggregate ring per
    /// ancestor). Called after every scene rebuild while enabled, so
    /// grading recolors the map live.
    func applyMasteryOverlay() {
        guard masteryOverlayEnabled, let mapDocument = studyDocument else {
            canvas.setMasteryMarks(nil)
            return
        }
        let report = MasteryReport.compute(map: mapDocument.model, now: Date())
        canvas.setMasteryMarks(Self.masteryMarks(from: report))
    }

    /// The report → overlay marks conversion: bucket colors at F-STD-6's
    /// thresholds (dynamic via the system colors, re-resolved per
    /// appearance), new cards as a gray outline, ancestors as rings.
    static func masteryMarks(from report: MasteryReport) -> [String: MasteryMark] {
        var marks: [String: MasteryMark] = [:]
        for (nodeID, mastery) in report.nodes {
            marks[nodeID] = Self.mark(for: mastery.bucket)
        }
        for (nodeID, mean) in report.aggregates {
            guard marks[nodeID] == nil else { continue }
            marks[nodeID] = .ring(
                color: MasteryPalette.color(for: MasteryBucket.bucket(retrievability: mean)),
                progress: mean)
        }
        return marks
    }

    private static func mark(for bucket: MasteryBucket) -> MasteryMark {
        switch bucket {
        case .fresh: .outline(MasteryPalette.freshOutline)
        default: .tint(MasteryPalette.color(for: bucket))
        }
    }

    // MARK: F-STD-7 — dashboard

    /// Study ▸ Show Dashboard.
    @objc func showStudyDashboardAction(_ sender: Any?) {
        guard let mapDocument = studyDocument else { return }
        StudyDashboardController.shared.show(for: mapDocument, variant: currentVariant())
    }

    // MARK: menu validation (reached from validateMenuItem in the
    // toolbar file's switch)

    func validateStudyMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(makeStudyDeckAction(_:)):
            guard let mapDocument = studyDocument, !canvas.isEditing, !canvas.selection.isEmpty else {
                return false
            }
            let deckOn = canvas.selection.allSatisfy { mapDocument.model.nodes[$0]?.study?.deck == true }
            menuItem.state = deckOn ? .on : .off
            return true
        case #selector(setCardPolicyAction(_:)):
            guard let mapDocument = studyDocument, !canvas.isEditing, !canvas.selection.isEmpty else {
                return false
            }
            let policies = Set(canvas.selection.compactMap { mapDocument.model.nodes[$0]?.study?.card })
            let policy: CardPolicy? =
                policies.count == 1 ? policies.first : nil
            switch menuItem.tag {
            case 1: menuItem.state = policy == .on ? .on : .off
            case 2: menuItem.state = policy == .off ? .on : .off
            default: menuItem.state = (policy == nil || policy == .auto) ? .on : .off
            }
            return true
        case #selector(makeClozeAction(_:)):
            // Only meaningful with selected title text inside the editor.
            return canvas.isEditing && canvas.nodeTextEditor.selectedTitleRange() != nil
        case #selector(studyBranchAction(_:)):
            // Falls back to the first root when nothing is selected.
            return !canvas.isEditing
        case #selector(studyWeakestBranchAction(_:)):
            let mapDocument = studyDocument
            return mapDocument != nil
                && MasteryReport.compute(map: mapDocument!.model, now: Date()).weakestBranchID != nil
        case #selector(toggleMasteryOverlayAction(_:)):
            menuItem.state = masteryOverlayEnabled ? .on : .off
            return true
        case #selector(studyDocumentAction(_:)), #selector(studyDueAction(_:)),
            #selector(showStudyDashboardAction(_:)):
            return studyDocument != nil
        default:
            return true
        }
    }
}

/// The F-STD-6 palette: bucket → color, resolved from the system
/// semantic colors so light and dark both read (the overlay
/// re-resolves on appearance changes).
@MainActor
enum MasteryPalette {
    static let freshOutline = NSColor.systemGray.cgColor

    static func color(for bucket: MasteryBucket) -> CGColor {
        switch bucket {
        case .strong: NSColor.systemGreen.withAlphaComponent(0.28).cgColor
        case .good: NSColor.systemYellow.withAlphaComponent(0.30).cgColor
        case .fading: NSColor.systemOrange.withAlphaComponent(0.30).cgColor
        case .forgotten: NSColor.systemRed.withAlphaComponent(0.28).cgColor
        case .fresh: NSColor.systemGray.cgColor
        }
    }
}
