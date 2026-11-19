import Foundation
import MapCore

/// The pasteboard text formats a paste can be parsed from (F-EDT-9).
public enum PasteFormat: String, Sendable, CaseIterable {
    case opml
    case markdown
    case plainText
}

/// A subtree parsed off the pasteboard, ready to become fresh nodes. The
/// snapshot is a template: `PasteboardParser.insertCommand(_:parent:index:)`
/// replaces ids and timestamps, drops inherited study state, and applies the
/// style rules of the paste before building the `insertSubtrees` command.
public struct PastedSubtree: Sendable {
    public var snapshot: Node
    public var children: [PastedSubtree]
    /// The document the snapshot came from (internal payloads only). A paste
    /// into a different document drops asset references that would dangle.
    public var sourceDocID: String?

    public init(snapshot: Node, children: [PastedSubtree] = [], sourceDocID: String? = nil) {
        self.snapshot = snapshot
        self.children = children
        self.sourceDocID = sourceDocID
    }
}
