#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check a PR Protocol impact declaration against merge-base-to-worktree changes.

Includes staged, unstaged, untracked, deleted and both sides of renamed paths.
Content predicates examine old AND new file contents so deleting a bridge call
still triggers it. This checks declaration coverage, not the truth of a justified
'none'; reviewers still assess its reason and the actual contract delta.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'spec/tools'))
from registry_check import SpecError, lint_schema, load_json, path_matches, validate_json


def git(root, *args, allow_missing=False):
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True)
    if result.returncode and not allow_missing:
        raise SpecError('git failed: ' + result.stderr.decode('utf-8', 'replace').strip())
    return result.stdout if not result.returncode else b''


def base_commit(root, ref):
    if ref.startswith('-') or '\n' in ref:
        raise SpecError('invalid base ref')
    return git(root, 'rev-parse', '--verify', ref + '^{commit}').decode().strip()


def comparison_base(root, ref):
    """Use the common ancestor, matching a three-dot PR diff's left endpoint."""
    resolved = base_commit(root, ref)
    return git(root, 'merge-base', resolved, 'HEAD').decode().strip()


def load_contracts(root):
    data = load_json(root / 'spec/registry.json')
    if type(data.get('format_version')) is not int or data['format_version'] != 1:
        raise SpecError('unsupported registry format')
    lint_schema(data['schema'])
    validate_json(data['contracts'], data['schema'], 'registry contracts')
    ids = [c['id'] for c in data['contracts']]
    if len(ids) != len(set(ids)):
        raise SpecError('duplicate registry IDs')
    return data['contracts']


def changed_paths(root, base):
    tracked = git(root, 'diff', '--no-renames', '--name-only', '-z', base, '--')
    untracked = git(root, 'ls-files', '--others', '--exclude-standard', '-z')
    return sorted({p.decode('utf-8') for p in (tracked + untracked).split(b'\0') if p})


def file_versions(root, base, path):
    before = git(root, 'show', base + ':' + path, allow_missing=True)
    current = root / path
    if not current.resolve().is_relative_to(root):
        raise SpecError('changed path escapes repository: ' + path)
    after = current.read_bytes() if current.is_file() else b''
    return before.decode('utf-8', 'replace'), after.decode('utf-8', 'replace')


def triggered_contracts(root, base, contracts, paths):
    hits = {}
    contents = {}
    for path in paths:
        for contract in contracts:
            for trigger in contract['triggers']:
                if not path_matches(path, trigger['glob']):
                    continue
                if any(path_matches(path, p) for p in trigger.get('exclude', [])):
                    continue
                if trigger.get('contains_any'):
                    if path not in contents:
                        contents[path] = file_versions(root, base, path)
                    if not any(token in value for token in trigger['contains_any'] for value in contents[path]):
                        continue
                hits.setdefault(contract['id'], set()).add(path)
                break
    return hits


def none_reason(value):
    match = re.fullmatch(r'none\s*(?:—|–|-|:)\s*(.+)', value, re.IGNORECASE)
    if not match or not any(c.isalnum() for c in match[1]):
        raise SpecError('none requires a reason')
    return match[1].strip()


def check_declaration(body, triggered, known):
    # Accept the inline-code label in the repository PR template as well as plain text.
    lines = re.findall(r'^[ \t]*`?Protocol impact:`?[ \t]*(.*?)[ \t]*$', body, re.MULTILINE | re.IGNORECASE)
    if len(lines) != 1:
        raise SpecError('exactly one Protocol impact: line is required')
    value = lines[0].strip('` ')
    if re.match(r'^none\b', value, re.IGNORECASE):
        if triggered:
            raise SpecError('global none cannot cover triggered IDs: ' + ', '.join(sorted(triggered)))
        # Semicolons delimit declarations, never part of a global-none reason.
        if ';' in value:
            raise SpecError('global none cannot be mixed with contract declarations')
        return 'none — ' + none_reason(value)
    declared = {}
    for clause in value.split(';'):
        clause = clause.strip()
        scoped_none = re.fullmatch(r'(P\d{2})\s*:\s*(none\b.*)', clause, re.IGNORECASE)
        if scoped_none:
            items = [scoped_none[1].upper()]
            description = 'none — ' + none_reason(scoped_none[2])
        elif re.fullmatch(r'P\d{2}(?:\s*,\s*P\d{2})*', clause):
            items = [item.strip() for item in clause.split(',')]
            description = 'affected'
        else:
            raise SpecError('invalid impact clause; use P01, P02; P09: none — reason')
        for ident in items:
            if ident not in known:
                raise SpecError('unknown contract ID ' + ident)
            if ident in declared:
                raise SpecError('duplicate/contradictory declaration for ' + ident)
            declared[ident] = description
    missing = set(triggered) - set(declared)
    if missing:
        raise SpecError('Protocol impact missing ' + ', '.join(sorted(missing)))
    return '; '.join(ident if description == 'affected' else ident + ': ' + description
                     for ident, description in sorted(declared.items()))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.', help='repository root')
    parser.add_argument('--base', required=True, help='ref whose merge-base with HEAD is compared with the working tree')
    parser.add_argument('--body-file', type=Path, required=True, help='UTF-8 PR/task body')
    args = parser.parse_args(argv)
    try:
        root = Path(args.root).resolve()
        base = comparison_base(root, args.base)
        contracts = load_contracts(root)
        paths = changed_paths(root, base)
        hits = triggered_contracts(root, base, contracts, paths)
        for ident in sorted(hits):
            print(ident + ': ' + ', '.join(sorted(hits[ident])))
        declaration = check_declaration(args.body_file.read_text(encoding='utf-8'), hits,
                                        [c['id'] for c in contracts])
        print('PASS protocol impact: {}; {} triggered ID(s), {} changed path(s)'.format(declaration, len(hits), len(paths)))
        return 0
    except (SpecError, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        print('FAIL protocol impact: ' + str(exc))
        return 1


if __name__ == '__main__':
    sys.exit(main())
