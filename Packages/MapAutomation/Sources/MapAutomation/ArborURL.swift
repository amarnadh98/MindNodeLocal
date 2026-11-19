import Foundation

/// The `x-arbor://` URL scheme (SPEC §5.16 F-INT-5, §11.9). Pure parsing:
/// the host selects the route and the query carries the arguments,
/// percent-decoded by `URLComponents`. Malformed input throws — the app
/// layer shows the error and never touches the documents.
public enum ArborURL {
    public static let scheme = "x-arbor"

    public enum Route: Equatable, Sendable {
        /// `open?doc=&node=` — bring the map forward, optionally selecting
        /// `node`.
        case open(doc: String, node: String?)
        /// `new?title=&outline=` — a fresh untitled map, optionally named
        /// and seeded from outline text.
        case newDocument(title: String?, outline: String?)
        /// `add?doc=&parent=&text=` — append `text` (a line or an outline)
        /// under `parent` (or a new root when nil).
        case add(doc: String, parent: String?, text: String)
        /// `study?doc=` — open the map and start a study session (the study
        /// UI's seam).
        case study(doc: String)
    }

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case wrongScheme(String)
        case missingRoute
        case unknownRoute(String)
        case missingParameter(String)

        public var description: String {
            switch self {
            case .wrongScheme(let found): "not an \(scheme) URL (found \"\(found)\")"
            case .missingRoute: "the URL names no route"
            case .unknownRoute(let route): "unknown route \"\(route)\""
            case .missingParameter(let name): "the required \"\(name)\" parameter is missing"
            }
        }
    }

    /// Parses a URL string. Throws `ParseError` on anything that is not a
    /// well-formed scheme route.
    public static func parse(_ raw: String) throws -> Route {
        guard let url = URL(string: raw) else {
            throw ParseError.wrongScheme(raw)
        }
        return try parse(url)
    }

    /// Parses a URL. The scheme comparison is case-insensitive per RFC
    /// 3986; route names are lowercase.
    public static func parse(_ url: URL) throws -> Route {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw ParseError.wrongScheme(url.absoluteString)
        }
        let found = components.scheme ?? ""
        guard found.lowercased() == scheme else {
            throw ParseError.wrongScheme(found.isEmpty ? url.absoluteString : found)
        }
        guard let route = components.host, !route.isEmpty else {
            throw ParseError.missingRoute
        }
        let query = queryItems(components)

        func required(_ name: String) throws -> String {
            guard let value = query[name], !value.isEmpty else {
                throw ParseError.missingParameter(name)
            }
            return value
        }
        func optional(_ name: String) -> String? {
            query[name].flatMap { $0.isEmpty ? nil : $0 }
        }

        switch route {
        case "open":
            return .open(doc: try required("doc"), node: optional("node"))
        case "new":
            return .newDocument(title: optional("title"), outline: optional("outline"))
        case "add":
            return .add(doc: try required("doc"), parent: optional("parent"), text: try required("text"))
        case "study":
            return .study(doc: try required("doc"))
        default:
            throw ParseError.unknownRoute(route)
        }
    }

    private static func queryItems(_ components: URLComponents) -> [String: String] {
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            // First occurrence wins, like URL query convention.
            if values[item.name] == nil {
                values[item.name] = value
            }
        }
        return values
    }
}
