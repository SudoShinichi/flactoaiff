# FlacToAiff — Code Review

**Date:** 2026-10-26 · **Commit:** `bb94a83` (master) · **Scope:** all of `Sources/` (11 files,
about 2,600 lines), `build.sh`, `test.sh`, `scripts/`.

This file is listed in `.gitignore` and is not part of the repository.

**Status (2026-10-26):** findings 1, 2, 3, 5, 6, 7, 8 and 9 are fixed on branch `review-fixes-3`.
Finding 9 went further: AIFF can't exceed 4 GB on any drive, so the size check applies everywhere,
not only to FAT32. Finding 4 waits for a product decision; finding 10 is open.

## Summary

The code is in good shape. No finding loses audio, overwrites a file or saves an AIFF that failed
its checks. The core guarantees hold everywhere I traced them: hidden temp file plus no-replace
rename, length and format checks, sample-level MD5 for FLAC and WAV, tag read-back, cleanup on quit.

The new findings come from the features added in the last week (WAV, ALAC, players, USB check).
They are about edge cases in **identifying files** and **wording that's wrong in a few
situations**, not about safety. Two of them I reproduced on the current build.

| # | Severity | Area | Finding |
| --- | --- | --- | --- |
| 1 | Medium | Duplicates | An ALAC file (or a FLAC without a checksum) is identified by its file size, so a retag that changes the size makes it "a different file" |
| 2 | Medium | Errors | Every failed ALAC conversion says the file is damaged, even when the output drive is the problem |
| 3 | Medium | Performance | Adding a big WAV folder again re-reads every WAV in full just to say "Already converted" |
| 4 | Medium | Product | "Skip files the player already plays" leaves those files out of **Save to** entirely |
| 5 | Low–Medium | USB check | Plain `.aac` files are reported as unplayable; `.mp4` files are ignored |
| 6 | Low | Wording | The player text says "From the manufacturer's manual" for rows that come from a community table |
| 7 | Low | Wording | During a USB check, the window and the quit dialog say "Converting" |
| 8 | Low | Tags | Some iTunes and ID3 tags are dropped without notice (`gnre` genre, unsynchronised ID3) |
| 9 | Low | Limits | A hi-res AIFF over 4 GB fails on a FAT32 **Save to** only after the whole conversion |
| 10 | Medium | Tests | Everything in the app layer (queue, watch bookkeeping, settings migration) is tested only by hand |

Open from the previous review (still valid, not repeated in detail): folder paths instead of
bookmarks, one conversion at a time, strict TXXX check, `main.swift` size, bundle ID and version,
tags in a FLAC's leading ID3 block ignored. See [Still open](#still-open-from-earlier-reviews).

---

## Findings

### 1. ALAC files are identified by size — Medium

**Where:** `Sources/AudioSource.swift:37` (`fingerprint`), used by `Converter.existing`
(`Sources/Converter.swift:185`).

The fingerprint is the audio checksum when the source has one, else the file size. FLAC normally
has an MD5 and WAV gets one computed, but **ALAC never has one**, and some FLAC encoders leave the
MD5 empty. For those files the size is the identity.

**Reproduced:** I converted an ALAC file, then added the same file with 108 bytes of padding
appended (as a tag editor does when it runs out of room). Result:

```
ERROR song.m4a: song.aiff already exists, made from a different file — rename one of them and add it again
```

Retagging in Apple Music or a tag editor only changes the size when the tags outgrow the padding,
so this won't happen every time, which makes it more confusing when it does.

**Fix:** give ALAC an audio-based fingerprint. The audio lives in the `mdat` atom and tags live
in `moov/udta`, so an MD5 of the `mdat` payload (or of the packet table plus total frames) doesn't
change on retagging. A cheaper fallback is `frames + rate + channels + bits`, which is unique
enough for same-named files in one folder. Apply the same fallback to FLACs without an MD5.

### 2. Every failed ALAC conversion blames the file — Medium

**Where:** `Sources/AudioSource.swift:186`, used at `Sources/Converter.swift:150`.

`AlacSource.decodeFailureReason` always returns "Couldn't read this ALAC file — it may still be
downloading, or be damaged", and the converter uses it for **any** non-zero afconvert exit. If
afconvert fails on the output side, the message points at the wrong file. Examples: the output
drive is full, FAT32's 4 GB limit is reached, or the permissions are wrong. `Jobs.run` only
catches a missing **Save to**, not a full one.

**Fix:** use the reason only when the input is the problem. Either check afconvert's error text
(it says "Couldn't open input file") or open the file again with ExtAudioFile after the failure. If
it opens, show afconvert's own message.

### 3. Re-adding a big WAV folder re-hashes every WAV — Medium

**Where:** `Sources/AudioSource.swift:37` with `WavSource.audioChecksum`
(`Sources/AudioSource.swift:119` and `hashSamples` at line 128), called from `Converter.existing`.

When the AIFF already exists, the fingerprint is compared, and for WAV that means an MD5 of the
whole data chunk. Dropping a 500-track WAV folder a second time reads every byte of every WAV
(about 25 GB for 500 typical tracks) before it can say "Already converted". During a conversion
the hash is needed anyway for the audio check, so only the skip path is wasteful.

**Fix:** record a cheap identity next to the MD5 in the AIFF, for example
`md5:… frames:… format:…`. On a skip, compare only the cheap part: different frames or format
means a different file, with no hashing needed. Matching frames and format count as the same file.
Two different WAVs with the same name, the exact same length and the same format are rare enough to
accept. Hash only when converting, where the audio check needs it anyway.

### 4. "Skip files the player already plays" leaves files out of Save to — Medium (product)

**Where:** `Sources/Jobs.swift:134`.

A file the player can play gets a "Plays as is — not converted" row, and nothing is written. That
fits "Save to = a library folder". But a common setup is "Save to = the USB stick": with the option
on, the stick ends up with only the converted tracks and none of the playable ones. The row text
says "not converted", not "not copied", so this is easy to miss.

**Options:**
- Copy playable files unchanged into **Save to** (same folder structure), and label the row
  "Copied as is". This is the most useful behaviour, but it's a change of meaning.
- Keep the behaviour and say it plainly: "Left where it is — not copied to Save to", plus a line
  in the README.

This is your call; I'd lean towards copying.

### 5. USB check: `.aac` reported unplayable, `.mp4` ignored — Low–Medium

**Where:** `Sources/USBCheck.swift:8` and the `default:` branch after line 58.

`aac` is in the list of audio extensions the check looks at, but no input format handles `.aac`,
so it falls through to "AAC — the … doesn't play this format". The manuals list AAC as `.m4a`,
`.aac` and `.mp4`, so this is wrong.

**Reproduced:** a stick with `track.aac` and an AAC `.m4a`: the `.m4a` counts as playable, the
`.aac` doesn't.

**Fix:** treat `aac` like `mp3` (playable on every listed player), and add `mp4` to the extensions
handled the same way. Add both to check 47.

### 6. "From the manufacturer's manual" overstates the sources — Low

**Where:** `Sources/Players.swift:59`.

The text under the Player menu ends with "From the manufacturer's manual" for every DJ player. The
XDJ-1000MK2, XDJ-RX3/XZ, OPUS-QUAD and part of the CDJ-2000NXS row come from a community table
built from the manuals, not from a manual I opened. The README now says "manuals and spec sheets".
The app should say the same.

**Fix:** "Based on the manufacturer's specifications. Check your player's manual." for all rows,
or a per-player source flag.

### 7. "Converting" during a USB check — Low

**Where:** `Sources/main.swift:225` and `Sources/main.swift:441`.

`isWorking` is true during a check, so an empty window says "Converting…". Quitting during a
check asks "Quit while converting?" and says files will be skipped. Neither is true for a
read-only check.

**Fix:** track what's running (a `ConversionQueue.activity` enum, or a separate `isChecking`) and
word both places for it. Quitting during a check needs no confirmation.

### 8. Tags dropped without notice — Low

**Where:** `Sources/Tags.swift:272` (iTunes keys), `Sources/Tags.swift:291` (ID3 header).

- **`gnre`**: older iTunes files store standard genres as a numeric ID3v1 index in `gnre`
  instead of text in `©gen`. These ALAC files lose their genre.
- **Other iTunes fields** that are ignored: grouping (`©grp`), compilation (`cpil`), lyrics
  (`©lyr`), sort names.
- **ID3 with unsynchronisation** (header flag `0x80`) in a WAV is skipped as a whole, so the WAV
  converts with only its INFO tags.

None of these blocks a conversion, and the verification checks what was written, so nothing is
reported wrongly. They just fall short of "keeps the tags".

**Fix:** map `gnre` through the ID3v1 genre table; add `©grp` (→ `TIT1`) and `cpil`
(→ `TCMP`); undo unsynchronisation (replace `FF 00` with `FF`) instead of giving up.

### 9. FAT32's 4 GB limit is found late — Low

**Where:** `Sources/Converter.swift:148`.

A 2-hour 24-bit / 96 kHz stereo mix is about 4.1 GB as AIFF. On a FAT32 **Save to**, afconvert
fails when the temp file reaches 4 GB, after most of the work. The message is afconvert's (and,
for ALAC, finding 2's wrong one).

**Fix:** before converting, estimate the output size (`frames × channels × depth/8`). If the
volume is FAT32 (`statfs` type `msdos`) and the estimate is over 4 GB, fail at once with "Too
large for a FAT32 drive (4 GB per file) — use exFAT or Mac OS Extended".

### 10. The app layer has no automated tests — Medium

**Where:** `ConversionQueue`, `AppDelegate` (watch start/stop/follow, `recordWatchedUntil`),
`Settings` (migration from the old Format setting), `DropView`.

`test.sh` is thorough, with 47 end-to-end checks through the command line. But the CLI bypasses
`ConversionQueue` and `AppDelegate` completely. That's where the most delicate logic lives: the
retry-at-next-launch bookkeeping, watch sessions, the catch-up start date, the settings migration.
All of it was verified by hand once and would regress silently.

**Fix:** the queue and settings are plain classes. A small test target (or a `--selftest` mode
behind `TEST_HOOKS`) could drive `ConversionQueue` with a temporary `UserDefaults` suite and check
`oldestUnfinishedWatched`, `forgetWatched` and the migration. That's a few hours of work and covers
the riskiest untested code.

---

## Smaller notes

- **Deprecated API:** `AVURLAsset.metadata(forFormat:)` (Verifier, Tags) is deprecated from macOS
  13 in favour of `load(.metadata)`. It works and builds without warnings at the macOS 12 target,
  but will warn once the minimum moves up.
- **Window width:** with a DJ player chosen, the toggle and the "Check USB Stick…" button share
  one row at the minimum width of 400 pt. Check that nothing truncates; otherwise put the button on
  its own row.
- **AAC folders:** dropping an iTunes folder full of AAC gives one "Skipped" row per file. A
  single "N AAC files skipped" row per folder would be easier to read.
- **USB check and WAV_EXTENSIBLE:** several sources say older firmware rejects some extensible-header
  WAVs. The check could add a warning (not an error) for those on players other than the CDJ-3000
  class, once that's confirmed on real gear.
- **`test.sh` size:** 858 lines in one file. Splitting it into `tests/*.sh` sourced by a runner
  would make single checks runnable on their own. Not urgent.

## Still open from earlier reviews

| Earlier finding | Status |
| --- | --- |
| Folders stored as paths: a renamed stick breaks **Save to** and **Watch** | Open |
| One conversion at a time | Open |
| One odd TXXX value blocks the whole file | Open (product call) |
| `main.swift` mixes CLI, view and app delegate (now 501 lines) | Open |
| Bundle ID `local.flactoaiff`, version `1.0` fixed in `build.sh` | Open (needs your developer account) |
| Tags in an ID3 block in front of a FLAC are ignored | Open; the WAV ID3 reader from #13 could now handle them |

## What's solid

- **Saving:** `renamex_np(RENAME_EXCL)` with a `link()` and check-then-rename fallback; temp files
  are registered and removed on quit; stale temp files are cleaned by checking the writer's PID.
- **Checks:** the audio comparison never relies on Apple's decoder for FLAC and WAV, and the labels
  never claim more than was checked. ALAC is labelled honestly.
- **Input formats:** one `AudioSource` type each. WAV and ALAC were added without touching the
  converter or the watcher, which shows the interface works.
- **Watch folder:** file IDs instead of paths, Date Added of parent folders, settle times, catch-up
  that can't skip files still queued at quit, drives that mount later.
- **Tests:** 47 end-to-end checks on real files, run natively and under Rosetta, including tampered,
  truncated and unusual files, FAT32/exFAT images and races. Test hooks are compiled out of the app.
