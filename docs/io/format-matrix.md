# Import/export format matrix (M5, F-IO)

Per-format field matrix for the document-level importers/exporters in
`Packages/MapIO`. Every importer runs the result through
`MapRepairer`, so imported documents always pass `MapValidator`.
Round-trip tests compare an export→import against the source *modulo
exactly the fields listed here* (see the `for…()` transforms in
`MapIOTests/IOTestHelpers.swift`).

## Fields

| Field | OPML 2.0 | Markdown | Plain text | FreeMind `.mm` | XMind (in) | MindNode (in) |
|---|---|---|---|---|---|---|
| Hierarchy (multi-root) | ✓ | ✓ | ✓ | ✓ | ✓ (sheets → roots) | ✓ |
| Titles | flat | §8.3 runs | flat | flat | flat | flat |
| Notes | ✓ (`_note`) | ✓ (indented paragraphs) | – | ✓ (`richcontent`, HTML flattened) | ✓ | ✓ |
| Tasks | done/due/priority | done only (`- [ ]`/`- [x]`) | – | done/due/priority (`button_ok` + `arbor-*` attributes) | done (task markers) | done/due |
| Tags | names (`arbor:tags`) | – | – | names (`arbor-tags` attribute) | labels → names | names |
| Structure | ✓ (`arbor:structure`) | – | – | ✓ (`arbor-structure` attribute) | structure classes | ✓ |
| Folded | ✓ (`arbor:folded`) | – | – | ✓ (`FOLDED`) | – | ✓ |
| Side pins | – | – | – | ✓ (`POSITION`, level 1) | – | – |
| Links | – | – | – | ✓ (`LINK`) | – | – |
| Connections | – | – | – | ✓ (`arrowlink`, no label) | ✓ (relationships, with label) | ✓ (cross connections) |
| Boundaries | – | – | – | – | ✓ (JSON path only) | – |
| Summaries | – | – | – | – | ✓ (JSON path; summary node synthesized when the file has none) | – |

"–" means the field is dropped on export/import; the round-trip tests
assert that.

## Lossy fields (dropped in both directions)

Fields no exchange format carries — every one of them is lost on any
non-native round trip: images, attachments, style overrides, offsets,
width settings, numbering, markers, study/FSRS state, presentations,
fields, and the document's theme/appearance/view state.

Per format beyond the table above:

- **OPML 2.0**: inline title runs (titles export flat); task
  `repeat`/`reminderID`; tag colors (imported tags get
  `DocumentAssembler.defaultTagColor`); blank lines inside notes are
  preserved via `&#10;`, but arbitrary formatting inside `_note` is not.
- **Markdown**: task due/priority; connections; blank lines inside
  notes collapse (paragraphs are trimmed and joined with `\n`);
  underline/color/highlight/font/size runs are outside the §8.3
  markdown subset; task nodes below heading depth force their whole
  subtree into list mode (a deliberate rule — a heading cannot carry
  `- [ ]`).
- **Plain text**: everything but hierarchy and flat titles.
- **FreeMind**: connection labels (arrowlinks carry none); imported
  note HTML is flattened to plain paragraphs (bold/italic inside notes
  is lost); FreeMind icons other than `button_ok`; edge/cloud/folder
  styling; blank lines inside notes.
- **XMind** (import only): topic ids (fresh Arbor ids are assigned);
  callout topics; sheet titles; floating/detached positions (detached
  topics of a sheet root become their own Arbor roots); XMind styling
  (colors, borders, shapes, number stamps, legends); boundaries and
  summaries in the legacy Xmind 8 `content.xml` path are dropped
  (topics, notes, labels, task markers and relationships map);
  relationships between topics on different sheets are dropped.
- **MindNode** (import only, best effort): node uuids; images;
  per-node style overrides; MindNode layout state; tag colors;
  anything in the plist the tolerant key extraction does not
  recognize. Unknown plist versions fail with a clear error whose
  documented fallback is: export OPML from MindNode and import that.

## Fixture provenance

The fixtures under `Packages/MapIO/Tests/MapIOTests/Fixtures` are
**constructed from the publicly documented structures** of each format;
no real third-party files were downloaded (the SPEC §14 wish of
"real-world fixture files" remains open for MindNode/XMind until
someone contributes real samples). In particular:

- `xmind/sample.xmind` and `xmind/legacy.xmind` are genuine zip
  archives (DEFLATE `content.json`/`content.xml` + stored
  `metadata.json`, built with `/usr/bin/zip`) following the Xmind 2020
  JSON and Xmind 8 XML layouts.
- `mindnode/contents-v9.xml` is a hand-written XML rendering of the
  documented binary-plist layout; `mindnode/contents-v9.plist` is the
  same document converted to a real binary plist with `plutil`. The
  MindNode importer reads key names tolerantly (several spellings per
  field) because the exact keys could not be verified against a real
  file.
