# FlacToAiff — DJ Workflow Features: Design

Date: 2026-10-24

## Goal
Remove friction from the DJ library workflow with three features:

1. **Output & duplicates** — AIFFs go to a remembered, user-chosen folder; files already converted are skipped.
2. **Folders + Dock drop** — drop whole folders (structure kept), drop onto the Dock icon, or use Finder's Open With.
3. **Compatibility formats** — a Format menu: Original (lossless), CDJ (max 24-bit / 48 kHz) or CD (16-bit / 44.1 kHz). Each mode explains which players it is for.

## Non-goals
- Watch folder, tag-based renaming, output verification, Music/rekordbox import (later candidates).
- "Next to original" output, or a Replace/Keep-both duplicate setting.
- More than these three modes (the enum makes adding one easy later).
- A separate Settings window.
- Re-converting a file when settings change (the user deletes the AIFF to redo it).

## Architecture

| Unit | Responsibility |
| --- | --- |
| `Sources/Settings.swift` (new) | `outputFolder: URL` (default `~/Downloads`) and `mode: OutputMode` (default `.original`, stored by raw value), persisted in `UserDefaults`. Pure value access; no UI. |
| `Sources/ConversionQueue.swift` (new) | `ObservableObject`, main-actor state. `enqueue(_ urls: [URL])` accepts files and folders from any source, expands folders into jobs, converts serially on a background queue, publishes `rows` and `isWorking`. Single owner shared by the window and `AppDelegate`. |
| `Sources/Converter.swift` (changed) | `convert(flacURL:destDir:options:) -> Outcome`. Gains atomic publish, skip-if-exists and format modes (resampling/dither). Still UI-free. |
| `Sources/Tags.swift` (unchanged) | Tags are appended to the temporary file before it is published. |
| `Sources/main.swift` (changed) | `DropView` only draws queue state plus the settings bar. `AppDelegate` creates the queue, handles `application(_:open:)`, and passes URLs to it. CLI mode is extended. |

### Data flow
```
Drop on window ─┐
Dock / Open With ┼─▶ ConversionQueue.enqueue(urls)
CLI --convert   ─┘        │ expand folders → [Job(source, destDir)]
                          ▼
                 Converter.convert(source, destDir, options)  (serial, background)
                          ▼
                 Outcome → Row (main thread) → DropView
```
The CLI uses the queue's folder expansion and `Converter` directly, synchronously, with no UI.

## Settings bar (main window)
A slim row under the drop zone:

- `Save to: <folder name> ▾` — opens an `NSOpenPanel` for choosing a directory. Tooltip shows the full path.
- `Format: <mode title> ▾` — menu with the three modes, on its own row.
- One line of secondary text under it: the selected mode's explanation. It updates on change.

Both persist across launches. Changes apply to files enqueued after the change.

## Conversion behavior

### Output naming and duplicates
- Target is `destDir/<basename>.aiff`. If it already exists → **skip**, outcome `.alreadyConverted`. There is no `song 2.aiff` numbering any more.
- **Atomic publish:** convert to a temp file in `destDir`, append the ID3 chunk, then publish with `renamex_np(tmp, final, RENAME_EXCL)`.
  - The final name therefore only ever refers to a complete file, so "exists → skip" is safe.
  - If `RENAME_EXCL` fails with `EEXIST` (a concurrent conversion won), delete the temp file and report `.alreadyConverted`.
- **Temp name:** `.<basename>.<pid>.<n>.aiff.partial`, created with `O_CREAT|O_EXCL`. `n` is a per-process counter, so concurrent writers never share a temp file.
- **Stale cleanup:** before converting, delete any `.<basename>.<pid>.*.aiff.partial` whose PID is not a live process (crash leftovers).
- Any failure after the temp file is created deletes it.

### Output formats (compatibility modes)
A setting with three modes. `Original` is the default.

| Mode (`OutputMode`) | Menu title | Output | Explanation shown under the menu |
| --- | --- | --- | --- |
| `original` | Original (lossless) | Depth matched (≤16→16, 17–24→24, >24→32), rate unchanged | Unchanged quality. For CDJ-3000/3000X, CDJ-2000NXS2 (USB/SD), rekordbox, Serato and Music. |
| `max48` | CDJ: max 24-bit / 48 kHz | Depth as Original but capped at 24. Rate >48 kHz → 44.1 kHz if a multiple of 44 100, else 48 kHz. ≤48 kHz unchanged. | For CDJ-2000NXS, 2000, 900NXS, 850, 350 and XDJ-1000MK2: hi-res files are lowered to 48 kHz / 24-bit. |
| `cd` | CD: 16-bit / 44.1 kHz | Always 16-bit / 44.1 kHz. TPDF dither (`--dither 1`) when the source is >16-bit or its depth is unknown. | For burning audio CDs for CD-only players (CDJ-1000MK3, 800MK2, 400): everything becomes 16-bit / 44.1 kHz. |

- The model lists come from third-party compatibility guides and Pioneer manual excerpts (researched 2026-10-24). The in-app text names only these models.
- The rate is detected from `afinfo -x` (`track/sample_rate`), the same way as bit depth.
  - **max48:** if detection fails, the rate is left unchanged (no `@rate`).
  - **cd:** if detection fails, it resamples to 44.1 kHz anyway; skipped only when the source is known to be 44.1 kHz.
- **Resampling:** `afconvert -f AIFF -d BEI<depth>@<rate> -r 127 --src-complexity bats [--dither 1] in out`.
- **No resampling:** `afconvert -f AIFF -d BEI<depth> [--dither 1] in out`.
- Without resampling or dither, the command line is unchanged from today, so in-limit files stay bit-identical. In particular, a 16/44.1 source in `cd` mode is bit-identical to `original`.
- **Row note:** the outcome lists what was reduced, e.g. `→ track.aiff (96 → 44.1 kHz, 24 → 16-bit)`.

### Folder expansion
- Recursive enumeration that skips hidden files and packages. Names starting with `.` exclude `._*` AppleDouble files.
- Only `.flac` (case-insensitive) files become jobs; other files inside folders are ignored silently.
- Job `destDir` = `outputFolder/<droppedFolderName>/<relative subpath>`. Directories are created only when a job starts converting; a skipped job never creates them. If the job fails, any directories it created are removed again if they are empty, so no empty folders are left behind.
- A dropped folder with zero FLACs produces one row: `No .flac files found`.
- A dropped single non-FLAC file still produces `Skipped — not a .flac file`.
- Aliases are resolved, as today.

### Queueing
- `enqueue` while working appends jobs. Rows accumulate. Reveal/Clear show when `isWorking == false`.
- `Clear` is disabled while working.

### Row outcomes
| Outcome | Icon | Detail |
| --- | --- | --- |
| converted | green ✓ | `→ name.aiff` (+ resample note) |
| alreadyConverted | grey ⏭ | `Already converted` |
| skipped | grey | reason |
| failed | red ✗ | error message |

`Reveal in Finder` selects converted and already-converted outputs.

### Output folder unavailable
If `outputFolder` does not exist or is not writable, each job fails with `Output folder not available — choose another in “Save to”`. There is no fallback to Downloads.

## Dock / Open With
`Info.plist` gains `CFBundleDocumentTypes`:
- `LSItemContentTypes = [org.xiph.flac]`, `CFBundleTypeRole = Viewer`, `LSHandlerRank = None` (accept drops only).
  - `Alternate` was tried first. It made the app the *default* FLAC handler: QuickTime, the only other FLAC app, claims audio only generically, so the exact-type match won.
  - With `None`, QuickTime stays the default and Dock drops still work (verified 2026-10-24). The app is reachable via Open With → Other…, not the short list.
- `LSItemContentTypes = [public.folder]`, `CFBundleTypeRole = Viewer`, `LSHandlerRank = None` (accept drops only).

`AppDelegate.application(_:open:)` enqueues the URLs. URLs that arrive before the window exists (cold launch) are enqueued once the queue is created in `applicationWillFinishLaunching`.

## CLI
```
FlacToAiff --convert [--format original|max48|cd] <file-or-folder>... <outputDir>
```
- Prints one line per job: `OK <path>`, `SKIP <path>` (already converted), or `ERROR <name>: <message>` to stderr.
- Exit codes:
  - `0` — all jobs converted or skipped
  - `1` — any job failed
  - `2` — usage error (no inputs or missing outputDir)

## Testing (`test.sh`)
Existing checks stay, except check 4 (auto-rename), which becomes a duplicate check. New or changed checks:

1. **Duplicate:** a second conversion of the same file prints `SKIP`, exits 0, and leaves exactly one AIFF.
2. **No broken outputs:** a corrupt FLAC leaves no `.aiff` and no `*.partial`. A planted stale `.tone.99999.0.aiff.partial` (dead PID) does not block conversion and is removed.
3. **Race:** 4 parallel conversions of one file into one dir produce exactly 1 AIFF, which passes `afinfo`. At least 3 runs print `SKIP`.
4. **Folders:** a tree with nested FLACs, a `.jpg`, `._x.flac` and a FLAC-less subfolder produces the mirrored tree, real tracks only, and no empty dirs.
5. **Formats:**
   - `max48`: 24/96 → 24/48, 24/88.2 → 24/44.1, and 16/44.1 unchanged.
   - `cd`: 24/96 → 16/44.1, 24/44.1 → 16/44.1, and a 16/44.1 source is byte-identical to its `original` output.
   - Default (no `--format`): 24/96 stays 24/96.
   - An unknown `--format` value exits 2.

   All checked via `afinfo`.
6. **Tags under CDJ:** the tag test is re-run with `--format cd` on a 96 kHz source.
7. **Arity:** `--convert` with fewer than 2 paths exits 2 with usage.

Manual checks (not scriptable):
- Dock drop with the app running and with the app closed.
- Finder Open With.
- The app is not offered as the default FLAC handler.
- The settings bar folder picker and Format menu persist across a relaunch.
- An unplugged output drive gives the error row.
