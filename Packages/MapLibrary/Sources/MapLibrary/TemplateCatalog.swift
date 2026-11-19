import Foundation
import MapCore

/// The built-in templates (F-LIB-5) — twelve starter maps, all content
/// written for Arbor (nothing copied from any other app's template
/// library). Each is a plain `MapModel` built in code; "Save as
/// Template…" writes user templates as `.arbor` packages under
/// Application Support/Templates, and "New from Template" materializes
/// a copy with fresh ids so the template file is never edited
/// (ADR-0016 records the in-code-builtins choice).
public enum TemplateCatalog {
    public struct Template: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let model: MapModel
    }

    /// The twelve built-ins (SPEC §5.12 F-LIB-5's list).
    public static let builtins: [Template] = [
        brainstorm,
        projectPlan,
        meetingNotes,
        bookSummary,
        lectureNotes,
        conceptStudy,
        swot,
        decisionMatrix,
        weeklyReview,
        okrs,
        fishboneRCA,
        timeline,
    ]

    // MARK: materialization

    /// A copy of `model` ready to become a NEW untitled document:
    /// fresh `docID`, fresh node ids (parents/children/roots remapped),
    /// no view state, no presentations. The source model is untouched.
    public static func materialize(_ model: MapModel, docID: String = UUID().uuidString) -> MapModel {
        var fresh = model
        fresh.docID = docID
        fresh.view = nil
        fresh.presentations = nil
        fresh.nodes = [:]
        var mapping: [String: String] = [:]
        for (nodeID, node) in model.nodes {
            let newID = UUID().uuidString
            mapping[nodeID] = newID
            var copy = node
            copy.id = newID
            copy.children = []
            copy.parent = nil
            fresh.nodes[newID] = copy
        }
        for (nodeID, node) in model.nodes {
            let mapped = mapping[nodeID]!
            fresh.nodes[mapped]?.children = node.children.map { mapping[$0]! }
            fresh.nodes[mapped]?.parent = node.parent.map { mapping[$0]! }
        }
        fresh.roots = model.roots.map { mapping[$0]! }
        return fresh
    }

    /// Loads user-saved templates (`.arbor` packages) from a directory,
    /// newest first; missing directory reads as empty.
    public static func userTemplates(in directory: URL) -> [Template] {
        let packages = PackageScanner.packages(in: directory)
        return packages.compactMap { package in
            guard let contents = try? ArborPackage.read(at: package) else { return nil }
            let name = package.deletingPathExtension().lastPathComponent
            return Template(id: "user:\(package.path)", name: name, model: contents.model)
        }
    }
}

// MARK: - builders

/// One node in a template sketch. Children are unlabeled (the body of
/// the node); `note` and `card` are trailing labels.
private struct SketchNode {
    let title: String
    let note: String?
    let children: [SketchNode]
    let card: Bool

    init(_ title: String, _ children: [SketchNode] = [], note: String? = nil, card: Bool = false) {
        self.title = title
        self.note = note
        self.children = children
        self.card = card
    }
}

/// Builds a one-root `MapModel` from a sketch. Timestamps are fixed so
/// builtins are deterministic (tests can golden them).
private func sketchModel(_ id: String, _ name: String, _ root: SketchNode) -> TemplateCatalog.Template {
    let stamp = Date(timeIntervalSince1970: 0)
    var model = MapModel(docID: UUID().uuidString)
    model.title = name

    func build(_ sketch: SketchNode, parent: String?) -> String {
        let nodeID = UUID().uuidString
        var node = Node(id: nodeID, parent: parent, title: NodeTitle(text: sketch.title))
        node.note = sketch.note
        if sketch.card { node.study = NodeStudy(card: .on) }
        node.created = stamp
        node.modified = stamp
        model.nodes[nodeID] = node
        if let parent { model.nodes[parent]?.children.append(nodeID) }
        for child in sketch.children {
            _ = build(child, parent: nodeID)
        }
        return nodeID
    }

    let rootID = build(root, parent: nil)
    model.roots = [rootID]
    return TemplateCatalog.Template(id: id, name: name, model: model)
}

// MARK: - the twelve templates

extension TemplateCatalog {
    fileprivate static let brainstorm: Template = sketchModel(
        "brainstorm",
        "Brainstorm",
        SketchNode(
            "Central question",
            [
                SketchNode(
                    "The problem",
                    [
                        SketchNode("Who feels it?"),
                        SketchNode("Why now?"),
                        SketchNode("What has been tried?"),
                    ]),
                SketchNode(
                    "Wild ideas",
                    [
                        SketchNode("Obvious first takes"),
                        SketchNode("Strange combinations"),
                        SketchNode("What would remove the problem entirely?"),
                    ],
                    note: "Quantity over quality — nothing is too silly yet."),
                SketchNode(
                    "Constraints",
                    [
                        SketchNode("Budget"),
                        SketchNode("Time"),
                        SketchNode("Skills & people"),
                        SketchNode("Non-negotiables"),
                    ]),
                SketchNode("Promising clusters", note: "Group the wild ideas that keep returning."),
                SketchNode(
                    "Next steps",
                    [
                        SketchNode("Pick three to explore"),
                        SketchNode("Who to talk to"),
                        SketchNode("First experiment"),
                    ]),
            ],
            note: "Write the question you're answering in one sentence."))

    fileprivate static let projectPlan: Template = sketchModel(
        "project-plan",
        "Project Plan",
        SketchNode(
            "Project: name it here",
            [
                SketchNode("Goal", note: "One sentence. Done looks like…"),
                SketchNode(
                    "Milestones",
                    [
                        SketchNode("Kickoff", note: "Scope agreed, owners named."),
                        SketchNode("First deliverable"),
                        SketchNode("Review point"),
                        SketchNode("Ship"),
                    ]),
                SketchNode(
                    "Workstreams",
                    [
                        SketchNode("Research"),
                        SketchNode("Build"),
                        SketchNode("Content & polish"),
                    ]),
                SketchNode(
                    "Risks",
                    [
                        SketchNode(
                            "What could sink this?",
                            note: "Add the mitigation next to each risk."),
                        SketchNode("Dependencies outside the team"),
                    ]),
                SketchNode("Team & roles"),
                SketchNode(
                    "Definition of done", note: "The checklist you'll actually verify against."),
            ]))

    fileprivate static let meetingNotes: Template = sketchModel(
        "meeting-notes",
        "Meeting Notes",
        SketchNode(
            "Meeting: topic",
            [
                SketchNode("When & where"),
                SketchNode("Attendees"),
                SketchNode("Agenda", note: "One branch per item; tick them off as you go."),
                SketchNode(
                    "Decisions",
                    note: "Only things actually agreed — with who decided."),
                SketchNode(
                    "Action items",
                    [
                        SketchNode(
                            "Task — owner — deadline", note: "Duplicate this node per task.")
                    ]),
                SketchNode("Open questions"),
                SketchNode("Next meeting"),
            ]))

    fileprivate static let bookSummary: Template = sketchModel(
        "book-summary",
        "Book Summary",
        SketchNode(
            "Book: title",
            [
                SketchNode("Author & context", note: "Who wrote it, when, and why it exists."),
                SketchNode("Thesis", note: "The one idea the whole book argues for."),
                SketchNode(
                    "Key arguments",
                    [
                        SketchNode("Argument 1", note: "Claim + strongest evidence."),
                        SketchNode("Argument 2"),
                        SketchNode("Argument 3"),
                    ]),
                SketchNode("Evidence worth stealing"),
                SketchNode("Quotations", note: "Page number with each quote."),
                SketchNode("Where I disagree"),
                SketchNode("How to apply it", note: "One change to try this week."),
            ]))

    fileprivate static let lectureNotes: Template = sketchModel(
        "lecture-notes",
        "Lecture Notes",
        SketchNode(
            "Lecture: topic & date",
            [
                SketchNode("Main concepts", note: "One branch per concept."),
                SketchNode("Definitions"),
                SketchNode("Worked examples"),
                SketchNode(
                    "Questions to review",
                    [
                        SketchNode("Question 1"),
                        SketchNode("Question 2"),
                    ],
                    note: "Anything the lecturer said would come up again.",
                    card: true),
                SketchNode("What to read next"),
            ]))

    fileprivate static let conceptStudy: Template = sketchModel(
        "concept-study",
        "Concept Study",
        SketchNode(
            "Concept: name it",
            [
                SketchNode("Definition", note: "Say it in one plain sentence.", card: true),
                SketchNode(
                    "Why it matters", note: "Where would the world break without it?", card: true),
                SketchNode("Examples", note: "Two concrete cases.", card: true),
                SketchNode(
                    "Common confusions",
                    note: "The near-miss concept and how to tell them apart.",
                    card: true),
                SketchNode(
                    "Connections", note: "Which other concepts build on this one?", card: true),
            ],
            note: "A study deck: the root is the prompt, the children are the answer.",
            card: true))

    fileprivate static let swot: Template = sketchModel(
        "swot",
        "SWOT",
        SketchNode(
            "SWOT: subject",
            [
                SketchNode("Strengths", note: "Internal, working in your favour."),
                SketchNode("Weaknesses", note: "Internal, working against you."),
                SketchNode("Opportunities", note: "External, upside you could capture."),
                SketchNode("Threats", note: "External, downside you must survive."),
                SketchNode(
                    "So what?",
                    [
                        SketchNode("Strength × opportunity plays"),
                        SketchNode("Weakness × threat hedges"),
                    ]),
            ]))

    fileprivate static let decisionMatrix: Template = sketchModel(
        "decision-matrix",
        "Decision Matrix",
        SketchNode(
            "Decision: state it as a question",
            [
                SketchNode(
                    "Options",
                    [
                        SketchNode("Option A", note: "One branch per option."),
                        SketchNode("Option B"),
                        SketchNode("Do nothing"),
                    ]),
                SketchNode(
                    "Criteria",
                    [
                        SketchNode("Cost"),
                        SketchNode("Speed"),
                        SketchNode("Reversibility"),
                        SketchNode("Who it helps"),
                    ]),
                SketchNode("Weights", note: "Which criteria matter most, 1–5."),
                SketchNode("Scores", note: "Option × criterion; keep it rough."),
                SketchNode(
                    "Verdict",
                    note: "Write the choice AND the reason, not just the winner."),
            ]))

    fileprivate static let weeklyReview: Template = sketchModel(
        "weekly-review",
        "Weekly Review",
        SketchNode(
            "Week of …",
            [
                SketchNode("Wins", note: "Start here — name three, however small."),
                SketchNode("Lessons", note: "What surprised you?"),
                SketchNode("Metrics", [SketchNode("Tracked numbers, if any")]),
                SketchNode("What slipped", note: "No blame — just the cause."),
                SketchNode(
                    "Next week's priorities",
                    [
                        SketchNode(
                            "Priority 1", note: "One is best; three is the cap.")
                    ]),
                SketchNode("Gratitude"),
            ]))

    fileprivate static let okrs: Template = sketchModel(
        "okrs",
        "OKRs",
        SketchNode(
            "Objective",
            [
                SketchNode("Key result 1", note: "Measurable: baseline → target.", card: true),
                SketchNode("Key result 2", card: true),
                SketchNode("Key result 3", card: true),
                SketchNode(
                    "Initiatives",
                    [
                        SketchNode("The work that moves key result 1"),
                        SketchNode("The work that moves key result 2"),
                    ]),
                SketchNode(
                    "Check-in cadence", note: "When you'll score the KRs — weekly or biweekly."),
            ],
            note: "Qualitative, inspiring, time-boxed to the quarter."))

    fileprivate static let fishboneRCA: Template = sketchModel(
        "fishbone-rca",
        "Fishbone RCA",
        SketchNode(
            "Problem: describe the effect",
            [
                SketchNode("People"),
                SketchNode("Process"),
                SketchNode("Equipment & tools"),
                SketchNode("Environment"),
                SketchNode("Materials & inputs"),
                SketchNode(
                    "Measurement", note: "Bad data causes bad decisions too."),
                SketchNode(
                    "Likely root cause",
                    note: "Circle one cause — verify it, then fix that one."),
            ],
            note: "Root-cause analysis: causes per category, then pick the likeliest root."))

    fileprivate static let timeline: Template = sketchModel(
        "timeline",
        "Timeline",
        SketchNode(
            "Timeline: project or story",
            [
                SketchNode(
                    "Phase 1 — prepare",
                    [
                        SketchNode(
                            "Milestone", note: "What must be true when this phase ends."),
                        SketchNode("Owner"),
                    ]),
                SketchNode(
                    "Phase 2 — build",
                    [
                        SketchNode("Milestone"),
                        SketchNode("Owner"),
                    ]),
                SketchNode(
                    "Phase 3 — launch",
                    [
                        SketchNode("Milestone"),
                        SketchNode("Owner"),
                    ]),
                SketchNode(
                    "Phase 4 — after",
                    [
                        SketchNode("Follow-up"),
                        SketchNode("Retrospective"),
                    ]),
            ]))
}
