# FlacToAiff — DJ Workflow Features: Design

Date: 2026-10-24

## Goal
Remove friction from the DJ library workflow with three features:

1. **Output & duplicates** — AIFFs go to a remembered, user-chosen folder; files already converted are skipped.
2. **Folders + Dock drop** — drop whole folders (structure kept), drop onto the Dock icon, or use Finder's Open With.
3. **CDJ mode** — optional cap at 24-bit / 48 kHz so every file plays on CDJ-2000-class players.

## Non-goals
- Watch folder, tag-based renaming, output verification, Music/rekordbox import (later candidates).
- "Next to original" output, or a Replace/Keep-both duplicate setting.
- 16/44.1 CDJ target, or a menu of targets.
- A separate Settings window.
- Re-converting a file when settings change (the user deletes the AIFF to redo it).

## Architecture

| Unit | Responsibility |
| --- | --- |
| `Sources/Settings.swift` (new) | `outputFolder: URL` (default `~/Downloads`) and `cdjMode: Bool` (default `false`), persisted in `UserDefaults`. Pure value access; no UI. |
| `Sources/ConversionQueue.swift` (new) | `ObservableObject`, main-actor state. `enqueue(_ urls: [URL])` accepts files and folders from any source, expands folders into jobs, converts serially on a background queue, publishes `rows` and `isWorking`. Single owner shared by the window and `AppDelegate`. |
| `Sources/Converter.swift` (changed) | `convert(flacURL:destDir:options:) -> Outcome`. Gains atomic publish, skip-if-exists and CDJ resampling. Still UI-free. |
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
- `☐ CDJ mode (max 24-bit / 48 kHz)` — checkbox.

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

### CDJ mode (off by default)

| Source bit depth | Output |
| --- | --- |
| ≤16 | 16 |
| 17–24 | 24 |
| >24 | 24 (CDJ) / 32 (normal) |

| Source sample rate | CDJ output |
| --- | --- |
| ≤48 000 | unchanged |
| 88 200, 176 400, 352 800 | 44 100 |
| 96 000, 192 000, 384 000 | 48 000 |
| other >48 000 | 48 000 |

- The rate is detected from `afinfo -x` (`sample_rate`), the same way as bit depth. If detection fails, the rate is left unchanged (no `@rate` passed).
- `afconvert -f AIFF -d BEI<depth>@<rate> -r 127 --src-complexity bats in out` is used only when resampling. The non-resampling command line is unchanged from today, so in-limit files stay bit-identical.
- The outcome records `(fromRate, toRate)` and/or `(fromDepth, toDepth)` when they differ. The row shows e.g. `→ track.aiff (96 → 48 kHz)`.

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
- `LSItemContentTypes = [org.xiph.flac]`, `CFBundleTypeRole = Viewer`, `LSHandlerRank = Alternate`. The app never becomes the default FLAC app.
- `LSItemContentTypes = [public.folder]`, `CFBundleTypeRole = Viewer`, `LSHandlerRank = None` (accept drops only).

`AppDelegate.application(_:open:)` enqueues the URLs. URLs that arrive before the window exists (cold launch) are enqueued once the queue is created in `applicationWillFinishLaunching`.

## CLI
```
FlacToAiff --convert [--cdj] <file-or-folder>... <outputDir>
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
5. **CDJ:**
   - 24/96 → 24/48 and 24/88.2 → 24/44.1 with `--cdj`;
   - 16/44.1 is unchanged with `--cdj`;
   - 24/96 stays 24/96 without `--cdj`.

   All checked via `afinfo`.
6. **Tags under CDJ:** the tag test is re-run with `--cdj` on a 96 kHz source.
7. **Arity:** `--convert` with fewer than 2 paths exits 2 with usage.

Manual checks (not scriptable):
- Dock drop with the app running and with the app closed.
- Finder Open With.
- The app is not offered as the default FLAC handler.
- The settings bar folder picker and checkbox persist across a relaunch.
- An unplugged output drive gives the error row.
