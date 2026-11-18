import Foundation
import Testing

@testable import MapCore

@Test func emptyDocumentRoundTrips() throws {
    let model = MapModel.emptyDocument()
    let decoded = try MapDocumentCoder.roundTrip(model)
    #expect(decoded == model)
}

@Test func fullNodeRoundTrips() throws {
    let rootID = UUID().uuidString
    let childID = UUID().uuidString
    let tagID = UUID().uuidString
    let created = Date(timeIntervalSince1970: 1_800_000_000.25)

    let root = Node(
        id: rootID,
        children: [childID],
        title: NodeTitle(
            text: "Central Idea",
            runs: [Run(range: [0, 7], bold: true, color: "#E5484D", link: "https://example.com")]),
        note: "A **bold** note",
        structure: "mindmap.balanced",
        side: .right,
        offset: ModelOffset(x: 12, y: -4),
        folded: false,
        width: NodeWidth(mode: .fixed, value: 320),
        style: NodeStylePatch(
            shape: .underline, fill: "#12A594", borderWidth: 2, shadow: .raised,
            imagePlacement: .above),
        markers: ["sf:star.fill", "emoji:💡", "sticker:priority-1"],
        image: NodeImage(asset: "sha256.png", size: [200, 120], placement: .right),
        attachments: [Attachment(asset: "sha256.pdf", name: "Paper.pdf")],
        link: "x-arbor://open?doc=abc",
        source: SourceRef(url: "https://youtube.com/watch?v=x", page: nil, time: 93.5, excerpt: "quote"),
        tags: [tagID],
        task: NodeTask(done: true, due: "2026-12-01", priority: 2, repeat: "weekly", reminderID: "EK1"),
        fields: ["f1": "value"],
        type: "concept",
        study: NodeStudy(
            card: .on,
            fsrs: FSRSState(
                due: created, stability: 3.1, difficulty: 5.2, elapsedDays: 2,
                scheduledDays: 4, reps: 4, lapses: 0, state: .review, lastReview: created)),
        math: true,
        numbering: .decimal,
        created: created,
        modified: created,
        modifiedBy: .ai
    )
    let child = Node(
        id: childID,
        parent: rootID,
        title: NodeTitle(
            text: "Child",
            runs: [Run(range: [0, 3], italic: true, code: true, highlight: "#FFC53D", font: "SF Mono", size: 14)]),
        task: NodeTask(done: false),
        created: created,
        modified: created
    )

    var model = MapModel(
        title: "Round Trip",
        theme: ThemeSelection(
            id: "paper", overrides: ThemePatch(canvasColor: "#FAF9F7", paletteColors: ["#E5484D"], baseFont: "SF Pro")),
        appearance: .dark,
        roots: [rootID],
        nodes: [rootID: root, childID: child],
        connections: [
            Connection(
                id: UUID().uuidString, from: rootID, to: childID, label: "relates",
                control: ModelOffset(x: 40, y: 0),
                style: ConnectionStyle(color: "#8E8E93", width: 1.5, dash: true, arrowheads: .end, lineStyle: .straight)
            )
        ],
        boundaries: [Boundary(id: UUID().uuidString, nodes: [childID], title: "Scope")],
        summaries: [Summary(id: UUID().uuidString, parent: rootID, range: [childID, childID], node: childID)],
        tags: [Tag(id: tagID, name: "exam", color: "#E5484D")],
        fieldDefs: [FieldDef(id: "f1", name: "Due", kind: "date")],
        presentations: [
            Presentation(
                id: UUID().uuidString, name: "Talk",
                slides: [
                    Slide(
                        id: UUID().uuidString, title: "Overview",
                        camera: SlideCamera(x: 10, y: 20, scale: 1.5), folded: [childID],
                        focus: [rootID], dimOthers: true, build: [childID],
                        notes: "Welcome")
                ])
        ],
        studySettings: StudySettings(newPerDay: 30, retention: 0.85),
        view: ViewState(camera: SlideCamera(x: 1, y: 2, scale: 3), selection: [rootID], mode: .sideBySide),
        filters: [SavedFilter(id: UUID().uuidString, name: "Open", query: "task:open")]
    )
    model.formatVersion = ArborFormat.formatVersion

    let decoded = try MapDocumentCoder.roundTrip(model)
    #expect(decoded == model)
}

@Test func encodingIsDeterministic() throws {
    let model = try sampleTree()
    let first = try MapDocumentCoder.encode(model)
    let second = try MapDocumentCoder.encode(model)
    #expect(first == second)
}

@Test func malformedJSONThrowsTypedError() {
    #expect(throws: ArborError.self) {
        _ = try MapDocumentCoder.decode(Data("not json".utf8))
    }
}

func sampleTree() throws -> MapModel {
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000.25)
    let rootID = UUID().uuidString
    let nodeA = UUID().uuidString
    let nodeB = UUID().uuidString
    let root = Node(
        id: rootID, children: [nodeA, nodeB], title: NodeTitle(text: "Root"), created: timestamp,
        modified: timestamp)
    let childA = Node(
        id: nodeA, parent: rootID, title: NodeTitle(text: "A"), created: timestamp,
        modified: timestamp)
    let childB = Node(
        id: nodeB, parent: rootID, title: NodeTitle(text: "B"), created: timestamp,
        modified: timestamp)
    return MapModel(
        roots: [rootID], nodes: [rootID: root, nodeA: childA, nodeB: childB])
}
