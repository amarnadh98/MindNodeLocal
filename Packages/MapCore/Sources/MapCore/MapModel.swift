import Foundation

public struct ThemePatch: Codable, Sendable, Hashable {
    public var canvasColor: String?
    public var paletteColors: [String]?
    public var baseFont: String?

    public init(canvasColor: String? = nil, paletteColors: [String]? = nil, baseFont: String? = nil) {
        self.canvasColor = canvasColor
        self.paletteColors = paletteColors
        self.baseFont = baseFont
    }
}

public struct ThemeSelection: Codable, Sendable, Hashable {
    public var id: String
    public var overrides: ThemePatch?

    public init(id: String = "paper", overrides: ThemePatch? = nil) {
        self.id = id
        self.overrides = overrides
    }
}

public enum AppearanceMode: String, Codable, Sendable {
    case auto
    case light
    case dark
}

public enum Arrowheads: String, Codable, Sendable {
    case none
    case start
    case end
    case both
}

public enum ConnectionLineStyle: String, Codable, Sendable {
    case curve
    case straight
}

public struct ConnectionStyle: Codable, Sendable, Hashable {
    public var color: String?
    public var width: Double?
    public var dash: Bool?
    public var arrowheads: Arrowheads?
    public var lineStyle: ConnectionLineStyle?

    public init(
        color: String? = nil,
        width: Double? = nil,
        dash: Bool? = nil,
        arrowheads: Arrowheads? = nil,
        lineStyle: ConnectionLineStyle? = nil
    ) {
        self.color = color
        self.width = width
        self.dash = dash
        self.arrowheads = arrowheads
        self.lineStyle = lineStyle
    }
}

public struct Connection: Codable, Sendable, Hashable {
    public var id: String
    public var from: String
    public var to: String
    public var label: String?
    public var control: ModelOffset?
    public var style: ConnectionStyle?

    public init(
        id: String,
        from: String,
        to: String,
        label: String? = nil,
        control: ModelOffset? = nil,
        style: ConnectionStyle? = nil
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.control = control
        self.style = style
    }
}

public struct Boundary: Codable, Sendable, Hashable {
    public var id: String
    public var nodes: [String]
    public var title: String?
    public var style: ConnectionStyle?

    public init(id: String, nodes: [String], title: String? = nil, style: ConnectionStyle? = nil) {
        self.id = id
        self.nodes = nodes
        self.title = title
        self.style = style
    }
}

public struct Summary: Codable, Sendable, Hashable {
    public var id: String
    public var parent: String
    public var range: [String]
    public var node: String

    public init(id: String, parent: String, range: [String], node: String) {
        self.id = id
        self.parent = parent
        self.range = range
        self.node = node
    }
}

public struct Tag: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var color: String

    public init(id: String, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }
}

public struct FieldDef: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct SlideCamera: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var scale: Double

    public init(x: Double = 0, y: Double = 0, scale: Double = 1) {
        self.x = x
        self.y = y
        self.scale = scale
    }
}

public struct Slide: Codable, Sendable, Hashable {
    public var id: String
    public var title: String?
    public var camera: SlideCamera?
    public var folded: [String]?
    public var focus: [String]?
    public var dimOthers: Bool?
    public var build: [String]?
    public var notes: String?

    public init(
        id: String,
        title: String? = nil,
        camera: SlideCamera? = nil,
        folded: [String]? = nil,
        focus: [String]? = nil,
        dimOthers: Bool? = nil,
        build: [String]? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.camera = camera
        self.folded = folded
        self.focus = focus
        self.dimOthers = dimOthers
        self.build = build
        self.notes = notes
    }
}

public struct Presentation: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var slides: [Slide]

    public init(id: String, name: String, slides: [Slide] = []) {
        self.id = id
        self.name = name
        self.slides = slides
    }
}

public struct StudySettings: Codable, Sendable, Hashable {
    public var newPerDay: Int
    public var retention: Double

    public init(newPerDay: Int = 20, retention: Double = 0.9) {
        self.newPerDay = newPerDay
        self.retention = retention
    }
}

public enum ViewMode: String, Codable, Sendable {
    case map
    case outline
    case sideBySide
}

public struct ViewState: Codable, Sendable, Hashable {
    public var camera: SlideCamera
    public var selection: [String]
    public var mode: ViewMode

    public init(camera: SlideCamera = SlideCamera(), selection: [String] = [], mode: ViewMode = .map) {
        self.camera = camera
        self.selection = selection
        self.mode = mode
    }
}

public struct SavedFilter: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var query: String

    public init(id: String, name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

public struct MapModel: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var docID: String
    public var title: String?
    public var theme: ThemeSelection?
    public var appearance: AppearanceMode?
    public var roots: [String]
    public var nodes: [String: Node]
    public var connections: [Connection]?
    public var boundaries: [Boundary]?
    public var summaries: [Summary]?
    public var tags: [Tag]?
    public var fieldDefs: [FieldDef]?
    public var presentations: [Presentation]?
    public var studySettings: StudySettings?
    public var view: ViewState?
    public var filters: [SavedFilter]?

    public init(
        formatVersion: Int = ArborFormat.formatVersion,
        docID: String = UUID().uuidString,
        title: String? = nil,
        theme: ThemeSelection? = nil,
        appearance: AppearanceMode = .auto,
        roots: [String] = [],
        nodes: [String: Node] = [:],
        connections: [Connection]? = nil,
        boundaries: [Boundary]? = nil,
        summaries: [Summary]? = nil,
        tags: [Tag]? = nil,
        fieldDefs: [FieldDef]? = nil,
        presentations: [Presentation]? = nil,
        studySettings: StudySettings? = nil,
        view: ViewState? = nil,
        filters: [SavedFilter]? = nil
    ) {
        self.formatVersion = formatVersion
        self.docID = docID
        self.title = title
        self.theme = theme
        self.appearance = appearance
        self.roots = roots
        self.nodes = nodes
        self.connections = connections
        self.boundaries = boundaries
        self.summaries = summaries
        self.tags = tags
        self.fieldDefs = fieldDefs
        self.presentations = presentations
        self.studySettings = studySettings
        self.view = view
        self.filters = filters
    }

    public static func emptyDocument(docID: String = UUID().uuidString) -> MapModel {
        MapModel(docID: docID)
    }
}
