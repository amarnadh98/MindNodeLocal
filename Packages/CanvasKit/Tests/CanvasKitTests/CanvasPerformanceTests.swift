import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// SPEC §11.8 budgets on a 5,000-node map, measured like the MapLayout
/// smoke test (best of 10; the budget assertions only bite in release,
/// where the optimizer can't hide constant factors behind debug checks).
/// Timings are printed so CI runs show the actual numbers.
@MainActor
struct CanvasPerformanceTests {
    private let viewport = CGSize(width: 1_200, height: 800)

    private func bigMap(nodeCount: Int) -> MapModel {
        var model = MapModel.emptyDocument(docID: "perf")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<nodeCount {
            let id = "n\(index)"
            model.nodes[id] = Node(
                id: id,
                title: NodeTitle(text: "Node \(index) with a title of some length"),
                created: date, modified: date)
        }
        // A 7-ary breadth-first tree: deep enough for realistic branch
        // levels, wide enough for contour work.
        var childrenOf: [String: [String]] = [:]
        var frontier = 0
        var nextChild = 1
        let rootID = "n0"
        model.roots = [rootID]
        while nextChild < nodeCount {
            let childCount = min(7, nodeCount - nextChild)
            childrenOf["n\(frontier)"] = (nextChild..<(nextChild + childCount)).map { "n\($0)" }
            nextChild += childCount
            frontier += 1
        }
        for (parent, children) in childrenOf {
            model.nodes[parent]?.children = children
            for child in children {
                model.nodes[child]?.parent = parent
            }
        }
        return model
    }

    private func grid(for scene: CanvasScene) -> SpatialGrid {
        var grid = SpatialGrid()
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
        return grid
    }

    /// The camera the host uses on open: everything fitted to the
    /// viewport (tiny scale → the whole map is visible, LOD capsules).
    private func fitCamera(for scene: CanvasScene) -> Camera {
        let content = scene.bounds.insetBy(dx: -40, dy: -40)
        let scale = min(
            viewport.width / max(content.width, 1),
            viewport.height / max(content.height, 1), 4)
        return Camera(
            origin: CGPoint(
                x: content.midX - viewport.width / (2 * scale),
                y: content.midY - viewport.height / (2 * scale)),
            scale: scale)
    }

    @Test func fiveThousandNodeBudgets() throws {
        let model = bigMap(nodeCount: 5_000)
        let measurer = TextMeasurer()
        let accent = CGColor(gray: 0, alpha: 1)

        // --- Open to first paint: build + layer-tree apply at the
        // initial fit (everything visible, LOD capsules).
        var coldOpen: Double = 0
        var scene: CanvasScene?
        for run in 0..<10 {
            let start = DispatchTime.now()
            let built = SceneGeometry.build(
                model: model, variant: .light, measurer: measurer)
            let tree = CanvasLayerTree()
            var openContext = ApplyContext(
                scene: built, grid: grid(for: built),
                camera: fitCamera(for: built), viewport: viewport)
            openContext.backingScale = 1
            openContext.animated = false
            openContext.reduceMotion = false
            openContext.selectionColor = accent
            tree.apply(openContext)
            let elapsed = elapsed(since: start)
            if run == 0 {
                coldOpen = elapsed
            }
            scene = built
        }
        let built = try #require(scene)
        print(
            "perf open (5k, cold measurer, first run): \(format(coldOpen))"
                + " — build + grid + layer-tree apply at fit")
        #expect(built.nodes.count == 5_000)

        // --- Keystroke → relayout → paint at a working zoom (SPEC §11.8:
        // 8 ms): one title change through the incremental path —
        // `SceneGeometry.update` re-measures one node, relayouts only the
        // dirty chain, and the grid/diff apply touches only changed
        // nodes. The viewport is at 100% around the edited node's
        // subtree.
        let tree = CanvasLayerTree()
        let workingCamera = Camera(
            origin: CGPoint(x: -viewport.width / 2, y: -viewport.height / 2), scale: 1)
        var initial = ApplyContext(
            scene: built, grid: grid(for: built),
            camera: workingCamera, viewport: viewport)
        initial.backingScale = 1
        initial.animated = false
        initial.reduceMotion = false
        initial.selectionColor = accent
        tree.apply(initial)

        // The per-document caches a real window holds: filled by a full
        // build, then reused by every keystroke.
        let cache = SceneBuildCache(variant: .light)
        var incrementalGrid = grid(for: built)
        var edited = model
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)
        var best: Double?
        for _ in 0..<10 {
            edited.nodes["n600"]?.title = NodeTitle(
                text: "Node 600 retitled \(Int.random(in: 0..<1000))")
            let start = DispatchTime.now()
            let rebuilt = SceneGeometry.update(
                model: edited, cache: cache, variant: .light, measurer: measurer,
                dirty: ["n600"])
            var keystrokeContext = ApplyContext(
                scene: rebuilt, grid: incrementalGrid,
                camera: workingCamera, viewport: viewport)
            keystrokeContext.backingScale = 1
            keystrokeContext.animated = false
            keystrokeContext.reduceMotion = false
            keystrokeContext.selectionColor = accent
            let diff = tree.apply(keystrokeContext)
            // The canvas view's grid sync: only the touched cells change.
            for (id, change) in diff.nodes {
                switch change {
                case .removed:
                    incrementalGrid.remove(id: id)
                case .added:
                    if let frame = rebuilt.nodes[id]?.frame {
                        incrementalGrid.insert(id: id, frame: frame)
                    }
                case .moved(_, let to), .restyled(_, let to):
                    incrementalGrid.update(id: id, frame: to)
                }
            }
            let elapsedSeconds = elapsed(since: start)
            best = min(best ?? elapsedSeconds, elapsedSeconds)
        }
        let keystroke = try #require(best)
        print(
            "perf keystroke (5k, best of 10): \(format(keystroke))"
                + " — incremental update + grid delta + layer diff apply at 100% zoom")

        #if !DEBUG
            // §11.8's 8 ms keystroke→relayout→paint budget, now enforced:
            // the incremental path (§11.3's `Layout.update(dirty:)`,
            // re-measuring one node and relayouting only its chain) keeps
            // the measured split at roughly 1 ms incremental layout + ~1 ms
            // scene assembly + ~2 ms layer diff apply.
            //
            // The budgets are for an Apple M1 (§11.8). Shared CI runners
            // measure 2–3× slower, so CI (which sets `CI`) only prints the
            // numbers; local release runs enforce them.
            if ProcessInfo.processInfo.environment["CI"] == nil {
                #expect(
                    keystroke < 0.008,
                    "SPEC §11.8 keystroke→relayout→paint budget (8 ms): \(format(keystroke))"
                )
                #expect(
                    coldOpen < 0.300,
                    "SPEC §11.8 open 5k document to first paint budget: \(format(coldOpen))")
            }
        #endif
    }

    private func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }
}
