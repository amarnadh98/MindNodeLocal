import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

// `MapCore` declares the schema-level `CanvasViewState` for `map.json`'s
// `view` field; these tests target CanvasKit's live copy (ADR-0005),
// so the name is pinned to the right module.
private typealias CanvasViewState = CanvasKit.CanvasViewState

/// A scene containing only the listed ids, for selection sanitization.
private func tinyScene(ids: [String]) -> CanvasScene {
    let style = PaperTheme.resolvedStyle(level: 0, level1Index: 0, variant: .light)
    var nodes: [String: SceneNode] = [:]
    for (index, id) in ids.enumerated() {
        nodes[id] = SceneNode(
            id: id, frame: CGRect(x: 0, y: CGFloat(index * 100), width: 100, height: 40),
            style: style, title: NodeTitle(text: id), level: 0, level1Index: 0)
    }
    return CanvasScene(
        nodes: nodes, branches: [],
        canvasColor: CGColor(srgbRed: 0.98, green: 0.97, blue: 0.97, alpha: 1))
}

/// A fresh directory the test owns and removes afterwards.
private func freshTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "viewstate-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct ViewStateTests {
    @Test func defaultsMatchAFreshCamera() {
        let state = CanvasViewState()
        #expect(state.scale == 1)
        #expect(state.origin == .zero)
        #expect(state.selection.isEmpty)
        #expect(state.activeView == .map)
        #expect(state.camera == Camera())
    }

    @Test func sanitizedDropsSelectionIdsMissingFromTheScene() {
        let state = CanvasViewState(selection: ["a", "gone", "b"])
        let sanitized = state.sanitized(for: tinyScene(ids: ["a", "b"]))
        // Missing (deleted or folded) ids go; present ids keep order.
        #expect(sanitized.selection == ["a", "b"])
        #expect(state.selection.count == 3)  // no in-place mutation
        #expect(sanitized.scale == state.scale)
    }
}

struct ViewStateStoreTests {
    @Test func roundTripsThroughATempDirectory() throws {
        let base = try freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ViewStateStore(baseURL: base)
        let state = CanvasViewState(
            camera: Camera(origin: CGPoint(x: -42.5, y: 100), scale: 1.5),
            selection: ["root", "branch-1"], activeView: .map)

        try store.save(state, docID: "doc-1")
        #expect(store.load(docID: "doc-1") == state)
        // Other documents are untouched.
        #expect(store.load(docID: "doc-2") == nil)
    }

    @Test func overwritesOnSecondSave() throws {
        let base = try freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ViewStateStore(baseURL: base)
        try store.save(CanvasViewState(scale: 0.5), docID: "doc")
        try store.save(CanvasViewState(scale: 2), docID: "doc")
        #expect(store.load(docID: "doc")?.scale == 2)
    }

    @Test func corruptFileReturnsNilWithoutThrowing() throws {
        let base = try freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ViewStateStore(baseURL: base)
        try Data("{ not json".utf8).write(to: store.fileURL(forDocID: "broken"))
        #expect(store.load(docID: "broken") == nil)
        // A JSON document of the wrong shape is equally tolerable.
        try Data("[]".utf8).write(to: store.fileURL(forDocID: "wrong-shape"))
        #expect(store.load(docID: "wrong-shape") == nil)
    }

    @Test func missingFileReturnsNil() {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "viewstate-tests-missing", directoryHint: .isDirectory)
        let store = ViewStateStore(baseURL: base)
        #expect(store.load(docID: "never-saved") == nil)
    }

    @Test func defaultBaseDirectoryLivesUnderApplicationSupport() {
        let url = ViewStateStore.defaultBaseURL()
        #expect(url.path.contains("Application Support"))
        #expect(url.path.contains("Arbor/ViewState"))
    }

    @Test func docIDIsFlattenedIntoOneFileComponent() {
        let store = ViewStateStore(baseURL: FileManager.default.temporaryDirectory)
        #expect(store.fileURL(forDocID: "123e4567-e13b").lastPathComponent == "123e4567-e13b.json")
        #expect(store.fileURL(forDocID: "../../etc/passwd").lastPathComponent == "______etc_passwd.json")
        #expect(store.fileURL(forDocID: "").lastPathComponent == "unknown.json")
    }
}
