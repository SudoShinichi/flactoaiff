<div align="center">

<img src="docs/images/icon.png" width="160" alt="FlacToAiff icon">

# FlacToAiff

**A native macOS app that converts FLAC to AIFF, keeps the tags and artwork, and checks every
file against the FLAC before saving it.**

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## Why AIFF?

FLAC is the usual format for lossless downloads, but not everything plays it:

- **Apple Music** can't import FLAC.
- **Older CDJs** don't play it, for example the CDJ-2000NXS.

AIFF is just as lossless, plays nearly everywhere, and carries tags. FlacToAiff makes that
conversion a drag and drop. If your software and players all handle FLAC (rekordbox, Serato,
the CDJ-3000 and CDJ-2000NXS2 do), you may not need it.

## Features

- **Drag and drop.** Drop files or folders onto the window or the Dock icon, or use Finder's
  **Open With**. Folders keep their structure.
- **Lossless by default.** The sample rate is kept and the bit depth matched.
- **Optional compatibility formats.** One caps files at 24-bit / 48 kHz for older players. The
  other makes 16-bit / 44.1 kHz files for burning audio CDs.
- **Tags and artwork.** They are written as an ID3v2.3 tag, the version DJ software reads most
  reliably.
- **Verified output.** Before an AIFF is saved, its length, format and tags are checked against
  the FLAC. Lossless conversions are also compared against the FLAC's audio checksum. A file
  that fails any check is not saved.
- **Watch folder.** It converts new FLACs that appear in a folder you choose while the app is
  open.
- **Careful with your files.**
  - Existing files are never overwritten.
  - An unfinished AIFF never appears under its final name.
  - It saves directly to exFAT or FAT32 USB sticks.
- **No dependencies.** It uses macOS's built-in `afconvert`.

## Installation

There is no prebuilt download yet. Build it with the Xcode Command Line Tools; the full Xcode is
not needed:

```bash
xcode-select --install          # once, if you don't have the tools
git clone https://github.com/SudoShinichi/flactoaiff.git
cd flactoaiff
./build.sh
```

Then drag `build/FlacToAiff.app` into `/Applications`.

**Requirements:** macOS 12 Monterey or later, on Apple Silicon.

## Usage

Open FlacToAiff and drag `.flac` files or folders onto the window. The AIFFs are written to the
**Save to** folder, which is Downloads by default. You can also drop onto the Dock icon, even
while the app isn't running, or right-click FLACs in Finder → **Open With → FlacToAiff**.
FlacToAiff never makes itself the default app for FLAC files.

### Settings

| Setting | What it does |
| --- | --- |
| **Save to** | The folder the AIFFs go to, for example a USB stick. |
| **Format** | The output format (see the next table). The text under the menu explains each option. |
| **Watch** | A folder whose new FLACs convert automatically (see [Watch folder](#watch-folder)). |

A changed setting applies to the next files you add. Files already queued keep the setting they
were added with.

| Format | Output |
| --- | --- |
| **Original** (default) | Lossless: same sample rate and bit depth (16 or 24-bit) as the source |
| **CDJ: max 24-bit / 48 kHz** | Higher sample rates are resampled to the same family (96 → 48 kHz, 88.2 → 44.1 kHz), and depth is capped at 24-bit |
| **CD: 16-bit / 44.1 kHz** | Resampled and dithered to CD format |

Files that already fit a format are converted unchanged. For example, a 16-bit/44.1 kHz FLAC
comes out identical in all three modes.

> **Which format does my player need?** Check the supported formats in your player's manual.
> For example, Pioneer's manual for the CDJ-2000NXS lists WAV/AIFF at 44.1 and 48 kHz,
> 16- and 24-bit, which is the CDJ format. The CDJ-2000NXS2 and CDJ-3000 also play
> 88.2/96 kHz, so Original works for them.

### Results

Every file gets a row in the window. The label at the end says what was checked:

| Label | Meaning |
| --- | --- |
| `verified` | The audio is bit-for-bit identical to the FLAC (checked against its MD5), and format, length and tags were checked. |
| `tags verified` | Format, length and tags were checked. The audio was resampled or dithered, so it can't be identical, or the FLAC carries no checksum. |
| `format checked` | Format and length were checked. There were no tags, and the audio couldn't be compared (resampled, or no checksum in the FLAC). |
| Already converted | An AIFF with that name already exists in the output folder. It is left untouched. |
| Red row | Nothing was saved. The row says why (see [Troubleshooting](#troubleshooting)). |

To convert a track again, for example in a different format, delete its AIFF and add the FLAC
again.

### Watch folder

Click **Watch** and choose a folder, such as the one your browser downloads into. While the app
is open, new FLACs that appear there are converted into **Save to**. That includes albums
unzipped or moved into the folder, and their subfolders are kept: `Watch/Album/01.flac` becomes
`Save to/Album/01.aiff`.

- A file is picked up once it has stopped changing. A download that stalls for longer than that
  shows an "incomplete" row, then converts once it is complete.
- FLACs that arrive while the app is quit are picked up at the next launch.
- Files already in the folder when you start watching are left alone.

### Tags

FLAC tags (Vorbis comments) are mapped to ID3v2.3 frames:

| FLAC tag | ID3 frame | | FLAC tag | ID3 frame |
| --- | --- | --- | --- | --- |
| `TITLE` | Title | | `BPM` | BPM |
| `ARTIST` | Artist | | `INITIALKEY` | Key |
| `ALBUM` | Album | | `ORGANIZATION` / `LABEL` | Publisher |
| `ALBUMARTIST` | Album artist | | `DATE` / `YEAR` | Year |
| `GENRE` | Genre | | `TRACKNUMBER` / `DISCNUMBER` | Track / disc (with totals) |
| `COMPOSER` | Composer | | `COMMENT` | Comment |
| `REMIXER` | Remixer | | `ISRC` | ISRC |

Embedded pictures become cover art. Other tags are kept as custom `TXXX` fields. Non-Latin text
is preserved.

## How it works

1. **Convert.** `afconvert` decodes the FLAC into a hidden temporary file in the output folder.
   Lossless output uses `afconvert -f AIFF -d BEI<depth>`. Resampling adds
   `-r 127 --src-complexity bats` (highest quality). Bit-depth reduction in CD mode adds TPDF
   dither.
2. **Tag.** `afconvert` copies audio only, so FlacToAiff reads the FLAC's metadata blocks and
   appends an ID3v2.3 chunk.
3. **Verify.** The FLAC's STREAMINFO header records the track's length and an MD5 of its audio.
   - The AIFF's length and format must match.
   - For lossless output, the MD5 of the AIFF's samples must equal the FLAC's.
   - Every tag and picture must read back identically through AVFoundation, the framework Apple's
     apps use.
4. **Publish.** The file is renamed into place without replacing anything that exists. On
   volumes that lack an atomic no-overwrite rename (exFAT, FAT32), a fallback keeps the result a
   complete file.

## Limitations

- **Apple Silicon only, and you build it yourself.** There's no signed or notarized release.
- **FLAC input only.** WAV, ALAC and other formats are skipped.
- **No 32-bit FLAC.** macOS's FLAC decoder stops at 24-bit, so these files fail with a clear
  message. They are rare; save them as 24-bit in an audio editor first.
- **Duplicates are detected by file name.** If `track.aiff` already exists in the output folder,
  a different FLAC named `track.flac` is reported as "Already converted".
- **Changing the format doesn't redo existing files.** Delete the AIFFs first.
- **Tags are checked only through Apple's reader.** Nothing tests them in rekordbox or Serato
  automatically, although both read ID3v2.3.
- **The watch folder works only while the app is open.**
  - Renaming converted files inside it doesn't convert them again until the next launch; after a
    relaunch, a renamed file counts as new.
  - On exFAT volumes, renames may always count as new.

## Troubleshooting

**"FLAC is incomplete — only N% of the audio is there".** The FLAC is shorter than its header
says. It is still being downloaded or copied, or the download broke off. Wait for it to finish,
or download it again.

**"macOS can't decode 32-bit FLAC".** macOS only decodes FLAC up to 24-bit. Save the file as
24-bit in an audio editor, then add it again.

**"Audio doesn't match the FLAC's checksum — the FLAC may be damaged".** The decoded audio
doesn't match the checksum the FLAC was encoded with, so the FLAC file itself is probably
corrupt. Download it again.

**"Tag check failed: …".** A tag didn't read back as it was written, so the file wasn't saved.
Please [open an issue](https://github.com/SudoShinichi/flactoaiff/issues) and include the
FLAC's tags.

**"Output folder not available".** The **Save to** folder was renamed or deleted, or its drive
isn't connected. Reconnect the drive or choose another folder. Watched files that failed for
this reason are retried at the next launch.

**"Watch folder not available".** The watch folder was renamed or deleted, or its drive isn't
connected. Choose it again under **Watch** once it's back.

**macOS says the app can't be opened.** Builds you make yourself open normally. A copy that
arrived by download or AirDrop is quarantined: right-click → **Open** once, or run
`xattr -dr com.apple.quarantine FlacToAiff.app`.

**macOS asks for folder access.** The first time the app writes to Downloads, Desktop or
Documents, click **OK**. Open the app from Finder, not by running its binary in Terminal, so the
permission goes to FlacToAiff itself.

## Development

```bash
./build.sh && ./test.sh
```

`test.sh` runs end-to-end checks on real FLAC files that it generates itself. It covers:
- bit-depth and sample-rate handling in every format, including a 32-bit FLAC that macOS can't decode
- tag and artwork transfer, including unusual tags
- the verification checks, including tampered and truncated files
- duplicate handling and concurrent conversions
- the watch folder
- saving to an exFAT volume

It also builds a separate test binary with `-D TEST_HOOKS` to reach failure paths that real
files can't trigger. Those hooks are never in the app.

A headless command-line mode is available for scripting:

```bash
FlacToAiff.app/Contents/MacOS/FlacToAiff --convert [--format original|max48|cd] <file-or-folder>... <output-dir>
FlacToAiff.app/Contents/MacOS/FlacToAiff --watch   [--format original|max48|cd] <watch-dir> <output-dir>
```

**Output lines:**
- A converted file prints `OK <path>`, a tab, and its label.
- An existing file prints `SKIP <path>`.
- A failure prints `ERROR <name>: <reason>` to stderr, and the exit status is 1.

| File | Purpose |
| --- | --- |
| `Sources/main.swift` | Window, settings bar, app delegate, command-line modes |
| `Sources/Converter.swift` | Output-format choice, `afconvert`, atomic publishing |
| `Sources/Tags.swift` | FLAC STREAMINFO/tag/picture parsing, ID3 writing, AIFF reading |
| `Sources/Verifier.swift` | Length, format, audio checksum and tag checks |
| `Sources/Jobs.swift` | Expands dropped files and folders into conversions |
| `Sources/FolderWatcher.swift` | Watch folder (FSEvents) and launch catch-up |
| `Sources/ConversionQueue.swift` | Background queue shared by all inputs |
| `Sources/Settings.swift` | Persisted settings |
| `scripts/make-icon.swift` | Draws the app icon; rendered by `build.sh` |
| `scripts/make-flac32.swift` | Writes a 32-bit FLAC for `test.sh` (macOS tools can't) |

## License

[MIT](LICENSE)
