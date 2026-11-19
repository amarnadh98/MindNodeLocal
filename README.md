# Arbor

A free, native macOS mind-mapping app for thinking, presenting and learning. It does everything MindNode Plus does, adds presentation and spaced-repetition study modes, stores your maps as real files, and has no subscription.

> Screenshots: [`docs/design/`](docs/design/) — capture slots for the v1.0.0 release are listed there.

- 📐 **Spec:** [SPEC.md](SPEC.md) is the source of truth for implementation.
- 🔎 **Research:** [docs/research/RESEARCH.md](docs/research/RESEARCH.md) covers MindNode, its competitors and the technical approach.
- 🤖 **For coding agents:** [AGENTS.md](AGENTS.md)
- 🧭 **Decisions:** [docs/decisions/](docs/decisions/)
- 🚢 **Releasing:** [docs/release-checklist.md](docs/release-checklist.md)

## Features

- **Editing:** keyboard-first, with animated auto-layout. Structures include mind map (balanced/left/right), org chart, logic chart, radial, timeline and fishbone, and you can mix them per branch.
- **Node content:** Markdown notes, images, SF Symbols and emoji, links, tasks with progress rings, tags, connections, boundaries and summaries.
- **Views:** an outline side by side with the map, Focus and Zen modes, a find/replace bar, Quick Open and a command palette.
- **Look:** 12 dynamic themes (light + dark) with a theme editor.
- **Present:** auto or authored slides, branch-by-branch builds, and a presenter view on a second display.
- **Study:** FSRS flashcards straight from your branches, a recall mode on the canvas, and a mastery heatmap.
- **AI:** on-device Apple Intelligence, or bring your own API key. Off by default.
- **Import and export:** OPML, Markdown, plain text outlines, FreeMind, XMind, MindNode import; PDF, PNG, SVG and more out.
- **System integration:** Spotlight, Quick Look, print, drag-and-drop everything.
- **In-app updates:** Sparkle, strictly opt-in (see Privacy).

## Requirements

macOS 26 or later. Built with Xcode 27 and Swift 6.4.

## Install

Download the latest `Arbor-<version>.dmg` from [Releases](https://github.com/amarnadh98/MindNodeLocal/releases), open it, and drag Arbor into the Applications folder.

What happens on first launch depends on how the release was signed:

- **Developer ID + notarized builds** (when the owner has joined the Apple Developer Program): the app opens normally.
- **Ad-hoc builds** (the free path, SPEC §13 B): macOS blocks the first open. Try to open the app once, then go to **System Settings ▸ Privacy & Security** and click **Open Anyway**. Or, from a terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Arbor.app
  ```

  On ad-hoc builds the Keychain may prompt again after each update, and some extensions (Quick Look, Spotlight) may not register.

## Build from source

```sh
xcodegen generate            # once, and after every project.yml edit
open Arbor.xcodeproj          # then ⌘R the Arbor scheme
```

Or from the command line:

```sh
xcodebuild -scheme Arbor -destination 'platform=macOS' build
```

To produce a shareable DMG locally (ad-hoc signed, no Apple Developer Program membership needed):

```sh
scripts/release/build-dmg-local.sh        # → dist/local/Arbor-<version>.dmg
```

The full pipeline — test, archive, sign, notarize, DMG, Sparkle appcast, GitHub Release and Pages — runs automatically when a `v*.*.*` tag is pushed (see [`.github/workflows/release.yml`](.github/workflows/release.yml) and [docs/release-checklist.md](docs/release-checklist.md)).

## Privacy

Arbor works fully offline and collects nothing — no telemetry, no analytics, no account.

Network access is limited to two things you control:

1. **Update checks** (Sparkle). Automatic checks are **off** by default; Arbor never contacts the update feed unless you click *Check for Updates…* or enable automatic checks yourself. See [ADR-0021](docs/decisions/0021-sparkle-in-app-updates.md).
2. **Cloud AI providers**, only if you configure one with your own key (Settings ▸ AI), plus importing content from a URL you explicitly paste.

Maps are ordinary `.arbor` package files on your disk — no lock-in, nothing hidden in a database.
