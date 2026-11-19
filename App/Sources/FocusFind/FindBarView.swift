import AppKit

/// A find-bar field: an `NSTextField` that remembers the bar it lives
/// in, so the window's custom field editor (see
/// `windowWillReturnFieldEditor` in DocumentWindowController+FocusFind)
/// can route its plain Return/⇥/⎋/arrow presses — which otherwise fall
/// through to the menu's key equivalents ("Add Sibling Below" owns a
/// bare ⏎) — back to the bar.
@MainActor
final class FindBarField: NSTextField {
    weak var owningBar: FindBarView?
}

/// The shared field editor the find bar's fields type into. Plain
/// editing keys are claimed before the menu sees them; ⌘-modified keys
/// (⌘G, ⇧⌘G, ⌘F…) stay with the menu so the Edit ▸ Find items work
/// while the caret is in the field.
@MainActor
final class FindFieldEditor: NSTextView {
    weak var editorBar: FindBarView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let bar = editorBar,
            let key = event.charactersIgnoringModifiers, key.count == 1,
            !event.modifierFlags.contains(.command)
        else { return super.performKeyEquivalent(with: event) }
        return bar.interceptEditingKey(key)
    }
}

/// The F-FOC-3 find bar: a material strip over the top of the
/// document window with the query field, the match counter, the tags
/// toggle, next/previous, and (in replace mode) the replacement field
/// with Replace / Replace All. Hand-rolled AppKit — the callbacks
/// route into `FocusFindCoordinator`, which owns all the state.
@MainActor
final class FindBarView: NSView, NSTextFieldDelegate {
    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onReplace: ((String) -> Void)?
    var onReplaceAll: ((String) -> Void)?
    var onTagsToggle: ((Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let findField = FindBarField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let tagsButton = NSButton(checkboxWithTitle: "Tags", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let replaceField = FindBarField()
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let replaceRowContainer = NSView()
    private let background = NSVisualEffectView(frame: .zero)
    private var replaceVisible = false

    static let findRowHeight: CGFloat = 36
    static let replaceRowHeight: CGFloat = 36

    init() {
        super.init(frame: .zero)

        background.blendingMode = .withinWindow
        background.material = .contentBackground
        addSubview(background)

        findField.owningBar = self
        findField.placeholderString = "Find"
        findField.bezelStyle = .roundedBezel
        findField.focusRingType = .none
        findField.setAccessibilityLabel("Find")
        findField.delegate = self
        addSubview(findField)

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.alignment = .center
        addSubview(countLabel)

        previousButton.bezelStyle = .accessoryBar
        previousButton.setAccessibilityLabel("Find Previous")
        previousButton.controlSize = .small
        previousButton.target = self
        previousButton.action = #selector(previousClicked)
        addSubview(previousButton)

        nextButton.bezelStyle = .accessoryBar
        nextButton.setAccessibilityLabel("Find Next")
        nextButton.controlSize = .small
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        addSubview(nextButton)

        tagsButton.controlSize = .small
        tagsButton.setAccessibilityLabel("Search tags")
        tagsButton.target = self
        tagsButton.action = #selector(tagsClicked)
        addSubview(tagsButton)

        doneButton.bezelStyle = .accessoryBar
        doneButton.controlSize = .small
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        addSubview(doneButton)

        replaceField.owningBar = self
        replaceField.placeholderString = "Replace with"
        replaceField.bezelStyle = .roundedBezel
        replaceField.setAccessibilityLabel("Replace with")
        addSubview(replaceRowContainer, positioned: .above, relativeTo: background)
        replaceRowContainer.addSubview(replaceField)

        replaceButton.bezelStyle = .accessoryBar
        replaceButton.controlSize = .small
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        replaceRowContainer.addSubview(replaceButton)

        replaceAllButton.bezelStyle = .accessoryBar
        replaceAllButton.controlSize = .small
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)
        replaceRowContainer.addSubview(replaceAllButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FindBarView is created in code")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: host-facing API

    /// The current query text.
    var query: String {
        get { findField.stringValue }
        set { findField.stringValue = newValue }
    }

    /// The current replacement text.
    var replacement: String { replaceField.stringValue }

    /// Whether the tags toggle is on.
    var includesTags: Bool {
        get { tagsButton.state == .on }
        set { tagsButton.state = newValue ? .on : .off }
    }

    /// "3 of 12", "No matches", or "" while the bar is empty.
    func setCount(_ text: String) {
        countLabel.stringValue = text
    }

    /// Shows or hides the replace row, relayouting the bar.
    func setReplaceVisible(_ visible: Bool) {
        replaceVisible = visible
        replaceRowContainer.isHidden = !visible
        needsLayout = true
    }

    /// Focuses the query field with the text selected.
    func focusFindField() {
        window?.makeFirstResponder(findField)
        findField.selectText(nil)
        findField.currentEditor()?.selectAll(nil)
    }

    // MARK: plain editing keys (claimed before the menu)

    /// Handles one plain (no ⌘) editing key from the shared field
    /// editor: ⏎ next (replace field: replace all), ↑/↓ previous/next,
    /// ⎋ cancel, ⇥ cycle fields. Returns false for keys it doesn't
    /// own.
    func interceptEditingKey(_ key: String) -> Bool {
        switch key {
        case "\u{1b}":
            onCancel?()
            return true
        case "\r":
            if window?.firstResponder === replaceField.currentEditor() {
                onReplaceAll?(replacement)
            } else {
                onNext?()
            }
            return true
        case "\u{f700}":
            onPrevious?()
            return true
        case "\u{f701}":
            onNext?()
            return true
        case "\t":
            if replaceVisible {
                let target =
                    window?.firstResponder === replaceField.currentEditor()
                    ? findField : replaceField
                window?.makeFirstResponder(target)
            } else {
                focusFindField()
            }
            return true
        default:
            return false
        }
    }

    // MARK: layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let replaceHeight: CGFloat = replaceVisible ? Self.replaceRowHeight : 0
        let barHeight = Self.findRowHeight + replaceHeight
        frame.size.height = barHeight

        background.frame = bounds

        let margin: CGFloat = 8
        let fieldWidth: CGFloat = 240
        var x = margin

        findField.frame = NSRect(x: x, y: 6, width: fieldWidth, height: 24)
        x += fieldWidth + margin

        countLabel.frame = NSRect(x: x, y: 12, width: 72, height: 16)
        x += 72 + margin

        nextButton.sizeToFit()
        previousButton.sizeToFit()
        let nextWidth = nextButton.frame.width
        previousButton.frame = NSRect(x: x, y: 6, width: nextWidth, height: 24)
        nextButton.frame.origin = NSPoint(x: x + nextWidth + 4, y: 6)
        x += nextWidth * 2 + 8 + margin

        tagsButton.sizeToFit()
        tagsButton.frame.origin = NSPoint(x: x, y: 8)
        x += tagsButton.frame.width + margin

        doneButton.sizeToFit()
        doneButton.frame.origin = NSPoint(
            x: width - doneButton.frame.width - margin, y: 6)

        replaceRowContainer.frame = NSRect(
            x: 0, y: 0, width: width, height: replaceVisible ? Self.replaceRowHeight : 0)
        let replaceY: CGFloat = 6
        let replaceFieldWidth: CGFloat = 240
        replaceField.frame = NSRect(x: margin, y: replaceY, width: replaceFieldWidth, height: 24)
        replaceButton.sizeToFit()
        replaceAllButton.sizeToFit()
        replaceButton.frame.origin = NSPoint(x: margin + replaceFieldWidth + margin, y: replaceY)
        replaceAllButton.frame.origin = NSPoint(
            x: margin + replaceFieldWidth + margin + replaceButton.frame.width + 4, y: replaceY)
    }

    // MARK: NSControlTextEditingDelegate

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(findField.stringValue)
    }

    // MARK: button targets

    @objc private func previousClicked() {
        onPrevious?()
    }

    @objc private func nextClicked() {
        onNext?()
    }

    @objc private func tagsClicked() {
        onTagsToggle?(tagsButton.state == .on)
    }

    @objc private func doneClicked() {
        onCancel?()
    }

    @objc private func replaceClicked() {
        onReplace?(replaceField.stringValue)
    }

    @objc private func replaceAllClicked() {
        onReplaceAll?(replaceField.stringValue)
    }
}
