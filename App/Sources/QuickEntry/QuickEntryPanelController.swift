import AppKit
import MapCore
import MapIO
import os

/// The floating Quick Entry panel (F-QEN-1): key-accepting,
/// non-activating, borderless, framed by Liquid Glass
/// (`NSGlassEffectView`, the macOS 26 material) around the outline
/// editor. Plain ⏎ is a new line, ⇥ indents, ⇧⇥ outdents (the delegate),
/// ⌘⏎ = Create Map and ⎋ = close (the panel's key router, before any
/// menu equivalent can claim the keys).
@MainActor
final class QuickEntryPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Routes the two panel-level keys; false otherwise.
    var keyRouter: ((_ event: NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyRouter?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns the panel's views and the capture actions (F-QEN-2, plus
/// F-QEN-3's clipboard pull). Every action parses the editor's text
/// through `QuickEntryOutline` and lands ONE grouped `MapCommand` in the
/// target document's `MapStore` — never a direct model mutation.
@MainActor
final class QuickEntryPanelController: NSObject, NSTextViewDelegate {
    let panel: QuickEntryPanel
    private let editor: NSTextView
    private let inboxButton = NSButton()
    private let entryLog = Logger(subsystem: "arbor", category: "quickentry")

    /// The pasteboard F-QEN-3 pulls from; injectable so hosted tests use
    /// a private `NSPasteboard.withUniqueName()` instead of the user's
    /// clipboard.
    var clipboard: NSPasteboard = .general

    override init() {
        panel = QuickEntryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        // Liquid Glass frame (SPEC §6.15): the glass view embeds the
        // content view inside the effect.
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))
        glass.style = .regular
        glass.cornerRadius = 18
        let content = NSView(frame: glass.bounds)
        content.autoresizingMask = [.width, .height]
        glass.contentView = content
        panel.contentView = glass

        editor = Self.makeEditor(applyTypingPreferences: true)
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let title = NSTextField(labelWithString: "Quick Entry")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let hintLabel = NSTextField(
            labelWithString: "⏎ new line  ·  ⇥ indent, ⇧⇥ outdent  ·  ⌘⏎ create")
        hintLabel.font = .controlContentFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hintLabel)

        super.init()

        let buttons = Self.makeButtons(controller: self, inboxButton: inboxButton)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hintLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        editor.delegate = self
        panel.keyRouter = { [weak self] event in
            self?.route(event: event) ?? false
        }
        panel.setAccessibilityLabel("Quick Entry")
        refreshInboxButtonTitle()
    }

    // MARK: panel lifecycle

    /// Shows the panel near the top of the main display and focuses the
    /// editor — no app activation (`.nonactivatingPanel`), so the
    /// thought being captured keeps its context.
    func show() {
        if !panel.isVisible, let visible = NSScreen.main?.visibleFrame {
            let frame = panel.frame
            panel.setFrameOrigin(
                NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 48))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        editor.window?.makeFirstResponder(editor)
        editor.scrollToBeginningOfDocument(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// The editor's text (the capture payload).
    var text: String {
        get { editor.string }
        set {
            editor.string = newValue
            editor.scrollToBeginningOfDocument(nil)
        }
    }

    /// The editor itself, so hosted tests type through the real path.
    var editorView: NSTextView { editor }

    // MARK: NSTextViewDelegate (outline keys)

    /// ⇧⇥ outdents the current line: removes one leading tab so the
    /// outline structure is exactly as typed.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            outdentCurrentLine(of: textView)
            return true
        }
        return false
    }

    private func outdentCurrentLine(of textView: NSTextView) {
        let text = textView.string as NSString
        let selected = textView.selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: selected.location, length: 0))
        guard text.substring(with: lineRange).hasPrefix("\t") else { return }
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: lineRange.location, length: 1),
            with: NSAttributedString(string: ""))
    }

    // MARK: keys

    /// ⌘⏎ creates, ⎋ closes — claimed before the menu's equivalents.
    private func route(event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            createMapAction(nil)
            return true
        }
        if event.keyCode == 53 {
            close()
            return true
        }
        return false
    }

    // MARK: actions (F-QEN-2)

    /// **Create Map**: a new untitled document, the first line as root,
    /// everything else descending from it. One grouped command through
    /// the new document's store — one undo step.
    @objc func createMapAction(_ sender: Any?) {
        guard let subtrees = QuickEntryOutline.subtrees(from: editor.string), !subtrees.isEmpty else {
            NSSound.beep()
            return
        }
        do {
            let scratch = MapModel.emptyDocument()
            let command = try QuickEntryOutline.createMapCommand(subtrees: subtrees, in: scratch)
            guard
                let document = try NSDocumentController.shared.makeUntitledDocument(
                    ofType: AppIdentity.documentUTI) as? MapDocument
            else { return }
            try document.store.perform(command)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            for controller in document.windowControllers {
                controller.showWindow(nil)
            }
            captureSucceeded()
        } catch {
            entryLog.error("Quick Entry create failed: \(String(describing: error))")
            NSSound.beep()
        }
    }

    /// **Append to Inbox map** (F-QEN-2): designates an inbox on first
    /// use, then appends the outline as children of the inbox's first
    /// root (or as new roots of an empty inbox) — one grouped command in
    /// the target document's store.
    @objc func appendInboxAction(_ sender: Any?) {
        let inbox = QuickEntryInboxStore.shared
        guard let url = inbox.resolve() ?? inbox.chooseInboxMap() else { return }
        guard let document = openMapDocument(at: url) else {
            NSSound.beep()
            return
        }
        guard !document.isReadOnlyFormat else {
            presentReadOnlyAlert(documentName: inbox.displayName() ?? url.lastPathComponent)
            return
        }
        appendToDocument(document, selectingIn: nil)
    }

    /// **Add to…** (F-QEN-2): pick a recent map and a node; the outline
    /// becomes that node's last children.
    @objc func addToAction(_ sender: Any?) {
        let picker = AddToMapPanelController()
        picker.onCommit = { [weak self] url, nodeID in
            guard let self else { return }
            guard let document = self.openMapDocument(at: url) else {
                NSSound.beep()
                return
            }
            guard !document.isReadOnlyFormat else {
                self.presentReadOnlyAlert(documentName: url.lastPathComponent)
                return
            }
            self.appendToDocument(document, selectingIn: nodeID)
        }
        picker.show(attachedTo: panel)
    }

    /// **Paste as Outline** (F-QEN-3): pulls the clipboard into the
    /// editor — the richest flavour the paste machinery understands
    /// (Arbor payload, OPML, Markdown, indented text) folds into the
    /// outline as text.
    @objc func pasteOutlineAction(_ sender: Any?) {
        let pasteboard = clipboard
        if let data = pasteboard.data(forType: Self.arborPayloadType),
            let subtrees = try? PasteboardParser.parsePayload(data),
            let outline = Self.outlineText(from: subtrees)
        {
            insertOutline(outline)
            return
        }
        for type in Self.textFlavours {
            guard let text = pasteboard.string(forType: type), !text.isEmpty else { continue }
            insertOutline(text)
            return
        }
        NSSound.beep()
    }

    // MARK: action plumbing

    /// Appends the editor's outline to `document`: under `nodeID` when
    /// given, else the inbox rule (first root, or new roots when empty).
    /// ONE command, ONE undo step; the panel then clears and closes.
    private func appendToDocument(_ document: MapDocument, selectingIn nodeID: String?) {
        guard let subtrees = QuickEntryOutline.subtrees(from: editor.string), !subtrees.isEmpty else {
            NSSound.beep()
            return
        }
        do {
            let model = document.store.model
            let command: MapCommand
            if let nodeID {
                command = try QuickEntryOutline.appendCommand(
                    subtrees: subtrees, parent: nodeID, in: model)
            } else if let rootID = model.roots.first, model.nodes[rootID] != nil {
                command = try QuickEntryOutline.appendCommand(
                    subtrees: subtrees, parent: rootID, in: model)
            } else {
                command = try PasteboardParser.insertCommand(
                    subtrees, parent: nil, index: model.roots.count, in: model)
            }
            try document.store.perform(command)
            for controller in document.windowControllers {
                controller.showWindow(nil)
            }
            captureSucceeded()
        } catch {
            entryLog.error("Quick Entry append failed: \(String(describing: error))")
            NSSound.beep()
        }
    }

    /// Finds an already-open document for `url`, or opens one through
    /// the document controller — either way the capture lands in a
    /// document the app owns. NSDocument normalizes package URLs with a
    /// trailing slash, so the comparison goes through
    /// `standardizedFileURL`.
    private func openMapDocument(at url: URL) -> MapDocument? {
        let target = url.standardizedFileURL
        for case let document as MapDocument in NSDocumentController.shared.documents
        where document.fileURL?.standardizedFileURL == target {
            return document
        }
        do {
            guard
                let document = try NSDocumentController.shared.makeDocument(
                    withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument
            else { return nil }
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            return document
        } catch {
            entryLog.error("Quick Entry open failed: \(String(describing: error))")
            return nil
        }
    }

    /// A capture succeeded: clear the editor, close the panel.
    private func captureSucceeded() {
        text = ""
        close()
    }

    /// The read-only refusal (F-DOC-4): the panel stays open with its
    /// text, so nothing typed is lost.
    private func presentReadOnlyAlert(documentName: String) {
        let alert = NSAlert()
        alert.messageText = "\"\(documentName)\" is read-only"
        alert.informativeText =
            "The document was saved by a newer version of Arbor and can't be modified."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: panel, completionHandler: nil)
    }

    private func insertOutline(_ outline: String) {
        let current = editor.string
        let joined =
            current.isEmpty || current.hasSuffix("\n") ? current + outline : current + "\n" + outline
        text = joined
    }

    /// Re-title the inbox button when the designated inbox changes.
    private func refreshInboxButtonTitle() {
        if let name = QuickEntryInboxStore.shared.displayName() {
            inboxButton.title = "Append to \(name)"
        } else {
            inboxButton.title = "Append to Inbox…"
        }
    }

    // MARK: view construction

    private static let arborPayloadType =
        NSPasteboard.PasteboardType("com.arbor.paste.nodes")
    private static let textFlavours: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.opml.opml"),
        NSPasteboard.PasteboardType("net.daringfireball.markdown"),
        .string,
    ]

    /// The outline editor: plain-text, undo-armed, with the F-SET
    /// Editing preferences (smart typing, spell check) applied.
    static func makeEditor(applyTypingPreferences: Bool) -> NSTextView {
        let editor = NSTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.insertionPointColor = .labelColor
        if applyTypingPreferences {
            editor.applyTypingPreferences()
        }
        return editor
    }

    /// The action row: Paste as Outline | Add to… | Append to Inbox |
    /// Create Map (emphasized, F-QEN-2's primary). The spacer pushes the
    /// last two to the row's trailing edge.
    private static func makeButtons(
        controller: QuickEntryPanelController, inboxButton: NSButton
    ) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        inboxButton.title = "Append to Inbox…"
        inboxButton.target = controller
        inboxButton.action = #selector(QuickEntryPanelController.appendInboxAction(_:))
        inboxButton.bezelStyle = .recessed
        inboxButton.translatesAutoresizingMaskIntoConstraints = false

        func smallButton(_ title: String, action: Selector) -> NSButton {
            let button = NSButton(title: title, target: controller, action: action)
            button.bezelStyle = .recessed
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }

        let paste = smallButton(
            "Paste as Outline", action: #selector(QuickEntryPanelController.pasteOutlineAction(_:)))
        let addTo = smallButton(
            "Add to…", action: #selector(QuickEntryPanelController.addToAction(_:)))
        let create = smallButton(
            "Create Map", action: #selector(QuickEntryPanelController.createMapAction(_:)))
        create.bezelStyle = .push
        create.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)

        row.addArrangedSubview(paste)
        row.addArrangedSubview(addTo)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(inboxButton)
        row.addArrangedSubview(create)
        return row
    }

    /// The Arbor payload flavour as indented text (F-QEN-3).
    private static func outlineText(from subtrees: [PastedSubtree]) -> String? {
        var lines: [String] = []

        func walk(_ subtree: PastedSubtree, depth: Int) {
            lines.append(String(repeating: "\t", count: depth) + subtree.snapshot.title.text)
            for child in subtree.children {
                walk(child, depth: depth + 1)
            }
        }

        for subtree in subtrees {
            walk(subtree, depth: 0)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// F-SET Editing rows wired to the Quick Entry editor (the editor this
/// slice owns): smart typing and spell check read the shared
/// preferences, so the Settings toggles and ⌘V behave alike.
extension NSTextView {
    @MainActor
    func applyTypingPreferences(defaults: UserDefaults = .standard) {
        isAutomaticQuoteSubstitutionEnabled = AppSettings.bool(
            AppSettings.smartTypingKey, defaults: defaults, fallback: true)
        isAutomaticDashSubstitutionEnabled = isAutomaticQuoteSubstitutionEnabled
        isAutomaticTextReplacementEnabled = isAutomaticQuoteSubstitutionEnabled
        isContinuousSpellCheckingEnabled = AppSettings.bool(
            AppSettings.spellCheckKey, defaults: defaults, fallback: true)
    }
}
