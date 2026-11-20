import AppKit
import CanvasKit
import MapCore

extension DocumentWindowController {
    // MARK: drag drop (F-EDT-5)

    /// A finished canvas drag hands over exactly one command: performed
    /// through the store it is one undo step, and the selection stays on
    /// the moved nodes. A nil command (cancelled drag, no-op drop, or
    /// the connection TODO in CanvasView+Drag.swift) changes nothing.
    func performDragDrop(_ command: MapCommand?, selection: Set<String>) {
        guard let command else { return }
        perform(command) { _ in selection }
    }
}
