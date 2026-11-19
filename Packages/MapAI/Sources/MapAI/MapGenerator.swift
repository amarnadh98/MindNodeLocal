import Foundation
import MapCore

/// A generated map before it becomes model nodes (F-AI-3): a flat list
/// of `{text, parentIndex}` — the SPEC §5.15 shape that respects small
/// on-device context windows. `parentIndex` is -1 for children of the
/// central topic, otherwise the index of an earlier item.
public struct MapSketch: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Codable {
        public var text: String
        public var parentIndex: Int

        public init(text: String, parentIndex: Int) {
            self.text = text
            self.parentIndex = parentIndex
        }
    }

    public var centralTitle: String
    public var items: [Item]

    public init(centralTitle: String, items: [Item]) {
        self.centralTitle = centralTitle
        self.items = items
    }
}

/// Normalization shared by every sketch producer: parents must precede
/// their children, indexes must resolve, text is trimmed and capped —
/// defensive against whatever the model actually answered.
public enum SketchSanitizer {
    public static func clean(_ items: [AIListItem], centralTitle: String) -> MapSketch {
        var result: [MapSketch.Item] = []
        for item in items {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let parent = item.parentIndex ?? -1
            // A parent that does not exist (yet) or that appears later
            // would create a cycle or an orphan: attach to the center.
            guard parent >= 0, parent < result.count else {
                result.append(MapSketch.Item(text: String(text.prefix(120)), parentIndex: -1))
                continue
            }
            result.append(MapSketch.Item(text: String(text.prefix(120)), parentIndex: parent))
        }
        return MapSketch(centralTitle: String(centralTitle.prefix(80)), items: result)
    }
}

/// Turns a sanitized sketch into exactly ONE grouped `MapCommand`
/// (F-AI-5: one undo group, one undo step). Either a whole new map
/// under a fresh root, or a branch inserted under an existing node
/// (`insertUnder`; then no new root is created and the sketch's
/// level-1 items attach to that node).
public enum SketchCommands {
    public static func makeCommand(sketch: MapSketch, insertUnder parentID: String?) -> MapCommand {
        func node(_ text: String) -> Node {
            Node(id: UUID().uuidString, title: NodeTitle(text: text))
        }

        // Create in item order so a child always follows its parent
        // (SketchSanitizer guarantees parents precede children).
        var commands: [MapCommand] = []
        var rootID = parentID
        if rootID == nil {
            let root = node(sketch.centralTitle)
            rootID = root.id
            commands.append(.addRoot(index: nil, node: root))
        }
        var idsByItem: [Int: String] = [:]
        for (index, item) in sketch.items.enumerated() {
            let fresh = node(item.text)
            idsByItem[index] = fresh.id
            let parent = item.parentIndex >= 0 ? idsByItem[item.parentIndex] : rootID
            commands.append(.addChild(parent: parent ?? rootID!, index: nil, node: fresh))
        }
        return MapCommand.group(name: "Generate Map", commands: commands)
    }
}

/// Level-by-level map generation (F-AI-3): two small requests instead
/// of one huge one, so an on-device model with a small context window
/// can serve it. Level 1 asks for the main branches; level 2 lists the
/// level-1 nodes (numbered) and asks for children of each, flat
/// `{text, parentIndex}` referencing the numbers.
public enum MapSketchGenerator {
    /// How many parents the level-2 prompt lists (bounded for small
    /// context windows).
    public static let levelParentLimit = 8

    public static func generate(
        source: GenerationSource,
        provider: any AIProvider,
        includeSecondLevel: Bool = true
    ) async throws -> MapSketch {
        let first = try await generateLevel(
            request: Prompts.generateFirstLevel(source: source),
            provider: provider, maxTokens: 16_000, centralTitle: source.centralTitle)
        guard includeSecondLevel, !first.items.isEmpty else {
            return first
        }
        let parents = Array(first.items.prefix(levelParentLimit)).map {
            AIListItem(text: $0.text, parentIndex: $0.parentIndex)
        }
        return try await generateLevel(
            request: Prompts.generateNextLevel(source: source, parents: parents),
            provider: provider, maxTokens: 16_000, centralTitle: first.centralTitle,
            existing: first)
    }

    /// One level: HTTP providers answer JSON lines (streamed, parsed
    /// defensively); the Apple provider answers through its
    /// `@Generable` guided decoding. With `existing`, the level-2
    /// parents keep their item indexes, so the model's parent numbers
    /// address the merged list directly and one `clean` validates the
    /// whole sketch.
    static func generateLevel(
        request: AIRequest,
        provider: any AIProvider,
        maxTokens: Int,
        centralTitle: String,
        existing: MapSketch? = nil
    ) async throws -> MapSketch {
        var raw: [AIListItem] = []
        if let apple = provider as? AppleOnDeviceProvider {
            raw = try await apple.generateLevel(prompt: request.prompt, system: request.system)
        } else {
            var parser = JSONLinesStreamParser()
            for try await event in provider.streamText(request, maxTokens: maxTokens) {
                switch event {
                case .textDelta(let delta):
                    raw += parser.feed(delta)
                case .finished:
                    break
                }
            }
            raw += parser.finish()
        }
        if let existing {
            let merged = existing.items.map { AIListItem(text: $0.text, parentIndex: $0.parentIndex) } + raw
            return SketchSanitizer.clean(merged, centralTitle: centralTitle)
        }
        return SketchSanitizer.clean(raw, centralTitle: centralTitle)
    }
}
