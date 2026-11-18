import AppKit

@MainActor
final class DocumentWindowController: NSWindowController {
    private let placeholder = PlaceholderCanvasView()

    init(document: NSDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = document.displayName
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = placeholder
        super.init(window: window)
        self.document = document
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class PlaceholderCanvasView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.stringValue = "Arbor M0 — the canvas arrives in M1"
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}
