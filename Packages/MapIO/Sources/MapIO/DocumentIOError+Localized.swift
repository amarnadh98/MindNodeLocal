import Foundation

/// Presents the importer/exporter failures in the language of the app's
/// sheets (SPEC §5.17: "errors shown as a sheet with the importer's
/// message" — including MindNode's documented OPML fallback hint).
extension DocumentIOError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformed(let format, let reason):
            "The \(format) document could not be read: \(reason)."
        case .emptyDocument(let format):
            "The \(format) document contains no nodes to import."
        case .unsupportedVersion(let format, let found, let hint):
            "The \(format) document uses version \(found), which Arbor does not "
                + "support. \(hint)"
        case .notImplemented(let what):
            what
        }
    }
}
