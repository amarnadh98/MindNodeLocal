import AppKit
import CanvasKit
import Combine
import CoreGraphics
import MapCore
import MapRender
import SwiftUI

/// The presenter view's observable state (F-PRE-5): the dashboard
/// reads exactly this; the coordinator pushes into it.
@MainActor
final class PresenterDashboardModel: ObservableObject {
    /// One full dashboard state push (the coordinator recomputes
    /// everything per slide/build change, so the update is one value).
    struct Update {
        var slideIndex = 0
        var slideCount = 0
        var buildCursor = -1
        var buildCount = 0
        var notes = ""
        var nextNotes = ""
        var scene: CanvasScene?
        var camera: Camera?
        var nextScene: CanvasScene?
        var nextCamera: Camera?
        var startedAt = Date()
        var screenBlanked = false
    }

    @Published var slideIndex = 0
    @Published var slideCount = 0
    @Published var buildCursor = -1
    @Published var buildCount = 0
    @Published var notes = ""
    @Published var nextNotes = ""
    @Published var currentSlideImage: NSImage?
    @Published var nextSlideImage: NSImage?
    @Published var mapImage: NSImage?
    @Published var cameraRect: CGRect?
    @Published var startedAt = Date()
    @Published var screenBlanked = false
}

/// The presenter view window (F-PRE-5): current slide, next slide,
/// speaker notes, elapsed timer, clock, slide counter and the
/// minimap-with-position — on the second display when there is one,
/// or wherever ⌥P opened it on a single display.
@MainActor
final class PresenterWindowController: NSWindowController, NSWindowDelegate {
    let model = PresenterDashboardModel()
    private weak var coordinator: PresentationCoordinator?

    init(coordinator: PresentationCoordinator, screen: PresentationCoordinator.ScreenSpec) {
        self.coordinator = coordinator
        let frame = screen.frame
        let window = NSWindow(
            contentRect: NSRect(origin: frame.origin, size: frame.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Presenter"
        window.setFrameAutosaveName("ArborPresenterWindow")
        window.contentView = NSHostingView(rootView: PresenterDashboardView(model: model))
        super.init(window: window)
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Closing the dashboard detaches it from the coordinator.
    func windowWillClose(_ notification: Notification) {
        coordinator?.presenterWindowDidClose()
    }

    /// The coordinator pushes the whole dashboard state here after
    /// every slide/build/screen change; the scenes and cameras are the
    /// audience view's own values, so the thumbnails match it exactly.
    func update(_ update: PresenterDashboardModel.Update) {
        model.slideIndex = update.slideIndex
        model.slideCount = update.slideCount
        model.buildCursor = update.buildCursor
        model.buildCount = update.buildCount
        model.notes = update.notes
        model.nextNotes = update.nextNotes
        model.startedAt = update.startedAt
        model.screenBlanked = update.screenBlanked

        let slideThumb = CGSize(width: 320, height: 180)
        if let scene = update.scene, let camera = update.camera {
            model.currentSlideImage = SlideThumbnails.render(scene: scene, camera: camera, size: slideThumb)
        } else {
            model.currentSlideImage = nil
        }
        if let nextScene = update.nextScene, let nextCamera = update.nextCamera {
            model.nextSlideImage = SlideThumbnails.render(
                scene: nextScene, camera: nextCamera, size: slideThumb)
        } else {
            model.nextSlideImage = nil
        }
        let minimapSize = CGSize(width: 200, height: 140)
        if let scene = update.scene, let camera = update.camera {
            let fitCamera = CameraFit.camera(
                fitting: scene.bounds.insetBy(dx: -20, dy: -20), in: minimapSize, margin: 4)
            model.mapImage = SlideThumbnails.render(scene: scene, camera: fitCamera, size: minimapSize)
            model.cameraRect = SlideThumbnails.visibleRect(
                of: camera, sceneBounds: scene.bounds, in: minimapSize)
        } else {
            model.mapImage = nil
            model.cameraRect = nil
        }
    }
}

/// The F-PRE-5 dashboard.
struct PresenterDashboardView: View {
    @ObservedObject var model: PresenterDashboardModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                thumbnailPane(title: "Current", image: model.currentSlideImage)
                thumbnailPane(title: "Next", image: model.nextSlideImage)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Notes", systemImage: "text.note")
                        .font(.headline)
                    ScrollView {
                        Text(model.notes.isEmpty ? "No notes" : model.notes)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    Text("Up next: \(model.nextNotes.isEmpty ? "—" : model.nextNotes)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 16) {
                Label(
                    "\(model.slideIndex + 1) / \(max(model.slideCount, 1))"
                        + (model.buildCount > 0
                            ? " · build \(model.buildCursor + 1)/\(model.buildCount)" : ""),
                    systemImage: "square.stack.3d.up"
                )
                .font(.title3)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(
                        Self.elapsed(from: model.startedAt, to: context.date),
                        systemImage: "timer"
                    )
                    .font(.title3)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(
                        Self.clock(context.date), systemImage: "clock"
                    )
                    .font(.title3)
                }
                Spacer()
                if model.screenBlanked {
                    Label("Screen blanked", systemImage: "moon.zzz")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                minimap
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 480)
    }

    private func thumbnailPane(title: String, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ZStack {
                Rectangle().fill(.black.opacity(0.1))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(width: 320)
    }

    private var minimap: some View {
        ZStack {
            if let map = model.mapImage {
                Image(nsImage: map).resizable().aspectRatio(contentMode: .fit)
            }
            if let rect = model.cameraRect {
                Rectangle()
                    .stroke(.red, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: 200, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(start))
        let minutes = Int(interval / 60)
        let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func clock(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: now)
    }
}

/// Thumbnail rendering for the presenter view — the same shared
/// `SceneRenderer` path as the canvas and PDF export, drawn into a
/// small bitmap.
enum SlideThumbnails {
    static func render(scene: CanvasScene, camera: Camera, size: CGSize) -> NSImage? {
        let width = max(8, Int(size.width.rounded()))
        let height = max(8, Int(size.height.rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // SceneRenderer draws into a flipped (y-down) context.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        SceneRenderer.draw(
            scene: scene, camera: camera, selectionColor: NSColor.controlAccentColor.cgColor,
            in: context, viewport: size)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    /// The audience camera's visible rect, mapped into a whole-map
    /// thumbnail of `size` (the minimap-with-position, F-PRE-5).
    static func visibleRect(of camera: Camera, sceneBounds: CGRect, in size: CGSize) -> CGRect {
        guard !sceneBounds.isNull, sceneBounds.width > 0, sceneBounds.height > 0,
            size.width > 0, size.height > 0
        else { return .zero }
        let scale = min(size.width / sceneBounds.width, size.height / sceneBounds.height)
        let offsetX = (size.width - sceneBounds.width * scale) / 2
        let offsetY = (size.height - sceneBounds.height * scale) / 2
        let visible = camera.visibleRect(viewportSize: size)
        return CGRect(
            x: offsetX + (visible.minX - sceneBounds.minX) * scale,
            y: offsetY + (visible.minY - sceneBounds.minY) * scale,
            width: visible.width * scale,
            height: visible.height * scale)
    }
}
