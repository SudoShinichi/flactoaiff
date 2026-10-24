# Watch Folder — Design

**Date:** 2026-10-24. The user skipped the design questions ("start"), so every decision below is the implementer's call.

## Intent
New FLACs (Bandcamp/Beatport downloads, unzipped albums) should become AIFFs without dragging them onto the window. Choose a folder once; while the app runs, FLACs that land there are converted with the current Save to / Format settings, and their rows appear in the window like drops.

## Goals
- One watch folder, set from the settings bar. Off by default.
- New `.flac` files anywhere under it, including inside subfolders and folders moved in, convert automatically.
- Only finished files are converted, never a download or unzip that is still being written.
- FLACs added while the app was quit are converted at the next launch.
- Already-converted outputs are skipped, as with drops.

## Non-goals
- Converting a watch folder's existing backlog when watching is turned on. Drop the folder for that.
- Several watch folders, or running without the app open (login item, background agent).
- Deleting or moving the source FLAC afterwards.

## Behavior
- **Detection:** FSEvents with file-level events on the watch folder, recursive. Only regular, non-hidden `*.flac` files count. Hidden path components and packages are ignored, as in folder drops.
- **Folders moved in:** an event for a directory flagged Created or Renamed scans it for FLACs.
- **Finished-file check:** a candidate is polled every second. It is ready once it is non-empty (Firefox first creates an empty placeholder), its size and modification time are unchanged since the previous poll, and the modification time is at least 2 s old. A candidate that disappears is dropped.
- **Stalled writers:** a writer can pause for more than 2 s (slow network or USB copy, `curl`). `Converter` therefore checks every output's frame count against the FLAC's STREAMINFO total. Resampled lengths are expected within ±2 frames. On a mismatch it fails with `FLAC is incomplete — only N% of the audio is there` and publishes nothing. When the file changes again its size and modification time differ from what was handed off, so it is handed off again. The check also protects drops.
- **No double work:** a file handed off is remembered by path + size + modification time, and repeated events for it are ignored.
- **Dropped events:** on `MustScanSubDirs`, the given folder is rescanned. Only files that arrived since watching started are queued, using the catch-up rule below.
- **Output path:** `<Save to>/<subpath relative to the watch folder>/<name>.aiff`. Settings are read at the moment the file is handed off.
- **Catch-up at launch:** FLACs are found by the same finished-file check, and their "Already converted" results stay quiet. A FLAC counts if its Finder "Date Added" is on or after `watchedUntil − 2 min`, or if that is true of any folder between it and the watch folder (a folder moved in keeps its files' old dates). Without Date Added (exFAT/FAT), the creation date is used. The 2 minutes cover files that were still settling at quit.
- **`watchedUntil`:** set to now when a folder is chosen, every minute while watching, and at quit. So catch-up covers only the time nothing was watching, and moving converted AIFFs out of Save to doesn't bring them back.
- **Stopping:** `stop()` invalidates the stream on the watcher's own queue, and no `onReady` follows it. AppDelegate also drops batches from a watcher it has replaced or stopped.
- **Watch folder missing** (renamed, unplugged): the settings bar shows `Watch folder not available`. Watching restarts when a folder is chosen again, or at the next launch.
- The watch folder may contain or equal the Save to folder: outputs are `.aiff` and temp files are hidden, so they never trigger conversions.
- **Known limitations:** moving or renaming FLACs inside the watch folder counts as an arrival and converts them. A tag edit on an already-converted FLAC adds an "Already converted" row and doesn't update the AIFF.

## UI
A settings-bar row under Save to: `Watch: Off ▾`, or `Watch: <folder name> ▾`. Its menu has `Choose Folder…` and `Stop Watching`. The tooltip shows the full path. The empty drop zone adds `Watching <folder>` when a folder is set.

## Persistence
`Settings.watchFolder` (path, optional) and `Settings.watchedUntil` (date) are stored in UserDefaults.

## CLI (headless, used by tests)
`FlacToAiff --watch [--format original|max48|cd] [--catch-up-since <unix-time>] <watchDir> <outputDir>` watches until killed. It prints `WATCHING <path>` to stderr once the stream has started, then the same `OK`/`SKIP`/`ERROR` lines as `--convert`, flushing each one immediately. `--catch-up-since` runs the launch catch-up from that time.

## Architecture
| Unit | Responsibility |
| --- | --- |
| `FolderWatcher` (new) | FSEvents stream, finished-file polling, dedup, catch-up (`start(catchingUpSince:)`). Reports ready FLAC URLs and whether they came from catch-up. UI-free. |
| `Jobs.watched` (new) | Maps watched files to jobs with `destDir` = output root + relative subpath. |
| `ConversionQueue` | Gains `enqueueWatched(_:root:quietSkips:)` beside `enqueue`. |
| `Settings` | `watchFolder`, `watchedUntil`. |
| `AppDelegate` | Starts and stops the watcher when `watchFolder` changes, starts it with catch-up at launch, and records `watchedUntil`. |

## Testing
`test.sh`, through `--watch`:
- A FLAC copied in converts.
- A FLAC written in two halves 1 s apart converts only once complete, giving the same frame count as a direct conversion and no `ERROR`.
- A folder moved in keeps its subfolder.
- Hidden and non-FLAC files are ignored.
- A truncated FLAC dropped directly fails as incomplete and publishes nothing.
- A writer that stalls 3.5 s ends as a full-length AIFF. A Firefox-style empty placeholder gives no `ERROR`.
- `--catch-up-since` converts a FLAC added after that time and the FLACs of a folder moved in after it, but not a FLAC that was already there.
- Tests wait for the `WATCHING` line instead of sleeping.

Manual checks: the settings-bar menu, persistence across a relaunch, catch-up at launch (including that moving converted AIFFs away doesn't bring them back), and the "not available" state.
