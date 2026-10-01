"""Workspace preservation regressions: real temporary Git repos, no real app/account access."""
import json
import os
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

import test_safety


class WorkspaceTests(unittest.TestCase):
    # Reuse the harness without inheriting its test cases.
    setUp = test_safety.SafetyTests.setUp
    tearDown = test_safety.SafetyTests.tearDown
    snapshot = test_safety.SafetyTests.snapshot
    assert_aborts_unchanged = test_safety.SafetyTests.assert_aborts_unchanged
    def scratch(self, n=1, name='account/org/scratch-old'):
        return self.r.pdir(n) / 'scratch-workspaces' / name

    def make_scratch(self):
        p = self.scratch()
        p.mkdir(parents=True)
        (p / 'empty').mkdir()
        (p / 'notes.txt').write_text('initial context')
        (p / 'remove-me').write_text('temporary')
        (p / 'link').symlink_to('notes.txt')
        self.r.edit('local_s1', cwd=str(p), originCwd=str(p), cliSessionId='cli-one')
        transcript = self.r.root / '.claude/projects/existing/cli-one.jsonl'
        transcript.parent.mkdir(parents=True)
        transcript.write_text('{"type":"user","message":"keep me"}\n')
        return p, transcript

    def git(self, path, *args):
        return subprocess.check_output(['git', '-C', str(path), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def make_worktree(self):
        repo = self.r.root / 'repo'
        repo.mkdir()
        self.git(repo, 'init')
        self.git(repo, 'config', 'user.email', 'test@example.com')
        self.git(repo, 'config', 'user.name', 'Test')
        (repo / 'tracked.txt').write_text('committed')
        self.git(repo, 'add', '.')
        self.git(repo, 'commit', '-m', 'initial')
        wt = self.r.root / 'repo-worktree'
        self.git(repo, 'worktree', 'add', '-b', 'session-branch', str(wt))
        (wt / 'tracked.txt').write_text('uncommitted')
        (wt / 'untracked.txt').write_text('valuable')
        self.r.edit('local_s1', cwd=str(wt), originCwd=str(repo), worktreeName='session-wt',
                    branch='session-branch', cliSessionId='cli-one', lastActivityAt=5000)
        entry = {'name': 'session-wt', 'path': str(wt), 'leasedBy': 'local_s1', 'baseRepo': str(repo),
                 'placementRoot': str(repo), 'branch': 'session-branch', 'sourceBranch': 'main',
                 'createdAt': 1, 'anchors': [{'gitRoot': str(wt)}]}
        self.registry(1, {'session-wt': entry})
        return wt, entry

    def registry(self, n, entries):
        p = self.r.pdir(n) / 'git-worktrees.json'
        p.write_text(json.dumps({'schemaVersion': 2, 'worktrees': entries, 'originUrls': {}, 'originPins': {},
                                'untrackedDirGc': {'sightings': {e['path']: 1 for e in entries.values()}}}))

    def test_scratch_contents_empty_dirs_and_links_survive_repeated_switches(self):
        original, transcript = self.make_scratch()
        original_bytes = transcript.read_bytes()
        self.r.switch(2)
        self.assertTrue(original.is_dir())
        self.assertTrue((original / 'empty').is_dir())
        self.assertEqual(os.readlink(original / 'link'), 'notes.txt')
        (original / 'notes.txt').write_text('newest context')
        (original / 'remove-me').unlink()
        for target in [3, 1, 2, 1]:
            self.r.switch(target)
            self.assertEqual((original / 'notes.txt').read_text(), 'newest context')
            self.assertFalse((original / 'remove-me').exists())
            self.assertEqual(self.r.session(target, 'local_s1')['cwd'], str(original))
            self.assertEqual(transcript.read_bytes(), original_bytes)
        roots = [self.scratch(n).parents[2] for n in (1, 2, 3)]
        self.assertEqual(len({root.resolve() for root in roots}), 1)

    def test_missing_live_scratch_is_restored_from_parked_profile(self):
        parked = self.scratch(3)
        parked.mkdir(parents=True)
        (parked / 'kept').write_text('history')
        self.r.edit('local_s1', cwd=str(self.scratch()), originCwd=str(self.scratch()))
        self.r.switch(2)
        self.assertEqual((self.scratch() / 'kept').read_text(), 'history')

    def test_worktree_registry_preserves_dirty_checkout_and_session_identity(self):
        wt, entry = self.make_worktree()
        before = self.git(wt, 'status', '--porcelain=v1')
        head = self.git(wt, 'rev-parse', 'HEAD')
        for target in [2, 3, 1, 3]:
            self.r.switch(target)
            data = json.loads((self.r.pdir(target) / 'git-worktrees.json').read_text())
            self.assertEqual(data['worktrees']['session-wt'], entry)
            self.assertNotIn(str(wt), data['untrackedDirGc']['sightings'])
            self.assertEqual(self.r.session(target, 'local_s1')['cliSessionId'], 'cli-one')
            self.assertEqual(self.git(wt, 'branch', '--show-current'), 'session-branch')
            self.assertEqual(self.git(wt, 'rev-parse', 'HEAD'), head)
            self.assertEqual(self.git(wt, 'status', '--porcelain=v1'), before)

    def test_active_repair_recovers_lease_from_parked_profile(self):
        wt, entry = self.make_worktree()
        self.registry(3, {'session-wt': entry})
        self.registry(1, {})
        self.cli.sync_current()
        data = json.loads((self.r.pdir(1) / 'git-worktrees.json').read_text())
        self.assertEqual(data['worktrees']['session-wt']['leasedBy'], 'local_s1')
        self.assertEqual(self.git(wt, 'branch', '--show-current'), 'session-branch')

    def test_recovered_workspace_bundle_wins_over_two_stale_profiles(self):
        wt, entry = self.make_worktree()
        old = {'cwd': '/gone/old', 'originCwd': '/gone/repo', 'worktreeName': 'old',
               'branch': 'old', 'cliSessionId': 'old-cli', 'lastActivityAt': 2000}
        for n in (2, 3):
            p = self.r.idx(n) / 'local_s1.json'
            d = json.loads(p.read_text()); d.update(old); p.write_text(json.dumps(d))
        self.r.switch(2)
        self.assertEqual(self.r.session(2, 'local_s1')['cwd'], str(wt))
        self.assertEqual(self.r.session(2, 'local_s1')['worktreeName'], 'session-wt')
        self.assertEqual(self.r.session(2, 'local_s1')['cliSessionId'], 'cli-one')

    def test_conflicting_scratch_files_abort_without_quitting_or_overwriting(self):
        self.make_scratch()
        other = self.scratch(2); other.mkdir(parents=True)
        (other / 'notes.txt').write_text('different important work')
        self.assert_aborts_unchanged()

    def test_invalid_registry_aborts_before_quit(self):
        self.make_worktree()
        (self.r.pdir(2) / 'git-worktrees.json').write_text('{')
        self.assert_aborts_unchanged()

    def test_unsupported_registry_schema_aborts_before_quit(self):
        (self.r.pdir(2) / 'git-worktrees.json').write_text('{"schemaVersion":99}')
        self.assert_aborts_unchanged()

    def test_failed_activation_restores_workspace_directories_and_registry(self):
        self.make_scratch(); self.make_worktree()
        before = self.snapshot()
        rename = Path.rename
        def fail(p, dest):
            if p == self.cli.PROFILES / '2' and dest == self.cli.LIVE:
                raise OSError('activation failed')
            return rename(p, dest)
        with patch.object(Path, 'rename', fail), self.assertRaises(SystemExit):
            self.cli.do_switch(2)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.r.pdir(1) / 'scratch-workspaces').is_symlink())

    def test_copy_failure_leaves_original_workspaces_untouched(self):
        self.make_scratch(); before = self.snapshot()
        with patch.object(self.cli.shutil, 'copy2', side_effect=OSError('disk full')), self.assertRaises(SystemExit):
            self.cli.do_switch(2)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.cli.SCRATCH.exists())

    def test_first_login_profile_gets_shared_root_before_session_index(self):
        self.make_scratch()
        with patch.object(self.cli.time, 'sleep'):
            self.cli.switch_profile(4)
        self.assertTrue((self.cli.LIVE / 'scratch-workspaces').is_symlink())
        self.assertEqual((self.cli.LIVE / 'scratch-workspaces/account/org/scratch-old/notes.txt').read_text(), 'initial context')

    def test_dry_run_is_read_only(self):
        self.make_scratch(); self.make_worktree(); before = self.snapshot()
        with patch.object(self.cli, 'quit_claude') as quit_app:
            self.cli.sync_current(dry_run=True)
        quit_app.assert_not_called()
        self.assertEqual(self.snapshot(), before)

    def test_extending_shared_tree_does_not_replace_existing_files(self):
        original, _ = self.make_scratch(); self.r.switch(2)
        new = self.cli.PROFILES / '4'
        folder = new / 'scratch-workspaces/new-account/org/scratch-new'
        folder.mkdir(parents=True); (folder / 'new').write_text('new profile')
        plan = self.cli.ScratchPlan({2: self.cli.LIVE, 4: new})
        inode = (original / 'notes.txt').stat().st_ino
        with plan.apply():
            pass
        self.assertEqual((original / 'notes.txt').stat().st_ino, inode)
        self.assertEqual((self.cli.SCRATCH / 'new-account/org/scratch-new/new').read_text(), 'new profile')

    def test_extension_rollback_keeps_shared_contents_and_original_new_profile(self):
        original, _ = self.make_scratch(); self.r.switch(2)
        new = self.cli.PROFILES / '4'
        folder = new / 'scratch-workspaces/new-account/org/scratch-new'
        folder.mkdir(parents=True); (folder / 'new').write_text('new profile')
        before = self.snapshot()
        plan = self.cli.ScratchPlan({2: self.cli.LIVE, 4: new})
        with self.assertRaisesRegex(RuntimeError, 'activation failed'):
            with plan.apply():
                raise RuntimeError('activation failed')
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((new / 'scratch-workspaces').is_symlink())

    def test_broken_shared_root_never_becomes_an_empty_replacement(self):
        self.make_scratch(); self.r.switch(2)
        saved = self.cli.SCRATCH.with_name('saved-workspaces')
        self.cli.SCRATCH.rename(saved)
        with self.assertRaisesRegex(ValueError, 'Shared workspaces are missing'):
            self.cli.ScratchPlan(self.cli.all_profile_dirs())
        self.assertFalse(self.cli.SCRATCH.exists())
        self.assertTrue((saved / 'account/org/scratch-old/notes.txt').is_file())

    def test_removing_parked_profile_keeps_shared_files(self):
        original, _ = self.make_scratch(); self.r.switch(2)
        self.cli.do_remove(['1', '--yes'])
        self.assertEqual((original / 'notes.txt').read_text(), 'initial context')


if __name__ == '__main__':
    unittest.main(verbosity=2)
