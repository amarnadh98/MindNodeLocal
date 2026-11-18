import Foundation

public enum ArborError: Error, Sendable, Equatable, Hashable {
    case unsupportedFormatVersion(found: Int, expected: Int)
    case missingPackageEntry(String)
    case notAPackage(URL)
    case invalidMapJSON(String)
    case invalidMetaJSON(String)
    case validationFailed([ValidationError])
}
