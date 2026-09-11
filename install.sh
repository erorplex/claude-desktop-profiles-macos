#!/usr/bin/env bash
# Installs the claude-profiles CLI and builds the "Profiles for Claude" menu bar app.
# Requires macOS 13+ and the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
APP="/Applications/Profiles for Claude.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install"; exit 1
fi
[ -d /Applications/Claude.app ] || echo "Note: /Applications/Claude.app not found – install Claude Desktop first."

mkdir -p "$BIN"
install -m 755 "$HERE/bin/claude-profiles" "$BIN/claude-profiles"
echo "CLI installed: $BIN/claude-profiles"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Add $BIN to your PATH, e.g.:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc";; esac

# mark the current Claude data directory as profile 1 (only if not set up yet)
LIVE="$HOME/Library/Application Support/Claude"
if [ -d "$LIVE" ] && [ ! -f "$LIVE/.claude-profiles-id" ]; then
  echo 1 > "$LIVE/.claude-profiles-id"; echo "Current Claude sign-in registered as profile 1."
fi

echo "Building the menu bar app …"
pkill -x ProfilesForClaude 2>/dev/null || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/ProfilesForClaude" "$HERE/menubar/main.swift"
cp "$HERE/menubar/Info.plist" "$APP/Contents/Info.plist"
codesign --force -s - "$APP" >/dev/null 2>&1 || true     # ad-hoc signature (no developer account needed)
open "$APP"
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Profiles for Claude.app", hidden:true}' >/dev/null 2>&1 \
  && echo "Menu bar app installed and set to start at login." || echo "Menu bar app installed (could not add login item – add it under System Settings > General > Login Items)."
echo
echo "Done. Look for the profile icon in the menu bar (top right). Run 'claude-profiles' in a terminal for the status."
