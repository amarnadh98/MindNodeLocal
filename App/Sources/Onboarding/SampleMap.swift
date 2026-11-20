import AppKit
import MapCore
import MapIO
import MapRender

/// F-ONB-1's sample map: the tutorial that teaches by doing. Every text
/// is original to Arbor; every branch names a real shortcut the app
/// already answers, so a new user learns the app by playing it. Built
/// from `MapCore` models in code (the template catalog's pattern) and
/// written fresh to Application Support on every open — the tour is
/// disposable, a user's real maps live wherever they saved them.
/// One chapter of the tour: the branch title, its "do this now" steps
/// and an optional branch note.
private struct TourChapter {
    let id: String
    let title: String
    let steps: [String]
    let note: String?
}

enum SampleMap {
    static let tourFileName = "Arbor Tour.arbor"

    static var tourURL: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Arbor/\(tourFileName)", directoryHint: .isDirectory)
    }

    /// The tour's content. Level-1 branches are the chapters; their
    /// children are the "do this now" steps. `@MainActor` because the
    /// default-theme lookup is main-actor confined (the catalog reads
    /// UserDefaults and its own directory listing).
    @MainActor
    static func buildModel() -> MapModel {
        var model = MapModel.emptyDocument()
        let date = Date()
        func node(_ id: String, parent: String? = nil, text: String, note: String? = nil) -> Node {
            var created = Node(
                id: id, parent: parent, title: NodeTitle(text: text), created: date, modified: date)
            created.note = note
            return created
        }

        let root = node(
            "tour-root",
            text: "Welcome to Arbor",
            note: "This map is the tour. Click a branch, follow the words, and press the keys it names.")
        model.nodes[root.id] = root
        model.roots = [root.id]

        let chapters: [TourChapter] = [
            TourChapter(
                id: "tour-build", title: "Build with the keyboard",
                steps: [
                    "Press ⇥ to add a child here",
                    "⏎ adds a sibling below; ⌥⏎ above",
                    "Start typing on a selected node — it replaces the text",
                    "Drag me onto another branch to re-parent me",
                    "⌫ deletes; ⌘Z brings me right back",
                    "⌥. folds this branch — click the count pill to reopen",
                ],
                note:
                    "Tip: while dragging, hold ⌥ to place a node freely, or press D to detach it as a new root."
            ),
            TourChapter(
                id: "tour-outline", title: "See it as an outline",
                steps: [
                    "⌘2 shows the full outline; ⌘3 puts it beside the map",
                    "Type in the outline — the map changes in the same step",
                    "⌘1 brings the map back",
                ],
                note: nil),
            TourChapter(
                id: "tour-focus", title: "Focus on one branch",
                steps: [
                    "Select me, then press ⇧⌘F to focus my branch",
                    "Move around inside the focus — it follows you",
                    "⎋ gives the whole map back",
                ],
                note: nil),
            TourChapter(
                id: "tour-present", title: "Present it",
                steps: [
                    "⌥⌘⏎ starts a presentation from this map",
                    "→ builds the map branch by branch; ← steps back",
                    "B and W blank the screen; hold L for a laser dot",
                ],
                note: nil),
            TourChapter(
                id: "tour-study", title: "Learn it",
                steps: [
                    "⌥⌘S marks a branch as a study deck",
                    "⌃⌘⏎ starts a review session on due cards",
                    "⌥⌘R hides this branch behind blurred cards — recall it",
                    "⌥⌘H tints the map by what you remember",
                ],
                note: nil),
            TourChapter(
                id: "tour-capture", title: "Capture from anywhere",
                steps: [
                    "⌃⌥Space opens Quick Entry over any app",
                    "Type an indented list, then Create Map",
                    "Or append it to a recent map without switching windows",
                ],
                note: nil),
            TourChapter(
                id: "tour-style", title: "Make it yours",
                steps: [
                    "⇧⌘E opens the theme editor",
                    "Every theme carries a light and a dark side — try both",
                    "View ▸ Appearance pins this map to one of them",
                ],
                note: nil),
            TourChapter(
                id: "tour-share", title: "Share it",
                steps: [
                    "⌥⌘E exports PDF, PNG, SVG and text formats",
                    "Maps are folders you own — save them anywhere",
                ],
                note: nil),
        ]

        for chapter in chapters {
            let chapterNode = node(chapter.id, parent: root.id, text: chapter.title, note: chapter.note)
            model.nodes[chapter.id] = chapterNode
            model.nodes[root.id]?.children.append(chapter.id)
            for (index, step) in chapter.steps.enumerated() {
                let stepID = "\(chapter.id)-\(index)"
                model.nodes[stepID] = node(stepID, parent: chapter.id, text: step)
                model.nodes[chapter.id]?.children.append(stepID)
            }
        }
        // The tour is a NEW map (F-STY-6): it opens in the user's
        // default theme rather than rendering as the engine's Paper
        // fallback — the first map a new user sees should be the
        // default look (ADR-0037). Paper stays implicit, like
        // `MapDocument.initialModel`.
        let themeID = ThemeCatalog.defaultThemeID
        if themeID != BuiltInThemes.defaultID {
            model.theme = ThemeSelection(id: themeID)
        }
        return model
    }

    /// Writes the tour package and opens it. Returns the written URL
    /// (nil when the write failed — a broken tour is never fatal; the
    /// welcome window stays and "New Map" still works).
    @MainActor
    @discardableResult
    static func openTour() -> URL? {
        let url = tourURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let model = buildModel()
            try ArborPackage.write(
                model, meta: PackageMeta(appVersion: AppIdentity.appVersion, docID: model.docID), to: url)
        } catch {
            return nil
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        return url
    }
}
