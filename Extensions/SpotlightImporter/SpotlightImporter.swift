import CoreSpotlight
import Foundation
import MapCore
import SystemIntegration

/// F-INT-2: the Spotlight importer app extension (`CSImportExtension`)
/// for `com.arbor.map` packages. Parsing is headless through
/// `ArborPackage.read` (MapCore) and the pure `SpotlightMetadata`
/// extraction shared with the tests; this class only maps the record
/// onto the Core Spotlight attribute set.
final class SpotlightImporter: CSImportExtension {
    // The SDK imports `updateAttributes:forFileAtURL:error:` under its
    // Swift 3 rename `update(_:forFileAt:)`, throwing.
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        let contents = try ArborPackage.read(at: contentURL)
        let fileDate =
            (try? FileManager.default.attributesOfItem(atPath: contentURL.path))?[.modificationDate]
            as? Date
        let record = SpotlightMetadata.record(
            model: contents.model, meta: contents.meta, fileModificationDate: fileDate)
        attributes.title = record.title
        attributes.textContent = record.textContent
        attributes.keywords = record.keywords.isEmpty ? nil : record.keywords
        attributes.authorNames = record.authors
        attributes.contentCreationDate = record.contentCreationDate
        attributes.contentModificationDate = record.contentModificationDate
    }
}

/// The importer's mirror of `AppIdentity.documentUTI` (SPEC §11.9):
/// extensions cannot link the app target, so the UTI string lives here
/// too — the project's Info.plists keep the two honest. The extension
/// only ever receives files of this type (declared in its Info.plist
/// CFBundleDocumentTypes), so no per-call type check is needed.
enum ArborImporter {
    static let documentUTI = "com.arbor.map"
}
