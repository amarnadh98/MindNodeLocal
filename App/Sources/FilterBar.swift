import AppKit
import CanvasKit
import MapCore

/// The F-TAG-3 filter bar (⇧⌥⌘F): one row combining text, one tag,
/// task state, content flags, node type, mastery level and due date,
/// with the dim/hide mode switch, saved filters and the clear button.
/// Pure routing: every change reports a `NodeFilter` + mode through
/// `onChange`; the window controller applies them (dim = view state,
/// hide = a full scene rebuild with pruning; saved filters = the one
/// undoable `MapCommand.setFilters`).
final class FilterBarView: NSView {
    static let barHeight: CGFloat = 34

    /// The active filter + mode (true = hide non-matching).
    var onChange: ((NodeFilter, Bool) -> Void)?
    /// Save the active filter under a name (the controller runs the
    /// one undoable `setFilters`).
    var onSaveFilter: ((NodeFilter) -> Void)?
    /// Apply a saved filter by query string.
    var onApplySaved: ((String) -> Void)?

    private let textField = NSTextField()
    private let tagPopup = NSPopUpButton()
    private let taskPopup = NSPopUpButton()
    private let contentPopup = NSPopUpButton()
    private let typePopup = NSPopUpButton()
    private let masteryPopup = NSPopUpButton()
    private let duePopup = NSPopUpButton()
    private let modeSegment = NSSegmentedControl()
    private let savedPopup = NSPopUpButton()
    private let clearButton = NSButton()

    /// The document's tags, for the tag popup (id → menu item).
    private var tagIDs: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FilterBarView is created directly")
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 0

        configureField(textField, placeholder: "Text")
        configurePopup(tagPopup, accessibility: "Filter by tag", action: #selector(popChanged))
        configurePopup(taskPopup, accessibility: "Filter by task state", action: #selector(popChanged))
        configurePopup(contentPopup, accessibility: "Filter by content", action: #selector(popChanged))
        configurePopup(typePopup, accessibility: "Filter by node type", action: #selector(popChanged))
        configurePopup(masteryPopup, accessibility: "Filter by mastery level", action: #selector(popChanged))
        configurePopup(duePopup, accessibility: "Filter by due date", action: #selector(popChanged))
        configurePopup(savedPopup, accessibility: "Saved filters", action: #selector(savedChanged))

        taskPopup.addItems(withTitles: ["Any task state", "Task", "Open task", "Done", "Not a task"])
        contentPopup.addItems(
            withTitles: ["Any content", "Has note", "No note", "Has image", "No image", "Has attachment"])
        masteryPopup.addItems(
            withTitles: ["Any mastery", "Strong", "Good", "Fading", "Forgotten", "New"])
        duePopup.addItems(withTitles: ["Any due date", "Overdue", "Due today", "Due this week"])

        modeSegment.segmentStyle = .texturedRounded
        modeSegment.segmentCount = 2
        modeSegment.setLabel("Dim", forSegment: 0)
        modeSegment.setLabel("Hide", forSegment: 1)
        modeSegment.selectedSegment = 0
        modeSegment.action = #selector(popChanged)
        modeSegment.target = self
        modeSegment.setAccessibilityLabel("Filter mode")

        clearButton.bezelStyle = .recessed
        clearButton.title = "Clear"
        clearButton.action = #selector(clearPressed)
        clearButton.target = self
        clearButton.setAccessibilityLabel("Clear the filter")

        let stack = NSStackView(views: [
            textField, tagPopup, taskPopup, contentPopup, typePopup, masteryPopup, duePopup,
            modeSegment, savedPopup, clearButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            textField.widthAnchor.constraint(equalToConstant: 150),
        ])
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.target = self
        field.action = #selector(textChanged)
        field.setAccessibilityLabel(placeholder)
    }

    private func configurePopup(_ popup: NSPopUpButton, accessibility: String, action: Selector) {
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popup.bezelStyle = .texturedRounded
        popup.action = action
        popup.target = self
        popup.setAccessibilityLabel(accessibility)
    }

    // MARK: host surface

    /// Rebuilds the document-driven popups (tags, types, saved).
    func refresh(model: MapModel) {
        let selectedTag = tagPopup.indexOfSelectedItem
        tagPopup.itemArray.forEach { tagPopup.menu?.removeItem($0) }
        tagPopup.addItem(withTitle: "Any tag")
        tagIDs = []
        for tag in model.tags ?? [] {
            tagPopup.addItem(withTitle: "#" + tag.name)
            tagIDs.append(tag.id)
        }
        tagPopup.selectItem(at: min(max(selectedTag, 0), tagPopup.numberOfItems - 1))

        let selectedType = typePopup.indexOfSelectedItem
        let types = Array(Set(model.nodes.values.compactMap(\.type))).sorted()
        typePopup.itemArray.forEach { typePopup.menu?.removeItem($0) }
        typePopup.addItem(withTitle: "Any type")
        for type in types {
            typePopup.addItem(withTitle: type.capitalized)
        }
        typePopup.selectItem(at: min(max(selectedType, 0), typePopup.numberOfItems - 1))

        let selectedSaved = savedPopup.indexOfSelectedItem
        savedPopup.itemArray.forEach { savedPopup.menu?.removeItem($0) }
        savedPopup.addItem(withTitle: "Save Filter…")
        savedPopup.menu?.items[0].action = #selector(savePressed)
        savedPopup.menu?.items[0].target = self
        if let saved = model.filters, !saved.isEmpty {
            savedPopup.menu?.addItem(.separator())
            for filter in saved {
                let item = NSMenuItem(
                    title: filter.name, action: #selector(savedItemPressed), keyEquivalent: "")
                item.target = self
                item.representedObject = filter.query
                savedPopup.menu?.addItem(item)
            }
        }
        savedPopup.selectItem(at: min(max(selectedSaved, 0), savedPopup.numberOfItems - 1))
    }

    /// Resets every control and reports the empty filter.
    func clear() {
        textField.stringValue = ""
        for popup in [tagPopup, taskPopup, contentPopup, typePopup, masteryPopup, duePopup] {
            popup.selectItem(at: 0)
        }
        modeSegment.selectedSegment = 0
        onChange?(filter(), false)
    }

    /// The filter the controls describe.
    private func filter() -> NodeFilter {
        var filter = NodeFilter(text: textField.stringValue.isEmpty ? nil : textField.stringValue)
        if tagPopup.indexOfSelectedItem > 0, tagPopup.indexOfSelectedItem - 1 < tagIDs.count {
            filter.tagIDs = [tagIDs[tagPopup.indexOfSelectedItem - 1]]
        }
        switch taskPopup.indexOfSelectedItem {
        case 1: filter.taskState = .task
        case 2: filter.taskState = .open
        case 3: filter.taskState = .done
        case 4: filter.taskState = .notask
        default: break
        }
        switch contentPopup.indexOfSelectedItem {
        case 1: filter.hasNote = true
        case 2: filter.hasNote = false
        case 3: filter.hasImage = true
        case 4: filter.hasImage = false
        case 5: filter.hasAttachment = true
        default: break
        }
        if typePopup.indexOfSelectedItem > 0, let raw = typePopup.selectedItem?.title.lowercased() {
            filter.nodeType = raw
        }
        switch masteryPopup.indexOfSelectedItem {
        case 1: filter.mastery = .strong
        case 2: filter.mastery = .good
        case 3: filter.mastery = .fading
        case 4: filter.mastery = .forgotten
        case 5: filter.mastery = .fresh
        default: break
        }
        switch duePopup.indexOfSelectedItem {
        case 1: filter.due = .overdue
        case 2: filter.due = .today
        case 3: filter.due = .week
        default: break
        }
        return filter
    }

    // MARK: actions

    @objc private func textChanged() {
        onChange?(filter(), modeSegment.selectedSegment == 1)
    }

    @objc private func popChanged() {
        onChange?(filter(), modeSegment.selectedSegment == 1)
    }

    @objc private func savePressed() {
        onSaveFilter?(filter())
        savedPopup.selectItem(at: 0)
    }

    @objc private func savedItemPressed(_ sender: NSMenuItem) {
        if let query = sender.representedObject as? String {
            onApplySaved?(query)
        }
    }

    @objc private func savedChanged() {
        // "Save Filter…" rides its own action; the popup itself only
        // applies saved items.
        if savedPopup.indexOfSelectedItem == 0 {
            savePressed()
        } else if let query = savedPopup.selectedItem?.representedObject as? String {
            onApplySaved?(query)
        }
    }

    @objc private func clearPressed() {
        clear()
    }
}
