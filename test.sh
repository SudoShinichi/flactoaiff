#!/bin/bash
# End-to-end test: synthesize a FLAC, run the converter core, verify the AIFF.
set -euo pipefail
cd "$(dirname "$0")"

BIN="build/FlacToAiff.app/Contents/MacOS/FlacToAiff"
[ -x "$BIN" ] || { echo "Build first: ./build.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "1. Synthesize 24-bit source and encode to FLAC…"
say -o "$TMP/tone.aiff" --data-format=BEI24@44100 "test tone for flac conversion"
afconvert -f flac -d flac "$TMP/tone.aiff" "$TMP/tone.flac"

DEST="$TMP/out"

echo "2. Convert FLAC -> AIFF…"
"$BIN" --convert "$TMP/tone.flac" "$DEST"
OUT="$DEST/tone.aiff"
[ -f "$OUT" ] || { echo "FAIL: no output produced"; exit 1; }

echo "3. Verify format (24-bit big-endian PCM, sample rate preserved)…"
INFO="$(afinfo "$OUT")"
echo "$INFO" | grep -q "24-bit big-endian signed integer" || { echo "FAIL: wrong bit depth/format"; echo "$INFO"; exit 1; }
echo "$INFO" | grep -q "44100 Hz" || { echo "FAIL: sample rate not preserved"; echo "$INFO"; exit 1; }

echo "4. Verify auto-rename on name clash…"
"$BIN" --convert "$TMP/tone.flac" "$DEST"
[ -f "$DEST/tone 2.aiff" ] || { echo "FAIL: auto-rename did not produce 'tone 2.aiff'"; ls "$DEST"; exit 1; }

echo "5. Verify non-flac input is rejected…"
if "$BIN" --convert "$TMP/tone.aiff" "$DEST" 2>/dev/null; then
    echo "FAIL: non-flac input was not rejected"; exit 1
fi

echo "6. 16-bit source stays 16-bit…"
say -o "$TMP/t16.aiff" --data-format=BEI16@44100 "sixteen bit tone"
afconvert -f flac -d flac "$TMP/t16.aiff" "$TMP/t16.flac"
"$BIN" --convert "$TMP/t16.flac" "$DEST"
afinfo "$DEST/t16.aiff" | grep -q "16-bit big-endian signed integer" \
    || { echo "FAIL: 16-bit source not preserved as BEI16"; exit 1; }

echo "7. Spaces + '16-bit' in a 24-bit file's NAME must not fool detection (H3 regression)…"
cp "$TMP/tone.flac" "$TMP/my song (live) 16-bit dreams.flac"
"$BIN" --convert "$TMP/my song (live) 16-bit dreams.flac" "$DEST"
afinfo "$DEST/my song (live) 16-bit dreams.aiff" | grep -q "24-bit big-endian signed integer" \
    || { echo "FAIL: filename text leaked into bit-depth detection"; exit 1; }

echo "8. Corrupt FLAC fails loudly, propagates stderr, leaves no partial file…"
head -c 2048 /dev/urandom > "$TMP/corrupt.flac"
set +e
"$BIN" --convert "$TMP/corrupt.flac" "$DEST" 2>"$TMP/err.txt"; RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: corrupt FLAC did not fail"; exit 1; }
grep -q "ERROR" "$TMP/err.txt" || { echo "FAIL: no error propagated to stderr"; exit 1; }
ls "$DEST" | grep -q "^corrupt" && { echo "FAIL: partial output left behind (L2)"; exit 1; }

echo "9. Concurrent conversions never overwrite (O_EXCL reservation)…"
DEST2="$TMP/race"
for i in 1 2 3 4; do "$BIN" --convert "$TMP/tone.flac" "$DEST2" & done
wait
COUNT="$(ls "$DEST2" | wc -l | tr -d ' ')"
[ "$COUNT" -eq 4 ] || { echo "FAIL: expected 4 distinct outputs, got $COUNT"; ls "$DEST2"; exit 1; }

echo "10. --convert with wrong arity exits 2 with usage (never launches GUI)…"
set +e
"$BIN" --convert "$TMP/tone.flac" 2>"$TMP/usage.txt"; RC=$?
set -e
[ "$RC" -eq 2 ] || { echo "FAIL: expected exit 2, got $RC"; exit 1; }
grep -q "usage:" "$TMP/usage.txt" || { echo "FAIL: no usage message"; exit 1; }

echo
echo "PASS: conversion, 24/16-bit preservation, sample-rate preservation, auto-rename, rejection, filename-safe detection, corrupt-input handling, concurrent no-overwrite, and CLI arity all work."
