# DJ Workflow Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add skip-duplicates with atomic output, an optional CDJ mode (max 24-bit / 48 kHz), folder drops that keep their structure, a remembered output folder, and Dock / Open With input.

**Architecture:**
- `Converter` gains atomic temp-file → `renamex_np(RENAME_EXCL)` publishing, which makes "exists → skip" safe, plus CDJ format planning.
- A new UI-free `Jobs` layer expands dropped files and folders into work items and runs them into result `Row`s. The CLI and the new `ConversionQueue` both use it.
- `ConversionQueue` (an `ObservableObject`) is fed by window drops and by `AppDelegate.application(_:open:)`, and drives `DropView`.
- `Settings` persists the output folder and CDJ mode.

**Tech Stack:**
- Swift + SwiftUI/AppKit, compiled with `swiftc` (no Xcode).
- `afconvert` / `afinfo`.
- Bash end-to-end tests (`test.sh`) through the headless `--convert` mode.

**Spec:** `docs/superpowers/specs/2026-10-24-dj-workflow-design.md`

## Global Constraints

- Target `arm64-apple-macos12.0`: no APIs newer than macOS 12 (e.g. no `OSAllocatedUnfairLock`; use `NSLock`).
- No third-party dependencies; audio work goes through `/usr/bin/afconvert` and `/usr/bin/afinfo` only.
- Files already within limits must be converted with today's exact command line (`afconvert -f AIFF -d BEI<depth> in out`), so output stays bit-identical.
- CDJ mode is off by default.
- User-facing strings, verbatim:
  - `Already converted`
  - `No .flac files found`
  - `Skipped — not a .flac file`
  - `Output folder not available — choose another in “Save to”`
- CLI contract:
  - `FlacToAiff --convert [--cdj] <file-or-folder>... <outputDir>`
  - prints `OK <path>` / `SKIP <path>` on stdout, and `ERROR <name>: <message>` on stderr
  - exits 0 when all are OK/SKIP, 1 if any failed or was skipped as non-FLAC, 2 on usage error
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Verify with `./build.sh && ./test.sh` from the repo root. The suite must end with `PASS`.

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `Sources/Converter.swift` | modify | Single-file conversion: atomic publish, skip-if-exists, stale-partial cleanup, CDJ format planning. Returns `Outcome`. |
| `Sources/Jobs.swift` | create | `Job`, `WorkItem`, `Row`. `Jobs.expand` (files/folders → work) and `Jobs.run` (work → `Row`). UI-free; used by the CLI and the queue. *(The spec placed this inside `ConversionQueue.swift`; it is split out so the CLI doesn't depend on the observable queue.)* |
| `Sources/Settings.swift` | create | Persisted `outputFolder` / `cdjMode`. |
| `Sources/ConversionQueue.swift` | create | Observable serial pipeline: `enqueue`, `rows`, `isWorking`, `outputs`, `clear`. |
| `Sources/main.swift` | modify | CLI parsing; `DropView` (drop zone, settings bar, rows); `AppDelegate` (owns settings and queue, `application(_:open:)`). |
| `build.sh` | modify | Compile `Sources/*.swift`; `CFBundleDocumentTypes` in `Info.plist`. |
| `test.sh` | modify | New and changed end-to-end checks. |
| `README.md` | modify | Feature and usage docs kept true after each task. |

---

### Task 1: Atomic output and skip-if-already-converted

**Files:**
- Modify: `Sources/Converter.swift` (replace `reserve`, `uniqueOutputURL`, `convert`; add `Outcome`, `saveFailed`)
- Modify: `Sources/main.swift` (the two `Converter.convert` call sites)
- Modify: `test.sh` (checks 4, 8, 9, new 12; PASS line)
- Modify: `README.md`

**Interfaces:**
- Produces:
  - `enum Outcome { case converted(URL, note: String?); case alreadyConverted(URL) }`
  - `Converter.convert(flacURL: URL, destDir: URL) throws -> Outcome`
  - `ConvertError.saveFailed(String)`
  - CLI prints `SKIP <path>` for already-converted files.

- [ ] **Step 1: Write the failing tests in `test.sh`**

Replace check 4:

```bash
echo "4. Converting the same file again skips it (no 'tone 2.aiff')…"
SECOND="$("$BIN" --convert "$TMP/tone.flac" "$DEST")"
[ "$SECOND" = "SKIP $DEST/tone.aiff" ] || { echo "FAIL: expected SKIP, got: $SECOND"; exit 1; }
[ ! -e "$DEST/tone 2.aiff" ] || { echo "FAIL: duplicate 'tone 2.aiff' created"; exit 1; }
```

In check 8, after the existing `ls "$DEST" | grep -q "^corrupt" …` line, add:

```bash
ls -A "$DEST" | grep -q "\.partial$" && { echo "FAIL: temp .partial file left behind"; exit 1; }
```

Replace check 9:

```bash
echo "9. Concurrent conversions of one file: exactly one complete AIFF, the rest SKIP…"
DEST2="$TMP/race"
for i in 1 2 3 4; do "$BIN" --convert "$TMP/tone.flac" "$DEST2" > "$TMP/race.$i" & done
wait
COUNT="$(ls -A "$DEST2" | wc -l | tr -d ' ')"
[ "$COUNT" -eq 1 ] || { echo "FAIL: expected 1 file, got $COUNT"; ls -A "$DEST2"; exit 1; }
afinfo "$DEST2/tone.aiff" | grep -q "24-bit big-endian signed integer" \
    || { echo "FAIL: raced output is not a valid 24-bit AIFF"; exit 1; }
SKIPS="$(cat "$TMP"/race.* | grep -c '^SKIP')"
[ "$SKIPS" -eq 3 ] || { echo "FAIL: expected 3 SKIP lines, got $SKIPS"; cat "$TMP"/race.*; exit 1; }
```

After check 11 (before the final blank `echo`), add:

```bash
echo "12. A crash leftover (.partial of a dead process) doesn't block conversion and is removed…"
DEST3="$TMP/stale"; mkdir -p "$DEST3"
( : ) & DEAD=$!; wait "$DEAD"     # a PID that is guaranteed to be gone
echo junk > "$DEST3/.tone.$DEAD.0.aiff.partial"
"$BIN" --convert "$TMP/tone.flac" "$DEST3" >/dev/null
[ -f "$DEST3/tone.aiff" ] || { echo "FAIL: conversion blocked by stale partial"; exit 1; }
[ ! -e "$DEST3/.tone.$DEAD.0.aiff.partial" ] || { echo "FAIL: stale partial not cleaned up"; exit 1; }
```

Replace the final `echo "PASS: …"` line with:

```bash
echo "PASS: all checks."
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./build.sh && ./test.sh`
Expected: `FAIL: expected SKIP, got: OK …/tone 2.aiff` at check 4.

- [ ] **Step 3: Implement in `Sources/Converter.swift`**

Add the error case and its description:

```swift
enum ConvertError: Error, CustomStringConvertible {
    case notFlac
    case afconvertFailed(String)
    case saveFailed(String)

    var description: String {
        switch self {
        case .notFlac:
            return "Skipped — not a .flac file"
        case .afconvertFailed(let message), .saveFailed(let message):
            return message
        }
    }
}

/// What a single conversion did.
enum Outcome {
    case converted(URL, note: String?)   // note: what wasn't lossless, e.g. "96 → 48 kHz"
    case alreadyConverted(URL)
}
```

Delete `reserve(_:)` and `uniqueOutputURL(for:in:)`. Replace `convert` with:

```swift
    /// Convert a single FLAC to `destDir/<name>.aiff`. Skips if that AIFF already exists.
    /// Preserves sample rate; matches source bit depth (16-, 24- or 32-bit,
    /// big-endian signed PCM), rounding up on detection failure — never down.
    ///
    /// The AIFF is written to a hidden temp file and renamed into place only when
    /// complete, so an existing `<name>.aiff` is always a finished file.
    @discardableResult
    static func convert(flacURL: URL, destDir: URL) throws -> Outcome {
        guard flacURL.pathExtension.lowercased() == "flac" else { throw ConvertError.notFlac }
        let base = flacURL.deletingPathExtension().lastPathComponent
        let final = destDir.appendingPathComponent(base + ".aiff")
        if FileManager.default.fileExists(atPath: final.path) { return .alreadyConverted(final) }

        let createdDirs = try createDirectories(destDir)
        do {
            removeStalePartials(base: base, in: destDir)
            let tmp = try reserveTemp(base: base, in: destDir)
            do {
                let detected = detectBitDepth(flacURL) ?? 24   // on detection failure, fail toward lossless
                let depth: Int
                switch detected {
                case ...16:    depth = 16   // 4–16-bit → BEI16 (lossless up-conversion for <16)
                case 17...24:  depth = 24   // 17–24-bit (incl. 20-bit) → BEI24
                default:       depth = 32   // 25–32-bit → BEI32
                }
                let (code, err) = run(afconvert, ["-f", "AIFF", "-d", "BEI\(depth)", flacURL.path, tmp.path])
                guard code == 0 else {
                    throw ConvertError.afconvertFailed(err.isEmpty ? "afconvert exited with code \(code)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                // afconvert drops all tags; carry title/artist/album/cover etc. over as an ID3 chunk.
                if let tag = TagIO.id3v23(TagIO.readFlacTags(flacURL)) {
                    try TagIO.appendID3Chunk(tag, to: tmp)
                }

                // RENAME_EXCL: never replace an AIFF another conversion published meanwhile.
                guard renamex_np(tmp.path, final.path, UInt32(RENAME_EXCL)) == 0 else {
                    let e = errno
                    if e == EEXIST {
                        try? FileManager.default.removeItem(at: tmp)
                        return .alreadyConverted(final)
                    }
                    throw ConvertError.saveFailed("Could not save \(final.lastPathComponent): \(String(cString: strerror(e)))")
                }
                return .converted(final, note: nil)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
        } catch {
            for dir in createdDirs.reversed() { rmdir(dir.path) }   // only removes still-empty dirs
            throw error
        }
    }

    // MARK: - Output file helpers

    /// Create `dir` and any missing parents. Returns the ones created, outermost first.
    private static func createDirectories(_ dir: URL) throws -> [URL] {
        var missing: [URL] = []
        var d = dir.standardizedFileURL
        while !FileManager.default.fileExists(atPath: d.path) {
            missing.insert(d, at: 0)
            let parent = d.deletingLastPathComponent()
            if parent.path == d.path { break }
            d = parent
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return missing
    }

    private static let counterLock = NSLock()
    private static var counter = 0

    /// Create a fresh `.<base>.<pid>.<n>.aiff.partial` in `dir` (O_CREAT|O_EXCL), so no two
    /// writers — in this process or another — ever share a temp file.
    private static func reserveTemp(base: String, in dir: URL) throws -> URL {
        while true {
            counterLock.lock(); let n = counter; counter += 1; counterLock.unlock()
            let url = dir.appendingPathComponent(".\(base).\(getpid()).\(n).aiff.partial")
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 { close(fd); return url }
            let e = errno
            guard e == EEXIST else {
                throw ConvertError.saveFailed("Could not write to \(dir.path): \(String(cString: strerror(e)))")
            }
        }
    }

    /// Delete `.<base>.<pid>.<n>.aiff.partial` files whose process is gone (crash leftovers).
    private static func removeStalePartials(base: String, in dir: URL) {
        let prefix = "." + base + ".", suffix = ".aiff.partial"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let parts = name.dropFirst(prefix.count).dropLast(suffix.count).split(separator: ".")
            guard parts.count == 2, let pid = pid_t(parts[0]), Int(parts[1]) != nil else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
```

- [ ] **Step 4: Update the call sites in `Sources/main.swift`**

CLI block, replace the `do { let out = … }` body with:

```swift
    do {
        switch try Converter.convert(
            flacURL: URL(fileURLWithPath: cliArgs[2]),
            destDir: URL(fileURLWithPath: cliArgs[3], isDirectory: true)
        ) {
        case .converted(let out, _):   print("OK \(out.path)")
        case .alreadyConverted(let out): print("SKIP \(out.path)")
        }
        exit(0)
    } catch {
```

GUI `handleDrop`, replace the `let out = try Converter.convert(…)` and its `DispatchQueue.main.async { … }` with (Task 4 replaces this whole function):

```swift
                    let outcome = try Converter.convert(flacURL: u, destDir: dest)
                    DispatchQueue.main.async {
                        switch outcome {
                        case .converted(let out, _):
                            produced.append(out)
                            results.append(FileStatus(name: u.lastPathComponent, ok: true,
                                                      detail: "→ \(out.lastPathComponent)"))
                        case .alreadyConverted(let out):
                            produced.append(out)
                            results.append(FileStatus(name: u.lastPathComponent, ok: true,
                                                      detail: "Already converted"))
                        }
                    }
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `./build.sh && ./test.sh`
Expected: last line `PASS: all checks.`

- [ ] **Step 6: Update `README.md`**

- Replace the `**Never overwrites**` feature bullet with:
  `- **Skips duplicates** — files that were already converted are skipped, never overwritten. Output is written to a temp file and renamed into place only when complete, so a half-written AIFF can never be mistaken for a finished one.`
- In Development, replace `auto-renaming` with `duplicate skipping`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Converter.swift Sources/main.swift test.sh README.md
git commit -m "Skip already-converted files; publish AIFFs atomically

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: CDJ mode (max 24-bit / 48 kHz)

**Files:**
- Modify: `Sources/Converter.swift` (replace `detectBitDepth` with `probe`; add `ConvertOptions`, `SourceFormat`, `OutputFormat`, `outputFormat`, note helpers; extend `convert`)
- Modify: `Sources/main.swift` (CLI `--cdj`)
- Modify: `test.sh` (refactor check 11 into functions; new 13, 14)
- Modify: `README.md`

**Interfaces:**
- Consumes: `Outcome`, `convert` from Task 1.
- Produces:
  - `struct ConvertOptions { var cdjMode = false }`
  - `Converter.convert(flacURL: URL, destDir: URL, options: ConvertOptions = ConvertOptions()) throws -> Outcome`
  - `Outcome.converted`'s `note` is non-nil when CDJ mode reduced the format, e.g. `"96 → 48 kHz"` or `"96 → 48 kHz, 32 → 24-bit"`.
  - CLI accepts `--cdj` directly after `--convert`.

- [ ] **Step 1: Refactor check 11 and write the failing tests**

Replace all of check 11 (from `echo "11. …"` through the second `PY` line) with:

```bash
# tag_flac <src.flac> <dst.flac>: copy src, adding TITLE/ARTIST/ALBUM (non-ASCII) Vorbis comments.
tag_flac() {
python3 -I - "$1" "$2" <<'PY'
import sys, struct
src, dst = sys.argv[1:3]
d = open(src, 'rb').read()
i, out = 4, bytearray(b'fLaC')
while True:   # copy metadata blocks, clearing the "last block" flag
    h, n = d[i], int.from_bytes(d[i+1:i+4], 'big')
    out += bytes([h & 0x7F]) + d[i+1:i+4+n]
    i += 4 + n
    if h & 0x80: break
vals = [b'TITLE=Song Title', b'ARTIST=Some Artist', 'ALBUM=Album 蒸發'.encode()]
body = struct.pack('<I', 0) + struct.pack('<I', len(vals)) + b''.join(struct.pack('<I', len(v)) + v for v in vals)
out += bytes([0x84]) + len(body).to_bytes(3, 'big') + body + d[i:]
open(dst, 'wb').write(out)
PY
}

# check_tags <file.aiff>: exits non-zero unless the ID3 chunk holds tag_flac's tags.
check_tags() {
python3 -I - "$1" <<'PY'
import sys, struct
f = open(sys.argv[1], 'rb'); form = f.read(12); tag = None
while (h := f.read(8)) and len(h) == 8:
    cid, sz = h[:4], struct.unpack('>I', h[4:])[0]
    if cid == b'ID3 ': tag = f.read(sz); break
    f.seek(sz + (sz & 1), 1)
assert tag and tag[:3] == b'ID3', 'no ID3 chunk'
assert struct.unpack('>I', form[4:8])[0] + 8 == f.seek(0, 2), 'FORM size wrong'
frames, j = {}, 10
while j < len(tag) and tag[j] != 0:
    fid, n = tag[j:j+4].decode(), struct.unpack('>I', tag[j+4:j+8])[0]
    frames[fid] = tag[j+10:j+10+n][1:].decode('utf-16'); j += 10 + n
want = {'TIT2': 'Song Title', 'TPE1': 'Some Artist', 'TALB': 'Album 蒸發'}
assert all(frames.get(k) == v for k, v in want.items()), frames
PY
}

fmt() { afinfo "$1" | grep "Data format"; }

echo "11. FLAC tags (incl. non-ASCII) are carried into the AIFF's ID3 chunk…"
tag_flac "$TMP/tone.flac" "$TMP/tagged.flac"
"$BIN" --convert "$TMP/tagged.flac" "$DEST" >/dev/null
check_tags "$DEST/tagged.aiff" || { echo "FAIL: tags not carried over"; exit 1; }
```

After check 12, add:

```bash
echo "13. CDJ mode: hi-res → same-family 44.1/48 kHz at 24-bit; CD quality untouched; off by default…"
say -o "$TMP/hr96.aiff" --data-format=BEI24@96000 "high resolution"
afconvert -f flac -d flac "$TMP/hr96.aiff" "$TMP/hr96.flac"
say -o "$TMP/hr88.aiff" --data-format=BEI24@88200 "high resolution"
afconvert -f flac -d flac "$TMP/hr88.aiff" "$TMP/hr88.flac"
CDJ="$TMP/cdj"
for f in hr96 hr88 t16; do "$BIN" --convert --cdj "$TMP/$f.flac" "$CDJ" >/dev/null; done
fmt "$CDJ/hr96.aiff" | grep -q "48000 Hz.*24-bit big-endian" || { echo "FAIL: 96k not → 24/48"; fmt "$CDJ/hr96.aiff"; exit 1; }
fmt "$CDJ/hr88.aiff" | grep -q "44100 Hz.*24-bit big-endian" || { echo "FAIL: 88.2k not → 24/44.1"; fmt "$CDJ/hr88.aiff"; exit 1; }
fmt "$CDJ/t16.aiff"  | grep -q "44100 Hz.*16-bit big-endian" || { echo "FAIL: 16/44.1 altered in CDJ mode"; exit 1; }
"$BIN" --convert "$TMP/hr96.flac" "$TMP/nocdj" >/dev/null
fmt "$TMP/nocdj/hr96.aiff" | grep -q "96000 Hz.*24-bit big-endian" || { echo "FAIL: 96k resampled without --cdj"; exit 1; }

echo "14. Tags survive CDJ resampling…"
tag_flac "$TMP/hr96.flac" "$TMP/taggedhr.flac"
"$BIN" --convert --cdj "$TMP/taggedhr.flac" "$CDJ" >/dev/null
fmt "$CDJ/taggedhr.aiff" | grep -q "48000 Hz" || { echo "FAIL: tagged hi-res not resampled"; exit 1; }
check_tags "$CDJ/taggedhr.aiff" || { echo "FAIL: tags lost under CDJ mode"; exit 1; }
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./build.sh && ./test.sh`
Expected: check 11 still passes. Check 13 fails: without `--cdj` support the CLI sees 3 arguments and exits 2 with `usage:`, and `set -e` aborts the script.

- [ ] **Step 3: Implement in `Sources/Converter.swift`**

Add above `enum Converter`:

```swift
/// Per-conversion choices.
struct ConvertOptions {
    var cdjMode = false   // cap at 24-bit / 48 kHz for CDJ-2000-class players
}
```

Inside `enum Converter`, replace `detectBitDepth` with:

```swift
    /// What `afinfo` reports about a source; nil fields mean "couldn't detect".
    struct SourceFormat {
        let depth: Int?
        let rate: Int?
    }

    /// Target PCM format. `rate == nil` means "keep the source rate" (no resampling).
    struct OutputFormat: Equatable {
        let depth: Int
        let rate: Int?
    }

    /// Detect source bit depth and sample rate via one `afinfo -x` (XML) call.
    static func probe(_ url: URL) -> SourceFormat {
        guard let xml = runCapture(afinfo, ["-x", url.path]),
              let doc = try? XMLDocument(xmlString: xml) else { return SourceFormat(depth: nil, rate: nil) }
        func number(_ xpath: String) -> Int? {
            guard let text = (try? doc.nodes(forXPath: xpath))?.first?.stringValue,
                  let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int(value)
        }
        // Doc uses a default namespace — match by local-name() instead of registering it.
        // FLAC's real depth is <source_info><bit_depth>; the track-level <bit_depth> is 0.
        let depth = number("//*[local-name()='source_info']/*[local-name()='bit_depth']")
            .flatMap { (1...32).contains($0) ? $0 : nil }
        let rate = number("//*[local-name()='track']/*[local-name()='sample_rate']")
            .flatMap { $0 > 0 ? $0 : nil }
        return SourceFormat(depth: depth, rate: rate)
    }

    /// Lossless by default. CDJ mode caps at 24-bit and resamples > 48 kHz to the
    /// same-family rate (88.2/176.4 → 44.1, 96/192 → 48) so the ratio stays an integer.
    static func outputFormat(for source: SourceFormat, cdj: Bool) -> OutputFormat {
        let detected = source.depth ?? 24   // on detection failure, fail toward lossless
        let depth: Int
        switch detected {
        case ...16:    depth = 16   // 4–16-bit → BEI16 (lossless up-conversion for <16)
        case 17...24:  depth = 24   // 17–24-bit (incl. 20-bit) → BEI24
        default:       depth = cdj ? 24 : 32
        }
        guard cdj, let rate = source.rate, rate > 48_000 else { return OutputFormat(depth: depth, rate: nil) }
        return OutputFormat(depth: depth, rate: rate % 44_100 == 0 ? 44_100 : 48_000)
    }

    /// "96 → 48 kHz, 32 → 24-bit" for whatever was reduced; nil when lossless.
    private static func reductionNote(_ source: SourceFormat, _ out: OutputFormat) -> String? {
        var parts: [String] = []
        if let to = out.rate, let from = source.rate { parts.append("\(khz(from)) → \(khz(to)) kHz") }
        if let from = source.depth, from > out.depth { parts.append("\(from) → \(out.depth)-bit") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func khz(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000)" : String(format: "%.1f", Double(hz) / 1000)
    }
```

In `convert`:
- Change the signature to `static func convert(flacURL: URL, destDir: URL, options: ConvertOptions = ConvertOptions()) throws -> Outcome`.
- Update the doc comment's second line to: `/// Lossless by default (see outputFormat); options.cdjMode may cap depth/rate.`
- Replace the block from `let detected = …` through the `let (code, err) = run(…)` line with:

```swift
                let source = probe(flacURL)
                let format = outputFormat(for: source, cdj: options.cdjMode)
                var args = ["-f", "AIFF"]
                if let rate = format.rate {
                    args += ["-d", "BEI\(format.depth)@\(rate)", "-r", "127", "--src-complexity", "bats"]
                } else {
                    args += ["-d", "BEI\(format.depth)"]   // unchanged lossless command line
                }
                let (code, err) = run(afconvert, args + [flacURL.path, tmp.path])
```

Replace `return .converted(final, note: nil)` with:

```swift
                return .converted(final, note: reductionNote(source, format))
```

- [ ] **Step 4: Add `--cdj` to the CLI in `Sources/main.swift`**

Replace the CLI block's opening through the `do {` with (Task 3 rewrites this block):

```swift
if cliArgs.count >= 2 && cliArgs[1] == "--convert" {
    var args = Array(cliArgs.dropFirst(2))
    var options = ConvertOptions()
    if args.first == "--cdj" { options.cdjMode = true; args.removeFirst() }
    guard args.count == 2 else {
        FileHandle.standardError.write(
            "usage: FlacToAiff --convert [--cdj] <in.flac> <destDir>\n".data(using: .utf8)!)
        exit(2)
    }
    do {
        switch try Converter.convert(
            flacURL: URL(fileURLWithPath: args[0]),
            destDir: URL(fileURLWithPath: args[1], isDirectory: true),
            options: options
        ) {
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `./build.sh && ./test.sh`
Expected: `PASS: all checks.`

- [ ] **Step 6: Update `README.md`**

After the `**Lossless**` feature bullet, add:
`- **CDJ mode** (optional) — caps output at 24-bit / 48 kHz so every file plays on CDJ-2000-class players. Hi-res files are resampled to the matching rate (96 → 48 kHz, 88.2 → 44.1 kHz); files already within limits stay bit-identical.`

- [ ] **Step 7: Commit**

```bash
git add Sources/Converter.swift Sources/main.swift test.sh README.md
git commit -m "Add CDJ mode: cap output at 24-bit / 48 kHz

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Folder expansion, multi-input CLI, output-folder check

**Files:**
- Create: `Sources/Jobs.swift`
- Modify: `Sources/Converter.swift` (add `ConvertError.outputFolderUnavailable`)
- Modify: `Sources/main.swift` (CLI block)
- Modify: `build.sh` (compile `Sources/*.swift`)
- Modify: `test.sh` (new checks 15–17)
- Modify: `README.md`

**Interfaces:**
- Consumes: `Converter.convert(flacURL:destDir:options:) -> Outcome`, `ConvertOptions` (Tasks 1–2).
- Produces:
  - `struct Job { let source: URL; let destDir: URL }`
  - `enum WorkItem { case job(Job); case note(name: String, message: String) }`
  - `struct Row: Identifiable { enum Kind { case converted, alreadyConverted, skipped, failed }; let id: UUID; let name: String; let kind: Kind; let detail: String; let output: URL? }`
  - `Jobs.expand(_ inputs: [URL], into outputRoot: URL) -> [WorkItem]`
  - `Jobs.run(_ item: WorkItem, outputRoot: URL, options: ConvertOptions) -> Row`

- [ ] **Step 1: Write the failing tests**

After check 14, add:

```bash
echo "15. Dropped folder: recursive, structure kept, junk ignored, failed subfolder removed…"
LIB="$TMP/Album Name"
mkdir -p "$LIB/CD1" "$LIB/CD2" "$LIB/Artwork" "$LIB/Broken"
cp "$TMP/tone.flac" "$LIB/CD1/01 Intro.flac"
cp "$TMP/t16.flac"  "$LIB/CD2/01 Outro.FLAC"
cp "$TMP/tone.flac" "$LIB/top.flac"
echo jpg  > "$LIB/Artwork/cover.jpg"
echo junk > "$LIB/CD1/._01 Intro.flac"
cp "$TMP/corrupt.flac" "$LIB/Broken/bad.flac"
FOLD="$TMP/folders"
set +e; "$BIN" --convert "$LIB" "$FOLD" >/dev/null 2>"$TMP/fold.err"; RC=$?; set -e
[ "$RC" -eq 1 ] || { echo "FAIL: expected exit 1 (one corrupt file), got $RC"; exit 1; }
EXPECTED="$(printf '%s\n' "Album Name" "Album Name/CD1" "Album Name/CD1/01 Intro.aiff" \
    "Album Name/CD2" "Album Name/CD2/01 Outro.aiff" "Album Name/top.aiff" | LC_ALL=C sort)"
ACTUAL="$(cd "$FOLD" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort)"
[ "$ACTUAL" = "$EXPECTED" ] || { echo "FAIL: folder output tree wrong"; diff <(echo "$EXPECTED") <(echo "$ACTUAL"); exit 1; }

echo "16. Folder without FLACs reports it and creates nothing; several inputs in one call…"
mkdir -p "$TMP/NoFlacs"; echo x > "$TMP/NoFlacs/readme.txt"
set +e; "$BIN" --convert "$TMP/NoFlacs" "$FOLD" 2>"$TMP/nf.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "No .flac files found" "$TMP/nf.err" || { echo "FAIL: empty folder not reported"; exit 1; }
[ ! -e "$FOLD/NoFlacs" ] || { echo "FAIL: empty output folder created"; exit 1; }
MULTI="$("$BIN" --convert "$TMP/tone.flac" "$TMP/t16.flac" "$TMP/multi" | grep -c '^OK ')"
[ "$MULTI" -eq 2 ] || { echo "FAIL: expected 2 OK lines for two inputs, got $MULTI"; exit 1; }

echo "17. Unwritable output folder fails clearly instead of writing elsewhere…"
RO="$TMP/readonly"; mkdir "$RO"; chmod 555 "$RO"
set +e; "$BIN" --convert "$TMP/tone.flac" "$RO" 2>"$TMP/ro.err"; RC=$?; set -e
chmod 755 "$RO"
[ "$RC" -eq 1 ] && grep -q "Output folder not available" "$TMP/ro.err" || { echo "FAIL: unwritable output not reported"; cat "$TMP/ro.err"; exit 1; }
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./build.sh && ./test.sh`
Expected: check 15 fails with `FAIL: folder output tree wrong`. Today's CLI passes the folder straight to `Converter.convert`, which rejects it as non-FLAC (exit 1), so `$FOLD` stays empty.

- [ ] **Step 3: Create `Sources/Jobs.swift`**

```swift
import Foundation

/// One FLAC to convert, and the folder its AIFF goes into.
struct Job {
    let source: URL
    let destDir: URL
}

/// Work produced by expanding dropped items: a conversion, or a message for an input
/// that yields no conversion (e.g. a folder without FLACs).
enum WorkItem {
    case job(Job)
    case note(name: String, message: String)
}

/// The result of one work item, as listed in the window and printed by the CLI.
struct Row: Identifiable {
    enum Kind { case converted, alreadyConverted, skipped, failed }
    let id = UUID()
    let name: String
    let kind: Kind
    let detail: String
    let output: URL?   // the AIFF (converted or already converted), for Reveal in Finder
}

/// Turning dropped files/folders into work, and work into rows. UI-free.
enum Jobs {
    /// Folders are walked recursively and keep their structure under
    /// `outputRoot/<folder name>/`. Hidden files (incl. AppleDouble `._x.flac`) and
    /// non-FLAC files inside folders are ignored; single dropped files are always
    /// passed on so a non-FLAC one gets reported.
    static func expand(_ inputs: [URL], into outputRoot: URL) -> [WorkItem] {
        var items: [WorkItem] = []
        let fm = FileManager.default
        for input in inputs {
            var url = input
            // A Finder alias → its target.
            if (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
               let resolved = try? URL(resolvingAliasFileAt: url) {
                url = resolved
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                items.append(.job(Job(source: url, destDir: outputRoot)))
                continue
            }

            let folderOut = outputRoot.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            let flacs = (fm.subpaths(atPath: url.path) ?? [])
                .filter { rel in
                    var relIsDir: ObjCBool = false
                    return rel.lowercased().hasSuffix(".flac")
                        && !rel.split(separator: "/").contains { $0.hasPrefix(".") }
                        && fm.fileExists(atPath: url.appendingPathComponent(rel).path, isDirectory: &relIsDir)
                        && !relIsDir.boolValue
                }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if flacs.isEmpty {
                items.append(.note(name: url.lastPathComponent, message: "No .flac files found"))
            }
            for rel in flacs {
                let subdir = (rel as NSString).deletingLastPathComponent
                let dest = subdir.isEmpty ? folderOut : folderOut.appendingPathComponent(subdir, isDirectory: true)
                items.append(.job(Job(source: url.appendingPathComponent(rel), destDir: dest)))
            }
        }
        return items
    }

    /// Run one work item. `outputRoot` must already exist and be writable: a missing
    /// root (e.g. an unplugged drive) fails rather than being recreated somewhere unexpected.
    static func run(_ item: WorkItem, outputRoot: URL, options: ConvertOptions) -> Row {
        switch item {
        case .note(let name, let message):
            return Row(name: name, kind: .skipped, detail: message, output: nil)
        case .job(let job):
            let name = job.source.lastPathComponent
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: outputRoot.path, isDirectory: &isDir), isDir.boolValue,
                  FileManager.default.isWritableFile(atPath: outputRoot.path) else {
                return Row(name: name, kind: .failed,
                           detail: ConvertError.outputFolderUnavailable.description, output: nil)
            }
            do {
                switch try Converter.convert(flacURL: job.source, destDir: job.destDir, options: options) {
                case .converted(let out, let note):
                    return Row(name: name, kind: .converted,
                               detail: "→ \(out.lastPathComponent)" + (note.map { " (\($0))" } ?? ""),
                               output: out)
                case .alreadyConverted(let out):
                    return Row(name: name, kind: .alreadyConverted, detail: "Already converted", output: out)
                }
            } catch ConvertError.notFlac {
                return Row(name: name, kind: .skipped, detail: ConvertError.notFlac.description, output: nil)
            } catch {
                return Row(name: name, kind: .failed, detail: "\(error)", output: nil)
            }
        }
    }
}
```

- [ ] **Step 4: Add the error case in `Sources/Converter.swift`**

Add `case outputFolderUnavailable` to `ConvertError`, and to `description`:

```swift
        case .outputFolderUnavailable:
            return "Output folder not available — choose another in “Save to”"
```

- [ ] **Step 5: Rewrite the CLI block in `Sources/main.swift`**

Replace everything from `let cliArgs = CommandLine.arguments` through the CLI block's closing `}` with:

```swift
let cliArgs = CommandLine.arguments
if cliArgs.count >= 2 && cliArgs[1] == "--convert" {
    var args = Array(cliArgs.dropFirst(2))
    var options = ConvertOptions()
    if args.first == "--cdj" { options.cdjMode = true; args.removeFirst() }
    guard args.count >= 2 else {
        FileHandle.standardError.write(
            "usage: FlacToAiff --convert [--cdj] <file-or-folder>... <outputDir>\n".data(using: .utf8)!)
        exit(2)
    }
    let outputRoot = URL(fileURLWithPath: args.removeLast(), isDirectory: true)
    try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    var failed = false
    for item in Jobs.expand(args.map { URL(fileURLWithPath: $0) }, into: outputRoot) {
        let row = Jobs.run(item, outputRoot: outputRoot, options: options)
        switch row.kind {
        case .converted:        print("OK \(row.output!.path)")
        case .alreadyConverted: print("SKIP \(row.output!.path)")
        case .skipped, .failed:
            failed = true
            FileHandle.standardError.write("ERROR \(row.name): \(row.detail)\n".data(using: .utf8)!)
        }
    }
    exit(failed ? 1 : 0)
}
```

Also update the comment above it to `// MARK: - Headless CLI mode (used by test.sh): --convert [--cdj] <file-or-folder>... <outputDir>`.

- [ ] **Step 6: Compile all sources in `build.sh`**

Replace `Sources/Converter.swift Sources/Tags.swift Sources/main.swift \` with `Sources/*.swift \`.

- [ ] **Step 7: Run the tests and verify they pass**

Run: `./build.sh && ./test.sh`
Expected: `PASS: all checks.` Check 10 (`--convert` with one path exits 2 with `usage:`) still passes unchanged.

- [ ] **Step 8: Update `README.md`**

- Replace the `**Drag and drop**` feature bullet with:
  `- **Drag and drop** — drop files or whole folders. Folders are scanned recursively and keep their structure (\`Album/CD1/…\`); cover images and other non-FLAC files are ignored.`
- In Development, replace the headless example with:

  ```bash
  build/FlacToAiff.app/Contents/MacOS/FlacToAiff --convert [--cdj] <file-or-folder>... <output-dir>
  ```

- Add `Sources/Jobs.swift` to the file table: `Expands dropped files/folders into conversions and runs them`.

- [ ] **Step 9: Commit**

```bash
git add Sources/Jobs.swift Sources/Converter.swift Sources/main.swift build.sh test.sh README.md
git commit -m "Convert dropped folders recursively, keeping their structure

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Settings, conversion queue and the new window

**Files:**
- Create: `Sources/Settings.swift`
- Create: `Sources/ConversionQueue.swift`
- Modify: `Sources/main.swift` (replace `FileStatus` and `DropView`; `AppDelegate` owns settings and queue)
- Modify: `README.md`

**Interfaces:**
- Consumes: `Jobs.expand`, `Jobs.run`, `Row`, `ConvertOptions` (Task 3).
- Produces:
  - `final class Settings: ObservableObject { @Published var outputFolder: URL; @Published var cdjMode: Bool; static var downloads: URL }`
  - `final class ConversionQueue: ObservableObject { init(settings:); @Published private(set) var rows: [Row]; @Published private(set) var isWorking: Bool; var outputs: [URL]; func enqueue(_ urls: [URL]); func clear() }`
  - `AppDelegate.queue`, used by Task 5.

- [ ] **Step 1: Create `Sources/Settings.swift`**

```swift
import Foundation

/// User choices that persist across launches.
final class Settings: ObservableObject {
    private enum Key {
        static let outputFolder = "outputFolder"
        static let cdjMode = "cdjMode"
    }
    private let defaults: UserDefaults

    @Published var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }
    @Published var cdjMode: Bool {
        didSet { defaults.set(cdjMode, forKey: Key.cdjMode) }
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Key.outputFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.downloads
        cdjMode = defaults.bool(forKey: Key.cdjMode)   // false when never set
    }
}
```

- [ ] **Step 2: Create `Sources/ConversionQueue.swift`**

```swift
import Foundation

/// The app's single conversion pipeline. Window drops, Dock drops and Finder "Open With"
/// all feed `enqueue`; work runs serially off the main thread and rows publish as they finish.
final class ConversionQueue: ObservableObject {
    @Published private(set) var rows: [Row] = []
    @Published private(set) var isWorking = false

    private let settings: Settings
    private let worker = DispatchQueue(label: "local.flactoaiff.conversion", qos: .userInitiated)   // serial
    private var batchesInFlight = 0   // main thread only

    init(settings: Settings) { self.settings = settings }

    /// AIFFs to select in Finder: converted and already-converted outputs.
    var outputs: [URL] { rows.compactMap(\.output) }

    /// Add files and/or folders (main thread). Settings are captured now, so changing
    /// them mid-batch affects the next drop, not files already queued.
    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let root = settings.outputFolder
        let options = ConvertOptions(cdjMode: settings.cdjMode)
        batchesInFlight += 1
        isWorking = true
        worker.async {
            for item in Jobs.expand(urls, into: root) {
                let row = Jobs.run(item, outputRoot: root, options: options)
                DispatchQueue.main.async { self.rows.append(row) }
            }
            DispatchQueue.main.async {
                self.batchesInFlight -= 1
                if self.batchesInFlight == 0 { self.isWorking = false }
            }
        }
    }

    func clear() {
        guard !isWorking else { return }
        rows = []
    }
}
```

- [ ] **Step 3: Replace `FileStatus` and `DropView` in `Sources/main.swift`**

Delete `struct FileStatus` and the whole `struct DropView`, and insert:

```swift
struct DropView: View {
    @ObservedObject var queue: ConversionQueue
    @ObservedObject var settings: Settings
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 12) {
            dropZone
            settingsBar
            if !queue.rows.isEmpty && !queue.isWorking {
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(queue.outputs)
                    }
                    .disabled(queue.outputs.isEmpty)
                    Spacer()
                    Button("Clear") { queue.clear() }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 320)
    }

    private var settingsBar: some View {
        HStack(spacing: 6) {
            Text("Save to:").foregroundColor(.secondary)
            Button(action: chooseOutputFolder) {
                HStack(spacing: 4) {
                    Text(settings.outputFolder.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .help(settings.outputFolder.path)
            Spacer(minLength: 12)
            Toggle("CDJ mode (max 24-bit / 48 kHz)", isOn: $settings.cdjMode)
                .help("Hi-res files are resampled so they play on CDJ-2000-class players. Files already within limits stay lossless.")
        }
        .font(.callout)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundColor(targeted ? .accentColor : Color.secondary.opacity(0.5))
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )

            if queue.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44, weight: .light))
                    Text(queue.isWorking ? "Converting…" : "Drop .flac files or folders here")
                        .font(.headline)
                    Text("Converted .aiff files are saved to \(settings.outputFolder.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(targeted ? .accentColor : .primary)
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(queue.rows) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: row.kind.symbol)
                                    .foregroundColor(row.kind.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.callout)
                                    Text(row.detail).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputFolder
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolder = url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let u = url {
                    lock.lock(); urls.append(u); lock.unlock()
                }
            }
        }

        // Drops while a batch runs are queued behind it.
        group.notify(queue: .main) {
            self.queue.enqueue(urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
        return true
    }
}

private extension Row.Kind {
    var symbol: String {
        switch self {
        case .converted:        return "checkmark.circle.fill"
        case .alreadyConverted: return "forward.end.circle.fill"
        case .skipped:          return "minus.circle.fill"
        case .failed:           return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .converted:                     return .green
        case .alreadyConverted, .skipped:    return .secondary
        case .failed:                        return .red
        }
    }
}
```

- [ ] **Step 4: Make `AppDelegate` own settings and queue**

In `final class AppDelegate`, replace `private var window: NSWindow!` with:

```swift
    private var window: NSWindow!
    private let settings: Settings
    let queue: ConversionQueue

    override init() {
        let settings = Settings()
        self.settings = settings
        queue = ConversionQueue(settings: settings)
        super.init()
    }
```

In `applicationDidFinishLaunching`:
- Replace `window.contentView = NSHostingView(rootView: DropView())` with `window.contentView = NSHostingView(rootView: DropView(queue: queue, settings: settings))`.
- Change `contentRect` width from `380` to `420`.

- [ ] **Step 5: Build and run the automated suite**

Run: `./build.sh && ./test.sh`
Expected: `PASS: all checks.` The CLI path is unchanged, so this guards against regressions.

- [ ] **Step 6: Manual check of the window**

Run: `open build/FlacToAiff.app`
Verify each of these:
1. The settings bar shows `Save to: Downloads ⌃⌄` and an unchecked `CDJ mode (max 24-bit / 48 kHz)`.
2. Dropping a FLAC gives a green ✓ row `→ name.aiff`. Dropping it again gives a grey `Already converted` row.
3. Clicking `Save to`, choosing a new empty folder, then dropping writes the AIFF there.
4. Checking CDJ mode and dropping a 96 kHz FLAC gives a row ending in `(96 → 48 kHz)`. Make one with `say -o /tmp/x.aiff --data-format=BEI24@96000 hi && afconvert -f flac -d flac /tmp/x.aiff /tmp/x.flac`.
5. Dropping a second batch while a large first batch runs appends rows, and no drop is ignored.
6. Quitting with ⌘Q and relaunching keeps the folder and the CDJ checkbox.
7. Choosing a folder, then renaming it in Finder and dropping a file, gives a red row `Output folder not available — choose another in “Save to”`.

- [ ] **Step 7: Update `README.md`**

- Intro: replace `the converted copies appear in your **Downloads** folder` with `the converted copies appear in your chosen output folder (Downloads by default)`.
- Usage step 3: `3. Find the converted \`.aiff\` files in the **Save to** folder shown under the drop zone (Downloads by default). Click it to choose another folder; tick **CDJ mode** to cap output at 24-bit / 48 kHz.`
- Troubleshooting `Downloads folder permission prompt`: change the heading to `**Folder permission prompt.**` and the first sentence to `The first time the app writes to Downloads (or another protected folder like Desktop or Documents), macOS asks for permission — click **OK**.`
- File table: add `Sources/Settings.swift` (`Remembered output folder and CDJ mode`) and `Sources/ConversionQueue.swift` (`Background conversion queue shared by the window, Dock and Open With`). Change the `main.swift` description to `SwiftUI window (drop zone, settings bar, results), app delegate, and the headless \`--convert\` mode`.

- [ ] **Step 8: Commit**

```bash
git add Sources/Settings.swift Sources/ConversionQueue.swift Sources/main.swift README.md
git commit -m "Add output folder setting, CDJ toggle and a queued conversion pipeline

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Dock icon drops and Finder "Open With"

**Files:**
- Modify: `build.sh` (`CFBundleDocumentTypes`)
- Modify: `Sources/main.swift` (`application(_:open:)`)
- Modify: `test.sh` (new check 18)
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-10-24-dj-workflow-design.md` (folder rank)

**Interfaces:**
- Consumes: `AppDelegate.queue.enqueue(_:)` (Task 4).

- [ ] **Step 1: Write the failing test**

After check 17, add:

```bash
echo "18. App declares FLAC + folders for Dock/Open With, as an alternate (never default) handler…"
PLIST="build/FlacToAiff.app/Contents/Info.plist"
[ "$(plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes.0 raw "$PLIST" 2>/dev/null)" = "org.xiph.flac" ] \
    || { echo "FAIL: org.xiph.flac not declared"; exit 1; }
[ "$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw "$PLIST")" = "Alternate" ] \
    || { echo "FAIL: FLAC handler rank is not Alternate"; exit 1; }
[ "$(plutil -extract CFBundleDocumentTypes.1.LSItemContentTypes.0 raw "$PLIST")" = "public.folder" ] \
    || { echo "FAIL: folders not declared"; exit 1; }
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `./build.sh && ./test.sh`
Expected: `FAIL: org.xiph.flac not declared`.

- [ ] **Step 3: Declare document types in `build.sh`**

In the `Info.plist` heredoc, after the `CFBundleIconFile` line, add:

```xml
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>FLAC Audio</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>org.xiph.flac</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
```

Folders use `Alternate`, not the spec's `None`. `None` can stop the Dock from accepting folder drops, and Finder always stays the default for folders anyway, so `Alternate` can't take over anything.

- [ ] **Step 4: Handle opened URLs in `Sources/main.swift`**

In `AppDelegate`, after `applicationDidFinishLaunching`, add:

```swift
    /// Dock-icon drops and Finder "Open With". On a cold launch this can arrive before
    /// applicationDidFinishLaunching; the queue exists from init, so nothing is lost.
    func application(_ application: NSApplication, open urls: [URL]) {
        queue.enqueue(urls)
    }
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `./build.sh && ./test.sh`
Expected: `PASS: all checks.`

- [ ] **Step 6: Install and check by hand**

Run:

```bash
pkill -x FlacToAiff; rm -rf /Applications/FlacToAiff.app
ditto build/FlacToAiff.app /Applications/FlacToAiff.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/FlacToAiff.app
```

Verify each of these:
1. With the app running, dropping a FLAC on its Dock icon converts it and adds a row.
2. With the app quit and kept in the Dock, dropping a FLAC launches it, and the window shows the converted row.
3. Dropping a folder on the Dock icon converts its FLACs with the structure kept.
4. Right-clicking a FLAC in Finder → Open With lists FlacToAiff, and choosing it converts.
5. In Finder → Get Info on a FLAC → "Open with", the default app is unchanged (not FlacToAiff).

- [ ] **Step 7: Update docs**

- `README.md` features: change the `**Drag and drop**` bullet's opening to `- **Drag and drop** — onto the window or the Dock icon, or right-click → Open With. Drop files or whole folders.` and keep the rest of the bullet.
- `README.md` Usage, after the numbered steps, add: `You can also drop files or folders on the app's Dock icon, or right-click FLACs in Finder → **Open With → FlacToAiff**. The app never becomes the default app for FLAC files.`
- Spec, in the Dock / Open With section: change the folder line's `LSHandlerRank = None` (accept drops only) to `LSHandlerRank = Alternate` (Finder remains the default for folders; None can block Dock drops).

- [ ] **Step 8: Commit**

```bash
git add build.sh Sources/main.swift test.sh README.md docs/superpowers/specs/2026-10-24-dj-workflow-design.md
git commit -m "Accept FLACs and folders via Dock icon and Finder Open With

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
