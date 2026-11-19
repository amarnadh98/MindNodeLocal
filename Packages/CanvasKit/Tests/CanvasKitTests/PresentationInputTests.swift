import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// The presenting key state machine (F-PRE-4/5/6/7), pure: every key in
/// the SPEC's presenting table, driven through one deck with builds.
struct PresentationInputTests {
    /// 3 slides: builds [2, 0, 1].
    private var deck: PresenterDeck {
        PresenterDeck(slidesBuildCounts: [2, 0, 1])
    }

    private func update(
        _ session: PresenterSession, _ event: PresenterEvent
    ) -> (session: PresenterSession, effects: [PresenterEffect]) {
        PresenterInput.update(session, deck: deck, event: event)
    }

    // MARK: advancing (F-PRE-4: →/Space/⏎/PageDown/click)

    @Test func nextKeysAdvanceBuildsThenSlides() {
        var session = PresenterSession()
        // Slide 0 has 2 builds: the four next keys each advance one
        // build until they run out, then move the deck forward.
        let first = update(session, .keyDown(.rightArrow))
        #expect(first.effects == [.revealNextBuild])
        #expect(first.session.buildCursor == 0)
        #expect(first.session.slideIndex == 0)

        session = first.session
        let space = update(session, .keyDown(.space))
        #expect(space.effects == [.revealNextBuild])
        #expect(space.session.buildCursor == 1)

        // Builds exhausted → the next key goes straight on to a fresh
        // slide 1 (which has no builds of its own).
        let onward = update(space.session, .keyDown(.enter))
        #expect(onward.effects == [.showSlide(index: 1, buildCursor: -1)])
        #expect(onward.session.slideIndex == 1)
        #expect(onward.session.buildCursor == -1)

        let pageDown = update(onward.session, .keyDown(.pageDown))
        #expect(pageDown.effects == [.showSlide(index: 2, buildCursor: -1)])

        // Slide 2's single build, then the end of the deck: nothing.
        session = update(pageDown.session, .keyDown(.space)).session
        let atEnd = update(session, .click)
        #expect(atEnd.effects.isEmpty)
        #expect(atEnd.session.slideIndex == 2)
        #expect(atEnd.session.buildCursor == 0)
    }

    // MARK: back (F-PRE-4: ←/PageUp)

    @Test func backUnrevealsBuildsThenSlidesAtTheirCompletedBuild() {
        var session = PresenterSession()
        session.slideIndex = 1
        session.buildCursor = -1

        // ← from slide 1's start: slide 0 shown COMPLETED (its last
        // build applied) — back never replays a slide from scratch.
        let toSlide0 = update(session, .keyDown(.leftArrow))
        #expect(toSlide0.effects == [.showSlide(index: 0, buildCursor: 1)])
        #expect(toSlide0.session.slideIndex == 0)

        session = toSlide0.session
        let unbuild = update(session, .keyDown(.pageUp))
        #expect(unbuild.effects == [.unrevealLastBuild])
        #expect(unbuild.session.buildCursor == 0)

        let again = update(unbuild.session, .keyDown(.leftArrow))
        #expect(again.effects == [.unrevealLastBuild])
        #expect(again.session.buildCursor == -1)

        // Before the deck's start: nothing.
        let nothing = update(again.session, .keyDown(.leftArrow))
        #expect(nothing.effects.isEmpty)
    }

    // MARK: Home / End

    @Test func homeAndEndJump() {
        var session = PresenterSession()
        session.slideIndex = 2
        session.buildCursor = 0

        let home = update(session, .keyDown(.home))
        #expect(home.effects == [.showSlide(index: 0, buildCursor: -1)])
        #expect(home.session.slideIndex == 0)

        let end = update(home.session, .keyDown(.end))
        #expect(end.effects == [.showSlide(index: 2, buildCursor: 0)])
        #expect(end.session.slideIndex == 2)
        #expect(end.session.buildCursor == 0)

        // Home at home does nothing.
        #expect(update(end.session, .keyDown(.home)).effects == [.showSlide(index: 0, buildCursor: -1)])
    }

    // MARK: digits + ⏎ (F-PRE-4: number + ⏎ jumps)

    @Test func digitsPlusReturnJumpToTheSlide() {
        var session = PresenterSession()
        // "3" then ⏎ → slide 3 = index 2.
        session = update(session, .keyDown(.digit("3"))).session
        #expect(session.digitBuffer == "3")
        // More digits accumulate.
        session = update(session, .keyDown(.digit("1"))).session
        #expect(session.digitBuffer == "31")

        let jump = update(session, .keyDown(.enter))
        // 31 is past the 3-slide deck: the buffer clears, nothing
        // happens (an invalid target is a no-op, like Keynote).
        #expect(jump.session.digitBuffer.isEmpty)
        #expect(jump.effects.isEmpty)

        // A valid two-digit target: with this 3-slide deck only 1–3
        // work; try "2".
        session = update(jump.session, .keyDown(.digit("2"))).session
        let valid = update(session, .keyDown(.enter))
        #expect(valid.effects == [.showSlide(index: 1, buildCursor: -1)])
        #expect(valid.session.slideIndex == 1)
        #expect(valid.session.digitBuffer.isEmpty)
    }

    @Test func plainReturnWithoutDigitsIsANext() {
        let session = PresenterSession()
        let plain = update(session, .keyDown(.enter))
        #expect(plain.effects == [.revealNextBuild])
    }

    @Test func anyNextKeyClearsADigitBuffer() {
        var session = PresenterSession()
        session = update(session, .keyDown(.digit("2"))).session
        let click = update(session, .click)
        #expect(click.session.digitBuffer.isEmpty)
        #expect(click.effects == [.revealNextBuild])
    }

    @Test func escapeFirstClearsAStartedNumberThenExits() {
        var session = PresenterSession()
        session = update(session, .keyDown(.digit("2"))).session
        let clear = update(session, .keyDown(.escape))
        #expect(clear.effects.isEmpty)
        #expect(clear.session.digitBuffer.isEmpty)

        let exit = update(clear.session, .keyDown(.escape))
        #expect(exit.effects == [.exitPresentation])
    }

    // MARK: B / W (F-PRE-4: black/white screen)

    @Test func blackAndWhiteToggleBackToNormal() {
        let session = PresenterSession()
        let black = update(session, .keyDown(.blackKey))
        #expect(black.effects == [.setScreen(.black)])
        #expect(black.session.screen == .black)

        // B again restores the slide.
        let back = update(black.session, .keyDown(.blackKey))
        #expect(back.effects == [.setScreen(.normal)])
        #expect(back.session.screen == .normal)

        // W from black goes straight to white; W again back to normal.
        let white = update(back.session, .keyDown(.whiteKey))
        #expect(white.effects == [.setScreen(.white)])
        let stillWhite = update(white.session, .keyDown(.blackKey))
        #expect(stillWhite.effects == [.setScreen(.black)])
        // From black, W goes to white (not back through normal).
        let fromBlack = update(stillWhite.session, .keyDown(.whiteKey))
        #expect(fromBlack.effects == [.setScreen(.white)])
        let normal = update(fromBlack.session, .keyDown(.whiteKey))
        #expect(normal.effects == [.setScreen(.normal)])
    }

    // MARK: live edit (F-PRE-6: E pauses, ⌘⏎ resumes)

    @Test func liveEditPausesAndResumes() {
        var session = PresenterSession()
        session = update(session, .keyDown(.space)).session

        let pause = update(session, .keyDown(.liveEdit))
        #expect(pause.effects == [.pauseForLiveEdit])
        #expect(pause.session.liveEditPaused)

        // While paused, the deck ignores navigation keys…
        let ignored = update(pause.session, .keyDown(.rightArrow))
        #expect(ignored.effects.isEmpty)
        // …but ⌘⏎ (resume) works and the cursor is where it was.
        let resume = update(pause.session, .keyDown(.resume))
        #expect(resume.effects == [.resumeFromLiveEdit])
        #expect(!resume.session.liveEditPaused)
        #expect(resume.session.buildCursor == session.buildCursor)

        // E while already paused is a no-op.
        #expect(update(pause.session, .keyDown(.liveEdit)).effects.isEmpty)
    }

    // MARK: hold keys (F-PRE-7: L laser, S spotlight)

    @Test func laserAndSpotlightFollowHoldAndRelease() {
        let session = PresenterSession()
        let down = update(session, .keyDown(.laser))
        #expect(down.effects == [.laserActive(true)])
        let up = update(down.session, .keyUp(.laser))
        #expect(up.effects == [.laserActive(false)])

        let spotDown = update(session, .keyDown(.spotlight))
        #expect(spotDown.effects == [.spotlightActive(true)])
        let spotUp = update(spotDown.session, .keyUp(.spotlight))
        #expect(spotUp.effects == [.spotlightActive(false)])

        // An unrelated key-up never fires the holds.
        let otherUp = update(session, .keyUp(.unknown))
        #expect(otherUp.effects.isEmpty)
    }

    // MARK: presenter view (F-PRE-5: ⌥P)

    @Test func presenterToggleFlipsBothWays() {
        let session = PresenterSession()
        let on = update(session, .keyDown(.presenterToggle))
        #expect(on.effects == [.togglePresenterView])
        let off = update(on.session, .keyDown(.presenterToggle))
        #expect(off.effects == [.togglePresenterView])
    }

    // MARK: unknown keys

    @Test func unknownKeysDoNothing() {
        let session = PresenterSession()
        #expect(update(session, .keyDown(.unknown)).effects.isEmpty)
    }

    // MARK: the NSEvent translation (PresentationShield)

    @Test func shieldKeyTranslation() throws {
        func event(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
        }

        #expect(PresentationShield.key(for: try #require(event("\u{f703}"))) == .rightArrow)
        #expect(PresentationShield.key(for: try #require(event("\u{f702}"))) == .leftArrow)
        #expect(PresentationShield.key(for: try #require(event("\u{f715}"))) == .pageDown)
        #expect(PresentationShield.key(for: try #require(event("\u{f712}"))) == .pageUp)
        #expect(PresentationShield.key(for: try #require(event("\u{f729}"))) == .home)
        #expect(PresentationShield.key(for: try #require(event("\u{f72b}"))) == .end)
        #expect(PresentationShield.key(for: try #require(event("\u{1b}"))) == .escape)
        #expect(PresentationShield.key(for: try #require(event("\r"))) == .enter)
        #expect(PresentationShield.key(for: try #require(event(" "))) == .space)
        #expect(PresentationShield.key(for: try #require(event("5"))) == .digit("5"))
        #expect(PresentationShield.key(for: try #require(event("b"))) == .blackKey)
        #expect(PresentationShield.key(for: try #require(event("w"))) == .whiteKey)
        #expect(PresentationShield.key(for: try #require(event("e"))) == .liveEdit)
        #expect(PresentationShield.key(for: try #require(event("l"))) == .laser)
        #expect(PresentationShield.key(for: try #require(event("s"))) == .spotlight)
        #expect(PresentationShield.key(for: try #require(event("x"))) == .unknown)

        // ⌥P: characters carries the composed glyph, the translation
        // reads through charactersIgnoringModifiers.
        let optionP = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                windowNumber: 0, context: nil, characters: "π", charactersIgnoringModifiers: "p",
                isARepeat: false, keyCode: 0))
        #expect(PresentationShield.key(for: optionP) == .presenterToggle)

        let commandReturn = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 0))
        #expect(PresentationShield.key(for: commandReturn) == .resume)
    }
}

/// The slides PDF writer (M6 exit list, F-PRE-8's PDF half): page
/// counts per option, drawn through the shared renderer.
@MainActor
struct SlidesPDFWriterTests {
    private func slides() throws -> [ResolvedSlide] {
        let model = sceneModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let auto = AutoPresentation.slides(model: model, scene: scene)
        #expect(auto.count >= 3)
        return auto
    }

    private func write(_ options: SlidesPDFWriter.Options) throws -> (URL, Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slides-\(UUID().uuidString).pdf")
        let pages = try SlidesPDFWriter.write(
            model: sceneModel(), variant: .light, slides: slides(), options: options, to: url)
        return (url, pages)
    }

    @Test func onePagePerSlide() throws {
        let (url, pages) = try write(SlidesPDFWriter.Options())
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = try slides()
        #expect(pages == deck.count)

        let document = CGPDFDocument(url as CFURL)
        #expect(document?.numberOfPages == pages)
    }

    @Test func notesPagesDoubleTheCount() throws {
        var options = SlidesPDFWriter.Options()
        options.includeNotes = true
        let (url, pages) = try write(options)
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = try slides()
        #expect(pages == deck.count * 2)
    }

    @Test func buildStepPagesCountEveryState() throws {
        var deck = try slides()
        // Give the first non-overview slide two build steps.
        if let index = deck.firstIndex(where: { $0.kind != .overview }) {
            let slide = deck[index]
            let focus = slide.focus.sorted().filter { $0 != "root" }
            deck[index].build = Array(focus.prefix(2))
        }
        var options = SlidesPDFWriter.Options()
        options.pagePerBuildStep = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slides-\(UUID().uuidString).pdf")
        let pages = try SlidesPDFWriter.write(
            model: sceneModel(), variant: .light, slides: deck, options: options, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected =
            deck.reduce(0) { count, slide in
                count + 1 + slide.build.count
            }
        #expect(pages == expected)
    }

    @Test func emptyDeckThrows() {
        #expect(throws: SlidesPDFWriter.PDFError.emptyDeck) {
            _ = try SlidesPDFWriter.write(
                model: sceneModel(), variant: .light, slides: [],
                to: FileManager.default.temporaryDirectory.appendingPathComponent("x.pdf"))
        }
    }
}
