import Foundation

/// Arbor on-disk document format version (SPEC §8). Version 2 added
/// `Node.paletteIndex` (the persistent branch palette index, ADR-0009);
/// `Migrations.v1ToV2` back-fills it positionally for existing files.
/// Version 3 added the optional `MapModel.ai` policy object (the
/// per-document "Never send to cloud AI" flag, SPEC §12/F-AI-1) and
/// `Node.note` editing (`setNote`); both are optional, so
/// `Migrations.v2ToV3` only stamps the version.
/// Version 4 added four OPTIONAL fields — `NodeStylePatch.fontWeight`,
/// `NodeStylePatch.fontItalic` (F-STY-2 text weight/italic),
/// `NodeStylePatch.minWidth` and `ThemePatch.rainbowBranches` (F-STY-8's
/// toggle as a document override, ADR-0028) — so `Migrations.v3ToV4`
/// has nothing to back-fill: older files decode with `nil` and keep
/// rendering exactly as before; the step only stamps the version so a
/// save writes current-format files.
public enum ArborFormat {
    public static let formatVersion = 4
}
