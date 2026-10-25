<div align="center">

<img src="docs/images/icon.png" width="160" alt="FlacToAiff icon">

# FlacToAiff

**A native macOS app that converts FLAC, WAV and Apple Lossless files to AIFF, keeps their tags
and artwork, and checks each AIFF before saving it.**

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-black?logo=apple)
![Apple Silicon and Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-black)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

</div>

---

## Why AIFF?

Lossless downloads usually come as FLAC or WAV, and neither works everywhere:

- **Apple Music** doesn't import FLAC.
- **Older DJ players**, such as the CDJ-2000NXS, don't play FLAC or Apple Lossless.
- **WAV** plays almost everywhere, but its tags are often ignored, so DJ software may show only
  the file name.

AIFF is lossless, plays on these players and in Apple Music, and carries ID3 tags. If all your
software and players already handle your files (rekordbox, Serato, the CDJ-3000 and the
CDJ-2000NXS2 all play FLAC), you may not need this app.

## Features

- **Drag and drop.** Drop files or folders onto the window or the Dock icon, or use **Open With**
  in Finder. Folders keep their structure.
- **Lossless by default.** The sample rate and bit depth are kept.
- **Player presets.** Choose a DJ player and files are converted to what it plays: for example,
  192 kHz becomes 96 kHz for a CDJ-3000 and 48 kHz for a CDJ-2000NXS. There is also a preset for
  burning audio CDs.
- **Tags and artwork.** They are written as an ID3v2.3 tag, which rekordbox, Serato and Apple
  Music all read.
- **Checked output.** Before an AIFF is saved, its format, length and tags are compared with the
  source. Lossless FLAC and WAV conversions are also compared sample for sample. A file that fails
  any check is not saved. See [Results](#results) for what each label means.
- **Watch folder.** New files in a folder you choose, such as your downloads folder, are
  converted while the app is open.
- **USB check.** Lists the tracks on a USB stick that a chosen player won't play, without
  changing anything on the stick.
- **Safe with existing files.** Nothing is ever overwritten, and an unfinished AIFF never
  appears under its final name, including on exFAT and FAT32 sticks.
- **No dependencies.** Conversion uses macOS's built-in `afconvert`.

## Status

FlacToAiff is a young, single-developer project.

- There is no signed or notarized download yet. You build the app yourself (see below).
- The player presets are based on the manufacturers' manuals and spec sheets. They have not yet
  been tested on every player. Check your player's manual if a track matters.

## Installation

Build the app with the Xcode Command Line Tools. The full Xcode isn't needed.

```bash
xcode-select --install          # once, if you don't have the tools
git clone https://github.com/SudoShinichi/flactoaiff.git
cd flactoaiff
./build.sh
```

Then drag `build/FlacToAiff.app` into `/Applications`.

**Requirements:** macOS 12 Monterey or later, on Apple Silicon or Intel (universal binary).

## Usage

Open FlacToAiff and drag `.flac`, `.wav` or `.m4a` (Apple Lossless) files or folders onto the
window. The AIFFs are saved to the **Save to** folder, which is Downloads by default.

You can also drop files onto the Dock icon, even while the app isn't running, or right-click them
in Finder and choose **Open With → FlacToAiff**. FlacToAiff never makes itself the default app for
any file type.

### Settings

| Setting | What it does |
| --- | --- |
| **Save to** | The folder the AIFFs go to, for example a USB stick. |
| **Watch** | A folder whose new files convert automatically (see [Watch folder](#watch-folder)). |
| **Player** | What the files are for (see [Players](#players)). The text under the menu says what the player plays. |
| **Skip files the player already plays** | Only for DJ players; off by default. Files the player takes as they are, such as a 44.1 kHz FLAC on a CDJ-3000, are left alone. |

A changed setting applies to files you add afterwards. Files already queued keep the settings
they were added with.

### Players

| Player | Plays from USB | Converted to |
| --- | --- | --- |
| **Original (lossless)** (default) | — | Same sample rate and bit depth as the source. For Apple Music and software. |
| **CDJ-3000 / CDJ-3000X**, **CDJ-2000NXS2**, **OPUS-QUAD** | FLAC, WAV, ALAC, AIFF up to 24-bit / 96 kHz | At most 24-bit / 96 kHz |
| **XDJ-1000MK2** | FLAC, WAV, ALAC, AIFF up to 24-bit / 48 kHz | At most 24-bit / 48 kHz |
| **XDJ-RX3 / XDJ-XZ** | FLAC, WAV, AIFF up to 24-bit / 48 kHz | At most 24-bit / 48 kHz |
| **CDJ-2000NXS / CDJ-900NXS / XDJ-1000 / XDJ-700** | WAV, AIFF up to 24-bit / 48 kHz | At most 24-bit / 48 kHz |
| **Audio CD** | — | 16-bit / 44.1 kHz |

- Higher sample rates are lowered within their family, so the ratio is a whole number: 192 kHz
  becomes 96 or 48 kHz, and 176.4 kHz becomes 88.2 or 44.1 kHz.
- Lowering the bit depth adds dither.
- Files that already fit are converted without any change to the audio. A 16-bit / 44.1 kHz FLAC
  comes out identical with every choice.

Each player's limits, and where they come from, are listed in `Sources/Players.swift`. If your
player isn't listed, choose one with the same limits according to its manual, or **Original** if
it plays everything.

### Results

Every file gets a row in the window.

| Row | Meaning |
| --- | --- |
| `verified` | The audio is bit-for-bit identical to the source, and the format, length and tags were checked. FLAC audio is compared with the checksum stored in the FLAC, WAV audio with the WAV's own samples. |
| `tags verified` | The format, length and tags were checked. The audio couldn't be compared: it was resampled or dithered, or the source has no checksum (ALAC never has one). |
| `format checked` | The format and length were checked. There were no tags, and the audio couldn't be compared. |
| Already converted | This file's AIFF already exists in the output folder. It was left untouched. |
| Plays as is | "Skip files the player already plays" is on, and the player takes this file as it is. Nothing was written. |
| Red row | Nothing was saved. The row says why (see [Troubleshooting](#troubleshooting)). |

**Why ALAC is never `verified`.** ALAC files contain no checksum, and the only ALAC decoder on
the Mac is Apple's, the same one Apple Music uses. FlacToAiff checks the length, format and tags,
but has nothing independent to compare the audio with. This is a limit of what can be proven, not
a loss of quality.

To convert a track again, for example for a different player, delete its AIFF and add the source
file again.

### Watch folder

Click **Watch** and choose a folder. While the app is open, new FLAC, WAV and ALAC files that
appear there are converted into **Save to**. Albums unzipped or moved into the folder count too,
and their subfolders are kept: `Watch/Album/01.flac` becomes `Save to/Album/01.aiff`.

- A file is converted once it has stopped changing for 2 seconds. A file whose header doesn't
  record its length waits 30 seconds instead, because some encoders write that last.
- A download that stalls for longer shows an "incomplete" row, and converts once it's complete.
- Files that arrive while the app is closed are converted at the next launch.
- Files already in the folder when you start watching are left alone, even if you later rename
  them, move them within the folder or tag them in Finder. Changing a file's contents, for
  example editing its tags in a tag editor, makes it count as new.
- If the folder's drive isn't connected, watching starts as soon as it is.

### USB check

With a DJ player chosen, click **Check USB Stick…** and choose a stick or a folder on it. The
window lists each track the player won't play, and why:

- a format it doesn't play, such as FLAC on a CDJ-2000NXS, or OGG
- a sample rate or bit depth above its limit
- a floating-point or compressed WAV

It also warns when the stick itself is a problem: no player listed here reads APFS or NTFS, and
only some read exFAT. The last row says how many tracks will play.

The check never changes the stick. Replacing tracks on a stick breaks its rekordbox export, so the
fix is to convert the original files with the player chosen, then export them to the stick again
with rekordbox. **Reveal in Finder** selects the tracks that won't play.

### Tags

FLAC tags (Vorbis comments) are written as these ID3v2.3 frames:

| FLAC tag | ID3 frame | | FLAC tag | ID3 frame |
| --- | --- | --- | --- | --- |
| `TITLE` | Title | | `BPM` | BPM |
| `ARTIST` | Artist | | `INITIALKEY` | Key |
| `ALBUM` | Album | | `ORGANIZATION` / `LABEL` | Publisher |
| `ALBUMARTIST` | Album artist | | `DATE` / `YEAR` | Year |
| `GENRE` | Genre | | `TRACKNUMBER` / `DISCNUMBER` | Track / disc (with totals) |
| `COMPOSER` | Composer | | `COMMENT` | Comment |
| `REMIXER` | Remixer | | `ISRC` | ISRC |

- Other tags are kept as custom `TXXX` fields. Non-Latin text is kept.
- The year is taken from `DATE` in either order, so `2026-03-01` and `03.05.2026` both give 2026.
- Embedded pictures become cover art, front cover first, because players that show one picture
  show the first. Pictures that are only a web link are left out.

**WAV** tags are read from an embedded ID3 tag (v2.3 or v2.4, as many stores include) and from the
`LIST/INFO` chunk. Where both have a field, the ID3 tag is used.

**ALAC** tags are the iTunes ones: title, artist, album, album artist, genre, composer, year,
comment, copyright, track and disc numbers, BPM, cover art, and custom fields such as
`INITIALKEY`. Gapless and volume data (`iTunSMPB`, `iTunNORM`) is player data and isn't copied.

## How it works

1. **Convert.** `afconvert` decodes the source into a hidden temporary file in the output folder.
   Lossless output uses `-f AIFF -d BEI<depth>`. Resampling uses afconvert's highest-quality
   setting, `-r 127 --src-complexity bats`. Lowering the bit depth adds TPDF dither.
2. **Tag.** `afconvert` copies only the audio, so FlacToAiff reads the source's tags itself and
   adds them to the AIFF as an ID3v2.3 chunk.
3. **Check.**
   - The AIFF's format and length must match the source's header.
   - For lossless FLAC and WAV output, an MD5 of the AIFF's samples must equal the source's: the
     one stored in the FLAC, or one computed from the WAV's samples.
   - Every tag and picture must read back unchanged through AVFoundation, the framework Apple's
     own apps use.
4. **Save.** The file is renamed into place without replacing anything. On exFAT and FAT32, which
   lack an atomic no-replace rename, a fallback still guarantees a complete file under the final
   name.

## Limitations

- **No signed release.** You build the app yourself.
- **FLAC, WAV and ALAC input only.** Other formats are skipped.
  - An `.m4a` holding AAC is skipped, because as AIFF it would only be 5–10 times larger.
  - Floating-point and compressed WAVs are skipped, because they can't become a lossless AIFF.
    Export them as 24-bit WAV.
- **16, 20 and 24-bit FLAC only.** As of macOS 26, macOS decodes no other FLAC bit depth, so rare
  8, 12 or 32-bit FLACs fail with a message.
- **Tags are checked only through Apple's reader.** rekordbox and Serato aren't tested
  automatically, although both read ID3v2.3.
- **Changing the player doesn't redo existing files.** Delete the AIFFs first.
- **AIFFs made by versions before October 2026 don't record their source.** An existing
  `track.aiff` of that kind counts as converted for any source file named `track`.
- **The watch folder only works while the app is open.** On exFAT drives, renaming a file that
  arrived while the app was open may convert it again.

## Troubleshooting

**"FLAC is incomplete — only N% of the audio is there"** (or "WAV is incomplete"). The file is
shorter than its header says: it's still downloading or copying, or the download broke off. Wait
for it to finish, or download it again.

**"Couldn't read this ALAC file".** The `.m4a` is cut off or damaged. Let the download finish, or
download it again.

**"macOS can't decode 32-bit FLAC"** (or 8 or 12-bit). Save the file as 16 or 24-bit in an audio
editor, then add it again.

**"Skipped — floating-point WAV can't become a lossless AIFF".** Export the track from your DAW as
24-bit WAV, then add it again.

**"track.aiff already exists, made from a different file".** Two different files share a name,
for example `A/track.flac` and `B/track.flac` added to the same **Save to** folder. Nothing was
saved and the existing AIFF is untouched. Rename one of the files and add it again.

**"Audio doesn't match the FLAC's checksum — the FLAC may be damaged".** The decoded audio doesn't
match the checksum the FLAC was made with, so the FLAC file is probably corrupt. Download it again.

**"Tag check failed: …".** A tag didn't read back as it was written, so the file wasn't saved.
Please [open an issue](https://github.com/SudoShinichi/flactoaiff/issues) and include the source
file's tags.

**"Output folder not available".** The **Save to** folder was renamed or deleted, or its drive
isn't connected. Reconnect the drive or choose another folder. Watched files that failed for this
reason are tried again at the next launch.

**"Watch folder not available".** The watch folder was renamed or deleted, or its drive isn't
connected. Watching resumes by itself when the drive is back. A renamed or deleted folder has to be
chosen again under **Watch**.

**macOS says the app can't be opened.** Apps you build yourself open normally. A copy that came by
download or AirDrop is quarantined: right-click it and choose **Open** once, or run
`xattr -dr com.apple.quarantine FlacToAiff.app`.

**macOS asks for folder access.** The first time the app saves to Downloads, Desktop or Documents,
click **OK**. Open the app from Finder rather than running its binary in Terminal, so the
permission goes to FlacToAiff itself.

## Development

```bash
./build.sh && ./test.sh
arch -x86_64 ./test.sh          # the same checks on the Intel build, under Rosetta
```

`test.sh` rebuilds the app if the sources changed, then runs end-to-end checks on real FLAC, WAV
and ALAC files it generates itself. They cover:

- bit depths and sample rates for every player choice, including the FLAC depths macOS can't decode
- tags and artwork from all three formats, including unusual tags
- the output checks, with tampered and truncated files
- duplicate names, concurrent conversions and quitting mid-conversion
- the watch folder
- the USB check, on FAT32 and exFAT disk images and an APFS folder
- saving to an exFAT volume

A separate test binary, built with `-D TEST_HOOKS`, reaches failure paths that real files can't
trigger. Those hooks are never compiled into the app.

The app also runs from the command line:

```bash
FlacToAiff.app/Contents/MacOS/FlacToAiff --convert [<format>] <file-or-folder>... <output-dir>
FlacToAiff.app/Contents/MacOS/FlacToAiff --watch   [<format>] <watch-dir> <output-dir>
FlacToAiff.app/Contents/MacOS/FlacToAiff --check   --player <name> <folder>
# <format>: --format original|max96|max48|cd
#       or: --player cdj-3000|cdj-2000nxs2|opus-quad|xdj-1000mk2|xdj-rx3|cdj-2000nxs|original|cd [--skip-playable]
```

| Output | Meaning |
| --- | --- |
| `OK <path>`, tab, label | Converted |
| `SKIP <path>` | Already converted |
| `KEEP <name>`, tab, reason | Left alone by `--skip-playable` |
| `NOTE <name>: <text>` | A `--check` summary or note |
| `ERROR <name>: <reason>` (stderr) | Failed or won't play; the exit status is 1 |

| File | Purpose |
| --- | --- |
| `Sources/main.swift` | Window, settings bar, app delegate, command-line modes |
| `Sources/AudioSource.swift` | Input formats, one type each (FLAC, WAV, ALAC) |
| `Sources/Players.swift` | The player presets: each player's limits, with sources |
| `Sources/Converter.swift` | Output format, `afconvert`, saving without overwriting |
| `Sources/Tags.swift` | Header and tag reading for each format, ID3 writing, AIFF reading |
| `Sources/Verifier.swift` | Format, length, audio and tag checks |
| `Sources/USBCheck.swift` | The USB check (read-only) |
| `Sources/Jobs.swift` | Turns dropped files and folders into conversions |
| `Sources/FolderWatcher.swift` | Watch folder (FSEvents) and launch catch-up |
| `Sources/ConversionQueue.swift` | Background queue shared by all inputs |
| `Sources/Settings.swift` | Saved settings |
| `scripts/make-icon.swift` | Draws the app icon; run by `build.sh` |
| `scripts/make-flac.swift` | Writes FLACs of any bit depth for `test.sh` (macOS tools can't) |

## License

[MIT](LICENSE)
