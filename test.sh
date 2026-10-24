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

echo "4. Converting the same file again skips it (no 'tone 2.aiff')…"
SECOND="$("$BIN" --convert "$TMP/tone.flac" "$DEST")"
[ "$SECOND" = "SKIP $DEST/tone.aiff" ] || { echo "FAIL: expected SKIP, got: $SECOND"; exit 1; }
[ ! -e "$DEST/tone 2.aiff" ] || { echo "FAIL: duplicate 'tone 2.aiff' created"; exit 1; }

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
ls -A "$DEST" | grep -q "\.partial$" && { echo "FAIL: temp .partial file left behind"; exit 1; }

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

echo "10. --convert with wrong arity exits 2 with usage (never launches GUI)…"
set +e
"$BIN" --convert "$TMP/tone.flac" 2>"$TMP/usage.txt"; RC=$?
set -e
[ "$RC" -eq 2 ] || { echo "FAIL: expected exit 2, got $RC"; exit 1; }
grep -q "usage:" "$TMP/usage.txt" || { echo "FAIL: no usage message"; exit 1; }

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

echo "12. A crash leftover (.partial of a dead process) doesn't block conversion and is removed…"
DEST3="$TMP/stale"; mkdir -p "$DEST3"
( : ) & DEAD=$!; wait "$DEAD"     # a PID that is guaranteed to be gone
echo junk > "$DEST3/.tone.$DEAD.0.aiff.partial"
"$BIN" --convert "$TMP/tone.flac" "$DEST3" >/dev/null
[ -f "$DEST3/tone.aiff" ] || { echo "FAIL: conversion blocked by stale partial"; exit 1; }
[ ! -e "$DEST3/.tone.$DEAD.0.aiff.partial" ] || { echo "FAIL: stale partial not cleaned up"; exit 1; }

echo "13. Output formats: max48 / cd / original, plus bad --format…"
say -o "$TMP/hr96.aiff" --data-format=BEI24@96000 "high resolution"
afconvert -f flac -d flac "$TMP/hr96.aiff" "$TMP/hr96.flac"
say -o "$TMP/hr88.aiff" --data-format=BEI24@88200 "high resolution"
afconvert -f flac -d flac "$TMP/hr88.aiff" "$TMP/hr88.flac"
M48="$TMP/max48"
for f in hr96 hr88 t16; do "$BIN" --convert --format max48 "$TMP/$f.flac" "$M48" >/dev/null; done
fmt "$M48/hr96.aiff" | grep -q "48000 Hz.*24-bit big-endian" || { echo "FAIL: max48: 96k not → 24/48"; fmt "$M48/hr96.aiff"; exit 1; }
fmt "$M48/hr88.aiff" | grep -q "44100 Hz.*24-bit big-endian" || { echo "FAIL: max48: 88.2k not → 24/44.1"; fmt "$M48/hr88.aiff"; exit 1; }
fmt "$M48/t16.aiff"  | grep -q "44100 Hz.*16-bit big-endian" || { echo "FAIL: max48 altered 16/44.1"; exit 1; }
CDQ="$TMP/cdq"
for f in hr96 tone t16; do "$BIN" --convert --format cd "$TMP/$f.flac" "$CDQ" >/dev/null; done
fmt "$CDQ/hr96.aiff" | grep -q "44100 Hz.*16-bit big-endian" || { echo "FAIL: cd: 24/96 not → 16/44.1"; fmt "$CDQ/hr96.aiff"; exit 1; }
fmt "$CDQ/tone.aiff" | grep -q "44100 Hz.*16-bit big-endian" || { echo "FAIL: cd: 24/44.1 not → 16/44.1"; exit 1; }
cmp -s "$CDQ/t16.aiff" "$DEST/t16.aiff" || { echo "FAIL: cd mode altered a 16/44.1 source"; exit 1; }
"$BIN" --convert "$TMP/hr96.flac" "$TMP/orig" >/dev/null
fmt "$TMP/orig/hr96.aiff" | grep -q "96000 Hz.*24-bit big-endian" || { echo "FAIL: default format resampled 96k"; exit 1; }
set +e; "$BIN" --convert --format bogus "$TMP/tone.flac" "$TMP/orig" 2>/dev/null; RC=$?; set -e
[ "$RC" -eq 2 ] || { echo "FAIL: unknown --format should exit 2, got $RC"; exit 1; }

echo "14. Tags survive resampling + dither…"
tag_flac "$TMP/hr96.flac" "$TMP/taggedhr.flac"
"$BIN" --convert --format cd "$TMP/taggedhr.flac" "$CDQ" >/dev/null
fmt "$CDQ/taggedhr.aiff" | grep -q "44100 Hz.*16-bit" || { echo "FAIL: tagged hi-res not converted to CD format"; exit 1; }
check_tags "$CDQ/taggedhr.aiff" || { echo "FAIL: tags lost in cd mode"; exit 1; }

echo
echo "PASS: all checks."
