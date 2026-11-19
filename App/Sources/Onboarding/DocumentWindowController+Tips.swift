import AppKit
import CanvasKit

/// F-ONB-4's window-side wiring: the moments a tip fits and the banner
/// pinned over the canvas. The banner is a canvas subview found by
/// type, so no stored property is needed on the controller; TipCenter
/// owns the one-per-session and dismiss-forever rules.
@MainActor
extension DocumentWindowController {
    /// Shows `tip` if the rules allow (one per session, not dismissed),
    /// pinned to the bottom center of the canvas above the minimap
    /// lane.
    func showTipOnce(_ tip: TipCenter.Tip) {
        guard TipCenter.claimSessionOnce(for: tip) else { return }
        hideTip()
        let banner = TipBannerView(tip: tip)
        banner.onDismiss = { [weak self] in self?.hideTip() }
        canvas.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            banner.bottomAnchor.constraint(
                equalTo: canvas.bottomAnchor, constant: -MinimapView.canvasMargin),
            banner.widthAnchor.constraint(lessThanOrEqualTo: canvas.widthAnchor, constant: -32),
        ])
    }

    /// Removes the visible tip banner (dismiss or replacement).
    func hideTip() {
        for subview in canvas.subviews where subview is TipBannerView {
            subview.removeFromSuperview()
        }
    }

    /// The drag-reparent moment: the tip names the modifiers the
    /// gesture already proved interesting.
    func showDragTipOnce() {
        showTipOnce(TipCenter.freePlacementTip)
    }

    /// The map-grew moment (modelDidChange): the fold tip.
    func showMapGrewTipIfNeeded(nodeCount: Int) {
        guard nodeCount > 12 else { return }
        showTipOnce(TipCenter.foldTip)
    }
}
