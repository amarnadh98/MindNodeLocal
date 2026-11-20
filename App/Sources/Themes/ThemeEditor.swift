import AppKit
import CanvasKit
import MapCore
import MapRender
import SwiftUI
import UniformTypeIdentifiers

/// The theme editor's editable state (F-STY-5): a working copy of a
/// `Theme`, the variant its live preview shows, and the preview image
/// itself — rebuilt through the SAME `SceneGeometry` + `SceneRenderer`
/// path the canvas, export and Quick Look use, so what the sheet shows
/// is exactly what a document would render. Pure data in, pixels out;
/// saving and applying live in `ThemeEditorController`.
@MainActor
final class ThemeEditorModel: ObservableObject {
    @Published private(set) var draft: Theme {
        didSet { rebuildPreview() }
    }
    /// Which variant the preview (and the property form) edits:
    /// every theme is dynamic (F-STY-4), so both schemes are editable.
    @Published private(set) var previewVariant: ThemeVariant = .light {
        didSet { rebuildPreview() }
    }
    @Published private(set) var preview: NSImage?
    /// Set when Apply/Save mints a user id for a built-in draft — the
    /// form shows "saves as a new theme" so the intent is honest.
    @Published private(set) var statusMessage = ""

    /// The map the preview renders — a fixed teaching-shaped sample, so
    /// the preview exercises a root, level-1 tinted fills, underlined
    /// level-2+ nodes and several palette branches at every level.
    private let previewMap: MapModel

    init(start: Theme, variant: ThemeVariant = .light) {
        draft = start
        previewVariant = variant
        previewMap = Self.previewMap()
        rebuildPreview()
    }

    /// True while the draft still carries a built-in id: saving it must
    /// mint a user id (built-ins are compile-time app data; ADR-0024).
    var isBuiltInDraft: Bool { BuiltInThemes.all.contains { $0.id == draft.id } }

    // MARK: draft mutation (each setter keeps the struct value whole)

    func setName(_ name: String) {
        draft.name = name
    }

    func setVariant(_ variant: ThemeVariant) {
        previewVariant = variant
    }

    /// The scheme the form edits (light or dark, per the toggle).
    var scheme: ThemeScheme {
        previewVariant == .dark ? draft.dark : draft.light
    }

    func setCanvasColor(_ hex: String) {
        if previewVariant == .dark { draft.dark.canvasColor = hex } else { draft.light.canvasColor = hex }
    }

    func setPaletteColor(at index: Int, hex: String) {
        var colors = scheme.palette
        guard colors.indices.contains(index) else { return }
        colors[index] = hex
        assignPalette(colors)
    }

    func addPaletteColor(hex: String = "#12A594") {
        guard scheme.palette.count < 12 else { return }
        assignPalette(scheme.palette + [hex])
    }

    func removePaletteColor(at index: Int) {
        var colors = scheme.palette
        guard colors.indices.contains(index), colors.count > 1 else { return }
        colors.remove(at: index)
        assignPalette(colors)
    }

    private func assignPalette(_ colors: [String]) {
        if previewVariant == .dark { draft.dark.palette = colors } else { draft.light.palette = colors }
    }

    /// Replaces one level style of the editing variant.
    func setLevel(_ key: ThemeLevelKey, _ style: ThemeLevelStyle) {
        if previewVariant == .dark {
            draft.dark.levels.setLevel(key, style)
        } else {
            draft.light.levels.setLevel(key, style)
        }
    }

    func setBranch(_ style: ThemeBranchStyle) { draft.branch = style }
    func setRainbowBranches(_ on: Bool) { draft.rainbowBranches = on }
    func setConnection(_ style: ThemeConnectionStyle) { draft.connection = style }
    func setBoundary(_ style: ThemeBoundaryStyle) { draft.boundary = style }

    /// "Duplicate as New Theme": mints a fresh user id immediately, so
    /// the copy saves to the themes folder instead of shadowing the
    /// built-in it started from.
    func duplicateAsNewTheme() {
        draft.id = Self.mintedUserID()
        draft.name = draft.name.isEmpty ? "My Theme" : "\(draft.name) Copy"
        statusMessage = "Editing a copy — Save writes it as a new theme."
    }

    static func mintedUserID() -> String {
        "user-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// If the draft still carries a built-in id, mint a user id now
    /// (Apply and Save call this; the mutation is once-only).
    func ensureUserID() {
        guard isBuiltInDraft else { return }
        draft.id = Self.mintedUserID()
    }

    // MARK: preview (the shared render path)

    private func rebuildPreview() {
        preview = Self.renderPreview(theme: draft, map: previewMap, variant: previewVariant)
    }

    /// The preview's fixed sample map: original text, shaped to show a
    /// root, tinted level-1 branches and underlined deeper levels.
    static func previewMap() -> MapModel {
        var model = MapModel.emptyDocument()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func node(_ id: String, parent: String? = nil, text: String) -> Node {
            Node(id: id, parent: parent, title: NodeTitle(text: text), created: date, modified: date)
        }
        let root = node("preview-root", text: "Theme Preview")
        model.nodes[root.id] = root
        model.roots = [root.id]
        let branches = [
            ("one", "First Branch", ["one-a", "one-b"]),
            ("two", "Second Branch", ["two-a", "two-b"]),
            ("three", "Third Branch", ["three-a"]),
        ]
        for (id, title, leaves) in branches {
            let branch = node(id, parent: root.id, text: title)
            model.nodes[id] = branch
            model.nodes[root.id]?.children.append(id)
            for leaf in leaves {
                model.nodes[leaf] = node(leaf, parent: id, text: "Leaf \(leaf)")
                model.nodes[id]?.children.append(leaf)
            }
        }
        return model
    }

    /// Renders `map` in `theme` at `variant`, fit into `size` — the
    /// same SceneGeometry + SceneRenderer pair every other surface uses
    /// (the sheet's preview can never drift from the canvas).
    static func renderPreview(
        theme: Theme, map: MapModel, variant: ThemeVariant, size: CGSize = CGSize(width: 520, height: 400)
    ) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scene = SceneGeometry.build(
            model: map, variant: variant, measurer: SceneRenderer.sharedMeasurer, theme: theme)
        guard let camera = fittedCamera(for: scene, in: size) else { return nil }
        return SlideThumbnails.render(scene: scene, camera: camera, size: size)
    }

    /// Centers the whole scene in `size` with a small margin.
    static func fittedCamera(for scene: CanvasScene, in size: CGSize) -> Camera? {
        guard !scene.nodes.isEmpty else { return nil }
        var bounds: CGRect?
        for frame in scene.nodes.values.map(\.frame) {
            bounds = bounds.map { $0.union(frame) } ?? frame
        }
        guard var bounds, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        bounds = bounds.insetBy(dx: -24, dy: -24)
        let margin: CGFloat = 16
        let usable = CGSize(width: size.width - margin * 2, height: size.height - margin * 2)
        guard usable.width > 0, usable.height > 0 else { return nil }
        let scale = min(max(min(usable.width / bounds.width, usable.height / bounds.height), 0.1), 2)
        return Camera(
            origin: CGPoint(
                x: bounds.midX - size.width / (2 * scale),
                y: bounds.midY - size.height / (2 * scale)),
            scale: scale)
    }
}

/// The four level styles a theme defines (F-STY-3), as form keys.
enum ThemeLevelKey: String, CaseIterable, Identifiable {
    case root
    case level1
    case level2
    case level3Plus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .root: "Root"
        case .level1: "Level 1"
        case .level2: "Level 2"
        case .level3Plus: "Level 3+"
        }
    }
}

extension ThemeLevels {
    mutating func setLevel(_ key: ThemeLevelKey, _ style: ThemeLevelStyle) {
        switch key {
        case .root: root = style
        case .level1: level1 = style
        case .level2: level2 = style
        case .level3Plus: level3Plus = style
        }
    }
}

// MARK: - controller

/// Owns the editor's lifecycle: presents the SwiftUI sheet, and turns
/// its actions into real effects — Apply performs ONE `setTheme`
/// `MapCommand` through the document's store (one undo step, F-STY-4),
/// after saving the theme into the catalog so the id resolves; Save
/// and Export write the same `.arbortheme` bytes to the catalog folder
/// or a chosen location (F-STY-5).
@MainActor
final class ThemeEditorController {
    let model: ThemeEditorModel
    /// Where Apply/Save write; injectable so hosted tests never touch
    /// the real Application Support.
    private let catalog: ThemeCatalog
    private weak var document: MapDocument?
    private weak var hostWindow: NSWindow?

    /// Creates the editor for `document`'s current theme (also the
    /// F-STY-5 "New Theme from Current Map" entry point: the draft is
    /// seeded from the live document until per-node overrides exist —
    /// ADR-0024).
    init(document: MapDocument, catalog: ThemeCatalog = .shared) {
        self.document = document
        self.catalog = catalog
        model = ThemeEditorModel(start: catalog.theme(for: document.model))
    }

    /// Creates the editor over an explicit theme (Settings ▸ Themes).
    init(theme: Theme) {
        catalog = .shared
        model = ThemeEditorModel(start: theme)
    }

    func present(asSheetOn window: NSWindow) {
        hostWindow = window
        let actions = ThemeEditorActions(
            applyToDocument: { [weak self] in self?.applyToDocument() },
            save: { [weak self] in self?.save() },
            export: { [weak self] in self?.exportTheme() },
            duplicate: { [weak self] in self?.model.duplicateAsNewTheme() },
            done: { [weak self] in self?.dismiss() })
        let host = NSHostingController(
            rootView: ThemeEditorView(model: model, actions: actions))
        // NSWindow only begins sheets from an NSWindow (the export
        // sheet's pattern): the controls inside dismiss through
        // `window.attachedSheet`.
        window.beginSheet(NSWindow(contentViewController: host))
    }

    private func dismiss() {
        if let sheet = hostWindow?.attachedSheet {
            hostWindow?.endSheet(sheet)
        }
    }

    /// Apply: save the (possibly fresh) user theme, then ONE undoable
    /// `setTheme` command through the store.
    func applyToDocument() {
        guard let document else { return }
        model.ensureUserID()
        do {
            _ = try catalog.save(model.draft)
        } catch {
            presentError(error, message: "The theme could not be saved.")
            return
        }
        do {
            try document.store.perform(.setTheme(id: model.draft.id))
        } catch {
            // A read-only document (F-DOC-4) refuses: tell the user,
            // keep the sheet open so nothing is lost.
            presentError(error, message: "The document refused the change.")
            return
        }
        dismiss()
    }

    /// Save: writes the `.arbortheme` into the themes folder; applying
    /// it to documents is a separate step.
    func save() {
        model.ensureUserID()
        do {
            let url = try catalog.save(model.draft)
            model.setStatusMessage("Saved to \(url.lastPathComponent)")
        } catch {
            presentError(error, message: "The theme could not be saved.")
        }
    }

    /// Export: the same bytes Save writes, to a location the user picks.
    func exportTheme() {
        model.ensureUserID()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ThemeCatalog.themeType]
        panel.nameFieldStringValue =
            ThemeCatalog.sanitizedName(model.draft.name, fallback: model.draft.id)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThemeCatalog.shared.export(model.draft, to: url)
        } catch {
            presentError(error, message: "The theme could not be exported.")
        }
    }

    private func presentError(_ error: Error, message: String) {
        let alert = NSAlert(error: error)
        alert.messageText = message
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow)
        } else {
            alert.runModal()
        }
    }
}

/// The sheet's action surface (the SlidesUIActions pattern): plain
/// `@MainActor` closures, `Sendable` through SwiftUI bindings under
/// strict concurrency.
struct ThemeEditorActions: Sendable {
    var applyToDocument: @MainActor () -> Void = {}
    var save: @MainActor () -> Void = {}
    var export: @MainActor () -> Void = {}
    var duplicate: @MainActor () -> Void = {}
    var done: @MainActor () -> Void = {}
}

extension ThemeEditorModel {
    /// The status line's text (save confirmations).
    func setStatusMessage(_ message: String) {
        statusMessage = message
    }
}

extension ThemeCatalog {
    /// The save panel's UTType for `.arbortheme`.
    static var themeType: UTType { UTType(themeUTI) ?? .json }
}
