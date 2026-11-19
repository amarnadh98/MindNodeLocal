import AppKit
import CanvasKit
import MapAI
import MapCore
import MapRender
import os

/// The per-window AI assistant (F-AI-2/F-AI-3/F-AI-4): resolves the
/// provider from Settings ▸ AI (on-device first, SPEC §5.15), streams
/// expand-node suggestions in as canvas ghosts, and turns accepted
/// suggestions / generated sketches / rewrites into exactly ONE
/// grouped `MapCommand` performed with author `.ai` — one undo step,
/// stamped `lastModifiedBy: "ai"` in the document metadata (F-AI-5).
///
/// Privacy (SPEC §12): cloud providers run only after the master
/// switch, the one-time consent sheet and the per-document
/// "Never send to cloud AI" flag all allow it; keys stay in the
/// Keychain and are never logged.
@MainActor
final class AIController {
    weak var host: DocumentWindowController?

    /// Settings + secrets, injectable for tests.
    var settingsStore = AISettingsStore()
    var keys: any APIKeyStore = SystemKeychainStore()

    /// Test seams: fixed provider, recorded errors, instant consent.
    var providerOverride: (() -> (any AIProvider)?)?
    var errorHandler: ((AIError) -> Void)?
    var consentHandler: (@MainActor (AIProviderDescriptor) async -> Bool)?
    /// Where a generated map lands (default: a new untitled document).
    var newDocumentSink: ((MapCommand) -> Void)?

    // MARK: provider resolution (F-AI-1)

    /// The provider the settings select, honoring the master switch,
    /// readiness and the per-document cloud opt-out. Nil = all AI UI
    /// stays hidden/disabled.
    func resolveProvider() -> (any AIProvider)? {
        if let providerOverride {
            return providerOverride()
        }
        let settings = settingsStore.load()
        return AIProviderFactory.resolve(settings: settings, keys: keys)
    }

    /// True when the AI menu should exist at all: the master switch is
    /// on. (Individual items still validate against selection and
    /// provider readiness.)
    var menuAvailable: Bool {
        settingsStore.load().enabled
    }

    /// Resolves a provider for a request that would send map text:
    /// enforces consent + the per-document cloud opt-out first.
    /// Throws the typed privacy error instead of silently sending.
    func resolveProviderForRequest() throws -> (any AIProvider, Bool) {
        let provider = try requireProvider(resolveProvider())
        guard provider.descriptor.isCloud else {
            return (provider, false)
        }
        if host?.document == nil {
            throw AIError.noUsableProvider
        }
        // The per-document flag lives in the model (MapModel.ai).
        if let document = host?.document as? MapDocument,
            document.model.ai?.neverSendToCloud == true
        {
            throw AIError.cloudBlockedByDocument
        }
        return (provider, true)
    }

    /// The first-cloud-call consent (SPEC §12): presents the privacy
    /// sheet "map text is sent to <provider>" once; the grant persists
    /// in settings.
    func authorizeCloud(_ descriptor: AIProviderDescriptor) async -> Bool {
        var settings = settingsStore.load()
        if settings.cloudConsentGranted {
            return true
        }
        let granted: Bool
        if let consentHandler {
            granted = await consentHandler(descriptor)
        } else {
            granted = await Self.presentConsentSheet(descriptor, window: host?.window)
        }
        if granted {
            settings.cloudConsentGranted = true
            settingsStore.save(settings)
        }
        return granted
    }

    // MARK: F-AI-2 expand node

    /// One streamed suggestion: the ghost id IS the eventual node id,
    /// so accepting is exactly one addChild per suggestion.
    struct Suggestion: Equatable {
        let id: String
        let title: String
    }

    private var expandTask: Task<Void, Never>?
    private(set) var suggestions: [Suggestion] = []
    private(set) var expandedParentID: String?
    private var streamTruncated = false

    var presentingGhosts: Bool {
        expandedParentID != nil
    }

    /// ⌘. — expand the single selected node; pressed again while
    /// ghosts are showing, regenerates from scratch.
    func expandAction() {
        if presentingGhosts {
            if let parentID = expandedParentID {
                startExpansion(parentID: parentID)
            }
            return
        }
        guard
            let host,
            let document = host.document as? MapDocument,
            host.canvas.selection.count == 1,
            let selectedID = host.canvas.selection.first,
            document.model.nodes[selectedID] != nil
        else { return }
        startExpansion(parentID: selectedID)
    }

    private func startExpansion(parentID: String) {
        expandTask?.cancel()
        suggestions = []
        expandedParentID = parentID
        streamTruncated = false
        let provider: any AIProvider
        let isCloud: Bool
        do {
            (provider, isCloud) = try resolveProviderForRequest()
        } catch let error as AIError {
            present(error)
            clearGhosts()
            return
        } catch {
            clearGhosts()
            return
        }

        let request: AIRequest
        if let host, let document = host.document as? MapDocument {
            guard let built = ExpandContext.request(for: parentID, in: document.model) else {
                clearGhosts()
                return
            }
            request = built
        } else {
            clearGhosts()
            return
        }

        expandTask = Task { [weak self] in
            if isCloud, await self?.authorizeCloud(provider.descriptor) == false {
                self?.clearGhosts()
                return
            }
            if isCloud {
                aiLog.debug("Expanding a node with \(provider.descriptor.displayName)")
            }
            var parser = JSONLinesStreamParser()
            do {
                for try await event in provider.streamText(request, maxTokens: 4_096) {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .textDelta(let delta):
                        self.absorb(parser.feed(delta))
                    case .finished(let finish):
                        self.streamTruncated = finish.reason == .maxTokens
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.absorb(parser.finish())
                self.refreshGhostPresentation()
                if self.streamTruncated {
                    self.present(.truncated)
                }
            } catch let error as AIError {
                // A refusal discards everything streamed so far.
                self?.clearGhosts()
                self?.present(error)
            } catch {
                if !Task.isCancelled {
                    self?.clearGhosts()
                }
            }
        }
    }

    private func absorb(_ parsed: [AIListItem]) {
        guard !parsed.isEmpty else { return }
        for item in parsed where suggestions.count < 8 {
            let title = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            suggestions.append(Suggestion(id: UUID().uuidString, title: title))
        }
        refreshGhostPresentation()
    }

    /// Rebuilds the ghost overlay: a probe scene (model + suggested
    /// children) laid out through the SAME geometry the canvas uses —
    /// a full rebuild per ghost change, deliberate (SPEC: "force a
    /// full rebuild"; ghosts are view-only) so the document's
    /// incremental caches never see ghost nodes.
    private func refreshGhostPresentation() {
        guard let host,
            let document = host.document as? MapDocument,
            let parentID = expandedParentID,
            let parent = document.model.nodes[parentID]
        else { return }

        var probe = document.model
        for suggestion in suggestions {
            probe.nodes[suggestion.id] = Node(
                id: suggestion.id, parent: parentID, title: NodeTitle(text: suggestion.title))
            probe.nodes[parentID]?.children.append(suggestion.id)
        }
        let scene = SceneGeometry.build(
            model: probe, variant: host.effectiveThemeVariant, measurer: SceneRenderer.sharedMeasurer)
        let items = suggestions.compactMap { suggestion -> GhostPresentation.Item? in
            guard let node = scene.nodes[suggestion.id] else { return nil }
            return GhostPresentation.Item(id: suggestion.id, node: node)
        }
        guard !items.isEmpty else {
            host.canvas.ghosts = nil
            return
        }
        let branches = scene.branches.filter { suggestion in
            suggestions.contains { $0.id == suggestion.childID }
        }
        _ = parent
        host.canvas.ghosts = GhostPresentation(parentID: parentID, items: items, branches: branches)
    }

    /// ⇥ — accept every ghost as ONE grouped command, one undo step,
    /// author `.ai` (F-AI-5).
    func acceptAll() {
        guard let parentID = expandedParentID, !suggestions.isEmpty else { return }
        accept(ids: Set(suggestions.map(\.id)), parentID: parentID)
    }

    /// A ghost click — accept exactly one suggestion.
    func acceptGhost(_ id: String) {
        guard let parentID = expandedParentID else { return }
        accept(ids: [id], parentID: parentID)
    }

    private func accept(ids: Set<String>, parentID: String) {
        guard let host, let document = host.document as? MapDocument else { return }
        let accepted = suggestions.filter { ids.contains($0.id) }
        guard !accepted.isEmpty else { return }
        var commands: [MapCommand] = []
        // A folded parent would hide the accepted children: unfold in
        // the same step.
        if document.model.nodes[parentID]?.folded == true {
            commands.append(.setFolded(id: parentID, folded: false))
        }
        for suggestion in accepted {
            commands.append(
                .addChild(
                    parent: parentID, index: nil,
                    node: Node(id: suggestion.id, title: NodeTitle(text: suggestion.title))))
        }
        let command = MapCommand.group(name: "Add AI Suggestions", commands: commands)
        do {
            try document.store.perform(command, author: .ai)
        } catch {
            return
        }
        clearGhosts()
        host.canvas.setSelection(ids)
        host.canvas.scrollSelectionIntoView()
    }

    /// Esc — dismiss the ghosts without touching the document.
    func dismissGhosts() {
        expandTask?.cancel()
        clearGhosts()
    }

    private func clearGhosts() {
        suggestions = []
        expandedParentID = nil
        streamTruncated = false
        host?.canvas.ghosts = nil
    }

    /// After any model change: the expansion target may be gone —
    /// drop the ghosts instead of accepting into a deleted node.
    func modelDidChange() {
        guard presentingGhosts, let host, let document = host.document as? MapDocument,
            let parentID = expandedParentID
        else { return }
        if document.model.nodes[parentID] == nil {
            dismissGhosts()
        }
    }

    // MARK: F-AI-3 generate map

    /// Generates a map level-by-level (two small requests) and returns
    /// the ONE grouped command that builds it — a new-document root or
    /// a branch under `insertUnder`. The sheet calls this on a Task;
    /// tests call it directly with a fake provider.
    func generateMapCommand(
        source: GenerationSource, insertUnder: String?, provider: (any AIProvider)? = nil
    ) async throws -> MapCommand {
        let resolved = try requireProvider(provider ?? resolveProvider())
        let isCloud = resolved.descriptor.isCloud
        if isCloud {
            if let document = host?.document as? MapDocument,
                document.model.ai?.neverSendToCloud == true
            {
                throw AIError.cloudBlockedByDocument
            }
            guard await authorizeCloud(resolved.descriptor) else {
                throw AIError.consentRequired(resolved.descriptor)
            }
        }
        let sketch = try await MapSketchGenerator.generate(source: source, provider: resolved)
        aiLog.debug("Generated a \(sketch.items.count)-node sketch")
        return SketchCommands.makeCommand(sketch: sketch, insertUnder: insertUnder)
    }

    /// Where a generated map lands when no insertion point is given:
    /// a new untitled document, the command performed with author
    /// `.ai` as its single undo step.
    func deliverGeneratedMap(command: MapCommand) {
        if let newDocumentSink {
            newDocumentSink(command)
            return
        }
        Self.openNewDocumentWith(command)
    }

    /// F-AI-3's default delivery: a fresh untitled document whose
    /// store performs the generation command.
    static func openNewDocumentWith(_ command: MapCommand) {
        guard
            let document =
                (try? NSDocumentController.shared.makeUntitledDocument(
                    ofType: AppIdentity.documentUTI)) as? MapDocument
        else { return }
        document.store.replaceModel(MapModel.emptyDocument())
        try? document.store.perform(command, author: .ai)
        document.makeWindowControllers()
        for case let controller as DocumentWindowController in document.windowControllers {
            controller.showWindow(nil)
        }
        document.updateChangeCount(.changeDone)
    }
}

private let aiLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "arbor", category: "ai")

/// The `guard` bridge: a typed error instead of a silent nil provider.
private func requireProvider(_ provider: (any AIProvider)?) throws -> any AIProvider {
    guard let provider else {
        throw AIError.noUsableProvider
    }
    return provider
}
