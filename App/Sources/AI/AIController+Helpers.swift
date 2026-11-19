import AppKit
import MapAI
import MapCore

/// The AI assistant's secondary surface (see `AIController`): the
/// F-AI-4 helpers, their tree walks, and the error/consent UI — split
/// out so the controller's core (provider resolution + the ghost
/// expansion flow) stays reviewable in one screen.
extension AIController {
    // MARK: F-AI-4 (P2) study/helpers

    /// Summarize the selected branch into its note: ONE `setNote`,
    /// author `.ai`.
    func summarizeBranchAction() async {
        guard let host, let document = host.document as? MapDocument,
            let selectedID = host.canvas.selection.sorted().first
        else { return }
        do {
            let (provider, isCloud) = try resolveProviderForRequest()
            if isCloud, await authorizeCloud(provider.descriptor) == false { return }
            let titles = Self.subtreeTitles(rootID: selectedID, in: document.model)
            guard !titles.isEmpty else { return }
            let notes = Self.subtreeNotes(rootID: selectedID, in: document.model)
            let (text, _) = try await provider.completeText(
                Prompts.summarizeBranch(titles: titles, notes: notes), maxTokens: 2_048)
            let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return }
            try document.store.perform(.setNote(id: selectedID, note: summary), author: .ai)
        } catch let error as AIError {
            present(error)
        } catch {
            present(.invalidResponse("generation failed"))
        }
    }

    /// Rewrite the selected subtree's titles concisely: ONE grouped
    /// `editText` per node (author `.ai`), one undo step.
    func rewriteTitlesAction() async {
        guard let host, let document = host.document as? MapDocument,
            let selectedID = host.canvas.selection.sorted().first
        else { return }
        let ids = Self.subtreeIDs(rootID: selectedID, in: document.model)
        let titles = ids.compactMap { document.model.nodes[$0]?.title.text }
        guard !titles.isEmpty else { return }
        do {
            let (provider, isCloud) = try resolveProviderForRequest()
            if isCloud, await authorizeCloud(provider.descriptor) == false { return }
            let (text, _) = try await provider.completeText(
                Prompts.rewriteTitles(titles: titles), maxTokens: 4_096)
            let rewritten = JSONLinesParser.parse(text)
            guard !rewritten.isEmpty else { return }
            var commands: [MapCommand] = []
            for (index, id) in ids.enumerated() where index < rewritten.count {
                let newTitle = rewritten[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newTitle.isEmpty, newTitle != document.model.nodes[id]?.title.text else {
                    continue
                }
                commands.append(.editText(id: id, title: NodeTitle(text: newTitle)))
            }
            if let command = commands.count == 1
                ? commands.first
                : (commands.isEmpty ? nil : .group(name: "Rewrite Titles", commands: commands))
            {
                try document.store.perform(command, author: .ai)
            }
        } catch let error as AIError {
            present(error)
        } catch {
            present(.invalidResponse("generation failed"))
        }
    }

    /// Suggest a document title: ONE `setTitle`, author `.ai`.
    func suggestTitleAction() async {
        guard let host, let document = host.document as? MapDocument else { return }
        let outline = document.model.roots.flatMap { rootID in
            Self.subtreeTitles(rootID: rootID, in: document.model)
        }
        guard !outline.isEmpty else { return }
        do {
            let (provider, isCloud) = try resolveProviderForRequest()
            if isCloud, await authorizeCloud(provider.descriptor) == false { return }
            let (text, _) = try await provider.completeText(
                Prompts.suggestDocumentTitle(outline: outline), maxTokens: 64)
            let title =
                text
                .split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return }
            try document.store.perform(.setTitle(title), author: .ai)
        } catch let error as AIError {
            present(error)
        } catch {
            present(.invalidResponse("generation failed"))
        }
    }

    // MARK: F-AI-1/§12 per-document opt-out

    /// The document menu's "Never send to cloud AI" toggle: one undoable
    /// `setAIPolicy` command (stored in `map.json`'s `ai` object).
    func toggleNeverSendToCloud() {
        guard let document = host?.document as? MapDocument else { return }
        let current = document.model.ai?.neverSendToCloud == true
        let policy = current ? nil : DocumentAIPolicy(neverSendToCloud: true)
        try? document.store.perform(.setAIPolicy(policy: policy))
        // A policy flip mid-expansion must drop the ghosts if they came
        // from a (now forbidden) cloud stream.
        if presentingGhosts, let provider = resolveProvider(),
            provider.descriptor.isCloud, policy?.neverSendToCloud == true
        {
            dismissGhosts()
        }
    }

    var neverSendToCloud: Bool {
        (host?.document as? MapDocument)?.model.ai?.neverSendToCloud == true
    }

    // MARK: tree walks (F-AI-4 helpers)

    static func subtreeIDs(rootID: String, in model: MapModel) -> [String] {
        var result: [String] = []
        var stack = [rootID]
        while let id = stack.popLast() {
            guard let node = model.nodes[id] else { continue }
            result.append(id)
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }

    static func subtreeTitles(rootID: String, in model: MapModel) -> [String] {
        subtreeIDs(rootID: rootID, in: model).compactMap { model.nodes[$0]?.title.text }
    }

    static func subtreeNotes(rootID: String, in model: MapModel) -> [String] {
        subtreeIDs(rootID: rootID, in: model).compactMap { model.nodes[$0]?.note ?? "" }
    }

    // MARK: errors & consent UI

    func present(_ error: AIError) {
        if let errorHandler {
            errorHandler(error)
            return
        }
        Self.presentError(error, window: host?.window)
    }

    /// The friendly, user-facing message for every typed AI failure.
    static func friendlyMessage(for error: AIError) -> String {
        switch error {
        case .notEnabled:
            "AI is turned off. Enable it in Settings ▸ AI."
        case .noUsableProvider:
            "No AI provider is available. Configure one in Settings ▸ AI."
        case .cloudBlockedByDocument:
            "This document is marked “Never send to cloud AI.”"
        case .consentRequired(let descriptor):
            "Allow “\(descriptor.displayName)” in Settings ▸ AI before sending map text to it."
        case .refused:
            "The AI provider declined this request."
        case .truncated:
            "The AI stopped early — the result may be incomplete."
        case .unauthorized:
            "The stored API key is missing or invalid. Update it in Settings ▸ AI."
        case .rateLimited:
            "The AI provider is rate-limiting requests. Try again in a moment."
        case .server:
            "The AI provider is having trouble. Try again in a moment."
        case .network:
            "Could not reach the AI provider."
        case .invalidResponse:
            "The AI provider returned something Arbor could not read."
        case .unavailable:
            "The on-device model is not available on this Mac."
        }
    }

    static func presentError(_ error: AIError, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = friendlyMessage(for: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// The one-time cloud consent sheet (SPEC §12): the privacy notice
    /// names the provider — "map text is sent to <provider>".
    static func presentConsentSheet(_ descriptor: AIProviderDescriptor, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Send map text to \(descriptor.displayName)?"
        alert.informativeText = Self.consentCopy(descriptor.displayName)
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        guard let window else {
            return await withCheckedContinuation { continuation in
                continuation.resume(returning: alert.runModal() == .alertSecondButtonReturn)
            }
        }
        let response = await alert.beginSheetModal(for: window)
        return response == .alertSecondButtonReturn
    }

    /// The privacy notice (SPEC §12) — copy kept in one place.
    static func consentCopy(_ providerName: String) -> String {
        "When you use \(providerName), the text of this map is sent to that provider "
            + "over the network and processed under its terms. Nothing is sent without "
            + "an action like Expand or Generate. You can turn this off any time in "
            + "Settings ▸ AI, or per document with “Never Send to Cloud AI.”"
    }
}
