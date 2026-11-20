import AppKit
import Foundation
import MapCore
import PDFKit
import SystemIntegration

/// F-INT-9: printing. `MapDocument` presents the standard Print panel
/// with the Arbor options accessory (fit to page / tile across pages /
/// outline print; header/footer toggles), then composes the job as a
/// paper-sized vector PDF through the shared scene renderer (ADR-0029:
/// print == export) and prints it via PDFKit's `NSPrintOperation`. Page
/// Setup works through the panel's own paper controls and the standard
/// File ▸ Page Setup… item.
extension MapDocument {
    /// ⌘P presents the panel; the job is composed and printed on OK.
    func presentPrintPanel() {
        guard let window = windowControllers.first?.window else { return }
        let info = printInfo.copied()
        let accessory = PrintAccessoryController()
        let panel = NSPrintPanel()
        panel.addAccessoryController(accessory)

        panel.beginSheet(
            using: info, on: window,
            completionHandler: { [weak self] result in
                guard result == .printed, let self else { return }
                do {
                    let operation = try PrintCoordinator.makePrintOperation(
                        model: self.store.model,
                        options: accessory.printOptions,
                        printInfo: info,
                        title: self.displayName ?? "Untitled")
                    operation.run()
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Print failed"
                    alert.informativeText =
                        "The document could not be prepared for printing."
                    alert.beginSheetModal(for: window)
                }
            })
    }
}

/// Builds the print `NSPrintOperation` from the model + the user's
/// options. The one seam the hosted tests drive (no panels): compose,
/// assert page counts, run the operation to a file.
enum PrintCoordinator {
    /// The composer spec distilled from AppKit's `NSPrintInfo`
    /// (paper + imageable area, orientation already applied by
    /// `paperSize`/`imageablePageBounds`).
    static func spec(options: PrintOptions, printInfo: NSPrintInfo, title: String) -> PrintComposer.Spec {
        PrintComposer.Spec(
            paperSize: printInfo.paperSize,
            printableRect: printInfo.imageablePageBounds,
            options: options,
            title: title)
    }

    /// The composed bytes (pure; testable without an operation).
    static func compose(
        model: MapModel, options: PrintOptions, printInfo: NSPrintInfo, title: String
    ) throws -> Data {
        try PrintComposer.compose(
            model: model, spec: spec(options: options, printInfo: printInfo, title: title))
    }

    /// The pages the job will produce for the same inputs (pure).
    static func pageCount(
        model: MapModel, options: PrintOptions, printInfo: NSPrintInfo, title: String
    ) -> Int {
        PrintComposer.pageCount(
            model: model, spec: spec(options: options, printInfo: printInfo, title: title))
    }

    /// The operation: the composed PDF, printed 1:1 onto the paper the
    /// Print panel chose (`.pageScaleNone` — the pages already ARE the
    /// paper size). The print panel is NOT shown again — the caller's
    /// NSPrintPanel run before this point is the one the user answered.
    static func makePrintOperation(
        model: MapModel, options: PrintOptions, printInfo: NSPrintInfo, title: String,
        showsProgressPanel: Bool = true
    ) throws -> NSPrintOperation {
        let data = try compose(model: model, options: options, printInfo: printInfo, title: title)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw PrintError.emptyPrintJob
        }
        guard
            let operation = document.printOperation(
                for: printInfo, scalingMode: .pageScaleNone, autoRotate: false)
        else {
            throw PrintError.noPrintOperation
        }
        operation.showsPrintPanel = false
        operation.showsProgressPanel = showsProgressPanel
        return operation
    }
}

enum PrintError: LocalizedError {
    case emptyPrintJob
    case noPrintOperation

    var errorDescription: String? {
        switch self {
        case .emptyPrintJob: "The document has no content to print."
        case .noPrintOperation: "The system could not create a print job."
        }
    }
}

extension NSPrintInfo {
    /// `copy()` (documented to return `NSPrintInfo`) without a force
    /// cast at every call site.
    func copied() -> NSPrintInfo {
        // swiftlint:disable:next force_cast
        copy() as! NSPrintInfo
    }
}

/// The Print panel's accessory panel (F-INT-9 options): the mode popup,
/// the header/footer toggles, and — for tiling — the overlap stepper.
/// Plain AppKit controls, labelled for VoiceOver.
@MainActor
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    private let modePopup = NSPopUpButton()
    private let titleCheck = NSButton()
    private let dateCheck = NSButton()
    private let pageNumbersCheck = NSButton()
    private let backgroundCheck = NSButton()
    private let overlapStepper = NSStepper()
    private let overlapValueLabel = NSTextField(labelWithString: "12 pt")

    /// The panel's summary line (the Print dialog's Summary pane).
    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Layout", .itemDescription: modePopup.titleOfSelectedItem ?? ""]]
    }

    /// The panel's state as the print coordinator consumes it.
    var printOptions: PrintOptions {
        var options = PrintOptions()
        switch modePopup.selectedTag() {
        case 1: options.mode = .tile
        case 2: options.mode = .outline
        default: options.mode = .fit
        }
        options.showHeaderTitle = titleCheck.state == .on
        options.showHeaderDate = dateCheck.state == .on
        options.showPageNumbers = pageNumbersCheck.state == .on
        options.includeBackground = backgroundCheck.state == .on
        options.tileOverlap = CGFloat(overlapStepper.intValue)
        return options
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        modePopup.addItems(withTitles: ["Fit to page", "Tile across pages", "Outline print"])
        modePopup.item(at: 0)?.tag = 0
        modePopup.item(at: 1)?.tag = 1
        modePopup.item(at: 2)?.tag = 2
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        stack.addArrangedSubview(labeledRow("Print", modePopup))

        titleCheck.setButtonType(.switch)
        titleCheck.title = "Print title in header"
        titleCheck.state = .on
        dateCheck.setButtonType(.switch)
        dateCheck.title = "Print date in header"
        dateCheck.state = .on
        pageNumbersCheck.setButtonType(.switch)
        pageNumbersCheck.title = "Page numbers in footer"
        pageNumbersCheck.state = .on
        backgroundCheck.setButtonType(.switch)
        backgroundCheck.title = "Print background"
        backgroundCheck.state = .on
        for control in [titleCheck, dateCheck, pageNumbersCheck, backgroundCheck] {
            stack.addArrangedSubview(control)
        }

        overlapStepper.minValue = 0
        overlapStepper.maxValue = 48
        overlapStepper.increment = 4
        overlapStepper.intValue = 12
        overlapStepper.target = self
        overlapStepper.action = #selector(overlapChanged(_:))
        overlapStepper.isEnabled = false
        overlapStepper.setAccessibilityLabel("Tile overlap in points")
        overlapValueLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(
            labeledRow("Tile overlap", overlapStepper, overlapValueLabel))

        view = stack
    }

    /// A labeled row: label on the left, the controls trailing.
    private func labeledRow(_ label: String, _ controls: NSView...) -> NSView {
        let text = NSTextField(labelWithString: label)
        let row = NSStackView(views: [text] + controls)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func modeChanged(_ sender: Any?) {
        let tiled = modePopup.selectedTag() == 1
        overlapStepper.isEnabled = tiled
    }

    @objc private func overlapChanged(_ sender: Any?) {
        overlapValueLabel.stringValue = "\(overlapStepper.intValue) pt"
    }

    // MARK: testing hooks (the controls themselves are private)

    /// Selects the tile mode (the popup's second item) and refreshes the
    /// overlap control state, exactly like a user click.
    func selectTileModeForTesting() {
        modePopup.selectItem(withTag: 1)
        modeChanged(nil)
    }

    /// Sets the tile overlap stepper's point value.
    func setTileOverlapForTesting(_ points: Int) {
        overlapStepper.intValue = Int32(points)
        overlapChanged(nil)
    }
}
