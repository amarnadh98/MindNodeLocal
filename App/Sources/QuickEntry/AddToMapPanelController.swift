import AppKit
import MapCore
import os

/// The **Add to…** picker (F-QEN-2): stage one lists recent Arbor maps,
/// stage two lists the chosen map's nodes (depth-indented, searchable).
/// Committing hands `(url, nodeID)` back to the Quick Entry panel, which
/// appends the outline as that node's last children through the target
/// document's store.
@MainActor
final class AddToMapPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// The commit: the chosen map and the node to append under.
    var onCommit: ((URL, String) -> Void)?

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false)
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let headerLabel = NSTextField(labelWithString: "Add to a recent map")
    private let chooseButton = NSButton(title: "Choose", target: nil, action: nil)
    private let pickerLog = Logger(subsystem: "arbor", category: "addto")

    /// Stage state: the candidate list being browsed.
    private var candidates: [Candidate] = []
    /// The unfiltered candidate list the search narrows.
    private var allCandidates: [Candidate] = []
    private struct Candidate {
        let id: String
        let title: String
        let depth: Int
        let url: URL?
    }

    override init() {
        super.init()
        panel.title = "Add To"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        column.title = "Node"
        column.width = 380
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(chooseAction(_:))
        table.target = self
        table.allowsEmptySelection = false

        searchField.placeholderString = "Search nodes"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.action = #selector(searchChanged(_:))
        searchField.target = self

        chooseButton.bezelStyle = .push
        chooseButton.action = #selector(chooseAction(_:))
        chooseButton.target = self
        chooseButton.keyEquivalent = "\r"
        chooseButton.isEnabled = false
        chooseButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(
            title: "Cancel", target: self, action: #selector(cancelAction(_:)))
        cancelButton.bezelStyle = .recessed
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
        content.addSubview(headerLabel)
        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(cancelButton)
        content.addSubview(chooseButton)
        panel.contentView = content

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            cancelButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            chooseButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            chooseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -10),
        ])

        loadRecents()
        searchField.isHidden = candidates.isEmpty
    }

    // MARK: presentation

    /// Shows the picker centered, first row preselected.
    func show(attachedTo parent: NSWindow?) {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        if !candidates.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            chooseButton.isEnabled = true
        }
    }

    func close() {
        panel.orderOut(nil)
    }

    // MARK: data

    /// Stage one: the document controller's recents, filtered to files
    /// that still exist.
    private func loadRecents() {
        let recents =
            (NSDocumentController.shared.recentDocumentURLs ?? []).filter {
                $0.pathExtension == AppIdentity.documentExtension
                    && FileManager.default.fileExists(atPath: $0.path)
            }
        candidates = recents.prefix(20).map { url in
            Candidate(
                id: url.path, title: url.lastPathComponent, depth: 0, url: url)
        }
        allCandidates = candidates
        table.reloadData()
    }

    /// Stage two: the chosen map's nodes, in document order, depth from
    /// the root. Folding is ignored — every node is appendable.
    private func loadNodes(of url: URL) {
        do {
            let contents = try ArborPackage.read(at: url)
            var nodes: [Candidate] = []
            var stack: [(id: String, depth: Int)] = []
            for rootID in contents.model.roots {
                stack.append((rootID, 0))
            }
            while let (id, depth) = stack.popLast() {
                guard let node = contents.model.nodes[id] else { continue }
                nodes.append(
                    Candidate(id: id, title: node.title.text, depth: depth, url: url))
                for childID in node.children.reversed() {
                    stack.append((childID, depth + 1))
                }
            }
            candidates = nodes
            allCandidates = nodes
            headerLabel.stringValue = url.lastPathComponent
            searchField.isHidden = false
            table.reloadData()
        } catch {
            pickerLog.error("Add-to map read failed: \(String(describing: error))")
            panel.orderOut(nil)
        }
    }

    /// The search filter narrows the current stage's list; clearing the
    /// field restores it.
    @objc private func searchChanged(_ sender: Any?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        candidates =
            query.isEmpty
            ? allCandidates
            : allCandidates.filter { $0.title.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if !candidates.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: actions

    @objc private func chooseAction(_ sender: Any?) {
        guard let row = table.selectedRowIndexes.first, candidates.indices.contains(row) else {
            return
        }
        let candidate = candidates[row]
        if let url = candidate.url, candidate.id == url.path {
            // Stage one → stage two: browse the picked map's nodes.
            loadNodes(of: url)
            searchField.stringValue = ""
            if !candidates.isEmpty {
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                chooseButton.isEnabled = true
            }
            return
        }
        guard let url = candidate.url else { return }
        close()
        onCommit?(url, candidate.id)
    }

    @objc private func cancelAction(_ sender: Any?) {
        close()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        candidates.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard candidates.indices.contains(row) else { return nil }
        let candidate = candidates[row]
        return String(repeating: "    ", count: candidate.depth) + candidate.title
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        chooseButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}
