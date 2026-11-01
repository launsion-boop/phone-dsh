#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Conformance checker for the host-side contract tree at ``spec/host/v1``.

The tree is the judge of the Kotlin ``:agentcore`` port: it fixes the
AgentHarness operation surface, the device seam and the host facade in a
language-neutral form. No second implementation reads it for meaning, so the
tree needs a mechanical gate:

  * every schema is linted against the keyword subset the repository validator
    implements (no ``$ref``/``$defs``, no ``anyOf``/``allOf``/``not``, no
    ``format``, no ``patternProperties``/``propertyNames``, ...); every
    ``oneOf`` variant must be a closed object that pins a required member,
    because an open variant makes matching ambiguous;
  * every golden instance is validated with ``spec_golden.validate_json``;
  * a golden may declare ``ignore_members``: the members listed there are
    removed before validation, which is the executable form of the rule that a
    contract-1 decoder ignores unknown optional members;
  * an event sequence is a list instance of ``schema/harness-event.schema.json``:
    every event must be durable (carry ``seq``), seq must be strictly
    increasing, and it must be dense from 1 unless the file declares
    ``seq_rule: sparse``; an optional ``resume`` block is checked against the
    sequence it describes;
  * every capability name of a device manifest (and every harness capability
    member) must be declared by its schema, or match the ``vendor.*``
    passthrough the device contract fixes;
  * every schema must be exercised by at least one golden;
  * the crosswalk's host-kind set must equal the schema's ``kind`` set, and the
    kind count it states must equal both: a stale "fifteen" in prose is how
    "the doc says 15, the code has 14" stays green.

One line per checked file is printed. Exit code 0 on success, 1 on any
mismatch, 2 on a usage or I/O error.

Usage:
    python3 spec/host/v1/tools/host_check.py [--root DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

# spec/host/v1/tools/host_check.py -> spec/host/v1 -> spec/host -> spec -> repo root
TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
CONTRACT_DIR = os.path.dirname(TOOLS_DIR)
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(CONTRACT_DIR)))

# The repository validator is the only judge of schema conformance; this tool
# never re-implements it. The import is after the path fix by design.
sys.path.insert(0, os.path.join(REPO_ROOT, "spec/v1/tools"))
from spec_golden import Reporter, SpecError, load_json, validate_json  # noqa: E402

SCHEMA_DIR = "schema"
GOLDEN_DIR = "golden"
SCHEMA_SUFFIX = ".schema.json"
HARNESS_CAPABILITIES = "schema/harness-capabilities.schema.json"
DEVICE_CAPABILITIES = "schema/device-capabilities.schema.json"
DEVICE_ENVELOPE = "schema/device-envelope.schema.json"
HARNESS_EVENT = "schema/harness-event.schema.json"
EVENT_KINDS_DOC = "event-kinds.md"
README_DOC = "README.md"
TRAJECTORY_GOLDEN = "spec/v1/golden/trajectory"
GOLDEN_VALUES = ("yes", "no", "folded", "none")

# A stated kind count. The crosswalk must carry the numeral claim; every
# numeral claim in the two host documents is compared with the table.
KIND_COUNT_CLAIM_RE = re.compile(r"exactly\s+(\d{1,2})\s+snake_case\s+values")
KIND_COUNT_MENTION_RE = re.compile(r"\bthe\s+(\d{1,2})\s+(?:host|event)\s+kinds\b")

# Keywords the repository validator does not implement. A schema that used one
# would validate nothing, so their presence is a failure rather than a warning.
FORBIDDEN_KEYWORDS = frozenset(
    {
        "$ref",
        "$defs",
        "$id",
        "$schema",
        "anyOf",
        "allOf",
        "not",
        "if",
        "then",
        "else",
        "format",
        "patternProperties",
        "propertyNames",
        "uniqueItems",
        "contains",
        "minProperties",
        "maxProperties",
        "exclusiveMinimum",
        "exclusiveMaximum",
        "multipleOf",
        "dependencies",
        "prefixItems",
    }
)

# Member names whose value is data, not a nested schema: never linted.
DATA_KEYWORDS = frozenset({"const", "enum", "required", "type", "title", "description"})

# Vendor extensions are the one open capability namespace: the host passes them
# through unparsed (device-adapter-contract-draft.md §5).
VENDOR_CAPABILITY_RE = re.compile(r"^vendor\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$")

SEQ_RULES = ("dense", "sparse")


# ---------------------------------------------------------------------------
# Schema lint.
# ---------------------------------------------------------------------------


def lint_schema(schema):
    """Return the problems of one schema document (an empty list when clean)."""

    if not isinstance(schema, dict):
        return ["schema root is not an object"]
    problems = []
    if not isinstance(schema.get("title"), str) or not schema["title"]:
        problems.append("schema must declare a non-empty title")
    _lint_node(schema, "$", problems)
    return problems


def _lint_node(node, path, problems):
    if isinstance(node, list):
        for index, item in enumerate(node):
            _lint_node(item, "{}[{}]".format(path, index), problems)
        return
    if not isinstance(node, dict):
        return
    for key in node:
        if key in FORBIDDEN_KEYWORDS:
            problems.append(
                "{}: unsupported keyword {!r} (the repository validator implements a fixed subset)".format(
                    path, key
                )
            )
    variants = node.get("oneOf")
    if isinstance(variants, list) and variants:
        for index, variant in enumerate(variants):
            where = "{} oneOf[{}]".format(path, index)
            if not isinstance(variant, dict):
                problems.append(where + ": variant is not an object")
                continue
            if variant.get("type") != "object":
                problems.append(where + ": variant must declare type object")
            required = variant.get("required")
            if not isinstance(required, list) or not required:
                problems.append(where + ": variant must pin at least one required member")
            if variant.get("additionalProperties") is not False:
                problems.append(
                    where + ": variant must be closed (additionalProperties false)"
                )
    for key, value in node.items():
        if key == "properties":
            if isinstance(value, dict):
                for name in value:
                    _lint_node(value[name], "{}.properties.{}".format(path, name), problems)
            continue
        if key in DATA_KEYWORDS:
            continue
        _lint_node(value, "{}.{}".format(path, key), problems)


# ---------------------------------------------------------------------------
# Capability vocabularies.
# ---------------------------------------------------------------------------


def _properties(schema):
    return schema.get("properties", {}) if isinstance(schema, dict) else {}


def capability_vocabularies(schemas):
    """Known capability names per capability schema, derived from the schema."""

    vocabularies = {}
    harness = schemas.get(HARNESS_CAPABILITIES)
    if harness is not None:
        vocabularies[HARNESS_CAPABILITIES] = set(_properties(harness))
    device = schemas.get(DEVICE_CAPABILITIES)
    if device is not None:
        manifest = _properties(device).get("capabilities", {})
        vocabularies[DEVICE_CAPABILITIES] = set(_properties(manifest))
    return vocabularies


def check_capability_names(instance, schema_rel, vocabularies, label, rep):
    known = vocabularies.get(schema_rel)
    if known is None or not isinstance(instance, dict):
        return
    if schema_rel == DEVICE_CAPABILITIES:
        manifest = instance.get("capabilities")
        if not isinstance(manifest, dict):
            return
        declared = manifest
    else:
        declared = instance
    for name in sorted(declared):
        if name in known or VENDOR_CAPABILITY_RE.match(name):
            continue
        rep.fail(
            label,
            "unknown capability name {!r}: a device capability must be declared by "
            "schema/device-capabilities.schema.json or live under vendor.<name>.*".format(name),
        )


# ---------------------------------------------------------------------------
# Cross-field rules the keyword subset cannot express.
# ---------------------------------------------------------------------------


def check_envelope_rules(instance, schema_rel, label, rep):
    if schema_rel != DEVICE_ENVELOPE or not isinstance(instance, dict):
        return
    direction = instance.get("dir")
    origin = instance.get("origin")
    if direction == "up" and origin != "device":
        rep.fail(
            label,
            "dir 'up' requires origin 'device', got {!r} (device-adapter-contract-draft.md §3)".format(
                origin
            ),
        )
    if direction == "down" and origin not in ("phone", "agent"):
        rep.fail(
            label,
            "dir 'down' requires origin 'phone' or 'agent', got {!r} "
            "(device-connector-2026-10-31.md §4.1)".format(origin),
        )


# ---------------------------------------------------------------------------
# Event-kind crosswalk (event-kinds.md) and capability provenance.
# ---------------------------------------------------------------------------


def _markdown_tables(text):
    """Every pipe table in *text*, each as a list of cell lists."""

    tables = []
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            current = None
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if current is None:
            current = []
            tables.append(current)
        current.append(cells)
    return tables


def _table_by_header(text, header):
    """The data rows of the first table whose first header cell is *header*."""

    for table in _markdown_tables(text):
        if not table or not table[0] or table[0][0] != header:
            continue
        rows = []
        for row in table[1:]:
            if row and all(set(cell) <= set("-: ") for cell in row):
                continue
            rows.append(row)
        return rows
    return None


def _backticked(cell):
    match = re.search(r"`([^`]+)`", cell)
    return match.group(1) if match else None


def parse_event_kinds(text):
    """Parse ``event-kinds.md`` into its four vocabularies.

    Returns ``(data, problems)``; ``data`` has ``host`` (kind -> projection and
    golden status), ``projection_types`` (type -> set of golden statuses),
    ``synthetic`` and ``not_projected``.  A malformed table is reported rather
    than raising, so one bad row cannot hide the other invariants.
    """

    problems = []
    host = {}

    rows = _table_by_header(text, "host kind")
    if rows is None:
        problems.append("mapping table ('| host kind | projection type | golden |') is missing")
        rows = []
    for row in rows:
        if len(row) < 3:
            problems.append("mapping table row has fewer than three cells: {!r}".format(row))
            continue
        kind = _backticked(row[0])
        projection = _backticked(row[1])
        golden = row[2].strip().strip("`")
        if kind is None:
            problems.append("mapping table host-kind cell is not backticked: {!r}".format(row[0]))
            continue
        if golden not in GOLDEN_VALUES:
            problems.append(
                "host kind {!r} has golden {!r}; expected one of {}".format(
                    kind, golden, ", ".join(GOLDEN_VALUES)
                )
            )
            continue
        if kind in host:
            problems.append("mapping table repeats host kind {!r}".format(kind))
            continue
        if (projection is None) != (golden == "none"):
            problems.append(
                "host kind {!r} must pair an absent projection type with golden 'none' "
                "and a present one with yes/no/folded; got projection={!r} golden={!r}".format(
                    kind, projection, golden
                )
            )
        host[kind] = {"projection": projection, "golden": golden}

    projection_types = {}
    for kind, entry in sorted(host.items()):
        if entry["projection"] is None:
            continue
        projection_types.setdefault(entry["projection"], set()).add(entry["golden"])

    synthetic = set()
    rows = _table_by_header(text, "synthetic type")
    if rows is None:
        problems.append("synthetic table ('| synthetic type | projected from | rule |') is missing")
        rows = []
    for row in rows:
        name = _backticked(row[0]) if row else None
        if name is None:
            problems.append("synthetic table type cell is not backticked: {!r}".format(row[:1]))
            continue
        if name in synthetic:
            problems.append("synthetic table repeats type {!r}".format(name))
        synthetic.add(name)
        if name in host:
            problems.append("synthetic type {!r} is also a host kind".format(name))

    not_projected = set()
    rows = _table_by_header(text, "type")
    if rows is None:
        problems.append("not-projected table ('| type | class | reason |') is missing")
        rows = []
    for row in rows:
        name = _backticked(row[0]) if row else None
        if name is None:
            problems.append("not-projected table type cell is not backticked: {!r}".format(row[:1]))
            continue
        if name in not_projected:
            problems.append("not-projected table repeats type {!r}".format(name))
        not_projected.add(name)
        if name in host:
            problems.append("not-projected type {!r} is also a host kind".format(name))

    for name in sorted(synthetic):
        if name in projection_types:
            problems.append("type {!r} is both synthetic and a projection type".format(name))
    for name in sorted(not_projected):
        if name in projection_types:
            problems.append("type {!r} is both not-projected and a projection type".format(name))

    return (
        {
            "host": host,
            "projection_types": projection_types,
            "synthetic": synthetic,
            "not_projected": not_projected,
        },
        problems,
    )


def _host_event_kinds(schema):
    kinds = set()
    variants = schema.get("oneOf") if isinstance(schema, dict) else None
    for variant in variants if isinstance(variants, list) else []:
        if not isinstance(variant, dict):
            continue
        properties = variant.get("properties")
        if not isinstance(properties, dict):
            continue
        declaration = properties.get("kind")
        if not isinstance(declaration, dict):
            continue
        if isinstance(declaration.get("const"), str):
            kinds.add(declaration["const"])
        values = declaration.get("enum")
        for value in values if isinstance(values, list) else []:
            if isinstance(value, str):
                kinds.add(value)
    return kinds


def _expected_projection_types(trajectory_dir, rep):
    """Types actually present in the trajectory oracle's expected rows."""

    kinds = set()
    base = Path(trajectory_dir)
    if not base.is_dir():
        rep.fail(
            EVENT_KINDS_DOC,
            "cannot read the trajectory expected rows: {} is missing".format(
                os.path.relpath(trajectory_dir)
            ),
        )
        return kinds
    files = sorted(base.rglob("*expected*.jsonl"))
    if not files:
        rep.fail(EVENT_KINDS_DOC, "no *expected*.jsonl under the trajectory golden")
        return kinds
    for path in files:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            rep.fail(EVENT_KINDS_DOC, "cannot read {} ({})".format(path, exc.strerror or exc))
            continue
        for lineno, line in enumerate(lines, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except ValueError as exc:
                rep.fail(EVENT_KINDS_DOC, "{}:{}: invalid JSON ({})".format(path, lineno, exc))
                continue
            if isinstance(row, dict) and isinstance(row.get("type"), str):
                kinds.add(row["type"])
    return kinds


def check_kind_count_claims(contract, text, count, rep):
    """The stated host-kind count must equal the table, in both host documents.

    The mapping table is the authority, but a reader quotes the prose, and a
    stale "fifteen" outlived a kind removal once already. So the crosswalk must
    state the count as a numeral in its lead sentence, and every numeral claim
    in the crosswalk and the README is compared with the set the table
    declares. Spelled-out counts are prose and are not parsed; the numeral is
    the claim this gate holds.
    """

    if KIND_COUNT_CLAIM_RE.search(text) is None:
        rep.fail(
            EVENT_KINDS_DOC,
            "the lead sentence must state the host-kind count as 'exactly <n> snake_case values'",
        )
    documents = [(EVENT_KINDS_DOC, text)]
    readme_path = os.path.join(contract, README_DOC)
    if os.path.isfile(readme_path):
        rep.add(README_DOC)
        try:
            documents.append((README_DOC, Path(readme_path).read_text(encoding="utf-8")))
        except OSError as exc:
            rep.fail(README_DOC, "cannot read ({})".format(exc.strerror or exc))
    for label, document in documents:
        for pattern in (KIND_COUNT_CLAIM_RE, KIND_COUNT_MENTION_RE):
            for match in pattern.finditer(document):
                stated = int(match.group(1))
                if stated == count:
                    continue
                rep.fail(
                    label,
                    "line {}: claims {} host kinds, but the mapping table declares {}".format(
                        document.count("\n", 0, match.start()) + 1, stated, count
                    ),
                )


def check_event_kinds_doc(contract, root, schemas, rep, trajectory_dir=None):
    """The crosswalk must match the schema, the trajectory goldens and its own count."""

    label = EVENT_KINDS_DOC
    path = os.path.join(contract, EVENT_KINDS_DOC)
    if not os.path.isfile(path):
        rep.fail(label, "missing: the three event vocabularies need one crosswalk")
        return
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        rep.fail(label, "cannot read ({})".format(exc.strerror or exc))
        return
    rep.add(label)
    data, problems = parse_event_kinds(text)
    for problem in problems:
        rep.fail(label, problem)

    schema = schemas.get(HARNESS_EVENT)
    schema_kinds = _host_event_kinds(schema) if schema is not None else set()
    if not schema_kinds:
        rep.fail(label, "{}: no event kind const/enum found".format(HARNESS_EVENT))
        return
    table_kinds = set(data["host"])
    for kind in sorted(schema_kinds - table_kinds):
        rep.fail(label, "mapping table misses host kind {!r}".format(kind))
    for kind in sorted(table_kinds - schema_kinds):
        rep.fail(label, "mapping table declares unknown host kind {!r}".format(kind))
    check_kind_count_claims(contract, text, len(table_kinds), rep)

    if trajectory_dir is None:
        if not root:
            rep.fail(label, "cannot locate the repository root that holds the trajectory golden")
            return
        trajectory_dir = os.path.join(root, TRAJECTORY_GOLDEN)
    expected = _expected_projection_types(trajectory_dir, rep)
    for name, statuses in sorted(data["projection_types"].items()):
        covered = bool(statuses & {"yes", "folded"})
        if covered and name not in expected:
            rep.fail(
                label,
                "projection type {!r} is marked golden but no expected fixture uses it".format(name),
            )
        if not covered and name in expected:
            rep.fail(
                label,
                "projection type {!r} is marked not-golden but an expected fixture uses it".format(
                    name
                ),
            )
    for name in sorted(expected - set(data["projection_types"])):
        if name in data["synthetic"] or name in data["not_projected"]:
            continue
        rep.fail(
            label,
            "expected fixture type {!r} is neither mapped, synthetic nor not-projected".format(name),
        )
    folded = sorted(name for name, statuses in data["projection_types"].items()
                    if "folded" in statuses and "yes" not in statuses)
    for name in folded:
        rep.fail(
            label,
            "projection type {!r} is only folded; it needs a row that emits the row itself".format(
                name
            ),
        )


def check_provisional_capabilities(contract, schemas, rep):
    """Every capability without a golden use must be marked provisional."""

    device = schemas.get(DEVICE_CAPABILITIES)
    if device is None:
        return
    label = DEVICE_CAPABILITIES
    manifest = _properties(device).get("capabilities", {})
    declared = _properties(manifest)
    if not declared:
        rep.fail(label, "no capability property found; the vocabulary cannot be marked")
        return

    golden_dir = Path(os.path.join(contract, GOLDEN_DIR))
    used = set()
    for path in sorted(golden_dir.glob("device-*.json")):
        try:
            wrapper = load_json(path)
        except SpecError as exc:
            rep.fail(label, str(exc))
            continue
        instance = wrapper.get("instance") if isinstance(wrapper, dict) else None
        capabilities = instance.get("capabilities") if isinstance(instance, dict) else None
        if isinstance(capabilities, dict):
            used.update(capabilities)

    for name in sorted(declared):
        declaration = declared[name]
        provisional = isinstance(declaration, dict) and declaration.get("provisional") is True
        if name.endswith(".*"):
            golden_uses = any(other.startswith(name[:-1]) for other in used)
        else:
            golden_uses = name in used
        if golden_uses and provisional:
            rep.fail(
                label,
                "capability {!r} is marked provisional but a device golden uses it".format(name),
            )
        elif not golden_uses and not provisional:
            rep.fail(
                label,
                "capability {!r} has no device golden and is not marked provisional".format(name),
            )


# ---------------------------------------------------------------------------
# Goldens.
# ---------------------------------------------------------------------------


def check_sequence(label, wrapper, items, schema, rep):
    if wrapper.get("schema") != HARNESS_EVENT:
        rep.fail(label, "an instance list is only defined for " + HARNESS_EVENT)
        return
    rule = wrapper.get("seq_rule", "dense")
    if rule not in SEQ_RULES:
        rep.fail(label, "seq_rule must be one of {} , got {!r}".format(SEQ_RULES, rule))
        return
    sessions = set()
    seqs = []
    for index, item in enumerate(items):
        where = "{}: event {}".format(label, index + 1)
        try:
            validate_json(item, schema, where)
        except SpecError as exc:
            rep.fail(label, str(exc))
            continue
        if not isinstance(item, dict):
            continue
        sessions.add(item.get("session_id"))
        seq = item.get("seq")
        if not isinstance(seq, int) or isinstance(seq, bool):
            rep.fail(label, "event {} is not durable: it carries no seq".format(index + 1))
            continue
        seqs.append((index + 1, seq))
    if len(sessions) > 1:
        rep.fail(label, "sequence mixes sessions: {}".format(sorted(str(s) for s in sessions)))
    if not seqs:
        rep.fail(label, "sequence carries no durable event")
        return
    seen = {}
    previous = None
    for position, seq in seqs:
        if seq in seen:
            rep.fail(
                label,
                "duplicate durable seq {} (events {} and {})".format(seq, seen[seq], position),
            )
        seen[seq] = position
        if previous is not None and seq <= previous:
            rep.fail(label, "seq {} does not increase after {}".format(seq, previous))
        previous = seq
    if rule == "dense":
        first = seqs[0][1]
        if first != 1:
            rep.fail(label, "dense sequence must start at 1, found {}".format(first))
        for index in range(1, len(seqs)):
            before = seqs[index - 1][1]
            after = seqs[index][1]
            if after != before + 1:
                rep.fail(
                    label,
                    "dense sequence must step by 1 after seq {}, found {}".format(before, after),
                )
    resume = wrapper.get("resume")
    if resume is not None:
        _check_resume(label, resume, [seq for _position, seq in seqs], rep)


def _check_resume(label, resume, seqs, rep):
    if not isinstance(resume, dict):
        rep.fail(label, "resume must be an object")
        return
    after = resume.get("after_seq")
    expected = resume.get("expect_next_seq")
    if not isinstance(after, int) or isinstance(after, bool):
        rep.fail(label, "resume.after_seq must be an integer")
        return
    if not isinstance(expected, int) or isinstance(expected, bool):
        rep.fail(label, "resume.expect_next_seq must be an integer")
        return
    if after not in seqs:
        rep.fail(label, "resume.after_seq {} is not a seq of this sequence".format(after))
        return
    following = [seq for seq in seqs if seq > after]
    if not following:
        rep.fail(label, "resume.after_seq {} is the last seq of the sequence".format(after))
        return
    if following[0] != expected:
        rep.fail(
            label,
            "resume after seq {} delivers seq {}, not {}".format(after, following[0], expected),
        )


def check_golden_file(contract, rel, path, schemas, vocabularies, referenced, rep):
    try:
        wrapper = load_json(path)
    except SpecError as exc:
        rep.add(rel)
        rep.fail(rel, str(exc))
        return
    target = wrapper.get("schema") if isinstance(wrapper, dict) else None
    label = rel
    if isinstance(target, str) and target:
        label = "{} -> {}".format(rel, target)
    rep.add(label)

    if not isinstance(wrapper, dict):
        rep.fail(label, "golden is not an object")
        return
    for member in ("name", "schema", "instance", "notes"):
        if member not in wrapper:
            rep.fail(label, "missing wrapper member {!r}".format(member))
    if "schema" not in wrapper:
        return
    if not isinstance(target, str) or not target.startswith(SCHEMA_DIR + "/"):
        rep.fail(label, "schema must be a path under {}/, got {!r}".format(SCHEMA_DIR, target))
        return
    normalized = os.path.normpath(target)
    if os.path.isabs(normalized) or normalized.startswith(".."):
        rep.fail(label, "schema path escapes the contract tree: {!r}".format(target))
        return
    schema = schemas.get(normalized)
    if schema is None:
        rep.fail(label, "unknown schema {!r}".format(target))
        return
    referenced.add(normalized)

    notes = wrapper.get("notes")
    if not isinstance(notes, str) or ":" not in notes:
        rep.fail(label, "notes must cite a source as <file>:<line> or <document> §<section>")

    instance = wrapper.get("instance")
    ignore = wrapper.get("ignore_members", [])
    if not isinstance(ignore, list) or any(not isinstance(name, str) for name in ignore):
        rep.fail(label, "ignore_members must be a list of member names")
        ignore = []

    if isinstance(instance, list):
        check_sequence(label, wrapper, instance, schema, rep)
        return

    payload = instance
    if ignore:
        if not isinstance(payload, dict):
            rep.fail(label, "ignore_members is only defined for an object instance")
        else:
            payload = dict(payload)
            for member in ignore:
                if member not in payload:
                    rep.fail(
                        label,
                        "declares to ignore {!r} but the instance has no such member".format(member),
                    )
                    continue
                del payload[member]
    try:
        validate_json(payload, schema, rel)
    except SpecError as exc:
        rep.fail(label, str(exc))
    check_capability_names(payload, normalized, vocabularies, label, rep)
    check_envelope_rules(payload, normalized, label, rep)


def check_coverage(schemas, referenced, rep):
    for rel in sorted(schemas):
        if rel not in referenced:
            rep.fail(rel, "no golden instance references this schema")


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------


def _repo_root(contract):
    """The repository root above a standard ``spec/host/v1`` tree, or None."""

    candidate = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(contract))))
    return candidate if os.path.isdir(os.path.join(candidate, "spec")) else None


def check_contract(contract, root=None, trajectory_dir=None):
    """Check one contract tree and return the populated ``Reporter``."""

    schema_dir = os.path.join(contract, SCHEMA_DIR)
    golden_dir = os.path.join(contract, GOLDEN_DIR)
    if not os.path.isdir(schema_dir):
        raise SpecError("no {}/ directory under {}".format(SCHEMA_DIR, contract))
    if not os.path.isdir(golden_dir):
        raise SpecError("no {}/ directory under {}".format(GOLDEN_DIR, contract))

    rep = Reporter()
    schemas = {}
    for path in sorted(Path(schema_dir).glob("*" + SCHEMA_SUFFIX)):
        rel = "{}/{}".format(SCHEMA_DIR, path.name)
        rep.add(rel)
        try:
            schema = load_json(path)
        except SpecError as exc:
            rep.fail(rel, str(exc))
            continue
        schemas[rel] = schema
        for problem in lint_schema(schema):
            rep.fail(rel, problem)
    if not schemas:
        raise SpecError("no *{} under {}".format(SCHEMA_SUFFIX, schema_dir))

    vocabularies = capability_vocabularies(schemas)
    referenced = set()
    for path in sorted(Path(golden_dir).glob("*.json")):
        rel = "{}/{}".format(GOLDEN_DIR, path.name)
        check_golden_file(contract, rel, path, schemas, vocabularies, referenced, rep)
    check_coverage(schemas, referenced, rep)
    check_event_kinds_doc(contract, root or _repo_root(contract), schemas, rep, trajectory_dir)
    check_provisional_capabilities(contract, schemas, rep)
    return rep


def resolve_contract(root):
    """Return the contract tree under *root* (a repo root or the tree itself)."""

    root = os.path.abspath(root)
    candidate = os.path.join(root, "spec", "host", "v1")
    if os.path.isdir(os.path.join(candidate, SCHEMA_DIR)):
        return candidate
    if os.path.isdir(os.path.join(root, SCHEMA_DIR)) and os.path.isdir(
        os.path.join(root, GOLDEN_DIR)
    ):
        return root
    raise SpecError(
        "no spec/host/v1 tree under {!r}: expected {}/spec/host/v1/{}".format(
            root, root, SCHEMA_DIR
        )
    )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Validate the spec/host/v1 schemas, goldens and event sequences."
    )
    parser.add_argument(
        "--root",
        default=".",
        help="repository root (or the contract directory itself); default: .",
    )
    args = parser.parse_args(argv)
    try:
        contract = resolve_contract(args.root)
        rep = check_contract(contract, root=_repo_root(contract) or os.path.abspath(args.root))
    except SpecError as exc:
        print("host_check: {}".format(exc), file=sys.stderr)
        return 2
    errors = rep.emit()
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
