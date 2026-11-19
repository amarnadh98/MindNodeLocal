import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Hosted view-state tests (F-CAN-8, M1 slice 7a): the sidecar flushes on
/// document close and debounced after camera/selection moves, reopens
/// restore INSTEAD of zoom-to-fit, stale selection ids sanitize away,
/// and none of it ever dirties the document.
@MainActor
struct ViewStateRestoreTests {
    /// root ─ a, b (docID fixed so the sidecar is findable on reopen).
    private static func viewStateModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "viewstate-doc")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for (id, parent) in [("root", nil as String?), ("a", "root"), ("b", "root")] {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: "node \(id)"),
                created: date, modified: date)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        return model
    }

    @Test func savedViewStateRestoresOnReopenInsteadOfZoomToFit() throws {
        let url = try writeViewStateFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewstate-\(UUID().uuidString)", isDirectory: true)

        let document = try openShownDocument(at: url, storeBase: baseURL)
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let canvas = controller.canvas

        // Pan + select, then close: the close must flush the sidecar.
        let savedCamera = Camera(origin: CGPoint(x: 321, y: 123), scale: 1.5)
        canvas.camera = savedCamera
        canvas.setSelection(["a"])
        document.close()
        #expect(ViewStateStore(baseURL: baseURL).load(docID: "viewstate-doc") != nil)

        // Reopen: camera and selection come back as they were.
        let reopened = try openShownDocument(at: url, storeBase: baseURL)
        let restoredCanvas =
            (try #require(
                reopened.windowControllers.first as? DocumentWindowController)).canvas
        #expect(restoredCanvas.camera == savedCamera)
        #expect(restoredCanvas.selection == ["a"])
        #expect(!restoredCanvas.needsInitialFit)
        // Restoring is not a model mutation: the document stays clean.
        #expect(!reopened.isDocumentEdited)
        reopened.close()
    }

    @Test func cameraChangesDebounceToTheStoreWithoutDirtying() async throws {
        let url = try writeViewStateFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewstate-\(UUID().uuidString)", isDirectory: true)
        let store = ViewStateStore(baseURL: baseURL)

        let document = try openShownDocument(at: url, storeBase: baseURL)
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        controller.viewStateSaveDelay = .milliseconds(50)
        #expect(store.load(docID: "viewstate-doc") == nil)

        controller.canvas.camera = Camera(origin: CGPoint(x: -50, y: 60), scale: 2)
        controller.canvas.setSelection(["b"])
        try await Task.sleep(for: .seconds(1))

        let state = try #require(store.load(docID: "viewstate-doc"))
        #expect(state.camera == Camera(origin: CGPoint(x: -50, y: 60), scale: 2))
        #expect(state.selection == ["b"])
        // A pan is not a mutation (ADR-0005): the document stays clean.
        #expect(!document.isDocumentEdited)
        document.close()
    }

    @Test func noSidecarFallsBackToZoomToFit() throws {
        let url = try writeViewStateFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // A store base with nothing in it: the open fits instead.
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewstate-\(UUID().uuidString)", isDirectory: true)

        let document = try openShownDocument(at: url, storeBase: baseURL)
        let canvas =
            (try #require(
                document.windowControllers.first as? DocumentWindowController)).canvas
        #expect(!canvas.needsInitialFit)
        #expect(canvas.selection.isEmpty)
        // No sidecar → the classic first-open behaviour: zoom-to-fit.
        let scene = try #require(canvas.scene)
        let visible = canvas.camera.visibleRect(viewportSize: canvas.bounds.size)
        #expect(visible.contains(CGPoint(x: scene.bounds.midX, y: scene.bounds.midY)))
        document.close()
    }

    @Test func staleSelectionIDsSanitizeOutOnRestore() throws {
        let url = try writeViewStateFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewstate-\(UUID().uuidString)", isDirectory: true)
        // A sidecar saved by a session where an extra node existed.
        let store = ViewStateStore(baseURL: baseURL)
        try store.save(
            CanvasViewState(
                camera: Camera(origin: CGPoint(x: 10, y: 20), scale: 1), selection: ["a", "ghost"]),
            docID: "viewstate-doc")

        let document = try openShownDocument(at: url, storeBase: baseURL)
        let canvas =
            (try #require(
                document.windowControllers.first as? DocumentWindowController)).canvas
        #expect(canvas.camera == Camera(origin: CGPoint(x: 10, y: 20), scale: 1))
        #expect(canvas.selection == ["a"])
        document.close()
    }

    // MARK: arrow navigation (F-CAN-4) over a real document window

    @Test func arrowKeyDownMovesTheSelection() throws {
        let url = try writeViewStateFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewstate-\(UUID().uuidString)", isDirectory: true)

        let document = try openShownDocument(at: url, storeBase: baseURL)
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let canvas = controller.canvas
        canvas.setSelection(["root"])

        // → dives into the subtree on the right; the two branches sit at
        // the root's exact height in this balanced map, so ↓ correctly
        // has no target from the root.
        canvas.keyDown(with: Self.keyEvent("\u{f703}"))
        #expect(!canvas.selection.isEmpty)
        #expect(canvas.selection != ["root"])
        let moved = try #require(canvas.selection.first)
        #expect(moved == "a" || moved == "b")

        document.close()
    }

    // MARK: helpers

    private func writeViewStateFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewstate-\(UUID().uuidString).arbor")
        try ArborPackage.write(
            Self.viewStateModel(), meta: PackageMeta(docID: "viewstate-doc"), to: url)
        return url
    }

    private func openShownDocument(at url: URL, storeBase: URL) throws -> MapDocument {
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        controller.viewStateStore = ViewStateStore(baseURL: storeBase)
        controller.showWindow(nil)
        return document
    }

    private static func keyEvent(_ key: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    }
}
