import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Shared fixtures for the F-FOC hosted tests: a small document with
/// a folded branch, a matching note and a tag, opened through the real
/// document controller with its window shown — the same path the app
/// uses.
@MainActor
enum FocusFindFixtures {
    /// root "Ideas" ▸ [a "alpha branch" (folded ▸ a1 "hidden beta
    /// leaf"), b "beta branch" (note with BETA), c "gamma branch"
    /// (tagged "exam")].
    static func model() -> MapModel {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var model = MapModel.emptyDocument(docID: "focus-find")
        let root = Node(id: "root", title: NodeTitle(text: "Ideas"), created: date, modified: date)
        var alpha = Node(
            id: "a", parent: "root", title: NodeTitle(text: "alpha branch"), folded: true,
            created: date, modified: date)
        let leaf = Node(
            id: "a1", parent: "a", title: NodeTitle(text: "hidden beta leaf"),
            created: date, modified: date)
        var beta = Node(
            id: "b", parent: "root",
            title: NodeTitle(
                text: "beta branch", runs: [Run(range: [5, 6], bold: true)]),
            note: "a note containing BETA text", created: date, modified: date)
        let betaChild = Node(
            id: "b1", parent: "b", title: NodeTitle(text: "beta child"),
            created: date, modified: date)
        var gamma = Node(
            id: "c", parent: "root", title: NodeTitle(text: "gamma branch"),
            tags: ["t1"], created: date, modified: date)
        alpha.children = ["a1"]
        beta.children = ["b1"]
        gamma.children = []
        model.nodes = ["root": root, "a": alpha, "a1": leaf, "b": beta, "b1": betaChild, "c": gamma]
        model.roots = ["root"]
        model.nodes["root"]?.children = ["a", "b", "c"]
        model.tags = [Tag(id: "t1", name: "exam", color: "#E5484D")]
        return model
    }

    /// Writes the model to a temp package, opens it through the real
    /// document controller and shows the window.
    static func makeShownDocument(
        model: MapModel, viewStateBase: URL? = nil
    ) throws -> (MapDocument, DocumentWindowController) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-find-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        document.undoManager?.groupsByEvent = false
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        if let viewStateBase {
            controller.viewStateStore = ViewStateStore(baseURL: viewStateBase)
        }
        controller.showWindow(nil)
        // The find tests must not race the debounced view-state save.
        controller.viewStateSaveDelay = .seconds(60)
        return (document, controller)
    }
}
