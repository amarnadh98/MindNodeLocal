import AppKit
import CanvasKit
import MapCore

/// The outline row view: draws one indent guide per ancestor level at
/// the outline's per-level indent (F-OUT-2), on top of AppKit's own
/// selection drawing.
@MainActor
final class OutlineRowView: NSTableRowView {
    var depth = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard depth > 0 else { return }
        let indent = OutlineViewController.indentPerLevel
        let guide = NSColor.separatorColor.withAlphaComponent(0.55)
        guide.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        // A guide at each ancestor's nesting column, through the full
        // row height.
        for level in 1...depth {
            let x = (indent * CGFloat(level)).rounded() - 6
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
        }
        path.stroke()
    }
}

/// One outline row's content (F-OUT-2): the title as an attributed
/// string (bold/italic/underline preserved from the `NodeTitle` runs —
/// the same conversion the canvas editor uses, `NodeTitleText`) and
/// trailing placeholders where the model has data (note, link, tags).
@MainActor
final class OutlineRowCellView: NSTableCellView {
    private let noteIcon = OutlineRowCellView.symbolView("note.text")
    private let linkIcon = OutlineRowCellView.symbolView("link")
    private let tagsIcon = OutlineRowCellView.symbolView("tag")

    static let cellIdentifier = NSUserInterfaceItemIdentifier("outline.row.cell")
    private static let indicatorsWidth: CGFloat = 66

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width]

        let title = NSTextField(labelWithString: "")
        title.font = OutlineViewController.titleFont
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false
        title.identifier = NSUserInterfaceItemIdentifier("title")
        textField = title
        addSubview(title)

        let stack = NSStackView(views: [noteIcon, linkIcon, tagsIcon])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 2
        stack.orientation = .horizontal
        addSubview(stack)

        NSLayoutConstraint.activate([
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Configures for `node`: the attributed title plus the trailing
    /// placeholders the node's data warrants.
    func configure(node: Node) {
        let attributed = NodeTitleText.attributed(
            node.title,
            baseFont: OutlineViewController.titleFont,
            baseColor: .labelColor)
        textField?.attributedStringValue = attributed
        noteIcon.isHidden = (node.note ?? "").isEmpty
        linkIcon.isHidden = node.link == nil
        tagsIcon.isHidden = (node.tags ?? []).isEmpty
    }

    private static func symbolView(_ symbol: String) -> NSImageView {
        let view = NSImageView()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        view.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: symbol.replacingOccurrences(of: ".", with: " ")
        )?.withSymbolConfiguration(configuration)
        view.contentTintColor = .tertiaryLabelColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 13).isActive = true
        return view
    }
}
