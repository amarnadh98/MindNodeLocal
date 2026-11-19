# Theme screenshots (M2 exit criterion)

One PNG per built-in theme, light and dark — the M2 exit-criterion
screenshot set (SPEC §16 "a designer-quality screenshot set (each
theme, light/dark)").

**These are not mockups.** They are produced by
`App/Tests/ThemeScreenshotTests`, which renders the sample tour map
through the SAME `SceneGeometry` + `SceneRenderer` pair the canvas,
PDF/PNG/SVG export, Quick Look previews and the theme editor's live
preview draw with. The sandboxed test host writes them to its
container's Application Support and prints the path; the committed
copies came from that run:

```sh
xcodebuild -scheme Arbor -destination 'platform=macOS' test \
  -only-testing ArborTests 2>&1 | grep "THEME SCREENSHOTS"
# then copy the printed directory's PNGs over this one
cp "$SCREENSHOT_DIR"/*.png docs/design/themes/
```

Re-run and re-copy whenever a theme or the renderer changes — the test
fails if any theme stops rendering, so the set cannot drift silently.
