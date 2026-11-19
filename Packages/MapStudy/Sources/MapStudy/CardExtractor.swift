import Foundation
import MapCore

/// A study card derived on demand from a node (SPEC §10, F-STD-1/2).
/// Card ids are stable across edits that do not touch the node:
/// `nodeID` basic, `nodeID#r` reversed, `nodeID#cN` cloze, `summaryID` summary.
public struct Card: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable {
        case basic
        case reversed
        case cloze
        case summary
    }

    /// The stable card id (the key for review state and the review log).
    public let id: String
    public let kind: Kind
    /// The node that owns this card's content and review state.
    public let nodeID: String
    /// The prompt: the node's title with its ancestor path as breadcrumb
    /// context ("Biology › Cell › Mitochondria"); for reversed cards the
    /// answer side; for summaries the sibling-range prompt; for clozes the
    /// masked text.
    public let front: String
    /// The answer: child titles in map order plus the note (basic); the
    /// breadcrumb prompt (reversed); the summary node's title (summary); the
    /// full unmasked text (cloze).
    public let back: String
}

/// Derives study cards from a map (SPEC §10, F-STD-1/F-STD-2).
///
/// Card policy on a node's `study.card` (SPEC §8.2):
/// - `off`: no cards of any kind are derived from the node.
/// - `on`: a basic card even for a bare leaf; the explicit marking also opts the
///   node into a reversed card (F-STD-2 "Reversed, optional") when the node has
///   answer content, so ids `nodeID` and `nodeID#r` travel together.
/// - `auto` (or unset): a basic card iff the node has children or a note —
///   "a node becomes a card if it has children or a note; leaf nodes without a
///   note are not cards by default" (F-STD-1).
///
/// Cloze markup in a title or note is explicit intent, so cloze cards are
/// derived whenever the node is not `off`, regardless of the auto rule; one
/// card per distinct deletion index, emitted in ascending index order.
/// Summary cards come from `summaries`: the sibling range is the prompt, the
/// summary node's title the answer; the summary node can opt out with `off`.
///
/// Cards are emitted in map (outline) order: roots in creation order, then
/// depth-first in `children` order; a node's own cards come before its
/// children's, and a summary card follows the last sibling of its range.
public enum CardExtractor {
    public static func extract(from map: MapModel) -> [Card] {
        let context = ExtractionContext(map: map)
        for root in map.roots {
            context.visit(root, breadcrumb: [])
        }
        return context.cards
    }

    private final class ExtractionContext {
        let map: MapModel
        var cards: [Card] = []
        private var summariesByLastChild: [String: [Summary]]
        private var pendingSummaries: Set<String> = []

        init(map: MapModel) {
            self.map = map
            summariesByLastChild = [:]
            for summary in map.summaries ?? [] {
                guard let last = summary.range.last else { continue }
                summariesByLastChild[last, default: []].append(summary)
                pendingSummaries.insert(summary.id)
            }
        }

        func visit(_ nodeID: String, breadcrumb: [String]) {
            guard let node = map.nodes[nodeID] else { return }
            cards.append(contentsOf: nodeCards(node, breadcrumb: breadcrumb))
            var childBreadcrumb = breadcrumb
            childBreadcrumb.append(node.title.text)
            for child in node.children {
                visit(child, breadcrumb: childBreadcrumb)
            }
            for summary in summariesByLastChild[nodeID] ?? [] where pendingSummaries.contains(summary.id) {
                pendingSummaries.remove(summary.id)
                if let card = summaryCard(summary) {
                    cards.append(card)
                }
            }
        }

        // MARK: Per-node cards

        private func nodeCards(_ node: Node, breadcrumb: [String]) -> [Card] {
            let policy = node.study?.card ?? .auto
            guard policy != .off else { return [] }

            let title = node.title.text
            let note = node.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let front = (breadcrumb + [title]).joined(separator: " › ")
            let back = answerText(children: node.children, note: note)
            var cards: [Card] = []

            let isBasic: Bool
            switch policy {
            case .on: isBasic = true
            case .auto: isBasic = !node.children.isEmpty || !note.isEmpty
            case .off: isBasic = false
            }
            if isBasic {
                cards.append(Card(id: node.id, kind: .basic, nodeID: node.id, front: front, back: back))
                if policy == .on, !back.isEmpty {
                    cards.append(Card(id: node.id + "#r", kind: .reversed, nodeID: node.id, front: back, back: front))
                }
            }

            let clozeIndices = ClozeParser.indices(in: title) + ClozeParser.indices(in: note)
            for index in Array(Set(clozeIndices)).sorted() {
                var maskedFront = ClozeParser.rendered(text: title, clozeIndex: index)
                var fullText = ClozeParser.revealed(text: title)
                if !note.isEmpty {
                    maskedFront += "\n\n" + ClozeParser.rendered(text: note, clozeIndex: index)
                    fullText += "\n\n" + ClozeParser.revealed(text: note)
                }
                cards.append(
                    Card(id: node.id + "#c\(index)", kind: .cloze, nodeID: node.id, front: maskedFront, back: fullText)
                )
            }
            return cards
        }

        /// F-STD-1 back side: child titles as a list in map order, plus the note.
        private func answerText(children: [String], note: String) -> String {
            let childTitles = children.compactMap { map.nodes[$0]?.title.text }
            let list = childTitles.joined(separator: "\n")
            guard !note.isEmpty else { return list }
            return list.isEmpty ? note : list + "\n\n" + note
        }

        // MARK: Summaries

        private func summaryCard(_ summary: Summary) -> Card? {
            guard summary.range.count >= 2,
                let first = summary.range.first,
                let last = summary.range.last,
                let summaryNode = map.nodes[summary.node],
                summaryNode.study?.card != .off,
                let parent = map.nodes[summary.parent],
                let firstIndex = parent.children.firstIndex(of: first),
                let lastIndex = parent.children.firstIndex(of: last),
                firstIndex <= lastIndex
            else { return nil }
            let prompt = parent.children[firstIndex...lastIndex]
                .compactMap { map.nodes[$0]?.title.text }
                .joined(separator: "\n")
            return Card(
                id: summary.id,
                kind: .summary,
                nodeID: summary.node,
                front: prompt,
                back: summaryNode.title.text
            )
        }
    }
}
