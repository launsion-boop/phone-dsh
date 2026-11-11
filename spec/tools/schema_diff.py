#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Conservative schema compatibility check against a git merge-base (baseline section 5.1).

Examines spec/**/schema/*.json, including removals. Existing validation-domain
changes in either direction are breaking. Optional property additions and
annotation-only edits are not automatically breaking. Unknown changed validation
keywords fail closed. This is structural analysis, not proof of semantic equivalence.
"""
import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/ci'))
from protocol_impact import (SpecError, comparison_base, changed_paths, git, load_contracts,
                             load_json, path_matches)

SCHEMA_PATH = re.compile(r'^spec/(?:.*/)?schema/[^/]+\.json$')
ANNOTATIONS = {'title', 'description', 'examples', '$comment', 'deprecated'}
# Combinators with the same variant count compare variant-by-variant, which
# intentionally relaxes the old any-change-is-breaking rule. Known miss: oneOf
# variants can become ambiguous; see test_oneof_variant_ambiguity_is_known_limitation.
COMBINATORS = {'oneOf', 'anyOf', 'allOf'}


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


def compare_schema(old, new, pointer='$'):
    if canonical(old) == canonical(new):
        return []
    if not isinstance(old, dict) or not isinstance(new, dict):
        return [(pointer, 'schema shape/boolean changed')]
    issues = []
    old_props, new_props = old.get('properties', {}), new.get('properties', {})
    if not isinstance(old_props, dict) or not isinstance(new_props, dict):
        return [(pointer, 'malformed properties')]
    for name in sorted(set(old_props) - set(new_props)):
        issues.append((pointer + '.properties.' + name, 'property removed/renamed'))
    for name in sorted(set(old_props) & set(new_props)):
        issues += compare_schema(old_props[name], new_props[name], pointer + '.properties.' + name)
    old_type, new_type = old.get('type'), new.get('type')
    types = lambda value: set(value if isinstance(value, list) else [value])
    if types(old_type) != types(new_type):
        issues.append((pointer + '.type', 'type narrowed/widened/changed'))
    if set(old.get('required', [])) != set(new.get('required', [])):
        issues.append((pointer + '.required', 'required members added/removed'))
    if ('enum' in old or 'enum' in new) and (
            {canonical(v) for v in old.get('enum', [])} != {canonical(v) for v in new.get('enum', [])}
            or ('enum' in old) != ('enum' in new)):
        issues.append((pointer + '.enum', 'enum values added/removed (no automatic unknown-value policy)'))
    before, after = old.get('additionalProperties', True), new.get('additionalProperties', True)
    if isinstance(before, dict) and isinstance(after, dict):
        issues += compare_schema(before, after, pointer + '.additionalProperties')
    elif canonical(before) != canonical(after):
        issues.append((pointer + '.additionalProperties', 'unknown-member policy changed'))
    handled = {'properties', 'type', 'required', 'enum', 'additionalProperties'} | ANNOTATIONS
    for key in sorted((set(old) | set(new)) - handled):
        if key not in old or key not in new or canonical(old[key]) != canonical(new[key]):
            if key == 'items' and isinstance(old.get(key), dict) and isinstance(new.get(key), dict):
                issues += compare_schema(old[key], new[key], pointer + '.' + key)
            elif (key in COMBINATORS and isinstance(old.get(key), list)
                  and isinstance(new.get(key), list) and len(old[key]) == len(new[key])):
                for index, (old_variant, new_variant) in enumerate(zip(old[key], new[key])):
                    issues += compare_schema(old_variant, new_variant, f'{pointer}.{key}[{index}]')
            else:
                issues.append((pointer + '.' + key, 'validation/default/reference keyword changed'))
    return issues


def affected_contracts(path, contracts):
    return {entry['id'] for entry in contracts for trigger in entry['triggers']
            if path_matches(path, trigger['glob'])
            and not any(path_matches(path, exclude) for exclude in trigger.get('exclude', []))}


def record_summary(text):
    """Read the template's small YAML summary subset, without a YAML dependency."""
    match = re.search(r'^```ya?ml\s*\n(.*?)^```\s*$', text, re.MULTILINE | re.DOTALL)
    if not match:
        match = re.match(r'^---\s*\n(.*?)^---\s*$', text, re.MULTILINE | re.DOTALL)
    if not match:
        raise SpecError('change record needs a YAML summary block')
    fields = {}
    for line in match[1].splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        field = re.fullmatch(r'([a-z_]+):\s*(.*?)\s*', line)
        if not field or field[1] in fields:
            raise SpecError('malformed/duplicate change record summary field')
        fields[field[1]] = field[2].split(' #', 1)[0].strip().strip('\"\'')
    return fields


def authorized_contracts(root, base, changed):
    approved, reasons = set(), []
    for path in sorted(changed):
        if not re.fullmatch(r'docs/protocol-changes/[^/]+\.md', path) or not (root / path).is_file():
            continue
        try:
            fields = record_summary((root / path).read_text(encoding='utf-8'))
            if fields.get('breaking') != 'true':
                continue
            if fields.get('status') not in {'frozen', 'implemented', 'verified'}:
                raise SpecError('breaking record must be frozen or later')
            if comparison_base(root, fields.get('base', '')) != base:
                raise SpecError('breaking record merge-base does not match comparison merge-base')
            decision = fields.get('version_decision', '')
            if not any(c.isalnum() for c in decision) or '<' in decision:
                raise SpecError('breaking record requires a concrete version_decision')
            match = re.fullmatch(r'\[([^\]]+)\]', fields.get('contracts', ''))
            ids = {part.strip().strip('\"\'') for part in match[1].split(',')} if match else set()
            if not ids or any(not re.fullmatch(r'P\d{2}', ident) for ident in ids):
                raise SpecError('breaking record requires contracts: [Pxx, ...]')
            approved |= ids
        except (SpecError, OSError, ValueError) as exc:
            reasons.append(path + ': ' + str(exc))
    return approved, reasons


def check(root, ref):
    root = Path(root).resolve()
    base = comparison_base(root, ref)
    contracts = load_contracts(root)
    # A removed/renamed schema can belong to a previous registry revision.
    previous = git(root, 'show', base + ':spec/registry.json', allow_missing=True)
    if previous:
        prior = json.loads(previous)
        contracts += prior['contracts']
    base_paths = {p for p in git(root, 'ls-tree', '-r', '--name-only', base, '--', 'spec').decode().splitlines()
                  if SCHEMA_PATH.fullmatch(p)}
    current_paths = {p.relative_to(root).as_posix() for p in (root / 'spec').rglob('*.json')
                     if SCHEMA_PATH.fullmatch(p.relative_to(root).as_posix())}
    issues = []
    for path in sorted(base_paths | current_paths):
        if path not in base_paths:
            # New standalone schema has no previous accepted-input domain.
            load_json(root / path)
            continue
        if path not in current_paths:
            issues.append((path, '$', 'schema removed/renamed'))
            continue
        before = json.loads(git(root, 'show', base + ':' + path))
        after = load_json(root / path)
        issues += [(path, pointer, reason) for pointer, reason in compare_schema(before, after)]
    if not issues:
        return [], [], len(base_paths | current_paths)
    changed = changed_paths(root, base)
    approved, reasons = authorized_contracts(root, base, changed)
    errors = []
    for path in sorted({p for p, _, _ in issues}):
        ids = affected_contracts(path, contracts)
        if not ids:
            errors.append(path + ': breaking schema has no registry owner')
        elif ids - approved:
            errors.append(path + ': breaking change requires current-base frozen record, breaking: true, '
                          'version_decision and contracts ' + ', '.join(sorted(ids - approved)))
    return issues, errors + (reasons if errors else []), len(base_paths | current_paths)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.')
    parser.add_argument('--base', required=True)
    args = parser.parse_args(argv)
    try:
        issues, errors, count = check(args.root, args.base)
        for path, pointer, reason in issues:
            print('BREAKING {}#{}: {}'.format(path, pointer, reason))
        for error in errors:
            print('FAIL schema diff: ' + error)
        if errors:
            return 1
        print('PASS schema diff: {} schemas; {} breaking finding(s){}; structural check only'.format(
            count, len(issues), ' with explicit change records' if issues else ''))
        return 0
    except (SpecError, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        print('FAIL schema diff: ' + str(exc))
        return 1


if __name__ == '__main__':
    sys.exit(main())
