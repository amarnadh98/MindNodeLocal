# ADR 0009: read-only zip via Apple's Compression framework instead of ZIPFoundation

Date: 2026-11-19
Status: accepted

## Context

SPEC §11.1 lists ZIPFoundation as a planned runtime dependency, and
SPEC §5.17 mentions "Zip (ZIPFoundation)" for XMind import. The M5 IO
slice only needs to *read* archives: the formats that arrive as zips
(`.xmind`, later `.itmz`) are import-only, and no M5 export produces a
zip (TextBundle export, a later slice, would be the first writer).
The dependency budget is 8 runtime dependencies (SPEC §11.1), each
requiring an ADR.

## Decision

Do **not** add ZIPFoundation for M5 slice 1. Read zips with a small
in-house reader, `MiniZip` in `Packages/MapIO/Sources/MapIO/MiniZip.swift`:

- ZIP reading needs only the End-of-Central-Directory record, the
  central directory and local file headers — ~150 lines of
  bounds-checked parsing.
- Both compression methods every producer writes are supported:
  stored (method 0) and raw DEFLATE (method 8). Apple's `Compression`
  framework decodes raw DEFLATE: its `COMPRESSION_ZLIB` is raw
  DEFLATE without the zlib wrapper, which is exactly what a ZIP entry
  stores. No third-party code is involved.
- Every entry is CRC-32-verified; any structural damage throws —
  malformed archives are an expected input and must never crash an
  importer.
- ZIP64 archives (> 4 GiB) and exotic methods throw
  `unsupportedCompression`; no mind-map file in practice needs them.

## Consequences

- The dependency count stays under budget for this milestone.
- Writing zips is *not* implemented. When TextPack/TextBundle export
  (SPEC §5.17, P1) or any other zip-writing feature lands, that slice
  should either add ZIPFoundation (with its own ADR, covering the
  write path: headers, CRC, streaming) or extend MiniZip with a writer
  — decided there, with real requirements in hand.
- `MiniZip` is deliberately minimal and internal to `MapIO`; if import
  needs grow (encryption, zip64), revisit rather than accrete.
