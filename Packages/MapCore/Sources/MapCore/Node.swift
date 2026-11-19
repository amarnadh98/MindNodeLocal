import Foundation

/// A styled range inside a node title (SPEC §8.3 allow-list). `range` is
/// `[start, length]` in **UTF-16 units** — the indices `CFString` and
/// `NSAttributedString` use — so surrogate-pair glyphs (emoji) count as
/// one unit per the platform's text APIs.
public struct Run: Codable, Sendable, Hashable {
    public var range: [Int]
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    public var code: Bool?
    public var color: String?
    public var highlight: String?
    public var link: String?
    public var font: String?
    public var size: Double?

    public init(
        range: [Int],
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        strike: Bool? = nil,
        code: Bool? = nil,
        color: String? = nil,
        highlight: String? = nil,
        link: String? = nil,
        font: String? = nil,
        size: Double? = nil
    ) {
        self.range = range
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.code = code
        self.color = color
        self.highlight = highlight
        self.link = link
        self.font = font
        self.size = size
    }
}

public struct NodeTitle: Codable, Sendable, Hashable {
    public var text: String
    public var runs: [Run]

    public init(text: String, runs: [Run] = []) {
        self.text = text
        self.runs = runs
    }
}

public enum WidthMode: String, Codable, Sendable {
    case auto
    case fixed
}

public struct NodeWidth: Codable, Sendable, Hashable {
    public var mode: WidthMode
    public var value: Double

    public init(mode: WidthMode = .auto, value: Double = 280) {
        self.mode = mode
        self.value = value
    }
}

public enum NodeShape: String, Codable, Sendable, CaseIterable {
    case roundedRect
    case pill
    case rectangle
    case circle
    case square
    case hexagon
    case octagon
    case cloud
    case diamond
    case underline
    case none
}

public enum ShadowStyle: String, Codable, Sendable, CaseIterable {
    case none
    case soft
    case raised
}

public enum ImagePlacement: String, Codable, Sendable {
    case above
    case below
    case left
    case right
}

public struct NodeImage: Codable, Sendable, Hashable {
    public var asset: String
    public var size: [Double]
    public var placement: ImagePlacement

    public init(asset: String, size: [Double], placement: ImagePlacement = .above) {
        self.asset = asset
        self.size = size
        self.placement = placement
    }
}

public struct Attachment: Codable, Sendable, Hashable {
    public var asset: String
    public var name: String

    public init(asset: String, name: String) {
        self.asset = asset
        self.name = name
    }
}

public struct SourceRef: Codable, Sendable, Hashable {
    public var url: String
    public var page: Int?
    public var time: Double?
    public var excerpt: String?

    public init(url: String, page: Int? = nil, time: Double? = nil, excerpt: String? = nil) {
        self.url = url
        self.page = page
        self.time = time
        self.excerpt = excerpt
    }
}

public struct NodeTask: Codable, Sendable, Hashable {
    public var done: Bool
    public var due: String?
    public var priority: Int?
    public var `repeat`: String?
    public var reminderID: String?

    public init(
        done: Bool = false,
        due: String? = nil,
        priority: Int? = nil,
        repeat: String? = nil,
        reminderID: String? = nil
    ) {
        self.done = done
        self.due = due
        self.priority = priority
        self.`repeat` = `repeat`
        self.reminderID = reminderID
    }
}

public enum FSRSStateKind: String, Codable, Sendable {
    case new
    case learning
    case review
    case relearning
}

public struct FSRSState: Codable, Sendable, Hashable {
    public var due: Date
    public var stability: Double
    public var difficulty: Double
    public var elapsedDays: Double
    public var scheduledDays: Double
    public var reps: Int
    public var lapses: Int
    public var state: FSRSStateKind
    public var lastReview: Date?
    /// Index into the scheduler's learning/relearning step list (SPEC §10).
    /// Added in `formatVersion` 2 (M7); optional, so v1 files decode unchanged (nil = step 0).
    public var learningSteps: Int?

    public init(
        due: Date,
        stability: Double = 0,
        difficulty: Double = 0,
        elapsedDays: Double = 0,
        scheduledDays: Double = 0,
        reps: Int = 0,
        lapses: Int = 0,
        state: FSRSStateKind = .new,
        lastReview: Date? = nil,
        learningSteps: Int? = nil
    ) {
        self.due = due
        self.stability = stability
        self.difficulty = difficulty
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
        self.reps = reps
        self.lapses = lapses
        self.state = state
        self.lastReview = lastReview
        self.learningSteps = learningSteps
    }
}

public enum CardPolicy: String, Codable, Sendable {
    case auto
    case on
    case off
}

public struct NodeStudy: Codable, Sendable, Hashable {
    public var card: CardPolicy
    /// The FSRS state of the node's **basic** card (`nodeID`, SPEC §10):
    /// the field `map.json` has always had under `study.fsrs`.
    public var fsrs: FSRSState?
    /// FSRS state of the node's non-basic cards, keyed by card key
    /// (SPEC §10: "card state is stored on the node, keyed by card
    /// subtype"): `"r"` reversed, `"cN"` each cloze index, `"s:<summaryID>"`
    /// a summary card owned by this node. Optional, so files written
    /// before the field decode with an empty map (ADR-0015).
    public var fsrsByCard: [String: FSRSState]?
    /// True on a branch node marked as a study deck (F-STD-1, ADR-0015):
    /// nodes inside a deck follow the auto card rule. `nil` reads as
    /// not-a-deck.
    public var deck: Bool?

    public init(
        card: CardPolicy = .auto,
        fsrs: FSRSState? = nil,
        fsrsByCard: [String: FSRSState]? = nil,
        deck: Bool? = nil
    ) {
        self.card = card
        self.fsrs = fsrs
        self.fsrsByCard = fsrsByCard
        self.deck = deck
    }
}

public enum NumberingStyle: String, Codable, Sendable {
    case none
    case decimal
    case alpha
    case roman
}

public enum SidePin: String, Codable, Sendable {
    case left
    case right
}

public enum AuthorKind: String, Codable, Sendable {
    case user
    case ai
    case mcp
    case sync
}

public struct ModelOffset: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

public struct Node: Codable, Sendable, Hashable {
    public var id: String
    public var parent: String?
    public var children: [String]
    public var title: NodeTitle
    public var note: String?
    public var structure: String?
    public var side: SidePin?
    public var offset: ModelOffset?
    public var folded: Bool
    public var width: NodeWidth?
    /// The persistent branch palette index (ADR-0009, formatVersion 2).
    /// Set on level-1 nodes (a root's direct children); descendants
    /// inherit their level-1 ancestor's index at render time (F-STY-3).
    /// `nil` falls back to the node's position among its siblings.
    public var paletteIndex: Int?
    public var style: NodeStylePatch?
    public var markers: [String]?
    public var image: NodeImage?
    public var attachments: [Attachment]?
    public var link: String?
    public var source: SourceRef?
    public var tags: [String]?
    public var task: NodeTask?
    public var fields: [String: String]?
    public var type: String?
    public var study: NodeStudy?
    public var math: Bool?
    public var numbering: NumberingStyle?
    public var created: Date
    public var modified: Date
    public var modifiedBy: AuthorKind

    public init(
        id: String,
        parent: String? = nil,
        children: [String] = [],
        title: NodeTitle = NodeTitle(text: ""),
        note: String? = nil,
        structure: String? = nil,
        side: SidePin? = nil,
        offset: ModelOffset? = nil,
        folded: Bool = false,
        width: NodeWidth? = nil,
        paletteIndex: Int? = nil,
        style: NodeStylePatch? = nil,
        markers: [String]? = nil,
        image: NodeImage? = nil,
        attachments: [Attachment]? = nil,
        link: String? = nil,
        source: SourceRef? = nil,
        tags: [String]? = nil,
        task: NodeTask? = nil,
        fields: [String: String]? = nil,
        type: String? = nil,
        study: NodeStudy? = nil,
        math: Bool? = nil,
        numbering: NumberingStyle? = nil,
        created: Date = Date(),
        modified: Date = Date(),
        modifiedBy: AuthorKind = .user
    ) {
        self.id = id
        self.parent = parent
        self.children = children
        self.title = title
        self.note = note
        self.structure = structure
        self.side = side
        self.offset = offset
        self.folded = folded
        self.width = width
        self.paletteIndex = paletteIndex
        self.style = style
        self.markers = markers
        self.image = image
        self.attachments = attachments
        self.link = link
        self.source = source
        self.tags = tags
        self.task = task
        self.fields = fields
        self.type = type
        self.study = study
        self.math = math
        self.numbering = numbering
        self.created = created
        self.modified = modified
        self.modifiedBy = modifiedBy
    }
}
