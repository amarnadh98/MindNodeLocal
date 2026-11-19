import AppKit
import MapRender
import MapStudy

/// The study session surface (F-STD-4): breadcrumb above, the card in
/// the map's theme typography, "Show Answer", the answer children
/// animating in one by one, grade buttons with next-interval labels,
/// the corner minimap and the session summary.
///
/// The view is deliberately dumb: the controller pushes card content,
/// reveal commands and labels; key presses and buttons flow back through
/// closures. VoiceOver reads every piece — card, answers, grades and
/// the summary are real controls and static text with labels.
///
/// The answer reveal is a small self-contained animation here
/// (§7.6's 250 ms fade + 8 pt slide, staggered 60 ms) —
/// TODO(M6 RevealEngine): swap the manual animation for the shared
/// reveal overlay once F-STD-5 lands on the same engine.
@MainActor
final class StudySessionView: NSView {
    struct Styling {
        let frontFont: NSFont
        let answerFont: NSFont
        let textColor: NSColor
        let backgroundColor: NSColor

        @MainActor
        static func standard(theme: MapRender.Theme, variant: ThemeVariant) -> Styling {
            Styling(
                frontFont: StudyTheme.frontFont(theme: theme, variant: variant),
                answerFont: StudyTheme.answerFont(theme: theme, variant: variant),
                textColor: StudyTheme.textColor(theme: theme, variant: variant),
                backgroundColor: StudyTheme.canvasColor(theme: theme, variant: variant))
        }
    }

    /// Keyboard/button routing back to the session controller.
    var onShowAnswer: (() -> Void)?
    var onGrade: ((Grade) -> Void)?
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?

    private let breadcrumbField = NSTextField(labelWithString: "")
    private let frontField = NSTextField(wrappingLabelWithString: "")
    private let progressField = NSTextField(labelWithString: "")
    private let showAnswerButton = NSButton(title: "Show Answer", target: nil, action: nil)
    private var gradeButtons: [NSButton] = []
    private var answerFields: [NSTextField] = []
    private var summaryFields: [NSTextField] = []
    private(set) var revealed = false

    let minimap = SessionMinimapView(frame: .zero)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private let styling: Styling

    init(frame frameRect: NSRect, styling: Styling) {
        self.styling = styling
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = styling.backgroundColor.cgColor
        setFontSizes()

        breadcrumbField.textColor = .secondaryLabelColor
        breadcrumbField.alignment = .center
        breadcrumbField.font = .systemFont(ofSize: 13, weight: .regular)
        frontField.alignment = .center
        frontField.maximumNumberOfLines = 0
        frontField.textColor = styling.textColor
        frontField.cell?.wraps = true
        progressField.textColor = .secondaryLabelColor
        progressField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressField.alignment = .right

        showAnswerButton.bezelStyle = .recessed
        showAnswerButton.controlSize = .large
        showAnswerButton.font = .systemFont(ofSize: 15, weight: .semibold)
        showAnswerButton.action = #selector(showAnswerAction(_:))
        showAnswerButton.target = self
        showAnswerButton.setAccessibilityLabel("Show Answer")

        // F-STD-4: keys 1–4, Space = Good; the titles carry the
        // scheduler's next-interval preview ("Good · 4d").
        for grade in Grade.ascending {
            let button = NSButton(title: "", target: nil, action: nil)
            button.bezelStyle = .recessed
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.tag = grade.value
            button.action = #selector(gradeAction(_:))
            button.target = self
            button.isHidden = true
            gradeButtons.append(button)
        }

        doneButton.bezelStyle = .recessed
        doneButton.action = #selector(doneAction(_:))
        doneButton.target = self
        doneButton.isHidden = true

        addSubview(breadcrumbField)
        addSubview(progressField)
        addSubview(frontField)
        addSubview(showAnswerButton)
        gradeButtons.forEach(addSubview)
        addSubview(minimap)
        addSubview(doneButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func setFontSizes() {
        frontField.font = styling.frontFont
    }

    // MARK: content pushes (from the controller)

    /// One card's front side: the breadcrumb context above, the card
    /// text centered (F-STD-1 front), the progress counter, and the
    /// answers hidden until Space.
    func setCard(front: String, breadcrumb: String, progress: String) {
        breadcrumbField.stringValue = breadcrumb
        frontField.stringValue = front
        progressField.stringValue = progress
        frontField.setAccessibilityLabel("Card, \(front)")
        revealCleanup()
        needsLayout = true
    }

    /// The four grade buttons' next-interval labels ("Good · 4d").
    /// Tag → grade for the four buttons.
    static let gradesByTag: [Int: Grade] = [1: .again, 2: .hard, 3: .good, 4: .easy]

    func setGradeLabels(_ labels: [Grade: String]) {
        for button in gradeButtons {
            guard let grade = Self.gradesByTag[button.tag] else { continue }
            button.title = "\(gradeName(grade)) · \(labels[grade] ?? "")"
            button.setAccessibilityLabel("Grade \(gradeName(grade)), next interval \(labels[grade] ?? "")")
        }
    }

    /// Reveals the answer children one by one (§7.6: fade + 8 pt slide,
    /// 250 ms, staggered 60 ms; Reduce Motion collapses it) and brings
    /// the grade buttons up.
    func revealAnswers(_ lines: [String], reduceMotion: Bool) {
        revealed = true
        showAnswerButton.isHidden = true
        for button in gradeButtons {
            button.isHidden = false
        }
        // TODO(M6 RevealEngine): the manual stagger below becomes the
        // shared reveal overlay's job once presentations land on it.
        Task { @MainActor [weak self] in
            for line in lines {
                guard let self else { return }
                let field = NSTextField(wrappingLabelWithString: line)
                field.alignment = .center
                field.textColor = styling.textColor
                field.font = styling.answerFont
                field.setAccessibilityLabel("Answer, \(line)")
                self.addSubview(field)
                self.answerFields.append(field)
                field.alphaValue = reduceMotion ? 1 : 0
                self.layoutAnswerFields()
                let finalOrigin = field.frame.origin
                if !reduceMotion {
                    field.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + 8))
                    NSAnimationContext.beginGrouping()
                    NSAnimationContext.current.duration = 0.25
                    field.animator().setFrameOrigin(finalOrigin)
                    field.animator().alphaValue = 1
                    NSAnimationContext.endGrouping()
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        }
    }

    /// Clears the answer area and hides the grade buttons (next card).
    private func revealCleanup() {
        revealed = false
        showAnswerButton.isHidden = false
        for button in gradeButtons {
            button.isHidden = true
        }
        for field in answerFields {
            field.removeFromSuperview()
        }
        answerFields = []
        for field in summaryFields {
            field.removeFromSuperview()
        }
        summaryFields = []
        doneButton.isHidden = true
    }

    /// The end-of-session summary (F-STD-4: reviewed, accuracy, time,
    /// streak) replacing the card.
    func showSummary(_ lines: [String]) {
        revealCleanup()
        showAnswerButton.isHidden = true
        for (index, line) in lines.enumerated() {
            let field = NSTextField(labelWithString: line)
            field.alignment = .center
            field.font =
                index == 0
                ? .systemFont(ofSize: 24, weight: .semibold) : .systemFont(ofSize: 16, weight: .regular)
            field.textColor = index == 0 ? styling.textColor : .secondaryLabelColor
            field.setAccessibilityLabel(line)
            addSubview(field)
            summaryFields.append(field)
        }
        doneButton.isHidden = false
        needsLayout = true
    }

    /// The empty-queue celebration (F-ONB-3: "nothing due" is designed,
    /// not defaulted).
    func showEmptyState() {
        revealCleanup()
        showAnswerButton.isHidden = true
        showSummary(["Nothing due — you're all caught up.", "Come back tomorrow, or add a new deck."])
    }

    // MARK: layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height

        progressField.frame = NSRect(x: width - 130, y: 12, width: 118, height: 16)
        minimap.frame = NSRect(
            x: width - SessionMinimapView.preferredSize.width - 16, y: 34,
            width: SessionMinimapView.preferredSize.width, height: SessionMinimapView.preferredSize.height)
        breadcrumbField.frame = NSRect(x: 16, y: 44, width: width - 32, height: 18)
        frontField.frame = NSRect(x: 48, y: 96, width: width - 96, height: 140)
        frontField.cell?.wraps = true
        showAnswerButton.frame = NSRect(x: width / 2 - 70, y: 260, width: 140, height: 32)

        layoutAnswerFields()
        layoutGradeButtons(width: width, height: height)

        var summaryY: CGFloat = height / 2 - 40
        for field in summaryFields {
            field.sizeToFit()
            field.frame.origin = NSPoint(x: width / 2 - field.frame.width / 2, y: summaryY)
            summaryY += field.frame.height + 14
        }
        if !doneButton.isHidden {
            doneButton.frame = NSRect(x: width / 2 - 50, y: summaryY + 8, width: 100, height: 32)
        }
    }

    private func layoutAnswerFields() {
        var y: CGFloat = 320
        for field in answerFields {
            field.sizeToFit()
            let fieldWidth = min(max(field.frame.width + 8, 120), bounds.width - 64)
            field.frame = NSRect(
                x: bounds.midX - fieldWidth / 2, y: y, width: fieldWidth, height: field.frame.height + 2)
            y += field.frame.height + 10
        }
    }

    private func layoutGradeButtons(width: CGFloat, height: CGFloat) {
        let buttonWidth: CGFloat = 110
        let spacing: CGFloat = 12
        let total = CGFloat(gradeButtons.count) * buttonWidth + spacing * CGFloat(gradeButtons.count - 1)
        let originX = (width - total) / 2
        for (index, button) in gradeButtons.enumerated() {
            button.frame = NSRect(
                x: originX + CGFloat(index) * (buttonWidth + spacing), y: height - 56,
                width: buttonWidth, height: 32)
        }
    }

    // MARK: events

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags
        switch (characters, modifiers.contains(.command)) {
        case (" ", false):
            onShowAnswer?()
        case ("1", false):
            onGrade?(.again)
        case ("2", false):
            onGrade?(.hard)
        case ("3", false):
            onGrade?(.good)
        case ("4", false):
            onGrade?(.easy)
        case ("\u{1b}", _):
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func showAnswerAction(_ sender: Any?) {
        onShowAnswer?()
    }

    @objc private func gradeAction(_ sender: Any?) {
        guard let tag = (sender as? NSButton)?.tag else { return }
        switch tag {
        case 1: onGrade?(.again)
        case 2: onGrade?(.hard)
        case 3: onGrade?(.good)
        case 4: onGrade?(.easy)
        default: break
        }
    }

    @objc private func doneAction(_ sender: Any?) {
        onDone?()
    }

    // MARK: grade naming

    private func gradeName(_ grade: Grade) -> String {
        switch grade {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}
