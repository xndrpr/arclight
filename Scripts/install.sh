#!/bin/zsh
# Builds Arclight and installs it to /Applications so macOS keeps it:
#  - quits a running editor first (normally, so it saves), then copies with ditto (keeps the signature intact)
#  - clears the quarantine flag that makes Gatekeeper say "damaged" / "Move to Trash"
#  - re-signs ad-hoc and verifies, then registers the app with Launch Services
# Usage: Scripts/install.sh            (install to /Applications)
#        DEST=~/Applications Scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${DEST:-/Applications}"

Scripts/bundle.sh
# Only the editor blocks the install. MCP servers (`arclight mcp`, started by AI agent sessions) keep running the old
# copy until their session restarts, so replacing the app under them is safe.
# A running editor is asked to quit the normal way (it saves the project on close), then the install goes ahead.
editor_running() { pgrep -fl "$DEST/Arclight.app/Contents/MacOS/arclight" | grep -vq " mcp\b"; }
if editor_running; then
  echo "Quitting Arclight (it saves the project)…"
  osascript -e 'tell application id "com.xndrpr.arclight" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do editor_running || break; sleep 0.25; done
  if editor_running; then
    echo "Arclight is still open (a dialog may be waiting). Quit it, then run this again." >&2; exit 1
  fi
fi
rm -rf "$DEST/Arclight.app"
ditto dist/Arclight.app "$DEST/Arclight.app"
xattr -cr "$DEST/Arclight.app"
[[ -n "${DEVELOPER_ID:-}" ]] || codesign --force --sign - --timestamp=none "$DEST/Arclight.app"
codesign --verify --strict "$DEST/Arclight.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Arclight.app"
echo "Installed $DEST/Arclight.app"
echo "MCP for AI agents: \"$DEST/Arclight.app/Contents/MacOS/arclight\" mcp"
