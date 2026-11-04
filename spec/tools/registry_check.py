#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the protocol registry against its embedded schema and baseline tables.

Only stdlib plus the existing spec JSON validator. Brace alternatives, path-segment
wildcards and ** (zero or more segments) are shared with the diff consumers.
Empty status means no implementation-status assertion; source retains all qualifiers.
"""
import argparse
import fnmatch
import os
import re
import sys
from functools import lru_cache
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'v1' / 'tools'))
from spec_golden import SpecError, load_json, validate_json  # noqa: E402

EXCLUDED_DIRS = {'.git', '.build', 'node_modules', 'target', 'build', 'dist', '.gradle', '__pycache__'}
SCHEMA_KEYS = {'type', 'properties', 'required', 'additionalProperties', 'items', 'minItems',
               'uniqueItems', 'minLength', 'pattern', 'enum'}


def expand_braces(pattern):
    match = re.search(r'\{([^{}]+)\}', pattern)
    if not match:
        if '{' in pattern or '}' in pattern:
            raise SpecError('invalid brace glob: ' + pattern)
        return [pattern]
    return [item for choice in match[1].split(',')
            for item in expand_braces(pattern[:match.start()] + choice + pattern[match.end():])]


def valid_path(pattern):
    if (not pattern or pattern.startswith('/') or '\\' in pattern
            or '..' in PurePosixPath(pattern).parts or any(c in pattern for c in '\n\r\0')):
        raise SpecError('not a repository-relative path: ' + repr(pattern))
    return expand_braces(pattern)


@lru_cache(maxsize=32768)
def _match_parts(parts, pattern):
    if not pattern:
        return not parts
    if pattern[0] == '**':
        return _match_parts(parts, pattern[1:]) or bool(parts and _match_parts(parts[1:], pattern))
    return bool(parts and fnmatch.fnmatchcase(parts[0], pattern[0])
                and _match_parts(parts[1:], pattern[1:]))


def path_matches(path, pattern):
    return any(_match_parts(tuple(path.split('/')), tuple(p.split('/')))
               for p in valid_path(pattern))


def repository_files(root):
    result = []
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIRS and not (Path(directory) / d).is_symlink())
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_file():
                result.append(path.relative_to(root).as_posix())
    return result


def baseline_tables(text):
    result = {}
    for number in (3, 4):
        try:
            section = text.split('## ' + str(number) + '.', 1)[1].split('\n## ', 1)[0]
        except IndexError as exc:
            raise SpecError('baseline missing section ' + str(number)) from exc
        rows = {}
        for line in section.splitlines():
            if not re.match(r'\| P\d\d\b', line):
                continue
            cells = [cell.strip() for cell in line.strip('|').split('|')]
            ident = cells[0][:3]
            if ident in rows:
                raise SpecError('duplicate baseline ID ' + ident)
            if len(cells) != (4 if number == 3 else 2):
                raise SpecError('malformed baseline table row ' + ident)
            rows[ident] = cells
        if not rows:
            raise SpecError('empty baseline section ' + str(number))
        result[number] = rows
    return result


def baseline_triggers(raw, ident):
    result = []
    for match in re.finditer(r'`([^`]+)`', raw):
        pattern = match[1]
        if '/' not in pattern:
            continue
        trigger = {'glob': pattern}
        exclude = re.match(r'（除 `([^`]+)`）', raw[match.end():])
        if exclude:
            trigger['exclude'] = [pattern.rsplit('/', 1)[0] + '/' + exclude[1]]
            if exclude[1] == 'device-*':
                trigger['exclude'] = [pattern.rsplit('/', 1)[0] + '/**/device-*']
        if '任何 `' + pattern + '` 中的' in raw:
            suffix = raw[match.end():].split('、', 1)[0]
            trigger['contains_any'] = re.findall(r'`([^`]+)`', suffix)
            if not trigger['contains_any']:
                raise SpecError(ident + ': content predicate has no tokens')
        result.append(trigger)
    return result


def lint_schema(schema):
    if not isinstance(schema, dict):
        raise SpecError('registry schema must be an object')
    unknown = set(schema) - SCHEMA_KEYS
    if unknown:
        raise SpecError('unsupported registry schema keywords: ' + ', '.join(sorted(unknown)))
    for node in schema.get('properties', {}).values():
        lint_schema(node)
    for key in ('items', 'additionalProperties'):
        if isinstance(schema.get(key), dict):
            lint_schema(schema[key])


def check_registry(root):
    root = Path(root).resolve()
    data = load_json(root / 'spec/registry.json')
    if (not isinstance(data, dict) or set(data) != {'format_version', 'schema', 'contracts'}
            or type(data['format_version']) is not int or data['format_version'] != 1):
        raise SpecError('registry requires format_version 1, schema and contracts')
    lint_schema(data['schema'])
    validate_json(data['contracts'], data['schema'], 'registry contracts')
    tables = baseline_tables((root / 'spec/README.md').read_text(encoding='utf-8'))
    ids = [entry['id'] for entry in data['contracts']]
    if len(ids) != len(set(ids)):
        raise SpecError('duplicate registry ID')
    if set(ids) != set(tables[3]) or set(ids) != set(tables[4]):
        raise SpecError('registry IDs must equal baseline sections 3 and 4')
    files = repository_files(root)
    paths_checked = 0
    for entry in data['contracts']:
        ident = entry['id']
        cells = tables[3][ident]
        source = dict(zip(('authority', 'ends', 'evidence'), cells[1:]))
        source['triggers'] = tables[4][ident][1]
        if entry['source'] != source or entry['owner_role'] != cells[0][4:]:
            raise SpecError(ident + ': registry source/owner differs from baseline section 3/4')
        if entry['triggers'] != baseline_triggers(source['triggers'], ident):
            raise SpecError(ident + ': structured triggers differ from baseline section 4')
        if not entry['ends']:
            raise SpecError(ident + ': no registered ends')
        paths = entry['authority'] + entry['evidence']
        paths += [p for end in entry['ends'].values() for p in end]
        for trigger in entry['triggers']:
            paths += [trigger['glob']] + trigger.get('exclude', [])
        for pattern in paths:
            variants = valid_path(pattern)
            if any(c in pattern for c in '*?[{'):
                matches = [p for p in files if path_matches(p, pattern)]
                if not matches:
                    raise SpecError(ident + ': empty file glob ' + pattern)
            else:
                resolved = (root / pattern).resolve()
                if not resolved.is_relative_to(root) or not resolved.exists():
                    raise SpecError(ident + ': missing/escaping path ' + pattern)
            paths_checked += 1
    return data['contracts'], paths_checked


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.')
    args = parser.parse_args(argv)
    try:
        contracts, count = check_registry(args.root)
    except (SpecError, OSError, ValueError, KeyError, TypeError) as exc:
        print('FAIL registry: ' + str(exc))
        return 1
    print('PASS registry: {} contracts, {} path/glob references; baseline sections 3/4 agree'.format(len(contracts), count))
    return 0


if __name__ == '__main__':
    sys.exit(main())
