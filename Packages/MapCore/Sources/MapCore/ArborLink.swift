import Foundation

/// A validated node link (F-CNT-4): web (`http`/`https`), a local
/// `file://` URL, or Arbor's own `x-arbor://` deep link
/// (`x-arbor://open?doc=<docID>&node=<nodeID>`, SPEC F-REL-5). Pure —
/// the ⌘K sheet validates with it and `openLink` routes on it.
public enum ArborLink: Sendable, Equatable {
    case web(URL)
    case file(URL)
    case arbor(docID: String?, nodeID: String?)

    /// Parses and validates a raw link string; nil means invalid. A
    /// scheme-less string is rejected (the sheet auto-prefixes
    /// `https://` before calling); an absolute path is accepted as a
    /// file URL.
    public static func parse(_ raw: String) -> ArborLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        if trimmed.lowercased().hasPrefix("x-arbor://") {
            guard let components = URLComponents(string: trimmed) else { return nil }
            let query = components.queryItems ?? []
            let docID = query.first(where: { $0.name == "doc" })?.value
            let nodeID = query.first(where: { $0.name == "node" })?.value
            return .arbor(docID: docID?.nilIfEmpty, nodeID: nodeID?.nilIfEmpty)
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                guard url.host != nil || url.path.contains("/") else { return nil }
                return .web(url)
            case "file":
                return .file(url)
            default:
                // Foreign schemes are out of the §8.2 allow-list.
                return nil
            }
        }

        // An absolute POSIX path is the file form of "attach this".
        if trimmed.hasPrefix("/") {
            return .file(URL(fileURLWithPath: trimmed))
        }
        return nil
    }
}

extension String {
    /// `nil` when the string is empty, else `self`.
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
