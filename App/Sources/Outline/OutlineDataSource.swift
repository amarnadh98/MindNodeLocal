import AppKit
import CanvasKit
import MapCore

/// The `NSOutlineView` datasource + delegate (F-OUT-2/4/6). Items are
/// node ids (`String`); roots are the model's root list in creation
/// order, and a root's children follow the map's clockwise visual
/// order (`OutlineModel.displayedChildren`, sides resolved from the
/// live scene). Every mutation routes through the controller, which
/// performs one `MapCommand` through the document's `MapStore`.
@MainActor
final class OutlineDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let rowType = NSPasteboard.PasteboardType("com.arbor.outline.row")

    weak var controller: OutlineViewController?

    private var model: MapModel? { controller?.model }
    private var outlineView: NSOutlineView? { controller?.outlineView }

    // MARK: tree structure

    func outlineView(
        _ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?
    ) -> Int {
        guard let controller else { return 0 }
        guard let parentID = item as? String else { return model?.roots.count ?? 0 }
        guard let parent = model?.nodes[parentID] else { return 0 }
        // Folded children are simply absent from the outline: the
        // datasource only ever reports them for an expanded (unfolded)
        // row, mirroring `node.folded` as the single truth.
        return parent.folded ? 0 : displayedChildren(of: parentID, in: controller).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let controller else { return "" }
        guard let parentID = item as? String else { return model?.roots[index] ?? "" }
        return displayedChildren(of: parentID, in: controller)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let id = item as? String else { return false }
        return !(model?.nodes[id]?.children.isEmpty ?? true)
    }

    private func displayedChildren(of parentID: String, in controller: OutlineViewController) -> [String] {
        guard let model else { return [] }
        return OutlineModel.displayedChildren(of: parentID, in: model, sideOf: controller.sideOf)
    }

    // MARK: row views (F-OUT-2)

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let id = item as? String, let node = model?.nodes[id] else { return nil }
        let cell =
            (outlineView.makeView(withIdentifier: OutlineRowCellView.cellIdentifier, owner: self)
                as? OutlineRowCellView)
            ?? OutlineRowCellView(frame: .zero)
        cell.identifier = OutlineRowCellView.cellIdentifier
        cell.configure(node: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let controller, let id = item as? String, model?.nodes[id] != nil else { return nil }
        let rowView = OutlineRowView(frame: .zero)
        rowView.depth = controller.depth(of: id)
        return rowView
    }

    // MARK: forwarded view notifications

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let id = notification.userInfo?["NSObject"] as? String {
            controller?.outlineViewItemDidChange(expanded: true, id: id)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let id = notification.userInfo?["NSObject"] as? String {
            controller?.outlineViewItemDidChange(expanded: false, id: id)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        controller?.outlineViewSelectionDidChange()
    }

    // MARK: drag & drop (F-OUT-4)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let id = item as? String else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(id, forType: Self.rowType)
        return writer
    }

    /// The drop is validated against the pure builder
    /// (`OutlineCommands.dropCommand`): on the row = becomes its last
    /// child (depth + 1, the horizontal offset meaning of F-OUT-4);
    /// on a gap between rows = the sibling directly below the row
    /// above the gap (vertical reorder / new depth via the gap's
    /// level). The gap above a group's first child reads as on-item.
    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let controller, let dragged = draggedID(from: info) else { return [] }
        if index == NSOutlineViewDropOnItemIndex {
            guard let target = item as? String else { return [] }
            return dropIsPossible(dragged: dragged, target: target) ? .move : []
        }
        // A gap: the row above it owns the "sibling below" landing.
        if let parentID = item as? String {
            guard let parent = model?.nodes[parentID], !parent.folded, index > 0 else { return [] }
            let children = displayedChildren(of: parentID, in: controller)
            guard children.indices.contains(index - 1) else { return [] }
            return dropIsPossible(dragged: dragged, target: children[index - 1]) ? .move : []
        }
        // A gap among the root sections.
        guard index > 0, let roots = model?.roots, roots.indices.contains(index - 1) else { return [] }
        return dropIsPossible(dragged: dragged, target: roots[index - 1]) ? .move : []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let controller, let model, let dragged = draggedID(from: info) else { return false }
        let asChild: Bool
        let target: String?
        if index == NSOutlineViewDropOnItemIndex {
            asChild = true
            target = item as? String
        } else if let parentID = item as? String {
            asChild = false
            let children = displayedChildren(of: parentID, in: controller)
            guard children.indices.contains(index - 1) else { return false }
            target = children[index - 1]
        } else {
            asChild = false
            let roots = model.roots
            guard roots.indices.contains(index - 1) else { return false }
            target = roots[index - 1]
        }
        guard let target,
            dropIsPossible(dragged: dragged, target: target),
            let action = OutlineCommands.dropCommand(
                dragged: dragged, target: target, asChild: asChild, in: model, sideOf: controller.sideOf)
        else { return false }
        controller.perform(action)
        return true
    }

    private func draggedID(from info: NSDraggingInfo) -> String? {
        let pasteboard = info.draggingPasteboard
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        return item.string(forType: Self.rowType)
    }

    /// The dragged row can land on `target` unless the target is the
    /// row itself or inside its own subtree (F-OUT-4).
    private func dropIsPossible(dragged: String, target: String) -> Bool {
        guard let model else { return false }
        return dragged != target
            && !OutlineModel.descendantIDs(of: [dragged], in: model).contains(target)
    }
}
