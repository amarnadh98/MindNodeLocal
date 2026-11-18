# ADR-0001: Native AppKit + Core Animation canvas, NSDocument packages

- **Status:** Accepted
- **Date:** 2026-11-18

## Context
We want a high-end Mac mind-mapping app. It must hold 120 fps pan and zoom with 5,000 nodes. It needs rich in-node text editing with full IME, spell check and Writing Tools support. It must store real files that live in Git and iCloud Drive. It must also be shareable with friends outside the App Store.

## Decision
- The app uses the AppKit lifecycle with `NSDocument` and `FileWrapper` package documents (`.arbor`).
- The canvas is a layer-hosting `NSView` with a camera transform, virtualized and pooled `CALayer` nodes, and model-space hit-testing.
- In-node editing uses a single shared TextKit 2 `NSTextView` overlay.
- SwiftUI is hosted for secondary UI: the inspector, library, settings and study screens.
- Tree layout uses the non-layered tidy tree algorithm (van der Ploeg 2014) in a pure-Swift package.
- The minimum supported OS is macOS 26.

## Alternatives rejected
- **SwiftUI `Canvas` or a view per node.** It has no per-element hit-testing or accessibility, redraws the whole canvas, and gets slow at scale.
- **Metal.** Text rendering costs too much and the extra performance isn't needed.
- **SwiftUI `DocumentGroup`.** It gives less control over async saves, windows and the canvas. Its new incremental APIs require macOS 27.
- **Electron or Tauri.** They aren't native and don't feel right on the Mac.
- **A CloudKit database like MindNode Next's.** Users dislike losing real files.

## Consequences
- There is more AppKit code to write, but we get full control over performance and behaviour.
- The core packages stay platform-agnostic, so an iPad port remains possible.
