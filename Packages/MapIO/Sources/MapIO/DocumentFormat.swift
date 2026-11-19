import Foundation

/// One document-level exchange format from the F-IO table (SPEC §5.17):
/// everything the open panel and the later export sheet need to know —
/// a stable id, display name, UTType identifier string, file extensions
/// and which directions Arbor implements. The UTType identifiers of the
/// third-party formats mirror what those apps declare; the App target
/// re-declares them in its Info.plist when the panels land.
public struct DocumentFormat: Sendable, Hashable, Codable {
    public enum Capability: String, Sendable, Codable, Hashable {
        case both
        case importOnly
        case exportOnly
    }

    public let id: String
    public let displayName: String
    public let utTypeIdentifier: String
    public let extensions: [String]
    public let capability: Capability

    public init(
        id: String,
        displayName: String,
        utTypeIdentifier: String,
        extensions: [String],
        capability: Capability
    ) {
        self.id = id
        self.displayName = displayName
        self.utTypeIdentifier = utTypeIdentifier
        self.extensions = extensions
        self.capability = capability
    }

    public var canImport: Bool { capability != .exportOnly }
    public var canExport: Bool { capability != .importOnly }
}

/// The F-IO registry (SPEC §5.17) for the formats whose document-level
/// importers/exporters exist after this milestone slice, plus the native
/// package (opened/saved by the document layer, not `DocumentIO`).
/// Later slices (PDF, PNG, SVG, TextBundle…) append their entries here.
public enum DocumentFormats {
    public static let arbor = DocumentFormat(
        id: "arbor",
        displayName: "Arbor Map",
        utTypeIdentifier: "com.arbor.map",
        extensions: ["arbor"],
        capability: .both)

    public static let opml = DocumentFormat(
        id: "opml",
        displayName: "OPML 2.0",
        utTypeIdentifier: "org.opml.opml",
        extensions: ["opml"],
        capability: .both)

    public static let markdown = DocumentFormat(
        id: "markdown",
        displayName: "Markdown",
        utTypeIdentifier: "net.daringfireball.markdown",
        extensions: ["md", "markdown"],
        capability: .both)

    public static let plainText = DocumentFormat(
        id: "plainText",
        displayName: "Plain Text Outline",
        utTypeIdentifier: "public.plain-text",
        extensions: ["txt"],
        capability: .both)

    public static let freemind = DocumentFormat(
        id: "freemind",
        displayName: "FreeMind / Freeplane",
        utTypeIdentifier: "com.freemind.freemind",
        extensions: ["mm"],
        capability: .both)

    public static let xmind = DocumentFormat(
        id: "xmind",
        displayName: "XMind",
        utTypeIdentifier: "org.xmind.xmind",
        extensions: ["xmind"],
        capability: .importOnly)

    public static let mindnode = DocumentFormat(
        id: "mindnode",
        displayName: "MindNode",
        utTypeIdentifier: "com.mindnode.mindnode",
        extensions: ["mindnode"],
        capability: .importOnly)

    /// Registry order: native first, then P0 exchange formats, then P1.
    public static let all: [DocumentFormat] = [
        arbor, opml, markdown, plainText, freemind, xmind, mindnode,
    ]

    public static func format(id: String) -> DocumentFormat? {
        all.first { $0.id == id }
    }

    public static func format(forExtension fileExtension: String) -> DocumentFormat? {
        let lowered = fileExtension.lowercased()
        return all.first { $0.extensions.contains(lowered) }
    }

    public static func format(forUTType utTypeIdentifier: String) -> DocumentFormat? {
        all.first { $0.utTypeIdentifier == utTypeIdentifier }
    }
}
