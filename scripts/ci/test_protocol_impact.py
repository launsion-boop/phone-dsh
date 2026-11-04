#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the real diff/registry/PR-body checker with temporary git repositories."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import protocol_impact as impact
ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ci/protocol_impact.py'


class ImpactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.write('spec/registry.json', (ROOT / 'spec/registry.json').read_text())
        self.write('Sources/PhoneDSHWire/Frame.swift', '// original\n')
        self.write('Sources/PhoneDSHWire/WAL.swift', '// original\n')
        self.write('plugins/demo/src/client/view.ts', 'postMessage({})\n')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Protocol Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'base')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], capture_output=True, check=True)

    def write(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def run_check(self, body, base='HEAD'):
        body_file = self.root / '.git/body.txt'
        body_file.write_text(body)
        return subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root),
                               '--base', base, '--body-file', str(body_file)], capture_output=True, text=True)

    def test_missing_id_fails_and_correct_id_passes(self):
        self.write('Sources/PhoneDSHWire/Frame.swift', '// changed\n')
        fail = self.run_check('Protocol impact: P02')
        self.assertEqual(fail.returncode, 1, fail.stdout)
        self.assertIn('missing P01', fail.stdout)
        self.assertEqual(self.run_check('Protocol impact: P01').returncode, 0)

    def test_triggered_p09_cannot_use_global_none(self):
        self.write('examples/probe-app/PhoneDSHProbe/review.swift', '// comment only\n')
        fail = self.run_check('Protocol impact: none — comment refactor')
        self.assertEqual(fail.returncode, 1, fail.stdout)
        self.assertIn('global none cannot cover triggered IDs: P09', fail.stdout)
        self.assertEqual(self.run_check('Protocol impact: P09: none — comment refactor').returncode, 0)

    def test_per_id_affected_and_none_cover_every_trigger(self):
        self.write('Sources/PhoneDSHWire/Frame.swift', '// changed\n')
        self.write('examples/probe-app/PhoneDSHProbe/review.swift', '// comment only\n')
        result = self.run_check('Protocol impact: P01; P09: none — UI comments only')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.run_check('Protocol impact: P09: none — UI comments only').returncode, 1)

    def test_ids_in_none_reasons_do_not_count_as_declarations(self):
        self.write('Sources/PhoneDSHWire/Frame.swift', '// changed\n')
        fail = self.run_check('Protocol impact: P09: none — P01 is discussed here')
        self.assertEqual(fail.returncode, 1, fail.stdout)
        self.assertIn('missing P01', fail.stdout)

    def test_scoped_none_requires_reason_and_cannot_conflict(self):
        for value in ['P09: none', 'P09: none — ...', 'P01; P01: none — comments',
                      'P09: none — comments; P09', 'P99: none — comments',
                      'P01, P09: none — shared reason', 'P09: none — comments;']:
            with self.subTest(value=value):
                self.assertEqual(self.run_check('Protocol impact: ' + value).returncode, 1)

    def test_advanced_base_only_paths_do_not_trigger_either_tool(self):
        schema_path = 'spec/v1/schema/hello.schema.json'
        self.write(schema_path, '{"type":"object"}')
        self.git('add', '.')
        self.git('-c', 'user.name=Protocol Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'shared schema')
        shared = self.git('rev-parse', 'HEAD').stdout.decode().strip()
        self.git('checkout', '-qb', 'advanced-base')
        self.write('Sources/PhoneDSHWire/Frame.swift', '// upstream-only change\n')
        self.write(schema_path, '{"type":"string"}')
        self.git('add', '.')
        self.git('-c', 'user.name=Protocol Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'base advances trigger and schema')
        self.git('checkout', '-qb', 'feature', shared)
        self.write('notes.md', 'feature-only documentation\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Protocol Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'feature diverges without touching either path')
        result = self.run_check('Protocol impact: none — local notes only', 'advanced-base')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('0 triggered ID(s)', result.stdout)
        schema = subprocess.run([sys.executable, str(ROOT / 'spec/tools/schema_diff.py'),
                                 '--root', str(self.root), '--base', 'advanced-base'],
                                capture_output=True, text=True)
        self.assertEqual(schema.returncode, 0, schema.stdout + schema.stderr)
        self.assertIn('0 breaking finding(s)', schema.stdout)
        for output in (result.stdout, schema.stdout):
            self.assertNotIn('Sources/PhoneDSHWire/Frame.swift', output)
            self.assertNotIn(schema_path, output)

    def test_missing_line_fails(self):
        self.assertEqual(self.run_check('Only a description').returncode, 1)

    def test_none_requires_reason(self):
        self.assertEqual(self.run_check('Protocol impact: none').returncode, 1)
        self.assertEqual(self.run_check('Protocol impact: none — ...').returncode, 1)
        self.assertEqual(self.run_check('Protocol impact: none — comment refactor').returncode, 0)

    def test_inline_template_label(self):
        self.assertEqual(self.run_check('`Protocol impact:` none — docs only').returncode, 0)

    def test_unknown_or_contradictory_declaration_fails(self):
        for body in ['Protocol impact: P99', 'Protocol impact: none — docs\nProtocol impact: P01',
                     'Protocol impact: P01, none — docs', 'Protocol impact:\nP01']:
            self.assertEqual(self.run_check(body).returncode, 1)

    def test_deletion_and_content_removal_still_trigger(self):
        (self.root / 'plugins/demo/src/client/view.ts').unlink()
        fail = self.run_check('Protocol impact: P01')
        self.assertEqual(fail.returncode, 1, fail.stdout)
        self.assertIn('missing P04', fail.stdout)

    def test_content_predicate_does_not_trigger_unrelated_client(self):
        self.write('plugins/demo/src/client/other.ts', 'export const label = 1\n')
        result = self.run_check('Protocol impact: P01')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('0 triggered', result.stdout)

    def test_renames_check_both_paths(self):
        self.git('mv', 'Sources/PhoneDSHWire/Frame.swift', 'renamed.swift')
        self.assertEqual(self.run_check('Protocol impact: P02').returncode, 1)
        self.assertEqual(self.run_check('Protocol impact: P01').returncode, 0)

    def test_exclusions_and_overlapping_ids(self):
        self.write('Sources/PhoneDSHWire/WAL.swift', '// changed\n')
        result = self.run_check('Protocol impact: P02')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('P01:', result.stdout)
        self.write('Sources/PhoneDSHLoopback/LoopbackServer.swift', '// changed\n')
        fail = self.run_check('Protocol impact: P01, P02')
        self.assertIn('P17', fail.stdout)
        self.assertIn('P20', fail.stdout)
        self.assertEqual(fail.returncode, 1)


if __name__ == '__main__':
    unittest.main()
