# Profiles for Claude Desktop (macOS)

Use several Claude accounts in **one** Claude Desktop app — switch from the menu bar instead of signing out and back in. Your Claude Code sessions (the *Code* tab) follow you to whichever account is active.

> Unofficial. Not affiliated with or endorsed by Anthropic. It works by moving the app's data directory around, so an app update that changes the internal layout may break it — see [Caveats](#caveats).

## Why

Claude Desktop knows exactly one sign-in at a time. If you keep a personal account and a work account (or one per client), every switch means sign out → sign in → lose your place. This tool gives the app *profiles*, the way Chrome and Slack have them:

- **One app in the Dock.** No second copy of Claude, no `--user-data-dir` juggling.
- **Menu bar switcher.** Shows the active profile and its usage; click another profile to switch. The app relaunches in about ten seconds.
- **Code-tab sessions carry over.** Every profile sees the same session list, so you can continue a session under a different account.
- **Import old sessions.** Sessions you started in the Claude Code CLI or the VS Code extension can be added to the app's sidebar.

## Install

Requirements: macOS 13+, [Claude Desktop](https://claude.ai/download), Xcode Command Line Tools (`xcode-select --install`, needed to compile the tiny menu bar app).

```bash
git clone https://github.com/erorplex/claude-desktop-profiles-macos.git
cd claude-desktop-profiles-macos
./install.sh
```

This installs the `claude-profiles` CLI to `~/.local/bin`, builds **Profiles for Claude.app** into `/Applications`, starts it and adds it to your login items. Your current sign-in becomes profile 1.

The app is ad-hoc signed (no Apple developer account involved). If macOS refuses to open it, right-click → *Open* once.

## Use

Click the person icon in the menu bar (top right, next to the clock) and pick a profile:

```
Claude Desktop profile
● Account 1   ·   5 h: 2 %    7 d: 1 %
○ Account 2   ·   5 h: 7 %    7 d: 62 %
○ Account 3   ·   not signed in yet
```

The first time you switch to an empty profile, Claude starts signed out — sign in with the other account and open the *Code* tab once; your sessions are added automatically. From then on the profile stays signed in.

Everything is also available from the terminal:

```bash
claude-profiles                 # status
claude-profiles 2               # switch to profile 2 (or: claude-profiles work)
claude-profiles next            # next signed-in profile
claude-profiles label 2 work    # name a profile
claude-profiles profiles 3      # number of profile slots (default 4)
```

### Import sessions from the CLI or VS Code

```bash
claude-profiles import --dry-run                 # show what would be added
claude-profiles import                           # add them to the active profile
claude-profiles import --archive-older-than 14   # older sessions go to the archive (default: 30 days)
claude-profiles import --exclude ~/some/dir      # skip sessions from a directory (repeatable)
```

Titles come from the first message; sessions whose working directory no longer exists, empty ones, and ones in temp folders are skipped. Running it again adds only new sessions. Restart Claude once if the sidebar does not update.

## How it works

Claude Desktop keeps everything about the signed-in account in `~/Library/Application Support/Claude`. The active profile *is* that directory; every other profile is parked in `~/Library/Application Support/Claude-profiles/<N>`. A switch:

1. quits Claude,
2. renames the active directory into the parking lot and the target directory into place (two renames, sub-second, no copying),
3. syncs the Code-tab session index into the target profile — the newest version of each session wins, sessions you deleted in one profile are removed from the others, and account-bound fields (connectors, remote-control links) are reset,
4. relaunches Claude.

Session transcripts live in `~/.claude/projects` and are shared by all profiles anyway; only the small index entries the app uses for its sidebar are synced. Local MCP servers (`claude_desktop_config.json`) are shared too. Sign-in tokens are never read, copied or touched — the sign-in happens in Claude's own flow.

## Caveats

- **Chats in the Chat tab stay with their account.** They live on Anthropic's servers; only Code-tab sessions carry over.
- **One account at a time.** Switching relaunches the app; a running response is interrupted (the session resumes fine afterwards).
- **Relies on the app's internal layout.** The session index format and `plan-usage-history.json` are not public APIs. If an update changes them, run `claude-profiles repair`, check `~/Library/Logs/claude-profiles.log`, and open an issue.
- **Sign in with one profile at a time.** The browser sign-in returns to the app via a URL callback; make sure only the intended profile is running while you sign in (that is always the case unless you also start Claude with `--user-data-dir` yourself).

## Terms of use

This is for people who own several Claude accounts and want to use them comfortably from one Mac. Anthropic's terms allow multiple accounts but prohibit account sharing, reselling access, and using subscription credentials outside Anthropic's own apps — this tool does none of that, and please don't use it to. Note that advertised usage limits assume ordinary individual use. See Anthropic's [Consumer Terms](https://www.anthropic.com/legal/consumer-terms) and [usage policy](https://code.claude.com/docs/en/legal-and-compliance).

## Uninstall

```bash
./uninstall.sh
```

Removes the CLI and the menu bar app. The active profile stays in place, so Claude keeps working exactly as before. Parked profiles remain in `~/Library/Application Support/Claude-profiles` until you delete that folder.

## Development

```bash
./tests/test_cli.sh     # end-to-end tests in a sandbox; never touches the real app
```

`bin/claude-profiles` is a single Python 3 file with no dependencies; `menubar/main.swift` is the menu bar app.

## License

MIT
