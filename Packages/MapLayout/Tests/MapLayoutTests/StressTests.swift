import CoreGraphics
import Foundation
import Testing

@testable import MapLayout

/// Deterministic RNG (splitmix64) so stress failures reproduce from a seed.
struct SeededGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func uniform(_ range: ClosedRange<CGFloat>) -> CGFloat {
        let span = UInt64(UInt32.max)
        let roll = CGFloat(next() & UInt64(UInt32.max)) / CGFloat(span)
        return range.lowerBound + roll * (range.upperBound - range.lowerBound)
    }

    mutating func count(in range: ClosedRange<Int>) -> Int {
        Int(next() % UInt64(range.upperBound - range.lowerBound + 1)) + range.lowerBound
    }
}

func randomTree(_ generator: inout SeededGenerator, depth: Int, id: inout Int) -> LayoutNode {
    id += 1
    let own = id
    let width = generator.uniform(20...320)
    let height = generator.uniform(10...130)
    let childCount = depth <= 0 ? 0 : generator.count(in: 0...4)
    let children = (0..<childCount).map { _ in
        randomTree(&generator, depth: depth - 1, id: &id)
    }
    return LayoutNode(id: "r\(own)", size: CGSize(width: width, height: height), children: children)
}

func overlapViolations(_ frames: LayoutResult) -> [String] {
    let list = frames.values.map { $0.standardized }.sorted { $0.minX < $1.minX }
    var violations: [String] = []
    for i in list.indices {
        for j in list.indices where j > i {
            let first = list[i]
            let second = list[j]
            let separated =
                first.maxX <= second.minX || second.maxX <= first.minX
                || first.maxY <= second.minY || second.maxY <= first.minY
            if !separated {
                violations.append("\(first) overlaps \(second)")
            }
        }
    }
    return violations
}

@Test func stressNoOverlapsAcrossRandomTrees() {
    var failures: [String] = []
    for seed: UInt64 in 0..<300 {
        var generator = SeededGenerator(seed: seed)
        var id = 0
        let tree = randomTree(&generator, depth: 6, id: &id)
        for structure in allStructures {
            let frames = TreeLayout.layout(root: tree, structure: structure)
            for violation in overlapViolations(frames) {
                failures.append("seed \(seed) \(structure.rawValue): \(violation)")
                if failures.count > 20 {
                    break
                }
            }
            if failures.count > 20 {
                break
            }
        }
        if failures.count > 20 {
            break
        }
    }
    #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
}
