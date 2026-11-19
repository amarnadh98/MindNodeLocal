import AppKit
import MapCore

/// ⌘K's link sheet (F-CNT-4): a URL field validated live against the
/// three allowed shapes — web (`https://…`), file (`/…` or `file://…`)
/// and Arbor deep links (`x-arbor://open?doc=…&node=…`). A scheme-less
/// entry is auto-prefixed with `https://`. Accepting applies ONE
/// grouped `setLink` over the selection.
@MainActor
enum LinkSheet {
    static func present(
        over window: NSWindow, current: String?, onAccept: @escaping (String) -> Void
    ) {
        let controller = LinkSheetController(current: current, onAccept: onAccept)
        controller.present(over: window)
    }
}

@MainActor
private final class LinkSheetController: NSViewController, NSTextFieldDelegate {
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let accept = NSButton(title: "Attach Link", target: nil, action: #selector(acceptTapped))
    private let onAccept: (String) -> Void
    private var raw: String

    init(current: String?, onAccept: @escaping (String) -> Void) {
        self.onAccept = onAccept
        self.raw = current ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present(over window: NSWindow) {
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 132)
        buildUI()
        validate()
        window.beginSheet(view.window!) { [weak self] response in
            if response == .OK, let self {
                self.onAccept(self.raw)
            }
        }
        field.window?.makeFirstResponder(field)
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "Link")
        title.font = .boldSystemFont(ofSize: 13)

        field.stringValue = raw
        field.placeholderString = "https://example.com · /path/to/file · x-arbor://open?node=…"
        field.delegate = self
        field.target = self
        field.action = #selector(acceptTapped)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        accept.bezelStyle = .rounded
        accept.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"

        for subview in [title, field, status, accept, cancel] {
            view.addSubview(subview)
        }
        var layout = view.frame
        title.frame = NSRect(x: 16, y: layout.height - 28, width: 80, height: 20)
        field.frame = NSRect(x: 16, y: layout.height - 60, width: layout.width - 32, height: 24)
        status.frame = NSRect(x: 16, y: layout.height - 82, width: layout.width - 32, height: 16)
        accept.frame = NSRect(x: layout.width - 116, y: 12, width: 100, height: 26)
        cancel.frame = NSRect(x: layout.width - 216, y: 12, width: 100, height: 26)
    }

    // MARK: validation

    /// What the sheet accepts for the current text: the raw string to
    /// store, or nil when invalid. A scheme-less entry becomes https.
    private func normalizedLink(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate =
            trimmed.contains("://") || trimmed.hasPrefix("/")
            ? trimmed
            : "https://" + trimmed
        guard ArborLink.parse(candidate) != nil else { return nil }
        return candidate
    }

    private func validate() {
        raw = field.stringValue
        if let link = normalizedLink(from: raw) {
            raw = link
            status.stringValue = statusText(for: link)
            status.textColor = .secondaryLabelColor
            accept.isEnabled = true
        } else {
            status.stringValue = "Enter a web, file or x-arbor:// link"
            status.textColor = .systemRed
            accept.isEnabled = false
        }
    }

    private func statusText(for link: String) -> String {
        switch ArborLink.parse(link) {
        case .web:
            "Web link"
        case .file:
            "File link"
        case .arbor(let docID, let nodeID):
            docID == nil && nodeID == nil
                ? "Arbor link"
                : "Arbor link — node jump"
        case nil:
            ""
        }
    }

    // MARK: actions

    @objc private func acceptTapped(_ sender: Any?) {
        guard normalizedLink(from: field.stringValue) != nil else { return }
        raw = normalizedLink(from: field.stringValue) ?? raw
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .OK)
    }

    @objc private func cancelTapped(_ sender: Any?) {
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .cancel)
    }

    func controlTextDidChange(_ obj: Notification) {
        validate()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            acceptTapped(control)
            return true
        }
        return false
    }
}
