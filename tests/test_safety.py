"""Failure-path regressions. Synthetic profiles only; never control the real app."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_sync import Rig, SCRIPT, SIDS


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.r = Rig()
        loader = importlib.machinery.SourceFileLoader("switcher", SCRIPT)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.cli = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, self.r.env):
            loader.exec_module(self.cli)

    def tearDown(self):
        self.r.close()

    def snapshot(self):
        return {str(p.relative_to(self.r.root)): p.read_bytes()
                for p in self.r.root.rglob("*") if p.is_file() and p.name not in ("switch.log", "switch.lock")}

    def assert_aborts_unchanged(self):
        before = self.snapshot()
        with patch.object(self.cli, "quit_claude") as quit_app, patch.object(self.cli, "launch_claude") as launch:
            with self.assertRaises(SystemExit):
                self.cli.do_switch(2)
            quit_app.assert_not_called()
            launch.assert_not_called()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.r.active(), 1)

    def test_malformed_source_does_not_delete_healthy_copies(self):
        (self.r.idx(1) / "local_s1.json").write_text('{"sessionId":')
        self.assert_aborts_unchanged()

    def test_malformed_destination_is_not_overwritten(self):
        (self.r.idx(2) / "local_s1.json").write_text("[")
        self.assert_aborts_unchanged()

    def test_invalid_session_shapes_and_identities_abort(self):
        p = self.r.idx(1) / "local_s1.json"
        for data in ([], None, {}, {"sessionId": "local_s2"}, {"sessionId": ["local_s1"]}):
            with self.subTest(data=data):
                p.write_text(json.dumps(data))
                self.assert_aborts_unchanged()

    def test_unreadable_card_aborts(self):
        original = Path.read_text
        card = self.r.idx(1) / "local_s1.json"

        def read(p, *args, **kwargs):
            if p == card:
                raise PermissionError("test unreadable card")
            return original(p, *args, **kwargs)

        with patch.object(Path, "read_text", read):
            self.assert_aborts_unchanged()

    def test_invalid_utf8_aborts(self):
        (self.r.idx(1) / "local_s1.json").write_bytes(b"\xff")
        self.assert_aborts_unchanged()

    def test_missing_card_is_restored_on_return(self):
        (self.r.idx(1) / "local_s1.json").unlink()
        self.r.switch(2)
        self.assertEqual(self.r.session(2, "local_s1")["sessionId"], "local_s1")
        self.r.switch(1)
        for n in (1, 2, 3):
            self.assertEqual(set(self.cli.sessions_in(self.r.pdir(n))), set(SIDS))

    def test_malformed_auxiliary_data_aborts_before_any_writes(self):
        paths = [self.r.idx(2) / "archived-sessions.idx", self.r.idx(1) / "scheduled-tasks.json",
                 self.r.pdir(2) / "claude_desktop_config.json", self.cli.MANIFEST, self.cli.SNAPSHOT,
                 self.cli.ROUTINES_SNAPSHOT, self.r.pdir(1) / "config.json", self.cli.CONFIG]
        for p in paths:
            with self.subTest(path=p.name):
                old = p.read_bytes() if p.exists() else None
                p.write_text("{")
                self.assert_aborts_unchanged()
                if old is None:
                    p.unlink()
                else:
                    p.write_bytes(old)

    def test_invalid_routine_is_not_silently_dropped(self):
        for data in ({"scheduledTasks": [{}]}, {"scheduledTasks": "bad"},
                     {"scheduledTasks": [{"id": "same"}, {"id": "same"}]}):
            with self.subTest(data=data):
                (self.r.idx(1) / "scheduled-tasks.json").write_text(json.dumps(data))
                self.assert_aborts_unchanged()

    def test_final_app_write_is_revalidated_after_quit(self):
        p = self.r.idx(1) / "local_s1.json"
        other = (self.r.idx(2) / "local_s1.json").read_bytes()
        with patch.object(self.cli, "quit_claude", side_effect=lambda: p.write_text("{")), \
                patch.object(self.cli, "launch_claude") as launch:
            with self.assertRaises(SystemExit):
                self.cli.do_switch(2)
            launch.assert_called_once()
        self.assertEqual(self.r.active(), 1)
        self.assertEqual((self.r.idx(2) / "local_s1.json").read_bytes(), other)

    def test_disk_error_rolls_back_written_metadata(self):
        self.r.edit("local_s1", title="Latest title")
        before = self.snapshot()
        write = self.cli.atomic_write
        failed = False

        def fail_once(p, data):
            nonlocal failed
            if p == self.cli.SNAPSHOT and not failed:
                failed = True
                raise OSError("simulated disk error")
            return write(p, data)

        with patch.object(self.cli, "atomic_write", fail_once):
            with self.assertRaises(SystemExit):
                self.cli.do_switch(2)
        self.assertTrue(failed)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.r.active(), 1)

    def test_failed_activation_restores_directories_and_metadata(self):
        self.r.edit("local_s1", title="Latest title")
        before = self.snapshot()
        rename = Path.rename
        incoming = self.cli.PROFILES / "2"

        def fail_activation(p, dest):
            if p == incoming and dest == self.cli.LIVE:
                raise OSError("simulated directory rename failure")
            return rename(p, dest)

        with patch.object(Path, "rename", fail_activation):
            with self.assertRaises(SystemExit):
                self.cli.do_switch(2)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.r.active(), 1)

    def test_failed_rollback_stops_without_launching(self):
        self.r.edit("local_s1", title="Latest title")
        write = self.cli.atomic_write
        restoring = False

        def fail_rollback(p, data):
            nonlocal restoring
            if p == self.cli.SNAPSHOT:
                restoring = True
                raise OSError("simulated initial failure")
            if restoring:
                raise OSError("simulated rollback failure")
            return write(p, data)

        with patch.object(self.cli, "atomic_write", fail_rollback), patch.object(self.cli, "launch_claude") as launch:
            with self.assertRaisesRegex(SystemExit, "Rollback incomplete"):
                self.cli.do_switch(2)
            launch.assert_not_called()
        self.assertEqual(self.r.active(), 1)

    def test_failed_launch_is_not_reported_as_success(self):
        with patch.object(self.cli, "NO_APP", False), \
                patch.object(self.cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(RuntimeError, "Could not launch"):
                self.cli.launch_claude()

    def test_atomic_replace_failure_keeps_original_and_cleans_temp(self):
        p = self.r.idx(1) / "local_s1.json"
        before = self.snapshot()
        with patch.object(Path, "replace", side_effect=OSError("simulated replace failure")):
            with self.assertRaises(OSError):
                self.cli.save_json(p, {"new": "contents"})
        self.assertEqual(self.snapshot(), before)

    def test_failed_directory_recovery_does_not_write_to_unknown_live_path(self):
        source = (self.r.idx(1) / "local_s1.json").read_bytes()
        rename = Path.rename

        def fail_recovery(p, dest):
            if dest == self.cli.LIVE:
                raise OSError("simulated activation and recovery failure")
            return rename(p, dest)

        with patch.object(Path, "rename", fail_recovery), patch.object(self.cli, "launch_claude") as launch:
            with self.assertRaisesRegex(SystemExit, "Inspect these directories"):
                self.cli.do_switch(2)
            launch.assert_not_called()
        self.assertFalse(self.cli.LIVE.exists())
        parked_card = self.cli.PROFILES / "1" / "claude-code-sessions"
        self.assertEqual(next(parked_card.rglob("local_s1.json")).read_bytes(), source)
        self.assertTrue((self.cli.PROFILES / "2").is_dir())

    def test_simultaneous_switch_is_rejected(self):
        before = self.snapshot()
        with self.cli.switch_lock():
            result = subprocess.run([sys.executable, SCRIPT, "2"], env=self.r.env,
                                    capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another profile switch", result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.r.switch(2)  # released automatically; no stale lockfile blocker

    def test_other_writers_cannot_race_a_switch(self):
        before = self.snapshot()
        commands = [["remove", "2", "--yes"], ["add", "new"], ["repair"], ["profiles", "5"],
                    ["label", "1", "new"], ["import"], ["usage-record"]]
        with self.cli.switch_lock():
            for args in commands:
                with self.subTest(args=args):
                    result = subprocess.run([sys.executable, SCRIPT, *args], env=self.r.env,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Another profile switch", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_missing_routine_file_is_not_a_delete_instruction(self):
        self.r.set_routines([{"id": "keep", "createdAt": 1}])
        self.r.switch(2)
        (self.r.idx(2) / "scheduled-tasks.json").unlink()
        self.r.switch(1)
        self.assertEqual(self.r.routine_ids(1), {"keep"})

    def test_first_login_quits_again_before_syncing(self):
        import shutil
        shutil.rmtree(self.r.pdir(2))

        def signed_in(_seconds):
            self.r.idx(2).mkdir(parents=True, exist_ok=True)

        with patch.object(self.cli.time, "sleep", signed_in), \
                patch.object(self.cli, "quit_claude") as quit_app, patch.object(self.cli, "launch_claude") as launch:
            self.cli.do_switch(2)
        self.assertEqual(quit_app.call_count, 2)
        self.assertEqual(launch.call_count, 2)
        self.assertEqual(set(self.cli.sessions_in(self.r.pdir(2))), set(SIDS))

    def test_first_login_sync_failure_is_reported(self):
        import shutil
        shutil.rmtree(self.r.pdir(2))

        def signed_in(_seconds):
            self.r.idx(2).mkdir(parents=True, exist_ok=True)
            (self.r.idx(2) / "local_broken.json").write_text("{")

        with patch.object(self.cli.time, "sleep", signed_in), patch.object(self.cli, "notify") as notify:
            with self.assertRaisesRegex(SystemExit, "Invalid JSON"):
                self.cli.do_switch(2)
        self.assertEqual(self.r.active(), 2)  # sign-in is retained; original cards remain parked
        self.assertTrue((self.r.idx(1) / "local_s1.json").is_file())
        self.assertFalse(any("Sessions added" in c.args[0] for c in notify.call_args_list))
        self.assertIn("failed", notify.call_args.args[0])

    def test_quit_veto_does_not_move_profiles_or_kill_processes(self):
        before = self.snapshot()
        with patch.object(self.cli, "NO_APP", False), patch.object(self.cli, "claude_pids", return_value=[42]), \
                patch.object(self.cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), \
                patch.object(self.cli.os, "kill") as kill, patch.object(self.cli, "notify"):
            with self.assertRaisesRegex(SystemExit, "refused to quit"):
                self.cli.do_switch(2)
            kill.assert_not_called()
        self.assertEqual(self.snapshot(), before)

    def test_quit_timeout_never_force_kills(self):
        with patch.object(self.cli, "NO_APP", False), patch.object(self.cli, "claude_pids", return_value=[42]), \
                patch.object(self.cli.subprocess, "run", side_effect=subprocess.TimeoutExpired("osascript", 15)), \
                patch.object(self.cli.os, "kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "did not confirm"):
                self.cli.quit_claude()
            kill.assert_not_called()

    def test_app_that_stays_running_never_force_killed(self):
        with patch.object(self.cli, "NO_APP", False), patch.object(self.cli, "claude_pids", return_value=[42]), \
                patch.object(self.cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(self.cli.time, "sleep"), patch.object(self.cli.os, "kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "still running"):
                self.cli.quit_claude()
            kill.assert_not_called()

    def test_process_inventory_failure_aborts(self):
        with patch.object(self.cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, stdout="")):
            with self.assertRaisesRegex(RuntimeError, "Cannot check"):
                self.cli.claude_pids()

    def test_error_does_not_emit_success_notification(self):
        (self.r.idx(1) / "local_s1.json").write_text("{")
        with patch.object(self.cli, "notify") as notify:
            with self.assertRaises(SystemExit):
                self.cli.do_switch(2)
            self.assertEqual(len(notify.call_args_list), 1)
            self.assertIn("failed", notify.call_args.args[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
