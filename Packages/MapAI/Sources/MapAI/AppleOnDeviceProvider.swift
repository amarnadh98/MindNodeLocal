import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    /// The Apple on-device backend (F-AI-1 option 1, SPEC §11.1): the
    /// system language model via the FoundationModels framework — the
    /// default provider whenever `SystemLanguageModel.default.availability`
    /// is `.available`. No network, no key, no consent (SPEC §12).
    ///
    /// Plain-text streaming uses `LanguageModelSession.streamResponse`, the
    /// partial-content snapshots diffed into deltas so every provider
    /// streams the same way. Structured output (the generated-map sketch)
    /// goes through `@Generable` structs — the framework's guided decoding —
    /// instead of JSON lines (ADR-0017).
    public struct AppleOnDeviceProvider: AIProvider {
        public let descriptor = AIProviderDescriptor(kind: .apple, displayName: "Apple On-Device", isCloud: false)

        public var isReady: Bool { availability.isAvailable }

        private let availability: SystemLanguageModel.Availability

        public init() {
            availability = SystemLanguageModel.default.availability
        }

        init(availability: SystemLanguageModel.Availability) {
            self.availability = availability
        }

        public func streamText(
            _ request: AIRequest, maxTokens: Int?
        ) -> AsyncThrowingStream<AIStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await run(
                            request,
                            emit: { event in
                                continuation.yield(event)
                            })
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }

        private func run(
            _ request: AIRequest, emit: @escaping @Sendable (AIStreamEvent) -> Void
        ) async throws {
            guard availability.isAvailable else {
                throw AIError.unavailable("the on-device model is not ready on this Mac")
            }
            let session = Self.makeSession(system: request.system)
            // streamResponse yields growing snapshots, not deltas: keep the
            // already-emitted prefix and forward only the tail.
            var emitted = 0
            let stream = session.streamResponse(to: request.prompt)
            for try await partial in stream {
                try Task.checkCancellation()
                let content = partial.content
                guard content.count > emitted else { continue }
                let tail = String(content.dropFirst(emitted))
                emitted = content.count
                emit(.textDelta(tail))
            }
            emit(.finished(AIFinish(reason: .endTurn)))
        }

        private static func makeSession(system: String?) -> LanguageModelSession {
            if let system, !system.isEmpty {
                return LanguageModelSession(instructions: system)
            }
            return LanguageModelSession()
        }
    }

    extension SystemLanguageModel.Availability {
        var isAvailable: Bool {
            if case .available = self {
                return true
            }
            return false
        }
    }

    // MARK: - structured output (F-AI-3)

    /// One `@Generable` node of a generated level (top level: the framework
    /// macro does not support nested `@Generable` types).
    @Generable
    public struct GeneratedSketchItem: Sendable {
        @Guide(description: "Short node title, 1-8 words")
        public var text: String

        @Guide(description: "Index of the parent node in the given parent list, or -1 for a child of the central topic")
        public var parentIndex: Int
    }

    /// The `@Generable` schema for a generated map level (SPEC §5.15:
    /// "flat `@Generable` list `{text, parentIndex}`"): guided decoding on
    /// device, JSON lines only for the HTTP providers (ADR-0017).
    @Generable
    public struct GeneratedSketchLevel {
        @Guide(description: "Every node of this level")
        public var items: [GeneratedSketchItem]
    }

    extension AppleOnDeviceProvider {
        /// One structured generation step on device: the flat
        /// `{text, parentIndex}` list for a level, decoded through the
        /// `@Generable` schema. Cloud providers use the JSON-lines prompt
        /// instead — both produce `AIListItem`s.
        public func generateLevel(prompt: String, system: String?) async throws -> [AIListItem] {
            guard availability.isAvailable else {
                throw AIError.unavailable("the on-device model is not ready on this Mac")
            }
            let session = Self.makeSession(system: system)
            let response = try await session.respond(to: prompt, generating: GeneratedSketchLevel.self)
            let level = response.content
            return level.items.map { AIListItem(text: $0.text, parentIndex: $0.parentIndex) }
        }
    }

#else

    /// Placeholder when FoundationModels is unavailable at compile time: no
    /// on-device provider exists, so it never reports ready and every call
    /// throws — the rest of the AI stack keeps working with HTTP providers.
    public struct AppleOnDeviceProvider: AIProvider {
        public let descriptor = AIProviderDescriptor(kind: .apple, displayName: "Apple On-Device", isCloud: false)

        public var isReady: Bool { false }

        public init() {}

        public func streamText(
            _ request: AIRequest, maxTokens: Int?
        ) -> AsyncThrowingStream<AIStreamEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: AIError.unavailable("FoundationModels is not available")) }
        }
    }

#endif
