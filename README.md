<div align="center">

<img src="docs/images/icon.png" width="160" alt="FlacToAiff icon">

# FlacToAiff

**A native macOS app that converts FLAC, WAV and ALAC to AIFF, keeps the tags and artwork, and checks
every file against its source before saving it.**

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-black?logo=apple)
![Apple Silicon and Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-black)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## Why AIFF?

FLAC is the usual format for lossless downloads, but not everything plays it:

- **Apple Music** can't import FLAC.
- **Older CDJs** don't play it, for example the CDJ-2000NXS.

WAV plays nearly everywhere, but its tags are poorly supported, so DJ software often shows only
the file name. AIFF is just as lossless, plays nearly everywhere, and carries tags. FlacToAiff
makes that conversion a drag and drop. If your software and players all handle FLAC (rekordbox, Serato,
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
  the source. Lossless FLAC and WAV conversions are also compared sample for sample: against the
  FLAC's audio checksum, or against the WAV's own samples. A file that fails any check is not saved.
- **Watch folder.** It converts new FLAC, WAV and ALAC files that appear in a folder you choose while
  the app is open.
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

**Requirements:** macOS 12 Monterey or later, on Apple Silicon or Intel. The app is a universal
binary.

## Usage

Open FlacToAiff and drag `.flac`, `.wav` or `.m4a` (Apple Lossless) files or folders onto
the window. The AIFFs are written to the
**Save to** folder, which is Downloads by default. You can also drop onto the Dock icon, even
while the app isn't running, or right-click files in Finder → **Open With → FlacToAiff**.
FlacToAiff never makes itself the default app for any of these files.

### Settings

| Setting | What it does |
| --- | --- |
| **Save to** | The folder the AIFFs go to, for example a USB stick. |
| **Player** | What the files are for (see the next table). The text under the menu says what the player plays. |
| **Skip files the player already plays** | Shown for DJ players; off by default. Files the player plays as they are, such as a 44.1 kHz FLAC on a CDJ-3000, are left alone and listed as "Plays as is". |
| **Watch** | A folder whose new FLAC, WAV and ALAC files convert automatically (see [Watch folder](#watch-folder)). |

A changed setting applies to the next files you add. Files already queued keep the setting they
were added with.

| Player | Plays from USB | Output |
| --- | --- | --- |
| **Original (lossless)** (default) | — | Same sample rate and bit depth as the source. For Apple Music and software. |
| **CDJ-3000 / CDJ-3000X**, **CDJ-2000NXS2**, **OPUS-QUAD** | FLAC, WAV, ALAC, AIFF up to 24-bit / 96 kHz | 176.4 → 88.2 kHz, 192 → 96 kHz; 32-bit → 24-bit |
| **XDJ-1000MK2** | FLAC, WAV, ALAC, AIFF up to 24-bit / 48 kHz | 88.2/176.4 → 44.1 kHz, 96/192 → 48 kHz; 32-bit → 24-bit |
| **XDJ-RX3 / XDJ-XZ** | FLAC, WAV, AIFF up to 24-bit / 48 kHz (no ALAC) | as XDJ-1000MK2 |
| **CDJ-2000NXS / CDJ-900NXS / XDJ-1000 / XDJ-700** | WAV, AIFF up to 24-bit / 48 kHz | as XDJ-1000MK2 |
| **Audio CD** | — | Resampled and dithered to 16-bit / 44.1 kHz |

Resampling stays within a rate family (44.1 or 48 kHz), so the ratio is a whole number. Reducing
bit depth adds dither. Files that already fit are converted unchanged: a 16-bit/44.1 kHz FLAC
comes out identical for every choice.

The player limits come from the manufacturers' manuals; the sources are listed in
`Sources/Players.swift`. If your player isn't listed, pick one with the same limits from its
manual, or Original if it plays everything.

### Results

Every file gets a row in the window. The label at the end says what was checked:

| Label | Meaning |
| --- | --- |
| `verified` | The audio is bit-for-bit identical to the source (checked against the FLAC's MD5, or the WAV's samples), and format, length and tags were checked. |
| `tags verified` | Format, length and tags were checked. The audio was resampled or dithered, so it can't be identical, or the source carries no checksum (ALAC never does). |
| `format checked` | Format and length were checked. There were no tags, and the audio couldn't be compared (resampled, or no checksum in the source). |

**Why ALAC is never `verified`.** ALAC files contain no checksum, and Apple's decoder is the
only one on the Mac, the same one Apple Music plays them with. FlacToAiff checks the length,
format and tags, but has nothing independent to compare the audio against. That's a limit of
the proof, not a sign of lower quality: the conversion is just as lossless.
| Already converted | This file's AIFF already exists in the output folder. It is left untouched. |
| Plays as is | "Skip files the player already plays" is on, and the player takes this file as it is. Nothing was written. |
| Red row | Nothing was saved. The row says why (see [Troubleshooting](#troubleshooting)). |

To convert a track again, for example in a different format, delete its AIFF and add the source
file again.

### Watch folder

Click **Watch** and choose a folder, such as the one your browser downloads into. While the app
is open, new FLAC, WAV and ALAC files that appear there are converted into **Save to**. That includes albums
unzipped or moved into the folder, and their subfolders are kept: `Watch/Album/01.flac` becomes
`Save to/Album/01.aiff`.

- A file is picked up once it has stopped changing for 2 seconds. A download that stalls for
  longer than that shows an "incomplete" row, then converts once it is complete. A file whose
  header doesn't record its length (some encoders and WAV writers fill it in last) waits 30
  seconds instead.
- Files that arrive while the app is quit are picked up at the next launch.
- Files already in the folder when you start watching are left alone, even if you later rename
  them, move them within the folder or give them Finder tags. Changing a file's contents, for
  example editing its tags in a tag editor, makes it count as new.
- If the folder's drive isn't connected, watching starts as soon as it is.

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

Embedded pictures become cover art, with the front cover first, because players that show one
picture show the first. Pictures that are only a web link are left out. The year is taken from
`DATE` in any order, so `2026-03-01` and `03.05.2026` both give 2026. Other tags are kept as
custom `TXXX` fields. Non-Latin text is preserved.

WAV tags are read from an embedded ID3 tag (ID3v2.3 or v2.4, as store downloads carry) and from
the `LIST/INFO` chunk (`INAM` title, `IART` artist, `IPRD` album, `IGNR` genre, `ICRD` date,
`ITRK` track, `ICMT` comment, `ICOP` copyright). Where both have a field, the ID3 tag wins.

ALAC tags are the iTunes ones: title, artist, album, album artist, genre, composer, year,
comment, copyright, track and disc numbers, BPM, cover art, and custom fields such as
`INITIALKEY`. Gapless and volume data (`iTunSMPB`, `iTunNORM`) are player data and aren't copied.

## How it works

1. **Convert.** `afconvert` decodes the source into a hidden temporary file in the output folder.
   Lossless output uses `afconvert -f AIFF -d BEI<depth>`. Resampling adds
   `-r 127 --src-complexity bats` (highest quality). Bit-depth reduction in CD mode adds TPDF
   dither.
2. **Tag.** `afconvert` copies audio only, so FlacToAiff reads the source's tags (FLAC metadata
   blocks, a WAV's ID3 and INFO chunks, or an ALAC file's iTunes tags) and appends an ID3v2.3 chunk.
3. **Verify.** A FLAC's STREAMINFO header records the track's length and an MD5 of its audio. A
   WAV's header records the length, and its samples are hashed the same way.
   - The AIFF's length and format must match.
   - For lossless output, the MD5 of the AIFF's samples must equal the source's.
   - Every tag and picture must read back identically through AVFoundation, the framework Apple's
     apps use.
4. **Publish.** The file is renamed into place without replacing anything that exists. On
   volumes that lack an atomic no-overwrite rename (exFAT, FAT32), a fallback keeps the result a
   complete file.

## Limitations

- **You build it yourself.** There's no signed or notarized release.
- **FLAC, WAV and ALAC input only.** Other formats are skipped. An `.m4a` that holds lossy AAC
  is skipped with a message: as AIFF it would be 5–10 times larger and sound no better.
- **Integer WAV only.** Floating-point WAVs, which some DAWs export, can't become a lossless
  AIFF and are skipped with a message. Export them as 24-bit WAV. Compressed WAVs (ADPCM, MP3 in
  WAV) are skipped too.
- **16, 20 and 24-bit FLAC only.** macOS's FLAC decoder handles nothing else, so rare 8, 12
  or 32-bit FLACs fail with a clear message. Save them as 16 or 24-bit in an audio editor first.
- **AIFFs from earlier versions don't record their source.** If such a `track.aiff` exists, any
  FLAC named `track.flac` is reported as "Already converted". AIFFs made from now on record which
  file they came from.
- **Changing the format doesn't redo existing files.** Delete the AIFFs first.
- **Tags are checked only through Apple's reader.** Nothing tests them in rekordbox or Serato
  automatically, although both read ID3v2.3.
- **The watch folder works only while the app is open.** On exFAT volumes, renaming a FLAC that
  arrived while the app was open may convert it again.

## Troubleshooting

**"FLAC is incomplete — only N% of the audio is there"** (or "WAV is incomplete"). The file is
shorter than its header says. It is still being downloaded or copied, or the download broke off. Wait for it to finish,
or download it again.

**"macOS can't decode 32-bit FLAC"** (or 8 or 12-bit). macOS only decodes 16, 20 and 24-bit
FLAC. Save the file as 16 or 24-bit in an audio editor, then add it again.

**"track.aiff already exists, made from a different file".** Two different files share a name,
for example `A/track.flac` and `B/track.flac` dropped into the same **Save to** folder. Nothing was
saved and the existing AIFF is untouched. Rename one of the files and add it again.

**"Couldn't read this ALAC file".** The `.m4a` is cut off or damaged. Let the download finish, or
download it again.

**"Skipped — floating-point WAV can't become a lossless AIFF".** The WAV stores 32 or 64-bit
floating-point samples. Export it from your DAW as 24-bit WAV, then add it again.

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
connected. Watching starts by itself once the drive is back; a renamed or deleted folder has to
be chosen again under **Watch**.

**macOS says the app can't be opened.** Builds you make yourself open normally. A copy that
arrived by download or AirDrop is quarantined: right-click → **Open** once, or run
`xattr -dr com.apple.quarantine FlacToAiff.app`.

**macOS asks for folder access.** The first time the app writes to Downloads, Desktop or
Documents, click **OK**. Open the app from Finder, not by running its binary in Terminal, so the
permission goes to FlacToAiff itself.

## Development

```bash
./build.sh && ./test.sh
arch -x86_64 ./test.sh          # the same checks on the Intel build, under Rosetta
```

`test.sh` rebuilds the app if the sources changed, then runs end-to-end checks on real FLAC, WAV and ALAC files that it generates itself. It covers:
- bit-depth and sample-rate handling in every format, including the depths macOS can't decode
- tag and artwork transfer, including unusual tags
- the verification checks, including tampered and truncated files
- duplicate handling and concurrent conversions
- the watch folder
- saving to an exFAT volume

It also builds a separate test binary with `-D TEST_HOOKS` to reach failure paths that real
files can't trigger. Those hooks are never in the app.

A headless command-line mode is available for scripting:

```bash
FlacToAiff.app/Contents/MacOS/FlacToAiff --convert [<format>] <file-or-folder>... <output-dir>
FlacToAiff.app/Contents/MacOS/FlacToAiff --watch   [<format>] <watch-dir> <output-dir>
# <format>: --format original|max96|max48|cd
#           --player cdj-3000|cdj-2000nxs2|opus-quad|xdj-1000mk2|xdj-rx3|cdj-2000nxs|original|cd [--skip-playable]
```

**Output lines:**
- A converted file prints `OK <path>`, a tab, and its label.
- An existing file prints `SKIP <path>`.
- A file left alone with `--skip-playable` prints `KEEP <name>`, a tab, and the reason.
- A failure prints `ERROR <name>: <reason>` to stderr, and the exit status is 1.

| File | Purpose |
| --- | --- |
| `Sources/main.swift` | Window, settings bar, app delegate, command-line modes |
| `Sources/Converter.swift` | Output-format choice, `afconvert`, atomic publishing |
| `Sources/Tags.swift` | FLAC and WAV header and tag parsing, iTunes tags, ID3 reading and writing, AIFF reading |
| `Sources/Verifier.swift` | Length, format, audio checksum and tag checks |
| `Sources/Players.swift` | The Player menu: each player's limits, with their sources |
| `Sources/AudioSource.swift` | Input formats: one type per format (FLAC, WAV, ALAC) |
| `Sources/Jobs.swift` | Expands dropped files and folders into conversions |
| `Sources/FolderWatcher.swift` | Watch folder (FSEvents) and launch catch-up |
| `Sources/ConversionQueue.swift` | Background queue shared by all inputs |
| `Sources/Settings.swift` | Persisted settings |
| `scripts/make-icon.swift` | Draws the app icon; rendered by `build.sh` |
| `scripts/make-flac.swift` | Writes FLACs of any bit depth for `test.sh` (macOS tools can't) |

## License

[MIT](LICENSE)
