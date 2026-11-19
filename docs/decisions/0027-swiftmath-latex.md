# ADR-0027: SwiftMath for LaTeX rendering

- **Status:** Accepted
- **Date:** 2026-11-19
- **Satisfies:** SPEC §5.4 F-CNT-5 (LaTeX in titles and notes, "rendered natively via SwiftMath (MIT, Core Graphics-based)"), §11.1 (dependencies ≤ 8)

## Context

M3 (SPEC §16) ships node content: F-CNT-5 wants `$…$`/`$$…$$` LaTeX in node titles and note blocks, rendered so it **exports as vector** (the node title's pixels must come from the same `NodeRenderer` the canvas, export and Quick Look share — SPEC §11).

Options considered:

1. **Hand-roll a math typesetter** in MapRender (Core Text glyph layout for fractions, radicals, sub/superscripts, big operators). A correct TeX-style engine is thousands of lines (fraction stacks, delimiter stretching, operator limits) — far beyond M3's slice budget, and every layout rule would be Arbor's own untested math.
2. **MathJax/KaTeX via a web view** — banned by SPEC §1 ("never feel like a web app") and the no-WKWebView stance of §11.
3. **SwiftMath** (`https://github.com/mgriebling/SwiftMath`, MIT) — a maintained pure-Swift port of iosMath: a real TeX-algorithm typesetter (`MTMathListBuilder` parser with error reporting, `MTTypesetter`, GUST Latin Modern + 11 other bundled math fonts), drawing through Core Graphics/Core Text, macOS 12+, zero transitive dependencies, resource-only font bundles.

SPEC §11.1 already names SwiftMath in the SPM dependency list.

## Decision

1. **Add SwiftMath** (SPM, `from: "1.7.0"`) as a dependency of the **`CanvasKit` package** (dependency 2 of 8; Sparkle is 1). No other package links it: `MapCore`/`MapLayout`/`MapRender`/`MapIO`/`MapStudy` stay dependency-free, and the pure **SceneExport** target never imports it — exports consume already-rendered rasters/glyphs through the scene.
2. **The seam:** `MapRender.NodeRenderer` draws math through a `MathGlyph` value (size + a draw closure) carried in `NodeMedia`. `CanvasKit`'s `MathImageCache` (App layer wiring file, AppKit) renders via SwiftMath's `MTMathImage` API and hands the scene builder `MathGlyph`s; a **parse error returns nil and the node renders the LaTeX source text** — F-CNT-5's fallback, so no document is ever unrenderable.
3. **Caching (the §11.8 keystroke path):** rendered glyphs are cached by (latex, font size, tint) — a scene build only pays a dictionary lookup after the first render; the fallback measurement is the plain `TextMeasurer` path.
4. **Where it renders:** node titles (draw + measured through the glyph), note previews (`$$…$$` blocks and `$…$` inline → `NSImage`), PDF/PNG export (the shared `NodeRenderer` path), and SVG export (the raster embedded as an ImageIO data URI — SwiftMath rasters, so SVG's math is embedded, not vector; stickers and text stay true vectors there).

## Consequences

- Titles with `math: true` measure through the glyph size (an input to `SceneBuildCache.SizeKey`), so an incremental rebuild reuses the cache.
- The MIT license and the bundled GUST/OFL font licenses are compatible; the font bundles ride inside SwiftMath's resources with `defaultLocalization: en`.
- `swift test --package-path Packages/CanvasKit` now resolves one remote dependency (cached after first clone).
- Dependency budget after this ADR: 2 of 8.
