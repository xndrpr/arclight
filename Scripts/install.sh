#!/bin/zsh
# Builds Arclight and installs it to /Applications so macOS keeps it:
#  - copies with ditto (keeps the signature intact), never on top of a running copy
#  - clears the quarantine flag that makes Gatekeeper say "damaged" / "Move to Trash"
#  - re-signs ad-hoc and verifies, then registers the app with Launch Services
# Usage: Scripts/install.sh            (install to /Applications)
#        DEST=~/Applications Scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${DEST:-/Applications}"

Scripts/bundle.sh
if pgrep -xq arclight && pgrep -fl "$DEST/Arclight.app" >/dev/null; then
  echo "Quit Arclight first (it is running from $DEST)." >&2; exit 1
fi
rm -rf "$DEST/Arclight.app"
ditto dist/Arclight.app "$DEST/Arclight.app"
xattr -cr "$DEST/Arclight.app"
[[ -n "${DEVELOPER_ID:-}" ]] || codesign --force --sign - --timestamp=none "$DEST/Arclight.app"
codesign --verify --strict "$DEST/Arclight.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Arclight.app"
echo "Installed $DEST/Arclight.app"
echo "MCP for AI agents: \"$DEST/Arclight.app/Contents/MacOS/arclight\" mcp"
