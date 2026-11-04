#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Mutation/CLI tests: each breaking class must fail without explicit evidence."""
import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import schema_diff
ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'spec/tools/schema_diff.py'


class SchemaDiffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.path = 'spec/v1/schema/hello.schema.json'
        self.original = {'type': 'object', 'properties': {'value': {'type': 'string'},
                         'mode': {'type': 'string', 'enum': ['a', 'b']}},
                         'required': ['value'], 'additionalProperties': False}
        self.write('spec/registry.json', (ROOT / 'spec/registry.json').read_text())
        self.write_schema(self.original)
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Schema Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD').stdout.strip()

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], capture_output=True, text=True, check=True)

    def write(self, path, text):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def write_schema(self, value):
        self.write(self.path, json.dumps(value))

    def run_check(self, base=None):
        return subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--base', base or self.base],
                              capture_output=True, text=True)

    def assert_breaks(self, value, needle):
        self.write_schema(value)
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stdout)

    def test_required_added_and_removed_fail(self):
        for required in [['value', 'mode'], []]:
            changed = copy.deepcopy(self.original)
            changed['required'] = required
            self.assert_breaks(changed, 'required')

    def test_type_narrowing_and_widening_fail(self):
        for new_type in ['number', ['string', 'number']]:
            changed = copy.deepcopy(self.original)
            changed['properties']['value']['type'] = new_type
            self.assert_breaks(changed, 'type narrowed/widened')

    def test_enum_removal_and_addition_fail(self):
        for choices in [['a'], ['a', 'b', 'c']]:
            changed = copy.deepcopy(self.original)
            changed['properties']['mode']['enum'] = choices
            self.assert_breaks(changed, 'enum values')

    def test_additional_properties_flip_fails(self):
        changed = copy.deepcopy(self.original)
        changed['additionalProperties'] = True
        self.assert_breaks(changed, 'unknown-member')

    def test_property_removal_fails(self):
        changed = copy.deepcopy(self.original)
        del changed['properties']['mode']
        self.assert_breaks(changed, 'property removed')

    def test_bounds_patterns_defaults_and_refs_fail_closed(self):
        for key, value in [('minLength', 2), ('pattern', 'a.*'), ('default', 'a'), ('$ref', '#/other')]:
            changed = copy.deepcopy(self.original)
            changed['properties']['value'][key] = value
            self.assert_breaks(changed, 'keyword changed')

    def test_schema_removal_fails(self):
        (self.root / self.path).unlink()
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('schema removed', result.stdout)

    def test_optional_addition_and_annotation_are_not_breaking(self):
        changed = copy.deepcopy(self.original)
        changed['description'] = 'explanation'
        changed['properties']['optional'] = {'type': 'string', 'default': ''}
        self.write_schema(changed)
        self.assertEqual(self.run_check().returncode, 0)

    def test_reordered_sets_and_implicit_additional_true_are_equal(self):
        before = {'type': ['string', 'null'], 'enum': ['a', None]}
        after = {'type': ['null', 'string'], 'enum': [None, 'a'], 'additionalProperties': True}
        self.assertEqual(schema_diff.compare_schema(before, after), [])

    def test_unchanged_and_new_schema_pass(self):
        self.write('spec/v1/schema/new.schema.json', '{"type":"object"}')
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)

    def record(self, **overrides):
        fields = {'change': 'PC-test', 'contracts': '[P01]', 'status': 'frozen', 'breaking': 'true',
                  'base': self.base, 'version_decision': 'use next major, reject old peers explicitly'}
        fields.update(overrides)
        text = '```yaml\n' + '\n'.join(k + ': ' + v for k, v in fields.items()) + '\n```\n'
        self.write('docs/protocol-changes/test.md', text)

    def test_explicit_breaking_record_passes(self):
        self.record()
        changed = copy.deepcopy(self.original)
        changed['required'].append('mode')
        self.write_schema(changed)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('BREAKING', result.stdout)

    def test_wrong_contract_draft_missing_version_or_false_do_not_waive(self):
        changed = copy.deepcopy(self.original)
        changed['required'].append('mode')
        self.write_schema(changed)
        for fields in [{'contracts': '[P02]'}, {'breaking': 'false'}, {'status': 'draft'}, {'version_decision': ''}]:
            self.record(**fields)
            self.assertEqual(self.run_check().returncode, 1)

    def test_change_record_base_is_also_resolved_to_merge_base(self):
        self.git('checkout', '-qb', 'advanced-base')
        upstream = copy.deepcopy(self.original)
        upstream['properties']['mode']['enum'] = ['a']
        self.write_schema(upstream)
        self.git('add', '.')
        self.git('-c', 'user.name=Schema Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'base advances schema alone')
        self.git('checkout', '-qb', 'feature', self.base)
        changed = copy.deepcopy(self.original)
        changed['required'].append('mode')
        self.write_schema(changed)
        self.git('add', '.')
        self.git('-c', 'user.name=Schema Test', '-c', 'user.email=test@example.invalid',
                 'commit', '-qm', 'feature changes only required')
        self.record(base='advanced-base')
        result = self.run_check('advanced-base')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('required members', result.stdout)
        self.assertNotIn('enum values', result.stdout)

    def test_stale_base_record_does_not_waive(self):
        self.record(base='0000000000000000000000000000000000000000')
        changed = copy.deepcopy(self.original)
        changed['required'].append('mode')
        self.assert_breaks(changed, 'requires current-base')


if __name__ == '__main__':
    unittest.main()
