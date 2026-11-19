import AppKit

/// Zen mode's chrome bookkeeping (F-FOC-2): what the window had visible
/// when Zen started, so Esc can put it all back. Everything is queried
/// generically and tolerantly — a window with no toolbar, no split
/// controller and no minimap (today's window) captures and restores
/// nothing. A future toolbar, Outline split view or minimap hides
/// without Zen knowing anything about them specifically.
@MainActor
struct ZenChromeSnapshot {
    private let toolbar: NSToolbar?
    private let toolbarWasVisible: Bool
    /// Split view items collapsed on entry, to uncollapse on exit.
    private let collapsedItems: [NSSplitViewItem]

    static func capture(window: NSWindow, protectedView: NSView) -> ZenChromeSnapshot {
        let toolbar = window.toolbar
        var collapsed: [NSSplitViewItem] = []
        if let splitController = window.contentViewController as? NSSplitViewController {
            for item in splitController.splitViewItems
            where !item.viewController.view.isDescendant(of: protectedView) {
                collapsed.append(item)
            }
        }
        return ZenChromeSnapshot(
            toolbar: toolbar,
            toolbarWasVisible: toolbar?.isVisible ?? false,
            collapsedItems: collapsed)
    }

    func applyHidden() {
        toolbar?.isVisible = false
        for item in collapsedItems {
            item.isCollapsed = true
        }
    }

    func restore() {
        if let toolbar {
            toolbar.isVisible = toolbarWasVisible
        }
        for item in collapsedItems {
            item.isCollapsed = false
        }
    }
}

/// The brainstorm countdown (F-FOC-2): 5/10/15/25 minutes, a subtle
/// corner ring that drains, and a soft system chime at the end.
/// Time math is pure (`progress(now:)`, `remainingText(now:)`) so
/// tests drive it with synthetic clocks; the real clock is one
/// repeating `Timer` on the main run loop.
@MainActor
final class BrainstormTimer {
    let endDate: Date
    private let totalSeconds: TimeInterval
    private(set) var isRunning = false
    private var ticker: Timer?
    /// Called ~4×/second while running (the ring redraws).
    var onTick: (() -> Void)?
    /// Called once when the countdown completes.
    var onEnd: (() -> Void)?

    init(minutes: Int, now: Date = Date()) {
        totalSeconds = TimeInterval(minutes * 60)
        endDate = now.addingTimeInterval(totalSeconds)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
    }

    /// True when `now` is at or past the end (idempotent: fires `onEnd`
    /// once, then keeps returning true).
    @discardableResult
    func advance(to now: Date = Date()) -> Bool {
        guard now >= endDate else { return false }
        if isRunning {
            stop()
            onEnd?()
        }
        return true
    }

    /// 0…1 of the countdown elapsed.
    func progress(now: Date = Date()) -> Double {
        let remaining = endDate.timeIntervalSince(now)
        let elapsed = totalSeconds - remaining
        return min(max(elapsed / totalSeconds, 0), 1)
    }

    /// The remaining minutes as "m:ss" (or "0:00" when done).
    func remainingText(now: Date = Date()) -> String {
        let remaining = max(0, Int(endDate.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private func tick() {
        guard !advance() else { return }
        onTick?()
    }
}

/// Zen mode's corner overlay: while idle a small round timer button
/// (its menu offers the 5/10/15/25-minute durations); while running a
/// draining ring plus the remaining "m:ss". Drawn with `NSBezierPath`
/// in `draw(_:)` — nothing animates positionally, so Reduce Motion
/// needs no special case.
@MainActor
final class ZenTimerOverlay: NSView {
    static let diameter: CGFloat = 30

    private let ringButton = NSButton(frame: .zero)
    private let durationMenu = NSMenu()
    private(set) var timer: BrainstormTimer?

    /// Who to tell when a duration is picked.
    var onPick: ((_ minutes: Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Brainstorm timer")
        ringButton.image = image
        ringButton.bezelStyle = .texturedRounded
        ringButton.imagePosition = .imageOnly
        ringButton.imageScaling = .scaleProportionallyDown
        ringButton.setAccessibilityLabel("Brainstorm timer")
        ringButton.focusRingType = .none
        ringButton.target = self
        ringButton.action = #selector(showDurationMenu)
        addSubview(ringButton)
        buildMenu()
        setAccessibilityLabel("Brainstorm timer")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ZenTimerOverlay is created in code")
    }

    // MARK: host API

    /// Starts (or restarts) the countdown and switches the overlay to
    /// its running look.
    func startTimer(_ minutes: Int) {
        timer?.stop()
        let newTimer = BrainstormTimer(minutes: minutes)
        timer = newTimer
        newTimer.onTick = { [weak self] in self?.refresh() }
        newTimer.onEnd = { [weak self] in
            self?.refresh()
            self?.playChime()
            self?.announce("Brainstorm timer finished")
        }
        newTimer.start()
        refresh()
        announce("Timer set, \(minutes) minutes")
    }

    func cancelTimer() {
        timer?.stop()
        timer = nil
        refresh()
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let timer else { return }
        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 12

        let track = NSBezierPath()
        track.appendArc(
            withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: true)
        NSColor.separatorColor.setStroke()
        track.lineWidth = 2
        track.stroke()

        let elapsed = timer.progress()
        guard elapsed > 0 else { return }
        let arc = NSBezierPath()
        // The ring drains clockwise as time passes.
        arc.appendArc(
            withCenter: center, radius: radius, startAngle: 90,
            endAngle: 90 - 360 * CGFloat(elapsed), clockwise: true)
        NSColor.controlAccentColor.setStroke()
        arc.lineWidth = 2
        arc.stroke()
    }

    private func refresh() {
        needsDisplay = true
        if let timer {
            let label = "Brainstorm timer, \(timer.remainingText()) remaining"
            setAccessibilityLabel(label)
            ringButton.setAccessibilityLabel(label)
        } else {
            setAccessibilityLabel("Brainstorm timer")
            ringButton.setAccessibilityLabel("Brainstorm timer")
        }
        buildMenu()
    }

    // MARK: menu

    private func buildMenu() {
        durationMenu.removeAllItems()
        if timer == nil {
            for minutes in [5, 10, 15, 25] {
                let item = NSMenuItem(
                    title: "\(minutes) Minutes", action: #selector(pickDuration(_:)),
                    keyEquivalent: "")
                item.target = self
                item.tag = minutes
                durationMenu.addItem(item)
            }
        } else {
            let stop = NSMenuItem(
                title: "Cancel Timer", action: #selector(cancelAction(_:)), keyEquivalent: "")
            stop.target = self
            durationMenu.addItem(stop)
        }
    }

    @objc private func showDurationMenu() {
        let location = NSPoint(
            x: 0, y: ringButton.frame.maxY + 4)
        durationMenu.popUp(
            positioning: durationMenu.item(at: 0), at: location, in: ringButton)
    }

    @objc private func pickDuration(_ sender: NSMenuItem) {
        onPick?(sender.tag)
    }

    @objc private func cancelAction(_ sender: NSMenuItem) {
        cancelTimer()
    }

    // MARK: sound & accessibility

    /// The soft chime at the end: the system "Glass" sound at a gentle
    /// volume, falling back to the plain beep.
    private func playChime() {
        if let glass = NSSound(named: "Glass") {
            glass.volume = 0.5
            glass.play()
        } else {
            NSSound.beep()
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: text])
    }

    override func layout() {
        super.layout()
        ringButton.frame = bounds
    }
}
