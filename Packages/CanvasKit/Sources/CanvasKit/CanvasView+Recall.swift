import AppKit

extension CanvasView {
    // MARK: M7 (F-STD-5): the recall overlay — the same overlay API
    // the presentation surface drives, exposed for the App layer's
    /// recall session (the layer tree itself stays CanvasKit-internal).

    /// Installs, updates or clears the reveal overlay on the layer
    /// tree (SPEC §10: the renderer reads a `RevealState` overlay).
    /// Presentation slides use this through `PresentationView`; recall
    /// uses it on the live document canvas.
    public func setRevealOverlay(_ overlay: RevealOverlay?) {
        layerTree.setRevealOverlay(overlay)
    }

    /// Runs one reveal batch's build animation (§7.6: fade + 8 pt slide
    /// from the parent, 250 ms, staggered; instant under Reduce Motion).
    public func revealNodes(_ ids: [String], reduceMotion: Bool) {
        layerTree.revealNodes(ids, camera: camera, reduceMotion: reduceMotion)
    }
}
