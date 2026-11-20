# ADR-0030: Local MCP transport: stdio JSON-RPC + a Unix socket in the app container

Date: 2026-11-19
Status: Accepted

## Context

F-INT-4 (SPEC §5.16) requires a bundled MCP helper, `arbor-mcp`, that AI
clients (Claude Desktop, Claude Code) launch locally, with eight tools
(`list_maps`, `read_map`, `search_nodes`, `add_nodes`, `update_node`,
`move_node`, `create_map`, `get_due_cards`). Two hard constraints shape
the design:

- **Privacy (SPEC §12):** MCP is read-only by default and listens only
  via stdio/XPC/Unix socket from the local user. No TCP, no network.
- **One editing gateway (SPEC §11.3):** every mutation must be a
  `MapCommand` through the document's `MapStore` (undo, validation,
  authorship stamping) when the map is open — never a bare file write
  behind the app's back.

The sandbox complicates the "local user" part: the app is sandboxed
(`com.apple.security.app-sandbox`), a helper launched by an MCP client is
not, and they must share exactly two things — a socket to talk over and
a policy flag that says whether edits are allowed.

## Decision

1. **The helper speaks MCP over stdio** exactly as the MCP spec's stdio
   transport defines it: newline-delimited JSON-RPC 2.0, one JSON
   document per line, no embedded newlines, `Content-Length` framing not
   used. Responses stream per line (`FileHandle` raw writes, never
   buffered `print`), so piped clients see each response immediately.
2. **When Arbor runs, the helper forwards every tool call over a Unix
   domain socket** bound by the app at
   `~/Library/Containers/<bundle-id>/Data/arbor-mcp.sock` (the container's
   home, not `Library/Application Support/Arbor/` beside the settings file:
   that path overflows `sun_path`'s 104 bytes for most home-directory
   names, so the app could never bind), mode 0600 — the app's container, reachable by the unsandboxed helper
   and by nothing else. The app answers against its open documents
   (`MapStore`, one undo step, `modifiedBy: "mcp"`) and falls back to
   coordinated file access for closed maps. A stale socket
   (ECONNREFUSED) or a missing one (ENOENT) is not an error: the helper
   falls back to local mode.
3. **When Arbor is closed, the helper works on files directly** through
   `NSFileCoordinator` + `ArborPackage` (read → apply `MapCommand`s →
   ONE atomic write; a failing command leaves the file untouched).
4. **Read-only by default, fail closed:** the app writes
   `mcp-settings.json` ({"allowEdits": bool}) next to the socket; the
   helper re-reads it for every request; missing or corrupt means
   read-only. Mutating tools are absent from `tools/list` AND refused by
   `tools/call` while the flag is off, on both the helper and app sides
   (defence in depth).
5. **The helper is a separate unsandboxed Xcode tool target** (`type:
   tool`), embedded into `Contents/MacOS` of the app bundle, with
   `PRODUCT_NAME`/`PRODUCT_MODULE_NAME` set explicitly (the project-level
   `PRODUCT_NAME = Arbor` from `Config.xcconfig` would otherwise name the
   helper's binary and module "Arbor" and collide with the app's). It has
   no entitlements: launched by the user's MCP client, it needs the
   user's own file access; it opens no listening socket anywhere, so
   being outside the app sandbox grants it no attack surface it doesn't
   already have as the user.
6. **The logic lives in a new `MapAutomation` package** (MapCore +
   MapIO + MapStudy, no AppKit, `swift test` on the command line): the
   JSON-RPC codec, the MCP server, the eight tools against a
   `DocumentSpace` seam, the Unix-socket transport, headless (closed
   document) editing, node search and due-card counting. The app
   endpoint and the helper's local mode are two thin implementations of
   that seam, so the tool behavior is identical either way and
   testable headlessly. ArborURL parsing and the Services' outline
   conversion live there too.

An environment override, `ARBOR_MCP_STATE_DIR`, relocates the shared
state directory for tests and development builds (the sandboxed app's
`.applicationSupportDirectory` and the helper's home-relative path
agree inside the container; the override guarantees a match outside it).

## Consequences

- No TCP anywhere; the only listener is a 0600 Unix socket inside the
  user's own app container.
- Edits hit open documents through the same `MapStore` path as the UI:
  one undo step, validated, marked `lastModifiedBy: "mcp"`.
- The socket round trip is one request/one response per connection
  (simple, and MCP stdio is sequential anyway).
- Known limitation, accepted: doc resolution in app-closed mode scans
  `~/Documents` plus the container's `Documents` (capped at 500
  packages, skip-unreadable); a user whose maps live in iCloud Drive
  should keep Arbor running or pass a path. The Library index (F-LIB)
  will replace the scan once it lands.
- Share extensions remain out of scope (F-INT-6's second half).
