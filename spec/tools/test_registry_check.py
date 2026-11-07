#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation tests for the actual registry reader and baseline projection."""
import contextlib
import copy
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry_check as checker

ROOT = Path(__file__).resolve().parents[2]


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        schema = json.loads((ROOT / 'spec/registry.json').read_text())['schema']
        self.source = {'authority': '`Sources/wire.ts`', 'ends': 'TS reader',
                       'evidence': '`tests/wire.py`', 'triggers': '`Sources/**`'}
        self.entry = {'id': 'P01', 'owner_role': 'wire owner',
                      'authority': ['Sources/wire.ts'], 'ends': {'TypeScript': ['Sources/wire.ts']},
                      'triggers': [{'glob': 'Sources/**'}], 'status': [],
                      'evidence': ['tests/wire.py'], 'source': self.source}
        self.data = {'format_version': 1, 'schema': schema, 'contracts': [self.entry]}
        self.write('Sources/wire.ts', '// actual source\n')
        self.write('tests/wire.py', '# actual evidence\n')
        self.write('spec/README.md', '## 3. Registry\n| P01 wire owner | `Sources/wire.ts` | TS reader | `tests/wire.py` |\n'
                   '## 4. Triggers\n| P01 | `Sources/**` |\n## 5. Compatibility\n')
        self.save()

    def write(self, rel, value):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def save(self):
        self.write('spec/registry.json', json.dumps(self.data))

    def fails(self, needle):
        self.save()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = checker.main(['--root', str(self.root)])
        self.assertEqual(code, 1, output.getvalue())
        self.assertIn(needle, output.getvalue())

    def test_valid_registry(self):
        self.assertEqual(len(checker.check_registry(self.root)[0]), 1)

    def test_real_registry(self):
        self.assertEqual(len(checker.check_registry(ROOT)[0]), 23)

    def test_deleted_source_fails(self):
        (self.root / 'Sources/wire.ts').unlink()
        self.fails('missing/escaping path')

    def test_empty_glob_fails(self):
        self.entry['ends']['TypeScript'] = ['Sources/missing*.ts']
        self.fails('empty file glob')

    def test_extra_id_fails(self):
        extra = copy.deepcopy(self.entry)
        extra['id'] = 'P23'
        self.data['contracts'].append(extra)
        self.fails('IDs must equal')

    def test_duplicate_id_fails(self):
        self.data['contracts'].append(copy.deepcopy(self.entry))
        self.fails('duplicate registry ID')

    def test_required_field_and_types_are_checked(self):
        del self.entry['owner_role']
        self.fails('missing required member')

    def test_schema_unknown_keywords_fail(self):
        self.data['schema']['allOf'] = []
        self.fails('unsupported registry schema')

    def test_owner_and_source_drift_fail(self):
        self.entry['owner_role'] = 'other owner'
        self.fails('source/owner differs')

    def test_structured_trigger_drift_fails(self):
        self.entry['triggers'] = [{'glob': 'tests/**'}]
        self.fails('structured triggers differ')

    def test_path_escape_fails(self):
        self.entry['authority'] = ['../outside']
        self.fails('repository-relative')

    def test_braces_double_star_and_single_star(self):
        self.assertTrue(checker.path_matches('src/a.ts', 'src/**/{a,b}.ts'))
        self.assertTrue(checker.path_matches('src/deep/b.ts', 'src/**/{a,b}.ts'))
        self.assertFalse(checker.path_matches('src/deep/b.ts', 'src/*.ts'))
        self.assertTrue(checker.path_matches('src/a.ts', 'src/[ab].ts'))

    def test_exclusions_and_content_predicates_are_transcribed(self):
        raw = '`spec/host/v1/**`（除 `device-*`）'
        self.assertEqual(checker.baseline_triggers(raw, 'P06'), [
            {'glob': 'spec/host/v1/**', 'exclude': ['spec/host/v1/**/device-*']}])
        raw = '任何 `plugins/*/src/client/**` 中的 `postMessage`／`webkit.messageHandlers`'
        self.assertEqual(checker.baseline_triggers(raw, 'P04'), [
            {'glob': 'plugins/*/src/client/**', 'contains_any': ['postMessage', 'webkit.messageHandlers']}])


if __name__ == '__main__':
    unittest.main()
