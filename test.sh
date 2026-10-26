#!/bin/bash
# End-to-end test: synthesize a FLAC, run the converter core, verify the AIFF.
set -euo pipefail
# A "$(…)" assignment whose command fails would end the run silently under -e: such
# assignments end in "|| true" so the check after them prints a proper FAIL.
cd "$(dirname "$0")"

BIN="build/FlacToAiff.app/Contents/MacOS/FlacToAiff"
# Test what the sources say now, not an older build.
if [ ! -x "$BIN" ] || [ -n "$(find Sources scripts build.sh -newer "$BIN" | head -1)" ]; then ./build.sh; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Failure paths real files can't reach are driven by FLACTOAIFF_TEST_DAMAGE, which only a
# binary compiled with -D TEST_HOOKS reads; the app itself never does (check 35).
# It is built for the architecture this run uses, so "arch -x86_64 ./test.sh" tests Intel throughout.
HOOKBIN="$TMP/FlacToAiff-testhooks"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' build/FlacToAiff.app/Contents/Info.plist)"
swiftc -O -target "$(uname -m)-apple-macos$MINOS" -D TEST_HOOKS -o "$HOOKBIN" Sources/*.swift -framework AppKit -framework SwiftUI

echo "Testing the $(uname -m) build."

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
# PICTURE block, PICTURE=2 that plus a back cover. PICTURE=mixed writes, in this order, a URL
# picture, a file icon, a back cover and a front cover.
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
mixed = 'PICTURE=mixed' in extra
out += bytes([0x04 if pics or mixed else 0x84]) + len(body).to_bytes(3, 'big') + body
if mixed:
    def block(kind, mime, data):
        return struct.pack('>I', kind) + struct.pack('>I', len(mime)) + mime + struct.pack('>I', 0) + struct.pack('>5I', 1, 1, 24, 0, len(data)) + data
    blocks = [block(3, b'-->', b'https://example.com/cover.jpg'), block(1, b'image/png', b'\x89PNGicon'),
              block(4, b'image/jpeg', b'\xff\xd8back\xff\xd9'), block(3, b'image/jpeg', b'\xff\xd8front\xff\xd9')]
    for n, b in enumerate(blocks):
        out += bytes([0x86 if n == len(blocks) - 1 else 0x06]) + len(b).to_bytes(3, 'big') + b
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
    if fid[0] == 'T' and fid != 'TXXX': frames[fid] = tag[j+10:j+10+n][1:].decode('utf-16')
    j += 10 + n
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
[ "$RC" -eq 1 ] && grep -q "No FLAC, WAV or ALAC files found" "$TMP/nf.err" || { echo "FAIL: empty folder not reported"; exit 1; }
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
for i in 0 1 2 3; do
    [ "$(plutil -extract CFBundleDocumentTypes.$i.LSHandlerRank raw "$PLIST")" = "None" ] \
        || { echo "FAIL: document type $i rank is not None (could become the default app)"; exit 1; }
done
[ "$(plutil -extract CFBundleDocumentTypes.1.LSItemContentTypes.0 raw "$PLIST")" = "com.microsoft.waveform-audio" ] \
    || { echo "FAIL: WAV not declared"; exit 1; }
[ "$(plutil -extract CFBundleDocumentTypes.2.LSItemContentTypes.0 raw "$PLIST")" = "com.apple.m4a-audio" ] \
    || { echo "FAIL: ALAC (.m4a) not declared"; exit 1; }
[ "$(plutil -extract CFBundleDocumentTypes.3.LSItemContentTypes.0 raw "$PLIST")" = "public.folder" ] \
    || { echo "FAIL: folders not declared"; exit 1; }

echo "19. Converting onto an exFAT volume (typical DJ USB stick) works…"
hdiutil create -quiet -size 20m -fs ExFAT -volname FTA_EXFAT "$TMP/exfat.dmg"
EXFAT="$TMP/exfat"; mkdir "$EXFAT"
hdiutil attach -quiet -nobrowse -mountpoint "$EXFAT" "$TMP/exfat.dmg"
trap 'hdiutil detach -quiet -force "$EXFAT" 2>/dev/null || true; rm -rf "$TMP"' EXIT
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
trap 'kill $WATCHER 2>/dev/null || true; hdiutil detach -quiet -force "$EXFAT" 2>/dev/null || true; rm -rf "$TMP"' EXIT
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

set +e; FLACTOAIFF_TEST_DAMAGE=format "$HOOKBIN" --convert "$TMP/tone.flac" "$TMP/v4" >/dev/null 2>"$TMP/v.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "Output format is wrong" "$TMP/v.err" || { echo "FAIL: format damage not refused"; cat "$TMP/v.err"; exit 1; }
[ ! -e "$TMP/v4/tone.aiff" ] && ! ls -A "$TMP/v4" 2>/dev/null | grep -q "\.partial$" || { echo "FAIL: output or .partial left after format refusal"; exit 1; }

echo "30. Verification: tags read back through AVFoundation…"
tag_flac "$TMP/tone.flac" "$TMP/full.flac" 'GENRE=(13)' BPM=128 INITIALKEY=Am 'COMMENT=Nice track 蒸發' CATALOG=XYZ1 \
    DATE=2026-03-01 TRACKNUMBER=3 TRACKTOTAL=12 DISCNUMBER=1 DISCTOTAL=2 ALBUMARTIST='Various Artists' \
    'TITLE=Song\0' 'ARTIST=A\0B' 'MOOD=x\0' PICTURE=2
[ "$("$BIN" --convert "$TMP/full.flac" "$TMP/t1")" = "OK $TMP/t1/full.aiff${TAB}verified" ] || { echo "FAIL: fully tagged FLAC not verified"; exit 1; }
tag_flac "$TMP/hr96.flac" "$TMP/fullhr.flac" BPM=128 PICTURE=1
[ "$("$BIN" --convert --format max48 "$TMP/fullhr.flac" "$TMP/t2")" = "OK $TMP/t2/fullhr.aiff${TAB}tags verified" ] || { echo "FAIL: resampled tagged FLAC not 'tags verified'"; exit 1; }
set +e; FLACTOAIFF_TEST_DAMAGE=tags "$HOOKBIN" --convert "$TMP/full.flac" "$TMP/t3" >/dev/null 2>"$TMP/v.err"; RC=$?; set -e
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

echo "35. The app itself ignores the test-only damage hooks…"
OUT35="$(FLACTOAIFF_TEST_DAMAGE=format "$BIN" --convert "$TMP/tone.flac" "$TMP/nohook" 2>&1 || true)"
[ "$OUT35" = "OK $TMP/nohook/tone.aiff${TAB}verified" ] || { echo "FAIL: the app binary honours FLACTOAIFF_TEST_DAMAGE: $OUT35"; exit 1; }

echo "36. 8, 12 and 32-bit FLACs, which macOS can't decode, fail with a clear reason in every format…"
MAKEFLAC="$TMP/make-flac"
swiftc -O -o "$MAKEFLAC" scripts/make-flac.swift
for b in 16 24; do   # the fixture writer makes FLACs macOS decodes bit for bit
    "$MAKEFLAC" $b 44100 1 "$TMP/fix$b.flac"
    OUT36="$("$BIN" --convert "$TMP/fix$b.flac" "$TMP/fix" 2>&1 || true)"
    [ "$OUT36" = "OK $TMP/fix/fix$b.aiff${TAB}verified" ] || { echo "FAIL: $b-bit fixture didn't verify: $OUT36"; exit 1; }
done
for b in 8 12 32; do
    "$MAKEFLAC" $b 44100 1 "$TMP/s$b.flac"
    for m in original max48 cd; do
        set +e; "$BIN" --convert --format "$m" "$TMP/s$b.flac" "$TMP/s$b-$m" 2>"$TMP/s$b.err"; RC=$?; set -e
        [ "$RC" -eq 1 ] && grep -q "can't decode $b-bit FLAC" "$TMP/s$b.err" \
            || { echo "FAIL: $m: $b-bit FLAC not refused clearly"; cat "$TMP/s$b.err"; exit 1; }
        [ -z "$(ls -A "$TMP/s$b-$m" 2>/dev/null)" ] || { echo "FAIL: $m: $b-bit FLAC left files behind"; ls -A "$TMP/s$b-$m"; exit 1; }
    done
done

echo "37. Watch folder: FLACs already there stay alone when tagged, renamed or re-sorted; finished downloads convert…"
W5="$TMP/watch5"; O5="$TMP/watchout5"; mkdir -p "$W5/Old Album"
cp "$TMP/tone.flac" "$W5/pre1.flac"; cp "$TMP/tone.flac" "$W5/pre2.flac"; cp "$TMP/tone.flac" "$W5/pre3.flac"
cp "$TMP/tone.flac" "$W5/pre4.flac"; cp "$TMP/tone.flac" "$W5/Old Album/x.flac"
sleep 1.1
"$BIN" --watch "$W5" "$O5" > "$TMP/watch5.log" 2>&1 &
WATCHER=$!
wait_log "$TMP/watch5.log" '^WATCHING ' || { echo "FAIL: --watch never reported it was ready"; exit 1; }
xattr -w com.apple.metadata:_kMDItemUserTags x "$W5/pre1.flac"   # a Finder tag
chmod 600 "$W5/pre2.flac"
mv "$W5/pre3.flac" "$W5/renamed.flac"
mkdir "$W5/Sorted"; mv "$W5/pre4.flac" "$W5/Sorted/"              # moving resets Date Added
mv "$W5/Old Album" "$W5/Old Album (2020)"
head -c $((SIZE / 2)) "$TMP/tone.flac" > "$W5/dl.flac.part"      # a browser download…
tail -c +$((SIZE / 2 + 1)) "$TMP/tone.flac" >> "$W5/dl.flac.part"
mv "$W5/dl.flac.part" "$W5/dl.flac"                               # …renamed into place at the end
wait_log "$TMP/watch5.log" "^OK .*/dl.aiff" || { echo "FAIL: finished download not converted"; cat "$TMP/watch5.log"; exit 1; }
sleep 3
kill $WATCHER; wait $WATCHER 2>/dev/null || true
[ "$(grep -c '^OK' "$TMP/watch5.log")" -eq 1 ] || { echo "FAIL: FLACs that were already there got converted"; cat "$TMP/watch5.log"; exit 1; }

echo "38. Launch catch-up finds a download that started before watching stopped and finished after…"
W6="$TMP/watch6"; O6="$TMP/watchout6"; mkdir -p "$W6"
head -c $((SIZE / 2)) "$TMP/tone.flac" > "$W6/late.flac.part"
cp "$TMP/tone.flac" "$W6/old.flac"
sleep 1.1; STOPPED="$(date +%s)"; sleep 1.1                     # watching "stopped" here
tail -c +$((SIZE / 2 + 1)) "$TMP/tone.flac" >> "$W6/late.flac.part"
mv "$W6/late.flac.part" "$W6/late.flac"
"$BIN" --watch --catch-up-since "$STOPPED" "$W6" "$O6" > "$TMP/watch6.log" 2>&1 &
WATCHER=$!
wait_log "$TMP/watch6.log" "^OK .*/late.aiff" || { echo "FAIL: download finished while quit was missed"; cat "$TMP/watch6.log"; exit 1; }
sleep 3
kill $WATCHER; wait $WATCHER 2>/dev/null || true
[ ! -e "$O6/old.aiff" ] || { echo "FAIL: catch-up converted a FLAC from before watching stopped"; exit 1; }

echo "39. Watch folder: a FLAC without a length in its header, written with a pause, converts in full…"
cp "$TMP/tone.flac" "$TMP/nolen.flac"
dd if=/dev/zero of="$TMP/nolen.flac" bs=1 seek=21 count=21 conv=notrunc 2>/dev/null   # no length, no MD5
printf "$(printf '\\x%02x' $(( $(od -An -tu1 -j21 -N1 "$TMP/tone.flac") & 0xF0 )))" \
    | dd of="$TMP/nolen.flac" bs=1 seek=21 conv=notrunc 2>/dev/null                  # keep the bit depth's last bit
W7="$TMP/watch7"; O7="$TMP/watchout7"; mkdir -p "$W7"
"$BIN" --watch "$W7" "$O7" > "$TMP/watch7.log" 2>&1 &
WATCHER=$!
wait_log "$TMP/watch7.log" '^WATCHING ' || { echo "FAIL: --watch never reported it was ready"; exit 1; }
head -c $((SIZE / 2)) "$TMP/nolen.flac" > "$W7/nolen.flac"
sleep 5                                                          # an encoder pausing mid-file
tail -c +$((SIZE / 2 + 1)) "$TMP/nolen.flac" >> "$W7/nolen.flac"
wait_log "$TMP/watch7.log" "^OK .*/nolen.aiff" 45 || { echo "FAIL: FLAC without a length never converted"; cat "$TMP/watch7.log"; exit 1; }
kill $WATCHER; wait $WATCHER 2>/dev/null || true
[ "$(frames "$O7/nolen.aiff")" = "$(frames "$WOUT/new.aiff")" ] || { echo "FAIL: FLAC without a length converted while half written"; exit 1; }

echo "40. Killing a conversion stops afconvert and leaves no temp file…"
"$MAKEFLAC" 24 96000 240 "$TMP/long.flac"
"$BIN" --convert --format cd "$TMP/long.flac" "$TMP/killed" >/dev/null 2>&1 &
CONV=$!
for ((i = 0; i < 100; i++)); do pgrep -f "afconvert.*$TMP/killed" >/dev/null && break; sleep 0.1; done
pgrep -f "afconvert.*$TMP/killed" >/dev/null || { echo "FAIL: conversion never started"; exit 1; }
kill $CONV; wait $CONV 2>/dev/null || true
sleep 0.5
pgrep -f "afconvert.*$TMP/killed" >/dev/null && { echo "FAIL: afconvert kept running"; pkill -f "afconvert.*$TMP/killed"; exit 1; }
[ -z "$(ls -A "$TMP/killed")" ] || { echo "FAIL: killed conversion left files"; ls -A "$TMP/killed"; exit 1; }

echo "41. System errors read as sentences, not error dumps…"
mkdir -p "$TMP/syserr/Album" "$TMP/syserrout"; cp "$TMP/tone.flac" "$TMP/syserr/Album/"
echo x > "$TMP/syserrout/Album"                                  # a file where the album folder goes
set +e; "$BIN" --convert "$TMP/syserr/Album" "$TMP/syserrout" 2>"$TMP/syserr.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "^ERROR tone.flac: " "$TMP/syserr.err" && ! grep -q "Error Domain" "$TMP/syserr.err" \
    || { echo "FAIL: system error not readable"; cat "$TMP/syserr.err"; exit 1; }

echo
echo "42. Tags: the year is found in any date order, and the front cover comes first…"
tag_flac "$TMP/tone.flac" "$TMP/order.flac" DATE=03.05.2026 PICTURE=mixed
[ "$("$BIN" --convert "$TMP/order.flac" "$TMP/t42")" = "OK $TMP/t42/order.aiff${TAB}verified" ] || { echo "FAIL: mixed pictures not verified"; exit 1; }
# Prints TYER's value, then one "APIC <type>" line per picture, in file order.
FRAMES42="$(python3 -I - "$TMP/t42/order.aiff" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
tag = d[d.rindex(b'ID3 ') + 8:]
i, end = 10, 10 + sum((b & 0x7F) << (7 * (3 - n)) for n, b in enumerate(tag[6:10]))
while i + 10 <= end and tag[i] != 0:
    fid, size = tag[i:i+4].decode(), int.from_bytes(tag[i+4:i+8], 'big')
    body = tag[i+10:i+10+size]
    if fid == 'TYER': print(body[1:].decode('utf-16').rstrip('\0'))
    if fid == 'APIC':
        mime_end = body.index(b'\0', 1)
        print('APIC', body[mime_end + 1])
    i += 10 + size
PY
)" || true
EXPECT42="$(printf '2026\nAPIC 3\nAPIC 4\nAPIC 1')"
[ "$FRAMES42" = "$EXPECT42" ] || { echo "FAIL: expected year 2026 and pictures 3, 4, 1 without the URL picture, got:"; echo "$FRAMES42"; exit 1; }

echo "43. 'Already converted' only when the AIFF came from the same file; another file with that name fails…"
C43="$TMP/c43"
mkdir -p "$C43/A" "$C43/B" "$C43/C" "$C43/old"
cp "$TMP/tone.flac" "$C43/A/track.flac"
cp "$TMP/hr96.flac" "$C43/B/track.flac"    # different audio, same name
cp "$TMP/nomd5.flac" "$C43/C/track.flac"   # no audio checksum: told apart by size
"$BIN" --convert "$C43/A/track.flac" "$C43/out" >/dev/null
SUM43="$(md5 -q "$C43/out/track.aiff")"
[ "$("$BIN" --convert "$C43/A/track.flac" "$C43/out")" = "SKIP $C43/out/track.aiff" ] || { echo "FAIL: the same FLAC again should SKIP"; exit 1; }
for other in B C; do
    set +e; "$BIN" --convert "$C43/$other/track.flac" "$C43/out" >/dev/null 2>"$C43/err"; RC=$?; set -e
    [ "$RC" -eq 1 ] && grep -q "track.aiff already exists, made from a different file" "$C43/err" \
        || { echo "FAIL: a different FLAC ($other) with the same name wasn't refused:"; cat "$C43/err"; exit 1; }
done
[ "$(md5 -q "$C43/out/track.aiff")" = "$SUM43" ] || { echo "FAIL: the existing AIFF was changed"; exit 1; }
"$BIN" --convert "$C43/C/track.flac" "$C43/outC" >/dev/null
[ "$("$BIN" --convert "$C43/C/track.flac" "$C43/outC")" = "SKIP $C43/outC/track.aiff" ] || { echo "FAIL: the same FLAC without a checksum should SKIP"; exit 1; }
# An AIFF from an earlier version (or another app) records no source: "Already converted", as before.
afconvert -f AIFF -d BEI16 "$TMP/tone.aiff" "$C43/old/track.aiff"
[ "$("$BIN" --convert "$C43/B/track.flac" "$C43/old")" = "SKIP $C43/old/track.aiff" ] || { echo "FAIL: an AIFF without a recorded source should SKIP"; exit 1; }

echo "44. WAV input: every PCM depth verifies, tags come from INFO and ID3, float is skipped…"
W44="$TMP/w44"; mkdir -p "$W44/in"
afconvert -f AIFF -d BEI24 -c 2 "$TMP/tone.aiff" "$W44/stereo.aiff"
for d in UI8 LEI16 LEI24 LEI32; do afconvert -f WAVE -d "$d" "$W44/stereo.aiff" "$W44/in/$d.wav"; done
afconvert -f WAVE -d LEF32 "$W44/stereo.aiff" "$W44/float.wav"
for d in UI8 LEI16 LEI24 LEI32; do
    [ "$("$BIN" --convert "$W44/in/$d.wav" "$W44/out")" = "OK $W44/out/$d.aiff${TAB}verified" ] || { echo "FAIL: $d WAV not verified"; exit 1; }
done
fmt "$W44/out/UI8.aiff" | grep -q "16-bit" && fmt "$W44/out/LEI32.aiff" | grep -q "32-bit" || { echo "FAIL: WAV depths not matched"; exit 1; }
set +e; "$BIN" --convert "$W44/float.wav" "$W44/fout" >/dev/null 2>"$W44/err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "floating-point WAV can't become a lossless AIFF" "$W44/err" && [ ! -e "$W44/fout/float.aiff" ] \
    || { echo "FAIL: float WAV not skipped clearly:"; cat "$W44/err"; exit 1; }

# wav_variant <src.wav> <dst.wav> <kind>: extensible (fmt as WAVE_FORMAT_EXTENSIBLE), streamed
# (data size 0xFFFFFFFF), short (header claims more data than there is), info (LIST/INFO tags),
# id3 (an ID3v2.4 chunk with UTF-8 text, a TXXX and a picture), both (ID3 title only + full INFO).
wav_variant() {
python3 -I - "$@" <<'PY'
import sys, struct
src, dst, kind = sys.argv[1:4]
d = open(src, 'rb').read()
chunks, i = [], 12
while i < len(d):
    cid, n = d[i:i+4], struct.unpack('<I', d[i+4:i+8])[0]
    chunks.append([cid, d[i+8:i+8+n]]); i += 8 + n + (n & 1)
def chunk(cid, body): return cid + struct.pack('<I', len(body)) + body + (b'\0' if len(body) & 1 else b'')
def info(title=True):
    items = ([(b'INAM', 'Song Title')] if title else []) + [(b'IART', 'Some Artist'), (b'IPRD', 'Album 蒸發')]
    return chunk(b'LIST', b'INFO' + b''.join(chunk(k, v.encode() + b'\0') for k, v in items))
def id3(full=True):
    def frame(fid, body):
        n = len(body); return fid + bytes([n >> 21 & 127, n >> 14 & 127, n >> 7 & 127, n & 127]) + b'\0\0' + body
    fr = frame(b'TIT2', b'\x03Song Title')
    if full:
        fr += frame(b'TPE1', b'\x03Some Artist') + frame(b'TALB', b'\x03' + 'Album 蒸發'.encode())
        fr += frame(b'TXXX', b'\x03MOOD\0calm') + frame(b'TDRC', b'\x032026-03-01')
        fr += frame(b'APIC', b'\x03image/jpeg\0\x03\0' + bytes.fromhex('ffd8ffe000104a46494600010100000100010000ffd9'))
    n = len(fr)
    return chunk(b'id3 ', b'ID3\x04\0\0' + bytes([n >> 21 & 127, n >> 14 & 127, n >> 7 & 127, n & 127]) + fr)
out = b''
for cid, body in chunks:
    if cid == b'fmt ' and kind == 'extensible':
        tag, ch, rate, brate, align, bits = struct.unpack('<HHIIHH', body[:16])
        guid = struct.pack('<H', tag) + bytes.fromhex('000000001000800000aa00389b71')
        body = struct.pack('<HHIIHH', 0xFFFE, ch, rate, brate, align, bits) + struct.pack('<HHI', 22, bits, 3) + guid
    if cid == b'data' and kind == 'streamed':
        out += b'data' + struct.pack('<I', 0xFFFFFFFF) + body; continue
    if cid == b'data' and kind == 'short':
        out += b'data' + struct.pack('<I', len(body)) + body[:len(body) // 2]; continue
    out += chunk(cid, body)
if kind == 'info': out += info()
if kind == 'id3': out += id3()
if kind == 'both': out += id3(full=False) + info(title=False)
open(dst, 'wb').write(b'RIFF' + struct.pack('<I', 4 + len(out)) + b'WAVE' + out)
PY
}
for k in extensible streamed info id3 both; do wav_variant "$W44/in/LEI24.wav" "$W44/$k.wav" "$k"; done
for k in extensible streamed; do
    [ "$("$BIN" --convert "$W44/$k.wav" "$W44/vout")" = "OK $W44/vout/$k.aiff${TAB}verified" ] || { echo "FAIL: $k WAV not verified"; exit 1; }
done
for k in info id3 both; do
    [ "$("$BIN" --convert "$W44/$k.wav" "$W44/tout")" = "OK $W44/tout/$k.aiff${TAB}verified" ] || { echo "FAIL: tagged ($k) WAV not verified"; exit 1; }
    check_tags "$W44/tout/$k.aiff" || { echo "FAIL: $k WAV's tags didn't carry over"; exit 1; }
done
python3 -I - "$W44/tout/id3.aiff" <<'PY' || { echo "FAIL: the ID3v2.4 picture, TXXX or date didn't carry over"; exit 1; }
import sys
d = open(sys.argv[1], 'rb').read()
assert b'APIC' in d and 'MOOD'.encode('utf-16-le') in d and 'calm'.encode('utf-16-le') in d and '2026'.encode('utf-16-le') in d
PY
wav_variant "$W44/in/LEI24.wav" "$W44/short.wav" short
set +e; "$BIN" --convert "$W44/short.wav" "$W44/sout" >/dev/null 2>"$W44/err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "WAV is incomplete" "$W44/err" || { echo "FAIL: truncated WAV not refused:"; cat "$W44/err"; exit 1; }

# A folder with x.flac and x.wav: the first converts, the second can't take its name.
mkdir -p "$W44/mixed"; cp "$TMP/hr96.flac" "$W44/mixed/x.flac"; cp "$W44/in/LEI16.wav" "$W44/mixed/x.wav"
set +e; "$BIN" --convert "$W44/mixed" "$W44/mout" >"$W44/mixed.out" 2>"$W44/err"; set -e
grep -q "^OK $W44/mout/mixed/x.aiff" "$W44/mixed.out" && grep -q "x.wav: x.aiff already exists, made from a different file" "$W44/err" \
    || { echo "FAIL: x.flac + x.wav not handled:"; cat "$W44/mixed.out" "$W44/err"; exit 1; }

# The watch folder takes WAVs too.
W44W="$TMP/w44watch"; mkdir -p "$W44W"
"$BIN" --watch "$W44W" "$W44/wout" > "$W44/watch.log" 2>&1 &
WATCHER=$!
wait_log "$W44/watch.log" '^WATCHING ' || { echo "FAIL: --watch never reported it was ready"; exit 1; }
cp "$W44/in/LEI16.wav" "$W44W/dl.wav"
wait_log "$W44/watch.log" "^OK $W44/wout/dl.aiff${TAB}verified" || { echo "FAIL: watched WAV not converted"; cat "$W44/watch.log"; exit 1; }
kill $WATCHER 2>/dev/null || true; wait $WATCHER 2>/dev/null || true

echo "45. ALAC input: converts with its iTunes tags, checked for length and format; AAC is skipped…"
A45="$TMP/a45"; mkdir -p "$A45"
afconvert -f AIFF -d BEI16 "$TMP/tone.aiff" "$A45/t16.aiff"
afconvert -f m4af -d alac "$A45/t16.aiff" "$A45/a16.m4a"
afconvert -f m4af -d alac "$TMP/tone.aiff" "$A45/a24.m4a"
afconvert -f m4af -d aac "$TMP/tone.aiff" "$A45/aac.m4a"
# tag_m4a <src.m4a> <dst.m4a> [older]: add iTunes tags, growing moov into the free atom afconvert
# leaves after it. "older" adds what older iTunes writes: gnre (a numbered genre), grouping, cpil.
tag_m4a() {
python3 -I - "$1" "$2" "${3:-}" <<'PY'
import sys, struct
d = bytearray(open(sys.argv[1], 'rb').read())
def atom(t, body): return struct.pack('>I', 8 + len(body)) + t + body
def data(kind, value): return atom(b'data', struct.pack('>II', kind, 0) + value)
c = lambda s: ('©' + s).encode('latin1')
items = (atom(c('nam'), data(1, b'Song Title')) + atom(c('ART'), data(1, b'Some Artist'))
         + atom(c('alb'), data(1, 'Album 蒸發'.encode())) + atom(b'aART', data(1, b'VA'))
         + atom(b'trkn', data(0, struct.pack('>HHHH', 0, 3, 12, 0))) + atom(b'tmpo', data(21, struct.pack('>H', 128)))
         + atom(c('day'), data(1, b'2026-03-01'))
         + atom(b'----', atom(b'mean', b'\0\0\0\0com.apple.iTunes') + atom(b'name', b'\0\0\0\0INITIALKEY') + data(1, b'Am'))
         + atom(b'covr', data(13, bytes.fromhex('ffd8ffe000104a46494600010100000100010000ffd9'))))
if sys.argv[3] == 'older':
    items += atom(b'gnre', data(0, struct.pack('>H', 9))) + atom(c('grp'), data(1, b'Peak Time')) + atom(b'cpil', data(21, b'\x01'))
def find(t, start, end):
    i = start
    while i + 8 <= end:
        n = struct.unpack('>I', d[i:i+4])[0]
        if d[i+4:i+8] == t: return i, n
        i += n
    raise SystemExit('test setup: no ' + t.decode('latin1') + ' atom')
moov, mn = find(b'moov', 0, len(d)); udta, un = find(b'udta', moov + 8, moov + mn)
meta, men = find(b'meta', udta + 8, udta + un); ilst, iln = find(b'ilst', meta + 12, meta + men)
free, fn = find(b'free', moov + mn, len(d))
assert free == moov + mn and fn - 8 >= len(items), 'test setup: no room after moov'
for at in (moov, udta, meta, ilst): d[at:at+4] = struct.pack('>I', struct.unpack('>I', d[at:at+4])[0] + len(items))
d[ilst + iln:ilst + iln] = items
f = free + len(items); d[f:f+4] = struct.pack('>I', fn - len(items)); del d[f + fn - len(items):f + fn]
open(sys.argv[2], 'wb').write(d)
PY
}
tag_m4a "$A45/a24.m4a" "$A45/tagged.m4a" || { echo "FAIL: test setup: couldn't tag the ALAC file"; exit 1; }
[ "$("$BIN" --convert "$A45/a16.m4a" "$A45/out")" = "OK $A45/out/a16.aiff${TAB}format checked" ] || { echo "FAIL: 16-bit ALAC not converted"; exit 1; }
[ "$("$BIN" --convert "$A45/a24.m4a" "$A45/out")" = "OK $A45/out/a24.aiff${TAB}format checked" ] || { echo "FAIL: 24-bit ALAC not converted"; exit 1; }
fmt "$A45/out/a16.aiff" | grep -q "16-bit" && fmt "$A45/out/a24.aiff" | grep -q "24-bit" || { echo "FAIL: ALAC depth not matched"; exit 1; }
[ "$(frames "$A45/out/a24.aiff")" = "$(frames "$TMP/tone.aiff")" ] || { echo "FAIL: ALAC length changed"; exit 1; }
[ "$("$BIN" --convert "$A45/tagged.m4a" "$A45/out")" = "OK $A45/out/tagged.aiff${TAB}tags verified" ] || { echo "FAIL: tagged ALAC not 'tags verified'"; exit 1; }
check_tags "$A45/out/tagged.aiff" || { echo "FAIL: ALAC tags didn't carry over"; exit 1; }
python3 -I - "$A45/out/tagged.aiff" <<'PY' || { echo "FAIL: ALAC track, BPM, key, year, album artist or artwork didn't carry over, or player data leaked"; exit 1; }
import sys
d = open(sys.argv[1], 'rb').read()
u = lambda s: s.encode('utf-16-le')
assert all(x in d for x in [u('3/12'), u('128'), u('Am'), u('2026'), u('VA'), b'APIC']), 'missing'
assert u('iTunSMPB') not in d and u('ITUNSMPB') not in d, 'iTunSMPB copied'
PY
set +e; "$BIN" --convert "$A45/aac.m4a" "$A45/aout" >/dev/null 2>"$A45/err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "this .m4a is AAC, which is lossy" "$A45/err" && [ ! -e "$A45/aout/aac.aiff" ] \
    || { echo "FAIL: AAC not skipped clearly:"; cat "$A45/err"; exit 1; }
head -c 30000 "$A45/a24.m4a" > "$A45/short.m4a"
set +e; "$BIN" --convert "$A45/short.m4a" "$A45/sout" >/dev/null 2>"$A45/err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "Couldn't read this ALAC file" "$A45/err" && ! ls -A "$A45/sout" 2>/dev/null | grep -q . \
    || { echo "FAIL: cut-off ALAC not refused clearly:"; cat "$A45/err"; exit 1; }

echo "46. Player presets: rates capped per player; --skip-playable leaves playable files alone…"
P46="$TMP/p46"; mkdir -p "$P46/in"
afconvert -f AIFF -d BEI24@192000 "$TMP/hr96.aiff" "$P46/hr192.aiff"
afconvert -f AIFF -d BEI24@176400 "$TMP/hr88.aiff" "$P46/hr176.aiff"
for f in hr192 hr176; do afconvert -f flac -d flac "$P46/$f.aiff" "$P46/in/$f.flac"; done
cp "$TMP/hr96.flac" "$TMP/t16.flac" "$P46/in/"
"$BIN" --convert --player cdj-3000 "$P46/in" "$P46/c3" >/dev/null
fmt "$P46/c3/in/hr192.aiff" | grep -q "96000 Hz.*24-bit" && fmt "$P46/c3/in/hr176.aiff" | grep -q "88200 Hz.*24-bit" \
    && fmt "$P46/c3/in/hr96.aiff" | grep -q "96000 Hz.*24-bit" && fmt "$P46/c3/in/t16.aiff" | grep -q "44100 Hz.*16-bit" \
    || { echo "FAIL: CDJ-3000 preset: 192 → 96, 176.4 → 88.2, 96 and 44.1 kept"; for f in "$P46"/c3/in/*.aiff; do fmt "$f"; done; exit 1; }
"$BIN" --convert --player cdj-2000nxs "$P46/in/hr192.flac" "$P46/n" >/dev/null
fmt "$P46/n/hr192.aiff" | grep -q "48000 Hz.*24-bit" || { echo "FAIL: CDJ-2000NXS preset: 192 kHz not → 48 kHz"; exit 1; }
[ "$("$BIN" --convert --format max96 "$P46/in/hr96.flac" "$P46/m96")" = "OK $P46/m96/hr96.aiff${TAB}verified" ] || { echo "FAIL: max96 kept 96 kHz losslessly"; exit 1; }

# --skip-playable: the CDJ-3000 plays 44.1 and 96 kHz FLAC as is, not 192 kHz.
OUT46="$("$BIN" --convert --player cdj-3000 --skip-playable "$P46/in" "$P46/skip")"
grep -q "^KEEP hr96.flac${TAB}Plays as is on the CDJ-3000 / CDJ-3000X" <<<"$OUT46" && grep -q "^KEEP t16.flac" <<<"$OUT46" \
    && grep -q "^OK $P46/skip/in/hr192.aiff" <<<"$OUT46" && [ ! -e "$P46/skip/in/hr96.aiff" ] \
    || { echo "FAIL: --skip-playable on the CDJ-3000:"; echo "$OUT46"; exit 1; }
# The CDJ-2000NXS plays WAV but not FLAC; the XDJ-RX3 plays FLAC but not ALAC.
afconvert -f WAVE -d LEI16 "$TMP/t16.aiff" "$P46/t16.wav"
afconvert -f m4af -d alac "$TMP/t16.aiff" "$P46/t16.m4a"
[ "$("$BIN" --convert --player cdj-2000nxs --skip-playable "$P46/t16.wav" "$P46/x")" = "KEEP t16.wav${TAB}Plays as is on the CDJ-2000NXS / CDJ-900NXS / XDJ-1000 / XDJ-700 — left where it is, not copied to Save to" ] \
    || { echo "FAIL: 16-bit WAV not left alone for the CDJ-2000NXS"; exit 1; }
"$BIN" --convert --player cdj-2000nxs --skip-playable "$P46/in/t16.flac" "$P46/x" | grep -q "^OK " || { echo "FAIL: FLAC not converted for the CDJ-2000NXS"; exit 1; }
"$BIN" --convert --player xdj-rx3 --skip-playable "$P46/t16.m4a" "$P46/y" | grep -q "^OK " || { echo "FAIL: ALAC not converted for the XDJ-RX3"; exit 1; }
for bad in "--player bogus" "--player cd --skip-playable"; do
    set +e; "$BIN" --convert $bad "$P46/t16.wav" "$P46/x" 2>/dev/null; RC=$?; set -e
    [ "$RC" -eq 2 ] || { echo "FAIL: '$bad' should exit 2, got $RC"; exit 1; }
done

echo "47. USB check: lists the tracks a player won't play and sticks it can't read; changes nothing…"
U47="$TMP/u47"; mkdir -p "$U47/one"
hdiutil create -quiet -size 40m -fs MS-DOS -volname FTA_FAT "$U47/fat.dmg"
FAT="$U47/fat"; mkdir "$FAT"
hdiutil attach -quiet -nobrowse -mountpoint "$FAT" "$U47/fat.dmg"
trap 'kill $WATCHER 2>/dev/null || true; hdiutil detach -quiet -force "$FAT" 2>/dev/null || true; hdiutil detach -quiet -force "$EXFAT" 2>/dev/null || true; rm -rf "$TMP"' EXIT
T47="$FAT/Contents/Artist"; mkdir -p "$T47" "$FAT/PIONEER"
cp "$TMP/t16.flac" "$T47/a16.flac"; cp "$TMP/hr96.flac" "$T47/hr96.flac"; cp "$P46/in/hr192.flac" "$T47/hr192.flac"
cp "$P46/t16.wav" "$T47/w16.wav"; cp "$W44/float.wav" "$T47/float.wav"
cp "$A45/a16.m4a" "$T47/alac.m4a"; cp "$A45/aac.m4a" "$T47/aac.m4a"; cp "$TMP/hr96.aiff" "$T47/hr96.aiff"
echo x > "$T47/x.ogg"; echo x > "$FAT/PIONEER/export.pdb"; echo x > "$T47/cover.jpg"
BEFORE47="$(cd "$FAT" && find . -type f -exec md5 -r {} + | sort)"
set +e; "$BIN" --check --player cdj-2000nxs "$FAT" >"$U47/nxs.out" 2>"$U47/nxs.err"; RC=$?; set -e
NXS="CDJ-2000NXS / CDJ-900NXS / XDJ-1000 / XDJ-700"
[ "$RC" -eq 1 ] \
    && grep -qF "ERROR Contents/Artist/a16.flac: FLAC — the $NXS doesn't play FLAC" "$U47/nxs.err" \
    && grep -qF "ERROR Contents/Artist/hr96.aiff: 96 kHz — the $NXS plays 44.1 kHz and 48 kHz" "$U47/nxs.err" \
    && grep -qF "ERROR Contents/Artist/float.wav: Floating-point or compressed WAV" "$U47/nxs.err" \
    && grep -qF "ERROR Contents/Artist/alac.m4a: ALAC — the $NXS doesn't play ALAC" "$U47/nxs.err" \
    && grep -qF "ERROR Contents/Artist/x.ogg: OGG — the $NXS doesn't play this format" "$U47/nxs.err" \
    && ! grep -q "w16.wav\|aac.m4a\|cover.jpg\|PIONEER" "$U47/nxs.err" \
    && grep -qF "NOTE fat: 2 of 9 tracks play on the $NXS." "$U47/nxs.out" \
    || { echo "FAIL: USB check for the CDJ-2000NXS (exit $RC):"; cat "$U47/nxs.out" "$U47/nxs.err"; exit 1; }
set +e; "$BIN" --check --player cdj-3000 "$FAT" >"$U47/c3.out" 2>"$U47/c3.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && [ "$(wc -l < "$U47/c3.err" | tr -d ' ')" = 3 ] \
    && grep -qF "ERROR Contents/Artist/hr192.flac: 192 kHz — the CDJ-3000 / CDJ-3000X plays 44.1 kHz, 48 kHz, 88.2 kHz and 96 kHz" "$U47/c3.err" \
    && grep -qF "NOTE fat: 6 of 9 tracks play on the CDJ-3000 / CDJ-3000X." "$U47/c3.out" \
    || { echo "FAIL: USB check for the CDJ-3000 (exit $RC):"; cat "$U47/c3.out" "$U47/c3.err"; exit 1; }
[ "$(cd "$FAT" && find . -type f -exec md5 -r {} + | sort)" = "$BEFORE47" ] || { echo "FAIL: the USB check changed the stick"; exit 1; }
# Everything plays: exit 0. An APFS folder can't be read by any player; exFAT gets a note.
cp "$P46/t16.wav" "$U47/one/"
mkdir -p "$FAT/one"; cp "$P46/t16.wav" "$FAT/one/"
[ "$("$BIN" --check --player cdj-3000 "$FAT/one")" = "NOTE one: The track plays on the CDJ-3000 / CDJ-3000X" ] || { echo "FAIL: a playable stick should pass"; exit 1; }
set +e; "$BIN" --check --player cdj-3000 "$U47/one" >/dev/null 2>"$U47/apfs.err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "ERROR one: Formatted as APFS, which DJ players can't read" "$U47/apfs.err" || { echo "FAIL: APFS not reported"; cat "$U47/apfs.err"; exit 1; }
"$BIN" --check --player cdj-3000 "$EXFAT" | grep -q "^NOTE exfat: Formatted as exFAT" || { echo "FAIL: exFAT note missing"; exit 1; }
for bad in "--player original" "--player bogus" "--format cd"; do
    set +e; "$BIN" --check $bad "$FAT" >/dev/null 2>&1; RC=$?; set -e
    [ "$RC" -eq 2 ] || { echo "FAIL: --check $bad should exit 2, got $RC"; exit 1; }
done
hdiutil detach -quiet -force "$FAT" 2>/dev/null || true

echo "48. Same file after a retag, old AIFFs, full drives, 4 GB, .aac on sticks, older iTunes and unsynced ID3 tags…"
R48="$TMP/r48"; mkdir -p "$R48/a" "$R48/b" "$R48/c" "$R48/w"
# An ALAC file whose tags outgrew their padding is the same file; different audio is not.
cp "$A45/a24.m4a" "$R48/a/song.m4a"; cp "$A45/a24.m4a" "$R48/b/song.m4a"; cp "$A45/a16.m4a" "$R48/c/song.m4a"
python3 -I -c "import struct, sys; open(sys.argv[1], 'ab').write(struct.pack('>I', 108) + b'free' + bytes(100))" "$R48/b/song.m4a"
"$BIN" --convert "$R48/a/song.m4a" "$R48/out" >/dev/null
[ "$("$BIN" --convert "$R48/b/song.m4a" "$R48/out")" = "SKIP $R48/out/song.aiff" ] || { echo "FAIL: a retagged ALAC file counted as a different file"; exit 1; }
set +e; "$BIN" --convert "$R48/c/song.m4a" "$R48/out" >/dev/null 2>"$R48/err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "made from a different file" "$R48/err" || { echo "FAIL: different ALAC audio with the same name wasn't refused"; exit 1; }
cp "$W44/in/LEI16.wav" "$R48/w/take.wav"
"$BIN" --convert "$R48/w/take.wav" "$R48/wout" >/dev/null
[ "$("$BIN" --convert "$R48/w/take.wav" "$R48/wout")" = "SKIP $R48/wout/take.aiff" ] || { echo "FAIL: the same WAV again should SKIP"; exit 1; }

# AIFFs from before 2026-10-26 recorded an ALAC file's size and a WAV's full MD5: they still match.
# set_source <aiff> <value>: rewrite the AIFF's FLACTOAIFF_SOURCE frame, as an older version wrote it.
set_source() {
python3 -I - "$1" "$2" <<'PY'
import sys, struct
path, value = sys.argv[1], sys.argv[2]
d = open(path, 'rb').read(); i = 12
while d[i:i+4] != b'ID3 ': i += 8 + struct.unpack('>I', d[i+4:i+8])[0]; i += i & 1
n = struct.unpack('>I', d[i+4:i+8])[0]; tag = d[i+8:i+8+n]
size = sum((b & 127) << (7 * (3 - k)) for k, b in enumerate(tag[6:10]))
frames, j, out = tag[10:10+size], 0, b''
while j + 10 <= len(frames) and frames[j] != 0:
    fid, fn = frames[j:j+4], struct.unpack('>I', frames[j+4:j+8])[0]; body = frames[j+10:j+10+fn]
    if fid == b'TXXX' and body[1:].startswith('﻿FLACTOAIFF_SOURCE'.encode('utf-16-le')):
        body = b'\x01' + '﻿FLACTOAIFF_SOURCE'.encode('utf-16-le') + b'\0\0' + ('﻿' + value).encode('utf-16-le')
    out += fid + struct.pack('>I', len(body)) + b'\0\0' + body; j += 10 + fn
s = len(out); tag = b'ID3\x03\0\0' + bytes([s >> 21 & 127, s >> 14 & 127, s >> 7 & 127, s & 127]) + out
chunk = b'ID3 ' + struct.pack('>I', len(tag)) + tag + (b'\0' if len(tag) & 1 else b'')
d = d[:i] + chunk
open(path, 'wb').write(d[:4] + struct.pack('>I', len(d) - 8) + d[8:])
PY
}
set_source "$R48/out/song.aiff" "size:$(stat -f %z "$R48/a/song.m4a")"
[ "$("$BIN" --convert "$R48/a/song.m4a" "$R48/out")" = "SKIP $R48/out/song.aiff" ] || { echo "FAIL: an older AIFF recording the ALAC's size didn't match"; exit 1; }
WAVMD5="$(python3 -I -c "
import sys, struct, hashlib
d = open(sys.argv[1], 'rb').read(); i = 12
while d[i:i+4] != b'data': i += 8 + struct.unpack('<I', d[i+4:i+8])[0]
print(hashlib.md5(d[i+8:i+8+struct.unpack('<I', d[i+4:i+8])[0]]).hexdigest())" "$R48/w/take.wav")"
set_source "$R48/wout/take.aiff" "md5:$WAVMD5"
[ "$("$BIN" --convert "$R48/w/take.wav" "$R48/wout")" = "SKIP $R48/wout/take.aiff" ] || { echo "FAIL: an older AIFF recording the WAV's MD5 didn't match"; exit 1; }
set_source "$R48/wout/take.aiff" "md5:00000000000000000000000000000000"
set +e; "$BIN" --convert "$R48/w/take.wav" "$R48/wout" >/dev/null 2>"$R48/err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "made from a different file" "$R48/err" || { echo "FAIL: an older AIFF from another WAV wasn't refused"; exit 1; }

# A full drive is named as the problem, not the ALAC file.
say -o "$R48/long.aiff" --data-format=BEI24@44100 "$(printf 'a longer sentence to make a file of a few megabytes. %.0s' {1..12})"
afconvert -f m4af -d alac "$R48/long.aiff" "$R48/long.m4a"
hdiutil create -quiet -size 2m -fs MS-DOS -volname FTA_FULL "$R48/full.dmg"
FULL="$R48/full"; mkdir "$FULL"; hdiutil attach -quiet -nobrowse -mountpoint "$FULL" "$R48/full.dmg"
set +e; "$BIN" --convert "$R48/long.m4a" "$FULL" >/dev/null 2>"$R48/err"; RC=$?; set -e
hdiutil detach -quiet -force "$FULL" 2>/dev/null || true
[ "$RC" -eq 1 ] && grep -q "The drive is full — there's no room for long.aiff" "$R48/err" && ! grep -q "Couldn't read this ALAC" "$R48/err" \
    || { echo "FAIL: a full drive wasn't reported as full:"; cat "$R48/err"; exit 1; }

# Over 4 GB as AIFF: refused before converting.
cp "$TMP/tone.flac" "$R48/huge.flac"
python3 -I - "$R48/huge.flac" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read()); si = 8   # STREAMINFO body, after "fLaC" and its block header
packed = int.from_bytes(d[si+10:si+18], 'big') & ~((1 << 36) - 1) | (1 << 34)   # 17 billion samples
d[si+10:si+18] = packed.to_bytes(8, 'big'); open(sys.argv[1], 'wb').write(d)
PY
set +e; "$BIN" --convert "$R48/huge.flac" "$R48/hout" >/dev/null 2>"$R48/err"; RC=$?; set -e
[ "$RC" -eq 1 ] && grep -q "Too long for an AIFF file: it would be .* GB, and AIFF files can't be larger than 4 GB" "$R48/err" \
    && ! ls -A "$R48/hout" 2>/dev/null | grep -q . || { echo "FAIL: an over-4 GB AIFF wasn't refused up front:"; cat "$R48/err"; exit 1; }

# The USB check counts .aac and .mp4 files as playable.
mkdir -p "$R48/stick"; afconvert -f adts -d aac "$TMP/tone.aiff" "$R48/stick/a.aac"; afconvert -f mp4f -d aac "$TMP/tone.aiff" "$R48/stick/b.mp4"
STICK48="$("$BIN" --check --player cdj-2000nxs "$R48/stick" 2>/dev/null || true)"   # exit 1: the folder is on APFS
grep -q "^NOTE stick: All 2 tracks play" <<<"$STICK48" || { echo "FAIL: .aac/.mp4 not counted as playable: $STICK48"; exit 1; }

# Older iTunes tags: a numbered genre, grouping and compilation.
tag_m4a "$A45/a24.m4a" "$R48/older.m4a" older
[ "$("$BIN" --convert "$R48/older.m4a" "$R48/tout")" = "OK $R48/tout/older.aiff${TAB}tags verified" ] || { echo "FAIL: older iTunes tags not verified"; exit 1; }
python3 -I - "$R48/tout/older.aiff" <<'PY' || { echo "FAIL: gnre, grouping or compilation didn't carry over"; exit 1; }
import sys
d = open(sys.argv[1], 'rb').read(); u = lambda s: s.encode('utf-16-le')
assert b'TCON' in d and u('Jazz') in d and b'TIT1' in d and u('Peak Time') in d and u('COMPILATION') in d
PY

# A WAV whose ID3v2.3 tag is unsynchronised keeps its tags and picture.
python3 -I - "$W44/in/LEI24.wav" "$R48/unsync.wav" <<'PY'
import sys, struct
d = open(sys.argv[1], 'rb').read()
jpg = bytes.fromhex('ffd8ffe000104a46494600010100000100010000ffd9')
def frame(fid, body): return fid + struct.pack('>I', len(body)) + b'\0\0' + body
fr = (frame(b'TIT2', b'\0Song Title') + frame(b'TPE1', b'\0Some Artist') + frame(b'TALB', b'\x01' + '﻿Album 蒸發'.encode('utf-16-le'))
      + frame(b'APIC', b'\0image/jpeg\0\x03\0' + jpg))
fr = fr.replace(b'\xff', b'\xff\x00')   # unsynchronise: a zero after every FF
n = len(fr); tag = b'ID3\x03\x00\x80' + bytes([n >> 21 & 127, n >> 14 & 127, n >> 7 & 127, n & 127]) + fr
chunk = b'id3 ' + struct.pack('<I', len(tag)) + tag + (b'\0' if len(tag) & 1 else b'')
body = d[12:] + chunk
open(sys.argv[2], 'wb').write(b'RIFF' + struct.pack('<I', 4 + len(body)) + b'WAVE' + body)
PY
[ "$("$BIN" --convert "$R48/unsync.wav" "$R48/uout")" = "OK $R48/uout/unsync.aiff${TAB}verified" ] || { echo "FAIL: unsynced-ID3 WAV not verified"; exit 1; }
check_tags "$R48/uout/unsync.aiff" || { echo "FAIL: unsynced ID3 tags didn't carry over"; exit 1; }
python3 -I -c "import sys; assert bytes.fromhex('ffd8ffe000104a46494600010100000100010000ffd9') in open(sys.argv[1], 'rb').read()" "$R48/uout/unsync.aiff" \
    || { echo "FAIL: the unsynced picture wasn't restored"; exit 1; }

echo "49. Settings and the queue (the app's side, which the command line bypasses)…"
"$HOOKBIN" --selftest "$TMP/tone.flac" >"$TMP/selftest.out" 2>&1 || { echo "FAIL: selftest:"; cat "$TMP/selftest.out"; exit 1; }
grep -q "^SELFTEST passed" "$TMP/selftest.out" || { echo "FAIL: selftest didn't report:"; cat "$TMP/selftest.out"; exit 1; }
# Not by running the app with --selftest: an argument the app doesn't know opens its window.
grep -q "a queued watched file holds catch-up back" "$BIN" && { echo "FAIL: the app itself contains the selftest"; exit 1; }
grep -q "a queued watched file holds catch-up back" "$HOOKBIN" || { echo "FAIL: test setup: the selftest text isn't where this check looks"; exit 1; }

echo "PASS: all checks."
