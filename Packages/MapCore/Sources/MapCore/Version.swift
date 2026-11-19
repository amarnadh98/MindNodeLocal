import Foundation

/// Arbor on-disk document format version (SPEC §8). Version 2 added
/// `Node.paletteIndex` (the persistent branch palette index, ADR-0009);
/// `Migrations.v1ToV2` back-fills it positionally for existing files.
public enum ArborFormat {
    public static let formatVersion = 2
}
