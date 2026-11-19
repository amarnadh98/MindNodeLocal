import Foundation
import MapCore
import MapIO

/// Quick Entry's outline → command assembly (F-QEN-2). Pure, so the
/// editor's behavior is headless-testable: the text goes through
/// MapIO's paste parser (the same auto-detecting Markdown/OPML/indented
/// plain-text path ⌘V uses), and every destination turns the parsed
/// outline into exactly ONE `MapCommand` — one undo group, whatever the
/// shape of the outline.
enum QuickEntryOutline {
    /// Parses the editor's text into pasted subtrees; nil when there is
    /// nothing to capture (empty or all-whitespace input).
    static func subtrees(from text: String) -> [PastedSubtree]? {
        PasteboardParser.parseText(text)
    }

    /// **Create Map** (F-QEN-2): a NEW document whose first line is the
    /// root and everything else descends from it — remaining top-level
    /// lines become the root's direct children, deeper indents nest
    /// accordingly. One grouped command, so the new document opens with
    /// exactly one undo step.
    ///
    /// - Parameter scratch: an empty model the node ids are minted
    ///   against (fresh ids and timestamps come from the paste
    ///   machinery, never from the text).
    static func createMapCommand(subtrees: [PastedSubtree], in scratch: MapModel) throws -> MapCommand {
        guard let first = subtrees.first else {
            throw ArborError.commandFailure("nothing to capture")
        }
        let rootInsert = try PasteboardParser.insertCommand([first], parent: nil, index: 0, in: scratch)
        guard case .insertSubtrees(_, let rootAnchors) = rootInsert, let rootAnchor = rootAnchors.first else {
            throw ArborError.commandFailure("quick entry could not build the root")
        }
        var commands: [MapCommand] = [rootInsert]
        let rest = Array(subtrees.dropFirst())
        if !rest.isEmpty {
            // The rest land under the fresh root, preserving their own
            // internal hierarchy.
            commands.append(
                try PasteboardParser.insertCommand(
                    rest, parent: rootAnchor.id, index: 0, in: scratch))
        }
        return commands.count == 1 ? commands[0] : .group(name: "Quick Entry", commands: commands)
    }

    /// **Add to…** / **Append to Inbox map** (F-QEN-2): the whole
    /// outline appended as the last children of `parent` in the target
    /// document — one grouped command, one undo step in the target's
    /// store.
    static func appendCommand(
        subtrees: [PastedSubtree], parent: String, in target: MapModel
    ) throws -> MapCommand {
        let index = target.nodes[parent]?.children.count ?? 0
        return try PasteboardParser.insertCommand(subtrees, parent: parent, index: index, in: target)
    }
}
