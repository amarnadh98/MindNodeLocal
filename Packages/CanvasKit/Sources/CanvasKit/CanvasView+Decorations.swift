import AppKit
import CoreGraphics
import MapCore
import MapRender
import MapStudy

/// One interactive region of a node's decorations, in view space.
public enum DecorationHit: Equatable, Sendable {
    /// The task checkbox (F-TSK-1): click toggles done.
    case checkbox(id: String)
    /// The progress ring (F-TSK-2): click completes all leaf tasks,
    /// ⌥-click reopens all.
    case progressRing(id: String)
    /// The note badge (F-CNT-1): click opens the note popover.
    case noteBadge(id: String)
    /// The link badge (F-CNT-4): click opens the link.
    case linkBadge(id: String)
    /// One marker glyph (F-CNT-3): a priority/progress click cycles it.
    case marker(id: String, token: String)
    /// The citation chip (F-CNT-8): click opens the source URL.
    case sourceBadge(id: String)
    /// The attachment badge (F-CNT-7): double-click Quick Looks.
    case attachmentBadge(id: String)
    /// The image's resize corner (F-CNT-2): drag resizes, ⌥ unlocks
    /// the aspect.
    case imageResize(id: String)
}

/// F-TAG-2 / F-TSK-5 highlight mode: pure view state (never a model
/// mutation, never undoable). Non-matching nodes dim to 25%; Esc
/// exits.
public enum HighlightMode: Equatable, Sendable {
    /// Only nodes carrying one of these tags stay lit.
    case tags(Set<String>)
    /// Only task nodes stay lit.
    case tasks
    /// F-TAG-3 dim mode: only ids matching the filter stay lit (the
    /// engine owns the evaluation).
    case filter(NodeFilter)
}

/// The decorations surface of the canvas (M3): hit-testing the
/// checkbox / progress ring / note / link regions the shared renderer
/// drew (same `NodeDecorationLayout`), hover tooltips for the ring
/// and the note preview, and the highlight-mode dimming. All mutations
/// route to the host's closures — the view never touches the model
/// (SPEC §11.3).
extension CanvasView {
    /// Click on a checkbox: toggles the task's done state (one
    /// `setTaskDone` via the host).
    public var onToggleTaskDone: ((String) -> Void)? {
        get { decorationActions.onToggleTaskDone }
        set { decorationActions.onToggleTaskDone = newValue }
    }

    /// Click on a progress ring: `done` follows the ⌥ modifier
    /// (⌥ = reopen all, F-TSK-2).
    public var onSetLeafTasksDone: ((String, Bool) -> Void)? {
        get { decorationActions.onSetLeafTasksDone }
        set { decorationActions.onSetLeafTasksDone = newValue }
    }

    /// Click on the note badge: open the note popover (⇧⌘K's action).
    public var onOpenNote: ((String) -> Void)? {
        get { decorationActions.onOpenNote }
        set { decorationActions.onOpenNote = newValue }
    }

    /// Click on the link badge (or ⌥⌘K): open the link (NSWorkspace;
    /// `x-arbor://` routes to the host).
    public var onOpenLink: ((String) -> Void)? {
        get { decorationActions.onOpenLink }
        set { decorationActions.onOpenLink = newValue }
    }

    /// Click on a priority/progress marker (F-CNT-3): the host builds
    /// one `setMarkers` from `MarkerCycler`.
    public var onCycleMarker: ((String) -> Void)? {
        get { decorationActions.onCycleMarker }
        set { decorationActions.onCycleMarker = newValue }
    }

    /// Click on the citation chip (F-CNT-8): the host opens the source
    /// URL (a `t=` video opens at that time).
    public var onOpenSource: ((String) -> Void)? {
        get { decorationActions.onOpenSource }
        set { decorationActions.onOpenSource = newValue }
    }

    /// Double-click on the attachment badge (F-CNT-7): the host runs
    /// Quick Look on the extracted files.
    public var onQuickLookAttachments: ((String) -> Void)? {
        get { decorationActions.onQuickLookAttachments }
        set { decorationActions.onQuickLookAttachments = newValue }
    }

    /// Space on a selected node with an image (F-CNT-2): the host
    /// opens Quick Look of the image.
    public var onQuickLookImage: ((String) -> Void)? {
        get { decorationActions.onQuickLookImage }
        set { decorationActions.onQuickLookImage = newValue }
    }

    /// A finished file drop (CanvasView+Drop): the host performs the
    /// image/attachment commands.
    public var onDropFiles: ((_ urls: [URL], _ nodeID: String?) -> Void)? {
        get { decorationActions.onDropFiles }
        set { decorationActions.onDropFiles = newValue }
    }

    /// The image resize drag's commit (F-CNT-2): the host performs one
    /// `setImage` with the new display size (aspect already handled
    /// here — ⇧/⌥ unlocked it during the drag).
    public var onResizeImage: ((String, CGSize) -> Void)? {
        get { decorationActions.onResizeImage }
        set { decorationActions.onResizeImage = newValue }
    }

    /// F-TAG-2 / F-TSK-5: the active highlight mode (view state).
    public var highlight: HighlightMode? {
        get { decorationActions.highlight }
        set {
            guard decorationActions.highlight != newValue else { return }
            decorationActions.highlight = newValue
            applyScene(animated: false)
            needsDisplay = true
        }
    }

    /// True when a highlight mode dimmed anything — and Esc's job to
    /// clear (returns whether this call exited one). Esc's FIRST job
    /// is cancelling an in-flight image-resize drag (F-CNT-2's view
    /// state — no command was performed, so there is nothing to undo).
    public func exitHighlightIfActive() -> Bool {
        if isResizingImage {
            cancelImageResize()
            return true
        }
        guard highlight != nil else { return false }
        highlight = nil
        return true
    }

    // MARK: hit-testing

    /// The decoration region under a view point, if any. Pure over the
    /// current scene + camera: the same layout the renderer drew.
    public func decorationHit(at viewPoint: CGPoint) -> DecorationHit? {
        guard let scene, let node = nodeID(at: viewPoint).flatMap({ scene.nodes[$0] }),
            let decorations = node.decorations, !decorations.isEmpty
        else { return nil }
        let modelPoint = camera.modelPoint(for: viewPoint)
        let local = CGPoint(
            x: modelPoint.x - node.frame.minX,
            y: modelPoint.y - node.frame.minY)
        let layout = NodeRenderer.decorationLayout(
            style: node.style, decorations: decorations, frame: CGRect(origin: .zero, size: node.frame.size))
        if decorations.task != nil, let rect = layout.leadingRect, rect.contains(local) {
            switch decorations.task {
            case .checkbox:
                return .checkbox(id: node.id)
            case .progress:
                return .progressRing(id: node.id)
            case nil:
                break
            }
        }
        if decorations.hasNote, let rect = layout.noteBadgeRect, rect.contains(local) {
            return .noteBadge(id: node.id)
        }
        if decorations.linkURL != nil, let rect = layout.linkBadgeRect, rect.contains(local) {
            return .linkBadge(id: node.id)
        }
        if let rect = layout.markerRowRect, !decorations.markers.isEmpty,
            local.x >= rect.minX, local.x <= rect.maxX,
            local.y >= rect.minY, local.y <= rect.maxY
        {
            // The glyph under the point: slots are markerSize + gap wide.
            let offset = local.x - rect.minX - NodeDecorationMetrics.markerGap
            guard offset >= 0 else { return nil }
            let slot = Int(offset / (NodeDecorationMetrics.markerSize + NodeDecorationMetrics.markerGap))
            guard slot < decorations.markers.count else { return nil }
            return .marker(id: node.id, token: decorations.markers[slot].token)
        }
        if decorations.source != nil, let rect = layout.sourceBadgeRect, rect.contains(local) {
            return .sourceBadge(id: node.id)
        }
        if decorations.attachmentCount > 0, let rect = layout.attachmentBadgeRect, rect.contains(local) {
            return .attachmentBadge(id: node.id)
        }
        if decorations.image != nil, let rect = layout.imageRect {
            // The resize corner (F-CNT-2): a 12 pt (view-space) square
            // at the image's bottom-right.
            let corner = CGPoint(x: node.frame.minX + rect.maxX, y: node.frame.minY + rect.maxY)
            let reach = 6 / max(camera.scale, 0.01)
            if abs(modelPoint.x - corner.x) <= reach, abs(modelPoint.y - corner.y) <= reach {
                return .imageResize(id: node.id)
            }
        }
        return nil
    }

    /// The hover text for the point: the ring's "7 of 12 · 58%"
    /// (F-TSK-2), the note's 3-line preview (F-CNT-1), the citation
    /// chip's URL/excerpt (F-CNT-8) or the attachment names (F-CNT-7).
    public func decorationHoverText(at viewPoint: CGPoint) -> String? {
        guard let scene, let hit = decorationHit(at: viewPoint) else { return nil }
        switch hit {
        case .progressRing(let id):
            guard let decorations = scene.nodes[id]?.decorations,
                case .progress(let completed, let total)? = decorations.task
            else { return nil }
            return TaskRatio(completed: completed, total: total).tooltip
        case .noteBadge(let id):
            return Self.notePreview(of: id, in: dragModel)
        case .sourceBadge(let id):
            return Self.sourceTooltip(of: id, in: dragModel)
        case .attachmentBadge(let id):
            return Self.attachmentTooltip(of: id, in: dragModel)
        case .marker(let id, let token):
            return Self.markerTooltip(of: id, token: token, in: dragModel)
        case .checkbox, .linkBadge, .imageResize:
            return nil
        }
    }

    /// The note's first three non-empty lines (F-CNT-1's hover
    /// preview). Pure; also the headless test surface.
    public static func notePreview(of id: String, in model: MapModel?) -> String? {
        guard let note = model?.nodes[id]?.note else { return nil }
        let lines = note.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.prefix(3).joined(separator: "\n")
    }

    /// The node's scaled frame in view space — popover/sheet anchor for
    /// the content UI (⇧⌘K note, ⌥⌘T tags).
    public func viewRect(of id: String) -> NSRect? {
        guard let node = scene?.nodes[id] else { return nil }
        let origin = camera.screenPoint(for: node.frame.origin)
        return NSRect(
            origin: origin,
            size: CGSize(
                width: node.frame.width * camera.scale,
                height: node.frame.height * camera.scale))
    }

    // MARK: event routing

    /// Called from `mouseDown` before generic node selection: a
    /// decoration click acts on its node without starting a drag.
    func handleDecorationClick(at viewPoint: CGPoint, with event: NSEvent) -> Bool {
        guard let hit = decorationHit(at: viewPoint) else { return false }
        let optionDown = event.modifierFlags.contains(.option)
        switch hit {
        case .checkbox(let id):
            setSelection([id])
            onToggleTaskDone?(id)
        case .progressRing(let id):
            setSelection([id])
            onSetLeafTasksDone?(id, !optionDown)
        case .noteBadge(let id):
            setSelection([id])
            onOpenNote?(id)
        case .linkBadge(let id):
            setSelection([id])
            onOpenLink?(id)
        case .marker(let id, _):
            // F-CNT-3: any marker click cycles the priority/progress
            // family the host resolves; the token rides along.
            setSelection([id])
            onCycleMarker?(id)
        case .sourceBadge(let id):
            setSelection([id])
            onOpenSource?(id)
        case .attachmentBadge(let id):
            // The double-click path (below) Quick Looks; a single
            // click only selects so the drag never starts.
            setSelection([id])
        case .imageResize(let id):
            setSelection([id])
            beginImageResize(id: id, at: viewPoint, aspectLocked: !optionDown)
        }
        return true
    }

    /// The double-click consumption for the decoration surface
    /// (F-CNT-7): an attachment badge Quick Looks its files; anything
    /// else falls through to the normal title-editing double-click.
    func decorationDoubleClick(at viewPoint: CGPoint) -> Bool {
        guard let hit = decorationHit(at: viewPoint) else { return false }
        guard case .attachmentBadge(let id) = hit else { return false }
        setSelection([id])
        onQuickLookAttachments?(id)
        return true
    }

    // MARK: image resize (F-CNT-2)

    /// Begins a resize drag: the stored start pair plus the aspect lock
    /// (⌥ unlocks, SPEC's ⇧ note rides the option key on macOS).
    func beginImageResize(id: String, at viewPoint: CGPoint, aspectLocked: Bool) {
        decorationActions.imageResize = ImageResizeDrag(
            nodeID: id, startView: viewPoint, startSize: imageSize(of: id),
            aspectLocked: aspectLocked, liveSize: imageSize(of: id))
    }

    /// True while an image resize drag owns the pointer.
    var isResizingImage: Bool { decorationActions.imageResize != nil }

    /// One drag step: the preview rect tracks the pointer; the live
    /// size shows in the handle layer. `ending` commits the one
    /// `setImage` (the host's command) and clears the drag.
    func handleImageResizeDragged(to viewPoint: CGPoint, ending: Bool = false) -> Bool {
        guard let drag = decorationActions.imageResize else { return false }
        let delta = CGSize(
            width: (viewPoint.x - drag.startView.x) / max(camera.scale, 0.01),
            height: (viewPoint.y - drag.startView.y) / max(camera.scale, 0.01))
        var size = CGSize(width: drag.startSize.width + delta.width, height: drag.startSize.height + delta.height)
        size.width = max(24, min(size.width, 2048))
        size.height = max(24, min(size.height, 2048))
        if drag.aspectLocked, drag.startSize.width > 0, drag.startSize.height > 0 {
            // Aspect locked (F-CNT-2): the dominant axis drives.
            if abs(delta.width) >= abs(delta.height) {
                size.height = size.width * drag.startSize.height / drag.startSize.width
            } else {
                size.width = size.height * drag.startSize.width / drag.startSize.height
            }
        }
        decorationActions.imageResize?.liveSize = size
        showResizePreview(for: drag.nodeID, size: size)
        if ending {
            decorationActions.imageResize = nil
            hideResizeLayers()
            if size != drag.startSize {
                onResizeImage?(drag.nodeID, size)
            }
        }
        return true
    }

    /// Cancels an in-flight resize (Esc): no command, layers hidden.
    func cancelImageResize() {
        decorationActions.imageResize = nil
        hideResizeLayers()
    }

    /// The node's stored image display size.
    func imageSize(of id: String) -> CGSize {
        guard let image = dragModel?.nodes[id]?.image, image.size.count >= 2 else { return .zero }
        return CGSize(width: image.size[0], height: image.size[1])
    }

    /// The resize preview layer: a dashed rect at the target size
    /// (view space — the camera is idle during a drag), anchored at
    /// the node's top-left so the growth reads.
    private func showResizePreview(for id: String, size: CGSize) {
        guard let frame = scene?.nodes[id]?.frame,
            let drag = decorationActions.imageResize,
            let backing = layer
        else { return }
        if decorationActions.resizeLayer.superlayer == nil {
            backing.addSublayer(decorationActions.resizeLayer)
        }
        let growth = CGSize(
            width: size.width - drag.startSize.width, height: size.height - drag.startSize.height)
        let origin = camera.screenPoint(for: frame.origin)
        let rect = CGRect(
            origin: origin,
            size: CGSize(
                width: max(1, (frame.width + growth.width) * camera.scale),
                height: max(1, (frame.height + growth.height) * camera.scale)))
        decorationActions.resizeLayer.frame = CGRect(origin: .zero, size: bounds.size)
        decorationActions.resizeLayer.path = CGPath(rect: rect, transform: nil)
        decorationActions.resizeLayer.isHidden = false
    }

    private func hideResizeLayers() {
        decorationActions.resizeLayer.isHidden = true
    }

    // MARK: hover text builders

    /// The source anchor's hover (F-CNT-8): the URL, page/time when
    /// present, and the quoted excerpt's first line.
    static func sourceTooltip(of id: String, in model: MapModel?) -> String? {
        guard let source = model?.nodes[id]?.source, !source.url.isEmpty else { return nil }
        var lines = [source.url]
        if let page = source.page {
            lines.append("page \(page)")
        }
        if let time = source.time {
            let minutes = Int(time) / 60
            let seconds = Int(time) % 60
            lines.append(String(format: "at %d:%02d", minutes, seconds))
        }
        if let excerpt = source.excerpt?.split(separator: "\n").first, !excerpt.isEmpty {
            lines.append("“\(excerpt.prefix(80))”")
        }
        return lines.joined(separator: "\n")
    }

    /// The attachments' hover (F-CNT-7): names, count-capped.
    static func attachmentTooltip(of id: String, in model: MapModel?) -> String? {
        guard let attachments = model?.nodes[id]?.attachments, !attachments.isEmpty else { return nil }
        let names = attachments.prefix(4).map(\.name)
        let extra = attachments.count - names.count
        return extra > 0 ? names.joined(separator: "\n") + "\n+ \(extra) more" : names.joined(separator: "\n")
    }

    /// A marker's hover (F-CNT-3): the cycler's next step for the
    /// priority/progress families.
    static func markerTooltip(of id: String, token: String, in model: MapModel?) -> String? {
        guard MarkerKind.parse(token) != nil else { return nil }
        guard let family = MarkerCycler.family(of: token) else { return nil }
        guard let markers = model?.nodes[id]?.markers else { return nil }
        let cycled = MarkerCycler.cycled(markers, in: family) ?? []
        let next = cycled.last { family.contains($0) }
        return "→ \(next.map { String($0.dropFirst("sticker:".count)) } ?? "none")"
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        toolTip = decorationHoverText(at: point)
    }

    public override func mouseExited(with event: NSEvent) {
        toolTip = nil
        super.mouseExited(with: event)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                    owner: self, userInfo: nil))
        }
    }
}

/// The closures + highlight state the decoration surface forwards; in a
/// class box so the computed properties above stay clean.
@MainActor
final class DecorationActions {
    var onToggleTaskDone: ((String) -> Void)?
    var onSetLeafTasksDone: ((String, Bool) -> Void)?
    var onOpenNote: ((String) -> Void)?
    var onOpenLink: ((String) -> Void)?
    var onCycleMarker: ((String) -> Void)?
    var onOpenSource: ((String) -> Void)?
    var onQuickLookAttachments: ((String) -> Void)?
    var onResizeImage: ((String, CGSize) -> Void)?
    var onQuickLookImage: ((String) -> Void)?
    var onDropFiles: ((_ urls: [URL], _ nodeID: String?) -> Void)?
    var highlight: HighlightMode?
    var filterMastery: MasteryReport?
    var filterNow = Date()
    /// The in-flight image-resize drag (F-CNT-2), nil when idle.
    var imageResize: ImageResizeDrag?
    /// The dashed resize-preview layer (view space, z above content).
    let resizeLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        layer.strokeColor = NSColor.controlAccentColor.cgColor
        layer.lineWidth = 1
        layer.lineDashPattern = [4, 3]
        layer.zPosition = 3
        layer.isHidden = true
        return layer
    }()
}

/// One image-resize drag's geometry (F-CNT-2): the node, the grab point
/// and the stored start size; `liveSize` tracks the pointer.
@MainActor
struct ImageResizeDrag {
    let nodeID: String
    let startView: CGPoint
    let startSize: CGSize
    let aspectLocked: Bool
    var liveSize: CGSize
}
