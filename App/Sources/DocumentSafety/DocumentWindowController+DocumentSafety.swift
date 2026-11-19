import AppKit
import MapCore

/// F-DOC (SPEC §5.18) window-side wiring: the read-only banner for
/// documents from a newer app version (F-DOC-4), the scene refresh a
/// revert needs (F-DOC-3's reload path), and menu-item validation for
/// the File menu's safety items (Versions browser, Lock, Duplicate —
/// F-DOC-1) plus the read-only denial of every mutating action.
@MainActor
extension DocumentWindowController {
    /// Installs (or leaves out) the read-only banner. Called from
    /// `showWindow` — read-only state is fixed at open.
    func installReadOnlyBannerIfNeeded() {
        guard let text = (document as? MapDocument)?.readOnlyBannerText else { return }
        guard readOnlyBanner == nil, let contentView = window?.contentView else { return }
        let banner = ReadOnlyBannerView(labelText: text)
        banner.frame = NSRect(
            x: 0, y: contentView.bounds.maxY - ReadOnlyBannerView.height,
            width: contentView.bounds.width, height: ReadOnlyBannerView.height)
        banner.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(banner)
        readOnlyBanner = banner
    }

    /// After a revert (F-DOC-3's reload): the store was replaced behind
    /// the scene's back, so every view of it rebuilds — the canvas, the
    /// outline, the title — keeping the camera where the user left it.
    func refreshAfterRevert() {
        updateScene(preserveCamera: true)
        canvas.pruneSelection()
        outlineController.reloadPreservingSelection()
        window?.title = document?.displayName ?? window?.title ?? ""
    }

    /// §14.1 honest enabling for the F-DOC File items: Versions browser
    /// and revert need a file to revert to; Lock needs an unlocked file
    /// and Unlock a locked one; saves and duplicate refuse on a
    /// newer-format read-only document. Chained from the controller's
    /// single `validateMenuItem`; nil for items that are not F-DOC's.
    func validateDocumentSafetyMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        guard let mapDocument = document as? MapDocument else { return nil }
        switch menuItem.action {
        case #selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:)):
            return !mapDocument.isReadOnlyFormat
        case #selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:)):
            return mapDocument.fileURL != nil
        case #selector(NSDocument.duplicate(_:)):
            // Duplicating a future-format model would mint a copy that
            // claims a version this app can't vouch for — refuse.
            return !mapDocument.isReadOnlyFormat
        case #selector(NSDocument.lock(_:)):
            return mapDocument.fileURL != nil && !mapDocument.isLocked
        case #selector(NSDocument.unlock(_:)):
            return mapDocument.isLocked
        default:
            return nil
        }
    }

    /// The read-only denial (F-DOC-4, ADR-0023): while the store is
    /// locked, every MUTATING action is honestly disabled — editing,
    /// moving, folding, studying, slides authoring, clipboard writes.
    /// Non-mutating items fall through (nil). The store gate remains
    /// the enforcement; this is menu truth-telling.
    func validateReadOnlyMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        guard let mapDocument = document as? MapDocument, mapDocument.store.isReadOnly else {
            return nil
        }
        switch menuItem.action {
        case #selector(addChildAction(_:)), #selector(addSiblingBelowAction(_:)),
            #selector(addSiblingBelow(_:)), #selector(addSiblingAboveAction(_:)),
            #selector(insertParentAction(_:)), #selector(addRootAction(_:)),
            #selector(editTitleAction(_:)),
            #selector(deleteSubtreeAction(_:)), #selector(deleteNodeOnlyAction(_:)),
            #selector(reorderUpAction(_:)), #selector(reorderDownAction(_:)),
            #selector(promoteAction(_:)), #selector(demoteAction(_:)),
            #selector(duplicateAction(_:)), #selector(detachAction(_:)),
            #selector(toggleFoldAction(_:)), #selector(foldWithSiblingsAction(_:)),
            #selector(unfoldOneLevelAction(_:)), #selector(showLevelsAction(_:)),
            #selector(makeStudyDeckAction(_:)), #selector(setCardPolicyAction(_:)),
            #selector(makeClozeAction(_:)),
            #selector(NSText.cut(_:)), #selector(NSText.paste(_:)):
            return false
        default:
            return nil
        }
    }
}

/// The F-DOC-4 banner: a hairline material strip across the window's
/// top with the lock icon and the one-line explanation. VoiceOver reads
/// it as a static text.
@MainActor
final class ReadOnlyBannerView: NSView {
    static let height: CGFloat = 34

    init(labelText: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: Self.height))

        let material = NSVisualEffectView(frame: bounds)
        material.material = .titlebar
        material.blendingMode = .withinWindow
        material.autoresizingMask = [.width, .height]
        addSubview(material)

        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let label = NSTextField(labelWithString: labelText)
        label.font = .controlContentFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        setAccessibilityRole(.staticText)
        setAccessibilityLabel(labelText)
    }

    required init?(coder: NSCoder) {
        nil
    }
}
