# ADR-0017: AI providers without an SDK — wire contracts, structured output and privacy gating

Date: 2026-11-19
Status: accepted

## Context

SPEC §5.15 (F-AI-1…F-AI-5) wants three AI backends behind one protocol
(Apple on-device, Anthropic, OpenAI-compatible) with no new runtime
dependency (SPEC §11.1: URLSession clients, hand-written). The milestone
brief pins the Anthropic wire facts exactly; everything else below was
ours to decide and is recorded here so reviewers don't have to
rediscover it from the diff.

## Decisions

1. **Streaming protocol shape.** `AIProvider.streamText` yields
   `textDelta`s plus exactly one `finished` event carrying an
   `AIFinish.Reason` (`.endTurn` / `.maxTokens`). A refusal is an
   *error* (`AIError.refused`), not a finish — the brief demands partial
   output never be inserted, and an ended stream can't un-yield its
   deltas. `max_tokens` finishes normally with `.maxTokens` so callers
   keep the parsed text and can say it was truncated.
2. **Anthropic request.** Exactly the pinned facts: `POST /v1/messages`,
   `anthropic-version: 2026-10-21`, `x-api-key`; never
   `temperature`/`top_p`/`top_k`; never `thinking` (the brief says the
   model 400s on `thinking: {type:"disabled"}`), instead
   `"output_config": {"effort": "low"}` for the short creative tasks.
   The refusal fallback (`anthropic-beta: server-side-fallback-2026-07-01`
   + `"fallbacks": "default"`) ships as a Settings toggle, default ON,
   sent only when on.
3. **Retries.** 401 → immediate typed failure, no retry (a bad key
   stays bad). 429 → one retry honoring `retry-after`; 5xx/529 → one
   retry with backoff. A second identical failure throws the typed
   error. Retry delay is injectable so tests run instantly.
4. **SSE parsing.** Lines are split by hand over the raw bytes:
   `URLSession.AsyncBytes.lines` never yields the empty separator lines
   SSE frames dispatch on (found by test). Thinking /
   `signature_delta` blocks are ignored; `stop_reason` is read from
   `message_delta`'s `delta` (the top-level field stays as fallback).
   A multi-line frame tries each data line, so one mangled line never
   poisons a frame.
5. **Structured lists.** JSON lines (`{"text": ..., "parentIndex": n}`)
   over the HTTP providers — parsed defensively (fences skipped, bad
   lines dropped, plain-text fallback with list markers stripped). The
   Apple provider instead uses `@Generable` guided decoding
   (`GeneratedSketchLevel`) because that is the framework's native
   structured path; `respond(to:generating:)` is the correct overload.
   Both produce the same `AIListItem`s, so generation is uniform above
   the provider.
6. **Endpoint classification.** An OpenAI-compatible endpoint is
   "cloud" for consent purposes unless its host is loopback
   (`localhost`, `127.x`, `::1`) — Ollama/LM Studio stay local.
7. **Ghost placement.** Ghost frames come from a probe scene (model +
   hypothetical children) built through the ordinary `SceneGeometry`
   with a *throwaway* cache — a full rebuild per ghost update,
   deliberately, so the document's incremental-layout caches never see
   ghost ids. No ghosts → no probe → the §11.8 keystroke path is
   untouched.
8. **Authorship.** `MapStore.perform(_:author:)` stamps
   `modifiedBy = .ai` on touched nodes and records `lastAuthor`, which
   `MapDocument` writes into `meta.json` as `lastModifiedBy` (F-AI-5).
   Schema additions (`MapModel.ai`, `setNote`, `setTitle`) ship in
   formatVersion 3 with a stamping migration and fixtures.
9. **Consent order.** Master switch (Settings ▸ AI, off by default —
   M8's exit criterion) → one-time cloud consent sheet naming the
   provider → per-document "Never send to cloud AI" (a `setAIPolicy`
   command in `map.json`). All three gate *before* any request is
   built; keys live in the Keychain and never appear in settings JSON,
   documents or logs.

## Consequences

- The image tab of "Generate Map From…" is absent this slice: none of
  the configured wire formats accepts images. It returns with vision
  support.
- `AISettingsStore` is deliberately not `Sendable` (UserDefaults isn't
  annotated); the app confines one instance to the main actor.
- The `URLProtocol` stub suite is one serialized suite because its
  queue is global state.
