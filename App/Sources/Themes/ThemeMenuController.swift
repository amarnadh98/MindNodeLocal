import AppKit
import MapCore
import MapRender

/// F-STY-4's discoverability slice (user feedback: "there is no theme
/// selection in the Arbor app"): the ONE factory both doors to theme
/// selection share — the Format ▸ Theme submenu and the toolbar's
/// Theme pull-down. Every theme the catalog knows (built-ins first,
/// then user themes) is a title-carrying item, so the list works with
/// keyboard menu navigation and VoiceOver; choosing one routes to the
/// window controller's `setDocumentThemeAction` — the SAME one
/// `setTheme` command the inspector's Theme pane performs (one undo
/// step). The new-map default is marked in its title, the current
/// theme carries the checkmark.
///
/// F-STY-4 live hover preview: highlighting an item pins that theme on
/// the frontmost document's scene through the existing
/// `previewThemeOverride` seam — view-only; the model, the undo stack
/// and the dirty flag are untouched. Leaving the list (or closing the
/// menu) restores the stored selection.
@MainActor
final class ThemeMenuController: NSObject, NSMenuDelegate {
    static let shared = ThemeMenuController()

    /// The title suffix that marks the theme new maps start with
    /// (Settings ▸ General ▸ Default theme).
    private static let defaultSuffix = " — Default"

    // MARK: menu factory

    /// A theme menu, eagerly populated so the menu walkers (⇧⌘P's
    /// palette, the ⌘/ cheat sheet) see the full item list before it
    /// is ever opened; `menuNeedsUpdate` refreshes it at open time
    /// (fresh checkmark, freshly installed user themes).
    ///
    /// `owner` pins the menu to one window controller (the toolbar
    /// pull-down belongs to its window, whoever is key); the menu
    /// bar's copy passes nil and resolves through the key window.
    func makeMenu(title: String, owner: DocumentWindowController? = nil) -> NSMenu {
        pruneOwners()
        let menu = NSMenu(title: title)
        menu.delegate = self
        if let owner {
            let key = NSUserInterfaceItemIdentifier(UUID().uuidString)
            menu.identifier = key
            owners[key] = WeakController(value: owner)
            populate(menu, frontController: owner)
        } else {
            populate(menu, frontController: Self.frontDocumentController())
        }
        return menu
    }

    /// The controller this menu speaks for: its owner when it has
    /// one (the toolbar pull-down), else the key/main/first document
    /// window (the menu bar's copy routes through the key window).
    private func resolvedController(for menu: NSMenu) -> DocumentWindowController? {
        if let key = menu.identifier, let box = owners[key] {
            guard let value = box.value else {
                owners.removeValue(forKey: key)
                return Self.frontDocumentController()
            }
            return value
        }
        return Self.frontDocumentController()
    }

    /// (Re)builds `menu`'s items against `frontController`'s document:
    /// one item per theme (checked if current, "— Default" if it is
    /// the new-map default, a canvas swatch for at-a-glance reading),
    /// then the theme-editor and theme-inspector doors. A nil
    /// controller (no document window) disables every item — the same
    /// truth the responder chain would tell.
    func populate(_ menu: NSMenu, frontController: DocumentWindowController?) {
        menu.removeAllItems()
        let currentID =
            (frontController?.document as? MapDocument)?.model.theme?.id ?? BuiltInThemes.defaultID
        let hasDocument = frontController != nil
        for theme in ThemeCatalog.shared.themes {
            let title =
                theme.id == ThemeCatalog.defaultThemeID
                ? theme.name + Self.defaultSuffix : theme.name
            let entry = NSMenuItem(
                title: title,
                action: #selector(DocumentWindowController.setDocumentThemeAction(_:)),
                keyEquivalent: "")
            entry.target = nil
            entry.representedObject = theme.id
            // No document open, no current theme: nothing is checked.
            entry.state = hasDocument && theme.id == currentID ? .on : .off
            entry.isEnabled = hasDocument
            entry.image = Self.swatch(for: theme)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        // F-STY-5: the theme editor sheet (⇧⌘E — the item that used to
        // sit at the Format top level, moved into the Theme submenu so
        // every theme door is one place).
        let editor = NSMenuItem(
            title: "Edit Theme…",
            action: #selector(DocumentWindowController.editThemeAction(_:)),
            keyEquivalent: "E")
        editor.keyEquivalentModifierMask = [.command, .shift]
        editor.isEnabled = hasDocument
        menu.addItem(editor)
        // The Inspector's Theme tab, without having to know ⌥⌘I exists.
        let inspector = NSMenuItem(
            title: "Show Theme Inspector",
            action: #selector(DocumentWindowController.showThemeInspectorAction(_:)),
            keyEquivalent: "")
        inspector.isEnabled = hasDocument
        menu.addItem(inspector)
    }

    // MARK: NSMenuDelegate (open-time refresh + live hover preview)

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu, frontController: resolvedController(for: menu))
    }

    /// F-STY-4: highlighting a theme item previews it on the canvas
    /// without a command; highlighting anything else (or nothing)
    /// restores the stored selection.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let controller = resolvedController(for: menu) else { return }
        let id = item?.representedObject as? String
        guard id != controller.previewThemeID else { return }
        controller.previewThemeID = id
        controller.updateScene(preserveCamera: true)
    }

    /// Closing the menu without choosing: the preview must not linger
    /// on the canvas (choosing runs `setDocumentThemeAction`, which
    /// clears the preview itself before the command).
    func menuDidClose(_ menu: NSMenu) {
        guard let controller = resolvedController(for: menu),
            controller.previewThemeID != nil
        else { return }
        controller.previewThemeID = nil
        controller.updateScene(preserveCamera: true)
    }

    // MARK: helpers

    /// The controller the menu-bar copy's actions route to: the key
    /// window's when it is a document window, else the main window's,
    /// else the first document window (nil when no document is open —
    /// the items disable). A floating panel above a document never
    /// steals the target: the theme menu still speaks to the map
    /// behind it.
    static func frontDocumentController() -> DocumentWindowController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) + NSApp.windows {
            if let controller = window.windowController as? DocumentWindowController {
                return controller
            }
        }
        return nil
    }

    // MARK: owner bookkeeping (the toolbar pull-down's window)

    /// `[menu.identifier: weak controller]` — the owned menus'
    /// targets. Weak so a closed window's entry prunes itself.
    private var owners: [NSUserInterfaceItemIdentifier: WeakController] = [:]

    private final class WeakController {
        weak var value: DocumentWindowController?

        init(value: DocumentWindowController) {
            self.value = value
        }
    }

    private func pruneOwners() {
        for (key, box) in owners where box.value == nil {
            owners.removeValue(forKey: key)
        }
    }

    /// A small canvas-colour swatch carrying the theme's first palette
    /// colours, so the menu list reads like the inspector's tiles at a
    /// glance (at least a checkmark marks the current one).
    private static func swatch(for theme: Theme) -> NSImage {
        let size = NSSize(width: 26, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let card = NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 3, yRadius: 3)
        NSColor(hex: theme.light.canvasColor).setFill()
        cardPath.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        cardPath.stroke()
        let dot = CGFloat(4)
        var origin = NSPoint(x: card.minX + 3, y: card.minY + 2.5)
        for hex in theme.light.palette.prefix(4) {
            NSColor(hex: hex).setFill()
            NSBezierPath(ovalIn: NSRect(origin: origin, size: NSSize(width: dot, height: dot)))
                .fill()
            origin.x += dot + 1.5
        }
        image.unlockFocus()
        return image
    }
}

extension NSColor {
    /// `#RRGGBB` (or `RRGGBB`) → a color; unparsable strings fall
    /// back to the placeholder gray (the same rule as
    /// InspectorControls' SwiftUI `Color(hex:)`). Only this file
    /// uses it, so it stays fileprivate to the extension.
    fileprivate convenience init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self.init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            return
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}
