# FlacToAiff — Design

Date: 2026-07-09

## Goal
A minimal native macOS app that converts `.flac` audio files to `.aiff` via drag-and-drop, writing results to `~/Downloads`.

## Constraints / Environment
- macOS (Apple Silicon), Command Line Tools only — **no full Xcode**.
- No third-party dependencies. Conversion engine is the built-in `afconvert`, which natively reads FLAC and writes AIFF.
- Swift 5.10 available via `swiftc`.

## Architecture
Two independently-testable pieces:

1. **Converter core** (`Sources/Converter.swift`) — `convert(flacURL:destDir:) -> Result`.
   - Computes a non-clashing output filename in `destDir`.
   - Detects source bit depth and invokes `afconvert`.
   - No UI knowledge; callable from a CLI test harness.
2. **GUI layer** (`Sources/main.swift`) — SwiftUI window hosting a drop zone that passes dropped URLs to the converter and shows per-file status.

## Conversion engine
```
afconvert -f AIFF -d BEI<depth> "input.flac" "output.aiff"
```
- **Bit depth**: detected from source (16 or 24), default 16 if unknown.
- **Sample rate**: preserved (not overridden).
- AIFF is big-endian signed PCM → `BEI16` / `BEI24`.

## Behavior
- Accept **one or many** `.flac` files per drop.
- Ignore non-`.flac` files with a small notice.
- Output to `~/Downloads`, **auto-renamed** on clash: `song.aiff` → `song 2.aiff` → `song 3.aiff` …
- Window shows a live per-file list: ✅ converted / ❌ failed (with reason). Offer "Reveal in Finder" after a batch, then reset to the drop zone.

## UI
Single small window. Large dashed drop zone: "⬇ Drop .flac here". During/after a batch it becomes a status list, then resets.

## Build & run (no Xcode)
- `build.sh` compiles the Swift sources with `swiftc` and assembles `FlacToAiff.app` by hand (`Contents/MacOS/FlacToAiff` + `Contents/Info.plist`).
- Unsigned: first launch requires **right-click → Open** once to pass Gatekeeper. Documented in README.

## Testing
- `test.sh` synthesizes a test tone, encodes it to `.flac` with `afconvert`, runs the converter core, and verifies the output `.aiff` is valid via `afinfo`. Real end-to-end, no mocks.

## Layout
```
flactoaiff/
├── Sources/
│   ├── Converter.swift
│   └── main.swift
├── build.sh
├── test.sh
└── README.md
```
