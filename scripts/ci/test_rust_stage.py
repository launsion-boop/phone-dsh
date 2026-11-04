#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for Rust stage dispatch, failing cargo, and honest SKIP semantics."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which('bash')


class RustStageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        script = self.root / 'scripts/ci/check.sh'
        script.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'scripts/ci/check.sh', script)
        (self.root / 'shell').mkdir()
        (self.root / 'shell/Cargo.toml').write_text('[workspace]\n')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ['dirname', 'mkdir', 'date', 'tr', 'rm', 'sed', 'cat']:
            (self.bin / name).symlink_to(shutil.which(name))

    def run_stage(self, cargo=None):
        if cargo is not None:
            path = self.bin / 'cargo'
            path.write_text('#!/bin/sh\n' + cargo)
            path.chmod(0o755)
        env = dict(os.environ, PATH=str(self.bin), CI_TMP=str(self.root / 'tmp'))
        return subprocess.run([BASH, str(self.root / 'scripts/ci/check.sh'), '--only', 'phone-rust-tests'],
                              env=env, capture_output=True, text=True)

    def test_stage_runs_both_packages(self):
        result = self.run_stage('test "$*" = "test -p pdsh-wire -p pdsh-wal"\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS  phone-rust-tests', result.stdout)

    def test_cargo_failure_is_fail(self):
        result = self.run_stage('exit 9\n')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('FAIL  phone-rust-tests', result.stdout)

    def test_missing_cargo_is_skip_and_incomplete(self):
        result = self.run_stage()
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn('SKIP  phone-rust-tests', result.stdout)
        self.assertIn('CI GATE: INCOMPLETE', result.stdout)
        self.assertNotIn('CI GATE: PASS', result.stdout)


if __name__ == '__main__':
    unittest.main()
