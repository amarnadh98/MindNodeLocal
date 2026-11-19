import Foundation

/// The presenting state machine (F-PRE-4/5/6/7): a pure value over
/// (slide index, build cursor, screen color, digit buffer) that turns
/// clicker keys into effects. The App layer owns the machine's state
/// and applies the effects; this file decides nothing about windows so
/// every key path is headlessly testable.
public struct PresenterSession: Equatable, Sendable {
    /// B/W screen states (F-PRE-4): black and white blank the screen,
    /// the same key toggles back to normal.
    public enum Screen: Equatable, Sendable {
        case normal
        case black
        case white
    }

    public var slideIndex: Int = 0
    /// The reveal-engine cursor within the current slide (-1 before
    /// its first build step has applied).
    public var buildCursor: Int = -1
    /// Pending slide-jump digits (F-PRE-4: number + ⏎).
    public var digitBuffer: String = ""
    public var screen: Screen = .normal
    /// True while paused into live editing (F-PRE-6).
    public var liveEditPaused: Bool = false

    public init() {}
}

/// Deck shape the machine navigates: how many slides, and each
/// slide's build-step count.
public struct PresenterDeck: Equatable, Sendable {
    public let slideCount: Int
    public let buildCounts: [Int]

    public init(slideCount: Int, buildCounts: [Int]) {
        self.slideCount = slideCount
        self.buildCounts = buildCounts
    }

    public init(slidesBuildCounts: [Int]) {
        self.slideCount = slidesBuildCounts.count
        self.buildCounts = slidesBuildCounts
    }

    func buildCount(ofSlide index: Int) -> Int {
        guard buildCounts.indices.contains(index) else { return 0 }
        return buildCounts[index]
    }
}

/// Every key the presentation surface can report. `PresenterView`
/// translates `NSEvent`s into these; the machine never sees AppKit.
public enum PresenterKey: Equatable, Sendable {
    case rightArrow, space, enter, pageDown
    case leftArrow, pageUp, home, end
    case digit(String)
    case escape, blackKey, whiteKey, liveEdit, resume, presenterToggle
    case laser, spotlight, unknown

    /// True for the next-build keys (→/Space/⏎/PageDown, F-PRE-4 —
    /// what Bluetooth clickers send).
    public var isNext: Bool {
        self == .rightArrow || self == .space || self == .enter || self == .pageDown
    }

    /// True for the back keys (←/PageUp).
    public var isBack: Bool {
        self == .leftArrow || self == .pageUp
    }
}

/// One event from the presenting surface: a key going down or up (the
/// hold-keys L/S care about release), or a click (next, F-PRE-4).
public enum PresenterEvent: Equatable, Sendable {
    case keyDown(PresenterKey)
    case keyUp(PresenterKey)
    case click
}

/// What the App layer must do after an event. Ordered; usually one.
public enum PresenterEffect: Equatable, Sendable {
    /// One more build step revealed inside the current slide.
    case revealNextBuild
    /// One build step taken back.
    case unrevealLastBuild
    /// Show slide `index` at the given build cursor (fresh = -1, the
    /// completed slide = its last step — where back from the next
    /// slide lands).
    case showSlide(index: Int, buildCursor: Int)
    case setScreen(PresenterSession.Screen)
    case exitPresentation
    case togglePresenterView
    /// E: pause into live editing at the current camera (F-PRE-6).
    case pauseForLiveEdit
    /// ⌘⏎: resume presenting where it paused.
    case resumeFromLiveEdit
    /// Hold-keys (F-PRE-7): laser dot / spotlight while held.
    case laserActive(Bool)
    case spotlightActive(Bool)
}

public enum PresenterInput {
    /// Digits longer than this are ignored as a jump target (a deck
    /// with more slides than this is not a real deck).
    static let digitBufferLimit = 4

    /// The pure transition. Invalid targets (a jump past the end, next
    /// on the last slide) produce no effect — the clicker simply does
    /// nothing there, like Keynote. (A key-state switch is wide by
    /// design; the helpers stay small.)
    // swiftlint:disable:next cyclomatic_complexity
    public static func update(
        _ session: PresenterSession, deck: PresenterDeck, event: PresenterEvent
    ) -> (session: PresenterSession, effects: [PresenterEffect]) {
        var next = session
        var effects: [PresenterEffect] = []

        switch event {
        case .keyDown(let key) where key.isNext:
            guard !session.liveEditPaused else { break }
            // ⏎ is overloaded: with digits buffered it executes the
            // jump (an out-of-range target just clears the buffer —
            // a no-op, like Keynote); otherwise it is a plain next,
            // like the click.
            if key == .enter, !session.digitBuffer.isEmpty {
                next.digitBuffer = ""
                if let target = Int(session.digitBuffer), (1...deck.slideCount).contains(target) {
                    next.slideIndex = target - 1
                    next.buildCursor = -1
                    effects.append(.showSlide(index: target - 1, buildCursor: -1))
                }
            } else {
                next.digitBuffer = ""
                advance(&next, deck: deck, effects: &effects)
            }

        case .click:
            guard !session.liveEditPaused else { break }
            next.digitBuffer = ""
            advance(&next, deck: deck, effects: &effects)

        case .keyDown(.leftArrow), .keyDown(.pageUp):
            guard !session.liveEditPaused else { break }
            retreat(&next, deck: deck, effects: &effects)

        case .keyDown(.home):
            guard !session.liveEditPaused, session.slideIndex != 0 else { break }
            next.slideIndex = 0
            next.buildCursor = -1
            next.digitBuffer = ""
            effects.append(.showSlide(index: 0, buildCursor: -1))

        case .keyDown(.end):
            let last = deck.slideCount - 1
            guard !session.liveEditPaused, session.slideIndex != last, last >= 0 else { break }
            next.slideIndex = last
            next.buildCursor = deck.buildCount(ofSlide: last) - 1
            next.digitBuffer = ""
            effects.append(.showSlide(index: last, buildCursor: next.buildCursor))

        case .keyDown(.digit(let digit)):
            guard !session.liveEditPaused, next.digitBuffer.count < digitBufferLimit else { break }
            next.digitBuffer += digit

        case .keyDown(.escape):
            // A buffered number first cancels the jump; the next press
            // exits (the standard clicker idiom).
            if !session.digitBuffer.isEmpty {
                next.digitBuffer = ""
                break
            }
            effects.append(.exitPresentation)

        case .keyDown(.blackKey):
            let target: PresenterSession.Screen = session.screen == .black ? .normal : .black
            next.screen = target
            effects.append(.setScreen(target))

        case .keyDown(.whiteKey):
            let target: PresenterSession.Screen = session.screen == .white ? .normal : .white
            next.screen = target
            effects.append(.setScreen(target))

        case .keyDown(.liveEdit):
            guard !session.liveEditPaused else { break }
            next.liveEditPaused = true
            effects.append(.pauseForLiveEdit)

        case .keyDown(.resume):
            guard session.liveEditPaused else { break }
            next.liveEditPaused = false
            effects.append(.resumeFromLiveEdit)

        case .keyDown(.presenterToggle):
            effects.append(.togglePresenterView)

        case .keyDown(.laser):
            effects.append(.laserActive(true))

        case .keyUp(.laser):
            effects.append(.laserActive(false))

        case .keyDown(.spotlight):
            effects.append(.spotlightActive(true))

        case .keyUp(.spotlight):
            effects.append(.spotlightActive(false))

        case .keyUp:
            // Only the hold-keys care about release.
            break

        case .keyDown(.unknown):
            // Everything else (the machine never acts on it).
            break

        case .keyDown:
            // The `where key.isNext` pattern above is refutable, so
            // exhaustiveness needs this fall-through; every meaningful
            // key already matched earlier.
            break
        }
        return (next, effects)
    }

    /// →/Space/⏎/PageDown/click: one more build step, else the next
    /// slide fresh, else nothing at the end of the deck.
    private static func advance(
        _ session: inout PresenterSession, deck: PresenterDeck, effects: inout [PresenterEffect]
    ) {
        let builds = deck.buildCount(ofSlide: session.slideIndex)
        if session.buildCursor + 1 < builds {
            session.buildCursor += 1
            effects.append(.revealNextBuild)
        } else if session.slideIndex + 1 < deck.slideCount {
            session.slideIndex += 1
            session.buildCursor = -1
            effects.append(.showSlide(index: session.slideIndex, buildCursor: -1))
        }
    }

    /// ←/PageUp: one build step back, else the previous slide at its
    /// completed build state, else nothing at the start.
    private static func retreat(
        _ session: inout PresenterSession, deck: PresenterDeck, effects: inout [PresenterEffect]
    ) {
        if session.buildCursor >= 0 {
            session.buildCursor -= 1
            effects.append(.unrevealLastBuild)
        } else if session.slideIndex > 0 {
            session.slideIndex -= 1
            let completed = deck.buildCount(ofSlide: session.slideIndex) - 1
            session.buildCursor = completed
            session.digitBuffer = ""
            effects.append(.showSlide(index: session.slideIndex, buildCursor: completed))
        }
    }
}
