<div align="center">

<img src="docs/images/icon.png" width="160" alt="FlacToAiff icon">

# FlacToAiff

**Drag-and-drop FLAC → AIFF conversion for macOS. Lossless, tags included, zero dependencies.**

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

</div>

---

FlacToAiff is a small native Mac app for turning `.flac` files into `.aiff`, the format
expected by rekordbox, Serato, Apple Music and many CDJs. Drop files on the window and the
converted copies appear in your **Downloads** folder, with their metadata and cover art intact.

## Features

- **Drag and drop** — drop one file or a whole batch onto the window.
- **Lossless** — sample rate is preserved and bit depth (16, 24 or 32-bit) is matched. If the
  source depth can't be detected, the app rounds *up*, never down.
- **Tags and artwork carried over** — title, artist, album, cover art and more are written
  into the AIFF as an ID3 tag, so tracks show up correctly in your library.
- **Skips duplicates** — files that were already converted are skipped, never overwritten. Output is written to a temp file and renamed into place only when complete, so a half-written AIFF can never be mistaken for a finished one.
- **No dependencies** — built on macOS's own `afconvert` audio engine. No ffmpeg, no Homebrew.

## Requirements

- macOS 12 Monterey or later, on Apple Silicon
- Xcode Command Line Tools to build (`xcode-select --install`); the full Xcode is not needed

## Installation

```bash
git clone git@github.com:SudoShinichi/flactoaiff.git
cd flactoaiff
./build.sh
```

This produces `build/FlacToAiff.app`. Drag it into `/Applications` to install it.

## Usage

1. Open **FlacToAiff**.
2. Drag one or more `.flac` files onto the window.
3. Find the converted `.aiff` files in your **Downloads** folder.

Non-FLAC files are skipped, and each file's result is listed in the window.

### Metadata

FLAC tags (Vorbis comments) are mapped to ID3v2.3, the version DJ software reads most reliably:

| FLAC tag | ID3 frame | | FLAC tag | ID3 frame |
| --- | --- | --- | --- | --- |
| `TITLE` | Title | | `BPM` | BPM |
| `ARTIST` | Artist | | `INITIALKEY` | Key |
| `ALBUM` | Album | | `ORGANIZATION` / `LABEL` | Label / publisher |
| `ALBUMARTIST` | Album artist | | `DATE` / `YEAR` | Year |
| `GENRE` | Genre | | `TRACKNUMBER` / `DISCNUMBER` | Track / disc (with totals) |
| `COMPOSER` | Composer | | `COMMENT` | Comment |
| `REMIXER` | Remixer | | `ISRC` | ISRC |

Embedded pictures become cover art, and any other tags are kept as custom (`TXXX`) fields.
Non-Latin text is preserved.

## How it works

Conversion is handled by Apple's built-in `afconvert`:

```bash
afconvert -f AIFF -d BEI<depth> input.flac output.aiff
```

`afconvert` copies audio only, so FlacToAiff then reads the FLAC's metadata blocks and
appends an `ID3 ` chunk to the AIFF.

| File | Purpose |
| --- | --- |
| `Sources/main.swift` | SwiftUI drop-zone window, plus a headless `--convert` mode used by the tests |
| `Sources/Converter.swift` | Bit-depth detection, safe output naming, `afconvert` invocation |
| `Sources/Tags.swift` | FLAC tag/picture parsing and ID3 chunk writing |
| `scripts/make-icon.swift` | Draws the app icon in code; rendered by `build.sh` |

## Development

```bash
./build.sh && ./test.sh
```

The end-to-end test synthesizes real FLAC files and runs the actual conversion core. It
covers bit-depth and sample-rate preservation, duplicate skipping, rejecting non-FLAC and corrupt
input, concurrent conversions, and tag carry-over.

A headless mode is available for scripting:

```bash
build/FlacToAiff.app/Contents/MacOS/FlacToAiff --convert input.flac /path/to/output-dir
```

## Troubleshooting

**"App can't be opened" / Gatekeeper warning.** Builds you make yourself open with a plain
double-click. A copy received via browser download or AirDrop is quarantined. Right-click → **Open**
once, or run `xattr -dr com.apple.quarantine FlacToAiff.app`. The app is ad-hoc signed
(`local.flactoaiff`) and has no Developer ID.

**Downloads folder permission prompt.** On first use, macOS asks to let FlacToAiff access
Downloads. Click **OK**. Launch the app from Finder rather than running the binary from
Terminal, so the permission is granted to FlacToAiff itself.

**Converted files show the filename as the title.** Those files were converted before tag
support was added. Convert them again.
