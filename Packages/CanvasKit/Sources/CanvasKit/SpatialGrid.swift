import CoreGraphics
import Foundation

/// Uniform-grid spatial index for hit-testing and culling (SPEC §11.4:
/// 512 pt cells). Insert frames once, query rectangles cheaply.
public struct SpatialGrid {
    public static let cellSize: CGFloat = 512

    private var cells: [Int: [String]] = [:]
    private var frames: [String: CGRect] = [:]

    public init() {}

    /// The cell key for a model-space point.
    private static func key(x: Int, y: Int) -> Int {
        (x &* 1_000_003) &+ y &* 7_919
    }

    /// Inserts a frame for `id`, covering every cell it touches.
    public mutating func insert(id: String, frame: CGRect) {
        frames[id] = frame
        let firstColumn = Int(floor(frame.minX / Self.cellSize))
        let lastColumn = Int(floor((frame.maxX - 0.001) / Self.cellSize))
        let firstRow = Int(floor(frame.minY / Self.cellSize))
        let lastRow = Int(floor((frame.maxY - 0.001) / Self.cellSize))
        for column in firstColumn...max(firstColumn, lastColumn) {
            for row in firstRow...max(firstRow, lastRow) {
                cells[Self.key(x: column, y: row), default: []].append(id)
            }
        }
    }

    /// Ids whose frames intersect `rect`. Candidate cells give a superset;
    /// the exact frame test filters it.
    public func ids(intersecting rect: CGRect) -> Set<String> {
        let firstColumn = Int(floor(rect.minX / Self.cellSize))
        let lastColumn = Int(floor(rect.maxX / Self.cellSize))
        let firstRow = Int(floor(rect.minY / Self.cellSize))
        let lastRow = Int(floor(rect.maxY / Self.cellSize))
        var candidates = Set<String>()
        for column in firstColumn...max(firstColumn, lastColumn) {
            for row in firstRow...max(firstRow, lastRow) {
                if let ids = cells[Self.key(x: column, y: row)] {
                    candidates.formUnion(ids)
                }
            }
        }
        var result = Set<String>()
        for id in candidates {
            if let frame = frames[id], frame.intersects(rect) {
                result.insert(id)
            }
        }
        return result
    }

    /// The id whose frame contains `point`, if any. When several contain
    /// it (overlapping is invalid but defensive), the smallest frame wins
    /// — the most specific target.
    public func id(at point: CGPoint) -> String? {
        let probe = CGRect(
            x: point.x, y: point.y, width: 0.001, height: 0.001)
        let hits = ids(intersecting: probe)
        var best: (String, CGRect)?
        for id in hits {
            guard let frame = frames[id], frame.contains(point) else { continue }
            if best == nil || frame.width * frame.height < best!.1.width * best!.1.height {
                best = (id, frame)
            }
        }
        return best?.0
    }

    public var isEmpty: Bool { frames.isEmpty }

    public func frame(of id: String) -> CGRect? { frames[id] }
}
