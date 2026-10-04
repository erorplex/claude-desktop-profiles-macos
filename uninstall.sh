#!/usr/bin/env bash
# Removes the CLI and the menu bar app. Your profile directories are kept; the active one
# stays in ~/Library/Application Support/Claude, so Claude Desktop keeps working as-is.
set -uo pipefail
APP="/Applications/Profiles for Claude.app"
APP_SUPPORT="${CLAUDE_PROFILES_APP_SUPPORT:-$HOME/Library/Application Support}"
PROFILES="$APP_SUPPORT/Claude-profiles"
SCRATCH="$APP_SUPPORT/Claude/scratch-workspaces"
NO_APP="${CLAUDE_PROFILES_NO_APP:-}"   # tests: leave the running apps and /Applications alone

# The active profile's scratch workspaces link into Claude-profiles/shared. Put a real copy
# back first, so Claude keeps them even if Claude-profiles is deleted after uninstalling.
shared="$(cd -P "$PROFILES/shared/scratch-workspaces" 2>/dev/null && pwd)"
if [ -L "$SCRATCH" ] && [ -n "$shared" ] && [ "$(cd -P "$SCRATCH" 2>/dev/null && pwd)" = "$shared" ]; then
  if [ "$NO_APP" != 1 ] && ps -axo comm= | grep -q '/Claude\.app/Contents/MacOS/Claude$'; then
    echo "Quit Claude first, then run ./uninstall.sh again. Nothing was removed."; exit 1
  fi
  tmp="$APP_SUPPORT/Claude/.scratch-workspaces.uninstall"
  rm -rf "$tmp" "$tmp.link"
  if ! ditto "$shared" "$tmp"; then
    rm -rf "$tmp"; echo "Could not copy $shared back into the active profile. Nothing was removed."; exit 1
  fi
  if ! mv "$SCRATCH" "$tmp.link"; then
    rm -rf "$tmp"; echo "Could not replace $SCRATCH. Nothing was removed."; exit 1
  fi
  if ! mv "$tmp" "$SCRATCH"; then
    mv "$tmp.link" "$SCRATCH"; rm -rf "$tmp"; echo "Could not replace $SCRATCH. Nothing was removed."; exit 1
  fi
  rm "$tmp.link"
  echo "Copied the shared scratch workspaces back into the active profile."
elif [ -L "$SCRATCH" ] && [ ! -d "$SCRATCH" ]; then
  echo "$SCRATCH links to a missing folder."
  echo "Restore it from $PROFILES/shared/workspace-backups first, then run ./uninstall.sh again. Nothing was removed."; exit 1
fi

if [ "$NO_APP" != 1 ]; then
  pkill -x ProfilesForClaude 2>/dev/null
  osascript -e 'tell application "System Events" to delete login item "Profiles for Claude"' >/dev/null 2>&1
  rm -rf "$APP"
fi
rm -f "$HOME/.local/bin/claude-profiles"
echo "Removed the CLI and the menu bar app."
echo "Parked profiles are still in: $PROFILES  (delete that folder if you no longer need them)"
echo "Config: $HOME/.config/claude-profiles   Log: $HOME/Library/Logs/claude-profiles.log"
