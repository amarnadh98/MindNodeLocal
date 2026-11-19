import AppKit
import MapCore

/// F-CAN-4 / F-CAN-7 wiring: arrow-key and menu navigation over the
/// current scene. The navigation semantics themselves are
/// `SpatialNavigator` (pure); this extension is the view-side glue —
/// which node a multi-selection departs from, how the selection updates,
/// and the camera follow.
///
/// Plain arrows have no menu key equivalents on purpose: AppKit treats
/// unmodified arrow equivalents as menu-tracking keys, so a menu item
/// with a bare arrow equivalent would misbehave in open menus. The moves
/// are still reachable as Select menu items (§14.1); the keys themselves
/// stay `keyDown`-only, documented here and in the PR.
extension CanvasView {
    // MARK: Select menu actions (§6.1 Select)

    @objc public func navigateUpAction(_ sender: Any?) {
        navigate(.up, extending: false)
    }

    @objc public func navigateDownAction(_ sender: Any?) {
        navigate(.down, extending: false)
    }

    @objc public func navigateLeftAction(_ sender: Any?) {
        navigate(.left, extending: false)
    }

    @objc public func navigateRightAction(_ sender: Any?) {
        navigate(.right, extending: false)
    }

    @objc public func extendUpAction(_ sender: Any?) {
        navigate(.up, extending: true)
    }

    @objc public func extendDownAction(_ sender: Any?) {
        navigate(.down, extending: true)
    }

    @objc public func extendLeftAction(_ sender: Any?) {
        navigate(.left, extending: true)
    }

    @objc public func extendRightAction(_ sender: Any?) {
        navigate(.right, extending: true)
    }

    /// ⌃⌥N / ⌃⌥P: the next / previous root of the selected tree — works
    /// from any node inside it; with nothing selected the step starts at
    /// the first root. No-op at the ends.
    @objc public func nextRootAction(_ sender: Any?) {
        stepRoot(forwards: true)
    }

    @objc public func previousRootAction(_ sender: Any?) {
        stepRoot(forwards: false)
    }

    private func stepRoot(forwards: Bool) {
        guard !isEditing, let model = dragModel else { return }
        guard let anchor = selection.min() ?? model.roots.first else { return }
        let target =
            forwards
            ? SpatialNavigator.nextRoot(after: anchor, model: model)
            : SpatialNavigator.previousRoot(before: anchor, model: model)
        guard let target else { return }
        setSelection([target])
        scrollSelectionIntoView()
    }

    /// ⌘J (F-CAN-7): jump to the selection — the camera centers on it,
    /// scale untouched, even when it was already on screen.
    @objc public func jumpToSelectionAction(_ sender: Any?) {
        guard !isEditing, let scene, let frame = selectionFrame(scene) else { return }
        camera = Camera(
            origin: CGPoint(
                x: frame.midX - bounds.midX / camera.scale,
                y: frame.midY - bounds.midY / camera.scale),
            scale: camera.scale)
    }

    // MARK: the shared navigation step

    /// One arrow-key step: the target replaces the selection, or joins
    /// it when extending (⇧). Afterwards the camera follows with
    /// `SpatialNavigator.scrollIntoView`'s 40 pt margin (F-CAN-7);
    /// already-visible frames leave the camera untouched, so stepping
    /// within the viewport never jitters. Editing sessions own the keys
    /// (the overlay's text view is first responder), and a defensive
    /// `isEditing` guard keeps menu-triggered moves from stealing them.
    public func navigate(_ direction: Direction, extending: Bool) {
        guard !isEditing, let scene, let model = dragModel else { return }
        guard let anchor = navigationAnchor(direction) else { return }
        let updated: Set<String>
        if extending {
            updated = SpatialNavigator.extendSelection(
                selection, from: anchor, direction: direction, scene: scene, model: model)
            guard updated != selection else { return }
        } else {
            guard
                let target = SpatialNavigator.target(
                    from: anchor, direction: direction, scene: scene, model: model)
            else { return }
            updated = [target]
        }
        setSelection(updated)
        scrollSelectionIntoView()
    }

    /// The node a step in `direction` departs from: with a
    /// multi-selection, the member furthest along the pressed axis — so ↓
    /// continues past the bottom-most selected node and ⇧↓ grows the band
    /// downward. Ties break on the smaller id for determinism.
    func navigationAnchor(_ direction: Direction) -> String? {
        guard let scene, !selection.isEmpty else { return nil }
        var best: (id: String, value: CGFloat)?
        for id in selection {
            guard let frame = scene.nodes[id]?.frame else { continue }
            let value: CGFloat
            switch direction {
            case .up: value = frame.minY
            case .down: value = frame.maxY
            case .left: value = frame.minX
            case .right: value = frame.maxX
            }
            let closer =
                best == nil
                || (direction == .up || direction == .left
                    ? value < best!.value || (value == best!.value && id < best!.id)
                    : value > best!.value || (value == best!.value && id < best!.id))
            if closer {
                best = (id, value)
            }
        }
        return best?.id
    }

    /// The minimal camera move that brings the whole selection into view
    /// (F-CAN-7's 40 pt margin); a no-op when it already is. Public so
    /// the host can follow programmatic selection changes (paste).
    public func scrollSelectionIntoView(margin: CGFloat = 40) {
        guard let scene, let frame = selectionFrame(scene) else { return }
        camera = SpatialNavigator.scrollIntoView(
            camera: camera, viewport: bounds.size, frame: frame, margin: margin)
    }

    /// The union frame of the selection, or nil when nothing selected
    /// (or the ids all fell out of the scene).
    private func selectionFrame(_ scene: CanvasScene) -> CGRect? {
        var frame: CGRect = .null
        for id in selection {
            if let node = scene.nodes[id] {
                frame = frame.union(node.frame)
            }
        }
        return frame.isNull ? nil : frame
    }
}
