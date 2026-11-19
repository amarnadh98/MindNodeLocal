import Foundation
import MapCore

/// OPML 2.0 paste exchange (F-EDT-9, §5.17): titles in the `text` attribute,
/// notes in `_note`, XML-escaped. Only the `<body>` outline tree is
/// exchanged on the pasteboard; document-level OPML import/export (with
/// tasks/tags in `arbor:` namespaced attributes) is the M5 F-IO slice.
enum OPMLDocument {
    /// Renders the subtrees rooted at `topIDs` as an OPML 2.0 document.
    static func render(_ model: MapModel, topIDs: [String]) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>\(escape(model.title ?? "Arbor"))</title>",
            "  </head>",
            "  <body>",
        ]
        for id in topIDs {
            renderOutline(id, in: model, depth: 2, into: &lines)
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    private static func renderOutline(_ id: String, in model: MapModel, depth: Int, into lines: inout [String]) {
        guard let node = model.nodes[id] else { return }
        let indent = String(repeating: "  ", count: depth)
        var attributes = "text=\"\(escape(MarkdownInline.flatTitle(node.title)))\""
        if let note = node.note, !note.isEmpty {
            attributes += " _note=\"\(escape(note))\""
        }
        if node.children.isEmpty {
            lines.append("\(indent)<outline \(attributes)/>")
            return
        }
        lines.append("\(indent)<outline \(attributes)>")
        for child in node.children {
            renderOutline(child, in: model, depth: depth + 1, into: &lines)
        }
        lines.append("\(indent)</outline>")
    }

    /// Attribute-value escaping for `& < > " '`; literal newlines become the
    /// `&#10;` character reference (XML normalizes a raw newline to a space).
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// Parses the `<body>` outline tree. `nil` when the input is not
    /// parseable XML or has no outlines (nothing to paste).
    static func parse(_ text: String) -> [PastedSubtree]? {
        guard let data = text.data(using: .utf8) else { return nil }
        let xmlParser = XMLParser(data: data)
        let bodyParser = OPMLBodyParser()
        xmlParser.delegate = bodyParser
        guard xmlParser.parse(), xmlParser.parserError == nil else { return nil }
        return OutlineBoxConverter.subtrees(from: bodyParser.roots)
    }

    /// The name of the first XML element, or nil when the data is not
    /// well-formed enough to produce one. Powers `PasteFormat` detection.
    static func rootElementName(of text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        let xmlParser = XMLParser(data: data)
        let detector = XMLRootElementDetector()
        xmlParser.delegate = detector
        _ = xmlParser.parse()
        return detector.rootName
    }
}

/// Collects the outline tree from an OPML `<body>`: `<outline text="…">`
/// elements nest by document structure; `_note` carries the note.
private final class OPMLBodyParser: NSObject, XMLParserDelegate {
    var roots: [MutableOutline] = []
    private var stack: [MutableOutline] = []
    private var inBody = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if name == "body" {
            inBody = true
            return
        }
        guard inBody, name == "outline" else { return }
        let box = MutableOutline(titleText: attributeDict["text"] ?? "")
        if let note = attributeDict["_note"], !note.isEmpty {
            box.note = note
        }
        if let parent = stack.last {
            parent.children.append(box)
        } else {
            roots.append(box)
        }
        stack.append(box)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if name == "outline", !stack.isEmpty {
            stack.removeLast()
        }
        if name == "body" {
            inBody = false
        }
    }
}

/// Records the root element name, then aborts the parse — element
/// detection only ever needs the opening tag.
private final class XMLRootElementDetector: NSObject, XMLParserDelegate {
    private(set) var rootName: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootName == nil {
            rootName = elementName
        }
        parser.abortParsing()
    }
}
