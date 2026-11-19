import AppKit
import MapCore
import MapRender
import SwiftUI

/// The contextual floating bar (SPEC §6.3): a compact glass bar that
/// appears 12 pt above a settled selection — shape, fill color, text
/// weight/italic, add child, task, note, link and "more" (opens the
/// inspector's Style tab). Every mutation is ONE `MapStore` command
/// over the whole selection (F-EDT-12); view-only state — showing or
/// hiding never touches the model or the undo stack.
///
/// The bar hides while typing or dragging, follows the camera, and
/// lands below the selection when there is no room above.
@MainActor
final class ContextualBarController {
    /// §6.3: the selection must settle for this long before the bar
    /// appears.
    static let settleDelay: Duration = .milliseconds(300)
    /// §6.3: 12 pt above the selection.
    static let verticalGap: CGFloat = 12

    private(set) var bar: NSVisualEffectView?
    private var showTask: Task<Void, Never>?
    private weak var host: DocumentWindowController?

    /// The bar's persisted preference (SPEC §6.3: "can be disabled").
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: DocumentPreferences.contextualBarKey)
            as? Bool) ?? true
    }

    // MARK: lifecycle

    func attach(to host: DocumentWindowController) {
        self.host = host
    }

    /// Selection settled: schedule the bar (§6.3's 300 ms), hiding any
    /// live one first so a moving selection never drags the bar along.
    func selectionDidChange() {
        guard let host else { return }
        showTask?.cancel()
        dismiss()
        guard Self.isEnabled, host.window?.isVisible == true else { return }
        let delay = Self.settleDelay
        showTask = Task { [weak self, weak host] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.presentIfNeeded()
        }
    }

    /// Any store change or camera move repositions (or drops) the bar.
    func reposition() {
        presentIfNeeded()
    }

    /// The typing/dragging contract (§6.3): the bar never rides an
    /// editing session or a drag.
    func dismiss() {
        bar?.removeFromSuperview()
        bar = nil
    }

    // MARK: presentation

    /// Builds and places the bar when the current state allows it;
    /// returns true when the bar is on screen afterwards.
    @discardableResult
    private func presentIfNeeded() -> Bool {
        guard let host, let window = host.window, !host.canvas.isEditing,
            !host.canvas.isDragging, !host.canvas.selection.isEmpty, Self.isEnabled
        else {
            dismiss()
            return false
        }
        let canvas = host.canvas
        guard let scene = canvas.scene else { return false }
        // The selection's combined frame, in view coordinates (the same
        // camera math the layer tree pins node layers with).
        var combined: CGRect = .null
        for id in canvas.selection {
            if let frame = scene.nodes[id]?.frame {
                combined = combined.union(frame)
            }
        }
        guard !combined.isNull else { return false }
        let scale = canvas.camera.scale
        let viewRect = CGRect(
            origin: canvas.camera.screenPoint(for: combined.origin),
            size: CGSize(width: combined.width * scale, height: combined.height * scale))

        let bar = self.bar ?? makeBar()
        if bar.superview == nil {
            window.contentView?.addSubview(bar)
        }
        let size = bar.fittingSize
        // Above the selection (the view is flipped); below when there
        // is no room above.
        let above = viewRect.minY - Self.verticalGap - size.height
        let y = above >= 0 ? above : viewRect.maxY + Self.verticalGap
        let x = min(
            max(viewRect.midX - size.width / 2, 8),
            max(canvas.bounds.width - size.width - 8, 8))
        bar.setFrameOrigin(NSPoint(x: x, y: y))
        self.bar = bar
        return true
    }

    // MARK: construction

    private func makeBar() -> NSVisualEffectView {
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .behindWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.setViews(buildControls(), in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        return bar
    }

    /// §6.3's node-selection controls. Shape and fill are popups (the
    /// shape item's tag is its `NodeShape.allCases` index); B/I are the
    /// text style toggles; the rest route to the existing first-
    /// responder actions.
    private func buildControls() -> [NSView] {
        guard let host else { return [] }
        var views: [NSView] = [shapePopup(), fillPopup()]
        views.append(button("bold", "Bold text", #selector(boldAction)))
        views.append(button("italic", "Italic text", #selector(italicAction)))
        views.append(NSStackView.separator())
        views.append(button("plus", "Add a child node", #selector(addChildAction)))
        views.append(button("checkmark.circle", "Toggle task", #selector(taskAction)))
        views.append(button("note.text", "Edit the note", #selector(noteAction)))
        views.append(button("link", "Add a link", #selector(linkAction)))
        views.append(NSStackView.separator())
        let more = button("ellipsis.circle", "More style options", #selector(moreAction))
        views.append(more)
        return views
    }

    private func shapePopup() -> NSView {
        let popup = NSPopUpButton()
        popup.bezelStyle = .texturedRounded
        popup.controlSize = .small
        for (index, shape) in NodeShape.allCases.enumerated() {
            popup.menu?.addItem(shapeItem(shape, tag: index))
        }
        popup.action = #selector(shapeChosen(_:))
        popup.target = self
        popup.toolTip = "Node shape"
        popup.setAccessibilityLabel("Node shape")
        return popup
    }

    private func shapeItem(_ shape: NodeShape, tag: Int) -> NSMenuItem {
        let entry = NSMenuItem(
            title: InspectorStyleTab.shapeName(shape), action: nil, keyEquivalent: "")
        entry.tag = tag
        return entry
    }

    private func fillPopup() -> NSView {
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.title = ""
        button.image = NSImage(
            systemSymbolName: "paintpalette", accessibilityDescription: "Fill color")
        button.imagePosition = .imageOnly
        button.action = #selector(fillChosen(_:))
        button.target = self
        button.toolTip = "Fill color"
        button.setAccessibilityLabel("Fill color")
        return button
    }

    private func button(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSView {
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.action = action
        button.target = self
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        return button
    }

    // MARK: actions (through the host — one MapStore command each)

    @objc private func shapeChosen(_ sender: NSPopUpButton) {
        guard let menuItem = sender.selectedItem else { return }
        host?.applyShapeAction(menuItem)
    }

    /// The fill palette menu: the theme's branch palette, "None", the
    /// recent colors and the system panel route through the inspector
    /// closure in F-STY-7's order.
    @objc private func fillChosen(_ sender: NSButton) {
        guard let host, let store = host.store else { return }
        let palette =
            store.model.theme?.overrides?.paletteColors
            ?? BuiltInThemes.theme(id: store.model.theme?.id ?? BuiltInThemes.defaultID).light.palette
        let menu = NSMenu(title: "Fill")
        for (index, hex) in palette.enumerated() {
            let entry = NSMenuItem(title: "Color \(index + 1)", action: nil, keyEquivalent: "")
            entry.image = swatchImage(hex)
            entry.action = #selector(fillPicked(_:))
            entry.target = self
            entry.representedObject = hex
            menu.addItem(entry)
        }
        let none = NSMenuItem(title: "No Fill", action: nil, keyEquivalent: "")
        none.action = #selector(fillPicked(_:))
        none.target = self
        none.representedObject = "none"
        menu.addItem(none)
        menu.popUp(
            positioning: nil,
            at: NSPoint(
                x: sender.frame.minX,
                y: sender.frame.maxY + Self.verticalGap / 2),
            in: sender)
    }

    @objc private func fillPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        host?.performStyleCommandOnSelection {
            .setStyle(ids: $0, patch: NodeStylePatch(fill: raw))
        }
        if raw != "none" {
            DocumentPreferences.noteColorPick(raw)
        }
    }

    /// §6.3's B: a bold text weight toggle (0.4 on, theme weight off).
    @objc private func boldAction() {
        host?.performStyleCommandOnSelection { ids in
            let current =
                (host?.store?.model.nodes[ids.first ?? ""]?.style?.fontWeight ?? nil) == 0.4
            return .setStyle(
                ids: ids, patch: NodeStylePatch(fontWeight: current ? 0.0 : 0.4))
        }
    }

    /// §6.3's I: an italic toggle.
    @objc private func italicAction() {
        host?.performStyleCommandOnSelection { ids in
            let current =
                (host?.store?.model.nodes[ids.first ?? ""]?.style?.fontItalic ?? nil) == true
            return .setStyle(ids: ids, patch: NodeStylePatch(fontItalic: !current))
        }
    }

    /// The existing first-responder actions (their validation and undo
    /// semantics are the menu's).
    @objc private func addChildAction() {
        host?.addChildAction(nil)
    }

    @objc private func taskAction() {
        host?.toggleTaskAction(nil)
    }

    @objc private func noteAction() {
        host?.noteAction(nil)
    }

    @objc private func linkAction() {
        host?.linkAction(nil)
    }

    /// "⋯": the inspector's Style tab (showing the pane if hidden).
    @objc private func moreAction() {
        guard let host else { return }
        if !host.inspector.isVisible {
            host.inspector.toggleVisibility()
        }
        host.inspector.model.tab = .style
    }

    private func swatchImage(_ hex: String) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        swatchColor(hex).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3)
            .fill()
        image.unlockFocus()
        return image
    }

    /// `#RRGGBB` → `NSColor` for the menu swatches (unparsable → gray).
    private func swatchColor(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            return .systemGray
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// The model-frame → view-rect conversion the bar positions itself
/// with is inline above (the camera's `screenPoint`, the same math the
/// layer tree uses).

extension NSStackView {
    fileprivate static func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }
}
