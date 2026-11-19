# ADR-0013: Quick Open is ⇧⌘O and reveals folded ancestors through a real command, on commit only

- **Status:** Accepted
- **Date:** 2026-11-19

## Context
F-FOC-4 (SPEC §5.10): ⇧⌘O fuzzy-jumps to any node in the document — select and reveal it. A jump target can sit behind a folded ancestor, and "reveal" only means something if the fold opens.

Two features in this slice need a node hidden behind a fold to become visible, and they pull in opposite directions:

1. **Find (F-FOC-3):** the folded ancestors of the *current match* are expanded **temporarily, in the scene only** — view state, never a `setFolded` command, never persisted, never an undo step. The user did not ask to change the map's fold structure; they asked to find text. When the match moves on or the find bar closes, the scene is rebuilt from the true model and the fold snaps back.
2. **Quick Open (F-FOC-4):** the user *navigates* to a specific node and stays there. After the jump, the document's honest fold state should show the path to that node — reopening the map later should still show it, and undo should behave predictably. A scene-only unfold here would be a lie the next rebuild erases.

## Decision
- **Find** unfolds by handing `SceneGeometry` a value **copy** of the model with the current match's folded ancestors cleared (`FindEngine.modelUnfoldingAncestors`). The document's model, the undo stack and the saved file are untouched; the rebuild path (`updateScene`) reads the copy only while the find session holds a current match.
- **Quick Open** performs a single grouped `setFolded` command over the folded ancestors of the chosen node — a real, persisted, undoable mutation ("Reveal Node", one undo step) — but **only when the user commits the jump**. Browsing and fuzzy-filtering the result list never touches the model, so a dismissed palette leaves the document completely unchanged.

## Consequences
- ⇧⌘O's reveal is durable and honest: the fold state after the jump is the state the file saves, and one ⌘Z restores it.
- An accidental ⇧⌘O-and-Escape costs nothing; an accidental ⇧⌘O-and-Return costs exactly one undo step.
- The two mechanisms live in different layers on purpose (a value copy in the view path vs. a command through the `MapStore`), so future features copy the pattern that matches their semantics, not whichever is closer at hand.

## Shortcut
SPEC §5.10 gives Quick Open ⌘P while F-INT-9 gives Print ⌘P. Print keeps ⌘P,
the macOS-wide convention every user expects (and F-INT-9 is P0). Quick Open
takes ⇧⌘O, Xcode's "Open Quickly", so it stays familiar to Mac power users.
The command palette keeps ⇧⌘P.
