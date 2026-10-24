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
echo junk > "$DEST3/.flactoaiff.$DEAD.0.partial"
"$BIN" --convert "$TMP/tone.flac" "$DEST3" >/dev/null
[ -f "$DEST3/tone.aiff" ] || { echo "FAIL: conversion blocked by stale partial"; exit 1; }
[ ! -e "$DEST3/.flactoaiff.$DEAD.0.partial" ] || { echo "FAIL: stale partial not cleaned up"; exit 1; }

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
[ -d "$FOLD" ] || { echo "FAIL: no output folder created for dropped folder"; exit 1; }
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

echo "18. App declares FLAC + folders for Dock drops, with rank None (never the default app)…"
PLIST="build/FlacToAiff.app/Contents/Info.plist"
[ "$(plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes.0 raw "$PLIST" 2>/dev/null)" = "org.xiph.flac" ] \
    || { echo "FAIL: org.xiph.flac not declared"; exit 1; }
for i in 0 1; do
    [ "$(plutil -extract CFBundleDocumentTypes.$i.LSHandlerRank raw "$PLIST")" = "None" ] \
        || { echo "FAIL: document type $i rank is not None (could become the default app)"; exit 1; }
done
[ "$(plutil -extract CFBundleDocumentTypes.1.LSItemContentTypes.0 raw "$PLIST")" = "public.folder" ] \
    || { echo "FAIL: folders not declared"; exit 1; }

echo "19. Converting onto an exFAT volume (typical DJ USB stick) works…"
hdiutil create -quiet -size 20m -fs ExFAT -volname FTA_EXFAT "$TMP/exfat.dmg"
EXFAT="$TMP/exfat"; mkdir "$EXFAT"
hdiutil attach -quiet -nobrowse -mountpoint "$EXFAT" "$TMP/exfat.dmg"
trap 'hdiutil detach -quiet -force "$EXFAT" 2>/dev/null; rm -rf "$TMP"' EXIT
set +e; "$BIN" --convert "$TMP/tone.flac" "$EXFAT" >/dev/null 2>"$TMP/exfat.err"; RC=$?; set -e
[ "$RC" -eq 0 ] && [ -f "$EXFAT/tone.aiff" ] || { echo "FAIL: exFAT conversion failed"; cat "$TMP/exfat.err"; exit 1; }
SECOND="$("$BIN" --convert "$TMP/tone.flac" "$EXFAT")"
[ "$SECOND" = "SKIP $EXFAT/tone.aiff" ] || { echo "FAIL: exFAT re-convert should SKIP, got: $SECOND"; exit 1; }
ls -A "$EXFAT" | grep -q "\.partial$" && { echo "FAIL: temp .partial file left on exFAT"; exit 1; }

echo "20. A long name that fits as .aiff converts (temp name must not overflow NAME_MAX)…"
LONG="$(printf 'a%.0s' {1..245})"
cp "$TMP/tone.flac" "$TMP/$LONG.flac"
set +e; "$BIN" --convert "$TMP/$LONG.flac" "$TMP/long" >/dev/null 2>"$TMP/long.err"; RC=$?; set -e
[ "$RC" -eq 0 ] && [ -f "$TMP/long/$LONG.aiff" ] || { echo "FAIL: long name not converted"; cat "$TMP/long.err"; exit 1; }

echo "21. Two dropped folders with the same name don't merge: the second becomes 'CD1 2'…"
mkdir -p "$TMP/A/CD1" "$TMP/B/CD1"
cp "$TMP/tone.flac" "$TMP/A/CD1/01.flac"
cp "$TMP/t16.flac"  "$TMP/B/CD1/01.flac"
SAME="$TMP/same"
"$BIN" --convert "$TMP/A/CD1" "$TMP/B/CD1" "$SAME" >/dev/null
fmt "$SAME/CD1/01.aiff"   | grep -q "24-bit" || { echo "FAIL: A/CD1 not in CD1"; ls -R "$SAME"; exit 1; }
fmt "$SAME/CD1 2/01.aiff" | grep -q "16-bit" || { echo "FAIL: B/CD1 not in 'CD1 2'"; ls -R "$SAME"; exit 1; }
AGAIN="$("$BIN" --convert "$TMP/A/CD1" "$TMP/B/CD1" "$SAME" | grep -c '^SKIP')"
[ "$AGAIN" -eq 2 ] || { echo "FAIL: re-dropping both should skip both, got $AGAIN SKIPs"; exit 1; }

echo "22. Packages inside a dropped folder (e.g. an .app or a library bundle) are not entered…"
PKG="$TMP/WithPackage"
mkdir -p "$PKG/Plugin.bundle/Contents/Resources"
cp "$TMP/tone.flac" "$PKG/Plugin.bundle/Contents/Resources/sample.flac"
cp "$TMP/tone.flac" "$PKG/real.flac"
ln -s "$TMP/t16.flac" "$PKG/linked.flac"   # symlinked FLACs still count
"$BIN" --convert "$PKG" "$TMP/pkgout" >/dev/null
ACTUAL="$(cd "$TMP/pkgout" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort)"
EXPECTED="$(printf '%s\n' "WithPackage" "WithPackage/linked.aiff" "WithPackage/real.aiff")"
[ "$ACTUAL" = "$EXPECTED" ] || { echo "FAIL: wrong output tree (package entered or symlink skipped)"; diff <(echo "$EXPECTED") <(echo "$ACTUAL"); exit 1; }

# wait_for <path> [seconds]: succeeds once <path> exists, fails after the timeout (default 20 s).
wait_for() {
    local i
    for ((i = 0; i < ${2:-20} * 4; i++)); do [ -e "$1" ] && return 0; sleep 0.25; done
    return 1
}
frames() { afinfo "$1" | sed -n 's/^audio packets: //p'; }   # PCM: 1 packet = 1 frame

echo "23. Watch folder: a FLAC copied in converts; hidden and non-FLAC files are ignored…"
WATCH="$TMP/watch"; WOUT="$TMP/watchout"; mkdir -p "$WATCH" "$WOUT"
"$BIN" --watch "$WATCH" "$WOUT" > "$TMP/watch.log" 2>&1 &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null; hdiutil detach -quiet -force "$EXFAT" 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 1   # let the FSEvents stream start
cp "$TMP/tone.flac" "$WATCH/new.flac"
cp "$TMP/tone.flac" "$WATCH/.hidden.flac"
echo x > "$WATCH/notes.txt"
wait_for "$WOUT/new.aiff" || { echo "FAIL: watched FLAC not converted"; cat "$TMP/watch.log"; exit 1; }
fmt "$WOUT/new.aiff" | grep -q "24-bit" || { echo "FAIL: watched output not a valid AIFF"; exit 1; }

echo "24. Watch folder: a FLAC still being written converts only once complete…"
SIZE="$(stat -f %z "$TMP/tone.flac")"; HALF=$((SIZE / 2))
head -c "$HALF" "$TMP/tone.flac" > "$WATCH/slow.flac"
sleep 1.5
tail -c +$((HALF + 1)) "$TMP/tone.flac" >> "$WATCH/slow.flac"
wait_for "$WOUT/slow.aiff" || { echo "FAIL: slowly written FLAC not converted"; cat "$TMP/watch.log"; exit 1; }
[ "$(frames "$WOUT/slow.aiff")" = "$(frames "$WOUT/new.aiff")" ] \
    || { echo "FAIL: converted before the file was complete"; cat "$TMP/watch.log"; exit 1; }

echo "25. Watch folder: a folder moved in keeps its structure…"
mkdir -p "$TMP/incoming/Some Album/CD2"
cp "$TMP/t16.flac" "$TMP/incoming/Some Album/CD2/02 Track.flac"
mv "$TMP/incoming/Some Album" "$WATCH/"
wait_for "$WOUT/Some Album/CD2/02 Track.aiff" || { echo "FAIL: moved-in folder not converted"; ls -R "$WOUT"; cat "$TMP/watch.log"; exit 1; }
sleep 3   # give stray events time to (wrongly) produce more work
kill $WATCHER; wait $WATCHER 2>/dev/null || true
[ ! -e "$WOUT/.hidden.aiff" ] && [ ! -e "$WOUT/notes.aiff" ] || { echo "FAIL: hidden/non-FLAC file converted"; exit 1; }
grep -q '^ERROR' "$TMP/watch.log" && { echo "FAIL: watcher reported errors"; cat "$TMP/watch.log"; exit 1; }
[ "$(grep -c '^OK' "$TMP/watch.log")" -eq 3 ] || { echo "FAIL: expected exactly 3 OK lines"; cat "$TMP/watch.log"; exit 1; }
grep -q '^SKIP' "$TMP/watch.log" && { echo "FAIL: a watched file was handed off twice"; cat "$TMP/watch.log"; exit 1; }

echo
echo "PASS: all checks."
