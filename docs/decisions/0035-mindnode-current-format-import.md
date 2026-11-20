# ADR 0035: importing the current MindNode format (protobuf `Contents.data`)

Date: 2026-11-20
Status: accepted

## Context

SPEC §5.17 documents the `.mindnode` import as "Package; `contents.xml`
is a binary plist v9" — true for MindNode 1-2. Real MindNode 2026
(`exportAppVersion` 2026.7.2) writes something else entirely, and
opening such a file showed only "Import failed". One real file was
available for study (`My own thought 1.mindnode`, read-only; a copy
was inspected under `/tmp` and **nothing from it is committed**):

- a **stored zip** (no compression), not a directory package;
- `Metadata.json`: `exportAppVersion`, `fileFormatVersion: 1`,
  `minFileFormatVersionForReading: 1`, `originalDocumentID`;
- `Contents.data`: 2915 bytes of **binary protobuf wire format** —
  no `.proto` schema exists publicly, and SPEC §11.1's dependency
  budget rules out SwiftProtobuf for decoding it.

The format is undocumented. Everything below was reverse-engineered
from that one sample: a generic wire-format dump (field numbers and
wire types, UUID payloads rendered as 8-4-4-4-12, doubles decoded as
IEEE-754) plus a Vision-framework OCR of the file's own
`Preview_fullSize_light.jpeg` to cross-check the visible map.
MindNode may change any of this in a future release — which is
exactly what `Metadata.json`'s `minFileFormatVersionForReading` gate
is for.

## Decision

Decode it in-house, in three pieces, all inside `MapIO` (no AppKit,
per SPEC §11.2; no new dependencies):

1. **`ProtobufWire`** — a small, strict, fully bounds-checked protobuf
   wire reader: varint / fixed32 / fixed64 / length-delimited only.
   Groups (wire types 3/4) and invalid wire types (6/7) are refused,
   field number 0 is refused, varints longer than 10 bytes are
   refused, declared lengths beyond the buffer are refused, and
   per-message field counts and total sizes are capped. Length-
   delimited payloads keep their raw bytes *and* carry the parsed
   nested fields when they parse cleanly — a string that happens to
   look like a message is never destroyed. Recursion is bounded by a
   depth cap (fields at the cap stay opaque bytes), so a nesting bomb
   can neither overflow the stack nor spin. Fuzz and truncation tests
   hammer it with thousands of random buffers.

2. **`MindNodeCurrentFormat`** — the schema decode, summarized below
   with what is **confirmed** (semantic proven by the sample: the
   decoded outline matches the file's own preview image and the
   MindNode outline the user reported) versus **guessed** (plausible
   but unverifiable from one sample) versus **ignored**.

   | Path | Meaning | Status |
   |---|---|---|
   | `1` → document, `1` | document UUID (= `Metadata.json`'s `originalDocumentID`) | confirmed |
   | `1` → document, `2` → wrapper, `1` | node store | confirmed |
   | store, repeated `2`, `1` | node UUID (map key) | confirmed |
   | store, repeated `2`, `2`, `11` → `1` → `4` → `1` | node title UTF-8 (empty container = untitled node) | confirmed |
   | store, repeated `2`, `2`, `2` | node note, same string shape as the title (accepted wrapped or bare) | **guessed** — empty in the sample, so unverifiable |
   | store, `3` (tree), `1` | the document UUID again (root container subject) | confirmed |
   | tree, repeated `2` | one record per subject: `1` subject UUID, `2` parent UUID, repeated `3` children **in order**, `4` branch style | confirmed (structure + order) |
   | tree, repeated `3` (container level) | detached node UUIDs | **interpreted** — see below |
   | tree, repeated `4` | top-level branch list (mirrors the root's children) | confirmed redundant, ignored |
   | node data `5` (two doubles), `6`/`10`, `7`, `9`, `12`, `13`; store `4`; store `5` (sticker with RGBA color); document wrapper `2` (32-byte digest), `3` (timestamp + peer) | position/size/style/session state | ignored |

   **The detached list:** the sample's tree container lists three
   UUIDs at container level; all three are empty-title nodes that
   also appear as tree children, and excluding exactly those three
   reproduces the outline MindNode itself shows for this document
   (the user's description of their map matches the result node for
   node). The likeliest readings are "floating/soft-removed nodes
   kept out of the outline" or "recoverable deletions"; the exact
   semantics are unconfirmed. Arbor excludes them from the import,
   and the titled node the user calls "a floating text on 2c"
   ('3t6782t2') is a normal attached child of '2c' in the tree and
   imports as such.

   **What this format does not yet map:** notes (guessed path only),
   tasks, tags, folding, links and cross connections — no sample data
   could confirm any of their field numbers, so none are extracted.
   The legacy plist importer (MindNode 1-2) keeps its richer mapping.

3. **Routing and gating** (`MindNodeIO.importDocument(archive:)`):
   the importer sniffs the bytes — a zip with `Contents.data` goes to
   the current path, a zip with `contents.xml` (or non-zip bytes, the
   old contract) to the legacy plist path. The current path requires
   `Metadata.json` and refuses files whose `minFileFormatVersionForReading`
   exceeds version 1 with a localized error that names the version
   and the OPML fallback — not a generic failure. The app layer
   dispatches on the file itself: a directory is a legacy package
   (read its `contents.xml`), a flat file is the current zip (read it
   whole). The UTI declaration follows MindNode's own current
   behavior: `.mindnode` is flat data (like `.xmind`), not a package.

   The import-failure alert now names the file in its title and puts
   the importer's localized reason in the detail line ("This MindNode
   file uses version 3, which Arbor can't read yet. …"), instead of
   the old "Import failed" + bare filename.

### Fixtures and honesty

The repo's test fixture is **synthetic**, generated in the exact
reverse-engineered wire shape by
`scripts/generate_mindnode_fixture.swift` (committed binary:
`Packages/MapIO/Tests/MapIOTests/Fixtures/mindnode/synthetic-current.mindnode`,
mirrored by an in-test builder for malformed variants). No personal
document is committed. An opt-in test (env var `ARBOR_REAL_MINDNODE`)
imports a real file when one is available locally, and is skipped
otherwise — CI never depends on personal data.

## Consequences

- Current-format `.mindnode` files import: titles, hierarchy, child
  order, empty nodes, the floating-text node; the result is a normal
  `MapModel` (validator-clean, opens untitled, round-trips through a
  native `.arbor` save).
- The stored child order is authoritative: for the sample the file
  stores root children as ['3rd thought', '4th thought',
  '2nd thought'] — the same set the user described, in the order the
  file records. If MindNode's outline order is in fact computed
  differently, a second sample will tell; the decoder takes order
  only from the repeated child lists.
- A future MindNode format bump (`minFileFormatVersionForReading` ≥ 2)
  is refused with the clear error and the OPML fallback, until
  someone reverse-engineers version 2 from a real file.
- If MindNode's actual note/task/tag wire fields are ever confirmed,
  `MindNodeCurrentFormat` grows them without touching the reader or
  the routing.
- Root child order for multi-root documents comes from the document
  record's child list, matching MindNode's own ordering source.
