import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import QuartzCore

/// The audience-facing presentation surface (F-PRE-4/5/6/7): a real
/// `CanvasView` rendering the slide's scene, shielded by a transparent
/// event view that turns clicks and clicker keys into
/// `PresenterEvent`s — the pure machine in PresentationInput.swift
/// decides what they mean, so this view stays dumb about flow.
///
/// The camera rides the §7.6 motion table: a 600 ms ease-in-out tween
/// driven by `displayLink`, instant with a 120 ms crossfade under
/// Reduce Motion. The blank screens (B/W), the laser dot (hold L) and
/// the spotlight (hold S) are plain layers over the canvas; the
/// spotlight's animated subclass implements `init(layer:)` so Core
/// Animation can copy it for presentation layers.
@MainActor
public final class PresentationView: NSView {
    /// The map, rendered exactly as the editor draws it (shared
    /// `NodeRenderer`, the same scene pipeline).
    public let canvas = CanvasView(frame: .zero)

    /// Every input the audience surface can produce.
    public var onEvent: ((PresenterEvent) -> Void)?

    /// Motion preference at present time (the host polls the system
    /// once and passes it in; Reduce Motion then applies to every
    /// camera move and reveal).
    public var reduceMotion = false

    private let shield = PresentationShield()
    private let blankLayer = CALayer()
    private let laserLayer = CALayer()
    private let spotlightLayer = SpotlightLayer()
    private var displayLink: CADisplayLink?
    private var tween: (from: Camera, to: Camera, start: CFTimeInterval)?

    /// The laser dot's radius (F-PRE-7: "a soft red dot").
    static let laserRadius: CGFloat = 6
    /// The spotlight hole's radius.
    static let spotlightRadius: CGFloat = 140

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func build() {
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)

        shield.frame = bounds
        shield.autoresizingMask = [.width, .height]
        shield.onEvent = { [weak self] event in self?.onEvent?(event) }
        addSubview(shield)

        blankLayer.frame = CGRect(origin: .zero, size: bounds.size)
        blankLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        blankLayer.opacity = 0
        blankLayer.zPosition = 10
        layer?.addSublayer(blankLayer)

        laserLayer.bounds = CGRect(x: 0, y: 0, width: Self.laserRadius * 2, height: Self.laserRadius * 2)
        laserLayer.cornerRadius = Self.laserRadius
        laserLayer.backgroundColor = NSColor.systemRed.cgColor
        laserLayer.shadowColor = NSColor.systemRed.cgColor
        laserLayer.shadowOpacity = 0.9
        laserLayer.shadowRadius = 8
        laserLayer.zPosition = 12
        laserLayer.isHidden = true
        layer?.addSublayer(laserLayer)

        spotlightLayer.frame = CGRect(origin: .zero, size: bounds.size)
        spotlightLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        spotlightLayer.zPosition = 11
        spotlightLayer.isHidden = true
        layer?.addSublayer(spotlightLayer)

        wantsLayer = true
    }

    public override var acceptsFirstResponder: Bool { true }

    /// Makes the shield the window's first responder.
    public func makeShieldFirstResponder() {
        window?.makeFirstResponder(shield)
    }

    // MARK: scene + camera

    /// Installs a slide's scene (built from the fold-derived model —
    /// the document is never touched) and its reveal overlay, then
    /// moves the camera: animated per §7.6 unless `animated` is false
    /// (the first slide lands instantly).
    public func load(
        scene: CanvasScene, overlay: RevealOverlay?, camera: Camera, animated: Bool
    ) {
        // The first scene application must not animate (nothing came
        // before it); camera moves on top of it do.
        canvas.setScene(scene, animated: false)
        canvas.dragModel = nil
        applyOverlay(overlay)
        showCamera(camera, animated: animated)
    }

    /// Installs/updates the reveal overlay through the layer tree —
    /// opacity writes only, never a re-raster (SPEC §10).
    public func applyOverlay(_ overlay: RevealOverlay?) {
        canvas.layerTree.setRevealOverlay(overlay)
    }

    /// Runs one build step's reveal animation inside the current
    /// slide (F-PRE-3: fade + 8 pt slide from the parent, 250 ms,
    /// staggered; instant under Reduce Motion — the machine's effects
    /// drive this, the engine's states were already applied).
    public func reveal(ids: [String]) {
        canvas.layerTree.revealNodes(ids, camera: canvas.camera, reduceMotion: reduceMotion)
    }

    /// Moves the camera to `target`: 600 ms ease-in-out, or instant
    /// with a 120 ms fade-in of the whole surface under Reduce Motion
    /// (§7.6).
    public func showCamera(_ target: Camera, animated: Bool) {
        guard animated, !reduceMotion else {
            if reduceMotion, animated {
                // Reduce Motion crossfade: land instantly, fade the
                // surface back in over 120 ms.
                canvas.camera = target
                fadeSurfaceIn()
            } else {
                canvas.camera = target
            }
            return
        }
        startTween(to: target)
    }

    private func startTween(to target: Camera) {
        tween = (from: canvas.camera, to: target, start: CACurrentMediaTime())
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(tweenStep(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func tweenStep(_ link: CADisplayLink) {
        guard let tween else {
            link.isPaused = true
            return
        }
        let elapsed = CACurrentMediaTime() - tween.start
        let progress = min(max(elapsed / CameraEasing.slideDuration, 0), 1)
        canvas.camera = CameraEasing.interpolate(from: tween.from, to: tween.to, progress: progress)
        if progress >= 1 {
            self.tween = nil
            link.isPaused = true
        }
    }

    private func fadeSurfaceIn() {
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = CameraEasing.reduceMotionCrossfade
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(fade, forKey: "reduce-motion-crossfade")
        layer?.opacity = 1
        CATransaction.commit()
    }

    // MARK: blank screens + hold overlays (F-PRE-4/7)

    /// B/W blank the screen; `.normal` clears (with a 120 ms fade).
    public func setScreen(_ screen: PresenterSession.Screen) {
        let color: NSColor?
        switch screen {
        case .normal: color = nil
        case .black: color = .black
        case .white: color = .white
        }
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        if let color {
            blankLayer.backgroundColor = color.cgColor
            blankLayer.opacity = 1
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = blankLayer.opacity
            fade.toValue = 0
            fade.duration = CameraEasing.reduceMotionCrossfade
            blankLayer.add(fade, forKey: "blank-fade")
            blankLayer.opacity = 0
        }
        CATransaction.commit()
    }

    /// F-PRE-7: the laser dot follows the cursor while L is held.
    public func setLaser(active: Bool) {
        laserLayer.isHidden = !active
        if active, let mouse = window?.mouseLocationOutsideOfEventStream {
            let point = convert(mouse, from: nil)
            laserLayer.position = point
        }
    }

    /// F-PRE-7: a spotlight hole follows the cursor while S is held.
    public func setSpotlight(active: Bool) {
        spotlightLayer.isHidden = !active
        if active {
            spotlightLayer.setHole(
                center: viewMousePoint(), radius: Self.spotlightRadius,
                bounds: CGRect(origin: .zero, size: bounds.size))
        }
    }

    /// Mouse moved (tracking-area driven): keep the hold overlays on
    /// the cursor.
    public func mouseHovered(at point: CGPoint) {
        if !laserLayer.isHidden {
            laserLayer.position = point
        }
        if !spotlightLayer.isHidden {
            spotlightLayer.setHole(center: point, radius: Self.spotlightRadius, bounds: bounds)
        }
    }

    private func viewMousePoint() -> CGPoint {
        guard let mouse = window?.mouseLocationOutsideOfEventStream else { return .zero }
        return convert(mouse, from: nil)
    }
}

/// The transparent input shield: full-cover NSView that swallows every
/// mouse and key event (the canvas underneath never sees them, so
/// presenting can never select or mutate anything) and translates them
/// into `PresenterEvent`s.
@MainActor
final class PresentationShield: NSView {
    var onEvent: ((PresenterEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = nil
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .activeAlways],
                owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .activeAlways],
                owner: self, userInfo: nil))
    }

    // MARK: keys → PresenterKey

    override func keyDown(with event: NSEvent) {
        onEvent?(.keyDown(Self.key(for: event)))
    }

    override func keyUp(with event: NSEvent) {
        onEvent?(.keyUp(Self.key(for: event)))
    }

    /// Pure event→key translation (nonisolated so tests and the
    /// machine stay headless): nothing here touches AppKit state. A key
    /// table is wide by design.
    // swiftlint:disable:next cyclomatic_complexity
    nonisolated static func key(for event: NSEvent) -> PresenterKey {
        let characters = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Modifiers first: ⌥P toggles the presenter view, ⌘⏎ resumes
        // from live edit (F-PRE-5/6).
        if modifiers == .option, characters == "p" {
            return .presenterToggle
        }
        if modifiers == .command, characters == "\r" {
            return .resume
        }
        guard modifiers.isEmpty || modifiers == .shift else { return .unknown }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            let value = scalar.value
            switch value {
            case 0xF703: return .rightArrow
            case 0xF702: return .leftArrow
            case 0xF715: return .pageDown
            case 0xF712: return .pageUp
            case 0xF729: return .home
            case 0xF72B: return .end
            case 0x1B: return .escape
            case 0x0D: return .enter
            case 0x20: return .space
            default: break
            }
            if let digit = characters.first, digit.isASCII,
                let value = digit.wholeNumberValue, (0...9).contains(value)
            {
                return .digit(String(digit))
            }
        }
        switch characters {
        case "b", "B": return .blackKey
        case "w", "W": return .whiteKey
        case "e", "E": return .liveEdit
        case "l", "L": return .laser
        case "s", "S": return .spotlight
        default: return .unknown
        }
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        // A click advances the deck (F-PRE-4).
        onEvent?(.click)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let presentation = superview as? PresentationView {
            presentation.mouseHovered(at: point)
        }
    }
}

/// The F-PRE-7 spotlight: a dark full-bleed layer with a soft circular
/// hole at the cursor. Animated by Core Animation (the hole follows the
/// mouse), so it implements the `init(layer:)` copy initializer every
/// animated `CALayer` subclass needs.
final class SpotlightLayer: CAShapeLayer {
    var holeCenter: CGPoint = .zero
    var holeRadius: CGFloat = 140

    override init() {
        super.init()
        fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        fillRule = .evenOdd
        isOpaque = false
    }

    override init(layer: Any) {
        let source = layer as? SpotlightLayer
        holeCenter = source?.holeCenter ?? .zero
        holeRadius = source?.holeRadius ?? 140
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Rebuilds the path: the full bounds plus the hole circle,
    /// even-odd filled so the hole stays clear.
    func setHole(center: CGPoint, radius: CGFloat, bounds: CGRect) {
        holeCenter = center
        holeRadius = radius
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        self.path = path
    }
}
