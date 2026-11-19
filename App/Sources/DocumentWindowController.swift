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
        // Note: addWindowController(_:) assigns .document, so this init
        // must not set it first — assigning it here makes AppKit's insert
        // a no-op and the document ends up with zero window controllers.
        super.init(window: window)

        canvas.onEffectiveAppearanceChange = { [weak self] in
            self?.updateScene(preserveCamera: true)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The document is only wired up after `addWindowController` returns,
    /// and the window reaches its real content size once shown — so the
    /// first scene build and fit run here, not in `init`.
    override func showWindow(_ sender: Any?) {
        if canvas.scene == nil {
            updateScene(preserveCamera: false)
        }
        super.showWindow(sender)
        if canvas.needsInitialFit {
            canvas.zoomToFit()
            canvas.needsInitialFit = false
        }
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
