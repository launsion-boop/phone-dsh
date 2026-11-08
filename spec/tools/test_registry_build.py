#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutate the registry/source and exercise the real deterministic builder CLI."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry_build

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'spec/tools/registry_build.py'


class RegistryBuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'spec').mkdir()
        self.baseline = self.root / 'spec/README.md'
        self.target = self.root / 'spec/registry.json'
        self.baseline.write_bytes((ROOT / 'spec/README.md').read_bytes())
        self.original = (ROOT / 'spec/registry.json').read_bytes()
        self.target.write_bytes(self.original)

    def run_builder(self, mode):
        return subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), mode],
                              capture_output=True, text=True)

    def assert_stale(self):
        before = self.target.read_bytes()
        result = self.run_builder('--check')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FAIL registry build:', result.stdout)
        self.assertEqual(self.target.read_bytes(), before, '--check must not repair files')

    def test_real_registry_is_reproducible(self):
        self.assertEqual(registry_build.build_registry(ROOT), (ROOT / 'spec/registry.json').read_bytes())
        # No implementation files or external evidence are present in this fixture.
        self.assertEqual(self.run_builder('--check').returncode, 0)

    def test_missing_output_check_fails_and_write_recreates_it(self):
        self.target.unlink()
        self.assertEqual(self.run_builder('--check').returncode, 1)
        self.assertFalse(self.target.exists())
        self.assertEqual(self.run_builder('--write').returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(self.run_builder('--check').returncode, 0)
        self.assertEqual(self.run_builder('--write').returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_manual_path_projection_edit_is_detected(self):
        data = json.loads(self.original)
        data['contracts'][0]['authority'] = ['spec/v1/README.md']
        self.target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        self.assert_stale()

    def test_embedded_schema_edit_is_detected(self):
        data = json.loads(self.original)
        data['schema']['items']['required'] = []
        self.target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        self.assert_stale()

    def test_semantically_equal_reformatting_fails_byte_check(self):
        data = json.loads(self.original)
        self.target.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True) + '\n')
        self.assertEqual(json.loads(self.target.read_bytes()), json.loads(self.original))
        self.assert_stale()
        self.assertEqual(self.run_builder('--write').returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_final_newline_is_part_of_the_artifact(self):
        self.target.write_bytes(self.original.rstrip(b'\n'))
        self.assert_stale()

    def test_source_cell_change_requires_regeneration(self):
        old = self.baseline.read_text()
        changed = old.replace('[v1/channel.md](v1/channel.md)', '[channel authority](v1/channel.md)', 1)
        self.assertNotEqual(old, changed)
        self.baseline.write_text(changed)
        self.assert_stale()
        self.assertEqual(self.run_builder('--write').returncode, 0)
        self.assertIn('[channel authority]', json.loads(self.target.read_bytes())['contracts'][0]['source']['authority'])
        self.assertEqual(self.run_builder('--check').returncode, 0)

    def test_trigger_change_is_regenerated_from_section_four(self):
        old = self.baseline.read_text()
        changed = old.replace('`spec/v1/{channel.md,README.md}`', '`spec/v1/{channel.md,README.md,bridge.md}`', 1)
        self.assertNotEqual(old, changed)
        self.baseline.write_text(changed)
        self.assert_stale()
        self.assertEqual(self.run_builder('--write').returncode, 0)
        first = json.loads(self.target.read_bytes())['contracts'][0]
        self.assertEqual(first['triggers'][0]['glob'], 'spec/v1/{channel.md,README.md,bridge.md}')

    def test_unknown_id_requires_explicit_projection_metadata(self):
        self.baseline.write_text(self.baseline.read_text().replace('| P22', '| P99'))
        before = self.target.read_bytes()
        result = self.run_builder('--write')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('same IDs', result.stdout)
        self.assertEqual(self.target.read_bytes(), before)

    def test_deleted_row_is_not_silently_dropped(self):
        self.baseline.write_text('\n'.join(line for line in self.baseline.read_text().splitlines()
                                           if not line.startswith('| P22')) + '\n')
        self.assertEqual(self.run_builder('--check').returncode, 1)
        self.assertEqual(self.run_builder('--write').returncode, 1)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_write_does_not_use_existing_json_as_input(self):
        self.target.write_bytes(b'not JSON at all\n')
        self.assertEqual(self.run_builder('--write').returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
