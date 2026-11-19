import Foundation
import Testing

@testable import MapCore

/// The `setStudy` command (F-STD-1/3/6, ADR-0015): deck flag, card
/// policy and per-card FSRS states swap exactly, and the inverse
/// restores the pre-state whole — including "no study section at all".
struct StudyCommandTests {
    private func modelWith(deck: Bool?) -> MapModel {
        var model = MapModel.emptyDocument()
        let node = Node(
            id: "n1",
            title: NodeTitle(text: "Cell"),
            study: NodeStudy(card: .auto, fsrsByCard: nil, deck: deck))
        model.nodes[node.id] = node
        model.roots = [node.id]
        return model
    }

    @Test func setStudyReplacesTheWholeSection() throws {
        var model = modelWith(deck: true)
        let graded = FSRSState(due: fixedDate, stability: 3.1, reps: 1, state: .review)
        let next = NodeStudy(card: .on, fsrs: graded, fsrsByCard: ["r": graded], deck: true)

        let command = MapCommand.setStudy(name: "Grade Card", id: "n1", study: next)
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)

        #expect(model.nodes["n1"]?.study == next)
        #expect(model.nodes["n1"]?.study?.fsrs?.reps == 1)
        #expect(model.nodes["n1"]?.study?.fsrsByCard?["r"]?.state == .review)

        try inverse.apply(to: &model)
        #expect(model.nodes["n1"]?.study == NodeStudy(card: .auto, deck: true))
    }

    @Test func setStudyInverseRestoresAMissingSection() throws {
        var model = modelWith(deck: nil)
        model.nodes["n1"]?.study = nil

        let next = NodeStudy(card: .on, deck: true)
        let command = MapCommand.setStudy(name: "Make Study Deck", id: "n1", study: next)
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        #expect(model.nodes["n1"]?.study == next)

        try inverse.apply(to: &model)
        #expect(model.nodes["n1"]?.study == nil)
    }

    @Test func setStudyCanRemoveTheSection() throws {
        var model = modelWith(deck: true)
        let command = MapCommand.setStudy(name: "Mark Card", id: "n1", study: nil)
        let inverse = try command.inverse(in: model)
        try command.apply(to: &model)
        #expect(model.nodes["n1"]?.study == nil)
        try inverse.apply(to: &model)
        #expect(model.nodes["n1"]?.study == NodeStudy(card: .auto, deck: true))
    }

    @Test func setStudyOnAMissingNodeThrowsLeavingTheModelUntouched() throws {
        let model = modelWith(deck: nil)
        var copy = model
        let command = MapCommand.setStudy(name: "Grade Card", id: "nope", study: NodeStudy(card: .on))
        #expect(throws: ArborError.self) {
            _ = try command.inverse(in: copy)
        }
        #expect(throws: ArborError.self) {
            try command.apply(to: &copy)
        }
        #expect(copy == model)
    }

    @Test func duplicateStripsPerCardStatesToo() throws {
        var model = modelWith(deck: true)
        model.nodes["n1"]?.study?.fsrsByCard = ["c1": FSRSState(due: fixedDate, reps: 2)]

        let duplicate = try MapCommand.duplicate(id: "n1", in: model)
        var applied = model
        try duplicate.apply(to: &applied)

        var copyID = ""
        if case .insertSubtrees(let mapping, _) = duplicate {
            copyID = mapping.keys.first!
        }
        let copy = applied.nodes[copyID]?.study
        #expect(copy?.fsrs == nil)
        #expect(copy?.fsrsByCard == nil)
        // The deck flag is content, not history: it travels with the copy.
        #expect(copy?.deck == true)
    }

    @Test func setStudyKeepsTheModelValid() throws {
        var model = modelWith(deck: nil)
        try MapCommand.setStudy(
            name: "Grade Card", id: "n1",
            study: NodeStudy(
                card: .off, fsrs: FSRSState(due: fixedDate), fsrsByCard: ["c2": FSRSState(due: fixedDate)], deck: false)
        ).apply(to: &model)
        #expect(MapValidator.validate(model).isEmpty)
    }
}

/// `study/reviews.jsonl` rides through the package writer (SPEC §8.1):
/// replaced on save, read back on open, absent when never written.
struct PackageStudyLogTests {
    private func packageWithLog() throws -> (FileWrapper, Data) {
        let log = Data(
            "{\"cardID\":\"n1\",\"elapsed\":0,\"grade\":\"good\",\"stateAfter\":\"review\",\"stateBefore\":\"new\",\"ts\":\"2027-01-15T08:00:00.000Z\"}\n"
                .utf8)
        var model = MapModel.emptyDocument()
        model.nodes["n1"] = Node(id: "n1", title: NodeTitle(text: "Card"))
        model.roots = ["n1"]
        let root = try ArborPackage.makeFileWrapper(
            model: model, meta: PackageMeta(formatVersion: ArborFormat.formatVersion, docID: model.docID))
        ArborPackage.setStudyLog(log, in: root)
        return (root, log)
    }

    @Test func logWritesReadsAndReplaces() throws {
        let (root, log) = try packageWithLog()
        let contents = try ArborPackage.read(from: root)
        #expect(contents.studyLogData == log)

        // A second save replaces the entry wholesale (append-only content
        // is the codec's business; the package just swaps the bytes).
        let longer = log + log
        ArborPackage.setStudyLog(longer, in: root)
        #expect(try ArborPackage.read(from: root).studyLogData == longer)

        // map.json keeps round-tripping alongside.
        #expect(try ArborPackage.read(from: root).model.nodes["n1"] != nil)
    }

    @Test func logIsAbsentUntilWrittenAndSurvivesMapRewrites() throws {
        var model = MapModel.emptyDocument()
        model.nodes["n1"] = Node(id: "n1", title: NodeTitle(text: "Card"))
        model.roots = ["n1"]
        let root = try ArborPackage.makeFileWrapper(
            model: model, meta: PackageMeta(formatVersion: ArborFormat.formatVersion, docID: model.docID))
        #expect(try ArborPackage.read(from: root).studyLogData == nil)

        // A truncated tail (interrupted append) is still handed out
        // verbatim; tolerance is the decoder's contract, not the package's.
        let truncated = Data("{\"cardID\":\"n1\",\"ela".utf8)
        ArborPackage.setStudyLog(truncated, in: root)
        #expect(try ArborPackage.read(from: root).studyLogData == truncated)

        // A later map.json update reuses the untouched study wrapper.
        model.nodes["n1"]?.title = NodeTitle(text: "Renamed")
        try ArborPackage.updateFileWrapper(
            root, model: model, meta: PackageMeta(formatVersion: ArborFormat.formatVersion, docID: model.docID))
        #expect(try ArborPackage.read(from: root).studyLogData == truncated)
        #expect(try ArborPackage.read(from: root).model.nodes["n1"]?.title.text == "Renamed")
    }
}
