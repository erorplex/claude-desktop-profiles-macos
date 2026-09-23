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

echo "# status (Standard: 2 Slots)"
"$CLI" | grep -q '● 1' || fail "Profil 1 nicht aktiv"
"$CLI" status --json | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["active"]==1 and len(d["profiles"])==2' || fail "status"; ok "status"
"$CLI" profiles 4 >/dev/null

echo "# switch 1 -> 2: Sessions kommen mit, Account-Felder zurückgesetzt"
"$CLI" 2 >/dev/null
[ "$(cat "$LIVE/.claude-profiles-id")" = 2 ] || fail "Wechsel zu 2"
[ -f "$LIVE/claude-code-sessions/A2/O2/local_s1.json" ] || fail "s1 fehlt in Profil 2"
python3 -c "import json;d=json.load(open('$LIVE/claude-code-sessions/A2/O2/local_s1.json'));assert d['remoteMcpServersConfig']==[] and d['bridgeSessionIds']==[] and d['title']=='Alpha'" || fail "switch + sync"; ok "switch + sync"

echo "# Änderung + Löschung in 2 propagieren nach 1"
python3 -c "import json;p='$LIVE/claude-code-sessions/A2/O2/local_s1.json';d=json.load(open(p));d['title']='Alpha NEU';d['lastActivityAt']=9000;json.dump(d,open(p,'w'))"
rm "$LIVE/claude-code-sessions/A2/O2/local_s2.json"
"$CLI" 1 >/dev/null
[ ! -f "$LIVE/claude-code-sessions/A1/O1/local_s2.json" ] || fail "s2 sollte in 1 gelöscht sein"
python3 -c "import json;d=json.load(open('$LIVE/claude-code-sessions/A1/O1/local_s1.json'));assert d['title']=='Alpha NEU'" || fail "Update + Löschung propagiert"; ok "Update + Löschung propagiert"

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

echo "# add: neuer Slot mit Label, add --switch wechselt sofort hinein"
"$CLI" add "Kunde X" | grep -q '5' || fail "add sollte Slot 5 melden"
"$CLI" status --json | python3 -c 'import json,sys;d=json.load(sys.stdin);p=d["profiles"];assert len(p)==5 and p[4]["label"]=="Kunde X" and not p[4]["logged_in"]'
( sleep 0.5; mkdir -p "$LIVE/claude-code-sessions/A6/O6"; echo '{"lastKnownAccountUuid":"x"}' > "$LIVE/config.json" ) &
"$CLI" add --switch >/dev/null; wait
[ "$(cat "$LIVE/.claude-profiles-id")" = 6 ] || fail "add --switch sollte zu Slot 6 wechseln"
[ -f "$LIVE/claude-code-sessions/A6/O6/local_s3.json" ] || fail "Sessions nicht in neues Profil synchronisiert"
ok "add"

echo "# remove: aktives Profil verweigern, geparktes löschen, letzten Slot einkürzen"
"$CLI" remove 6 --yes >/dev/null 2>&1 && fail "remove des aktiven Profils muss scheitern"
"$CLI" 1 >/dev/null
"$CLI" remove 6 --yes >/dev/null; [ ! -d "$P/6" ] || fail "Profil 6 nicht gelöscht"
"$CLI" status --json | python3 -c 'import json,sys;p=json.load(sys.stdin)["profiles"];assert len(p)==5 and p[4]["label"]=="Kunde X", "benannter leerer Slot 5 muss bleiben"'
"$CLI" remove 5 --yes >/dev/null
"$CLI" status --json | python3 -c 'import json,sys;assert len(json.load(sys.stdin)["profiles"])==4, "Slot 5 nach remove weg"'
"$CLI" remove 2 --yes >/dev/null; [ ! -d "$P/2" ] || fail "Profil 2 nicht gelöscht"
"$CLI" status --json | python3 -c 'import json,sys;p=json.load(sys.stdin)["profiles"];assert len(p)==4 and not p[1]["logged_in"] and p[1]["label"]=="Account 2", "Slot 2 muss leer bleiben"'
ok "remove"

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

echo "# import-Einträge kommen beim Wechsel mit (Profil 2 wurde oben entfernt -> Profil 3)"
"$CLI" 3 >/dev/null
ls "$LIVE/claude-code-sessions/A3/O3/" | grep -c local_ | grep -q 4 || fail "importierte Sessions nicht synchronisiert"
ok "import + sync"

# ---------- Limits: 5-Stunden-Fenster, Woche, Fable ----------
mk_plan() { # <5h%> <5h-Offset-s> <Woche%> <Offset-s> <Fable%> <Offset-s> – wie get_usage sie liefert
python3 - "$@" <<'PY'
import json, sys, time, datetime as dt
a = sys.argv[1:]
iso = lambda off: dt.datetime.fromtimestamp(time.time() + float(off), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
print(json.dumps({"status": "ok", "plan": "Max", "extraUsage": {"enabled": False, "currency": "USD"}, "windows": [
    {"label": "5-hour limit", "percentUsed": int(a[0]), "resetsAt": iso(a[1])},
    {"label": "Weekly · all models", "percentUsed": int(a[2]), "resetsAt": iso(a[3])},
    {"label": "Weekly · Fable", "percentUsed": int(a[4]), "resetsAt": iso(a[5])}]}))
PY
}
mk_history() { # <Profilordner> <org> <fh> <sd> <Alter-s>
python3 - "$@" <<'PY'
import json, sys, time
d, org, fh, sd, age = sys.argv[1:]
t = int((time.time() - float(age)) * 1000)
json.dump({"version": 2, "samples": [{"t": t, "org": org, "u": {"fh": int(fh), "sd": int(sd)}}]},
          open(d + "/plan-usage-history.json", "w"))
PY
}
age_record() { # <Profilordner> <Alter-s> – Aufzeichnung künstlich altern
python3 - "$@" <<'PY'
import json, sys, time
d, age = sys.argv[1:]
p = d + "/plan-usage-limits.json"
r = json.load(open(p)); r["recordedAt"] = int((time.time() - float(age)) * 1000); json.dump(r, open(p, "w"))
PY
}
check() { "$CLI" status --json > "$T/st.json"; python3 - "$T/st.json" || fail "$1"; ok "$1"; }

echo "# usage-record schreibt die vollen Fenster des aktiven Kontos"
rm -f "$LIVE/plan-usage-history.json"
mk_plan 12 3600 64 90000 100 90000 | "$CLI" usage-record | grep -qi fable || fail "usage-record meldet nichts"
[ -f "$LIVE/plan-usage-limits.json" ] || fail "Aufzeichnung nicht geschrieben"
check "usage-record" <<'PY'
import json, sys, time
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
w = {x["key"]: x for x in p["windows"]}
assert set(w) == {"five_hour", "weekly", "weekly_fable"}, w
assert [w[k]["percentUsed"] for k in ("five_hour", "weekly", "weekly_fable")] == [12, 64, 100], w
assert abs(w["five_hour"]["resetsAt"] / 1000 - (time.time() + 3600)) < 120, w["five_hour"]
assert p["fh"] == 12 and p["sd"] == 64, p
PY

echo "# abgelaufenes Fenster gilt als frei, der Reset rollt weiter"
mk_history "$LIVE" O3 80 40 21600          # 6 h alt: kein Beleg im laufenden 5-Stunden-Fenster
mk_plan 100 -7200 64 90000 100 90000 | "$CLI" usage-record >/dev/null
check "abgelaufenes Fenster" <<'PY'
import json, sys, time
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
w = {x["key"]: x for x in p["windows"]}
assert w["five_hour"]["percentUsed"] == 0, w["five_hour"]
assert abs(w["five_hour"]["resetsAt"] / 1000 - (time.time() + 3 * 3600)) < 120, w["five_hour"]
assert w["weekly"]["percentUsed"] == 64, "frische Aufzeichnung schlägt 6 h alte Historie"
PY

echo "# neuere App-Historie schlägt die ältere Aufzeichnung, Fable bleibt aus der Aufzeichnung"
mk_plan 12 3600 64 90000 100 90000 | "$CLI" usage-record >/dev/null
age_record "$LIVE" 7200
mk_history "$LIVE" O3 55 70 60
check "Historie schlägt alte Aufzeichnung" <<'PY'
import json, sys
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
w = {x["key"]: x for x in p["windows"]}
assert [w[k]["percentUsed"] for k in ("five_hour", "weekly", "weekly_fable")] == [55, 70, 100], w
assert p["fh"] == 55 and p["sd"] == 70, p
PY

echo "# ohne Aufzeichnung bleibt es beim heutigen Verhalten"
rm -f "$LIVE/plan-usage-limits.json"
mk_history "$LIVE" O3 33 44 60
check "ohne Aufzeichnung" <<'PY'
import json, sys
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
w = {x["key"]: x for x in p["windows"]}
assert set(w) == {"five_hour", "weekly"}, w
assert w["five_hour"]["percentUsed"] == 33 and w["five_hour"]["resetsAt"] is None, w
assert p["fh"] == 33 and p["sd"] == 44, p
PY

echo "# Müll wird abgewiesen, ohne etwas zu schreiben"
echo 'kein json' | "$CLI" usage-record >/dev/null 2>&1 && fail "ungültiges JSON muss scheitern"
echo '{"status":"unavailable"}' | "$CLI" usage-record >/dev/null 2>&1 && fail "Plan ohne Fenster muss scheitern"
[ ! -f "$LIVE/plan-usage-limits.json" ] || fail "fehlerhafte Eingabe darf nichts schreiben"
ok "Eingabeprüfung"

echo "# die Aufzeichnung bleibt beim Konto und wandert beim Wechsel mit"
mk_plan 7 3600 20 90000 90 90000 | "$CLI" usage-record >/dev/null
"$CLI" | grep -E '● 3 .*Fable +90%' >/dev/null || fail "Textausgabe zeigt Fable nicht: $("$CLI" | grep '3 ')"
"$CLI" 1 >/dev/null
check "Aufzeichnung bleibt beim Konto" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
by = {x["n"]: x for x in d["profiles"]}
assert d["active"] == 1, d["active"]
w3 = {x["key"]: x for x in by[3]["windows"]}
assert w3["weekly_fable"]["percentUsed"] == 90, w3
assert "weekly_fable" not in {x["key"] for x in by[1]["windows"]}, by[1]["windows"]
PY
echo "# Wochen-Reset aus der App-Historie ableiten, wenn keine Aufzeichnung da ist"
mk_weekly_history() { # <Profilordner> <org> <Anker-Offset-h: wann der Wochenreset liegt, relativ zu jetzt-7d> <Bracket-h>
python3 - "$@" <<'PY2'
import json, sys, time
d, org, off, br = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
now = time.time(); WEEK = 7 * 86400
anchor = now - WEEK + off * 3600          # letzter Wochenwechsel
S = lambda t, sd: {"t": int(t * 1000), "org": org, "u": {"fh": 0, "sd": sd}}
s = [S(anchor - WEEK - br * 1800, 60), S(anchor - WEEK + br * 1800, 5),   # Abfall vor zwei Wochen
     S(anchor - br * 1800, 70),        S(anchor + br * 1800, 8),          # Abfall vor einer Woche
     S(now - 600, 40)]
json.dump({"version": 2, "samples": s}, open(d + "/plan-usage-history.json", "w"))
PY2
}
rm -f "$LIVE/plan-usage-limits.json"
mk_weekly_history "$LIVE" O1 3 2
check "Wochen-Reset abgeleitet" <<'PY2'
import json, sys, time
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
w = {x["key"]: x for x in p["windows"]}
r = w["weekly"]
assert r["resetsAt"] is not None, "Wochen-Reset sollte abgeleitet werden"
assert r.get("estimated") is True, "abgeleitete Zeit muss als Schätzung markiert sein"
assert abs(r["resetsAt"] / 1000 - (time.time() + 3 * 3600)) < 3600, (r["resetsAt"] / 1000 - time.time()) / 3600
assert w["five_hour"]["resetsAt"] is None, "ohne laufendes Fenster gibt es keinen 5-Stunden-Reset"
PY2
"$CLI" | grep -E '● 1 .*7d .*↻~' >/dev/null || fail "Schätzung muss in der Textausgabe als ~ erkennbar sein"

echo "# zu unscharfe Historie liefert lieber gar keine Zeit"
mk_weekly_history "$LIVE" O1 3 40
check "unscharfe Historie" <<'PY2'
import json, sys
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
w = {x["key"]: x for x in p["windows"]}
assert w["weekly"]["resetsAt"] is None, w["weekly"]
PY2

echo "# eine Aufzeichnung schlägt die Schätzung"
mk_weekly_history "$LIVE" O1 3 2
mk_plan 12 3600 64 90000 100 90000 | "$CLI" usage-record >/dev/null
check "Aufzeichnung schlägt Schätzung" <<'PY2'
import json, sys, time
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
w = {x["key"]: x for x in p["windows"]}
assert not w["weekly"].get("estimated"), "aufgezeichnete Zeit ist keine Schätzung"
assert abs(w["weekly"]["resetsAt"] / 1000 - (time.time() + 90000)) < 120, w["weekly"]
PY2
echo "# ohne bekannte Reset-Zeit verfällt ein zu alter Wert trotzdem"
rm -f "$LIVE/plan-usage-limits.json"
mk_history "$LIVE" O1 90 40 21600          # 6 h alte Stichprobe: das 5-Stunden-Fenster ist längst vorbei
python3 - "$LIVE" <<'PY2'
import json, sys, time
# Aufzeichnung wie get_usage sie bei ruhendem Fenster liefert: Prozent, aber keine Reset-Zeit
json.dump({"version": 1, "recordedAt": int((time.time() - 25000) * 1000), "plan": "Max", "windows": [
    {"key": "five_hour", "label": "5-hour limit", "percentUsed": 50, "resetsAt": None},
    {"key": "weekly", "label": "Weekly · all models", "percentUsed": 40,
     "resetsAt": int((time.time() + 90000) * 1000)}], "extraUsage": {}},
    open(sys.argv[1] + "/plan-usage-limits.json", "w"))
PY2
check "alter Wert ohne Reset-Zeit verfaellt" <<'PY2'
import json, sys
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
w = {x["key"]: x for x in p["windows"]}
assert w["five_hour"]["percentUsed"] == 0, w["five_hour"]
assert w["weekly"]["percentUsed"] == 40, "die Woche laeuft noch, der Wert bleibt"
PY2

echo "# frische Stichprobe im laufenden Fenster bleibt stehen"
mk_history "$LIVE" O1 90 40 600
check "frische Stichprobe bleibt" <<'PY2'
import json, sys
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
assert {x["key"]: x for x in p["windows"]}["five_hour"]["percentUsed"] == 90
PY2
echo "# Limit-Sperre aus der Auto-Fortsetzung liefert den exakten 5-Stunden-Reset"
set_resume() { # <Profilordner> <Konto> <Offset-s> – so legt die App es beim Limit-Treffer ab
python3 - "$@" <<'PY2'
import json, os, sys, time
d, acct, off = sys.argv[1], sys.argv[2], float(sys.argv[3])
p = d + "/claude_desktop_config.json"
c = json.load(open(p)) if os.path.exists(p) else {}
prefs = c.setdefault("preferences", {}).setdefault("epitaxyPrefs", {})
prefs["autoResumeRateLimit." + acct] = {"local_x": {"resetsAt": int(time.time() + off), "attempt": 0, "optedIn": True}}
json.dump(c, open(p, "w"))
PY2
}
five_reset() { # erwartete Reset-Zeit in Sekunden ab jetzt, oder "none"
"$CLI" status --json > "$T/st.json"
python3 - "$T/st.json" "$1" <<'PY2'
import json, sys, time
p = [x for x in json.load(open(sys.argv[1]))["profiles"] if x["active"]][0]
r = {x["key"]: x for x in p["windows"]}["five_hour"]["resetsAt"]
if sys.argv[2] == "none":
    assert r is None, (r / 1000 - time.time()) / 3600
else:
    assert r is not None and abs(r / 1000 - (time.time() + float(sys.argv[2]))) < 120, r
PY2
}
rm -f "$LIVE/plan-usage-limits.json"
mk_history "$LIVE" O1 100 40 600
set_resume "$P/3" A1 7200               # liegt in der Konfig eines geparkten Profils – die Konfig wandert mit
set_resume "$LIVE" A3 3600              # Eintrag eines anderen Kontos darf nicht abfärben
five_reset 7200 || fail "Sperre muss den 5h-Reset liefern"; ok "Sperre liefert 5h-Reset"
set_resume "$P/3" A1 -60
five_reset none || fail "abgelaufene Sperre ignorieren"; ok "abgelaufene Sperre ignoriert"
set_resume "$P/3" A1 259200
five_reset none || fail "Sperre in 3 Tagen ist kein 5-Stunden-Limit"; ok "ferne Sperre ist kein 5h-Reset"
set_resume "$P/3" A1 7200; mk_history "$LIVE" O1 0 40 600
five_reset none || fail "ruhendes Fenster bekommt keinen Reset"; ok "ruhendes Fenster ohne Reset"
echo "ALLE TESTS OK"
