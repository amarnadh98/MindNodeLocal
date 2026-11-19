# Quick Look previews in the `.arbor` package (F-INT-3)

SPEC §5.16 F-INT-3 requires every `.arbor` package to carry its own
previews so Finder and Quick Look can show a map without opening it:

```
My Map.arbor/QuickLook/
├── Thumbnail.png   # 512 px on the long edge
└── Preview.pdf     # whole-map vector preview
```

## What this slice writes

Both files are regenerated on **every explicit save** (⌘S/Save As —
including the app's hosted tests' `write(to:)`), rendered by the same
`SceneExport` path the File ▸ Export… sheet uses:

- `Thumbnail.png` — `ImageExporter`, PNG, `targetLongEdgePixels: 512`,
  opaque canvas background, in the document's current appearance
  (explicit `appearance` override wins; `auto` follows the frontmost
  window's effective variant, else light).
- `Preview.pdf` — `PDFExporter`, whole map, background on, bookmarks
  off (a preview needs the vector content, not navigation).

Autosaves **skip** both: the SPEC §11.8 autosave budget is 2 ms on the
main thread and a scene render cannot fit there. The previews refresh
on the next explicit save. `MapDocument` detects the autosave case by
recording the `NSSaveOperationType` in its `writeSafely` override
(NSDocument exposes no direct "is autosaving" query).

Measured on the 5k fixture (Debug build, M-series CI hardware):
Quick Look render ~0.5 s, full explicit save ~1.0 s. Release numbers
are roughly an order lower; both sit far from anything a user notices
on ⌘S.

## Out of scope (P1, next slice)

The **extension targets** — `Extensions/QuickLookThumbnail`
(`QLThumbnailProvider`) and `Extensions/QuickLookPreview`
(`QLPreviewingController`) — are deliberately not part of M5 slice 2.
Until they land, Finder falls back to the package's generic folder
icon and Quick Look to the raw file listing; the payloads they need
are already in place (this directory's two files), so the extensions
can be pure, small, rendering-only targets that link `SceneExport`.
