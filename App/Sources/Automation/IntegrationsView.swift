import AppKit
import Foundation
import MapAutomation
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Integrations (F-INT-4/6, SPEC §5.20): the MCP edit toggle,
/// "Copy config for Claude Desktop / Claude Code" buttons, and the inbox
/// document for the Services menu. Hosted in the Settings window's
/// Integrations tab (SPEC §11.1: SwiftUI only where hosted).
@MainActor
final class IntegrationsModel: ObservableObject {
    @Published var allowEdits: Bool {
        didSet {
            guard oldValue != allowEdits else { return }
            AutomationSettings.setMCPEditsAllowed(allowEdits)
        }
    }
    @Published var inboxName: String?

    init() {
        allowEdits = AutomationSettings.mcpEditsAllowed
        inboxName = AutomationSettings.inboxURL()?.lastPathComponent
    }

    var helperPath: String {
        AutomationSettings.helperPath
    }

    var socketPath: String {
        AutomationPaths.appSocketURL().path
    }

    func copyClaudeDesktopConfig() {
        copyToPasteboard(AutomationSettings.claudeDesktopConfig())
    }

    func copyClaudeCodeCommand() {
        copyToPasteboard(AutomationSettings.claudeCodeCommand())
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func chooseInbox() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: AppIdentity.documentExtension) ?? .data]
        panel.message = "Choose the document the Inbox service appends to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AutomationSettings.setInbox(url: url)
        inboxName = url.lastPathComponent
    }

    func clearInbox() {
        AutomationSettings.clearInbox()
        inboxName = nil
    }
}

struct IntegrationsView: View {
    @ObservedObject var model: IntegrationsModel

    var body: some View {
        Form {
            Section("Local MCP server") {
                HStack {
                    Toggle("Allow MCP edits", isOn: $model.allowEdits)
                    Spacer()
                    Text(model.allowEdits ? "Read-write" : "Read-only")
                        .foregroundStyle(.secondary)
                }
                Text(
                    "The bundled \((model.helperPath as NSString).lastPathComponent) helper speaks MCP over stdio. "
                        + "Read-only by default; with the toggle on, Claude can add and edit nodes through "
                        + "the same command layer as the app (marked \"mcp\")."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Copy config for Claude Desktop…") { model.copyClaudeDesktopConfig() }
                    Button("Copy config for Claude Code…") { model.copyClaudeCodeCommand() }
                }
                LabeledContent("Socket") {
                    Text(model.socketPath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Read-only?") {
                    Text(model.allowEdits ? "no — edits enabled" : "yes")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Inbox document") {
                HStack {
                    Text(model.inboxName ?? "None selected")
                        .foregroundStyle(model.inboxName == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { model.chooseInbox() }
                    Button("Clear") { model.clearInbox() }
                        .disabled(model.inboxName == nil)
                }
                Text(
                    "\"Add Selection to Arbor Inbox\" appends the selected text under an Inbox node in this document."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
