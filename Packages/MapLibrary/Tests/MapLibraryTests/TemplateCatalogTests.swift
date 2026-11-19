import Foundation
import MapCore
import Testing

@testable import MapLibrary

@Suite struct TemplateCatalogTests {
    @Test func twelveBuiltinsWithExpectedNames() {
        let names = TemplateCatalog.builtins.map(\.name)
        #expect(
            names == [
                "Brainstorm", "Project Plan", "Meeting Notes", "Book Summary",
                "Lecture Notes", "Concept Study", "SWOT", "Decision Matrix",
                "Weekly Review", "OKRs", "Fishbone RCA", "Timeline",
            ])
        #expect(TemplateCatalog.builtins.allSatisfy { !$0.model.nodes.isEmpty })
    }

    @Test(arguments: TemplateCatalog.builtins)
    func builtinValidatesAndOpensAsPackage(template: TemplateCatalog.Template) throws {
        #expect(MapValidator.validate(template.model).isEmpty)

        // "Open": write it as a real .arbor package and read it back.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(
            template.model,
            meta: PackageMeta(modified: Date(timeIntervalSinceReferenceDate: 1), docID: template.model.docID),
            to: url)
        let contents = try ArborPackage.read(at: url)
        #expect(contents.model == template.model)
        #expect(contents.validationErrors.isEmpty)
    }

    @Test func materializeCreatesFreshIdsAndNeverEditsTheSource() throws {
        let source = TemplateCatalog.builtins.first { $0.id == "concept-study" }!
        let before = source.model
        let materialized = TemplateCatalog.materialize(source.model)

        #expect(materialized.docID != source.model.docID)
        #expect(materialized.nodes.count == source.model.nodes.count)
        #expect(materialized.roots.count == 1)
        #expect(materialized.view == nil)
        // Fresh node ids: no id survives, parent/child structure intact.
        #expect(Set(materialized.nodes.keys).isDisjoint(with: Set(source.model.nodes.keys)))
        let rootID = materialized.roots[0]
        #expect(materialized.nodes[rootID]?.children.count == source.model.nodes[source.model.roots[0]]!.children.count)
        for childID in materialized.nodes[rootID]?.children ?? [] {
            #expect(materialized.nodes[childID]?.parent == rootID)
        }
        // The materialized copy still validates.
        #expect(MapValidator.validate(materialized).isEmpty)
        // The template itself is untouched.
        #expect(source.model == before)
    }

    @Test func userTemplatesLoadFromDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("templates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = TemplateCatalog.userTemplates(in: directory)
        #expect(empty.isEmpty)

        let saved = TemplateCatalog.builtins[0]
        try ArborPackage.write(
            saved.model,
            meta: PackageMeta(modified: Date(timeIntervalSinceReferenceDate: 1), docID: saved.model.docID),
            to: directory.appendingPathComponent("My Start.arbor"))

        let loaded = TemplateCatalog.userTemplates(in: directory)
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "My Start")
        #expect(loaded.first?.model == saved.model)
    }
}
