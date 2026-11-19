import AppKit
import Foundation
import MapCore
import MapLibrary
import Testing

@testable import Arbor

/// Hosted tests for the Library window slice (F-LIB): the window opens,
/// templates create untitled documents, Save as Template writes a
/// package, saves feed the index, and the index's full-text search
/// finds nodes in a fixture package.
@MainActor
struct LibraryTests {
    /// A coordinator pointed at throwaway index/bookmark/template
    /// locations, so tests never touch the user's real library.
    private func makeCoordinator() throws -> (LibraryCoordinator, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = LibraryCoordinator(
            indexURL: root.appendingPathComponent("Index.sqlite"),
            bookmarkStore: AppBookmarkStore(baseURL: root.appendingPathComponent("Bookmarks")),
            templateStore: TemplateStore(directory: root.appendingPathComponent("Templates"))
        )
        return (coordinator, { try? FileManager.default.removeItem(at: root) })
    }

    private func fixturePackage(title: String, node: String) throws -> URL {
        var model = MapModel(docID: UUID().uuidString)
        let rootID = UUID().uuidString
        model.nodes[rootID] = Node(id: rootID, title: NodeTitle(text: title))
        model.roots = [rootID]
        let childID = UUID().uuidString
        model.nodes[childID] = Node(
            id: childID, parent: rootID, title: NodeTitle(text: node))
        model.nodes[rootID]?.children = [childID]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).arbor")
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)
        return url
    }

    @Test func libraryWindowOpens() throws {
        let (coordinator, cleanup) = try makeCoordinator()
        defer { cleanup() }

        #expect(coordinator.windowController == nil)
        coordinator.showLibrary()
        let controller = try #require(coordinator.windowController)
        #expect(controller.window?.title == "Library")
        #expect(controller.window?.isVisible == true)

        // One Library window (SPEC §4): showing again reveals it.
        coordinator.showLibrary()
        #expect(coordinator.windowController === controller)
    }

    @Test func newFromTemplateCreatesUntitledDocumentWithTemplateNodes() throws {
        let (coordinator, cleanup) = try makeCoordinator()
        defer { cleanup() }

        let template = TemplateCatalog.builtins.first { $0.id == "brainstorm" }!
        let document = try coordinator.templateStore.newDocument(from: template)

        #expect(document.fileURL == nil)
        #expect(document.model.docID != template.model.docID)
        #expect(document.model.nodes.count == template.model.nodes.count)
        let templateRootTitle = template.model.nodes[template.model.roots[0]]!.title.text
        let documentRootTitle = document.model.nodes[document.model.roots[0]]!.title.text
        #expect(documentRootTitle == templateRootTitle)
        // Untitled documents with content are dirty, so ⌘S saves.
        #expect(document.isDocumentEdited)
    }

    @Test func saveAsTemplateWritesAPackage() throws {
        let (coordinator, cleanup) = try makeCoordinator()
        defer { cleanup() }

        var model = MapModel(docID: UUID().uuidString)
        let rootID = UUID().uuidString
        model.nodes[rootID] = Node(id: rootID, title: NodeTitle(text: "My Weekly Plan"))
        model.roots = [rootID]

        let url = try coordinator.templateStore.saveAsTemplate(model: model, name: "Weekly Plan")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let templates = coordinator.templateStore.allTemplates()
        let saved = templates.first { $0.name == "Weekly Plan" }
        #expect(saved != nil)
        #expect(saved?.model.nodes.count == model.nodes.count)
        #expect(saved?.model.nodes[saved!.model.roots[0]]?.title.text == "My Weekly Plan")
        #expect(saved?.model.docID != model.docID)
        // The twelve built-ins are still listed.
        #expect(templates.contains { $0.id == "swot" })
    }

    @Test func savingADocumentFeedsTheIndexThroughTheSaveNotification() async throws {
        let (coordinator, cleanup) = try makeCoordinator()
        defer { cleanup() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m5-save-\(UUID().uuidString).arbor")
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        try document.writeSafely(to: url, ofType: AppIdentity.documentUTI, for: .saveOperation)

        // The notification handler reindexes off the main actor; poll
        // briefly for the entry to land.
        var entry: LibraryEntry?
        for _ in 0..<50 {
            entry = try? await coordinator.service.database.entry(at: url)
            if entry != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(entry?.path == url.resolvingSymlinksInPath().path)
    }

    @Test func searchFindsNodeInIndexedFixture() async throws {
        let (coordinator, cleanup) = try makeCoordinator()
        defer { cleanup() }

        let url = try fixturePackage(title: "Zoology", node: "Mitochondrial Uniqueness")
        try await coordinator.service.database.indexPackage(at: url)

        let hits = try await coordinator.service.database.searchNodes("mitochondrial")
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Mitochondrial Uniqueness")
        #expect(hits.first?.docID != nil)

        let maps = try await coordinator.service.database.search("mitochondrial")
        #expect(maps.map(\.path).contains(url.resolvingSymlinksInPath().path))

        // The UI model surfaces the same hit through the search field.
        let model = LibraryModel(service: coordinator.service, templateStore: coordinator.templateStore)
        model.searchQuery = "mitochondrial"
        await model.reload()
        #expect(model.entries.contains { $0.path == url.resolvingSymlinksInPath().path })
    }
}
