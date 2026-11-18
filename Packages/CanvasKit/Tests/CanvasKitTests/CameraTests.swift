import CoreGraphics
import Testing

@testable import CanvasKit

@Test func modelToScreen() {
    let camera = Camera(origin: CGPoint(x: 100, y: -50), scale: 2)
    let screen = camera.screenPoint(for: CGPoint(x: 330, y: 150))
    #expect(screen == CGPoint(x: 460, y: 400))
}

@Test func screenToModel() {
    let camera = Camera(origin: CGPoint(x: 100, y: -50), scale: 2)
    let model = camera.modelPoint(for: CGPoint(x: 460, y: 400))
    #expect(model == CGPoint(x: 330, y: 150))
}

@Test func pointTransformsInvertEachOther() {
    let camera = Camera(origin: CGPoint(x: -17.5, y: 42.25), scale: 1.75)
    let model = CGPoint(x: 312.5, y: -98.125)
    #expect(camera.modelPoint(for: camera.screenPoint(for: model)) == model)
    let identity = Camera()
    #expect(identity.screenPoint(for: model) == model)
    #expect(identity.modelPoint(for: model) == model)
}

@Test func visibleRectCoversViewportAtScale() {
    let camera = Camera(origin: CGPoint(x: 10, y: 20), scale: 2)
    let rect = camera.visibleRect(viewportSize: CGSize(width: 800, height: 600))
    #expect(rect == CGRect(x: 10, y: 20, width: 400, height: 300))
    #expect(camera.visibleRect(viewportSize: CGSize(width: 800, height: 600)).contains(CGPoint(x: 409, y: 319)))
    #expect(!rect.contains(CGPoint(x: 410, y: 320)))
}
