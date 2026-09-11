#!/usr/bin/env bash
# Sandbox-Tests für bin/claude-profiles: laufen komplett unter /tmp, fassen die echte App nicht an.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../bin/claude-profiles"
# not under /tmp or /var/folders: the import treats those as throwaway dirs and would skip every fixture
mkdir -p "$HOME/.cache"; T="$(mktemp -d "$HOME/.cache/claude-profiles-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export CLAUDE_PROFILES_APP_SUPPORT="$T/as" CLAUDE_PROFILES_CONFIG="$T/cfg/config.json" \
       CLAUDE_PROFILES_LOG="$T/log" CLAUDE_PROFILES_NO_APP=1 CLAUDE_PROFILES_POLL=0.2 \
       CLAUDE_PROFILES_HOME="$T/home"
mkdir -p "$T/as" "$T/home/.claude/projects"
NOW=$(python3 -c 'import time;print(int(time.time()*1000))')
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "  ok: $*"; }

mk_profile() { # <dir> <acct> <org> <fh> <sd>
  mkdir -p "$1/claude-code-sessions/$2/$3"; echo '{"oauth:tokenCacheV2":"x"}' > "$1/config.json"
  echo "{\"version\":2,\"samples\":[{\"t\":$NOW,\"org\":\"$3\",\"u\":{\"fh\":$4,\"sd\":$5}}]}" > "$1/plan-usage-history.json"
  echo '{"mcpServers":{}}' > "$1/claude_desktop_config.json"; }
mk_session() { # <id> <title> <lastActivity>
  echo "{\"sessionId\":\"local_$1\",\"cliSessionId\":\"cli-$1\",\"cwd\":\"$T/home\",\"originCwd\":\"$T/home\",\"title\":\"$2\",\"lastActivityAt\":$3,\"createdAt\":1,\"model\":\"claude-opus-5\",\"effort\":\"high\",\"permissionMode\":\"default\",\"remoteMcpServersConfig\":[{\"name\":\"Gmail\"}],\"enabledMcpTools\":{\"a\":true},\"bridgeSessionIds\":[\"b1\"],\"isArchived\":false}"; }

LIVE="$T/as/Claude"; P="$T/as/Claude-profiles"
mk_profile "$LIVE" A1 O1 80 60; echo 1 > "$LIVE/.claude-profiles-id"
mk_session s1 "Alpha" 1000 > "$LIVE/claude-code-sessions/A1/O1/local_s1.json"
mk_session s2 "Beta" 2000 > "$LIVE/claude-code-sessions/A1/O1/local_s2.json"
mk_profile "$P/2" A2 O2 10 20; echo 2 > "$P/2/.claude-profiles-id"
mk_session s3 "Gamma" 3000 > "$P/2/claude-code-sessions/A2/O2/local_s3.json"

echo "# status"
"$CLI" | grep -q '● 1' || fail "Profil 1 nicht aktiv"
"$CLI" status --json | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["active"]==1 and len(d["profiles"])==4' && ok "status"

echo "# switch 1 -> 2: Sessions kommen mit, Account-Felder zurückgesetzt"
"$CLI" 2 >/dev/null
[ "$(cat "$LIVE/.claude-profiles-id")" = 2 ] || fail "Wechsel zu 2"
[ -f "$LIVE/claude-code-sessions/A2/O2/local_s1.json" ] || fail "s1 fehlt in Profil 2"
python3 -c "import json;d=json.load(open('$LIVE/claude-code-sessions/A2/O2/local_s1.json'));assert d['remoteMcpServersConfig']==[] and d['bridgeSessionIds']==[] and d['title']=='Alpha'" && ok "switch + sync"

echo "# Änderung + Löschung in 2 propagieren nach 1"
python3 -c "import json;p='$LIVE/claude-code-sessions/A2/O2/local_s1.json';d=json.load(open(p));d['title']='Alpha NEU';d['lastActivityAt']=9000;json.dump(d,open(p,'w'))"
rm "$LIVE/claude-code-sessions/A2/O2/local_s2.json"
"$CLI" 1 >/dev/null
[ ! -f "$LIVE/claude-code-sessions/A1/O1/local_s2.json" ] || fail "s2 sollte in 1 gelöscht sein"
python3 -c "import json;d=json.load(open('$LIVE/claude-code-sessions/A1/O1/local_s1.json'));assert d['title']=='Alpha NEU'" && ok "Update + Löschung propagiert"

echo "# Wechsel in nie benutztes Profil 3: Nach-Sync sobald Index da ist"
( sleep 0.5; mkdir -p "$LIVE/claude-code-sessions/A3/O3"; echo '{"lastKnownAccountUuid":"x"}' > "$LIVE/config.json" ) &
"$CLI" 3 >/dev/null; wait
[ -f "$LIVE/claude-code-sessions/A3/O3/local_s3.json" ] || fail "Nach-Sync in Profil 3"
[ -f "$LIVE/claude_desktop_config.json" ] || fail "MCP-Config nicht übernommen"
ok "Erstlogin-Sync"

echo "# next, label, profiles-Anzahl"
"$CLI" next >/dev/null; [ "$(cat "$LIVE/.claude-profiles-id")" = 1 ] || fail "next sollte zu 1 (nächstes eingeloggtes)"
"$CLI" label 2 "Arbeit" >/dev/null; "$CLI" | grep -q 'Arbeit' || fail "label"
"$CLI" profiles 6 >/dev/null; "$CLI" status --json | python3 -c 'import json,sys;assert len(json.load(sys.stdin)["profiles"])==6'
"$CLI" profiles 4 >/dev/null; ok "next/label/profiles"

echo "# repair"
mv "$LIVE" "$P/1"; "$CLI" repair >/dev/null; [ "$(cat "$LIVE/.claude-profiles-id")" = 1 ] || fail "repair"; ok "repair"

echo "# import: CLI/VS-Code-Transkripte -> Index des aktiven Profils"
PRJ="$T/home/.claude/projects/$(echo "$T/home" | sed 's|[^A-Za-z0-9]|-|g')"; mkdir -p "$PRJ" "$T/home/gone"
mk_transcript() { # <uuid> <cwd> <first-msg> <days-ago> [model]
  local ts_first ts_last; ts_first=$(python3 -c "import datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(days=$4)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")
  ts_last=$(python3 -c "import datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(days=$4,hours=-1)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")
  { echo "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"timestamp\":\"$ts_first\",\"sessionId\":\"$1\"}"
    echo "{\"type\":\"user\",\"isSidechain\":false,\"cwd\":\"$2\",\"entrypoint\":\"claude-vscode\",\"permissionMode\":\"acceptEdits\",\"sessionId\":\"$1\",\"timestamp\":\"$ts_first\",\"message\":{\"role\":\"user\",\"content\":\"<local-command-caveat>Caveat: generated by local commands</local-command-caveat>\"}}"
    echo "{\"type\":\"user\",\"isSidechain\":false,\"cwd\":\"$2\",\"sessionId\":\"$1\",\"timestamp\":\"$ts_first\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$3\"}]}}"
    echo "{\"type\":\"assistant\",\"sessionId\":\"$1\",\"timestamp\":\"$ts_last\",\"message\":{\"role\":\"assistant\",\"model\":\"${5:-claude-sonnet-5}\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
  } > "$PRJ/$1.jsonl"; }
mk_transcript aaaa1111-0000-0000-0000-000000000001 "$T/home" "Bitte den   Login-Bug fixen\nzweite Zeile" 2 claude-opus-5
mk_transcript aaaa1111-0000-0000-0000-000000000002 "$T/home" "Alte Session von früher" 45
mk_transcript aaaa1111-0000-0000-0000-000000000003 "$T/home/gone" "cwd verschwindet gleich" 1; rmdir "$T/home/gone"
mk_transcript cli-s1 "$T/home" "schon in der App" 1                      # cliSessionId existiert bereits -> überspringen
mkdir -p "$T/home/.bot" "$T/tmpwork"
mk_transcript aaaa1111-0000-0000-0000-000000000004 "$T/home/.bot" "Automation im Bot-Ordner" 1     # --exclude
mk_transcript aaaa1111-0000-0000-0000-000000000005 "/private/tmp" "Test in tmp" 1                  # temp -> immer übersprungen
echo '{"type":"summary","summary":"x"}' > "$PRJ/aaaa1111-0000-0000-0000-000000000009.jsonl"   # leer -> überspringen
"$CLI" import --dry-run | tee "$T/dry.txt" | grep -q 'Login-Bug fixen' || fail "dry-run zeigt Titel nicht"
[ "$(ls "$LIVE/claude-code-sessions/A1/O1/" | grep -c local_)" = 2 ] || fail "dry-run hat geschrieben"
"$CLI" import --exclude "$T/home/.bot" > "$T/imp.txt"; cat "$T/imp.txt"
IDX="$LIVE/claude-code-sessions/A1/O1"
[ "$(ls "$IDX" | grep -c local_)" = 4 ] || fail "erwartet 2 alte + 2 importierte Einträge, ist: $(ls "$IDX")"
python3 - "$IDX" <<'PY'
import json,sys,glob,time
idx=sys.argv[1]; by={}
for f in glob.glob(idx+"/local_*.json"):
    d=json.load(open(f)); by[d["cliSessionId"]]=d
a=by["aaaa1111-0000-0000-0000-000000000001"]; b=by["aaaa1111-0000-0000-0000-000000000002"]
assert a["title"]=="Bitte den Login-Bug fixen", a["title"]
assert a["model"]=="claude-opus-5" and a["permissionMode"]=="acceptEdits" and a["isArchived"] is False
assert a["sessionId"].startswith("local_") and a["remoteMcpServersConfig"]==[] and a["bridgeSessionIds"]==[]
assert abs(a["lastActivityAt"]-a["createdAt"]-3600*1000)<5000, (a["lastActivityAt"],a["createdAt"])
assert time.time()*1000-a["createdAt"] > 1.9*86400*1000
assert b["isArchived"] is True, "45 Tage alt -> archiviert"
assert "aaaa1111-0000-0000-0000-000000000003" not in by, "fehlendes cwd darf nicht importiert werden"
assert "aaaa1111-0000-0000-0000-000000000009" not in by
assert "aaaa1111-0000-0000-0000-000000000004" not in by, "--exclude ignoriert"
assert "aaaa1111-0000-0000-0000-000000000005" not in by, "temp-Ordner muss übersprungen werden"
PY
grep -q 'cwd' "$T/imp.txt" || fail "Übersprungene (cwd fehlt) nicht gemeldet"
"$CLI" import --exclude "$T/home/.bot" | grep -q "^0 imported" || fail "zweiter Import muss idempotent sein"
ok "import"

echo "# import-Einträge kommen beim Wechsel mit"
"$CLI" 2 >/dev/null
ls "$LIVE/claude-code-sessions/A2/O2/" | grep -c local_ | grep -q 4 || fail "importierte Sessions nicht synchronisiert"
ok "import + sync"
echo "ALLE TESTS OK"
