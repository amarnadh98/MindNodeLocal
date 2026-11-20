import AppKit
import Foundation
import MapAutomation
import MapCore

/// The Services menu (F-INT-6): "New Arbor Map from Selection" turns the
/// selected text into a new untitled map (the same import path as the
/// `new` URL route); "Add Selection to Arbor Inbox" appends it under an
/// "Inbox" node in the configured inbox document — one undo step (open
/// document) or one atomic write (closed document), creating the Inbox
/// node if the map has none. Declared in Info.plist `NSServices`.
/// The Share extension (F-INT-6's second half) is out of scope for this
/// slice; see the PR notes.
@MainActor
final class ServicesResponder: NSObject {
    static let shared = ServicesResponder()

    // MARK: New Arbor Map from Selection

    @objc func newMapFromSelection(
        _ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "the selection carries no text"
            return
        }
        do {
            let document = try AutomationRouter.shared.createDocument(title: nil, outline: text)
            document.showWindows()
        } catch let failure {
            error.pointee = "Arbor could not build a map from that selection: \(failure)" as NSString
        }
    }

    // MARK: Add Selection to Arbor Inbox

    @objc func addSelectionToInbox(
        _ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "the selection carries no text"
            return
        }
        do {
            try appendToInbox(text)
        } catch InboxError.notConfigured {
            presentError(
                "No Inbox document is configured yet. Choose one in Arbor ▸ Settings ▸ Integrations ▸ Inbox document, then use the service again."
            )
        } catch {
            presentError("Arbor could not add the selection to the inbox: \(error)")
        }
    }

    enum InboxError: Error {
        case notConfigured
        case unreadable(String)
    }

    /// Appends `text` under the inbox document's "Inbox" node — one
    /// grouped command (find-or-create the Inbox node, then insert the
    /// parsed outline under it), so one undo step on an open document and
    /// one atomic write on a closed one.
    func appendToInbox(_ text: String) throws {
        guard let url = AutomationSettings.inboxURL() else {
            throw InboxError.notConfigured
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // An open instance of the inbox document edits through its store.
        if let open = AppMapDirectory.openDocument(matching: url.path) {
            try appendToInbox(text, in: open)
            return
        }
        // Closed: coordinated read → one grouped command → atomic write.
        let contents: PackageContents
        do {
            contents = try HeadlessMapEditor.read(at: url)
        } catch {
            throw InboxError.unreadable(url.lastPathComponent)
        }
        let command = try Self.inboxCommand(text: text, in: contents.model)
        try HeadlessMapEditor.apply([command], at: url, author: .user)
    }

    private func appendToInbox(_ text: String, in document: MapDocument) throws {
        let command = try Self.inboxCommand(text: text, in: document.model)
        try document.store.perform(command)
        document.updateChangeCount(.changeDone)
        document.showWindows()
    }

    /// The find-or-create + insert command, pure over the current model.
    static func inboxCommand(text: String, in model: MapModel) throws -> MapCommand {
        // An existing "Inbox" node (case-insensitive title match, any
        /// depth) wins; a root named Inbox is the preferred home.
        let inboxNode = Self.existingInboxNode(in: model)
        if let inboxNode,
            let insert = try OutlineConversion.insertCommand(
                fromText: text, parent: inboxNode,
                index: model.nodes[inboxNode]?.children.count ?? 0, in: model)
        {
            return insert
        }
        // No Inbox node: create one as a root, then append under it —
        // still ONE grouped command. The insert is validated against the
        // post-add state (a working copy), since the group applies the
        // addRoot first.
        let inbox = Node(id: UUID().uuidString, title: NodeTitle(text: "Inbox"))
        var working = model
        try MapCommand.addRoot(index: nil, node: inbox).apply(to: &working)
        if let insert = try OutlineConversion.insertCommand(
            fromText: text, parent: inbox.id, index: 0, in: working)
        {
            return .group(
                name: "Add to Inbox",
                commands: [
                    .addRoot(index: nil, node: inbox),
                    insert,
                ])
        }
        return .addRoot(index: nil, node: inbox)
    }

    /// The node titled "Inbox", preferring a root.
    static func existingInboxNode(in model: MapModel) -> String? {
        if let rootID = model.roots.first(where: {
            model.nodes[$0]?.title.text.caseInsensitiveCompare("Inbox") == .orderedSame
        }) {
            return rootID
        }
        return
            model.nodes.first {
                $0.value.title.text.caseInsensitiveCompare("Inbox") == .orderedSame
            }?.key
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Arbor inbox"
        alert.informativeText = message
        alert.runModal()
    }
}
