import AppKit
import Carbon.HIToolbox
import Foundation
import MapCore
import MapIO
import Testing

@testable import Arbor

/// Quick Entry's pieces (F-QEN-1/2/3): the hotkey spec codec, the
/// Carbon registration lifecycle, the menu-bar extra preference, the
/// menu wiring, and the pure outline→command assembly every capture
/// action goes through.
/// The suite serializes: the hotkey center, the coordinator's panel and
/// the status item are process-wide singletons, so tests observe one
/// shared machine.
@Suite(.serialized)
@MainActor
struct QuickEntryTests {
    // MARK: F-QEN-1 hotkey plumbing

    @Test func hotkeySpecRoundTripsThroughDefaults() {
        let spec = HotkeySpec(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: 4096)
        let raw = spec.defaultsString
        #expect(HotkeySpec(defaultsString: raw) == spec)
        #expect(HotkeySpec(defaultsString: "garbage") == nil)
        #expect(HotkeySpec(defaultsString: "") == nil)
    }

    @Test func defaultHotkeyIsControlOptionSpace() {
        #expect(HotkeySpec.quickEntryDefault.keyCode == UInt32(kVK_Space))
        #expect(HotkeySpec.quickEntryDefault.carbonModifiers == 4096 + 2048)
        #expect(HotkeySpec.quickEntryDefault.symbolRepresentation == "⌃⌥Space")
    }

    @Test func eventModifiersMapToCarbonBits() {
        let flags: NSEvent.ModifierFlags = [.control, .option]
        let spec = HotkeySpec(keyCode: 49, eventModifiers: flags)
        #expect(spec.carbonModifiers == HotkeySpec.quickEntryDefault.carbonModifiers)
        #expect(spec == .quickEntryDefault)
        // The inverse mapping (for the menu item's mask) round-trips.
        #expect(spec.eventModifierFlags == [.control, .option])
    }

    @Test func menuKeyEquivalentsRepresentTheSpec() {
        #expect(HotkeySpec.quickEntryDefault.keyEquivalentString == " ")
        let letter = HotkeySpec(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: 4096)
        #expect(letter.keyEquivalentString == "j")
        #expect(letter.eventModifierFlags == [.control])
        // Keys a menu can't represent stay Carbon-only.
        #expect(HotkeySpec(keyCode: 999, carbonModifiers: 4096).keyEquivalentString.isEmpty)
    }

    @Test func frontmostPressesDontDoubleFireTheDefaultHotkey() throws {
        // While Arbor is frontmost, the menu item with the same
        // equivalent delivers ⌃⌥Space itself; the Carbon handler must
        // not add a second toggle to the same press.
        let menu = AppDelegate().buildMenu()
        let fileMenu = try #require(menu.items.first(where: { $0.title == "File" })?.submenu)
        let quickEntry = try #require(fileMenu.items.first(where: { $0.title == "Quick Entry" }))
        #expect(quickEntry.keyEquivalent == HotkeySpec.quickEntryDefault.keyEquivalentString)
        #expect(
            quickEntry.keyEquivalentModifierMask
                == HotkeySpec.quickEntryDefault.eventModifierFlags)
    }

    @Test func coordinatorRegistersPersistsAndReRegistersTheHotkey() {
        let defaults = UserDefaults(suiteName: "quick-entry-tests-\(UUID().uuidString)")!
        QuickEntryCoordinator.shared.start(defaults: defaults)

        // The default registration is live with Carbon.
        #expect(GlobalHotkeyCenter.shared.activeSpec == .quickEntryDefault)

        // A Settings change swaps it atomically and persists the spec.
        let replacement = HotkeySpec(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: 4096)
        #expect(QuickEntryCoordinator.shared.updateHotkey(replacement, defaults: defaults))
        #expect(GlobalHotkeyCenter.shared.activeSpec == replacement)
        #expect(defaults.string(forKey: AppSettings.quickEntryHotkeyKey) == replacement.defaultsString)

        // A fresh coordinator start picks the persisted spec up.
        QuickEntryCoordinator.shared.registerHotkeyFromPreference(defaults: defaults)
        #expect(GlobalHotkeyCenter.shared.activeSpec == replacement)

        // Restore the default.
        QuickEntryCoordinator.shared.updateHotkey(.quickEntryDefault, defaults: defaults)
        #expect(GlobalHotkeyCenter.shared.activeSpec == .quickEntryDefault)
    }

    @Test func menuBarExtraPreferenceTogglesTheStatusItem() {
        let defaults = UserDefaults(suiteName: "quick-entry-tests-\(UUID().uuidString)")!
        QuickEntryCoordinator.shared.setMenuBarExtra(true, defaults: defaults)
        #expect(QuickEntryCoordinator.shared.statusItem != nil)
        #expect(defaults.bool(forKey: AppSettings.quickEntryMenuBarExtraKey))

        QuickEntryCoordinator.shared.setMenuBarExtra(false, defaults: defaults)
        #expect(QuickEntryCoordinator.shared.statusItem == nil)

        QuickEntryCoordinator.shared.applyMenuBarExtraPreference(defaults: defaults)
        #expect(QuickEntryCoordinator.shared.statusItem == nil)

        QuickEntryCoordinator.shared.setMenuBarExtra(true, defaults: defaults)
    }

    // MARK: menu wiring

    @Test func fileAndAppMenusCarryQuickEntrySettingsAndSafetyItems() throws {
        let menu = AppDelegate().buildMenu()
        let fileMenu = try #require(menu.items.first(where: { $0.title == "File" })?.submenu)
        let quickEntry = try #require(fileMenu.items.first(where: { $0.title == "Quick Entry" }))
        // ⌃⌥Space as the item's equivalent (SPEC §6.1).
        #expect(quickEntry.keyEquivalent == " ")
        #expect(quickEntry.keyEquivalentModifierMask == [.control, .option])

        let appMenu = try #require(menu.items.first?.submenu)
        let settings = try #require(appMenu.items.first(where: { $0.title == "Settings…" }))
        #expect(settings.keyEquivalent == ",")
        #expect(settings.keyEquivalentModifierMask == [.command])

        // F-DOC-1: the safety items.
        let revert = try #require(fileMenu.items.first(where: { $0.title == "Revert To" })?.submenu)
        #expect(revert.items.contains { $0.title == "Last Saved" })
        #expect(revert.items.contains { $0.title == "Browse All Versions…" })
        #expect(fileMenu.items.contains { $0.title == "Duplicate" })
        #expect(fileMenu.items.contains { $0.title == "Lock" })
        #expect(fileMenu.items.contains { $0.title == "Unlock" })
    }

    @Test func quickEntryMenuItemOpensThePanel() {
        let delegate = AppDelegate()
        delegate.quickEntryAction(nil)
        #expect(QuickEntryCoordinator.shared.panelController?.isVisible == true)
        QuickEntryCoordinator.shared.togglePanel()
        #expect(QuickEntryCoordinator.shared.panelController?.isVisible != true)
    }

    // MARK: F-QEN-2 outline → command assembly

    @Test func createMapCommandMakesTheFirstLineTheRoot() throws {
        let text = "Trip\n\tPack bags\n\tRoute\n\t\t\tFerry"
        let subtrees = try #require(QuickEntryOutline.subtrees(from: text))
        let command = try QuickEntryOutline.createMapCommand(
            subtrees: subtrees, in: MapModel.emptyDocument())

        var model = MapModel.emptyDocument()
        try command.apply(to: &model)
        let rootID = try #require(model.roots.first)
        #expect(model.nodes.count == 4)
        #expect(model.nodes[rootID]?.title.text == "Trip")
        let children = model.nodes[rootID]?.children ?? []
        #expect(children.count == 2)
        #expect(model.nodes[children[0]]?.title.text == "Pack bags")
        #expect(model.nodes[children[1]]?.title.text == "Route")
        // Over-deep indents clamp to parent+1 (the paste parser's rule).
        let routeChildren = model.nodes[children[1]]?.children ?? []
        #expect(routeChildren.map { model.nodes[$0]?.title.text } == ["Ferry"])
    }

    @Test func appendCommandAppendsUnderTheTargetNode() throws {
        var target = MapModel.emptyDocument()
        let root = UUID().uuidString
        target.roots = [root]
        target.nodes[root] = Node(id: root, title: NodeTitle(text: "Root"))
        let existing = UUID().uuidString
        target.nodes[existing] = Node(id: existing, parent: root, title: NodeTitle(text: "Existing"))
        target.nodes[root]?.children = [existing]

        let subtrees = try #require(QuickEntryOutline.subtrees(from: "A\n\tB"))
        let command = try QuickEntryOutline.appendCommand(
            subtrees: subtrees, parent: root, in: target)
        var model = target
        try command.apply(to: &model)
        // The capture's top line becomes one new child under the target…
        let children = model.nodes[root]?.children ?? []
        #expect(children.count == 2)
        #expect(model.nodes[children[0]]?.title.text == "Existing")
        #expect(model.nodes[children[1]]?.title.text == "A")
        // …and its own outline nests below it.
        #expect(model.nodes[children[1]]?.children.map { model.nodes[$0]?.title.text } == ["B"])
    }

    @Test func emptyCaptureYieldsNoSubtrees() {
        #expect(QuickEntryOutline.subtrees(from: "") == nil)
        #expect(QuickEntryOutline.subtrees(from: "   \n  \t ") == nil)
        #expect(QuickEntryOutline.subtrees(from: "\n\n") == nil)
    }

    @Test func outlineAcceptsMarkdownAndTabIndents() throws {
        // The paste parser's auto-detection is a Quick Entry feature:
        // pasted Markdown and 2-space indents parse the same way.
        let spaces = try #require(QuickEntryOutline.subtrees(from: "Root\n  Kid"))
        let tabs = try #require(QuickEntryOutline.subtrees(from: "Root\n\tKid"))
        #expect(spaces[0].children.count == tabs[0].children.count)

        let markdown = try #require(
            QuickEntryOutline.subtrees(from: "# Root\n- kid one\n- kid two"))
        #expect(markdown[0].children.count == 2)
    }

    // MARK: F-QEN-3 clipboard pull

    @Test func pasteAsOutlinePullsTheClipboardIntoTheEditor() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("Clip line one\n\tClip line two", forType: .string)

        let controller = QuickEntryPanelController()
        controller.clipboard = pasteboard
        controller.pasteOutlineAction(nil)
        #expect(controller.text == "Clip line one\n\tClip line two")
    }
}
