import Foundation

/// Finds `.arbor` packages inside a folder (F-LIB-1: maps are ordinary
/// files anywhere on disk). Shallow scan, hidden files skipped, package
/// interiors not descended into.
public enum PackageScanner {
    public static func packages(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        guard let enumerator else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true, url.pathExtension.lowercased() == "arbor" else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }
}
