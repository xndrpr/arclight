#!/bin/bash
# Regenerates every README image and the demo clip in docs/assets/ from the example projects, so they never go stale.
#
#   Scripts/screenshots.sh              build the CLI (release) and regenerate everything
#   Scripts/screenshots.sh --only demo  regenerate one group: snapshots, stills, demo
#   Scripts/screenshots.sh --out DIR    write somewhere else than docs/assets (to compare before committing)
#   ARCLIGHT=/path/to/arclight Scripts/screenshots.sh   use an existing binary instead of building
#   DEMO_MP4=1 Scripts/screenshots.sh --only demo        also write demo.mp4 (large; not committed)
#
# Never opens a window on screen: it only runs `arclight snapshot` (off-screen UI), `arclight render` and
# `arclight export`. It runs the CLI with an empty home folder, and the off-screen commands keep the editor's
# settings in a throwaway domain in a temp folder, so your themes, templates and preferences don't leak into the
# images and nothing is written to ~/Library/Preferences.
#
# Edit the lists below to change what is captured. Projects are named without extension and looked up in
# Examples/ as <name>.arclight.
set -euo pipefail

# ------------------------------------------------------------------------------------------------ what to capture

# The project the editor screenshots show by default. --select names a layer in its first scene; --time is in seconds.
EDITOR_PROJECT="spotlight-crowd"
EDITOR_SELECT="counter"
EDITOR_TIME="7"

# Editor UI snapshots: "<output file>|<project, empty for EDITOR_PROJECT>|<snapshot arguments>".
SNAPSHOTS=(
  "hero.jpg||--size 1600x1000 --theme dark --time $EDITOR_TIME --select $EDITOR_SELECT"
  "ai-panel.jpg||--size 1600x1000 --theme dark --time $EDITOR_TIME --setup ai,agent:editing"
  "editor-light.jpg|three-steps-light|--size 1600x1000 --theme light --time 6.4 --select headline"
)
# Snapshots come out at 2x; wider ones are scaled down to this many pixels to keep the repository small.
SNAPSHOT_MAX_WIDTH="1600"

# Rendered frames of the examples, for the README gallery: "<output file>|<project>|<scene id or empty>|<time>".
# An empty scene id means the project's first scene.
STILLS=(
  "example-spotlight-crowd.jpg|spotlight-crowd||7.0"
  "example-kinetic-type.jpg|kinetic-type||6.8"
  "example-data-bars.png|data-bars||6.5"
  "example-social-vertical.jpg|social-vertical||7.4"
  "example-three-steps-light.png|three-steps-light||6.4"
)
STILL_SCALE="0.5"

# Output format follows the file extension: .png stays PNG (flat artwork), .jpg is converted with sips at this
# quality (film grain and 3D scenes compress badly as PNG).
JPEG_QUALITY="88"

# The demo clip: a looping GIF (frames via `arclight render`, assembled with ImageIO) for the README, and optionally
# an MP4 of the same scene (via `arclight export`; off by default because it is large).
DEMO_PROJECT="kinetic-type"
DEMO_SCENE=""          # empty: the first scene
DEMO_GIF_FPS="10"
DEMO_GIF_SCALE="0.28"
DEMO_GIF_MAX_SECONDS="7.2"
DEMO_MP4="${DEMO_MP4:-0}"   # DEMO_MP4=1 Scripts/screenshots.sh --only demo  also writes demo.mp4
DEMO_MP4_SCALE="0.5"

# ------------------------------------------------------------------------------------------------ setup

cd "$(dirname "$0")/.."
ROOT="$PWD"
ASSETS="$ROOT/docs/assets"
WORK="$ROOT/out/screenshots-work"

ONLY=""
while (( $# )); do
  case "$1" in
    --only) ONLY="${2:-}"; shift ;;
    --out) ASSETS="$(mkdir -p "${2:?--out needs a folder}" && cd "$2" && pwd)"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
want() { [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]; }

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/presence" "$WORK/projects" "$ASSETS"

if [[ -n "${ARCLIGHT:-}" ]]; then
  BIN="$ARCLIGHT"
else
  echo "== building the CLI (release)"
  swift build -c release
  BINDIR="$(swift build -c release --show-bin-path)"
  BIN="$BINDIR/arclight"
fi
[[ -x "$BIN" ]] || { echo "screenshots: no CLI at $BIN" >&2; exit 1; }

# A copy under its own name: a `screenshots-cli` settings domain that appears during this run anyway (UserDefaults
# ignore CFFIXED_USER_HOME) is removed on exit. One that existed before is left alone.
cp "$BIN" "$WORK/bin/screenshots-cli"
PREFS_FILE="$HOME/Library/Preferences/screenshots-cli.plist"
PREFS_EXISTED=0; [[ -e "$PREFS_FILE" ]] && PREFS_EXISTED=1
cleanup_prefs() {
  [[ $PREFS_EXISTED == 1 || ! -e "$PREFS_FILE" ]] && return
  defaults delete screenshots-cli >/dev/null 2>&1 || true
  rm -f "$PREFS_FILE"
}
trap cleanup_prefs EXIT

# Only the off-screen commands are allowed through, so nothing here can open the editor window.
cli() {
  case "$1" in
    snapshot|render|export|info) ;;
    *) echo "screenshots: refusing to run '$1' (only snapshot, render, export and info)" >&2; exit 1 ;;
  esac
  CFFIXED_USER_HOME="$WORK/home" ARCLIGHT_PRESENCE_DIR="$WORK/presence" \
    "$WORK/bin/screenshots-cli" "$@"
}

# Copies an example to the work folder (so renders never touch Examples/) and prints its path.
project() {
  local name="$1" src="Examples/$1.arclight"
  [[ -d "$src" ]] || { echo "screenshots: no example named '$name' in Examples/" >&2; exit 1; }
  local dst="$WORK/projects/${src##*/}"
  [[ -d "$dst" ]] || cp -R "$src" "$dst"
  printf '%s\n' "$dst"
}

# Scene ids and durations from `arclight info`: lines "  <id>  <seconds>s  …" after the header.
first_scene() { cli info "$1" | sed -n '2p' | awk '{print $1}'; }
scene_duration() {
  cli info "$1" | awk -v id="$2" 'NR > 1 && $1 == id { sub(/s$/, "", $2); print $2 }'
}

written=()
wrote() { written+=("$1"); echo "   $1"; }

# Moves a rendered PNG to its final name: scaled down to max width $3 (if given), JPEG when the name ends in .jpg.
finish() {
  local src="$1" dst="$2" max="${3:-}" width
  if [[ -n "$max" ]]; then
    width="$(sips -g pixelWidth "$src" | awk '/pixelWidth/ { print $2 }')"
    (( width > max )) && sips --resampleWidth "$max" "$src" > /dev/null
  fi
  case "$dst" in
    *.jpg) sips -s format jpeg -s formatOptions "$JPEG_QUALITY" "$src" --out "$dst" > /dev/null; rm -f "$src" ;;
    *) mv "$src" "$dst" ;;
  esac
  wrote "$dst"
}

# ------------------------------------------------------------------------------------------------ snapshots

if want snapshots; then
  echo "== editor snapshots"
  for entry in "${SNAPSHOTS[@]}"; do
    IFS='|' read -r file name rest <<< "$entry"
    p="$(project "${name:-$EDITOR_PROJECT}")"
    read -r -a args <<< "$rest"
    cli snapshot "$p" --out "$WORK/snapshot.png" "${args[@]}" > /dev/null
    finish "$WORK/snapshot.png" "$ASSETS/$file" "$SNAPSHOT_MAX_WIDTH"
  done
fi

# ------------------------------------------------------------------------------------------------ stills

if want stills; then
  echo "== example stills"
  for entry in "${STILLS[@]}"; do
    IFS='|' read -r file name scene time <<< "$entry"
    p="$(project "$name")"
    [[ -n "$scene" ]] || scene="$(first_scene "$p")"
    cli render "$p" --scene "$scene" --time "$time" --scale "$STILL_SCALE" --out "$WORK/still.png" \
      > /dev/null 2> "$WORK/render.log" || { cat "$WORK/render.log" >&2; exit 1; }
    finish "$WORK/still.png" "$ASSETS/$file"
  done
fi

# ------------------------------------------------------------------------------------------------ demo

if want demo; then
  echo "== demo clip"
  p="$(project "$DEMO_PROJECT")"
  scene="${DEMO_SCENE:-$(first_scene "$p")}"

  if [[ "$DEMO_MP4" == 1 ]]; then
    cli export "$p" --scene "$scene" --format mp4 --scale "$DEMO_MP4_SCALE" --out "$WORK/export" > /dev/null \
      2> "$WORK/export.log" || { cat "$WORK/export.log" >&2; exit 1; }
    mv "$WORK/export/$scene.mp4" "$ASSETS/demo.mp4"
    wrote "$ASSETS/demo.mp4"
  fi

  # GIF: render the frames in one process, then assemble them with ImageIO (no third-party tools).
  duration="$(scene_duration "$p" "$scene")"
  [[ -n "$duration" ]] || { echo "screenshots: no duration for scene '$scene'" >&2; exit 1; }
  times=()
  while IFS= read -r t; do times+=(--time "$t"); done < <(
    awk -v d="$duration" -v m="$DEMO_GIF_MAX_SECONDS" -v f="$DEMO_GIF_FPS" \
      'BEGIN { if (d > m) d = m; n = int(d * f); for (i = 0; i < n; i++) printf "%.4f\n", i / f }'
  )
  mkdir -p "$WORK/frames"
  cli render "$p" --scene "$scene" --scale "$DEMO_GIF_SCALE" "${times[@]}" --out "$WORK/frames/f.png" \
    > "$WORK/frames/list.txt" 2> "$WORK/render.log" || { cat "$WORK/render.log" >&2; exit 1; }

  cat > "$WORK/gif.swift" <<'SWIFT'
import Foundation
import ImageIO
import UniformTypeIdentifiers

// usage: gif <fps> <out.gif> < list of PNG paths
let args = CommandLine.arguments
let delay = 1.0 / (Double(args[1]) ?? 15)
var paths: [String] = []
while let line = readLine() { if !line.isEmpty { paths.append(line) } }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.gif.identifier as CFString, paths.count, nil) else { exit(1) }
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
for p in paths {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, img, frame)
}
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
SWIFT
  swiftc -O -o "$WORK/gif" "$WORK/gif.swift"
  "$WORK/gif" "$DEMO_GIF_FPS" "$ASSETS/demo.gif" < "$WORK/frames/list.txt"
  wrote "$ASSETS/demo.gif"
fi

echo
echo "screenshots: ${#written[@]} file(s) in ${ASSETS#"$ROOT"/}"
for f in ${written[@]+"${written[@]}"}; do du -h "$f" | awk -v f="${f#"$ROOT"/}" '{ printf "   %-28s %s\n", f, $1 }'; done
