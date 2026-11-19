import AppKit
import CanvasKit
import Foundation
import MapAI
import MapCore
import Testing

@testable import Arbor

/// A provider whose answer is scripted ahead of time — these hosted
/// tests never touch a network (F-AI-1's real clients are covered by
/// the MapAI URLProtocol-stub suite).
private final class HostScriptedProvider: AIProvider, @unchecked Sendable {
    let descriptor: AIProviderDescriptor
    var isReady = true
    private let lock = NSLock()
    private var script: [[String]]
    var failure: (any Error)?
    private(set) var servedRequests: [AIRequest] = []

    init(
        descriptor: AIProviderDescriptor,
        script: [[String]],
        failure: (any Error)? = nil
    ) {
        self.descriptor = descriptor
        self.script = script
        self.failure = failure
    }

    private func nextDeltas() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !script.isEmpty else { return [] }
        return script.count > 1 ? script.removeFirst() : script[0]
    }

    func streamText(_ request: AIRequest, maxTokens: Int?) -> AsyncThrowingStream<AIStreamEvent, Error> {
        lock.lock()
        servedRequests.append(request)
        let failure = failure
        lock.unlock()
        let deltas = nextDeltas()
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                for delta in deltas {
                    await Task.yield()
                    continuation.yield(.textDelta(delta))
                }
                continuation.yield(.finished(AIFinish(reason: .endTurn)))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// Hosted tests for M8 slice 1: ⌘. streams ghosts (F-AI-2), ⇥ accepts
/// all as ONE undo step with author `.ai` (F-AI-5), Esc dismisses
/// without dirtying, per-document cloud opt-out blocks providers
/// (SPEC §12), and the generation/helpers build exact commands
/// (F-AI-3/F-AI-4).
@MainActor
struct AIFeatureTests {
    private static let cloudDescriptor = AIProviderDescriptor(kind: .anthropic, displayName: "Anthropic", isCloud: true)

    /// (language, ancestry, siblings) recorded via the prompt.
    private static let suggestionDeltas = [
        "{\"text\":\"Vocabulary\"}\n",
        "{\"text\":\"Grammar\"}\n{\"text\":\"Culture\"}\n",
    ]

    private struct Recorded {
        var errors: [AIError] = []
    }

    /// An untitled shown document whose AI controller is wired to a
    /// scripted provider (cloud unless told otherwise) with consent
    /// granted and errors recorded — no network, no modal alerts.
    /// Settings use an isolated UserDefaults suite: hosted tests run
    /// in one process, and a consent grant in one test must never leak
    /// into another.
    private static func makeShownDocument(
        provider: (any AIProvider)? = nil,
        consent: Bool = true
    ) throws -> AIHost {
        let document = try Self.makeShownDocumentOnly()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let scripted = provider as? HostScriptedProvider
        // Strong capture: the override must outlive this frame even when
        // the caller binds the tuple's provider slot to `_`.
        controller.ai.providerOverride = { scripted }
        let suiteName = "ai-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        controller.ai.settingsStore = AISettingsStore(defaults: defaults)
        controller.ai.consentHandler = { _ in consent }
        return AIHost(document: document, controller: controller, ai: controller.ai, provider: scripted)
    }

    /// Everything an AI test needs from one shown document window.
    private struct AIHost {
        let document: MapDocument
        let controller: DocumentWindowController
        let ai: AIController
        let provider: HostScriptedProvider?
    }

    private static func makeShownDocumentOnly() throws -> MapDocument {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        document.undoManager?.groupsByEvent = false
        document.makeWindowControllers()
        for case let controller as DocumentWindowController in document.windowControllers {
            controller.showWindow(nil)
        }
        return document
    }

    /// Yields the main actor until the AI task finished (or a cap hit).
    private static func settle(_ rounds: Int = 400) async {
        for _ in 0..<rounds {
            await Task.yield()
        }
    }

    private func typed(_ provider: HostScriptedProvider?) throws -> HostScriptedProvider {
        try #require(provider)
    }

    // MARK: F-AI-2 + F-AI-5

    @Test func expandShowsGhostSuggestionsAndTabAcceptsAllInOneUndoStep() async throws {
        let host = try Self.makeShownDocument(
            provider: HostScriptedProvider(descriptor: Self.cloudDescriptor, script: [Self.suggestionDeltas]))
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        var recorded: [AIError] = []
        ai.errorHandler = { recorded.append($0) }
        canvasSetup(controller)

        // One undo step exists: the placeholder root was seeded via
        // replaceModel (not a command). The root is committed empty.
        controller.canvas.commitEditing()
        let rootID = try #require(document.model.roots.first)
        controller.canvas.setSelection([rootID])

        // ⌘.
        controller.aiExpandAction(nil)
        await Self.settle()
        #expect(ai.presentingGhosts)
        #expect(controller.canvas.isPresentingGhosts)
        #expect(ai.suggestions.map(\.title) == ["Vocabulary", "Grammar", "Culture"])
        // Ghosts are view-only: the model has no children yet.
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)
        #expect(recorded.isEmpty)
        let acceptedIDs = Set(ai.suggestions.map(\.id))

        // ⇥ accepts ALL — one grouped command, one undo step.
        let before = document.model
        controller.addChildAction(nil)
        #expect(!ai.presentingGhosts)
        #expect(document.model.nodes[rootID]?.children.count == 3)
        #expect(Set(controller.canvas.selection) == acceptedIDs)

        // F-AI-5: the accepted nodes carry modifiedBy .ai.
        for childID in document.model.nodes[rootID]?.children ?? [] {
            #expect(document.model.nodes[childID]?.modifiedBy == .ai)
        }
        #expect(document.store.lastAuthor == .ai)

        // Exactly ONE undo step back to the pre-accept state. Journal
        // fields (modified/modifiedBy) are exempt — the store's own
        // docs: undo never rewinds them — so compare structure.
        #expect(document.undoManager?.canUndo == true)
        document.undoManager?.undo()
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)
        #expect(Self.sameStructure(document.model, before))
        _ = try typed(host.provider)
        document.close()
    }

    /// Model equality modulo the store's journal fields
    /// (`modified`/`modifiedBy` — deliberately not rewound by undo).
    static func sameStructure(_ lhs: MapModel, _ rhs: MapModel) -> Bool {
        guard lhs.roots == rhs.roots, Set(lhs.nodes.keys) == Set(rhs.nodes.keys) else {
            return false
        }
        for (id, node) in lhs.nodes {
            guard let other = rhs.nodes[id],
                node.parent == other.parent,
                node.children == other.children,
                node.title == other.title
            else {
                return false
            }
        }
        return true
    }

    @Test func escDismissesGhostsWithoutDirtyingTheDocument() async throws {
        let host = try Self.makeShownDocument(
            provider: HostScriptedProvider(descriptor: Self.cloudDescriptor, script: [Self.suggestionDeltas]))
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        canvasSetup(controller)
        let editedBefore = document.isDocumentEdited

        let rootID = try #require(document.model.roots.first)
        controller.canvas.setSelection([rootID])
        controller.aiExpandAction(nil)
        await Self.settle()
        #expect(ai.presentingGhosts)

        // Esc (the Deselect action) dismisses the ghosts first.
        controller.deselectAction(nil)
        #expect(!ai.presentingGhosts)
        #expect(controller.canvas.ghosts == nil)
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)
        #expect(document.undoManager?.canUndo == false)
        #expect(document.isDocumentEdited == editedBefore)
        document.close()
    }

    @Test func clickingAGhostAcceptsExactlyOne() async throws {
        let host = try Self.makeShownDocument(
            provider: HostScriptedProvider(descriptor: Self.cloudDescriptor, script: [Self.suggestionDeltas]))
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        canvasSetup(controller)
        let rootID = try #require(document.model.roots.first)
        controller.canvas.setSelection([rootID])
        controller.aiExpandAction(nil)
        await Self.settle()
        #expect(ai.suggestions.count == 3)

        let chosen = ai.suggestions[1]
        ai.acceptGhost(chosen.id)
        #expect(document.model.nodes[rootID]?.children.count == 1)
        #expect(document.model.nodes[chosen.id]?.title.text == chosen.title)
        #expect(document.model.nodes[chosen.id]?.modifiedBy == .ai)
        // One undo step removes it again.
        document.undoManager?.undo()
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)
        document.close()
    }

    @Test func pressingExpandAgainRegenerates() async throws {
        let host = try Self.makeShownDocument(
            provider: HostScriptedProvider(descriptor: Self.cloudDescriptor, script: [Self.suggestionDeltas]))
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        canvasSetup(controller)
        let rootID = try #require(document.model.roots.first)
        controller.canvas.setSelection([rootID])
        controller.aiExpandAction(nil)
        await Self.settle()
        let first = Set(ai.suggestions.map(\.id))

        // ⌘. again: fresh suggestions, fresh ids, nothing accepted.
        controller.aiExpandAction(nil)
        await Self.settle()
        #expect(ai.presentingGhosts)
        #expect(Set(ai.suggestions.map(\.id)).isDisjoint(with: first))
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)
        controller.ai.dismissGhosts()
        document.close()
    }

    @Test func refusalDiscardsPartialSuggestionsWithAFriendlyError() async throws {
        let host = try Self.makeShownDocument(
            provider: HostScriptedProvider(
                descriptor: Self.cloudDescriptor, script: [Self.suggestionDeltas], failure: AIError.refused))
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        var recorded: [AIError] = []
        ai.errorHandler = { recorded.append($0) }
        canvasSetup(controller)
        let rootID = try #require(document.model.roots.first)
        controller.canvas.setSelection([rootID])

        controller.aiExpandAction(nil)
        await Self.settle()
        // Nothing inserted, nothing ghosted, the typed error surfaced.
        #expect(!ai.presentingGhosts)
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)
        #expect(recorded == [.refused])
        #expect(document.undoManager?.canUndo == false)
        document.close()
    }

    // MARK: SPEC §12 privacy

    @Test func neverSendToCloudBlocksCloudProviders() async throws {
        let host = try Self.makeShownDocument(
            provider: HostScriptedProvider(descriptor: Self.cloudDescriptor, script: [Self.suggestionDeltas]))
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        var recorded: [AIError] = []
        ai.errorHandler = { recorded.append($0) }
        canvasSetup(controller)
        let rootID = try #require(document.model.roots.first)
        controller.canvas.setSelection([rootID])

        // The per-document flag, set through its one undoable command.
        controller.aiToggleNeverSendToCloudAction(nil)
        #expect(ai.neverSendToCloud)
        #expect(document.model.ai?.neverSendToCloud == true)

        controller.aiExpandAction(nil)
        await Self.settle()
        // Blocked before any request left the machine.
        #expect(try typed(host.provider).servedRequests.isEmpty)
        #expect(!ai.presentingGhosts)
        #expect(recorded == [.cloudBlockedByDocument])
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)

        // The toggle is one undoable command.
        document.undoManager?.undo()
        #expect(document.model.ai?.neverSendToCloud != true)
        document.close()
    }

    @Test func declinedConsentNeverCallsTheCloudProvider() async throws {
        let host = try Self.makeShownDocument(
            provider: HostScriptedProvider(descriptor: Self.cloudDescriptor, script: [Self.suggestionDeltas]),
            consent: false)
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        canvasSetup(controller)
        let rootID = try #require(document.model.roots.first)
        controller.canvas.setSelection([rootID])

        controller.aiExpandAction(nil)
        await Self.settle()
        #expect(try typed(host.provider).servedRequests.isEmpty)
        #expect(!ai.presentingGhosts)
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)
        document.close()
    }

    // MARK: F-AI-3 generation

    @Test func generateMapBuildsTheExactTreeFromTwoLevels() async throws {
        let script: [[String]] = [
            ["{\"text\":\"A\",\"parentIndex\":-1}\n{\"text\":\"B\",\"parentIndex\":-1}\n"],
            ["{\"text\":\"A1\",\"parentIndex\":0}\n{\"text\":\"B1\",\"parentIndex\":1}\n"],
        ]
        let host = try Self.makeShownDocument(
            provider: HostScriptedProvider(descriptor: Self.cloudDescriptor, script: script))
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        let scripted = try typed(host.provider)
        _ = controller

        let command = try await ai.generateMapCommand(source: .topic("Photosynthesis"), insertUnder: nil)
        // Exactly two requests: one per level (small context windows).
        #expect(scripted.servedRequests.count == 2)
        // Delivered through the sink the sheet/new-document path uses.
        var delivered: [MapCommand] = []
        ai.newDocumentSink = { delivered.append($0) }
        ai.deliverGeneratedMap(command: command)
        #expect(delivered.count == 1)

        var model = MapModel.emptyDocument()
        try command.apply(to: &model)
        #expect(model.roots.count == 1)
        let rootID = try #require(model.roots.first)
        #expect(model.nodes[rootID]?.title.text == "Photosynthesis")
        let children = try #require(model.nodes[rootID]?.children)
        #expect(children.count == 2)
        #expect(model.nodes[children[0]]?.children.map { model.nodes[$0]?.title.text } == ["A1"])
        #expect(model.nodes[children[1]]?.children.map { model.nodes[$0]?.title.text } == ["B1"])
        #expect(MapValidator.validate(model).isEmpty)

        // Insert-under instead: no new root, the branch lands on the
        // given node.
        let host2 = try Self.makeShownDocument(
            provider: HostScriptedProvider(descriptor: Self.cloudDescriptor, script: script))
        let insertCommand = try await host2.ai.generateMapCommand(source: .topic("T"), insertUnder: "root")
        var model2 = MapModel.emptyDocument()
        model2.nodes["root"] = Node(id: "root", title: NodeTitle(text: "Root"))
        model2.roots = ["root"]
        try insertCommand.apply(to: &model2)
        #expect(model2.roots == ["root"])
        #expect(model2.nodes["root"]?.children.count == 2)
        host2.document.close()
        document.close()
    }

    // MARK: F-AI-4 (P2)

    @Test func summarizeBranchWritesOneSetNoteUndoStep() async throws {
        let provider = HostScriptedProvider(
            descriptor: Self.cloudDescriptor,
            script: [["A well-structured summary of the branch."]])
        let host = try Self.makeShownDocument(provider: provider)
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        canvasSetup(controller)
        let rootID = try #require(document.model.roots.first)
        try document.store.perform(
            .addChild(parent: rootID, index: nil, node: Node(id: "branch", title: NodeTitle(text: "Branch"))))
        controller.canvas.setSelection(["branch"])

        await ai.summarizeBranchAction()
        #expect(document.model.nodes["branch"]?.note == "A well-structured summary of the branch.")
        #expect(document.model.nodes["branch"]?.modifiedBy == .ai)
        document.undoManager?.undo()
        #expect(document.model.nodes["branch"]?.note == nil)
        document.close()
    }

    @Test func rewriteTitlesReplacesEachNodeInOneUndoStep() async throws {
        let provider = HostScriptedProvider(
            descriptor: Self.cloudDescriptor,
            script: [["{\"text\":\"Short A\"}\n{\"text\":\"Short B\"}\n"]])
        let host = try Self.makeShownDocument(provider: provider)
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        canvasSetup(controller)
        let rootID = try #require(document.model.roots.first)
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "child", title: NodeTitle(text: "A Very Long Winded Title"))))
        controller.canvas.setSelection([rootID])

        await ai.rewriteTitlesAction()
        #expect(document.model.nodes[rootID]?.title.text == "Short A")
        #expect(document.model.nodes["child"]?.title.text == "Short B")
        #expect(document.store.lastAuthor == .ai)
        document.undoManager?.undo()
        #expect(document.model.nodes[rootID]?.title.text == "")
        #expect(document.model.nodes["child"]?.title.text == "A Very Long Winded Title")
        document.close()
    }

    @Test func suggestTitlePerformsOneSetTitleCommand() async throws {
        let provider = HostScriptedProvider(descriptor: Self.cloudDescriptor, script: [["Quarterly Plan"]])
        let host = try Self.makeShownDocument(provider: provider)
        let document = host.document
        let controller = host.controller
        let ai = host.ai
        canvasSetup(controller)
        let rootID = try #require(document.model.roots.first)
        try document.store.perform(
            .editText(id: rootID, title: NodeTitle(text: "some rambling root title")))

        await ai.suggestTitleAction()
        #expect(document.model.title == "Quarterly Plan")
        #expect(document.store.lastAuthor == .ai)
        document.undoManager?.undo()
        #expect(document.model.title == nil)
        document.close()
    }

    // MARK: helpers

    /// Leaves the placeholder editing session and seeds a titled root,
    /// the state every expansion test starts from.
    private func canvasSetup(_ controller: DocumentWindowController) {
        controller.canvas.commitEditing()
    }
}
