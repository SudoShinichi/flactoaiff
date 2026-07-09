# Code Review: FlacToAiff — 2026-07-09

**Scope:** `Sources/Converter.swift`, `Sources/main.swift`, `build.sh`, `test.sh`, `README.md`, design spec.

**Overall:** The core architecture is genuinely good — a UI-free converter core with a hidden CLI mode driven by a real end-to-end test is exactly the right shape for a 300-line app, and the exec-based (no shell) process invocation means filenames with spaces/quotes are safe by construction. The stderr-before-`waitUntilExit` read order in `run()` is correct. But the app makes three promises it doesn't keep — "quality preserved," "never overwrites," and "runs on macOS 12" — and each break is concrete and demonstrable.

Verification was performed against the built binary:
- `otool -l` reports `minos 15.0` (vs plist claim of 12.0).
- `codesign -dv` reports `flags=0x20002(adhoc,linker-signed)`, `Info.plist=not bound`, `TeamIdentifier=not set`.
- The built `.app` has no `com.apple.quarantine` xattr.

---

## Critical

### C1. Ships a binary that claims macOS 12 support but requires macOS 15
`build.sh:11-14` compiles with no `-target`, so swiftc uses the build machine's default deployment target. Verified on the built artifact: `LC_BUILD_VERSION: minos 15.0`, while `build.sh:28` writes `LSMinimumSystemVersion 12.0` into Info.plist. On macOS 12–14 the app will be killed at load time by dyld with a cryptic "requires a newer version" crash. Fix: `swiftc -target arm64-apple-macos12.0 ...` (and actually test the SwiftUI API surface against 12), or change the plist to match reality.

### C2. "Never overwrites" is violated by a second drop during a running batch
The drop zone stays active while `working == true` (`main.swift:102-105` — `onDrop` is never disabled, `handleDrop` returns `true` unconditionally). A second drop:
1. Resets `results`/`produced` (`main.swift:117-118`) while batch 1 is mid-flight.
2. Schedules a second `group.notify` block on the same **concurrent** global queue (`main.swift:142`), so two conversion loops run in parallel.
3. `Converter.uniqueOutputURL` (`Converter.swift:40-50`) is check-then-use with no reservation: both loops can compute the same candidate for identically named files, and `afconvert` **overwrites** existing outputs — breaking README.md:8's "Never overwrites" guarantee.
4. Both loops finish with `DispatchQueue.main.async { results = ...; produced = ... }` (`main.swift:158-162`) — last writer wins, so one batch's results and "Reveal in Finder" URLs silently vanish.

Within a single batch you're safe only by accident: the loop at `main.swift:145` is serial and `afconvert` creates the output file before the next `uniqueOutputURL` check. Minimal fix: `guard !working else { return false }` in `handleDrop`, plus atomically reserving the output name (create with `O_EXCL` before handing the path to afconvert).

---

## High

### H1. Bit-depth clamp silently destroys data for 20- and 32-bit FLAC
`Converter.swift:59`: `let depth = detectBitDepth(flacURL) == 24 ? 24 : 16`. FLAC supports 4–32 bits per sample:
- **20-bit source → BEI16**: truncation, quality loss, while README.md:7 says "Quality preserved."
- **32-bit source → BEI16**: not even clamped to 24. Two levels of loss.
- 8-bit → BEI16 is fine (lossless up-conversion).

Fix: `depth > 16 ? (depth > 24 ? 32 : 24) : 16` with BEI32 support, or at minimum `>= 17 → 24` plus a documented caveat.

### H2. `detectBitDepth` fails toward the lossy default
`Converter.swift:26, 35`: on any failure (afinfo missing, launch error, unparseable output) the function returns 16. For a 24-bit source that means silent quality loss with a green checkmark. The failure default should be the lossless direction (24) or should fail loudly.

### H3. Regex parsing is unanchored and scans the full afinfo output, including the file path
`Converter.swift:27-34`. afinfo's first output line echoes the file path. Both regexes use `range(of:options:.regularExpression)`, which returns the first match in the whole string. The fallback `(\d+)-bit` (`Converter.swift:31`) exists precisely for when the primary pattern fails — and in that world a track named `16-bit dreams.flac` or `8-bit anthem.flac` matches the filename echo line before any format line. Also, `out[range].filter(\.isNumber)` extracts digits from the whole match rather than capture group 1. Fix: parse `afinfo -x` XML deterministically, or use a capture group scoped to the `Data format:` line.

---

## Medium

### M1. Design-spec violation: no live per-file status, no cancel
The design doc promises "a live per-file list." The implementation publishes once, after the entire batch (`main.swift:143-163`). Drop 200 FLACs → static "Converting…" label, no progress, no count, no cancel. Fix: `DispatchQueue.main.async { results.append(row) }` per iteration.

### M2. Latent pipe deadlock in the process helpers
`Converter.swift:77` attaches a `Pipe()` to afconvert's stdout and never reads it; `Converter.swift:91` does the same for afinfo's stderr. If either tool writes more than the ~64KB pipe buffer to the unread pipe, it blocks and `readDataToEndOfFile` (`Converter.swift:79/93`) hangs forever. Use `FileHandle.nullDevice` for discarded streams.

### M3. `--convert` with wrong arity silently launches the GUI
`main.swift:8`: `if cliArgs.count >= 4 && cliArgs[1] == "--convert"`. `FlacToAiff --convert file.flac` (missing destDir) launches a window instead of a usage error. Fix: if `cliArgs[1] == "--convert"` and count is wrong, print usage and `exit(2)`.

### M4. No main menu: Cmd+Q, Cmd+W, Cmd+M are all dead
`main.swift:187-191` never sets `NSApp.mainMenu`. Without a menu there are no key equivalents. Add a minimal menu with a Quit item.

### M5. README's Gatekeeper section is wrong for the workflow it documents
README.md:22-25 says first launch is "blocked by Gatekeeper" and suggests `xattr -dr com.apple.quarantine`. Verified: the locally built app has no quarantine attribute (applied by browsers/AirDrop, not `swiftc`). For the build-it-yourself flow, first launch works with a plain double-click. "Unsigned" is also imprecise: the arm64 linker ad-hoc signs the binary.

### M6. TCC grants won't survive rebuilds
The ad-hoc, linker-signed binary has no stable identity (no Team ID, Info.plist not bound). macOS ties the Downloads TCC grant to code identity, so every `./build.sh` invalidates the previous grant. Mitigation: `codesign --force --sign - --identifier local.flactoaiff` after build. Note: running the binary directly from Terminal attributes the TCC prompt to Terminal, not the app.

---

## Low

### L1. Test suite never touches the GUI path — and the CLI test under-covers
- Zero coverage of `handleDrop`, provider decoding, concurrency, state updates (C2 and M1 untestable as structured).
- Only the 24-bit path is tested (test.sh:13). The 16-bit path is untested.
- Test 5 rejection (test.sh:33) is a pure extension check — can't fail unless someone deletes `Converter.swift:56`. No corrupt-FLAC test, no afconvert-stderr-propagation test, no multichannel, no non-44.1k, no spaces-in-filename.
- Reliance on `say` (test.sh:13) is nondeterministic and fails without the default voice.

### L2. Partial output files are left behind on failure
`Converter.swift:62-64` throws but never unlinks `output`. The next attempt's `uniqueOutputURL` sees the corpse and names the retry `song 2.aiff`. Add `try? FileManager.default.removeItem(at: output)` on the failure path.

### L3. Folders and Finder aliases produce unhelpful errors
Dropping a folder yields "Skipped — not a .flac file" per folder (`main.swift:146-148`). Detect the directory and message clearly. A Finder alias named `song.flac` passes the extension check and dies with raw afconvert stderr.

### L4. Non-resizable window contradicts the SwiftUI layout
`main.swift:173` omits `.resizable`, while `main.swift:56` sets `minWidth/minHeight` as if resizing were possible.

## Nits
- Dead branch: `reveal()`'s `produced.isEmpty` path (`main.swift:109-110`) is unreachable — button disabled exactly when that branch would run (`main.swift:49`).
- "Skipped — not a .flac file" string duplicated: `Converter.swift:11` and `main.swift:147`; extension check duplicated too (`main.swift:146`, `Converter.swift:56`).
- `window.isReleasedWhenClosed` defaults to `true` for programmatic NSWindows while `AppDelegate` holds a strong ref (`main.swift:168`). Set to `false`.
- Stray trailing ``` fence in design doc (line 56). No app icon.

---

## What's genuinely good
- Converter core / GUI separation with a real CLI seam — delivered as the design doc promises.
- `Process` with argument arrays — no shell injection surface.
- `test.sh` is real end-to-end with `afinfo` format verification, not mocks.
- Reading stderr to EOF before `waitUntilExit` (`Converter.swift:79-80`) is the correct deadlock-avoiding order.

## The 3 fixes to make first
1. **C1** — add `-target arm64-apple-macos12.0` (or fix the plist). Turns "crashes on launch below macOS 15" into a working app.
2. **H1+H2+H3 as one patch** — make bit-depth handling fail-safe: map `>16 → 24` (or add BEI32), default to 24 on detection failure, parse `afinfo -x` XML. This is the app's entire "quality preserved" value proposition.
3. **C2** — reject drops while `working`, reserve output names atomically. Kills the concurrent-batch race and the lost-results bug in one stroke.
