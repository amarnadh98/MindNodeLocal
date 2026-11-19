import CoreGraphics
import Foundation
import MapCore
import MapRender

@testable import CanvasKit
@testable import SceneExport

/// Shared fixtures for the exporter tests: a small canonical map plus
/// scene/option helpers. Plain ASCII titles where the test compares
/// against golden bytes.
enum ExportFixtures {
    /// Root Idea → (Alpha → Alpha Child), Beta. Deterministic ids:
    /// "root-node", "alpha-node", "alpha-child-node", "beta-node".
    static func canonicalMap() -> MapModel {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var model = MapModel.emptyDocument()

        func add(_ id: String, _ text: String, parent: String? = nil) {
            var node = Node(id: id, title: NodeTitle(text: text), created: timestamp, modified: timestamp)
            node.parent = parent
            model.nodes[id] = node
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }

        add("root-node", "Root Idea")
        add("alpha-node", "Alpha", parent: "root-node")
        add("alpha-child-node", "Alpha Child", parent: "alpha-node")
        add("beta-node", "Beta", parent: "root-node")
        return model
    }

    static func scene(
        for model: MapModel, variant: ThemeVariant = .light, measurer: TextMeasurer = TextMeasurer()
    ) -> CanvasScene {
        SceneGeometry.build(model: model, variant: variant, measurer: measurer)
    }
}
