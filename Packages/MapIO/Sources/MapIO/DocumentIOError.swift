import Foundation

/// Failures raised by the document-level importers/exporters (SPEC §5.17).
/// Importers never crash on malformed input: they throw, and the caller
/// shows the message.
public enum DocumentIOError: Error, Sendable, Hashable {
    /// The bytes are not parseable as the requested format.
    case malformed(format: String, reason: String)
    /// The bytes parsed but contain no nodes (nothing to import).
    case emptyDocument(format: String)
    /// The document's format version is one Arbor does not read.
    case unsupportedVersion(format: String, found: String, hint: String)
    /// The registry knows the format, but no importer/exporter is wired
    /// up yet (later M5 slices).
    case notImplemented(String)
}
