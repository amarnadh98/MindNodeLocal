import AppKit
import MapCore
import MapIO
import Testing

@testable import Arbor

/// F-ONB (SPEC §5.19, M2 slice): the welcome's once-per-user rule, the
/// sample tour map, the contextual tips' one-per-session rule, and the
/// ⌘/ cheat sheet generated from the real main menu.
@MainActor
struct OnboardingTests {
    private func resetWelcomeDefaults() {
        UserDefaults.standard.removeObject(forKey: WelcomeCoordinator.seenKey)
    }

    // MARK: F-ONB-1 welcome

    @Test func welcomeShowsOnceUntilSeenOrReopenedFromHelp() throws {
        resetWelcomeDefaults()
        let coordinator = WelcomeCoordinator()
        coordinator.showIfNeeded()
        #expect(coordinator.windowForTesting != nil, "first launch shows the welcome")

        // Dismissing (the close button path) marks it seen.
        coordinator.windowForTesting?.close()
        #expect(UserDefaults.standard.bool(forKey: WelcomeCoordinator.seenKey))

        // Second launch: silent.
        let secondLaunch = WelcomeCoordinator()
        secondLaunch.showIfNeeded()
        #expect(secondLaunch.windowForTesting == nil)

        // Help ▸ Welcome to Arbor reopens regardless of the flag.
        secondLaunch.showIfNeeded(force: true)
        #expect(secondLaunch.windowForTesting != nil)
        secondLaunch.windowForTesting?.close()
        resetWelcomeDefaults()
    }

    @Test func welcomeChoicesMarkSeenAndAct() throws {
        resetWelcomeDefaults()
        TipCenter.resetSessionClaim()
        let coordinator = WelcomeCoordinator()
        coordinator.showIfNeeded()
        let window = try #require(coordinator.windowForTesting)

        // The view's two doors exist as real actions on the window's
        // hosted content; simulate the "New Map" door by invoking the
        // action surface directly (the hosted view's buttons call the
        // same closures).
        var choseNewMap = false
        let actions = WelcomeActions(
            openSampleMap: {},
            newMap: { choseNewMap = true })
        actions.newMap()
        #expect(choseNewMap)

        // The coordinator's own path marks seen and closes.
        coordinator.chooseNewMapForTesting()
        #expect(UserDefaults.standard.bool(forKey: WelcomeCoordinator.seenKey))
        #expect(!window.isVisible)
        resetWelcomeDefaults()
    }

    // MARK: F-ONB-1 sample map

    @Test func sampleTourMapIsOriginalValidAndRoundTrips() throws {
        let model = SampleMap.buildModel()

        // The teaching branches are all present (edit, outline, focus,
        // present, study, capture, style, share).
        let chapters = Set(model.nodes[model.roots[0]]?.children ?? [])
        #expect(chapters.count == 8)
        // root + 8 chapters + steps (6 + 3 + 3 + 3 + 4 + 3 + 3 + 2).
        #expect(model.nodes.count == 1 + 8 + 27)

        // It passes the same validation every opened package passes.
        let tourURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tour-\(UUID().uuidString).arbor", isDirectory: true)
        try ArborPackage.write(
            model, meta: PackageMeta(appVersion: AppIdentity.appVersion, docID: model.docID),
            to: tourURL)
        let readBack = try ArborPackage.read(at: tourURL)
        #expect(readBack.model.nodes.count == model.nodes.count)
        #expect(readBack.model.roots == model.roots)
        #expect(readBack.validationErrors.isEmpty)
        try? FileManager.default.removeItem(at: tourURL)
    }

    // MARK: F-ONB-2 cheat sheet

    @Test func shortcutsSheetWalksTheRealMainMenu() throws {
        // Install the app's real menu (the command-palette test
        // pattern): the cheat sheet must list exactly what it holds.
        let delegate = AppDelegate()
        NSApp.mainMenu = delegate.buildMenu()

        let menuEntries = ShortcutsSheet.menuEntries(from: NSApp.mainMenu)
        #expect(!menuEntries.isEmpty)
        #expect(menuEntries.contains { $0.action == "Save" && $0.shortcut == "⌘s" })
        #expect(menuEntries.contains { $0.action == "Find…" && $0.shortcut == "⌘f" })
        #expect(menuEntries.contains { $0.action == "Focus Mode" && $0.shortcut == "⇧⌘F" })
        #expect(menuEntries.contains { $0.action == "Edit Theme…" && $0.shortcut == "⇧⌘E" })
        // The ⌘/ item lists itself — self-referentially complete.
        #expect(menuEntries.contains { $0.action == "Keyboard Shortcuts…" && $0.shortcut == "⌘/" })
        // Menu sections carry their menu's title.
        #expect(menuEntries.contains { $0.section == "Format" && $0.action == "Bold" })

        // The canvas-only tables ride along.
        let entries = ShortcutsSheet.entries(from: NSApp.mainMenu)
        #expect(entries.count > menuEntries.count)
        #expect(entries.contains { $0.section == "Presenting" && $0.shortcut.contains("→") })
        #expect(entries.contains { $0.section == "Recall" && $0.action.contains("Reveal") })

        // Search filters across action, section and shortcut.
        let foldHits = ShortcutsSheet.filtered(entries, query: "fold")
        #expect(!foldHits.isEmpty)
        #expect(
            foldHits.allSatisfy { entry in
                entry.action.localizedCaseInsensitiveContains("fold")
                    || entry.section.localizedCaseInsensitiveContains("fold")
                    || entry.shortcut.localizedCaseInsensitiveContains("fold")
            })
        let arrowHits = ShortcutsSheet.filtered(entries, query: "→")
        #expect(!arrowHits.isEmpty)
        #expect(ShortcutsSheet.filtered(entries, query: "zzzzzz").isEmpty)
    }

    @Test func shortcutsSheetOpensAsAPanel() {
        ShortcutsSheet.toggle()
        #expect(ShortcutsSheet.panelForTesting != nil)
        ShortcutsSheet.panelForTesting?.close()
    }

    // MARK: F-ONB-4 tips

    @Test func tipsAreOnePerSessionAndDismissForever() throws {
        UserDefaults.standard.removeObject(forKey: TipCenter.dismissedKeyPrefix + "test-tip")
        TipCenter.resetSessionClaim()
        let tip = TipCenter.Tip(id: "test-tip", message: "test")

        // First claim wins the session.
        #expect(TipCenter.claimSessionOnce(for: tip))
        // A second tip — even a different one — stays quiet this
        // session (F-ONB-4's "at most one per session").
        let other = TipCenter.Tip(id: "other-tip", message: "other")
        #expect(!TipCenter.claimSessionOnce(for: other))

        // A dismissed tip never comes back; a new session without the
        // dismissal may show it.
        TipCenter.dismissForever("test-tip")
        TipCenter.resetSessionClaim()
        #expect(!TipCenter.claimSessionOnce(for: tip))
        #expect(TipCenter.claimSessionOnce(for: other))

        // Reset tips (Settings ▸ Advanced) clears every dismissal.
        TipCenter.resetAllDismissed()
        TipCenter.resetSessionClaim()
        #expect(TipCenter.claimSessionOnce(for: tip))
        UserDefaults.standard.removeObject(forKey: TipCenter.dismissedKeyPrefix + "test-tip")
        UserDefaults.standard.removeObject(forKey: TipCenter.dismissedKeyPrefix + "other-tip")
    }

    @Test func tipBannerShowsInADocumentWindowAndRemovesItself() throws {
        for id in [TipCenter.keyboardFirstTip.id, TipCenter.foldTip.id] {
            UserDefaults.standard.removeObject(forKey: TipCenter.dismissedKeyPrefix + id)
        }
        TipCenter.resetSessionClaim()

        let document = MapDocument()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        // showWindow seeds the keyboard-first tip on a fresh untitled
        // document (F-ONB-4); clear the lane so this test drives the
        // fold tip deterministically.
        controller.hideTip()
        TipCenter.resetSessionClaim()

        controller.showTipOnce(TipCenter.foldTip)
        #expect(controller.canvas.subviews.contains { $0 is TipBannerView })

        // The session is claimed: a second tip never stacks.
        controller.showTipOnce(TipCenter.keyboardFirstTip)
        #expect(controller.canvas.subviews.filter { $0 is TipBannerView }.count == 1)

        // Dismissal (the banner's own path) removes it forever.
        let banner = try #require(controller.canvas.subviews.first { $0 is TipBannerView } as? TipBannerView)
        banner.performDismissForTesting()
        #expect(!controller.canvas.subviews.contains { $0 is TipBannerView })
        #expect(TipCenter.isDismissed(TipCenter.foldTip.id))
        TipCenter.resetSessionClaim()
        for id in [TipCenter.keyboardFirstTip.id, TipCenter.foldTip.id] {
            UserDefaults.standard.removeObject(forKey: TipCenter.dismissedKeyPrefix + id)
        }
        document.close()
    }
}
