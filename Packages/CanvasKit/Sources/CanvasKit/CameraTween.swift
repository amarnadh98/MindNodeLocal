import CoreGraphics
import Foundation

/// The §7.6 camera move: 500 ms ease-in-out cubic (inside the spec's
/// 450–600 ms band), decidable headlessly — `CameraEasing` is pure,
/// and the tween itself only advances a clock and hands each
/// interpolated camera to a step closure.
public enum CameraEasing {
    /// 500 ms, inside SPEC §7.6's 450–600 ms camera band.
    public static let focusDuration: CFTimeInterval = 0.5

    /// The slide-change camera duration for presentations: 600 ms,
    /// the top of §7.6's 450–600 ms camera band.
    public static let slideDuration: CFTimeInterval = 0.6
    /// §7.6 Reduce Motion: camera moves become a 120 ms crossfade.
    public static let reduceMotionCrossfade: CFTimeInterval = 0.12

    /// The slide tween duration honoring the motion preference.
    public static func slideDuration(reduceMotion: Bool) -> CFTimeInterval {
        reduceMotion ? 0 : slideDuration
    }

    /// Cubic ease-in-out, clamped to 0…1 (same curve as `value(at:)`).
    public static func easeInOutCubic(_ progress: Double) -> Double {
        value(at: progress)
    }

    /// Cubic ease-in-out: 0 at t=0, 1 at t=1, slow at both ends.
    public static func value(at progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped < 0.5
            ? 4 * clamped * clamped * clamped
            : 1 - pow(-2 * clamped + 2, 3) / 2
    }

    /// The camera `progress` (0…1) of the way from `start` to `end`.
    public static func interpolate(from start: Camera, to end: Camera, progress: Double) -> Camera {
        let eased = value(at: progress)
        return Camera(
            origin: CGPoint(
                x: start.origin.x + (end.origin.x - start.origin.x) * eased,
                y: start.origin.y + (end.origin.y - start.origin.y) * eased),
            scale: start.scale + (end.scale - start.scale) * eased)
    }
}

/// Drives one animated camera move (focus-mode zoom-to-fit and its
/// exit restore) on a ~60 Hz main-actor task. Reduce Motion collapses
/// the whole move to a single immediate step (SPEC §7.6: durations
/// become 0). Starting a new move cancels the running one.
@MainActor
public final class CameraTween {
    public init() {}

    private var task: Task<Void, Never>?

    /// True while a tween is ticking.
    public var isRunning: Bool { task != nil }

    /// Animates from `from` to `to` over `duration`, calling `step`
    /// per frame (~60 Hz) with the interpolated camera and `finish`
    /// once at the end.
    public func run(
        from: Camera,
        to: Camera,
        duration: CFTimeInterval = CameraEasing.focusDuration,
        reduceMotion: Bool,
        step: @escaping (Camera) -> Void,
        finish: (() -> Void)? = nil
    ) {
        cancel()
        guard !reduceMotion, duration > 0 else {
            step(to)
            finish?()
            return
        }
        let beganAt = Date()
        let frame = Duration.milliseconds(16)
        task = Task { [weak self] in
            step(from)
            while !Task.isCancelled {
                try? await Task.sleep(for: frame)
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(beganAt)
                guard let self else { return }
                if elapsed >= duration {
                    self.task = nil
                    step(to)
                    finish?()
                    return
                }
                step(CameraEasing.interpolate(from: from, to: to, progress: elapsed / duration))
            }
        }
    }

    /// Stops the tween without snapping to the target.
    public func cancel() {
        task?.cancel()
        task = nil
    }
}
