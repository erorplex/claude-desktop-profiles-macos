"""Szenario-Tests fuer den Kontowechsel: echte Wechsel ueber das Skript, App abgeschaltet, Attrappen-Profile."""
import json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

SCRIPT = os.environ.get("SWITCHER", str(Path(__file__).resolve().parent.parent / "bin" / "claude-profiles"))
ACCT = {1: ("a1111111-1111-1111-1111-111111111111", "o1111111-1111-1111-1111-111111111111"),
        2: ("a2222222-2222-2222-2222-222222222222", "o2222222-2222-2222-2222-222222222222"),
        3: ("a3333333-3333-3333-3333-333333333333", "o3333333-3333-3333-3333-333333333333")}
SIDS = ["local_s1", "local_s2"]


class Rig:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="switcher-"))
        self.sup = self.root / "support"
        self.env = dict(os.environ, CLAUDE_PROFILES_HOME=str(self.root), CLAUDE_PROFILES_APP_SUPPORT=str(self.sup),
                        CLAUDE_PROFILES_CONFIG=str(self.root / "cfg.json"), CLAUDE_PROFILES_LOG=str(self.root / "switch.log"),
                        CLAUDE_PROFILES_NO_APP="1")
        for n in (1, 2, 3):
            d = self.sup / "Claude" if n == 1 else self.sup / "Claude-profiles" / str(n)
            a, o = ACCT[n]
            idx = d / "claude-code-sessions" / a / o
            idx.mkdir(parents=True)
            (d / ".claude-profiles-id").write_text(str(n))
            (d / "config.json").write_text(json.dumps({"lastKnownAccountUuid": a}))
            for i, sid in enumerate(SIDS):
                (idx / f"{sid}.json").write_text(json.dumps({
                    "sessionId": sid, "title": f"Titel {i}", "lastActivityAt": 1000 + i, "isArchived": False,
                    "permissionMode": "default", "completedTurns": 1, "bridgeSessionIds": [f"bridge-{n}"]}))
            (idx / "archived-sessions.idx").write_text(json.dumps({"v": 1, "archived": []}))
            (d / "claude_desktop_config.json").write_text(json.dumps({"preferences": {"epitaxyPrefs": {}}}))
        (self.root / "cfg.json").write_text(json.dumps({"labels": {}, "active": 1, "profiles": 3}))
        man = self.sup / "Claude-profiles" / "shared" / "sessions-manifest.json"
        man.parent.mkdir(parents=True, exist_ok=True)
        man.write_text(json.dumps({sid: {"profiles": [1, 2, 3]} for sid in SIDS}))

    def pdir(self, n):
        return self.sup / "Claude" if self.active() == n else self.sup / "Claude-profiles" / str(n)

    def active(self):
        return int((self.sup / "Claude" / ".claude-profiles-id").read_text())

    def idx(self, n):
        a, o = ACCT[n]
        return self.pdir(n) / "claude-code-sessions" / a / o

    def session(self, n, sid):
        return json.loads((self.idx(n) / f"{sid}.json").read_text())

    def edit(self, sid, **changes):
        """Wie die App: aendert eine Sitzung im aktiven Profil, ohne lastActivityAt anzufassen."""
        n = self.active()
        p = self.idx(n) / f"{sid}.json"
        d = json.loads(p.read_text())
        for k, v in changes.items():
            if v is None:
                d.pop(k, None)
            else:
                d[k] = v
        p.write_text(json.dumps(d))

    def archive(self, sid, flag):
        n = self.active()
        self.edit(sid, isArchived=flag)
        p = self.idx(n) / "archived-sessions.idx"
        a = set(json.loads(p.read_text())["archived"])
        (a.add if flag else a.discard)(sid)
        p.write_text(json.dumps({"v": 1, "archived": sorted(a)}))

    def archived(self, n):
        return set(json.loads((self.idx(n) / "archived-sessions.idx").read_text())["archived"])

    def set_groups(self, groups, assignments):
        n = self.active()
        a, o = ACCT[n]
        p = self.pdir(n) / "claude_desktop_config.json"
        c = json.loads(p.read_text())
        c["preferences"]["epitaxyPrefs"]["dframe-group-scopes"] = {
            f"{a}/{o}": {"groups": groups, "assignments": assignments, "order": {}}}
        p.write_text(json.dumps(c))

    def groups(self, n):
        a, o = ACCT[n]
        c = json.loads((self.pdir(n) / "claude_desktop_config.json").read_text())
        return c["preferences"]["epitaxyPrefs"].get("dframe-group-scopes", {}).get(f"{a}/{o}")

    def switch(self, n):
        r = subprocess.run([sys.executable, SCRIPT, str(n)], env=self.env, capture_output=True, text=True)
        log = (self.root / "switch.log").read_text() if (self.root / "switch.log").exists() else ""
        assert r.returncode == 0, r.stderr + log
        assert "sync failed" not in log, log
        assert self.active() == n, log

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


class SwitchTests(unittest.TestCase):
    def setUp(self):
        self.r = Rig()
        self.r.switch(2)          # erster Wechsel legt den gemeinsamen Ausgangsstand fest
        self.r.switch(1)

    def tearDown(self):
        self.r.close()

    # --- neue Anforderungen ---

    def test_umbenennung_wandert_ins_zielkonto(self):
        self.r.edit("local_s1", title="ebay-rechnungen", titleSource="user")
        self.r.switch(2)
        self.assertEqual(self.r.session(2, "local_s1")["title"], "ebay-rechnungen")

    def test_umbenennung_erreicht_spaeter_auch_das_dritte_konto(self):
        self.r.edit("local_s1", title="ebay-rechnungen")
        self.r.switch(2)
        self.r.switch(3)
        self.assertEqual(self.r.session(3, "local_s1")["title"], "ebay-rechnungen")
        self.assertEqual(self.r.session(2, "local_s1")["title"], "ebay-rechnungen")

    def test_rechtemodus_wandert_ins_zielkonto(self):
        self.r.edit("local_s2", permissionMode="bypassPermissions")
        self.r.switch(3)
        self.assertEqual(self.r.session(3, "local_s2")["permissionMode"], "bypassPermissions")

    def test_neues_feld_wandert_mit(self):
        self.r.edit("local_s1", previousTitles=["Titel 0"])
        self.r.switch(2)
        self.assertEqual(self.r.session(2, "local_s1").get("previousTitles"), ["Titel 0"])

    def test_veraltetes_zielkonto_ueberschreibt_nichts(self):
        self.r.edit("local_s1", title="neu")
        self.r.switch(2)                  # Profil 3 bleibt veraltet
        self.r.switch(3)                  # Ziel 3 ist veraltet, darf den neuen Stand nicht verdraengen
        self.r.switch(1)
        for n in (1, 2, 3):
            self.assertEqual(self.r.session(n, "local_s1")["title"], "neu", f"Profil {n}")

    def test_unterbrochene_kette_verteilt_keinen_altstand(self):
        self.r.edit("local_s1", title="neu")
        self.r.switch(2)
        self.r.switch(3)
        # jemand aktiviert Profil 1 am Umschalter vorbei und Profil 1 traegt dort noch den alten Titel
        live, p1 = self.r.sup / "Claude", self.r.sup / "Claude-profiles" / "1"
        live.rename(self.r.sup / "Claude-profiles" / "3")
        p1.rename(live)
        self.r.edit("local_s1", title="Titel 0")
        cfg = json.loads((self.r.root / "cfg.json").read_text()); cfg["active"] = 1
        (self.r.root / "cfg.json").write_text(json.dumps(cfg))
        self.r.switch(2)
        self.assertEqual(self.r.session(2, "local_s1")["title"], "neu")

    def test_kontogebundene_felder_des_ziels_bleiben(self):
        self.r.edit("local_s1", title="neu")
        self.r.switch(2)
        self.assertEqual(self.r.session(2, "local_s1")["bridgeSessionIds"], ["bridge-2"])

    def test_gruppen_wandern_auch_wenn_ziel_config_neuer_ist(self):
        self.r.set_groups([{"id": "cg-x", "name": "Flowkom"}], {"code:local_s1": "cg-x"})
        p2 = self.r.pdir(2) / "claude_desktop_config.json"
        os.utime(p2, (4_000_000_000, 4_000_000_000))       # Zielkonfig juenger als die Quelle
        self.r.switch(2)
        g = self.r.groups(2)
        self.assertIsNotNone(g)
        self.assertEqual([x["name"] for x in g["groups"]], ["Flowkom"])
        self.assertEqual(len(g["assignments"]), 1)

    def test_alle_gruppen_geloescht_verschwinden_im_ziel(self):
        self.r.set_groups([{"id": "cg-x", "name": "Flowkom"}], {"code:local_s1": "cg-x"})
        self.r.switch(2)
        self.r.switch(1)
        self.r.set_groups([], {})
        self.r.switch(2)
        g = self.r.groups(2)
        self.assertFalse(g and g["groups"], g)

    def test_scope_entfernt_loescht_gruppen_im_ziel(self):
        self.r.set_groups([{"id": "cg-x", "name": "Flowkom"}], {"code:local_s1": "cg-x"})
        self.r.switch(2)
        self.r.switch(1)
        c = self.r.pdir(1) / "claude_desktop_config.json"
        d = json.loads(c.read_text()); d["preferences"]["epitaxyPrefs"].pop("dframe-group-scopes"); c.write_text(json.dumps(d))
        self.r.switch(2)
        self.assertIsNone(self.r.groups(2))

    # --- bestehendes Verhalten, darf nicht brechen ---

    def test_archivieren_wandert_ins_zielkonto(self):
        self.r.archive("local_s2", True)
        self.r.switch(2)
        self.assertTrue(self.r.session(2, "local_s2")["isArchived"])
        self.assertIn("local_s2", self.r.archived(2))

    def test_entarchivieren_wandert_ins_zielkonto(self):
        self.r.archive("local_s2", True)
        self.r.switch(2)
        self.r.archive("local_s2", False)
        self.r.switch(1)
        self.assertFalse(self.r.session(1, "local_s2")["isArchived"])
        self.assertNotIn("local_s2", self.r.archived(1))

    def test_neue_aktivitaet_wandert_ins_zielkonto(self):
        self.r.edit("local_s1", lastActivityAt=5000, completedTurns=9)
        self.r.switch(3)
        s = self.r.session(3, "local_s1")
        self.assertEqual((s["lastActivityAt"], s["completedTurns"]), (5000, 9))

    def test_gruppen_wandern_unter_dem_scope_des_ziels(self):
        self.r.set_groups([{"id": "cg-x", "name": "Timekom"}], {"code:local_s2": "cg-x"})
        self.r.switch(3)
        self.assertEqual([x["name"] for x in self.r.groups(3)["groups"]], ["Timekom"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
