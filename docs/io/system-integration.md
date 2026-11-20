# System integration: Quick Look + Spotlight extensions (F-INT-2/3) and how to verify them

SPEC §5.16 ships three app-extension targets alongside the app:

| Target | Extension point | What it does |
|---|---|---|
| `QuickLookThumbnail` | `com.apple.quicklook.thumbnail` | `QLThumbnailProvider`: the stored `QuickLook/Thumbnail.png` when fresh and large enough (downscaled to the request), else a headless re-render from `map.json` at the requested size |
| `QuickLookPreview` | `com.apple.quicklook.preview` | View-based `QLPreviewingController` showing the stored `QuickLook/Preview.pdf` when fresh, else a fresh render, in an auto-scaling `PDFView` |
| `SpotlightImporter` | `com.apple.spotlight-importer` | `CSImportExtension`: indexes the title, every node title and note (`textContent`), tag names (`keywords`), and the created/modified dates from `meta.json` |

All three link the **`SystemIntegration`** product (CanvasKit package,
ADR-0029) — the same pure code the app's save path and the tests use —
plus its `MapCore`/`MapRender`/`SceneExport` graph. They never link the
app's canvas code.

## UTI registration

- The app's exported UTI `com.arbor.map` conforms to
  `com.apple.package` **and `public.composite-content`** — the latter so
  the file is "content" Quick Look/Spotlight will bother with, not an
  opaque bundle.
- The Quick Look targets declare `QLSupportedContentTypes:
  [com.arbor.map]`; the Spotlight importer declares the type in its own
  `CFBundleDocumentTypes` (`LSItemContentTypes`, `LSTypeIsPackage`).

## How to verify locally

`qlmanage` and `mdimport` talk to the SYSTEM's registered extension
database, not to a build directory, so verification has two stages.

1. **The extension's logic, directly** (works everywhere, no
   registration needed):

   ```sh
   # thumbnail: renders via the same code the extension runs
   qlmanage -t -s 512 -o /tmp /path/to/Fixture.arbor

   # full preview window
   qlmanage -p /path/to/Fixture.arbor

   # Spotlight attributes, with debug output from the importer
   mdimport -d2 /path/to/Fixture.arbor
   ```

   With the app in `/Applications` (or `~/.t3`-style daily use),
   properly signed (Developer ID or a Personal Team build you launched
   once), these show the extension output. With an **ad-hoc signed
   debug build** they fall back to what `qlmanage` itself can do with
   the raw package, which for a *package* (directory) is usually the
   generic folder/file listing — see the honest results below.

2. **Whether the extensions registered with the system at all:**

   ```sh
   pluginkit -m -p com.apple.quicklook.thumbnail
   pluginkit -m -p com.apple.quicklook.preview
   pluginkit -m -p com.apple.spotlight-importer
   ```

   Each line should show the extension's bundle id with a `+` (enabled).
   `pluginkit -vvvv -m -i <bundle-id>` dumps the registration detail.

   After moving/copying a fresh build over an installed app, run
   `pluginkit -a /path/to/Arbor.app` and `qlmanage -r` (reset the QL
   daemon cache) so the system rescans.

## Honest status on this machine (ad-hoc signing)

This slice was developed under the local ad-hoc / debug signing, exactly
the SPEC §13 distribution path B warning: *"Extensions may not
register."* Results of the actual verification runs are recorded at the
bottom of this file — check the dated section rather than assuming.

What is **verified by tests** regardless of registration (all in
CI-able form):

- The stored-vs-render thumbnail choice (fresh/stale/missing, request
  larger than the stored 512 px) — `SystemIntegrationTests`.
- The rendered payloads' contract: PNG at 512 px long edge, 1-page
  vector preview PDF — `SystemIntegrationTests` and the hosted save
  tests.
- Spotlight attribute extraction from a fixture package: title, all node
  titles + notes in document order, tag names, dates, unicode (CJK +
  emoji) — `SpotlightRecordTests`.
- The extensions compile and link `SystemIntegration` headlessly (the
  Xcode build covers this).

---

## Verification log

### 2026-11-19 (ad-hoc debug + release builds, local machine)

Builds: the Debug build (`/tmp/arbor-dd-ql`) and `scripts/release/build-app.sh
--adhoc` both embed all three `.appex` bundles in `PlugIns/` — the archive's
`codesign --verify --deep --strict` passes for the app AND each extension
(ad-hoc signature, `com.example.arbor.*` bundle ids).

`qlmanage` on a sample `.arbor` (a hand-built package from the MapCore
migration fixture): **`qlmanage -r` works** (reset quicklookd), but
`qlmanage -t` and `qlmanage -p` **hang on this machine for ANY package
type** — a plain `.docx` and a bare directory-based `.xmind` hang
identically (the ThumbnailsAgent spins in `CFURLResolveBookmarkData`
loops; flat files like `.txt` thumbnail fine), so this is a local
quicklookd-state issue, not Arbor's extension. `pluginkit -m` lists no
Arbor extension registered either way — the expected SPEC §13 path-B
behaviour for untrusted ad-hoc signatures.

What IS proven on this machine, without the system registration dance:
a harness executed **the exact functions the appex shells call** —
`ArborPreviewRenderer.thumbnailImage(at:maximumPixelSize:scale:)` and
`ArborPreviewRenderer.previewPDF(at:)` — against the sample package:
a **1024×463 PNG** (1,508 non-white colors — the Paper-theme canvas
with nodes and branches rendered) and a **1-page 19 KB vector PDF**.
The extension targets link this same `SystemIntegration` product, so
the render code the extensions run is verified end to end; what remains
unverifiable without a trusted signature is only pluginkit registration
itself (re-verify under Developer ID / Personal Team signing when
distribution happens, SPEC §13 path A — see "How to verify locally"
above).

`mdimport -t -d2` on the same sample: the file resolves as
**`com.arbor.map`** with the full type tree (`com.apple.package`,
`public.directory`, `public.composite-content`) — the app's UTI
declaration is live through LaunchServices — and imports "with no
plugIn", the honest ad-hoc-build result: the SpotlightImporter is not
registered, so attribute extraction is verified by the same
`SpotlightRecordTests` the importer maps from.
