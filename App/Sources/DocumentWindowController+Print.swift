import AppKit

/// F-INT-9's File ▸ Print… / Page Setup… validation. Lives in its own
/// file: `DocumentWindowController.swift` is at SwiftLint's file-length
/// limit, and the single `validateMenuItem` is at its cyclomatic limit —
/// so this is a `Bool?` helper chained from that function's `default:`
/// arm (the same shape as `validateDocumentSafetyMenuItem`), not a new
/// switch case.
extension DocumentWindowController {
    /// Nil for items that aren't print's. Print needs a node to print —
    /// an empty document would only compose a job the composer refuses
    /// (`PrintComposer` throws `emptyScene`) — and Page Setup always
    /// applies to a document window.
    func validatePrintMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        guard let mapDocument = document as? MapDocument else { return nil }
        switch menuItem.action {
        case #selector(NSDocument.printDocument(_:)):
            return !mapDocument.store.model.nodes.isEmpty
        case #selector(NSDocument.runPageLayout(_:)):
            return true
        default:
            return nil
        }
    }
}
