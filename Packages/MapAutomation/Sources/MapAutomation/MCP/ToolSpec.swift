import Foundation
import MapCore

/// One tool the MCP server exposes (F-INT-4). The input schema is a JSON
/// Schema value, so `tools/list` is data the client can render.
public struct ToolSpec: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let isMutating: Bool
    public let schema: JSONValue

    public init(name: String, summary: String, isMutating: Bool, schema: JSONValue) {
        self.name = name
        self.summary = summary
        self.isMutating = isMutating
        self.schema = schema
    }

    /// The `tools/list` entry: name, description, inputSchema.
    public var listEntry: JSONValue {
        .object([
            ("name", .string(name)),
            ("description", .string(summary)),
            ("inputSchema", schema),
        ])
    }
}

/// The eight MCP tools (SPEC §5.16 F-INT-4). Schemas are plain JSON
/// Schema objects; argument validation beyond types happens in the
/// engine, where the error messages are better.
public enum ArborTools {
    public static let all: [ToolSpec] = [
        ToolSpec(
            name: "list_maps",
            summary: "Lists the user's Arbor maps (docID, title, path, last modified).",
            isMutating: false,
            schema: .object([
                ("type", .string("object")),
                (
                    "properties",
                    .object([
                        (
                            "query",
                            .object([("type", .string("string")), ("description", .string("optional title filter"))])
                        )
                    ])
                ),
            ])),
        ToolSpec(
            name: "read_map",
            summary: "Reads one map as a nested outline JSON tree or as Markdown.",
            isMutating: false,
            schema: .object([
                ("type", .string("object")),
                (
                    "properties",
                    .object([
                        (
                            "doc",
                            .object([
                                ("type", .string("string")), ("description", .string("docID, path or exact title")),
                            ])
                        ),
                        (
                            "format",
                            .object([
                                ("type", .string("string")),
                                ("enum", .array([.string("outline"), .string("markdown")])),
                                ("default", .string("outline")),
                            ])
                        ),
                    ])
                ),
                ("required", .array([.string("doc")])),
            ])),
        ToolSpec(
            name: "search_nodes",
            summary: "Finds nodes by title text, tag or task state, in one map or all of them.",
            isMutating: false,
            schema: .object([
                ("type", .string("object")),
                (
                    "properties",
                    .object([
                        ("query", .object([("type", .string("string")), ("description", .string("title substring"))])),
                        ("tag", .object([("type", .string("string"))])),
                        (
                            "task",
                            .object([
                                ("type", .string("string")),
                                ("enum", .array([.string("open"), .string("done")])),
                            ])
                        ),
                        (
                            "doc",
                            .object([
                                ("type", .string("string")), ("description", .string("optional: restrict to one map")),
                            ])
                        ),
                    ])
                ),
            ])),
        ToolSpec(
            name: "add_nodes",
            summary:
                "Appends outline text (Markdown, OPML or indented plain text) under a parent node — one atomic edit.",
            isMutating: true,
            schema: .object([
                ("type", .string("object")),
                (
                    "properties",
                    .object([
                        (
                            "doc",
                            .object([
                                ("type", .string("string")), ("description", .string("docID, path or exact title")),
                            ])
                        ),
                        (
                            "parent",
                            .object([
                                ("type", .string("string")),
                                ("description", .string("parent node id or title; omit for a new root")),
                            ])
                        ),
                        (
                            "text",
                            .object([("type", .string("string")), ("description", .string("the outline to insert"))])
                        ),
                        ("index", .object([("type", .string("integer"))])),
                    ])
                ),
                ("required", .array([.string("doc"), .string("text")])),
            ])),
        ToolSpec(
            name: "update_node",
            summary: "Updates a node's title, note or task state — one atomic edit.",
            isMutating: true,
            schema: .object([
                ("type", .string("object")),
                (
                    "properties",
                    .object([
                        ("doc", .object([("type", .string("string"))])),
                        ("node", .object([("type", .string("string")), ("description", .string("node id or title"))])),
                        ("title", .object([("type", .string("string"))])),
                        (
                            "note",
                            .object([
                                ("type", .string("string")),
                                ("description", .string("Markdown note; empty string clears")),
                            ])
                        ),
                        ("taskDone", .object([("type", .string("boolean"))])),
                    ])
                ),
                ("required", .array([.string("doc"), .string("node")])),
            ])),
        ToolSpec(
            name: "move_node",
            summary: "Moves a node (with its subtree) under a new parent, or out as a root.",
            isMutating: true,
            schema: .object([
                ("type", .string("object")),
                (
                    "properties",
                    .object([
                        ("doc", .object([("type", .string("string"))])),
                        ("node", .object([("type", .string("string"))])),
                        (
                            "parent",
                            .object([
                                ("type", .string("string")),
                                (
                                    "description",
                                    .string("new parent node id or title; empty or omitted makes it a root")
                                ),
                            ])
                        ),
                        ("index", .object([("type", .string("integer"))])),
                    ])
                ),
                ("required", .array([.string("doc"), .string("node")])),
            ])),
        ToolSpec(
            name: "create_map",
            summary: "Creates a new Arbor map from a title and/or outline text, saved as a .arbor package.",
            isMutating: true,
            schema: .object([
                ("type", .string("object")),
                (
                    "properties",
                    .object([
                        ("title", .object([("type", .string("string"))])),
                        ("outline", .object([("type", .string("string"))])),
                        (
                            "folder",
                            .object([
                                ("type", .string("string")),
                                ("description", .string("absolute directory; default is Arbor's documents folder")),
                            ])
                        ),
                    ])
                ),
            ])),
        ToolSpec(
            name: "get_due_cards",
            summary: "Counts today's due study cards (learning / review / new), for one map or all of them.",
            isMutating: false,
            schema: .object([
                ("type", .string("object")),
                (
                    "properties",
                    .object([
                        (
                            "doc",
                            .object([("type", .string("string")), ("description", .string("optional: one map only"))])
                        )
                    ])
                ),
            ])),
    ]

    public static func named(_ name: String) -> ToolSpec? {
        all.first { $0.name == name }
    }
}

/// One `tools/call`: the tool name plus its decoded arguments.
public struct ToolCall: Sendable, Equatable {
    public let name: String
    public let arguments: JSONValue

    public init(name: String, arguments: JSONValue) {
        self.name = name
        self.arguments = arguments
    }
}

/// Why a tool call failed before it could run.
public enum ToolError: Error, Equatable, Sendable {
    case badInput(String)
    case notFound(String)
    case disabled(String)
}
