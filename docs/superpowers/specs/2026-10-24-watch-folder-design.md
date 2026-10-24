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
- **Folders moved in:** an event for a directory scans it for FLACs.
- **Finished-file check:** a candidate is polled every second. It is ready once its size and modification time are unchanged since the previous poll and the modification time is at least 2 s old. A candidate that disappears is dropped.
- **No double work:** a file handed off is remembered by path + size + modification time, and repeated events for it are ignored.
- **Output path:** `<Save to>/<subpath relative to the watch folder>/<name>.aiff`. Settings are read at the moment the file is handed off.
- **Catch-up at launch:** files under the watch folder whose "Date Added" (`addedToDirectoryDate`) is on or after the moment watching was turned on (`watchSince`) are queued once. Already-converted ones are skipped silently: catch-up does not add "Already converted" rows.
- **Watch folder missing** (renamed, unplugged): the settings bar shows `Watch folder not available`. Watching restarts when a folder is chosen again.
- The watch folder may contain or equal the Save to folder: outputs are `.aiff`, so they never trigger conversions.

## UI
A settings-bar row under Save to: `Watch: Off ▾`, or `Watch: <folder name> ▾`. Its menu has `Choose Folder…` and `Stop Watching`. The tooltip shows the full path. The empty drop zone adds `Watching <folder>` when a folder is set.

## Persistence
`Settings.watchFolder` (path, optional) and `Settings.watchSince` (date) are stored in UserDefaults. Choosing a folder sets `watchSince = now`.

## CLI (headless, used by tests)
`FlacToAiff --watch [--format original|max48|cd] <watchDir> <outputDir>` watches until killed. It prints the same `OK`/`SKIP`/`ERROR` lines as `--convert`, flushing each one immediately. There is no catch-up in the CLI.

## Architecture
| Unit | Responsibility |
| --- | --- |
| `FolderWatcher` (new) | FSEvents stream, finished-file polling, dedup. Reports ready FLAC URLs. UI-free. Also `catchUp(root:since:)`. |
| `Jobs.watched` (new) | Maps watched files to jobs with `destDir` = output root + relative subpath. |
| `ConversionQueue` | Gains `enqueueWatched(_:root:quietSkips:)` beside `enqueue`. |
| `Settings` | `watchFolder`, `watchSince`. |
| `AppDelegate` | Starts and stops the watcher when `watchFolder` changes; runs catch-up at launch. |

## Testing
`test.sh`, through `--watch`:
- A FLAC copied in converts.
- A FLAC written in two halves 1.5 s apart converts only once complete, giving the same frame count as a direct conversion and no `ERROR`.
- A folder moved in keeps its subfolder.
- Hidden and non-FLAC files are ignored.

Manual checks: the settings-bar menu, persistence across a relaunch, catch-up at launch, and the "not available" state.
