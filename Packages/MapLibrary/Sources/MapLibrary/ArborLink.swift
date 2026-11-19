import Foundation

/// The canonical Arbor deep-link URL (SPEC §11.9's `x-arbor` scheme),
/// used by node links and the Concept Index's "Link these"
/// (F-LIB-4). Format: `x-arbor://<docID>/<nodeID>` — both UUIDs,
/// parsed case-insensitively (UUID hex digits are case-safe). The M8
/// URL-scheme handler will resolve these to the document + node.
public enum ArborLink {
    public static let scheme = "x-arbor"

    public static func url(docID: String, nodeID: String) -> String {
        "\(scheme)://\(docID.lowercased())/\(nodeID.lowercased())"
    }

    /// Parses an `x-arbor` target into (docID, nodeID), both lowercased;
    /// nil for anything else (web links, files, malformed).
    public static func parse(_ target: String) -> (docID: String, nodeID: String)? {
        let prefix = "\(scheme)://"
        guard target.count > prefix.count, target.lowercased().hasPrefix(prefix) else { return nil }
        let remainder = String(target.dropFirst(prefix.count))
        let parts = remainder.split(
            separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]).lowercased(), String(parts[1]).lowercased())
    }
}
