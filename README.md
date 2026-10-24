# FlacToAiff

A minimal native macOS app that converts `.flac` audio files to `.aiff` by drag-and-drop. Converted files are saved to your **Downloads** folder.

- **No dependencies** — uses macOS's built-in `afconvert` engine (no ffmpeg, no Homebrew).
- **Drag one or many** `.flac` files onto the window.
- **Quality preserved** — sample rate is kept; bit depth (16-, 24- or 32-bit) is matched, rounding up on any detection uncertainty, never down.
- **Tags kept** — title, artist, album, genre, BPM, key, label, year, track/disc numbers and cover art are copied from the FLAC into the AIFF (as an ID3 chunk, which Music, rekordbox, Serato etc. read).
- **Never overwrites** — name clashes auto-rename: `song.aiff` → `song 2.aiff`.

## Build

```bash
./build.sh
```

Produces `build/FlacToAiff.app`. Requires only the Xcode Command Line Tools (`swiftc`) — no full Xcode.

## Run

Double-click `build/FlacToAiff.app`, then drag `.flac` files onto the window.

Because you build the app locally, it carries no `com.apple.quarantine` attribute and first launch is a plain double-click — no Gatekeeper prompt. (The right-click → **Open** dance, or `xattr -dr com.apple.quarantine build/FlacToAiff.app`, is only needed for copies that arrive via a browser or AirDrop, which do get quarantined.) The binary is ad-hoc signed with a stable identifier (`local.flactoaiff`); there is no Developer ID / Team ID.

On the first save you may get a system prompt granting access to the Downloads folder — click **OK**. Launch via Finder (double-click the `.app`) so this prompt is attributed to FlacToAiff; running the binary from Terminal attributes it to Terminal instead.

To install it permanently, drag `FlacToAiff.app` into `/Applications`.

## Test

```bash
./build.sh && ./test.sh
```

The test synthesizes a FLAC, runs the real conversion core, and verifies the output AIFF's format via `afinfo`.

## How it works

`Sources/Converter.swift` shells out to:

```
afconvert -f AIFF -d BEI<depth> input.flac output.aiff
```

`Sources/main.swift` provides the SwiftUI drop-zone window (and a hidden
`--convert <in.flac> <destDir>` CLI mode used by the test).
