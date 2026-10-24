# Output Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify every new AIFF before it is published (audio bit-identical where lossless, format and length always, tags through AVFoundation). Refuse to publish on any mismatch.

**Architecture:**
- A new `Verifier` checks the finished temp AIFF against what the FLAC says (STREAMINFO MD5 and format) and against what was written (the ID3 frame list).
- `Converter.convert` calls it between appending the ID3 chunk and the `RENAME_EXCL` publish. A thrown error deletes the temp file, exactly like today's failures.
- What was checked travels back in `Outcome.converted`, so window rows and CLI lines can say it.

**Tech Stack:**
- Swift with `swiftc`.
- CryptoKit `Insecure.MD5` for the audio fingerprint.
- AVFoundation `AVURLAsset.metadata(forFormat: .id3Metadata)` for reading tags back.
- `test.sh` end to end through `--convert`.

**Spec:** `docs/superpowers/specs/2026-10-25-output-verification-design.md`

## Global Constraints
- Target `arm64-apple-macos12.0`: no API newer than macOS 12 without `#available`.
- No third-party dependencies.
- Original-mode output must stay bit-identical: verification only reads the temp file.
- On any failed check, publish nothing and delete the temp file.
- Only new conversions are verified. "Already converted" is untouched.
- Row wording must never claim more than was checked.

## Decisions taken here (facts established while planning)
- **AVFoundation and the tags the app writes.** Verified with a probe on a real conversion.
  - Every item's `key` is a `String` equal to the frame ID (`TIT2`, `TXXX`, `APIC`, …).
  - Text frames give `stringValue`.
  - COMM and TXXX give their description in `extraAttributes[.info]` (empty for COMM). The value is in `stringValue`.
  - APIC gives `dataValue`, the image bytes.
- **The MD5 rule.** Verified: the MD5 of a 24-bit AIFF's SSND bytes, reversed to little-endian per sample, equals the FLAC's STREAMINFO MD5.
- **Missing MD5** (16 zero bytes): skip the audio check and report it unchecked. Decoding the FLAC again with the same `afconvert` would only compare `afconvert` with itself.
- **20-bit input can't be made with macOS tools** (`afconvert` accepts 8/16/24/32 only). The test writes a tiny FLAC with VERBATIM subframes in Python.
- **Failures that real inputs can't provoke.** `afconvert` never writes a wrong format, and the app's own ID3 writer is what it reads back. These are covered by a test-only hook: the env var `FLACTOAIFF_TEST_DAMAGE=format|tags`, read only in `Verifier`. It damages the temp file just before checking. The spec allows such a hook if it is clearly fenced off.
- **CLI line.** `OK <path>` gains a tab and the label: `OK <path>\t<label>`. Existing `grep '^OK '` and `"^OK .*/x.aiff"` consumers keep working. The spec's "unchanged in shape" is updated to say this.

## Review Focus
1. **Stereo files.** Samples are interleaved: the MD5 must be over the SSND bytes in file order, not per channel. *Test in Task 1:* a stereo 24-bit FLAC verifies.
2. **Odd-length SSND followed by a pad byte and the appended ID3 chunk.** Mono 24-bit with an odd frame count is the existing `tone.flac`. The MD5 must stop at SSND's declared size. *Test in Task 1:* the tagged `tone` conversion (test 11) passes with a `verified` label.
3. **Large files** (e.g. 10 min of 24/96 stereo ≈ 350 MB). Read SSND in bounded chunks (1 MiB), never all at once. *Task 1, Step 3.* There is no automated test, but a reviewer must check that the code streams.
4. **Genre written as an ID3v1 reference like `(13)`.** AVFoundation might translate it to `Pop` and cause a false refusal. *Test in Task 2:* GENRE `(13)` must pass. If AVFoundation does translate it, TCON falls back to the raw `ID3 ` chunk, as the spec allows.
5. **A FLAC whose STREAMINFO MD5 is zero.** It must convert, and must not be labelled `verified`. *Test in Task 1.*

---

### Task 1: Audio and format verification, with labels in rows and the CLI

**Files:**
- Create: `Sources/Verifier.swift`
- Modify: `Sources/Tags.swift`: extend `flacStreamInfo`, replace `aiffFrameCount` with `aiffInfo`
- Modify: `Sources/Converter.swift`: call the verifier, carry the label in `Outcome`
- Modify: `Sources/Jobs.swift`: row detail
- Modify: `Sources/main.swift`: `cliPrint` adds the label
- Test: `test.sh`

**Interfaces:**
- Produces:
  - `struct StreamInfo { let samples: Int; let rate: Int; let channels: Int; let bitsPerSample: Int; let md5: Data? }`. `md5` is nil when all zero. It replaces the tuple returned by `TagIO.flacStreamInfo(_ url: URL) -> StreamInfo?`, and the length check in `Converter` uses its fields.
  - `struct AIFFInfo { let channels: Int; let frames: Int; let bitsPerSample: Int; let rate: Double; let soundDataOffset: UInt64; let soundDataLength: UInt64 }`, from `TagIO.aiffInfo(_ url: URL) -> AIFFInfo?`. It parses COMM (the rate is an 80-bit IEEE extended float) and SSND (offset = chunk data start + 8 + SSND's `offset` field; length = chunk size − 8). It replaces `aiffFrameCount`.
  - `struct Checks { var audio = false; var tags = false; var label: String }`. `label` is `"verified"` if `audio`, otherwise `"tags verified"` if `tags`, otherwise `"format checked"`.
  - `enum Verifier { static func verify(aiff: URL, source: StreamInfo?, expected: Converter.OutputFormat, lossless: Bool, writtenFrames: [ID3Frame]) throws -> Checks }`. Task 1 passes `writtenFrames: []`; Task 2 fills it.
  - `ConvertError.verificationFailed(String)`, whose `description` is the message.
  - `Outcome.converted(URL, note: String?, checks: Checks)`.

- [ ] **Step 1: Write the failing tests.** In `test.sh`, add check 29, "Verification: lossless outputs are verified, tampered audio is refused":
  - `"$BIN" --convert "$TMP/tone.flac" "$TMP/v1"` prints exactly `OK $TMP/v1/tone.aiff<TAB>verified`. Tone is mono 24-bit with an odd frame count (Review Focus 2).
  - The same for `t16.flac` (16-bit).
  - **Stereo:** `afconvert -f flac -d flac -c 2 "$TMP/tone.aiff" "$TMP/st.flac"` converts with the `verified` label. If `afconvert` rejects `-c 2`, make stereo with `say -o … --channels=2`.
  - **Tampered MD5:** copy `tone.flac` and flip one byte at file offset 30 (inside the STREAMINFO MD5, bytes 26–41) with `printf | dd conv=notrunc`. Expect exit 1, stderr containing `Audio doesn't match the FLAC`, no `tone.aiff`, and no `.partial`.
  - **Zero MD5:** write 16 zero bytes at offset 26. Expect `OK` with the label `format checked`, since the FLAC has no tags (Review Focus 5).
  - **Resampled:** `--format max48` on `hr96.flac` gives the label `format checked` (untagged, not lossless).
  - **Format hook:** `FLACTOAIFF_TEST_DAMAGE=format "$BIN" --convert "$TMP/tone.flac" "$TMP/v2"` exits 1 with `Output format is wrong`, and publishes nothing.
  - **20-bit:** add a helper `flac20 <out.flac>`, a Python `-I` heredoc that writes:
    - `fLaC`
    - STREAMINFO with the last flag set: blocksize 4096/4096, frame sizes 0, 44100 Hz, 1 channel, bps 20, total samples 4096, and the MD5 of the samples (as 3-byte little-endian signed)
    - one frame: sync `0xFFF8`, blocksize code `0b1100` (4096 is the 2^(n−8) form, n = 12), rate code `0b1001` (44.1 kHz), channel code 0, sample-size code `0b010` (20-bit), coded number 0, then CRC-8 (poly 0x07)
    - a VERBATIM subframe header `0b00000010` followed by 4096 × 20-bit big-endian samples (a ramp or sine), zero-padded to a byte, then CRC-16 (poly 0x8005)

    The FLAC must have `afinfo` reporting `source bit depth: I20`. In Original mode it converts with the label `verified`.
  - Update every existing exact-match `OK` assertion, if any, to the tab form.

- [ ] **Step 2: Run** `./build.sh && ./test.sh`. Expected: FAIL at check 29 (no label yet).

- [ ] **Step 3: Implement.**
  - **`StreamInfo` parsing:** bits from STREAMINFO bytes 10–17. Channels = 3 bits + 1, bps = 5 bits + 1. MD5 = bytes 18–33.
  - **`aiffInfo`:** walk the chunks the same way `appendID3Chunk`/the old `aiffFrameCount` do, including the odd-size pad.
  - **`Verifier.verify`:**
    - **Format:** channels and frames must match the source (frames within ±2 of the expected resampled count, the existing rule, which moves here from `Converter`). `bitsPerSample` must equal `expected.depth`. The rate must equal `expected.rate ?? source.rate`. Otherwise throw `Output format is wrong (<what>: got X, expected Y)`. If `source` is nil (STREAMINFO unreadable), check only depth and rate from `expected` and the probe.
    - **Audio:** only if `lossless`, `source.md5 != nil` and the source bps ≤ the output bps. Stream `soundDataLength` bytes from `soundDataOffset` in 1 MiB reads (a multiple of `frameBytes = channels × outBytes`). For each sample, take the big-endian signed value, shift it right by `outBits − srcBits` (arithmetic), and write it as `ceil(srcBits/8)` bytes little-endian into `Insecure.MD5`. Mismatch: throw `Audio doesn't match the FLAC`.
    - **Hook:** before checking, if `ProcessInfo.processInfo.environment["FLACTOAIFF_TEST_DAMAGE"] == "format"`, overwrite the COMM sample-size field with a different value. Mark it `// TEST HOOK — only test.sh sets this`.
  - **Lossless** (computed in `Converter`): `format.rate == nil && !format.dither && streamInfo.bitsPerSample <= format.depth`. Use STREAMINFO's bps, not the `afinfo` probe.
  - **`Jobs.run`:** detail = `"→ name.aiff"` + note + `" · \(checks.label)"`.
  - **`cliPrint`:** `OK <path>\t<label>`. That needs the label on `Row`: add `let checks: String?` to `Row`, or parse it from the detail; adding the field is preferred.

- [ ] **Step 4: Run** `./build.sh && ./test.sh`. Expected: `PASS: all checks.` (all 29). Also run `./test.sh` twice more: the watch tests use timing.

- [ ] **Step 5: Commit** `git commit -m "Verify audio (STREAMINFO MD5) and format before publishing"` with the co-author trailer.

### Task 2: Tag verification through AVFoundation, plus docs

**Files:**
- Modify: `Sources/Tags.swift`: an ID3 frame model, with `id3v23` built from it
- Modify: `Sources/Verifier.swift`: the tag check
- Modify: `Sources/Converter.swift`: pass the written frames
- Modify: `build.sh` only if linking needs `-framework AVFoundation` (swiftc usually autolinks on `import`)
- Modify: `README.md`, and the spec (the CLI line wording)
- Test: `test.sh`

**Interfaces:**
- Consumes: `Verifier.verify(…, writtenFrames:)` and `Checks` from Task 1.
- Produces:
  - `enum ID3Frame: Equatable { case text(id: String, value: String); case userText(description: String, value: String); case comment(String); case picture(Picture) }`, with `Picture: Equatable` added.
  - `TagIO.id3Frames(_ tags: Tags) -> [ID3Frame]`, the same selection and order as today's builder.
  - `TagIO.id3v23(_ frames: [ID3Frame]) -> Data?`. The old `id3v23(_ tags:)` keeps working as `id3v23(id3Frames(tags))`. The ID3 bytes must stay identical to today's: check that `cmp` of a tagged output before and after the refactor matches.

- [ ] **Step 1: Write the failing tests.** Check 30, "Verification: tags read back through AVFoundation":
  - Extend `tag_flac` with optional extra Vorbis comments, `tag_flac src dst [KEY=VALUE…]`.
  - A FLAC with TITLE/ARTIST/ALBUM (non-ASCII), `GENRE=(13)` (Review Focus 4), BPM, INITIALKEY, COMMENT, a custom `CATALOG=XYZ1`, and a front-cover PICTURE block converts with the label `verified`. Reuse the PICTURE builder pattern from test 11's data if one exists, or build a tiny JPEG-header blob.
  - `--format max48` of a tagged `hr96` copy gives the label `tags verified`.
  - `FLACTOAIFF_TEST_DAMAGE=tags` on the tagged FLAC exits 1 with `Tag check failed: artwork`, and publishes nothing. The hook rewrites the ID3 chunk without its APIC frames before checking.

- [ ] **Step 2: Run** the tests and see check 30 fail (the label is `verified` only because tags aren't checked yet, so the damage case wrongly passes).

- [ ] **Step 3: Implement.**
  - **Frame model and builder refactor:** described above; output bytes unchanged.
  - **`Verifier`:** load `AVURLAsset(url:).metadata(forFormat: .id3Metadata)`. For each written frame, find a matching item:
    - `.text`: `key == id`, `stringValue == value`.
    - `.userText`: `key == "TXXX"`, `extraAttributes[.info] as? String == description`, `stringValue == value`.
    - `.comment`: `key == "COMM"`, `stringValue == value`.
    - `.picture`: `key == "APIC"`, `dataValue == picture.data`. Each written picture needs its own item.

    A missing or different value throws `Tag check failed: <field>`. Field names: TIT2→`title`, TPE1→`artist`, TALB→`album`, TPE2→`album artist`, TCON→`genre`, TBPM→`BPM`, TKEY→`key`, TYER→`year`, TRCK→`track number`, TPOS→`disc number`, COMM→`comment`, APIC→`artwork`, TXXX→the description, anything else→the frame ID.
  - **TCON fallback:** only if Step 2's run shows AVFoundation translating `(13)`. Then compare TCON against the raw `ID3 ` chunk instead, parsed with the existing `Reader`.
  - **`Checks.tags`:** true when at least one frame was written and all passed.
  - **Hook:** `FLACTOAIFF_TEST_DAMAGE=tags`. Rewrite the temp file's ID3 chunk without its pictures (truncate at the chunk start, fix the FORM size, re-append `id3v23(frames.filter { not picture })`). Same `// TEST HOOK` marker.

- [ ] **Step 4: Run** `./build.sh && ./test.sh` three times. Expected: `PASS: all checks.` (30) each time.

- [ ] **Step 5: Docs.**
  - **README features:** extend "Never a cut-off track" into "Every file verified". It says:
    - lossless outputs are checked against the FLAC's own audio fingerprint
    - every output's format and length are checked
    - tags and artwork are read back the way Apple Music reads them
    - on any mismatch, nothing is saved and the row says why
  - **README development section:** add the `OK <path>\t<label>` format.
  - **Spec, Rows and CLI:** replace "unchanged in shape" with the tab-label form.
  - **README file table:** add `Sources/Verifier.swift | Checks each AIFF before it is saved: audio fingerprint, format, tags`.

- [ ] **Step 6: Commit** `git commit -m "Verify tags through AVFoundation before publishing"` with the co-author trailer.
