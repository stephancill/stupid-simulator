#!/usr/bin/env bash
# Capture a screenshot of a simulator and OCR it into text + coordinates.
#
# Usage:
#   sim_ocr.sh <udid> [--normalized] [--scale N] [--grep PATTERN] [--out FILE]
#               [--meta] [--regions] [--last FILE]
#
# Main output: one line per recognized element, "<x> <y>  <text>", the centre of the text
# from the top-left: in POINTS by default, or with --normalized as fractions of the screen
# (0 to 1), which is what `stupidsim tap <udid> --x <x> --y <y>` takes. META / REGION lines
# are informational and prefixed; REGION coordinates follow the same choice.
#
# Options:
#   --normalized print x,y as fractions of the screen, ready for `stupidsim tap`.
#   --accurate   use Vision's accurate recognizer. Fast is the default because accurate fails
#                on macOS 27 (e5rtError 13).
#   --scale N    pixels:points divisor (2 for @2x, 3 for @3x). Default: auto. Only changes
#                the units of the coordinates, never what is recognized.
#   --grep P     keep only lines whose text matches P (case-insensitive).
#   --out FILE   also write the raw PNG to FILE.
#   --meta       print "META ..." lines (frame hash, white%, stable file path).
#   --regions    print "REGION x y kind" for non-background pixel clusters (fallback when
#                text is unreadable but a button/panel is visible).
#   --last FILE  only print text not already present in the previous snapshot at FILE,
#                then save the current one there (for "wait for a change" loops).
#   --yes        (accepted, no-op) for forward compatibility.
set -euo pipefail

SELF="$(basename "$0")"
UDID="${1:?usage: $SELF <udid> [opts]}"
shift
SCALE=""
GREP=""
OUT=""
META=0
REGIONS=0
ACCURATE=0
LAST=""
NORMALIZED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scale) SCALE="$2"; shift 2;;
    --grep) GREP="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --last) LAST="$2"; shift 2;;
    --normalized) NORMALIZED=1; shift;;
    --meta) META=1; shift;;
    --regions) REGIONS=1; shift;;
    --accurate) ACCURATE=1; shift;;
    -y) shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
BIN="${OCR_BIN:-${TMPDIR:-/tmp}/stupid-simulator-ocr}"
# Rebuilt when ocr.swift is newer than the binary, so an edited helper is never stale.
if [ ! -x "$BIN" ] || [ "$DIR/ocr.swift" -nt "$BIN" ]; then
  swiftc -O "$DIR/ocr.swift" -o "$BIN"
fi

STABLE="${TMPDIR:-/tmp}/stupid-simulator-ocr-screen-${UDID}.png"
TMP="$(mktemp -d)/screen.png"
xcrun simctl io "$UDID" screenshot "$TMP" >/dev/null 2>&1
cp "$TMP" "$STABLE"
[ -n "$OUT" ] && cp "$TMP" "$OUT"

W=$(sips -g pixelWidth "$TMP" 2>/dev/null | awk '/pixelWidth/{print int($2)}')
H=$(sips -g pixelHeight "$TMP" 2>/dev/null | awk '/pixelHeight/{print int($2)}')
[ -n "$W" ] && [ -n "$H" ] || { echo "could not read the screenshot size" >&2; exit 1; }

# Auto-select scale from pixel width if not given.
if [ -z "$SCALE" ]; then
  if [ "$W" -ge 1000 ]; then SCALE=3; else SCALE=2; fi
fi

# Points to fractions of the screen, for the coordinates on text and REGION lines.
normalize() {
  if [ "$NORMALIZED" = 0 ]; then cat; return; fi
  LC_ALL=C awk -v s="$SCALE" -v w="$W" -v h="$H" '
    /^META / { print; next }
    /^REGION / { printf "REGION %.3f %.3f", $2 * s / w, $3 * s / h; for (i = 4; i <= NF; i++) printf " %s", $i; print ""; next }
    { printf "%.3f %.3f ", $1 * s / w, $2 * s / h; for (i = 3; i <= NF; i++) printf " %s", $i; print "" }
  '
}

curate() { if [ -n "$GREP" ]; then grep -iE "$GREP"; else cat; fi; }

# One OCR pass at a given scale.
ocr_at() {  # scale
  local args=""
  [ "$REGIONS" = 1 ] && args=" --regions"
  [ "$META" = 1 ] && args="$args --meta"
  [ "$ACCURATE" = 1 ] && args="$args --accurate"
  # shellcheck disable=SC2086
  "$BIN" "$TMP" "$1" $args
}

run_ocr() { ocr_at "$SCALE"; }

lastdiff() {
  if [ -z "$LAST" ]; then cat; return; fi
  local prev=""
  [ -f "$LAST" ] && prev="$(cat "$LAST")"
  local ptext="$(printf '%s\n' "$prev" | awk '{ s=""; for(i=3;i<=NF;i++) s=s" "$i; print s }')"
  awk -v p="$ptext" '
    BEGIN { n=split(p, a, "\n"); for(i=1;i<=n;i++) seen[a[i]]=1 }
    { s=""; for(i=3;i<=NF;i++) s=s" "$i; if(!(s in seen)) print; seen[s]=1 }
  '
}

if [ "$META" = 1 ]; then
  printf 'META frame=%s file=%s\n' "$(shasum -a 256 "$TMP" | cut -c1-12)" "$STABLE"
fi

run_ocr | normalize | lastdiff | curate

[ -n "$LAST" ] && cp "$TMP" "$LAST"
exit 0