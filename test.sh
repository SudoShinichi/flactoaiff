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

echo "11. FLAC tags (incl. non-ASCII) are carried into the AIFF's ID3 chunk…"
python3 -I - "$TMP/tone.flac" "$TMP/tagged.flac" <<'PY'
import sys, struct
src, dst = sys.argv[1:3]
d = open(src, 'rb').read()
# Find the end of the metadata blocks, clearing the "last block" flag as we go.
i, out = 4, bytearray(b'fLaC')
while True:
    h, n = d[i], int.from_bytes(d[i+1:i+4], 'big')
    out += bytes([h & 0x7F]) + d[i+1:i+4+n]
    i += 4 + n
    if h & 0x80: break
vals = [b'TITLE=Song Title', b'ARTIST=Some Artist', 'ALBUM=Album \u84b8\u767c'.encode()]
body = struct.pack('<I', 0) + struct.pack('<I', len(vals)) + b''.join(struct.pack('<I', len(v)) + v for v in vals)
out += bytes([0x84]) + len(body).to_bytes(3, 'big') + body + d[i:]
open(dst, 'wb').write(out)
PY
"$BIN" --convert "$TMP/tagged.flac" "$DEST"
python3 -I - "$DEST/tagged.aiff" <<'PY' || { echo "FAIL: tags not carried over"; exit 1; }
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
want = {'TIT2': 'Song Title', 'TPE1': 'Some Artist', 'TALB': 'Album \u84b8\u767c'}
assert all(frames.get(k) == v for k, v in want.items()), frames
PY

echo
echo "PASS: conversion, 24/16-bit preservation, sample-rate preservation, auto-rename, rejection, filename-safe detection, corrupt-input handling, concurrent no-overwrite, CLI arity, and tag carry-over all work."
