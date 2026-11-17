"""Reset dates must come from recorded plan data, not dips in cached percentages."""
import importlib.machinery
import importlib.util
import json
import os
import unittest
from unittest.mock import patch

from test_sync import Rig, SCRIPT


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.r = Rig()
        loader = importlib.machinery.SourceFileLoader("switcher_usage", SCRIPT)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.cli = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, self.r.env):
            loader.exec_module(self.cli)
        self.now = 1790665200

    def tearDown(self):
        self.r.close()

    def history(self, values):
        samples = [{"t": (self.now + offset) * 1000, "org": "test-org", "u": {"fh": 14, "sd": sd}}
                   for offset, sd in values]
        (self.cli.LIVE / "plan-usage-history.json").write_text(json.dumps({"samples": samples}))

    def record(self, key, offset):
        data = {"recordedAt": (self.now - 3600) * 1000, "windows": [
            {"key": key, "label": key, "percentUsed": 96, "resetsAt": (self.now + offset) * 1000}]}
        (self.cli.LIVE / self.cli.LIMITS).write_text(json.dumps(data))

    def windows(self):
        with patch.object(self.cli.time, "time", return_value=self.now):
            return {w["key"]: w for w in self.cli.usage(self.cli.LIVE)["windows"]}

    def test_multiple_drops_do_not_define_a_weekly_schedule(self):
        self.history([(-345600, 23), (-344700, 0), (-325800, 16), (-324900, 1),
                      (-86400, 100), (-85500, 0), (-60, 96)])
        weekly = self.windows()["weekly"]
        self.assertEqual(weekly["percentUsed"], 96)
        self.assertIsNone(weekly["resetsAt"])
        self.assertFalse(weekly.get("estimated", False))

    def test_even_recurring_drops_do_not_fabricate_a_reset(self):
        self.history([(-1209600, 90), (-1209000, 0), (-604800, 90), (-604200, 0), (-60, 96)])
        self.assertIsNone(self.windows()["weekly"]["resetsAt"])

    def test_confirmed_future_reset_survives_percentage_corrections(self):
        self.history([(-86400, 100), (-85500, 0), (-60, 97)])
        self.record("weekly", 259200)
        weekly = self.windows()["weekly"]
        self.assertEqual(weekly["resetsAt"], (self.now + 259200) * 1000)
        self.assertEqual(weekly["percentUsed"], 97)

    def test_expired_weekly_reset_is_not_advanced_by_seven_days(self):
        self.history([(-60, 12)])
        self.record("weekly", -3600)
        weekly = self.windows()["weekly"]
        self.assertIsNone(weekly["resetsAt"])
        self.assertEqual(weekly["percentUsed"], 12)

    def test_expired_five_hour_reset_is_not_advanced_by_five_hours(self):
        self.record("five_hour", -3600)
        five_hour = self.windows()["five_hour"]
        self.assertIsNone(five_hour["resetsAt"])
        self.assertEqual(five_hour["percentUsed"], 0)

    def samples(self, *values):
        samples = [{"t": (self.now + offset) * 1000, "org": "test-org", "u": u} for offset, u in values]
        (self.cli.LIVE / "plan-usage-history.json").write_text(json.dumps({"samples": samples}))

    def test_plan_without_five_hour_window_shows_only_the_weekly_one(self):
        # The app stopped reporting fh: the newest sample decides, older ones with fh do not.
        self.samples((-86400, {"fh": 14, "sd": 40}), (-60, {"sd": 3}))
        windows = self.windows()
        self.assertEqual(list(windows), ["weekly"])
        self.assertEqual(windows["weekly"]["percentUsed"], 3)

    def test_missing_five_hour_window_is_not_shown_as_reset_after_five_hours(self):
        self.samples((-6 * 3600, {"sd": 3}))
        self.assertEqual(list(self.windows()), ["weekly"])

    def test_unknown_values_still_show_both_windows(self):
        self.samples((-60, {"fh": None, "sd": 3}))
        self.assertIsNone(self.windows()["five_hour"]["percentUsed"])
        (self.cli.LIVE / "plan-usage-history.json").unlink()
        self.assertEqual(sorted(self.windows()), ["five_hour", "weekly"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
