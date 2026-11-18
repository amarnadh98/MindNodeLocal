import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

struct BranchPathTests {
    @Test func cubicMatchesSpecFormula() {
        let from = CGPoint(x: 100, y: 50)
        let to = CGPoint(x: 400, y: 120)
        let path = BranchPath.cubic(from: from, to: to)
        let elements = pathElements(path)

        #expect(elements.count == 2)
        guard case .moveToPoint(let move) = elements[0],
            case .curveToPoint(let control1, let control2, let end) = elements[1]
        else {
            Issue.record("unexpected path elements")
            return
        }
        let dx = to.x - from.x
        #expect(move == from)
        #expect(control1 == CGPoint(x: from.x + dx * 0.5, y: from.y))
        #expect(control2 == CGPoint(x: to.x - dx * 0.5, y: to.y))
        #expect(end == to)
    }

    @Test func verticalCubicSwapsAxes() {
        let from = CGPoint(x: 50, y: 100)
        let to = CGPoint(x: 120, y: 400)
        let path = BranchPath.cubic(from: from, to: to, axis: .vertical)
        guard case .curveToPoint(let control1, let control2, _) = pathElements(path)[1] else {
            Issue.record("missing curve")
            return
        }
        let dy = to.y - from.y
        #expect(control1 == CGPoint(x: from.x, y: from.y + dy * 0.5))
        #expect(control2 == CGPoint(x: to.x, y: to.y - dy * 0.5))
    }

    @Test func straightConnectsAnchors() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 100, y: 20)
        let path = BranchPath.straight(from: from, to: to)
        let elements = pathElements(path)
        #expect(elements.count == 2)
        guard case .moveToPoint(let move) = elements[0], case .addLineToPoint(let end) = elements[1] else {
            Issue.record("unexpected elements")
            return
        }
        #expect(move == from)
        #expect(end == to)
    }

    @Test func elbowStaysInsideCorridor() {
        let from = CGPoint(x: 100, y: 50)
        let to = CGPoint(x: 400, y: 120)
        let path = BranchPath.elbow(from: from, to: to)
        let box = path.boundingBox
        #expect(box.minX >= min(from.x, to.x) - 1)
        #expect(box.maxX <= max(from.x, to.x) + 1)
        #expect(box.minY >= min(from.y, to.y) - 9)
        #expect(box.maxY <= max(from.y, to.y) + 9)
    }

    @Test func taperedEnclosesTheCenterlineAndTapers() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 300, y: 40)
        let startWidth: CGFloat = 6
        let endWidth: CGFloat = 2
        let path = BranchPath.tapered(from: from, to: to, startWidth: startWidth, endWidth: endWidth)
        let box = path.boundingBox
        let elements = pathElements(path)

        #expect(box.contains(from))
        #expect(box.contains(to))
        #expect(elements.count >= 34)
        let centerlineSpan = abs(to.y - from.y)
        let spread = (startWidth + endWidth) / 2
        #expect(box.height >= centerlineSpan + spread - 0.5)
        #expect(box.height <= centerlineSpan + spread + 1.5)
    }

    @Test func taperedVerticalSwapsAxes() {
        let from = CGPoint(x: 10, y: 100)
        let to = CGPoint(x: 30, y: 400)
        let path = BranchPath.tapered(
            from: from, to: to, startWidth: 6, endWidth: 2, axis: .vertical)
        let box = path.boundingBox
        #expect(box.contains(from))
        #expect(box.contains(to))
        #expect(box.width >= 6 * 0.9)
    }

    @Test func taperedRoundCapsExtendPastTheEndpoints() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 100, y: 0)
        let path = BranchPath.tapered(from: from, to: to, startWidth: 6, endWidth: 6)
        #expect(path.contains(CGPoint(x: 2.5, y: 0)), "start cap must bulge left of the anchor")
        #expect(path.contains(CGPoint(x: 102.5, y: 0)), "end cap must bulge right of the anchor")
    }
}

/// Collects a path's elements for assertions.
func pathElements(_ path: CGPath) -> [PathElement] {
    var elements: [PathElement] = []
    path.applyWithBlock { elementPointer in
        let element = elementPointer.pointee
        switch element.type {
        case .moveToPoint:
            elements.append(.moveToPoint(element.points[0]))
        case .addLineToPoint:
            elements.append(.addLineToPoint(element.points[0]))
        case .addQuadCurveToPoint:
            elements.append(.quadCurve(element.points[0], element.points[1]))
        case .addCurveToPoint:
            elements.append(
                .curveToPoint(
                    element.points[0], element.points[1], element.points[2]))
        case .closeSubpath:
            elements.append(.close)
        default:
            break
        }
    }
    return elements
}

enum PathElement: Equatable {
    case moveToPoint(CGPoint)
    case addLineToPoint(CGPoint)
    case quadCurve(CGPoint, CGPoint)
    case curveToPoint(CGPoint, CGPoint, CGPoint)
    case close
}
