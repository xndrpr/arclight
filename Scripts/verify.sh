#!/bin/zsh
# Behaviour safety net for refactors: rebuilds, retests and reruns every CLI surface, then compares the results with
# a recorded baseline. Exits non-zero on any difference, with a summary at the end.
#
#   Scripts/verify.sh                 run everything, compare with out/baseline
#   Scripts/verify.sh --record        (re)record out/baseline from the current tree
#   Scripts/verify.sh --only render,mcp      run some sections: build test docs validate render snapshot clickprobe mcp
#   Scripts/verify.sh --smoke         no baseline needed (CI): renders every example and runs the MCP session (or the
#                                     sections given with --only), fails on any error or crash, compares nothing
#
# Never opens a window on screen: it uses only `render`, `snapshot` (off-screen) and `clickprobe` (off-screen).
#
# Isolation, so results don't depend on this Mac's state and runs don't touch it:
#   - the off-screen commands keep the editor's settings in a throwaway domain in a temp folder (Pref.store), never
#     in ~/Library/Preferences; the CLI also runs as a copy named `verify-cli`, and a `verify-cli` settings domain
#     that appears during the run anyway is deleted at the end (CFFIXED_USER_HOME doesn't move UserDefaults);
#   - CFFIXED_USER_HOME points at an empty home in the work dir (no user templates, themes, symbols or logs);
#   - agent presence goes to the work dir (ARCLIGHT_PRESENCE_DIR);
#   - examples are copied to fixed paths in the work dir;
#   - snapshots and click probes use Tests/Fixtures/UI.arclight (fixed English content), not the examples.
#
# Tolerances:
#   text (docs, validate, clickprobe, MCP transcript): compared exactly; the MCP serverInfo version is masked.
#   renders, MCP images: a pixel differs if a channel moves by more than 2/255; at most 0.01% of pixels may differ.
#   snapshots: same threshold, no differing pixels allowed. A differing snapshot is retaken up to twice, and
#   recording keeps a capture only when two in a row are identical (layout timing under load).
#   clickprobe: text compared exactly. `clickprobe <project>` (pointer sweep) and `repeat` are not run: their output
#   depends on timing. Grid regions avoid menus and text fields (they hang a probe) and Export (its sheet eats taps).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

RECORD=0
SMOKE=0
ONLY=""
while (( $# )); do
  case "$1" in
    --record) RECORD=1 ;;
    --smoke) SMOKE=1 ;;
    --only) ONLY="$2"; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
(( RECORD && SMOKE )) && { echo "--record and --smoke don't go together"; exit 2; }
# Smoke mode compares nothing, so it runs only the sections whose outputs it can check on their own.
(( SMOKE )) && [[ -z "$ONLY" ]] && ONLY="render,mcp"

BASE="$ROOT/out/baseline"
OUT="$ROOT/out/verify"
(( RECORD )) && OUT="$BASE"
COMPARE=$(( ! RECORD && ! SMOKE ))  # compare with the baseline (neither --record nor --smoke)
WORK="$ROOT/out/verify-work"
TOOLS="$ROOT/.build/verify-tools"
RENDER_TOL=(2 0.0001)
SNAP_TOL=(2 0)
TIMES=(0 1.5 3)

typeset -a FAILURES
START=$SECONDS
section() { print -P "%B== $1%b"; }
want() { [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]]; }
fail() { FAILURES+=("$1"); print -P "%F{red}FAIL%f $1"; }
pass() { print -P "%F{green}ok%f   $1"; }

# Compare one text file with its baseline.
text_compare() {  # <relative path> <label>
  local rel="$1" label="$2"
  if [[ ! -f "$BASE/$rel" ]]; then fail "$label: no baseline ($rel)"; return; fi
  if [[ ! -f "$OUT/$rel" ]]; then fail "$label: not produced ($rel)"; return; fi
  if diff -u "$BASE/$rel" "$OUT/$rel" > "$OUT/diff/${rel//\//__}.diff"; then
    rm -f "$OUT/diff/${rel//\//__}.diff"; pass "$label"
  else
    fail "$label differs: out/verify/diff/${rel//\//__}.diff"
    head -20 "$OUT/diff/${rel//\//__}.diff" | sed 's/^/       /'
  fi
}

# The `verify-cli` settings domain, if something creates it during this run (only then is it removed at the end).
PREFS_FILE="$HOME/Library/Preferences/verify-cli.plist"
PREFS_EXISTED=0; [[ -e "$PREFS_FILE" ]] && PREFS_EXISTED=1
cleanup_prefs() {
  (( PREFS_EXISTED )) && return
  [[ -e "$PREFS_FILE" ]] || return
  defaults delete verify-cli >/dev/null 2>&1; rm -f "$PREFS_FILE"
}

# Run the CLI with an empty home and presence folder.
cli() {
  CFFIXED_USER_HOME="$WORK/home" ARCLIGHT_PRESENCE_DIR="$WORK/presence" "$WORK/bin/verify-cli" "$@"
}

# `cli` with a time limit: off-screen probes hang if a click opens a menu or a modal; kill and report instead.
cli_limited() {  # <seconds> <args…>
  local limit="$1"; shift
  cli "$@" &
  local pid=$! i=0
  while kill -0 $pid 2>/dev/null; do
    (( i++ >= limit * 5 )) && { kill $pid 2>/dev/null; wait $pid 2>/dev/null; print "verify: timed out after ${limit}s (a menu or modal opened?)"; return 124; }
    sleep 0.2
  done
  wait $pid
}

if (( RECORD )); then
  rm -rf "$BASE.tmp"; mkdir -p "$BASE.tmp"
  # Keep anything recorded outside this script (e.g. notes) but replace what we produce.
  [[ -d "$BASE" ]] && for f in "$BASE"/*(N); do [[ "$(basename "$f")" == NOTES* ]] && cp -R "$f" "$BASE.tmp/"; done
  if [[ -z "$ONLY" ]]; then rm -rf "$BASE"; mv "$BASE.tmp" "$BASE"; else rm -rf "$BASE.tmp"; mkdir -p "$BASE"; fi
else
  rm -rf "$OUT"; mkdir -p "$OUT"
fi
mkdir -p "$OUT/diff"
# A killed run says so (instead of ending without a summary) and leaves the settings domain clean.
trap 'print "verify: interrupted, results incomplete: rerun"; cleanup_prefs; exit 130' \
  INT TERM HUP
rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/home" "$WORK/presence" "$WORK/projects"

# Examples, keyed by name without extension.
typeset -a EXAMPLES
for e in Examples/*.arclight(N/); do
  k="${e:t:r}"; EXAMPLES+=("$k")
  cp -R "$e" "$WORK/projects/$k.arclight"
done
proj() { print -r -- "$WORK/projects/$1.arclight"; }
# The editor snapshots and click probes use a fixed fixture, not the examples (which change).
FIXTURE="$ROOT/Tests/Fixtures/UI.arclight"
mkdir -p "$WORK/fixture"; cp -R "$FIXTURE" "$WORK/fixture/UI.arclight"
fixture() { print -r -- "$WORK/fixture/UI.arclight"; }

# ---------------------------------------------------------------- build (always: the other sections need the CLI)
section "build (release, warnings as errors)"
BUILD_PATH="$ROOT/.build/verify-release"
if swift build -c release --scratch-path "$BUILD_PATH" -Xswiftc -warnings-as-errors > "$WORK/build.log" 2>&1; then
  if grep -q "warning:" "$WORK/build.log"; then fail "build: warnings"; grep "warning:" "$WORK/build.log" | head -20
  else pass "release build, no warnings"; fi
else
  fail "release build failed"; grep -E "error:|warning:" "$WORK/build.log" | head -30
  print "verify: cannot continue without a build"; exit 1
fi
BINDIR="$(swift build -c release --scratch-path "$BUILD_PATH" --show-bin-path)"
CLI="$BINDIR/arclight"
[[ -x "$CLI" ]] || { print "verify: no arclight executable in $BINDIR"; exit 1; }
cp "$CLI" "$WORK/bin/verify-cli"
print "     CLI: $CLI"

# Helper tool (image diff, MCP normalisation), rebuilt when its source changes.
mkdir -p "$TOOLS"
if [[ ! -x "$TOOLS/verify-tool" || "$ROOT/Scripts/verify/VerifyTool.swift" -nt "$TOOLS/verify-tool" ]]; then
  swiftc -O -o "$TOOLS/verify-tool" "$ROOT/Scripts/verify/VerifyTool.swift" 2>&1 | grep -v "^$" || true
fi
VT="$TOOLS/verify-tool"

# Compare every PNG under <dir> with the baseline. Missing or extra files fail. TOL_OVERRIDE maps a relative path to
# its own max-fraction (documented per image where it is set).
typeset -A TOL_OVERRIDE
image_compare() {  # <dir> <threshold> <max-fraction> <label>
  local dir="$1" label="$4"
  [[ -d "$BASE/$dir" ]] || { fail "$label: no baseline"; return; }
  local list="$WORK/pairs-${dir//\//_}.txt"; : > "$list"
  for b in "$BASE/$dir"/**/*.(png|jpg)(N.); do
    local rel="${b#$BASE/}"; print -r -- "$rel	$b	$OUT/$rel${TOL_OVERRIDE[$rel]:+	${TOL_OVERRIDE[$rel]}}" >> "$list"
  done
  for c in "$OUT/$dir"/**/*.(png|jpg)(N.); do
    local rel="${c#$OUT/}"; [[ -f "$BASE/$rel" ]] || fail "$label: new image without baseline: $rel"
  done
  if "$VT" imgdiff "$2" "$3" "$OUT/diff" < "$list" > "$WORK/imgdiff-${dir//\//_}.txt"; then
    pass "$label: $(tail -1 "$WORK/imgdiff-${dir//\//_}.txt")"
    grep "^ok " "$WORK/imgdiff-${dir//\//_}.txt" | sed 's/^/       /'
  else
    fail "$label: $(tail -1 "$WORK/imgdiff-${dir//\//_}.txt")"
    grep -v "^images:" "$WORK/imgdiff-${dir//\//_}.txt" | sed 's/^/       /'
  fi
}

# ---------------------------------------------------------------- test
if want test; then
  section "swift test"
  swift test > "$WORK/test.log" 2>&1
  code=$?
  n=$(grep -Eo "Test run with [0-9]+ tests? passed" "$WORK/test.log" | grep -Eo "[0-9]+" | tail -1)
  x=$(grep -Eo "Executed [0-9]+ tests?, with 0 failures" "$WORK/test.log" | grep -Eo "^Executed [0-9]+" | grep -Eo "[0-9]+" | tail -1)
  total=$(( ${n:-0} + ${x:-0} ))
  print "$total" > "$OUT/test-count.txt"
  if (( code != 0 )); then fail "swift test failed (exit $code)"; grep -E "✘|error:|failed" "$WORK/test.log" | head -30
  elif grep -q "warning:" "$WORK/test.log"; then fail "swift test: compiler warnings"; grep "warning:" "$WORK/test.log" | head -20
  elif (( COMPARE )); then
    b=$(cat "$BASE/test-count.txt" 2>/dev/null || print 0)
    if (( total < b )); then fail "test count dropped: $total, baseline $b"; else pass "$total tests passed (baseline $b)"; fi
  else pass "$total tests passed"; fi
fi

# ---------------------------------------------------------------- docs
if want docs; then
  section "docs"
  cli docs > "$OUT/docs.md"
  (( COMPARE )) && text_compare docs.md "scene format reference (arclight docs)"
fi

# ---------------------------------------------------------------- validate
if want validate; then
  section "validate"
  mkdir -p "$OUT/validate"
  for k in $EXAMPLES; do
    cli validate "$(proj $k)" > "$OUT/validate/$k.txt" 2>&1
    print "exit $?" >> "$OUT/validate/$k.txt"
    cli check "$(proj $k)" > "$OUT/validate/$k.check.txt" 2>&1
    print "exit $?" >> "$OUT/validate/$k.check.txt"
  done
  if (( COMPARE )); then
    for b in "$BASE"/validate/*.txt(N); do text_compare "validate/${b:t}" "validate ${b:t:r}"; done
  fi
fi

# ---------------------------------------------------------------- render
if want render; then
  section "golden renders (scale 0.5 at 0, 1.5, 3 s and the last frame)"
  for k in $EXAMPLES; do
    p="$(proj $k)"
    fps=$(cli info "$p" | head -1 | grep -Eo "@ [0-9.]+ fps" | grep -Eo "[0-9.]+")
    [[ -n "$fps" ]] || { fail "render $k: arclight info failed"; continue; }
    scenes=0
    cli info "$p" | tail -n +2 | while read -r id dur _; do
      (( scenes++ ))
      dur="${dur%s}"
      last=$(printf "%.3f" $(( dur - 1.0 / fps )))
      mkdir -p "$OUT/render/$k"
      args=(); names=()
      for t in $TIMES "$last"; do args+=(--time "$t"); names+=("$t"); done
      cli render "$p" --scene "$id" --scale 0.5 $args --out "$WORK/r.png" > "$WORK/render-files.txt" \
        2>> "$WORK/render.log" || fail "render $k/$id failed (exit $?, see out/verify-work/render.log)"
      i=0
      for t in $names; do
        tag="$t"; [[ "$t" == "$last" ]] && tag="end"
        mv "$WORK/r_$i.png" "$OUT/render/$k/$id@$tag.png" 2>/dev/null || fail "render $k/$id@$tag: no image"
        (( i++ ))
      done
    done
    (( scenes )) || fail "render $k: no scenes"
  done
  if (( COMPARE )); then image_compare render $RENDER_TOL "renders"
  elif (( SMOKE )); then
    n=$(print -l "$OUT"/render/**/*.png(N.) | wc -l | tr -d ' ')
    pass "rendered $n images (${#EXAMPLES} examples)"
  fi
fi

# ---------------------------------------------------------------- snapshot
if want snapshot; then
  section "off-screen UI snapshots"
  S="$OUT/snapshot"; mkdir -p "$S"
  E="$(fixture)"
  # name → snapshot arguments (all against the UI fixture)
  typeset -A SNAP
  for size in 1400x900 1100x700; do
    for theme in dark light gruvboxLight; do SNAP[editor-$size-$theme]="--size $size --theme $theme --time 3"; done
  done
  SNAP[panel-settings]="--theme dark --panel settings --size 900x640"
  SNAP[panel-shortcuts]="--theme dark --panel shortcuts --size 900x700"
  SNAP[panel-inspector]="--theme dark --panel inspector --size 340x1000 --select counter --time 3"
  SNAP[panel-timeline]="--theme dark --panel timeline --size 1200x400 --select counter --time 3"
  SNAP[panel-templates]="--theme dark --panel templates --size 980x640"
  SNAP[panel-themepopover]="--theme dark --panel themepopover --size 420x640"
  SNAP[panel-installhelp]="--theme dark --panel installhelp --size 640x560"
  SNAP[setup-ai-agent-editing]="--theme dark --setup ai,agent:editing --size 1400x900 --time 3"
  take() {  # <name> [<out file>]
    cli_limited 60 snapshot "$E" --out "${2:-$S/$1.png}" ${=SNAP[$1]} > /dev/null || fail "snapshot $1"
  }
  # Snapshots wait 1.2 s and then until three drawings in a row are identical (Offscreen.settledDrawing): on a loaded
  # machine thumbnails arrive late and an inspector text field's value has landed 1-2 px lower. Status dots don't
  # pulse in snapshots. Recording still keeps a capture only when two in a row are identical, and a comparison
  # retakes a differing image up to twice before failing.
  same_as() {  # <name> <baseline png> <candidate png> <max fraction>: pixel comparison of one image, quiet
    print -r -- "snapshot/$1.png	$2	$3	$4" | "$VT" imgdiff 2 "$4" "$WORK/snapdiff" > /dev/null
  }
  for n in ${(ok)SNAP}; do
    take $n
    if (( RECORD )); then
      for i in 1 2 3; do
        take $n "$WORK/again.png"
        same_as $n "$S/$n.png" "$WORK/again.png" "${TOL_OVERRIDE[snapshot/$n.png]:-0}" && break
        mv "$WORK/again.png" "$S/$n.png"
        (( i == 3 )) && fail "snapshot $n: no two identical captures in a row"
      done
    elif (( COMPARE )) && [[ -f "$BASE/snapshot/$n.png" ]]; then
      for i in 1 2; do
        same_as $n "$BASE/snapshot/$n.png" "$S/$n.png" "${TOL_OVERRIDE[snapshot/$n.png]:-0}" && break
        print "     retaking $n (differs; attempt $i)"
        take $n
      done
    fi
  done
  (( COMPARE )) && image_compare snapshot $SNAP_TOL "snapshots"
fi

# ---------------------------------------------------------------- clickprobe
if want clickprobe; then
  section "clickprobe"
  C="$OUT/clickprobe"; mkdir -p "$C"
  E="$(fixture)"
  fresh() { rm -rf "$E"; cp -R "$FIXTURE" "$E"; }
  probe() {  # <out file> <clickprobe args…>; output plus exit code, with a watchdog
    local out="$1"; shift
    cli_limited 90 clickprobe "$@" > "$out" 2>&1; print "exit $?" >> "$out"
  }
  probe "$C/buttons.txt"
  probe "$C/scroll.txt" scroll
  # Clickable-area maps (`clickprobe grid`). Only buttons that report to ClickTrace show up (IconButton, tabs, rows).
  # Regions avoid SwiftUI Menus (a click starts a menu-tracking loop that never ends off-screen), text fields
  # (NSTextView's own tracking loop waits for a real mouse-up) and the project/scene names (a click starts a
  # rename field) and the Export button (x from about 1322): a tap that opens a sheet makes the window ignore every
  # later tap in the same process, so a grid reaching Export reports nothing after it.
  fresh; probe "$C/grid-tabs.txt" grid "$E" 44 76 0 208 4
  # The keyboard-shortcuts icon opens a sheet too, so only its first hit in a process means anything: one process per
  # row, which maps the icon's left edge. The settings gear opens nothing off-screen: one grid up to just before Export.
  : > "$C/grid-topbar.txt"
  for y in 2 8 14 20 26 32 38; do
    fresh; probe "$WORK/grid.txt" grid "$E" $y $y 1250 1290 2
    print -r -- "-- y=$y x=1250..1290" >> "$C/grid-topbar.txt"; grep -v "^x from" "$WORK/grid.txt" >> "$C/grid-topbar.txt"
  done
  fresh; probe "$WORK/grid.txt" grid "$E" 2 38 1290 1318 2
  print -r -- "-- y=2..38 x=1290..1318" >> "$C/grid-topbar.txt"; grep -v "^x from" "$WORK/grid.txt" >> "$C/grid-topbar.txt"
  fresh
  if (( COMPARE )); then
    for f in buttons scroll grid-tabs grid-topbar; do text_compare "clickprobe/$f.txt" "clickprobe $f"; done
  fi
fi

# ---------------------------------------------------------------- mcp
if want mcp; then
  section "MCP JSON-RPC transcript"
  before_mcp=${#FAILURES}
  M="$WORK/mcp"; mkdir -p "$M"
  P="$M/Scratch.arclight"
  SVG='<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#e33"/><circle cx="32" cy="32" r="20" fill="#fff"/></svg>'
  SVG_JSON=${SVG//\"/\\\"}
  cat > "$M/requests.jsonl" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"guide","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"project_create","arguments":{"path":"$P","name":"Scratch","size":[640,360],"fps":30}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"scene_create","arguments":{"id":"intro","duration":3,"background":"#101418","nodes":[{"id":"title","type":"text","text":"HELLO","font":"Helvetica-Bold","size":72,"color":"#F2EFE6","x":320,"y":160,"opacity":{"k":[[0,0],[0.6,1,"outCubic"]]}},{"id":"bar","type":"shape","shape":"rect","width":300,"height":12,"fill":"#E8A33D","x":320,"y":230}]}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"scene_apply","arguments":{"scene":"intro","rev":1,"ops":[{"op":"set","id":"title","text":"HELLO WORLD","size":56},{"op":"duplicate","id":"bar","as":"bar2"},{"op":"set","id":"bar2","y":260}]}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"symbol_save","arguments":{"pack":"brand","id":"spark","name":"Spark","path":"M0 -40 L10 -10 L40 0 L10 10 L0 40 L-10 10 L-40 0 L-10 -10 Z"}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"asset_write","arguments":{"name":"badge.png","svg":"$SVG_JSON","width":128}}}
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"scene_apply","arguments":{"scene":"intro","ops":[{"op":"add","node":{"id":"logo","type":"symbol","symbol":"brand/spark","size":60,"x":120,"y":80}},{"op":"add","node":{"id":"badge","type":"image","src":"badge.png","x":540,"y":80,"width":64}}]}}}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"render_frames","arguments":{"scene":"intro","times":[0.3,1.5],"scale":0.5,"save":"$M/sheet.png"}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"export","arguments":{"format":"png","frame":1.5,"out_dir":"$M/exports"}}}
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"project_check","arguments":{}}}
EOF
  cli mcp < "$M/requests.jsonl" > "$M/raw.jsonl" 2> "$M/stderr.txt"
  code=$?
  mkdir -p "$OUT/mcp"
  "$VT" mcpnorm "$WORK" "$OUT/mcp" < "$M/raw.jsonl" > "$OUT/mcp/transcript.txt"
  cp "$M/sheet.png" "$OUT/mcp/sheet.png" 2>/dev/null || fail "mcp: render_frames did not save its sheet"
  cp "$M/exports/intro@1.5s.png" "$OUT/mcp/export-intro@1.5s.png" 2>/dev/null || fail "mcp: export png missing"
  # Files the session wrote into the project (names only; contents are covered by the transcript and images).
  (cd "$P" && find . -type f ! -path "./.history/*" ! -name "activity.jsonl" | sort) > "$OUT/mcp/project-files.txt"
  if (( SMOKE )); then
    # Without a baseline: the server exits cleanly and answers every request, none of them with an error.
    (( code == 0 )) || fail "mcp: server exited with $code (see out/verify-work/mcp/stderr.txt)"
    missing=()
    for id in 1 2 3 4 5 6 7 8 9 10 11 12; do
      grep -q "^  \"id\" : $id,\$" "$OUT/mcp/transcript.txt" || missing+=($id)
    done
    (( ${#missing} )) && fail "mcp: no response to request(s) ${(j:, :)missing}"
    grep -q '^NON-JSON' "$OUT/mcp/transcript.txt" && fail "mcp: output that isn't JSON-RPC"
    grep -Eq '^  "error" :|"isError" : true' "$OUT/mcp/transcript.txt" && {
      fail "mcp: a request returned an error"; grep -E -B2 -A6 '^  "error" :|"isError" : true' "$OUT/mcp/transcript.txt" | head -30
    }
    (( ${#FAILURES} == before_mcp )) && pass "MCP session: 12 requests answered, no errors"
  elif (( COMPARE )); then
    text_compare mcp/transcript.txt "MCP transcript"
    text_compare mcp/project-files.txt "MCP project files"
    image_compare mcp $RENDER_TOL "MCP images"
  fi
fi

cleanup_prefs

# ---------------------------------------------------------------- summary
print
if (( RECORD )); then
  print "baseline recorded in out/baseline ($(( SECONDS - START )) s)"
  (( ${#FAILURES} )) && { print "with failures:"; printf '  - %s\n' $FAILURES; exit 1 }
  exit 0
fi
if (( ${#FAILURES} )); then
  print -P "%F{red}%Bverify: ${#FAILURES} problem(s)%b%f ($(( SECONDS - START )) s)"
  printf '  - %s\n' $FAILURES
  print "outputs: out/verify   diffs: out/verify/diff"
  exit 1
fi
if (( SMOKE )); then print -P "%F{green}%Bverify: smoke test passed (${ONLY})%b%f ($(( SECONDS - START )) s)"
else print -P "%F{green}%Bverify: everything matches the baseline%b%f ($(( SECONDS - START )) s)"; fi
