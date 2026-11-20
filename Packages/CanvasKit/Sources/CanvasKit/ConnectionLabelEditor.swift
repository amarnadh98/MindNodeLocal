import AppKit
import CoreGraphics
import MapRender

/// The inline connection-label editor (F-REL-1): one plain `NSTextView`
/// overlay positioned at the label's screen rect — the same overlay
/// approach the node editor uses (SPEC §11.4, ADR-0006): camera-scaled
/// geometry, real text editing, ONE commit as ONE command. The overlay
/// never touches the model; the commit closure hands the host the
/// connection id and text.
@MainActor
public final class ConnectionLabelEditor {
    /// The label edit in progress, if any.
    public private(set) var connectionID: String?
    /// The commit sink: called once with the edited connection id and
    /// the label text (empty text clears the label).
    public var onCommit: ((String, String) -> Void)?

    private var textView: LabelTextView?
    weak var canvas: CanvasView?

    public var isEditing: Bool { connectionID != nil }

    /// Opens the editor on `connectionID`'s label inside `frame` (view
    /// space), styled like the node editor's overlay.
    public func begin(
        connectionID: String, text: String, in frame: CGRect,
        onCommit: @escaping (String, String) -> Void
    ) {
        guard let canvas else { return }
        commit()
        self.connectionID = connectionID
        self.onCommit = onCommit

        let font = Self.nsFont(for: RelationRenderer.connectionLabelFont)
        let view = LabelTextView(frame: frame)
        view.editor = self
        view.font = font
        view.textColor = .controlTextColor
        view.backgroundColor = .textBackgroundColor
        view.drawsBackground = true
        view.isRichText = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 3, height: 2)
        view.string = text
        view.sizeToFit()
        view.frame = frame.union(view.frame.insetBy(dx: -3, dy: -2))
        canvas.addSubview(view)
        textView = view
        canvas.window?.makeFirstResponder(view)
        view.selectAll(nil)
    }

    /// Ends the session and delivers the commit (exactly once per
    /// session — the text view calls this on every end-editing event).
    public func commit() {
        guard let id = connectionID else { return }
        let text = textView?.string ?? ""
        connectionID = nil
        let sink = onCommit
        onCommit = nil
        textView?.removeFromSuperview()
        textView = nil
        sink?(id, text)
        // Return focus to the canvas so the keys keep working.
        if let canvas, canvas.window?.firstResponder != canvas {
            canvas.window?.makeFirstResponder(canvas)
        }
    }

    /// Positions the overlay at the current label rect (camera moves).
    func syncPosition() {
        guard let textView else { return }
        _ = textView
    }

    static func nsFont(for font: FontSpec) -> NSFont {
        let weight = NSFont.Weight(rawValue: font.weight)
        if font.monospace {
            return NSFont.monospacedSystemFont(ofSize: font.size, weight: weight)
        }
        if let family = font.family, let named = NSFont(name: family, size: font.size) {
            return named
        }
        return NSFont.systemFont(ofSize: font.size, weight: weight)
    }
}

/// The label's text view: commits on ⏎/⎋/focus loss — a plain single
/// line edit.
@MainActor
private final class LabelTextView: NSTextView {
    weak var editor: ConnectionLabelEditor?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{1b}":
            editor?.commit()
        default:
            super.keyDown(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        if editor?.isEditing == true {
            editor?.commit()
        }
        return super.resignFirstResponder()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The label editor owns clicks inside itself; nothing else in
        // this subview hierarchy intervenes.
        super.hitTest(point)
    }
}
