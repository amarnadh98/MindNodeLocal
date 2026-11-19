import AppKit
import CoreGraphics
import MapCore
import MapRender

/// The single inline editing overlay (SPEC §11.4): one TextKit 2
/// `NSTextView` positioned at the editing node's screen rect and styled
/// from the node's resolved theme style, so the live text is identical to
/// the committed node.
///
/// Typing never touches the model. The live text is converted to a draft
/// `NodeTitle` on every change and handed to the host
/// (`onDraftChange`), which rebuilds the scene through the shared
/// `TextMeasurer` — the node grows exactly as it will after commit
/// (F-EDT-8). One commit is one `editText` command; the host ends the
/// store's edit session so each editing session is one undo step
/// (F-DOC-2).
///
/// While an input method session is active (`hasMarkedText()`), every
/// editing key is routed into the text input system instead: ⏎ confirms
/// the composition and must never commit or create a sibling (F-EDT-15,
/// a known MindNode bug this spec explicitly forbids).
@MainActor
public final class NodeTextEditor {
    /// What to do after the current edit commits (F-EDT-1: while editing,
    /// ⇥/⏎ commit *and* create).
    public enum PostCommitAction: Equatable, Sendable {
        case none
        case child
        case siblingBelow
        case siblingAbove
        case insertParent
    }

    /// The routing decision for one key event.
    public enum KeyDecision: Equatable, Sendable {
        /// The input method owns the event; no commit, no create.
        case passToInputMethod
        /// ⌘⏎ or ⎋: commit, nothing else.
        case commit
        /// ⏎/⇥/⌥⏎/⌥⇥: commit, then create.
        case commitAndCreate(PostCommitAction)
        /// ⇧⏎ inside the text: a line break in the title.
        case insertLineBreak
    }

    /// The host performs the commit: ONE `editText` command through the
    /// `MapStore`, then the create action (if any). Called after the
    /// overlay has already been torn down.
    public var onCommit: ((String, NodeTitle, PostCommitAction) -> Void)?

    /// The live draft on every text change; the host rebuilds the scene
    /// with it and the overlay re-positions at the grown node.
    public var onDraftChange: ((String, NodeTitle) -> Void)?

    public internal(set) weak var canvas: CanvasView?
    public private(set) var editingNodeID: String?
    public private(set) var placeholder: String?

    /// The overlay's text view while a session is open.
    private(set) var textView: EditingTextView?
    private var baseFont: NSFont?
    private var baseColor: NSColor?
    private var isCommitting = false

    public var isEditing: Bool { editingNodeID != nil }

    // MARK: key routing (pure — also the headless IME-test surface)

    /// Decides what one key event means for the editing session. Pure:
    /// the view supplies its real `hasMarkedText()`, tests supply a
    /// simulated one.
    public static func decide(
        key: String,
        command: Bool,
        option: Bool,
        shift: Bool,
        hasMarkedText: Bool
    ) -> KeyDecision? {
        guard !hasMarkedText else {
            // During an IME composition every editing key belongs to the
            // input method (F-EDT-15): ⏎ confirms, ⎋ cancels, ⇥ navigates
            // candidates — none of them may commit or create.
            return isEditingKey(key: key, command: command, option: option, shift: shift)
                ? .passToInputMethod : nil
        }
        switch (key, command, option, shift) {
        case ("\r", true, false, _):
            return .commit
        case ("\r", false, false, false):
            return .commitAndCreate(.siblingBelow)
        case ("\r", false, false, true):
            return .insertLineBreak
        case ("\r", false, true, false):
            return .commitAndCreate(.siblingAbove)
        case ("\t", false, false, false):
            return .commitAndCreate(.child)
        case ("\t", false, true, false):
            return .commitAndCreate(.insertParent)
        case ("\u{1b}", false, false, false):
            return .commit
        default:
            return nil
        }
    }

    /// Whether the key is one the editing session owns (so its marked
    /// text variant must be swallowed before the menu sees ⏎/⇥/⎋ as key
    /// equivalents and, say, "Add Sibling" fires mid-composition).
    static func isEditingKey(key: String, command: Bool, option: Bool, shift: Bool) -> Bool {
        switch (key, command, option, shift) {
        case ("\r", _, false, _), ("\t", false, _, false), ("\u{1b}", false, false, false):
            return true
        default:
            return false
        }
    }

    // MARK: session lifecycle

    /// Opens the editing overlay on `nodeID`. `prefill` (F-EDT-2:
    /// spreadsheet-style replace) replaces the text and puts the caret
    /// after it; without it, the whole title is selected (F-EDT-2).
    public func beginEditing(nodeID: String, placeholder: String? = nil, prefill: String? = nil) {
        guard let canvas, let scene = canvas.scene, let node = scene.nodes[nodeID] else { return }
        if editingNodeID != nil {
            endSession()
        }

        editingNodeID = nodeID
        self.placeholder = placeholder
        let font = Self.nsFont(for: node.style.font)
        let color = NSColor(cgColor: node.style.textColor) ?? NSColor.labelColor
        baseFont = font
        baseColor = color

        let view = EditingTextView(frame: .zero)
        view.editor = self
        configure(view)
        view.placeholderText = placeholder
        view.placeholderAttributes = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(0.35),
        ]
        canvas.addSubview(view)
        textView = view

        let title = prefill.map { NodeTitle(text: $0) } ?? node.title
        let attributed = NodeTitleText.attributed(title, baseFont: font, baseColor: color)
        view.textStorage?.setAttributedString(attributed)
        view.typingAttributes =
            attributed.length > 0
            ? attributed.attributes(at: 0, effectiveRange: nil)
            : Self.baseAttributes(font: font, color: color)
        if prefill == nil {
            view.selectAll(nil)
        } else {
            view.selectedRange = NSRange(location: attributed.length, length: 0)
        }

        syncPosition()
        canvas.window?.makeFirstResponder(view)
        canvas.needsDisplay = true
    }

    private func configure(_ view: EditingTextView) {
        // A real NSTextView: spell check, autocorrect, Writing Tools,
        // dictation and the emoji picker all work (F-EDT-15) — nothing
        // here disables them.
        view.drawsBackground = false
        view.isRichText = true
        view.allowsUndo = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = []
    }

    /// Tears the overlay down without committing (the editing node keeps
    /// its committed title).
    public func cancel() {
        endSession()
    }

    /// Commits the live text as ONE `editText` command (via `onCommit`),
    /// then asks the host for the post-commit create. An empty commit of
    /// a brand-new node keeps the node — MindNode behaviour; the
    /// "Central Idea" hint is a placeholder, not text (ADR-0006).
    public func commit(next: PostCommitAction = .none) {
        guard let id = editingNodeID, !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }
        let title = currentTitle() ?? NodeTitle(text: "")
        endSession()
        onCommit?(id, title, next)
    }

    /// The live draft title of the session (nil when not editing).
    public func currentTitle() -> NodeTitle? {
        guard let view = textView, let font = baseFont, let color = baseColor else { return nil }
        guard let storage = view.textStorage else { return nil }
        return NodeTitleText.title(from: storage, baseFont: font, baseColor: color)
    }

    private func endSession() {
        let view = textView
        textView = nil
        editingNodeID = nil
        placeholder = nil
        baseFont = nil
        baseColor = nil
        if let view, let canvas {
            // Clear the session before the resign notifications fire, so
            // the text view's own textDidEndEditing can't commit twice.
            if canvas.window !== nil {
                canvas.window?.makeFirstResponder(canvas)
            }
            view.removeFromSuperview()
            canvas.needsDisplay = true
        }
    }

    /// Called by the text view after any text change: publishes the draft
    /// for the host's live relayout (F-EDT-8).
    func textDidChange() {
        guard let id = editingNodeID else { return }
        onDraftChange?(id, currentTitle() ?? NodeTitle(text: ""))
    }

    /// Commits when the overlay loses focus for a reason the canvas did
    /// not mediate (window switch, toolbar click-away).
    func sessionEndedByFocusLoss() {
        if editingNodeID != nil {
            commit(next: .none)
        }
    }

    func dispatch(_ decision: KeyDecision) {
        switch decision {
        case .passToInputMethod:
            break  // the view routes the event itself; never dispatched
        case .commit:
            commit(next: .none)
        case .commitAndCreate(let next):
            commit(next: next)
        case .insertLineBreak:
            insertLineBreak()
        }
    }

    // MARK: overlay geometry

    /// Re-positions the overlay at the editing node's current screen
    /// rect. Runs on every camera change (pan/zoom) and scene rebuild
    /// (live growth), so the overlay tracks the node (SPEC §11.4).
    public func syncPosition() {
        guard let canvas, let id = editingNodeID, let view = textView,
            let node = canvas.scene?.nodes[id]
        else { return }
        let camera = canvas.camera
        let scale = camera.scale
        let frame = node.frame

        // The wrap width the measurer used (SceneGeometry): the node's
        // fixed width, else the theme max width (F-EDT-8: auto-width up to
        // max, then wrap).
        let wrapWidth: CGFloat
        if node.width?.mode == .fixed, let fixed = node.width?.value {
            wrapWidth = fixed
        } else {
            wrapWidth = node.style.maxWidth
        }

        // Reproduce NodeRenderer.drawTitle's placement: the measured text
        // block, centered inside the padded content rect. Auto-width
        // nodes hug their text, so the centering offsets are 0 and the
        // block sits at the content rect's top-left.
        let draft = currentTitle() ?? node.title
        let measured = SceneRenderer.sharedMeasurer.nodeTitleSize(
            draft, font: node.style.font, maxWidth: wrapWidth)
        let contentWidth = frame.width - 2 * node.style.paddingWidth
        let contentHeight = frame.height - 2 * node.style.paddingHeight
        let blockOrigin = CGPoint(
            x: frame.minX + node.style.paddingWidth + max(0, (contentWidth - measured.width) / 2),
            y: frame.minY + node.style.paddingHeight + max(0, (contentHeight - measured.height) / 2)
        )

        // Growth room: the full wrap width, so typing never wraps early.
        // Point sizes scale with the camera (no view transform), so text
        // renders crisp at every zoom; layout wraps identically.
        let origin = camera.screenPoint(for: blockOrigin)
        view.frame = NSRect(
            x: (origin.x).rounded(),
            y: (origin.y).rounded(),
            width: wrapWidth * scale,
            height: max(measured.height * scale + 4, frame.height * scale))

        // Hit-testing stays confined to the node: clicks inside place the
        // caret, clicks outside pass through to the canvas (commit and
        // select). The bounds live in the canvas's flipped coordinates.
        let nodeScreen = NSRect(
            origin: camera.screenPoint(for: frame.origin),
            size: CGSize(width: frame.width * scale, height: frame.height * scale))
        view.editingNodeBounds = nodeScreen.insetBy(dx: -2, dy: -2)
    }

    /// Ends the session if the scene rebuild dropped the editing node,
    /// otherwise re-positions at its new frame.
    public func reconcileWithScene() {
        guard let id = editingNodeID, let canvas else { return }
        if canvas.scene?.nodes[id] == nil {
            endSession()
        } else {
            syncPosition()
        }
    }

    // MARK: editing commands (host + test surface)

    /// Inserts text at the caret (typing entry point; also how the app
    /// forwards a ⇧⏎ line break, F-EDT-1).
    public func insertText(_ text: String) {
        guard let view = textView else { return }
        view.insertText(text, replacementRange: view.selectedRange())
    }

    public func insertLineBreak() {
        insertText("\n")
    }

    public func selectAllText() {
        textView?.selectAll(nil)
    }

    public func deleteInEditor(forward: Bool) {
        guard let view = textView else { return }
        if forward {
            view.deleteForward(nil)
        } else {
            view.deleteBackward(nil)
        }
    }

    // MARK: style helpers

    static func baseAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// `NSFont` for a theme `FontSpec`. The weight constants match
    /// (NSFont.Weight raw values are the CoreText weights), so the
    /// overlay's font is the same font the measurer laid out with.
    static func nsFont(for spec: FontSpec) -> NSFont {
        if spec.monospace {
            return NSFont(name: "Menlo-Regular", size: spec.size) ?? NSFont.systemFont(ofSize: spec.size)
        }
        if let family = spec.family {
            return NSFont(name: family, size: spec.size) ?? NSFont.systemFont(ofSize: spec.size)
        }
        let weight = NSFont.Weight(rawValue: spec.weight)
        let base = NSFont.systemFont(ofSize: spec.size, weight: weight)
        guard spec.italic else { return base }
        let traits = base.fontDescriptor.symbolicTraits.union(.italic)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 0) ?? base
    }
}

/// The overlay's text view: a real TextKit 2 `NSTextView` (created without
/// a TextKit 1 text container, the default adoption path) so spell check,
/// autocorrect, Writing Tools, dictation and the emoji picker all work
/// (F-EDT-15). Claims the editing keys via `performKeyEquivalent` so the
/// menu's ⇥/⏎/⎋ key equivalents can't fire "Add Child" mid-composition,
/// and confines hit-testing to the node so the overlay's growth room never
/// eats canvas clicks.
@MainActor
final class EditingTextView: NSTextView {
    var editor: NodeTextEditor?
    /// Typing undo is internal to the edit session: it must never land on
    /// the document's undo manager, where it would shadow the commit's
    /// single `editText` step (F-DOC-2). The private manager (and its
    /// stack) dies with the session.
    private let sessionUndoManager = UndoManager()
    override var undoManager: UndoManager? { sessionUndoManager }
    /// Test seam: pretend an input-method session is active (F-EDT-15).
    var simulateMarkedText = false
    /// The editing node's screen rect; clicks outside it reach the canvas.
    var editingNodeBounds: NSRect?
    var placeholderText: String?
    var placeholderAttributes: [NSAttributedString.Key: Any]?

    // MARK: key routing

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let decision = editorDecision(for: event) {
            switch decision {
            case .passToInputMethod:
                // Bypass the menu (which owns ⏎/⇥/⎋ equivalents) and feed
                // the text input system, so the IME sees the key.
                keyDown(with: event)
            case .commit, .commitAndCreate, .insertLineBreak:
                editor?.dispatch(decision)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // The belt-and-braces path: if the event reaches keyDown without
        // the menu claiming it, the editing keys still behave.
        if let decision = editorDecision(for: event), decision != .passToInputMethod {
            editor?.dispatch(decision)
            return
        }
        super.keyDown(with: event)
    }

    private func editorDecision(for event: NSEvent) -> NodeTextEditor.KeyDecision? {
        guard editor != nil, let key = event.characters, key.count == 1 else { return nil }
        let flags = event.modifierFlags
        return NodeTextEditor.decide(
            key: key,
            command: flags.contains(.command),
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            hasMarkedText: simulateMarkedText || hasMarkedText())
    }

    // MARK: commit on focus loss

    override func resignFirstResponder() -> Bool {
        // The canvas mediates click-away commits itself; this catches the
        // other resigns (window switch, another view taking focus).
        editor?.sessionEndedByFocusLoss()
        return super.resignFirstResponder()
    }

    // MARK: live draft

    override func didChangeText() {
        super.didChangeText()
        editor?.textDidChange()
    }

    // MARK: hit confinement

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let bounds = editingNodeBounds else { return super.hitTest(point) }
        // The overlay is wider than the node (growth room): confine
        // hit-testing to the node's rect so clicks inside place the caret
        // (even in the padding band left of the text frame) and clicks
        // outside pass through to the canvas (commit + select).
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    // MARK: placeholder hint (F-CAN-3: a hint, never committed text)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let text = placeholderText, let attributes = placeholderAttributes,
            string.isEmpty, !hasMarkedText()
        else { return }
        // Sit the hint inside the same first-line box the caret occupies
        // (1.25 multiple, like the measurer).
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        let lineHeight = (font.ascender + abs(font.descender)) * 1.25
        let offset = max(0, (lineHeight - (font.ascender + abs(font.descender))) / 2)
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: NSPoint(x: 0, y: offset))
    }

    // MARK: Format menu (F-EDT-7): ⌘B/⌘I/⌘U toggle the selected run,
    // mapped back to NodeTitle runs restricted to the §8.3 allow-list.

    @objc func toggleBoldAction(_ sender: Any?) {
        toggleFontTrait(.bold)
    }

    @objc func toggleItalicAction(_ sender: Any?) {
        toggleFontTrait(.italic)
    }

    @objc func toggleUnderlineAction(_ sender: Any?) {
        toggleUnderline()
    }

    private func toggleFontTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        let mask: NSFontTraitMask = trait == .bold ? .boldFontMask : .italicFontMask
        let hasTrait: (NSFont) -> Bool = { NSFontManager.shared.traits(of: $0).contains(mask) }

        let range = selectedRange()
        if range.length == 0 {
            // Caret only: toggle the typing font so the next keystroke
            // continues in the toggled style.
            guard let font = typingAttributes[.font] as? NSFont else { return }
            typingAttributes[.font] = convertedFont(font, removing: hasTrait(font), trait: trait)
            return
        }

        // All-on semantics (like Notes): remove the trait only when every
        // font in the range carries it; otherwise apply it everywhere.
        var segments: [(font: NSFont, range: NSRange)] = []
        var allHave = true
        textStorage?.enumerateAttribute(
            .font, in: range, options: [.longestEffectiveRangeNotRequired]
        ) { value, segment, _ in
            let font = value as? NSFont ?? (typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14))
            segments.append((font, segment))
            if !hasTrait(font) {
                allHave = false
            }
        }
        guard let storage = textStorage else { return }
        storage.beginEditing()
        for (font, segment) in segments {
            storage.addAttribute(
                .font, value: convertedFont(font, removing: allHave, trait: trait), range: segment)
        }
        storage.endEditing()
        refreshTypingAttributesAndDraft()
    }

    private func toggleUnderline() {
        let range = selectedRange()
        if range.length == 0 {
            if (typingAttributes[.underlineStyle] as? Int ?? 0) != 0 {
                typingAttributes.removeValue(forKey: .underlineStyle)
            } else {
                typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return
        }
        var allUnderlined = true
        textStorage?.enumerateAttribute(
            .underlineStyle, in: range, options: [.longestEffectiveRangeNotRequired]
        ) { value, _, _ in
            if (value as? Int ?? 0) == 0 {
                allUnderlined = false
            }
        }
        guard let storage = textStorage else { return }
        storage.beginEditing()
        if allUnderlined {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        storage.endEditing()
        refreshTypingAttributesAndDraft()
    }

    private func convertedFont(
        _ font: NSFont, removing: Bool, trait: NSFontDescriptor.SymbolicTraits
    ) -> NSFont {
        switch trait {
        case .bold:
            return removing ? NodeTitleText.unboldVariant(of: font) : NodeTitleText.boldVariant(of: font)
        default:
            return removing
                ? NodeTitleText.unitalicVariant(of: font) : NodeTitleText.italicVariant(of: font)
        }
    }

    /// The caret inherits the style at the edit's end, and a style change
    /// re-measures (bold text is wider), so publish a fresh draft.
    private func refreshTypingAttributesAndDraft() {
        guard let storage = textStorage else { return }
        let length = (string as NSString).length
        if length > 0 {
            let selection = selectedRange()
            let index = min(max(selection.location + selection.length - 1, 0), length - 1)
            typingAttributes = storage.attributes(at: index, effectiveRange: nil)
        }
        editor?.textDidChange()
    }
}

/// Title ⇄ attributed-string conversion, restricted to the §8.3
/// allow-list. Both directions normalize: fonts compose per run like
/// `TextMeasurer`'s CoreText path (same quirk: a family or code override
/// drops trait composition), and extraction keeps only allow-listed
/// attributes, coalescing adjacent identical runs.
public enum NodeTitleText {
    /// The attribute keys the editor ever writes (the §8.3 allow-list,
    /// plus the base paragraph style that carries the 1.25 line height).
    public static let allowListedKeys: Set<NSAttributedString.Key> = [
        .font, .foregroundColor, .paragraphStyle, .underlineStyle,
        .strikethroughStyle, .backgroundColor, .link,
    ]

    /// `NodeTitle` → editor string, styled from the resolved node style so
    /// the live text looks identical to the rendered node.
    public static func attributed(
        _ title: NodeTitle, baseFont: NSFont, baseColor: NSColor, lineHeight: CGFloat = 1.25
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        let mutable = NSMutableAttributedString(
            string: title.text,
            attributes: [
                .font: baseFont,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraph,
            ])
        let length = (title.text as NSString).length
        for run in title.runs {
            let start = max(0, min(run.range.first ?? 0, length))
            let runLength = max(0, min(run.range.count > 1 ? run.range[1] : 0, length - start))
            guard runLength > 0 else { continue }
            let range = NSRange(location: start, length: runLength)

            let font = composeFont(base: baseFont, run: run)
            if font !== baseFont {
                mutable.addAttribute(.font, value: font, range: range)
            }
            if run.underline == true {
                mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if run.strike == true {
                mutable.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let hex = run.color, let color = nsColor(fromHex: hex) {
                mutable.addAttribute(.foregroundColor, value: color, range: range)
            }
            if let hex = run.highlight, let color = nsColor(fromHex: hex) {
                mutable.addAttribute(.backgroundColor, value: color, range: range)
            }
            if let link = run.link {
                mutable.addAttribute(.link, value: link, range: range)
            }
        }
        return mutable
    }

    /// Editor string → `NodeTitle`, extracting only the allow-listed
    /// attributes into runs. Adjacent identical runs coalesce; ranges are
    /// UTF-16 units (what `NSAttributedString` and `CFString` both use).
    public static func title(
        from attributed: NSAttributedString, baseFont: NSFont, baseColor: NSColor
    ) -> NodeTitle {
        let text = attributed.string
        let length = (text as NSString).length
        guard length > 0 else { return NodeTitle(text: text, runs: []) }

        var runs: [Run] = []
        var index = 0
        while index < length {
            var effective = NSRange(location: index, length: 0)
            let attributes = attributed.attributes(at: index, effectiveRange: &effective)
            if effective.length == 0 {
                effective.length = min(1, length - index)
            }
            if let run = extractRun(
                attributes: attributes, range: NSRange(location: index, length: effective.length),
                baseFont: baseFont, baseColor: baseColor)
            {
                if let last = runs.last, last.range[0] + last.range[1] == index,
                    sameAttributes(last, run)
                {
                    runs[runs.count - 1].range[1] += effective.length
                } else {
                    runs.append(run)
                }
            }
            index += effective.length
        }
        return NodeTitle(text: text, runs: runs)
    }

    /// Builds one run from a constant-attribute dictionary, or nil when
    /// nothing allow-listed is set (the base style needs no run).
    private static func extractRun(
        attributes: [NSAttributedString.Key: Any],
        range: NSRange,
        baseFont: NSFont,
        baseColor: NSColor
    ) -> Run? {
        let manager = NSFontManager.shared
        let font = attributes[.font] as? NSFont ?? baseFont
        var run = Run(range: [range.location, range.length])

        let traits = manager.traits(of: font)
        if traits.contains(.boldFontMask) {
            run.bold = true
        }
        if traits.contains(.italicFontMask) {
            run.italic = true
        }
        let symbolic = font.fontDescriptor.symbolicTraits
        if symbolic.contains(.monoSpace), !baseFont.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            run.code = true
        } else if let family = font.familyName, family != baseFont.familyName {
            run.font = family
        }
        if font.pointSize != baseFont.pointSize {
            run.size = font.pointSize
        }

        if let style = attributes[.underlineStyle] as? Int, style != 0 {
            run.underline = true
        }
        if let style = attributes[.strikethroughStyle] as? Int, style != 0 {
            run.strike = true
        }
        if let color = attributes[.foregroundColor] as? NSColor,
            hexString(from: color) != hexString(from: baseColor), let hex = hexString(from: color)
        {
            run.color = hex
        }
        if let background = attributes[.backgroundColor] as? NSColor, let hex = hexString(from: background) {
            run.highlight = hex
        }
        if let link = attributes[.link] as? String {
            run.link = link
        }

        let styled =
            run.bold != nil || run.italic != nil || run.underline != nil || run.strike != nil
            || run.code != nil || run.color != nil || run.highlight != nil || run.link != nil
            || run.font != nil || run.size != nil
        return styled ? run : nil
    }

    /// Mirrors `TextMeasurer`'s CoreText font composition, so the editor's
    /// live metrics equal the measurer's: bold raises the weight, italic
    /// adds the symbolic trait, code is Menlo, and a family override wins
    /// outright (traits and weight do not compose onto a named family).
    static func composeFont(base: NSFont, run: Run) -> NSFont {
        guard
            run.bold == true || run.italic == true || run.code == true || run.size != nil
                || run.font != nil
        else { return base }
        if let family = run.font {
            return NSFont(name: family, size: run.size ?? base.pointSize) ?? base
        }
        if run.code == true {
            return NSFont(name: "Menlo-Regular", size: run.size ?? base.pointSize) ?? base
        }
        var font = withSize(base, run.size)
        if run.italic == true {
            font = italicVariant(of: font)
        }
        if run.bold == true {
            font = boldVariant(of: font)
        }
        return font
    }

    /// The font with the italic trait removed (bold is handled by the
    /// weight, see `boldVariant(of:)`).
    static func unitalicVariant(of font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits.subtracting(.italic)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 0) ?? font
    }

    private static func withSize(_ font: NSFont, _ size: Double?) -> NSFont {
        guard let size else { return font }
        return NSFont(descriptor: font.fontDescriptor.withSize(CGFloat(size)), size: 0) ?? font
    }

    /// Italic composes through the symbolic trait (that works for system
    /// fonts).
    static func italicVariant(of font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.italic)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 0) ?? font
    }

    /// Bold on a system font is a weight, not a symbolic trait: the trait
    /// route silently resolves back to the same weight. Go through the
    /// weight (≥ 0.4) exactly like TextMeasurer's `max(base.weight, 0.4)`,
    /// after trying the trait route for non-system families.
    static func boldVariant(of font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.bold)
        if let viaTraits = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 0),
            NSFontManager.shared.traits(of: viaTraits).contains(.boldFontMask)
        {
            return viaTraits
        }
        return NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
    }

    /// The font with the bold weight removed: the trait route suffices
    /// here (an unbolded font carries no bold mask, which is all the
    /// §8.3 extraction records).
    static func unboldVariant(of font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits.subtracting(.bold)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 0) ?? font
    }

    private static func sameAttributes(_ lhs: Run, _ rhs: Run) -> Bool {
        lhs.bold == rhs.bold && lhs.italic == rhs.italic && lhs.underline == rhs.underline
            && lhs.strike == rhs.strike && lhs.code == rhs.code && lhs.color == rhs.color
            && lhs.highlight == rhs.highlight && lhs.link == rhs.link && lhs.font == rhs.font
            && lhs.size == rhs.size
    }

    /// `#RRGGBB` (the §8.3 storage format) → `NSColor`.
    static func nsColor(fromHex raw: String) -> NSColor? {
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(cgColor: PaperTheme.color(fromHex: value))
    }

    /// `NSColor` → canonical `#RRGGBB`, or nil when not representable in
    /// sRGB.
    static func hexString(from color: NSColor) -> String? {
        guard let converted = color.usingColorSpace(.sRGB) else { return nil }
        guard let hex = PaperTheme.hex(of: converted.cgColor) else { return nil }
        return String(format: "#%06X", hex)
    }
}
