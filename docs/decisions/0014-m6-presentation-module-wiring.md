# ADR-0014: M6 presentation module wiring

Date: 2026-11-19
Status: accepted

## Context

M6 (SPEC §5.13, §10, §16) delivers the RevealEngine, presentation
mode (auto + authored slides, builds, presenter view, clicker keys,
live edit) and the slides PDF export. SPEC §11.2 fixes the package
layout and §10 says the Reveal Engine lives in `MapStudy` and is
"shared with presentations" — but it does not say where each
presentation concern lands when `MapStudy` must stay AppKit-free and
no `MapPresent` package exists (§11.2's list is closed; adding a
package would also break the `swift test` loop and the dependency
budget conventions).

## Decision

- **`MapStudy`**: the pure reveal state machine (`RevealEngine`,
  `RevealStep`, `RevealState`). No AppKit; the FSRS work lands beside
  it untouched. `MapStudy/Package.swift` gains nothing — zero overlap
  with the concurrent FSRS PR.
- **`MapCore`**: slide authoring rides one wholesale command,
  `MapCommand.setPresentations`, the exact-inverse pattern of
  `setConnections`/`setBoundaries`/`setSummaries`. Every sidebar
  action performs a single grouped replace (`.group(name: "Add Slide",
  …)`), so each authored change is one undo step with a meaningful
  name and the inverse is a list snapshot. No schema change: §8.2's
  `presentations` model already exists.
- **`CanvasKit`** (importing `MapStudy` — no cycle, `MapStudy` only
  depends on `MapCore`): the `RevealState` overlay on the layer tree
  (opacity only, never a re-raster), the F-PRE-1 auto-slide generator
  (it needs laid-out frames, which is scene data), the pure
  presenting key machine, the camera tween, the presentation surface
  view, and the slides PDF writer (shared `SceneRenderer`).
- **`App`**: `PresentationCoordinator` (deck resolution, windows,
  screen choice with an injected screen list so the two-display path
  is testable without hardware), the presenter dashboard (SwiftUI
  hosted — allowed per §11.1), the Slides sidebar panel, and the
  menus/toolbar wiring.

## Consequences

- `CanvasKit` → `MapStudy` is a new edge not drawn in §11.2's diagram,
  but the doc's own rule ("MapCore ← MapStudy") stays true and nothing
  cycles. Study reuse of the overlay (M7) is now a direct import away.
- Live edit (F-PRE-6, "E pauses the presentation into editing at the
  current camera") is implemented as: E closes the audience surface
  and leaves the *document* window at the presentation camera (the
  full editing stack — overlay editor, commands, undo — stays the one
  implementation); ⌘⏎ rebuilds the audience surface at the paused
  slide/build. Editing during a presentation is ordinary document
  editing, one undo step per command, which matches "presentation
  never dirties the document" (presenting itself performs no command).
- Authored slides store the captured camera as-is (SPEC §8.2's
  `camera` field); a captured viewport and a presenting screen with
  different aspect ratios will frame the slide differently. Auto
  slides store a camera-fit rect instead, resolved against the actual
  screen at present time. Refinement (aspect-correct authored
  cameras) is deferred until real use shows it matters.
