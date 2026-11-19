import AppKit
import CanvasKit
import MapCore
import MapRender
import MapStudy

/// One study session over a queue of cards (F-STD-4): shows each card's
/// front, reveals the answers, grades through the document's
/// non-undoable write path (ADR-0015), and closes with a summary.
///
/// Keyboard-only by design: Space shows the answer (and grades Good
/// once revealed), 1–4 grade, Esc closes. The same commands ride the
/// grade buttons for VoiceOver and the mouse.
@MainActor
final class StudySessionController: NSWindowController {
    /// The queue this session runs (already daily-limited by the host).
    private let entries: [StudyQueue.Entry]
    private var index = 0
    private var grades: [Grade] = []
    private let startedAt: Date
    private let studyDocument: MapDocument
    private let scene: CanvasScene?
    /// Injectable clock so hosted tests pin grading times.
    var now: () -> Date = { Date() }

    /// The session surface (internal for hosted tests).
    private(set) var sessionView: StudySessionView

    /// True once the current card's answers are on screen.
    private var revealed: Bool {
        sessionView.revealed
    }

    init(
        document: MapDocument, scopeTitle: String, entries: [StudyQueue.Entry], variant: ThemeVariant,
        scene: CanvasScene?
    ) {
        self.studyDocument = document
        self.entries = entries
        self.startedAt = Date()
        self.scene = scene

        let styling = StudySessionView.Styling.standard(
            theme: StudyTheme.theme(for: studyDocument.model, variant: variant), variant: variant)
        sessionView = StudySessionView(frame: NSRect(x: 0, y: 0, width: 720, height: 560), styling: styling)

        let window = NSWindow(
            contentRect: sessionView.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Study — \(scopeTitle)"
        window.contentView = sessionView
        super.init(window: window)

        if let scene {
            sessionView.minimap.setScene(scene, highlight: entries.first?.card.nodeID)
        }

        sessionView.onShowAnswer = { [weak self] in self?.showAnswer() }
        sessionView.onGrade = { [weak self] grade in self?.grade(grade) }
        sessionView.onCancel = { [weak self] in self?.window?.performClose(nil) }
        sessionView.onDone = { [weak self] in self?.window?.performClose(nil) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(sessionView)
        if entries.isEmpty {
            sessionView.showEmptyState()
        } else {
            presentCurrentCard()
        }
    }

    // MARK: session flow

    /// Pushes the card at `index` to the view: front, breadcrumb, the
    /// minimap highlight, and the grade buttons' next-interval previews
    /// computed through the real scheduler.
    private func presentCurrentCard() {
        guard index < entries.count else { return }
        let entry = entries[index]
        let card = entry.card
        let breadcrumb = StudyTheme.breadcrumb(of: card.nodeID, in: studyDocument.model)
            .joined(separator: " › ")
        sessionView.setCard(
            front: card.front,
            breadcrumb: breadcrumb,
            progress: "\(index + 1) of \(entries.count)")
        sessionView.minimap.setHighlight(card.nodeID)

        // Next-interval previews: one scheduler pass per grade (F-STD-4
        // "Good · 4d") off the card's CURRENT state.
        let node = studyDocument.model.nodes[card.nodeID]
        let current = StudyStates.cardState(for: card, in: node?.study, now: now())
        let scheduler = studyDocument.studyScheduler
        var labels: [Grade: String] = [:]
        for grade in Grade.ascending {
            let review = scheduler.review(current, at: now(), grade: grade)
            labels[grade] = IntervalLabel.text(from: review.card.due, now: now())
        }
        sessionView.setGradeLabels(labels)
    }

    /// Space: reveal the answers of the current card; once revealed,
    /// Space grades Good.
    private func showAnswer() {
        if revealed {
            grade(.good)
            return
        }
        guard index < entries.count else { return }
        sessionView.revealAnswers(
            answerLines(of: entries[index].card),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The back side of a card (F-STD-1): the answer text, one line per
    /// child (children animate in one by one), the note as a trailing
    /// block. Cloze cards carry their own masked/unmasked pair already.
    private func answerLines(of card: Card) -> [String] {
        let back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !back.isEmpty else { return ["—"] }
        return back.split(separator: "\n").map(String.init)
    }

    /// Grades the current card: the document's non-undoable write path
    /// updates the node's FSRS state, the review joins the log, and the
    /// session advances.
    private func grade(_ grade: Grade) {
        guard revealed, index < entries.count else { return }
        let card = entries[index].card
        guard studyDocument.grade(card: card, grade: grade, now: now()) != nil else { return }
        grades.append(grade)
        index += 1
        if index < entries.count {
            presentCurrentCard()
        } else {
            showSummary()
        }
    }

    /// The session summary (F-STD-4): reviewed, accuracy, time, streak.
    private func showSummary() {
        let reviewed = grades.count
        let correct = grades.filter { $0 != .again }.count
        let accuracy = reviewed > 0 ? Double(correct) / Double(reviewed) : 1
        let seconds = now().timeIntervalSince(startedAt)
        let streak = StudyStats.streak(reviews: studyDocument.reviewLog, now: now())
        sessionView.showSummary([
            "Session complete",
            "Reviewed \(reviewed) card\(reviewed == 1 ? "" : "s") · \(Int((accuracy * 100).rounded()))% correct",
            "Time \(Self.durationText(seconds)) · \(streak)-day streak",
        ])
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \((total % 3_600) / 60)m"
    }
}
