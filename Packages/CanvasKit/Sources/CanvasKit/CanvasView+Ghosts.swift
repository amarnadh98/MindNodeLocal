import AppKit
import CoreGraphics

/// The F-AI-2 ghost-suggestion surface of the canvas (see
/// `GhostOverlay`): the presentation property, hit-testing and the
/// click hand-off. Split out of the main class body to keep both
/// reviewable.
extension CanvasView {
    /// F-AI-2 ghost suggestions: AI-proposed children rendered as a
    /// dashed, 50%-opacity overlay — never model nodes until accepted.
    /// Set by the host; the overlay rebuilds in place and follows the
    /// camera like real nodes.
    public var ghosts: GhostPresentation? {
        get { ghostStorage }
        set {
            guard newValue?.fingerprint != ghostStorage?.fingerprint else { return }
            ghostStorage = newValue
            ghostOverlay.update(
                newValue, camera: camera, backingScale: backingScale,
                measurer: SceneRenderer.sharedMeasurer)
            needsDisplay = true
        }
    }

    /// The ghost suggestion under `point` (view coordinates), or nil.
    /// Checked before real-node hit-testing, so a click on a ghost
    /// accepts that one suggestion instead of selecting underneath.
    public func ghostID(at point: CGPoint) -> String? {
        ghostOverlay.ghostID(at: camera.modelPoint(for: point))
    }

    /// True while ghost suggestions are presented (F-AI-2): the host's
    /// ⇥ (accept all), Esc (dismiss) and click (accept one) handling
    /// keys off this.
    public var isPresentingGhosts: Bool {
        ghostOverlay.isPresented
    }
}
