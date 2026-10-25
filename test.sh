#!/bin/bash
# End-to-end test: synthesize a FLAC, run the converter core, verify the AIFF.
set -euo pipefail
# A "$(…)" assignment whose command fails would end the run silently under -e: such
# assignments end in "|| true" so the check after them prints a proper FAIL.
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
SECOND="$("$BIN" --convert "$TMP/tone.flac" "$DEST" || true)"
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
SKIPS="$(cat "$TMP"/race.* | grep -c '^SKIP' || true)"
[ "$SKIPS" -eq 3 ] || { echo "FAIL: expected 3 SKIP lines, got $SKIPS"; cat "$TMP"/race.*; exit 1; }

echo "10. --convert with wrong arity exits 2 with usage (never launches GUI)…"
set +e
"$BIN" --convert "$TMP/tone.flac" 2>"$TMP/usage.txt"; RC=$?
set -e
[ "$RC" -eq 2 ] || { echo "FAIL: expected exit 2, got $RC"; exit 1; }
grep -q "usage:" "$TMP/usage.txt" || { echo "FAIL: no usage message"; exit 1; }

# tag_flac <src.flac> <dst.flac> [KEY=VALUE…]: copy src, adding TITLE/ARTIST/ALBUM (non-ASCII) Vorbis
# comments plus any extras (a literal \0 in one becomes NUL). PICTURE=1 adds a tiny front-cover
# PICTURE block, PICTURE=2 that plus a back cover.
tag_flac() {
python3 -I - "$@" <<'PY'
import sys, struct
src, dst, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
d = open(src, 'rb').read()
i, out = 4, bytearray(b'fLaC')
while True:   # copy metadata blocks, clearing the "last block" flag
    h, n = d[i], int.from_bytes(d[i+1:i+4], 'big')
    out += bytes([h & 0x7F]) + d[i+1:i+4+n]
    i += 4 + n
    if h & 0x80: break
vals = [b'TITLE=Song Title', b'ARTIST=Some Artist', 'ALBUM=Album 蒸發'.encode()] + [e.replace('\\0', '\0').encode() for e in extra if not e.startswith('PICTURE=')]   # literal \0 in an argument becomes NUL
body = struct.pack('<I', 0) + struct.pack('<I', len(vals)) + b''.join(struct.pack('<I', len(v)) + v for v in vals)
pics = 'PICTURE=1' in extra or 'PICTURE=2' in extra or 'PICTURE=empty' in extra
out += bytes([0x04 if pics else 0x84]) + len(body).to_bytes(3, 'big') + body
if pics:   # front cover, 16 header-ish JPEG bytes: players only need the bytes back
    jpg = b'' if 'PICTURE=empty' in extra else bytes.fromhex('ffd8ffe000104a46494600010100000100010000ffd9')   # empty: a tagger's placeholder
    pic = struct.pack('>I', 3) + struct.pack('>I', 10) + b'image/jpeg' + struct.pack('>I', 0) + struct.pack('>5I', 1, 1, 24, 0, len(jpg)) + jpg
    last = 'PICTURE=2' not in extra
    out += bytes([0x86 if last else 0x06]) + len(pic).to_bytes(3, 'big') + pic
    if not last:   # plus a back cover (type 4) with different bytes
        jpg2 = jpg[:-2] + b'back' + jpg[-2:]
        pic2 = struct.pack('>I', 4) + struct.pack('>I', 10) + b'image/jpeg' + struct.pack('>I', 0) + struct.pack('>5I', 1, 1, 24, 0, len(jpg2)) + jpg2
        out += bytes([0x86]) + len(pic2).to_bytes(3, 'big') + pic2
out += d[i:]
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
MULTI="$("$BIN" --convert "$TMP/tone.flac" "$TMP/t16.flac" "$TMP/multi" | grep -c '^OK ' || true)"
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
SECOND="$("$BIN" --convert "$TMP/tone.flac" "$EXFAT" || true)"
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
AGAIN="$("$BIN" --convert "$TMP/A/CD1" "$TMP/B/CD1" "$SAME" | grep -c '^SKIP' || true)"
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
# wait_log <file> <pattern> [seconds]: succeeds once a line in <file> matches <pattern>.
wait_log() {
    local i
    for ((i = 0; i < ${3:-20} * 4; i++)); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.25; done
    return 1
}
frames() { afinfo "$1" | sed -n 's/^audio packets: //p'; }   # PCM: 1 packet = 1 frame

echo "23. Watch folder: a FLAC copied in converts; hidden and non-FLAC files are ignored…"
WATCH="$TMP/watch"; WOUT="$TMP/watchout"; mkdir -p "$WATCH" "$WOUT"
"$BIN" --watch "$WATCH" "$WOUT" > "$TMP/watch.log" 2>&1 &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null; hdiutil detach -quiet -force "$EXFAT" 2>/dev/null; rm -rf "$TMP"' EXIT
wait_log "$TMP/watch.log" '^WATCHING ' || { echo "FAIL: --watch never reported it was ready"; cat "$TMP/watch.log"; exit 1; }
cp "$TMP/tone.flac" "$WATCH/new.flac"
cp "$TMP/tone.flac" "$WATCH/.hidden.flac"
echo x > "$WATCH/notes.txt"
wait_for "$WOUT/new.aiff" || { echo "FAIL: watched FLAC not converted"; cat "$TMP/watch.log"; exit 1; }
fmt "$WOUT/new.aiff" | grep -q "24-bit" || { echo "FAIL: watched output not a valid AIFF"; exit 1; }

echo "24. Watch folder: a FLAC still being written converts only once complete…"
SIZE="$(stat -f %z "$TMP/tone.flac")"; HALF=$((SIZE / 2))
head -c "$HALF" "$TMP/tone.flac" > "$WATCH/slow.flac"
sleep 1   # well under the 2 s settle time (test 27 covers longer stalls)
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

echo "26. A truncated FLAC fails as incomplete instead of becoming a short AIFF…"
SIZE="$(stat -f %z "$TMP/tone.flac")"
head -c $((SIZE / 2)) "$TMP/tone.flac" > "$TMP/truncated.flac"
set +e; "$BIN" --convert "$TMP/truncated.flac" "$TMP/trunc" >/dev/null 2>"$TMP/trunc.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "incomplete" "$TMP/trunc.err" || { echo "FAIL: truncated FLAC not reported as incomplete"; cat "$TMP/trunc.err"; exit 1; }
[ ! -e "$TMP/trunc/truncated.aiff" ] || { echo "FAIL: short AIFF published for a truncated FLAC"; exit 1; }
ls -A "$TMP/trunc" | grep -q "\.partial$" && { echo "FAIL: temp file left after incomplete FLAC"; exit 1; }

echo "27. Watch folder: a writer that pauses, and a Firefox-style empty placeholder, end as full AIFFs…"
WATCH2="$TMP/watch2"; WOUT2="$TMP/watchout2"; mkdir -p "$WATCH2"
"$BIN" --watch "$WATCH2" "$WOUT2" > "$TMP/watch2.log" 2>&1 &
WATCHER=$!
wait_log "$TMP/watch2.log" '^WATCHING ' || { echo "FAIL: --watch never reported it was ready"; exit 1; }
: > "$WATCH2/ff.flac"                                   # Firefox: empty placeholder first…
head -c $((SIZE / 2)) "$TMP/tone.flac" > "$WATCH2/stall.flac"
sleep 3.5                                               # …a writer stalled longer than the 2 s settle time
cp "$TMP/tone.flac" "$WATCH2/.ff.flac.part" && mv "$WATCH2/.ff.flac.part" "$WATCH2/ff.flac"
tail -c +$((SIZE / 2 + 1)) "$TMP/tone.flac" >> "$WATCH2/stall.flac"
wait_log "$TMP/watch2.log" "^OK .*/stall.aiff" || { echo "FAIL: stalled FLAC never converted in full"; cat "$TMP/watch2.log"; exit 1; }
wait_log "$TMP/watch2.log" "^OK .*/ff.aiff" || { echo "FAIL: Firefox-style download not converted"; cat "$TMP/watch2.log"; exit 1; }
kill $WATCHER; wait $WATCHER 2>/dev/null || true
[ "$(frames "$WOUT2/stall.aiff")" = "$(frames "$WOUT/new.aiff")" ] || { echo "FAIL: stalled FLAC gave a short AIFF"; exit 1; }
grep -q "^ERROR ff.flac" "$TMP/watch2.log" && { echo "FAIL: empty placeholder reported as an error"; cat "$TMP/watch2.log"; exit 1; }

echo "28. Watch catch-up: only FLACs (or folders) added after the given time convert…"
W3="$TMP/watch3"; mkdir -p "$W3" "$TMP/incoming3/Late Album"
cp "$TMP/tone.flac" "$W3/old.flac"                          # already there: must be left alone
cp "$TMP/t16.flac" "$TMP/incoming3/Late Album/inside.flac"  # its own Date Added stays old
sleep 2; SINCE="$(date +%s)"; sleep 1
cp "$TMP/tone.flac" "$W3/new.flac"
mv "$TMP/incoming3/Late Album" "$W3/"
sleep 1   # these arrive before the watcher starts: only catch-up can find them
"$BIN" --watch --catch-up-since "$SINCE" "$W3" "$TMP/watchout3" > "$TMP/watch3.log" 2>&1 &
WATCHER=$!
wait_log "$TMP/watch3.log" "^OK .*/new.aiff" || { echo "FAIL: FLAC added while 'quit' not caught up"; cat "$TMP/watch3.log"; exit 1; }
wait_log "$TMP/watch3.log" "^OK .*/Late Album/inside.aiff" || { echo "FAIL: folder moved in while 'quit' not caught up"; cat "$TMP/watch3.log"; exit 1; }
sleep 3
kill $WATCHER; wait $WATCHER 2>/dev/null || true
[ ! -e "$TMP/watchout3/old.aiff" ] || { echo "FAIL: FLAC that was already there got converted"; exit 1; }

# flac20 <out.flac>: a hand-written 20-bit mono FLAC (one VERBATIM frame, 4096 samples),
# since afconvert can't encode 20-bit. afconvert decodes it, so the converter sees a real 20-bit source.
flac20() {
python3 -I - "$1" <<'PY'
import sys, math, hashlib
N = 4096
def crc(data, poly, bits):
    c, top, mask = 0, 1 << (bits - 1), (1 << bits) - 1
    for b in data:
        c ^= b << (bits - 8)
        for _ in range(8):
            c = ((c << 1) ^ poly) & mask if c & top else (c << 1) & mask
    return c
samples = [int(300000 * math.sin(i * 0.05)) for i in range(N)]
md5 = hashlib.md5(b''.join(s.to_bytes(3, 'little', signed=True) for s in samples)).digest()
packed = (44100 << 44) | (0 << 41) | (19 << 36) | N   # rate, channels-1, bps-1, total samples
info = (N.to_bytes(2, 'big') * 2) + bytes(6) + packed.to_bytes(8, 'big') + md5
header = bytes([0xFF, 0xF8, 0xC9, 0x0A, 0x00])   # sample-size code 0b101 = 20-bit
header += bytes([crc(header, 0x07, 8)])
body = bytes([0x02])   # subframe header: VERBATIM
bits = ''.join(format(s & 0xFFFFF, '020b') for s in samples)
body += int(bits, 2).to_bytes(len(bits) // 8, 'big')
frame = header + body
frame += crc(frame, 0x8005, 16).to_bytes(2, 'big')
open(sys.argv[1], 'wb').write(b'fLaC' + bytes([0x80, 0, 0, 34]) + info + frame)
PY
}

echo "29. Verification: lossless outputs are verified, tampered audio is refused…"
TAB="$(printf '\t')"
V1="$TMP/v1"
[ "$("$BIN" --convert "$TMP/tone.flac" "$V1")" = "OK $V1/tone.aiff${TAB}verified" ] || { echo "FAIL: 24-bit mono not verified"; exit 1; }
[ "$("$BIN" --convert "$TMP/t16.flac" "$V1")" = "OK $V1/t16.aiff${TAB}verified" ] || { echo "FAIL: 16-bit not verified"; exit 1; }
afconvert -f flac -d flac -c 2 "$TMP/tone.aiff" "$TMP/st.flac" 2>/dev/null \
    || { say -o "$TMP/st.aiff" --data-format=BEI24@44100 --channels=2 "stereo tone" && afconvert -f flac -d flac "$TMP/st.aiff" "$TMP/st.flac"; }
afinfo "$TMP/st.flac" | grep -q "2 ch" || { echo "FAIL: test setup: no stereo FLAC"; exit 1; }
[ "$("$BIN" --convert "$TMP/st.flac" "$V1")" = "OK $V1/st.aiff${TAB}verified" ] || { echo "FAIL: stereo not verified"; exit 1; }
flac20 "$TMP/b20.flac"
afinfo "$TMP/b20.flac" | grep -q "I20" || { echo "FAIL: test setup: hand-made FLAC is not 20-bit"; afinfo "$TMP/b20.flac"; exit 1; }
[ "$("$BIN" --convert "$TMP/b20.flac" "$V1")" = "OK $V1/b20.aiff${TAB}verified" ] || { echo "FAIL: 20-bit not verified"; exit 1; }

cp "$TMP/tone.flac" "$TMP/badmd5.flac"
printf '\x5a' | dd of="$TMP/badmd5.flac" bs=1 seek=30 conv=notrunc 2>/dev/null
set +e; "$BIN" --convert "$TMP/badmd5.flac" "$TMP/v2" >/dev/null 2>"$TMP/v.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "Audio doesn't match the FLAC's checksum" "$TMP/v.err" || { echo "FAIL: tampered MD5 not refused"; cat "$TMP/v.err"; exit 1; }
[ ! -e "$TMP/v2/badmd5.aiff" ] && ! ls -A "$TMP/v2" 2>/dev/null | grep -q "\.partial$" || { echo "FAIL: output or .partial left after refusal"; exit 1; }

cp "$TMP/tone.flac" "$TMP/nomd5.flac"
dd if=/dev/zero of="$TMP/nomd5.flac" bs=1 seek=26 count=16 conv=notrunc 2>/dev/null
[ "$("$BIN" --convert "$TMP/nomd5.flac" "$V1")" = "OK $V1/nomd5.aiff${TAB}format checked" ] || { echo "FAIL: zero MD5 should be format checked"; exit 1; }
[ "$("$BIN" --convert --format max48 "$TMP/hr96.flac" "$TMP/v3")" = "OK $TMP/v3/hr96.aiff${TAB}format checked" ] || { echo "FAIL: resampled should be format checked"; exit 1; }

set +e; FLACTOAIFF_TEST_DAMAGE=format "$BIN" --convert "$TMP/tone.flac" "$TMP/v4" >/dev/null 2>"$TMP/v.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "Output format is wrong" "$TMP/v.err" || { echo "FAIL: format damage not refused"; cat "$TMP/v.err"; exit 1; }
[ ! -e "$TMP/v4/tone.aiff" ] && ! ls -A "$TMP/v4" 2>/dev/null | grep -q "\.partial$" || { echo "FAIL: output or .partial left after format refusal"; exit 1; }

echo "30. Verification: tags read back through AVFoundation…"
tag_flac "$TMP/tone.flac" "$TMP/full.flac" 'GENRE=(13)' BPM=128 INITIALKEY=Am 'COMMENT=Nice track 蒸發' CATALOG=XYZ1 \
    DATE=2026-03-01 TRACKNUMBER=3 TRACKTOTAL=12 DISCNUMBER=1 DISCTOTAL=2 ALBUMARTIST='Various Artists' \
    'TITLE=Song\0' 'ARTIST=A\0B' 'MOOD=x\0' PICTURE=2
[ "$("$BIN" --convert "$TMP/full.flac" "$TMP/t1")" = "OK $TMP/t1/full.aiff${TAB}verified" ] || { echo "FAIL: fully tagged FLAC not verified"; exit 1; }
tag_flac "$TMP/hr96.flac" "$TMP/fullhr.flac" BPM=128 PICTURE=1
[ "$("$BIN" --convert --format max48 "$TMP/fullhr.flac" "$TMP/t2")" = "OK $TMP/t2/fullhr.aiff${TAB}tags verified" ] || { echo "FAIL: resampled tagged FLAC not 'tags verified'"; exit 1; }
set +e; FLACTOAIFF_TEST_DAMAGE=tags "$BIN" --convert "$TMP/full.flac" "$TMP/t3" >/dev/null 2>"$TMP/v.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "Tag check failed: artwork" "$TMP/v.err" || { echo "FAIL: tag damage not refused"; cat "$TMP/v.err"; exit 1; }
[ ! -e "$TMP/t3/full.aiff" ] && ! ls -A "$TMP/t3" 2>/dev/null | grep -q "\.partial$" || { echo "FAIL: output or .partial left after tag refusal"; exit 1; }

echo "31. Verification: memory stays flat on a long hi-res file…"
python3 -I - "$TMP/long.aiff" <<'PY'
import sys, os, struct
data = os.urandom(3 << 20) * 70   # 210 MB of 24-bit stereo (35 min at 96 kHz)
comm = b'COMM' + struct.pack('>IhIh', 18, 2, len(data) // 6, 24) + bytes([0x40, 0x0F, 0xBB, 0x80]) + bytes(6)
ssnd = b'SSND' + struct.pack('>III', len(data) + 8, 0, 0)
with open(sys.argv[1], 'wb') as f:
    f.write(b'FORM' + struct.pack('>I', 4 + len(comm) + len(ssnd) + len(data)) + b'AIFF' + comm + ssnd)
    f.write(data)
PY
afconvert -f flac -d flac "$TMP/long.aiff" "$TMP/long.flac" || { echo "FAIL: test setup: no long FLAC"; exit 1; }
rm "$TMP/long.aiff"
RSS="$(/usr/bin/time -l "$BIN" --convert "$TMP/long.flac" "$TMP/t4" 2>&1 >"$TMP/long.out" | awk '/maximum resident/ {print $1}' || true)"
rm -f "$TMP/long.flac"
grep -q "${TAB}verified" "$TMP/long.out" || { echo "FAIL: long file not verified"; cat "$TMP/long.out"; exit 1; }
[ "${RSS:-999999999}" -lt 100000000 ] || { echo "FAIL: verifying a 210 MB file peaked at $RSS bytes of memory"; exit 1; }

# id3_prefix <src.flac> <dst.flac>: prepend an ID3v2.3 tag (TIT2 "Prefix"), as some taggers do.
id3_prefix() {
python3 -I - "$1" "$2" <<'PY'
import sys
body = b'\x00Prefix'
frame = b'TIT2' + len(body).to_bytes(4, 'big') + b'\x00\x00' + body
size = len(frame)
tag = b'ID3\x03\x00\x00' + bytes([size >> 21 & 0x7F, size >> 14 & 0x7F, size >> 7 & 0x7F, size & 0x7F]) + frame
open(sys.argv[2], 'wb').write(tag + open(sys.argv[1], 'rb').read())
PY
}

echo "32. Tag quirks never block a conversion: a NUL in a tag name, an empty picture…"
tag_flac "$TMP/tone.flac" "$TMP/nulkey.flac" 'AB\0C=val'
OUT32="$("$BIN" --convert "$TMP/nulkey.flac" "$TMP/q" 2>&1 || true)"
[ "$OUT32" = "OK $TMP/q/nulkey.aiff${TAB}verified" ] || { echo "FAIL: NUL in a tag name blocked the conversion: $OUT32"; exit 1; }
tag_flac "$TMP/tone.flac" "$TMP/emptypic.flac" PICTURE=empty
OUT32="$("$BIN" --convert "$TMP/emptypic.flac" "$TMP/q" 2>&1 || true)"
[ "$OUT32" = "OK $TMP/q/emptypic.aiff${TAB}verified" ] || { echo "FAIL: empty picture blocked the conversion: $OUT32"; exit 1; }

echo "33. A FLAC with a leading ID3v2 tag keeps its tags and all checks, and fails when truncated…"
tag_flac "$TMP/tone.flac" "$TMP/plain.flac"
id3_prefix "$TMP/plain.flac" "$TMP/prefixed.flac"
OUT33="$("$BIN" --convert "$TMP/prefixed.flac" "$TMP/p" 2>&1 || true)"
[ "$OUT33" = "OK $TMP/p/prefixed.aiff${TAB}verified" ] || { echo "FAIL: ID3-prefixed FLAC not fully verified: $OUT33"; exit 1; }
check_tags "$TMP/p/prefixed.aiff" || { echo "FAIL: ID3-prefixed FLAC lost its Vorbis tags"; exit 1; }
PSIZE="$(stat -f %z "$TMP/prefixed.flac")"
head -c $((PSIZE / 2)) "$TMP/prefixed.flac" > "$TMP/prefixhalf.flac"
set +e; "$BIN" --convert "$TMP/prefixhalf.flac" "$TMP/p" >/dev/null 2>"$TMP/ph.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "incomplete" "$TMP/ph.err" || { echo "FAIL: truncated ID3-prefixed FLAC not refused"; cat "$TMP/ph.err"; exit 1; }

echo "34. Watch folder: renames inside it and packages moved in don't convert; future timestamps do…"
W4="$TMP/watch4"; O4="$TMP/watchout4"; mkdir -p "$W4" "$TMP/in4/Album/Disc 1" "$TMP/in4/Plug.bundle/Contents"
cp "$TMP/tone.flac" "$TMP/in4/Album/Disc 1/a.flac"
cp "$TMP/tone.flac" "$TMP/in4/Plug.bundle/Contents/inner.flac"
"$BIN" --watch "$W4" "$O4" > "$TMP/watch4.log" 2>&1 &
WATCHER=$!
wait_log "$TMP/watch4.log" '^WATCHING ' || { echo "FAIL: --watch never reported it was ready"; exit 1; }
mv "$TMP/in4/Album" "$W4/"
wait_log "$TMP/watch4.log" "^OK .*/Album/Disc 1/a.aiff" || { echo "FAIL: moved-in album not converted"; cat "$TMP/watch4.log"; exit 1; }
mv "$W4/Album" "$W4/Album (2024)"                     # rename a folder inside the watch folder
mv "$W4/Album (2024)/Disc 1/a.flac" "$W4/Album (2024)/Disc 1/A Side.flac"   # and a file
mkdir "$W4/Sorted"; mv "$W4/Album (2024)" "$W4/Sorted/"                     # and move one into a subfolder
mv "$TMP/in4/Plug.bundle" "$W4/"                      # a package moved in
cp -p "$TMP/t16.flac" "$TMP/future.flac"; touch -t "$(date -v+2H +%Y%m%d%H%M)" "$TMP/future.flac"
cp -p "$TMP/future.flac" "$W4/future.flac"            # clock-skewed mtime, 2 h ahead
wait_log "$TMP/watch4.log" "^OK .*/future.aiff" || { echo "FAIL: FLAC with a future timestamp never converted"; cat "$TMP/watch4.log"; exit 1; }
sleep 3
kill $WATCHER; wait $WATCHER 2>/dev/null || true
[ "$(grep -c '^OK' "$TMP/watch4.log")" -eq 2 ] || { echo "FAIL: renames or a package produced conversions"; cat "$TMP/watch4.log"; exit 1; }
[ ! -e "$O4/Plug.bundle" ] || { echo "FAIL: package contents converted"; exit 1; }

echo
echo "PASS: all checks."
