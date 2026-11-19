import AppKit
import MapLibrary
import SwiftUI

/// The Concept Index (F-LIB-4): every node title across the library,
/// grouped by normalized text, with "Link these" creating `x-arbor://`
/// deep links between the occurrences of one concept.
struct ConceptIndexView: View {
    @EnvironmentObject private var model: LibraryModel

    private var shownGroups: [ConceptGroup] {
        model.conceptGroups
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter concepts", text: $model.conceptSearch)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .accessibilityLabel("Filter concepts")
            if shownGroups.isEmpty {
                Spacer()
                Text("Index your maps, then every node title shows up here grouped by concept.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(Array(shownGroups.enumerated()), id: \.offset) { _, group in
                        ConceptGroupRow(group: group)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onChange(of: model.conceptSearch) { _, _ in
            Task { await model.reload() }
        }
    }
}

/// One concept group: the normalized title, its occurrences across
/// maps, and the "Link these" action.
private struct ConceptGroupRow: View {
    @EnvironmentObject private var model: LibraryModel
    let group: ConceptGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(group.occurrences.first?.title ?? group.normalizedTitle)
                    .font(.headline)
                if group.documentCount > 1 {
                    Text("\(group.occurrences.count) in \(group.documentCount) maps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if group.occurrences.count > 1 {
                    Button("Link these") {
                        model.linkConcepts(in: group)
                    }
                    .buttonStyle(.bordered)
                    .help(
                        "Adds an x-arbor link to the other occurrences' nodes in their open maps; closed maps are never written"
                    )
                    .accessibilityLabel("Link these \(group.normalizedTitle) occurrences")
                }
            }
            ForEach(Array(group.occurrences.enumerated()), id: \.offset) { _, occurrence in
                Text("\(occurrence.documentTitle) › \(occurrence.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
