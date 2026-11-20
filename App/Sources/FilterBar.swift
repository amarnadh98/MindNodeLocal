import AppKit
import CanvasKit
import MapCore
import MapStudy

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

    /// Empties a popup the way popups behave: removing the item array
    /// from the end (index 0 each pass — `removeAllItems` resets the
    /// selected index we want to preserve).
    private func removeAllItems(of popup: NSPopUpButton) {
        while popup.numberOfItems > 0 {
            popup.menu?.removeItem(at: 0)
        }
    }

    // MARK: host surface

    /// Rebuilds the document-driven popups (tags, types, saved).
    func refresh(model: MapModel) {
        let selectedTag = tagPopup.indexOfSelectedItem
        removeAllItems(of: tagPopup)
        tagPopup.addItem(withTitle: "Any tag")
        tagIDs = []
        for tag in model.tags ?? [] {
            tagPopup.addItem(withTitle: "#" + tag.name)
            tagIDs.append(tag.id)
        }
        tagPopup.selectItem(at: min(max(selectedTag, 0), tagPopup.numberOfItems - 1))

        let selectedType = typePopup.indexOfSelectedItem
        let types = Array(Set(model.nodes.values.compactMap(\.type))).sorted()
        removeAllItems(of: typePopup)
        typePopup.addItem(withTitle: "Any type")
        for type in types {
            typePopup.addItem(withTitle: type.capitalized)
        }
        typePopup.selectItem(at: min(max(selectedType, 0), typePopup.numberOfItems - 1))

        let selectedSaved = savedPopup.indexOfSelectedItem
        removeAllItems(of: savedPopup)
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

    /// The filter the controls describe — one helper per popup keeps the
    /// whole surface readable.
    private func filter() -> NodeFilter {
        let content = contentSelection()
        return NodeFilter(
            tagIDs: tagSelection(),
            taskState: taskSelection(),
            hasNote: content.note,
            hasImage: content.image,
            hasAttachment: content.attachment,
            nodeType: typeSelection(),
            mastery: masterySelection(),
            due: dueSelection(),
            text: textField.stringValue.isEmpty ? nil : textField.stringValue)
    }

    private func tagSelection() -> Set<String> {
        let index = tagPopup.indexOfSelectedItem
        guard index > 0, index - 1 < tagIDs.count else { return [] }
        return [tagIDs[index - 1]]
    }

    private func taskSelection() -> NodeFilter.TaskState? {
        switch taskPopup.indexOfSelectedItem {
        case 1: return .task
        case 2: return .open
        case 3: return .done
        case 4: return .notask
        default: return nil
        }
    }

    /// The content popup picks exactly ONE of its flags.
    private func contentSelection() -> (note: Bool?, image: Bool?, attachment: Bool?) {
        switch contentPopup.indexOfSelectedItem {
        case 1: return (true, nil, nil)
        case 2: return (false, nil, nil)
        case 3: return (nil, true, nil)
        case 4: return (nil, false, nil)
        case 5: return (nil, nil, true)
        default: return (nil, nil, nil)
        }
    }

    private func typeSelection() -> String? {
        guard typePopup.indexOfSelectedItem > 0 else { return nil }
        return typePopup.selectedItem?.title.lowercased()
    }

    private func masterySelection() -> MasteryBucket? {
        switch masteryPopup.indexOfSelectedItem {
        case 1: return .strong
        case 2: return .good
        case 3: return .fading
        case 4: return .forgotten
        case 5: return .fresh
        default: return nil
        }
    }

    private func dueSelection() -> NodeFilter.Due? {
        switch duePopup.indexOfSelectedItem {
        case 1: return .overdue
        case 2: return .today
        case 3: return .week
        default: return nil
        }
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
