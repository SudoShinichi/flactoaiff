# Output Verification — Design

**Date:** 2026-10-25

## Intent
The user wants to trust a converted AIFF without listening to it or checking it in Apple Music or rekordbox. Both the sound and the tags matter to them ("neither of them would be good" if wrong). If the app shows ✓, the file is right. If anything is off, the user finds out in the window, not mid-set.

The user's decisions:
- A failed check means **no AIFF is saved**, and the row shows a warning.
- Only **new conversions** are verified. Existing AIFFs, including ones reported as "Already converted", are not checked.
- (Context, from dropping tag-based renaming:) what matters is that tags are right and that Apple Music and rekordbox read them. File names don't matter.

## Goals
- Every new conversion is verified before it is published (renamed into place):
  - **Audio**, when the conversion is meant to be lossless: the decoded samples are bit-identical to the FLAC's.
  - **Format**, always: the AIFF is readable and has the intended sample rate, bit depth and channel count. Its length matches (the existing STREAMINFO length check stays).
  - **Tags**, always: every field the app writes reads back correctly through macOS's own media framework (AVFoundation, which Apple Music builds on), artwork included.
- On failure: the temp file is deleted, nothing is published, and the row is red with a reason that names the check.
- On success: the row says it was verified.

## Non-goals
- Verifying AIFFs that already exist, or re-verifying on "Already converted".
- Checking rekordbox itself; it can't be driven from outside. It reads the same ID3v2.3 tag, so the AVFoundation check stands in for both.
- A setting to turn verification off.
- Proving that resampled or dithered audio "sounds right". It differs from the FLAC by design.

## Anti-goals
- A ✓ that claims more than was checked. Wording must say what was verified.
- Verification that noticeably slows a batch. Hashing is cheap; a second full decode per file should be avoided where the FLAC's own checksum suffices.

## Behavior

### When the audio counts as lossless
The output format has no resampling (`rate == nil`), no dither, and an output bit depth ≥ the source depth. That covers:
- every Original-mode conversion
- max48 and cd conversions of files already within limits

A 32-bit source in max48 (depth cut without dither) is *not* lossless.

The source depth for this decision comes from STREAMINFO, not the `afinfo` probe. The probe falls back to 24-bit when detection fails, which could wrongly mark a 32-bit file as lossless. *(Implementer's call.)*

AVFoundation was confirmed to return every frame the app writes: non-ASCII text, TXXX (names in `extraAttributes[.info]`), COMM, TYER, TRCK, and several APIC pictures with their full data and picture type. The raw-chunk fallback will likely go unused.

### Audio check (lossless only)
- A FLAC's STREAMINFO carries an MD5 of its decoded samples: signed, little-endian, interleaved, each sample in `ceil(bps/8)` bytes at the source bit depth.
- Compute the same MD5 from the AIFF's sample data (`SSND`, big-endian, signed, at the output depth). A source narrower than its container (e.g. 20-bit in BEI24) has to be shifted back to the source depth first.
- A mismatch fails the conversion: `Audio doesn't match the FLAC`.
- If STREAMINFO's MD5 is all zeros (the encoder didn't record one), the builder chooses between decoding the FLAC with `afconvert` and comparing samples directly, or skipping the audio check and saying so in the row. Either way the row must not claim the audio was verified when it wasn't.

### Format check (always)
`afinfo` (or AudioToolbox) on the temp AIFF must report the target sample rate, bit depth and channel count. The existing ±2-frame length check stays. A mismatch fails: `Output format is wrong (…)`.

### Tag check (always, when tags were written)
- Read the temp AIFF with AVFoundation (`AVURLAsset`, ID3 metadata).
- Every frame the app wrote must come back with the same value. That includes TXXX user fields, the COMM comment, and every APIC picture byte-for-byte.
- The ID3 builder is the source of truth for what was written. It can return the list of written frames alongside the tag bytes.
- If AVFoundation doesn't surface a frame the app wrote, the builder may verify that frame by parsing the AIFF's `ID3 ` chunk directly. That fallback must be limited to frames AVFoundation demonstrably doesn't expose. Title, artist, album and artwork must always pass through AVFoundation, because that is what Apple Music sees.
- A mismatch fails, naming the field: `Tag check failed: artwork missing`, `Tag check failed: BPM`.

### Ordering
afconvert → length check → append ID3 → **verify** → publish. Verification runs on the temp file, so nothing unverified ever appears under the final name.

### Rows and CLI
- **Window, verified lossless:** `→ track.aiff · verified`.
- **Window, verified non-lossless:** `→ track.aiff (96 → 48 kHz) · tags verified` (format and length were also checked; the wording avoids claiming bit-identical audio). If the audio check was skipped for a missing MD5: `· tags verified`.
- **Untagged FLAC** (no tags written): the suffix names only what was checked. That is `· verified` for lossless audio, and `· format checked` otherwise. *(Implementer's call.)*
- **Failure:** a red row with the reason. Watched files retry only when the FLAC changes, as today.
- **CLI:** `OK`/`ERROR` lines are unchanged in shape. Failures print `ERROR <name>: <reason>` and exit 1.

## Constraints
- macOS 12 deployment target. No third-party dependencies.
- MD5 via CryptoKit's `Insecure.MD5` (macOS 10.15+) or CommonCrypto.
- AVFoundation's synchronous metadata API is acceptable on macOS 12. Any API newer than 12 needs an `#available` fallback.
- Bit-identical behavior of Original mode must not change. Verification only reads.

## Testing (in `test.sh`, end-to-end through the CLI)
- All existing conversions pass verification, so the current 28 checks double as "no false alarms" tests. That covers 16/24-bit, the resampled modes and tagged files with non-ASCII text and artwork.
- **Audio mismatch:** a FLAC whose STREAMINFO MD5 has been altered (patch bytes in the header) must fail with the audio message, and publish nothing.
- **Tag mismatch:** how to provoke one is left to the builder. A failure hook that is active only in tests is acceptable if it is clearly fenced off, but a real-input trigger is preferred.
- **A 20-bit source** in Original mode verifies (shift handling).

## Left to the builder
- How to reach a 20-bit or missing-MD5 test input with only macOS tools.
- Where the verification code lives (a new `Verifier.swift` is suggested) and how the converter reports "what was verified" to the row.
- Exact failure wording, within the examples above.
