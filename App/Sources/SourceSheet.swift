import AppKit
import MapCore

/// F-CNT-8's source sheet (Format ▸ Source…): a URL plus the optional
/// page, timestamp and quoted excerpt. One commit — ONE `setSource`
/// on every selected node as a single undoable group. Hosted AppKit
/// (the LinkSheet pattern).
@MainActor
enum SourceSheet {
    static func present(
        over window: NSWindow, current: SourceRef?,
        onCommit: @escaping (SourceRef?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Source Anchor"
        alert.informativeText =
            "Where this idea came from. A page, timestamp and excerpt are optional."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        func row(label: String, width: CGFloat = 320) -> (NSStackView, NSTextField) {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.setAccessibilityLabel(label)
            let title = NSTextField(labelWithString: label)
            title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            let horizontal = NSStackView(views: [title, field])
            horizontal.orientation = .horizontal
            horizontal.spacing = 6
            return (horizontal, field)
        }

        let (urlRow, urlField) = row(label: "URL")
        let (pageRow, pageField) = row(label: "Page", width: 60)
        let (timeRow, timeField) = row(label: "Time (s)", width: 60)
        let (excerptRow, excerptField) = row(label: "Excerpt")
        excerptField.lineBreakMode = .byWordWrapping

        urlField.stringValue = current?.url ?? ""
        pageField.stringValue = current?.page.map(String.init) ?? ""
        timeField.stringValue = current?.time.map { String(format: "%.1f", $0) } ?? ""
        excerptField.stringValue = current?.excerpt ?? ""

        for element in [urlRow, pageRow, timeRow, excerptRow] {
            stack.addArrangedSubview(element)
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ])
        alert.accessoryView = container
        alert.window.initialFirstResponder = urlField

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                onCommit(nil)
                return
            }
            let source = SourceRef(
                url: url,
                page: Int(pageField.stringValue.trimmingCharacters(in: .whitespaces)),
                time: Double(timeField.stringValue.trimmingCharacters(in: .whitespaces)),
                excerpt: excerptField.stringValue.isEmpty ? nil : excerptField.stringValue)
            onCommit(source)
        case .alertSecondButtonReturn:
            onCommit(nil)
        default:
            break
        }
    }
}
