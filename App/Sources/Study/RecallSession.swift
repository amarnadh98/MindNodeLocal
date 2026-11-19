import AppKit
import CanvasKit
import MapCore
import MapStudy

/// F-STD-5 — recall mode on the canvas: the selected branch's
/// descendants hide behind blurred placeholders (outlines visible), a
/// click or → reveals one at a time, ⌥-click reveals the subtree, and
/// 1/2 mark the last revealed node ✓ remembered / ✗ forgot — which
/// feeds FSRS Good/Again for that node's card through the document's
/// NON-undoable grading path (ADR-0015). Esc exits.
///
/// The mode is **view state**: a `RevealOverlay` on the existing
/// layer tree (opacity + the M7 placeholder blur, never a re-raster)
/// plus a transparent input shield over the canvas — the pattern the
/// presentation surface uses — so no canvas gesture can select or
/// edit anything mid-recall, and the document never dirties except
/// through grading. The pure reveal logic is `MapStudy.RecallMachine`;
/// this class is the AppKit wiring only.
@MainActor
final class RecallSession {
    private weak var controller: DocumentWindowController?
    private var machine: RecallMachine
    private let branchTitle: String
    private let shield = RecallShield()
    private let hud = RecallHUDView()
    /// The node the next ✓/✗ applies to (the most recent reveal).
    private var lastRevealed: String?

    /// Nil when the branch has no visible descendants to recall.
    init?(controller: DocumentWindowController, branchID: String) {
        guard let document = controller.document as? MapDocument,
            let scene = controller.canvas.scene
        else { return nil }
        let machine = RecallMachine(
            model: document.model,
            branchID: branchID,
            visible: { scene.nodes[$0] != nil })
        guard !machine.order.isEmpty else { return nil }
        self.controller = controller
        self.machine = machine
        self.branchTitle = document.model.nodes[branchID]?.title.text ?? ""
    }

    // MARK: lifecycle

    func start() {
        guard let controller else { return }
        let canvas = controller.canvas
        applyOverlay()
        shield.frame = canvas.bounds
        shield.autoresizingMask = [.width, .height]
        shield.onEvent = { [weak self] event in self?.handle(event) }
        canvas.addSubview(shield)
        hud.place(above: canvas)
        updateHUD()
        controller.window?.makeFirstResponder(shield)
    }

    /// Exits the mode: overlay and chrome gone, the canvas first
    /// responder again. Safe to call twice.
    func stop() {
        guard let controller else { return }
        controller.canvas.setRevealOverlay(nil)
        shield.removeFromSuperview()
        hud.removeFromSuperview()
        if controller.recallSessionBox === self {
            controller.recallSessionBox = nil
        }
        controller.window?.makeFirstResponder(controller.canvas)
    }

    var isActive: Bool { controller?.recallSessionBox === self }

    // MARK: events (shield → here; internal so hosted tests drive the
    // same entry point the shield uses, without synthesizing NSEvents)

    func handle(_ event: RecallEvent) {
        switch event {
        case .revealNext:
            reveal([machine.revealNext()].compactMap { $0 })
        case .click(let point, let option):
            guard let id = controller?.canvas.nodeID(at: point),
                machine.states()[id] == .placeholder
            else { return }
            if option {
                reveal(machine.revealSubtree(id: id))
            } else {
                reveal(machine.reveal(id: id) ? [id] : [])
            }
        case .remembered:
            mark(remembered: true)
        case .forgot:
            mark(remembered: false)
        case .exit:
            stop()
        }
    }

    /// Applies the machine's new states and animates exactly the ids
    /// that just became visible (the §7.6 reveal build motion: fade +
    /// 8 pt slide, instant under Reduce Motion).
    private func reveal(_ fresh: [String]) {
        guard let controller, !fresh.isEmpty else { return }
        applyOverlay()
        controller.canvas.revealNodes(
            fresh, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        lastRevealed = fresh.last
        updateHUD()
    }

    private func applyOverlay() {
        controller?.canvas.setRevealOverlay(RevealOverlay(states: machine.states()))
    }

    /// Keys 1/2 (F-STD-5): the mark feeds FSRS as Good/Again for the
    /// node's basic card **if the node is one** (the branch session's
    /// implicit-deck scope, ADR-0015) — through the document's
    /// non-undoable grading write, the same path the study session
    /// uses. A non-card node is session feedback only: no FSRS write,
    /// no dirtying.
    private func mark(remembered: Bool) {
        guard let document = controller?.document as? MapDocument else { return }
        guard let id = lastRevealed else {
            hud.showMarkHint()
            return
        }
        let title = document.model.nodes[id]?.title.text ?? ""
        let card = machine.markingTarget(for: id)
        if let card {
            document.grade(card: card, grade: remembered ? .good : .again)
        }
        lastRevealed = nil
        hud.showMark(remembered: remembered, title: title, gradedCard: card != nil)
    }

    // MARK: HUD

    private func updateHUD() {
        let revealed = machine.order.count - machine.remainingCount
        hud.showProgress(
            branch: branchTitle, revealed: revealed, total: machine.order.count,
            complete: machine.isComplete)
    }
}

/// Every input the recall surface can produce. Pure data so hosted
/// tests drive the session without synthesizing NSEvents.
enum RecallEvent: Equatable, Sendable {
    case revealNext
    case click(point: CGPoint, option: Bool)
    case remembered
    case forgot
    case exit
}

/// The recall keys (F-STD-5): → reveal, 1 ✓, 2 ✗, ⎋ exit.
enum RecallKey: Equatable, Sendable {
    case revealNext
    case remembered
    case forgot
    case exit
    case unknown

    /// Pure event→key translation (nonisolated so tests and the
    /// shield stay headless about AppKit state).
    nonisolated static func key(for event: NSEvent) -> RecallKey {
        let characters = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty || modifiers == .shift else { return .unknown }
        switch characters {
        case "\u{f703}": return .revealNext  // →
        case "1": return .remembered
        case "2": return .forgot
        case "\u{1b}": return .exit
        default: return .unknown
        }
    }
}

/// The transparent input shield (the presentation surface's pattern):
/// full-cover over the canvas so recall can never select or edit
/// anything, translating clicks and keys into `RecallEvent`s. Pan
/// and pinch still reach the canvas — the branch may not fit the
/// viewport, and panning never mutates anything.
@MainActor
final class RecallShield: NSView {
    var onEvent: ((RecallEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = nil
        setAccessibilityLabel(Self.instructions)
    }

    /// VoiceOver reads the recall contract once, on entering the mode.
    nonisolated static let instructions: String =
        "Recall mode. The branch's answers are hidden. "
        + "Click a blurred placeholder to reveal it, or press the Right arrow to reveal the next one. "
        + "Hold Option and click to reveal a whole subtree. "
        + "Press 1 to mark the revealed node remembered, 2 to mark it forgot. Press Escape to exit."

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    /// The recall keys are consumed here, before the menu bar's key
    /// equivalents (Select ▸ Deselect owns a bare-⎋ equivalent, and
    /// AppKit offers menu matches only when the responder chain
    /// declined the key first).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch RecallKey.key(for: event) {
        case .unknown: return false
        case let key:
            onEvent?(recallEvent(from: key))
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        // The performKeyEquivalent pass above usually wins; keyDown
        // stays as the belt-and-braces path for direct test driving.
        switch RecallKey.key(for: event) {
        case .unknown: super.keyDown(with: event)
        case let key: onEvent?(recallEvent(from: key))
        }
    }

    private func recallEvent(from key: RecallKey) -> RecallEvent {
        switch key {
        case .revealNext: .revealNext
        case .remembered: .remembered
        case .forgot: .forgot
        case .exit: .exit
        case .unknown: .exit  // unreachable: callers never pass unknown
        }
    }

    // MARK: mouse → clicks on placeholders; pan/zoom reach the canvas

    override func mouseDown(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        onEvent?(.click(point: convert(event.locationInWindow, from: nil), option: option))
    }

    override func scrollWheel(with event: NSEvent) {
        (superview as? CanvasView)?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        (superview as? CanvasView)?.magnify(with: event)
    }
}

/// The recall mode's floating status line (top-centre of the canvas):
/// progress while revealing, the mark feedback after 1/2, and the
/// standing key hints. A standalone accessibility element so
/// VoiceOver reads the recall state without touching the covered
/// canvas rows.
@MainActor
final class RecallHUDView: NSView {
    private let label = NSTextField(labelWithString: "")

    static let width: CGFloat = 480
    static let height: CGFloat = 64
    static let margin: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addSubview(label)
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Installs the HUD at the top-centre of `canvas`.
    func place(above canvas: NSView) {
        frame = NSRect(
            x: (canvas.bounds.width - Self.width) / 2,
            y: Self.margin,
            width: Self.width,
            height: Self.height)
        autoresizingMask = [.minXMargin, .maxXMargin]
        canvas.addSubview(self)
        layoutLabel()
    }

    override func layout() {
        super.layout()
        layoutLabel()
    }

    private func layoutLabel() {
        label.frame = NSRect(
            x: 8, y: (bounds.height - labelFittingHeight) / 2,
            width: bounds.width - 16, height: labelFittingHeight)
    }

    private var labelFittingHeight: CGFloat {
        let bounding = label.attributedStringValue.boundingRect(
            with: NSSize(width: max(bounds.width - 16, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        return ceil(bounding.height)
    }

    // MARK: content

    func showProgress(branch: String, revealed: Int, total: Int, complete: Bool) {
        let status =
            complete
            ? "All \(total) revealed — ⎋ exits recall"
            : "Recall \(branch.isEmpty ? "" : "· \(branch) · ")\(revealed) of \(total) revealed"
        set(
            status: status,
            detail: "Click a blurred node or press → to reveal · ⌥-click reveals a subtree · "
                + "1 ✓ remembered · 2 ✗ forgot · ⎋ exit")
    }

    func showMark(remembered: Bool, title: String, gradedCard: Bool) {
        let mark = remembered ? "✓" : "✗"
        let word = remembered ? "remembered" : "forgot"
        let grading = gradedCard ? (remembered ? " · graded Good" : " · graded Again") : ""
        let name = title.isEmpty ? "Node" : "“\(title)”"
        set(status: "\(mark) \(name) \(word)\(grading)", detail: "")
    }

    /// 1/2 with nothing revealed yet: the mark needs a target.
    func showMarkHint() {
        set(status: "Nothing to mark yet — reveal a node first (click or →)", detail: "")
    }

    private func set(status: String, detail: String) {
        let statusParagraph = NSMutableParagraphStyle()
        statusParagraph.alignment = .center
        let text = NSMutableAttributedString(
            string: status,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .paragraphStyle: statusParagraph,
            ])
        if !detail.isEmpty {
            text.append(
                NSAttributedString(
                    string: "\n\(detail)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: statusParagraph,
                    ]))
        }
        label.attributedStringValue = text
        setAccessibilityLabel(detail.isEmpty ? status : "\(status). \(detail)")
        needsLayout = true
    }
}
