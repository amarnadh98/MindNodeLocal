import Foundation
import Testing

@testable import MapCore

/// The M6 presentation-authoring command (F-PRE-2/3): every authored
/// change rides one grouped `setPresentations` replace, whose inverse
/// restores the pre-action list exactly — one undo step each.
struct PresentationCommandTests {
    private func deck() -> MapModel {
        var model = MapModel.emptyDocument(docID: "slides")
        let root = Node(id: "root", title: NodeTitle(text: "root"))
        model.nodes[root.id] = root
        model.roots = [root.id]
        model.presentations = [
            Presentation(
                id: "deck-1", name: "Talk",
                slides: [
                    Slide(
                        id: "s1", title: "One",
                        camera: SlideCamera(x: 0, y: 0, scale: 1), focus: ["root"],
                        notes: "opening")
                ])
        ]
        return model
    }

    @Test func replaceRoundTripsThroughItsInverse() throws {
        let model = deck()
        let newSlides = [
            Slide(id: "s2", title: "Two", camera: SlideCamera(x: 10, y: 4, scale: 2), build: ["root"]),
            Slide(id: "s3", title: "Three", folded: ["root"], dimOthers: true),
        ]
        let command = MapCommand.group(
            name: "Add Slide", commands: [.setPresentations([Presentation(id: "deck-2", name: "N", slides: newSlides)])]
        )
        let inverse = try command.inverse(in: model)

        var applied = model
        try command.apply(to: &applied)
        #expect(applied.presentations?.count == 1)
        #expect(applied.presentations?.first?.slides.count == 2)
        #expect(applied.presentations?.first?.slides.first?.build == ["root"])

        var restored = applied
        try inverse.apply(to: &restored)
        #expect(restored == model)
    }

    @Test func clearingTheListInvertsFromNilAndBack() throws {
        var model = deck()
        model.presentations = nil
        let command = MapCommand.setPresentations(nil)
        let inverse = try command.inverse(in: model)
        var applied = model
        try command.apply(to: &applied)
        #expect(applied.presentations == nil)
        var restored = applied
        try inverse.apply(to: &restored)
        #expect(restored == model)
    }

    @Test func inverseSnapshotsTheNilPreState() throws {
        var model = deck()
        model.presentations = nil
        let command = MapCommand.setPresentations(
            [Presentation(id: "d", name: "Deck", slides: [])])
        let inverse = try command.inverse(in: model)
        var applied = model
        try command.apply(to: &applied)
        #expect(applied.presentations?.count == 1)
        var restored = applied
        try inverse.apply(to: &restored)
        #expect(restored.presentations == nil)
    }

    @Test func groupCarriesTheActionNameForUndo() {
        let command = MapCommand.group(name: "Add Slide", commands: [.setPresentations(nil)])
        #expect(command.displayName == "Add Slide")
        #expect(MapCommand.setPresentations(nil).displayName == "Edit Slides")
    }

    /// The authoring round trip a sidebar does: add, rename, reorder,
    /// duplicate, notes, build order, delete — each a grouped replace,
    /// each exactly inverted, in sequence.
    @Test func authoredSequenceFullyUndoes() throws {
        var model = deck()
        let original = model
        var undoStack: [MapCommand] = []

        func perform(_ name: String, _ mutate: (inout [Presentation]) -> Void) throws {
            var list = model.presentations ?? []
            mutate(&list)
            let command = MapCommand.group(name: name, commands: [.setPresentations(list.isEmpty ? nil : list)])
            undoStack.append(try command.inverse(in: model))
            try command.apply(to: &model)
        }

        try perform("Add Slide") { $0[0].slides.append(Slide(id: "s2", title: "Two")) }
        try perform("Reorder Slide") { $0[0].slides.swapAt(0, 1) }
        try perform("Rename Slide") { $0[0].slides[1].title = "Deux" }
        try perform("Set Notes") { $0[0].slides[0].notes = "hello" }
        try perform("Duplicate Slide") { $0[0].slides.insert($0[0].slides[0], at: 0) }
        try perform("Set Build Order") { $0[0].slides[0].build = ["root"] }
        try perform("Delete Slide") { $0[0].slides.removeFirst() }
        try perform("New Presentation") {
            $0.append(Presentation(id: "deck-2", name: "Second"))
        }
        try perform("Rename Presentation") { $0[1].name = "Second Talk" }
        try perform("Delete Presentation") { $0.remove(at: 1) }

        #expect(model.presentations?.first?.slides.count == 2)
        #expect(model.presentations?.first?.slides.first?.title == "Two")
        #expect(model.presentations?.first?.slides.first?.notes == "hello")
        #expect(model.presentations?.first?.slides.last?.title == "Deux")

        while let undo = undoStack.popLast() {
            try undo.apply(to: &model)
        }
        #expect(model == original)
    }
}
