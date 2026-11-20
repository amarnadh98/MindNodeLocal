# ADR-0029: print == export via a composed paper-sized PDF, and a shared `SystemIntegration` target

- **Status:** accepted
- **Date:** 2026-11-19

## Context

The M5 system-integration slice adds three things at once (SPEC §5.16):

- **F-INT-9 Print** (P0): ⌘P with fit-to-page / tile-across-pages /
  outline modes, header/footer, Page Setup — and the standing rule that
  the canvas, export and Quick Look all share one renderer.
- **F-INT-3's Quick Look extensions** (P1): `QLThumbnailProvider` and
  `QLPreviewingController` app-extension targets that must render a
  package headlessly — they cannot link the app's canvas code, but the
  render path must be identical to what a save writes.
- **F-INT-2's Spotlight importer** (P1): `CSImportExtension` over a
  headless package parse.

Each has a pure, testable core (pagination math, the stored-vs-render
thumbnail choice, attribute extraction) and a thin AppKit/AppExtension
shell. The spec is silent on where that core lives and on how printing
reaches paper.

## Decision

1. **A `SystemIntegration` target inside the CanvasKit package**
   (alongside `SceneExport`, the same shape as ADR-0012) holds the pure
   core: `PackagePreviews`/`ArborPreviewRenderer` (the Quick Look
   choice + render fallbacks), `SpotlightMetadata` (record extraction),
   and `PrintPagination`/`PrintComposer` (math + composed PDF). It
   depends on `SceneExport` + `MapCore` + `MapRender`, imports no
   AppKit of its own, and builds and tests with `swift test`. The app's
   save path (`DocumentQuickLook`), the three extension targets and the
   hosted tests all call the one implementation.

2. **Printing composes, then prints.** `PrintComposer` renders the job
   as a paper-sized vector PDF through the same `ScenePainter` shared
   primitives every export uses (print == export), with the F-INT-9
   furniture: header/footer bands (title, date, "page x of y"), the tile
   grid with dashed overlap marks, and the paginated text outline. The
   app prints those bytes through PDFKit's
   `PDFDocument.printOperation(for:scalingMode:autoRotate:)` at
   `.pageScaleNone` — the pages already ARE the paper size the Print
   panel and Page Setup chose (`NSPrintInfo.paperSize` /
   `imageablePageBounds`, which already carry orientation). The
   accessory panel is a plain-AppKit `NSViewController` conforming to
   `NSPrintPanelAccessorizing`.

3. **Print renders the light appearance.** Paper is white; a dark
   canvas background would spend a sheet of ink on nothing. The
   document's explicit dark mode stays on screen and in file exports.

4. **Tile pages are filtered, not clipped-whole.** Each printed tile
   page draws only the nodes and branches intersecting its slice
   (`ExportScene` gained a public initializer for that), so a huge map
   in tile mode costs one page's working set per page, not the whole
   scene per page.

5. **Extension targets link only SystemIntegration** (+ its
   MapCore/MapRender/SceneExport graph) — never the app or the canvas
   view layer. `PreviewProvider` uses a `@preconcurrency` conformance to
   the unannotated ObjC `QLPreviewingController` (its own header
   documents the main-thread call); the Spotlight importer implements
   the SDK's renamed `update(_:forFileAt:)`.

## Consequences

- One render path: a save's `QuickLook/Thumbnail.png`,
  `QuickLook/Preview.pdf`, the extensions' fallbacks and the printed
  page are all drawn by the same scene code — a rendering fix lands in
  all four places at once.
- The print tests can assert page counts as pure math (`tileGrid`,
  `paginateOutline`) and the full spool contract (the real
  `NSPrintOperation`, its save disposition and `NSPrintJobSavingURL`,
  and the composed bytes written and read back as a file). The one
  step deliberately NOT exercised headlessly is Apple's daemon
  delivery: `operation.run()` with a save disposition was
  harness-verified to block indefinitely when the print backend is
  unreachable (a plain PDFKit job hangs the same way — `printToolAgent`
  never answers; no printers needed), so a hosted `run()` would hang
  the suite on such machines instead of failing honestly.
- PDFKit owns the last mile (dialog, spooling, printer features), so
  Page Setup and the panel's paper/orientation controls work because
  they genuinely drive `NSPrintInfo`, which is what the composer reads.
- Known limits: tile overlap marks are dashed guides (no scissors
  glyph), and the composed PDF is also what lands in the spool file —
  fine for Preview/printing, not a bookmarks-bearing document PDF (that
  is what File ▸ Export… PDF is for).

Related: ADR-0012 (`SceneExport`), ADR-0013 (⌘P stays Print; Quick
Open ⇧⌘O — the conflict this slice's File ▸ Print… binding follows).
