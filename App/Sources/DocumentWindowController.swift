import AppKit
import CanvasKit
import MapCore
import MapRender

@MainActor
final class DocumentWindowController: NSWindowController {
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

    init(document: NSDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = document.displayName
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = canvas
        super.init(window: window)
        self.document = document

        if let mapDocument = document as? MapDocument {
            updateScene(from: mapDocument)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        rebuildScene()
    }

    /// Rebuilds and displays the canvas scene from the document's model,
    /// then fits it into the viewport.
    func rebuildScene() {
        guard let mapDocument = document as? MapDocument,
            let contentFrame = window?.contentRect(forFrameRect: window?.frame ?? .zero)
        else {
            return
        }
        canvas.frame = NSRect(origin: .zero, size: contentFrame.size)
        updateScene(from: mapDocument)
    }

    private func updateScene(from document: MapDocument) {
        let variant: ThemeVariant = document.effectiveAppearance == .dark ? .dark : .light
        let scene = SceneGeometry.build(
            model: document.model,
            variant: variant,
            measurer: SceneRenderer.sharedMeasurer)
        canvas.scene = scene
        canvas.zoomToFit()
    }
}
