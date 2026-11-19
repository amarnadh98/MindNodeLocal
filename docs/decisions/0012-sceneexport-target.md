# ADR-0012: a dedicated `SceneExport` target for the scene exporters

Date: 2026-11-19
Status: accepted

## Context

M5 slice 2 adds the scene exporters behind SPEC §5.17/§5.16: vector
PDF (with document outline), PNG/JPEG/HEIC rasters, and the hand-written
SVG emitter, plus the Quick Look payloads (F-INT-3). They must be "pure"
— CoreGraphics/CoreText/PDFKit only, no AppKit — and they must render
through the same `TextMeasurer`/`NodeRenderer`/`BranchPath` primitives
the canvas uses.

The scene types they consume (`CanvasScene`, `SceneNode`,
`SceneBranch`) and the scene builder (`SceneGeometry`) live in
`CanvasKit`, which imports AppKit for the view layer. Moving those types
out (to `MapRender`) would have touched `SceneGeometry`, whose internals
other M5 slices are reworking concurrently (incremental relayout,
themes), so that refactor is off the table for this slice.

## Decision

Add a **`SceneExport` target inside the `CanvasKit` package** (not a new
package, and no code in the `CanvasKit` target itself):

- It depends on `CanvasKit` (for the scene types and the shared
  measurer), `MapCore` and `MapRender`, and imports only
  CoreGraphics/CoreText/ImageIO/PDFKit/Foundation in its own files — no
  AppKit usage of its own, so it builds and tests headless via
  `swift test`.
- The App target and future system extensions (the P1
  `QuickLookThumbnail`/`QuickLookPreview` extension targets, the
  Spotlight importer) link `SceneExport` alone — without dragging in
  the canvas view layer they will never display.
- Everything lives in new files under
  `Packages/CanvasKit/Sources/SceneExport/`; shared files were touched
  only for the target declaration and small, clearly separated registry
  additions.

Two runtime quirks discovered while building this are worth recording:

- **PDF outlines**: CGPDFContext cannot author document outlines, and
  PDFKit silently *drops* an outline set on a `PDFDocument` loaded from
  bytes. The exporters therefore reopen their CGPDF output, copy the
  pages into a fresh `PDFDocument`, graft the outline there and write
  its `dataRepresentation`.
- **Giant rasters**: ImageIO has no tile-compositing API (every
  `CGImageDestinationAddImage` adds another frame), so a >16k-px export
  renders clipped tiles into one lazily-committed anonymous `mmap`
  bitmap — committed memory follows the content, not the canvas — and
  assembles the single image via `CGImageDestination` while the buffer
  is alive.

## Consequences

- The exporter surface is extension-linkable the day the Quick Look P1
  targets land; they should call `ImageExporter`/`PDFExporter` directly
  (they already do exactly what the in-app save writes).
- `CanvasScene` remaining in the AppKit-importing `CanvasKit` target
  keeps a small AppKit transitive link in SceneExport's dependency
  graph. If a later refactor moves the scene structs down to
  `MapRender`, SceneExport loses that edge with no call-site changes.
- Bookmarked PDFs make one extra PDFKit round trip; unbookmarked ones
  stay pure CGPDF.
