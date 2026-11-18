import Foundation

/// Formats Arbor can import (SPEC §5.17).
public enum ImportFormat: String, Sendable, CaseIterable, Codable {
    case arbor
    case opml
    case markdown
    case plainText
    case freemind
    case xmind
    case mindnode
    case textBundle
    case rtf
    case csv
    case jsonCanvas
}

/// Formats Arbor can export (SPEC §5.17).
public enum ExportFormat: String, Sendable, CaseIterable, Codable {
    case arbor
    case opml
    case markdown
    case plainText
    case pdf
    case png
    case svg
    case freemind
    case xmind
    case textBundle
    case rtf
    case csv
    case pptx
    case anki
    case jsonCanvas
    case mermaid
}
