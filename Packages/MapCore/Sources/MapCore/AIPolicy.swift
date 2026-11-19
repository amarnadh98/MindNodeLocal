import Foundation

/// Per-document AI policy (SPEC §12, F-AI-1): the document-level privacy
/// flags for the AI assistant. Stored as `MapModel.ai`; every field is
/// optional so pre-v3 files (which have no `ai` object at all) decode
/// unchanged — a missing field means "no restriction".
///
/// Mutations go through `MapCommand.setAIPolicy` like every other model
/// change, so toggling is one undoable step.
public struct DocumentAIPolicy: Codable, Sendable, Hashable {
    /// The document's "Never send to cloud AI" flag (SPEC §12): when
    /// true, no node text of this document may leave the machine —
    /// only on-device providers may serve it. On-device providers are
    /// always allowed.
    public var neverSendToCloud: Bool?

    public init(neverSendToCloud: Bool? = nil) {
        self.neverSendToCloud = neverSendToCloud
    }
}
