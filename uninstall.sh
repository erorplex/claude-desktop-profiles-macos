#!/usr/bin/env bash
# Removes the CLI and the menu bar app. Your profile directories are kept; the active one
# stays in ~/Library/Application Support/Claude, so Claude Desktop keeps working as-is.
set -uo pipefail
APP="/Applications/Profiles for Claude.app"
pkill -x ProfilesForClaude 2>/dev/null
osascript -e 'tell application "System Events" to delete login item "Profiles for Claude"' >/dev/null 2>&1
rm -rf "$APP" "$HOME/.local/bin/claude-profiles"
echo "Removed the CLI and the menu bar app."
echo "Parked profiles are still in: $HOME/Library/Application Support/Claude-profiles  (delete that folder if you no longer need them)"
echo "Config: $HOME/.config/claude-profiles   Log: $HOME/Library/Logs/claude-profiles.log"
