import Foundation

// Shared helpers of the apply dispatcher — structural bookkeeping shared
// with the inverse dispatcher, split out to keep the wide switches the
// only thing `MapCommand+Apply.swift` contains.
extension MapCommand {
    /// Strips every connection, boundary and summary that references a
    /// removed node, so the model stays structurally valid after a delete.
    /// The delete commands' inverses restore the pre-delete lists wholesale.
    func purgeSecondaryReferences(to removed: Set<String>, in model: inout MapModel) {
        guard !removed.isEmpty else { return }
        let connections = (model.connections ?? []).filter { connection in
            !removed.contains(connection.from) && !removed.contains(connection.to)
        }
        model.connections = connections.isEmpty ? nil : connections

        var boundaries: [Boundary] = []
        for boundary in model.boundaries ?? [] {
            let nodes = boundary.nodes.filter { !removed.contains($0) }
            if nodes.isEmpty { continue }
            if nodes.count == boundary.nodes.count {
                boundaries.append(boundary)
            } else {
                boundaries.append(Boundary(id: boundary.id, nodes: nodes, title: boundary.title, style: boundary.style))
            }
        }
        model.boundaries = boundaries.isEmpty ? nil : boundaries

        let summaries = (model.summaries ?? []).filter { summary in
            !removed.contains(summary.node) && !removed.contains(summary.parent)
                && !summary.range.contains { removed.contains($0) }
        }
        model.summaries = summaries.isEmpty ? nil : summaries
    }

    /// Drops summaries whose range is no longer a run of the summary
    /// parent's children (moves, promotions, demotions and detachments can
    /// break them). The move commands' inverses restore the pre-move list.
    func purgeStaleSummaries(in model: inout MapModel) {
        let summaries = (model.summaries ?? []).filter { summary in
            guard let parent = model.nodes[summary.parent] else { return false }
            guard model.nodes[summary.node] != nil else { return false }
            for rangeID in summary.range where !parent.children.contains(rangeID) {
                return false
            }
            return true
        }
        model.summaries = summaries.isEmpty ? nil : summaries
    }
}
