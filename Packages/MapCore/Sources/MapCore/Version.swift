import Foundation

/// Arbor on-disk document format version (SPEC §8). Version 2 added
/// `Node.paletteIndex` (the persistent branch palette index, ADR-0009);
/// `Migrations.v1ToV2` back-fills it positionally for existing files.
/// Version 3 added three OPTIONAL fields — `NodeStylePatch.fontWeight`
/// and `NodeStylePatch.minWidth` (F-STY-2 text weight / min node width)
/// and `ThemePatch.rainbowBranches` (F-STY-8's toggle as a document
/// override) — so `Migrations.v2ToV3` has nothing to back-fill: older
/// files decode with `nil` and keep rendering exactly as before; the
/// step only stamps the version so a save writes current-format files.
public enum ArborFormat {
    public static let formatVersion = 3
}
