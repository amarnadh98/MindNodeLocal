import AppKit
import MapAI
import MapCore
import SwiftUI

/// F-AI-3's "Generate Map From…" sheet (SwiftUI, hosted per SPEC §11.1):
/// topic/prompt, pasted text, a PDF (extracted locally), or a URL
/// (fetched only with a cloud provider or an explicit confirm —
/// SPEC §12). The image tab is deliberately absent: no configured
/// provider in this milestone accepts images, so the honest UI hides
/// it instead of offering a dead option (scope note in the PR).
struct GenerateMapSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case topic = "Topic"
        case text = "Text"
        case pdf = "PDF"
        case url = "URL"

        var id: String { rawValue }
    }

    let controller: AIController

    @State private var mode: Mode = .topic
    @State private var topic = ""
    @State private var pastedText = ""
    @State private var pdfURL: URL?
    @State private var urlString = ""
    @State private var insertUnderSelection = false
    @State private var generating = false
    @State private var failureText: String?

    private var canGenerate: Bool {
        guard !generating else { return false }
        switch mode {
        case .topic:
            return !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .text:
            return !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .pdf:
            return pdfURL != nil
        case .url:
            return URL(string: urlString.trimmingCharacters(in: .whitespaces)) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate Map From…")
                .font(.headline)
            Picker("Source", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch mode {
                case .topic:
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Topic or prompt", text: $topic)
                        Text("Creates a new map: a central topic with two levels of branches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .text:
                    ScrollView {
                        TextEditor(text: $pastedText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 160)
                    }
                case .pdf:
                    HStack {
                        Button("Choose PDF…") { choosePDF() }
                        Text(pdfURL?.lastPathComponent ?? "No file selected")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                case .url:
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("https://…", text: $urlString)
                        Text(
                            controller.resolveProvider()?.descriptor.isCloud == true
                                ? "The page is fetched, then summarized into a map."
                                : "Fetching needs your confirmation, then a cloud provider builds the map."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle(
                "Insert under the selected node instead of a new document",
                isOn: $insertUnderSelection)

            if let failureText {
                Label(failureText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                if generating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Generate") { Task { await generate() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGenerate)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            pdfURL = panel.url
        }
    }

    private func generate() async {
        generating = true
        failureText = nil
        defer { generating = false }

        let source: GenerationSource
        do {
            source = try await resolveSource()
        } catch let error as AIError {
            failureText = AIController.friendlyMessage(for: error)
            return
        } catch {
            failureText = "Could not read the source."
            return
        }

        do {
            let insertUnder =
                insertUnderSelection && controller.host?.canvas.selection.count == 1
                ? controller.host?.canvas.selection.first : nil
            let command = try await controller.generateMapCommand(
                source: source, insertUnder: insertUnder)
            if let insertUnder, let document = controller.host?.document as? MapDocument {
                try document.store.perform(command, author: .ai)
                if let host = controller.host {
                    host.canvas.ghosts = nil
                    host.canvas.setSelection([insertUnder])
                    host.canvas.scrollSelectionIntoView()
                }
            } else {
                controller.deliverGeneratedMap(command: command)
            }
            dismiss()
        } catch let error as AIError {
            failureText = AIController.friendlyMessage(for: error)
        } catch {
            failureText = "Generation failed."
        }
    }

    private func resolveSource() async throws -> GenerationSource {
        switch mode {
        case .topic:
            return .topic(topic)
        case .text:
            return .text(pastedText)
        case .pdf:
            guard let pdfURL else {
                throw AIError.invalidResponse("no PDF selected")
            }
            return .text(try GenerationInput.pdfText(at: pdfURL))
        case .url:
            guard
                let url = URL(
                    string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                throw AIError.invalidResponse("not a valid http(s) URL")
            }
            // SPEC §12: the fetch itself is network. A cloud provider's
            // consent sheet covers it; otherwise ask explicitly.
            if controller.resolveProvider()?.descriptor.isCloud != true {
                let granted = await confirmLocalFetch(url: url)
                guard granted else {
                    throw AIError.consentRequired(
                        AIProviderDescriptor(
                            kind: .openAICompatible, displayName: "network", isCloud: true))
                }
            }
            return .text(try await GenerationInput.fetchText(from: url))
        }
    }

    private func confirmLocalFetch(url: URL) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Fetch this URL?"
        alert.informativeText = "Arbor will download \(url.host ?? url.absoluteString) now. Nothing else is sent."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Fetch")
        guard let window = controller.host?.window else {
            return alert.runModal() == .alertSecondButtonReturn
        }
        return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
    }
}

/// Presents the F-AI-3 sheet on a document window.
@MainActor
enum GenerateMapSheetPresenter {
    static func present(on controller: AIController) {
        guard let window = controller.host?.window else { return }
        let hosting = NSHostingController(rootView: GenerateMapSheet(controller: controller))
        hosting.sizingOptions = []
        window.contentViewController?.presentAsSheet(hosting)
    }
}
