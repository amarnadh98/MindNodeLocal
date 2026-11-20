import AppKit
import MapCore

/// The contextual bar's leading control (ADR-0034): a "Box | Line"
/// segmented control for the selection's shape class — the choice
/// MindNode users reach for first, in plain words instead of the
/// eleven-entry shape menu (which stays in the inspector's Style tab
/// and Format ▸ Style ▸ Shape).
///
/// The state is the SELECTION's, so it is re-synced every time the
/// bar is (re)presented — `presentIfNeeded` runs on every selection
/// and store change. A mixed selection lights no segment; clicking
/// one applies the class to every selected node as ONE undo step
/// (F-EDT-12) through the host action both UIs share.
@MainActor
extension ContextualBarController {
    /// The bar's Box|Line control, looking up its own state.
    func shapeSegment() -> NSView {
        let segment = NSSegmentedControl()
        segment.segmentCount = 2
        segment.setLabel("Box", forSegment: 0)
        segment.setLabel("Line", forSegment: 1)
        segment.segmentStyle = .texturedRounded
        segment.controlSize = .small
        segment.trackingMode = .selectAny
        segment.setToolTip("Box", forSegment: 0)
        segment.setToolTip("Line", forSegment: 1)
        segment.action = #selector(shapeSegmentChosen(_:))
        segment.target = self
        segment.setAccessibilityLabel("Node shape")
        return segment
    }

    /// Lights the segment matching the selection's shape class, or
    /// neither for a mixed selection. The segment lives inside the
    /// bar's stack view (the bar is built once and reused).
    func syncShapeSegment() {
        guard let stack = bar?.subviews.compactMap({ $0 as? NSStackView }).first,
            let segment = stack.views.compactMap({ $0 as? NSSegmentedControl }).first
        else { return }
        let isBox = host?.selectionShapeClass()
        segment.setSelected(isBox == true, forSegment: 0)
        segment.setSelected(isBox == false, forSegment: 1)
        segment.setAccessibilityValue(isBox == nil ? "Mixed" : (isBox! ? "Box" : "Line"))
        let tip = isBox == nil ? "Mixed selection" : "Node shape"
        segment.setToolTip(tip, forSegment: 0)
        segment.setToolTip(tip, forSegment: 1)
    }

    /// One segment click: one `setStyle` command over the whole
    /// selection. Clicking the already-lit segment (a selectAny toggle
    /// off, `selectedSegment` −1) just re-lights it — no empty undo
    /// step.
    @objc func shapeSegmentChosen(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else {
            syncShapeSegment()
            return
        }
        let box = sender.selectedSegment == 0
        if let current = host?.selectionShapeClass(), current == box {
            syncShapeSegment()
            return
        }
        host?.setNodeShapeClass(box: box)
    }
}
