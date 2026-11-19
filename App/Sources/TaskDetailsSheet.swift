import AppKit
import MapCore

/// F-TSK-3's per-task details: an optional due date (YYYY-MM-DD), a
/// priority 1–3 and a repeat rule (none/daily/weekly/monthly), applied
/// as ONE `setTaskDetails` command. Overdue chips and the inspector's
/// richer control come with the inspector slice; this sheet covers the
/// menu/keyboard path.
@MainActor
enum TaskDetailsSheet {
    static func present(
        over window: NSWindow, task: NodeTask?,
        onAccept: @escaping (String?, Int?, String?) -> Void
    ) {
        let controller = TaskDetailsSheetController(task: task, onAccept: onAccept)
        controller.present(over: window)
    }
}

@MainActor
private final class TaskDetailsSheetController: NSViewController, NSTextFieldDelegate {
    private let dueField = NSTextField()
    private let priorityPopup = NSPopUpButton()
    private let repeatPopup = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let onAccept: (String?, Int?, String?) -> Void
    private let original: NodeTask?

    init(task: NodeTask?, onAccept: @escaping (String?, Int?, String?) -> Void) {
        self.original = task
        self.onAccept = onAccept
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present(over window: NSWindow) {
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 190)
        buildUI()
        window.beginSheet(view.window!) { [weak self] response in
            guard response == .OK, let self else { return }
            self.onAccept(self.dueValue(), self.priorityValue(), self.repeatValue())
        }
        dueField.window?.makeFirstResponder(dueField)
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Task Details")
        title.font = .boldSystemFont(ofSize: 13)

        let dueLabel = NSTextField(labelWithString: "Due (YYYY-MM-DD)")
        dueField.placeholderString = "2026-12-01"
        dueField.stringValue = original?.due ?? ""
        dueField.delegate = self

        let priorityLabel = NSTextField(labelWithString: "Priority")
        for entry in ["None", "1 — High", "2 — Medium", "3 — Low"] {
            priorityPopup.addItem(withTitle: entry)
        }
        priorityPopup.selectItem(at: original?.priority ?? 0)

        let repeatLabel = NSTextField(labelWithString: "Repeat")
        for entry in ["None", "Daily", "Weekly", "Monthly"] {
            repeatPopup.addItem(withTitle: entry)
        }
        let rules = ["none", "daily", "weekly", "monthly"]
        if let repeatRule = original?.repeat, let slot = rules.firstIndex(of: repeatRule) {
            repeatPopup.selectItem(at: slot)
        } else {
            repeatPopup.selectItem(at: 0)
        }

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let accept = NSButton(title: "Apply", target: self, action: #selector(acceptTapped))
        accept.bezelStyle = .rounded
        accept.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"

        let width = view.frame.width
        title.frame = NSRect(x: 16, y: view.frame.height - 28, width: 200, height: 20)
        dueLabel.frame = NSRect(x: 16, y: view.frame.height - 54, width: 140, height: 16)
        dueField.frame = NSRect(x: 16, y: view.frame.height - 78, width: 150, height: 24)
        priorityLabel.frame = NSRect(x: 190, y: view.frame.height - 54, width: 140, height: 16)
        priorityPopup.frame = NSRect(x: 190, y: view.frame.height - 78, width: 150, height: 26)
        repeatLabel.frame = NSRect(x: 16, y: view.frame.height - 110, width: 140, height: 16)
        repeatPopup.frame = NSRect(x: 16, y: view.frame.height - 134, width: 150, height: 26)
        status.frame = NSRect(x: 16, y: view.frame.height - 158, width: width - 32, height: 16)
        accept.frame = NSRect(x: width - 116, y: 12, width: 100, height: 26)
        cancel.frame = NSRect(x: width - 216, y: 12, width: 100, height: 26)

        for subview in [
            title, dueLabel, dueField, priorityLabel, priorityPopup, repeatLabel, repeatPopup, status, accept, cancel,
        ] {
            view.addSubview(subview)
        }
    }

    // MARK: values

    private func dueValue() -> String? {
        let raw = dueField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return Self.isValidDueDate(raw) ? raw : nil
    }

    private func priorityValue() -> Int? {
        let selected = priorityPopup.indexOfSelectedItem
        return selected > 0 ? selected : nil
    }

    private func repeatValue() -> String? {
        let rules = ["none", "daily", "weekly", "monthly"]
        let selected = repeatPopup.indexOfSelectedItem
        return selected > 0 ? rules[selected] : nil
    }

    /// `YYYY-MM-DD` (the §8.2 storage shape).
    static func isValidDueDate(_ raw: String) -> Bool {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
            let year = Int(parts[0]), parts[0].count == 4,
            let month = Int(parts[1]), parts[1].count == 2,
            let day = Int(parts[2]), parts[2].count == 2,
            (1...12).contains(month), (1...31).contains(day), year > 0
        else { return false }
        return true
    }

    // MARK: actions

    @objc private func acceptTapped(_ sender: Any?) {
        let raw = dueField.stringValue.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty, !Self.isValidDueDate(raw) {
            status.stringValue = "Due date must be YYYY-MM-DD"
            status.textColor = .systemRed
            return
        }
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .OK)
    }

    @objc private func cancelTapped(_ sender: Any?) {
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .cancel)
    }
}
