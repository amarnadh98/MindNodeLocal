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

        canvas.onEffectiveAppearanceChange = { [weak self] in
            self?.updateScene(preserveCamera: true)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        updateScene(preserveCamera: false)
    }

    /// Rebuilds the scene from the document's model at the view's
    /// effective appearance. The document's explicit override wins; `auto`
    /// follows the system (and re-renders when it changes).
    func updateScene(preserveCamera: Bool) {
        guard let mapDocument = document as? MapDocument else { return }
        let variant: ThemeVariant
        switch mapDocument.model.appearance {
        case .dark:
            variant = .dark
        case .light:
            variant = .light
        case .auto, .none:
            variant = canvas.effectiveVariant
        }
        let previousCamera = canvas.camera
        let scene = SceneGeometry.build(
            model: mapDocument.model,
            variant: variant,
            measurer: SceneRenderer.sharedMeasurer)
        canvas.scene = scene
        if preserveCamera {
            canvas.camera = previousCamera
        } else {
            canvas.zoomToFit()
        }
    }
}
