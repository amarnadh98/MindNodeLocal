import AppKit
import CoreGraphics
import MapCore
import UniformTypeIdentifiers

/// Finder/app drops on the canvas (SPEC §6.2 "Drop from Finder or
/// other apps"): image files become node images (F-CNT-2), anything
/// else becomes an attachment (F-CNT-7) — on a node when the drop
/// landed on one, as a new image/attachment node on empty canvas.
/// The view only routes: the host's closure owns every model change
/// (SPEC §11.3).
extension CanvasView {
    /// The pasteboard flavors the canvas accepts. Called by the host
    /// (App-side wiring) so this file needs no `CanvasView.swift`
    /// budget.
    public func registerFileDrop() {
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    /// True when the dragging session carries files the canvas can
    /// use (URLs of any kind, or raw image bytes).
    private func usableFiles(on pasteboard: NSPasteboard) -> Bool {
        if pasteboard.types?.contains(.fileURL) == true {
            return true
        }
        return pasteboard.types?.contains(where: { $0 == .png || $0 == .tiff }) == true
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isEditing, usableFiles(on: sender.draggingPasteboard) else { return [] }
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isEditing, usableFiles(on: sender.draggingPasteboard) else { return [] }
        // Hover feedback: the node under the drop lights up like a
        // reparent hover (the host's insertion-line machinery is for
        // node drags; a simple highlight reads fine here).
        let point = convert(sender.draggingLocation, from: nil)
        if let id = nodeID(at: point), selection != [id] {
            setSelection([id])
            syncSelectionRings()
        }
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        // The hover highlight was transient; leave the selection be.
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isEditing else { return false }
        let pasteboard = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        let target = nodeID(at: point)

        var urls: [URL] = []
        if let items = pasteboard.pasteboardItems?.first {
            if let data = items.data(forType: .png), let url = Self.writeTemporary(data, ext: "png") {
                urls = [url]
            } else if let data = items.data(forType: .tiff),
                let url = Self.writeTemporary(data, ext: "tiff")
            {
                urls = [url]
            } else {
                for item in pasteboard.pasteboardItems ?? [] {
                    if let data = item.data(forType: .fileURL),
                        let url = URL(dataRepresentation: data, relativeTo: nil)
                    {
                        urls.append(url)
                    }
                }
            }
        }
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls, target)
        return true
    }

    /// Raw image bytes from a drag land in a temp file so the host's
    /// file-based import path (downscale + content-addressed store)
    /// treats them uniformly.
    private static func writeTemporary(_ data: Data, ext: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-drop-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }
}
