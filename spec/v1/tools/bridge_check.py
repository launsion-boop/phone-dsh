#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Golden-vector checker for the page-host bridge of spec/v1/bridge.md.

Every vector in ``golden/bridge`` is validated against
``schema/bridge-message.schema.json`` with the JSON Schema subset validator imported from
``spec_golden.py`` (the specification keeps exactly one definition of that subset). A single vector
cannot express the invariants that tie messages together, so they are checked per sequence here:

* a ``response`` or ``error`` must name a request of the same sequence, must come after it and must
  echo its ``method``;
* ``result`` and ``error`` are never carried together, and one request gets one terminal at most;
* one ``requestId`` is requested at most once per sequence;
* a ``oneway`` is never answered, and an uncorrelated refusal is never invented.

``bridge.md`` itself is checked for its line cap and for the referenced schema name.

Usage:
    python3 spec/v1/tools/bridge_check.py [--root DIR]

Exit code 0 on success, 1 on any mismatch, 2 on a usage or I/O error.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import re
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

from spec_golden import Reporter, SpecError, load_json, validate_json  # noqa: E402

SCHEMA_NAME = "bridge-message.schema.json"
SCHEMA_DIR = "schema"
VECTOR_DIR = "golden/bridge"
DOC_NAME = "bridge.md"
DOC_LINE_CAP = 200
MINIMUM_VECTORS = 8

VECTOR_MEMBERS = frozenset({"name", "direction", "schema", "instance", "notes"})
MESSAGE_DIRECTIONS = ("page-to-host", "host-to-page")
DIRECTIONS = MESSAGE_DIRECTIONS + ("sequence",)
KINDS_BY_DIRECTION = {
    "page-to-host": ("request", "oneway"),
    "host-to-page": ("response", "error", "oneway"),
}
MAX_SEQUENCE_ENTRIES = 32

# Caps fixed by bridge.md 4.
MAX_REQUEST_BYTES = 256 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_BINARY_BYTES = 512 * 1024
MAX_BASE64_CHARS = 4 * ((MAX_BINARY_BYTES + 2) // 3)

BASE64_RE = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")
RETRYABLE_CODES = frozenset({
    "BRIDGE_TIMEOUT",
    "BRIDGE_BUSY",
    "BRIDGE_UNAVAILABLE",
})
EXPECTED_KINDS = frozenset({"request", "oneway", "response", "error"})

JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"
ALLOWED_KEYWORDS = frozenset({
    "$schema",
    "title",
    "description",
    "type",
    "properties",
    "required",
    "additionalProperties",
    "items",
    "enum",
    "const",
    "oneOf",
    "pattern",
    "minimum",
    "maximum",
    "minLength",
    "maxLength",
    "minItems",
    "maxItems",
    "dependentRequired",
})


# ---------------------------------------------------------------------------
# Schema self-containment.
# ---------------------------------------------------------------------------


def walk_schema(node, where):
    """Assert that *node* only uses the supported JSON Schema subset."""
    if not isinstance(node, dict):
        raise SpecError("{}: schema node is not an object".format(where))
    for key in node:
        if key not in ALLOWED_KEYWORDS:
            raise SpecError("{}: keyword {!r} is outside the supported subset".format(where, key))
    if "pattern" in node:
        pattern = node["pattern"]
        if not isinstance(pattern, str):
            raise SpecError("{}.pattern: pattern is not a string".format(where))
        try:
            re.compile(pattern)
        except re.error as exc:
            raise SpecError("{}.pattern: invalid regular expression: {}".format(where, exc)) from exc
    properties = node.get("properties")
    if properties is not None:
        if not isinstance(properties, dict):
            raise SpecError("{}.properties: not an object".format(where))
        for name, sub in properties.items():
            walk_schema(sub, "{}.properties.{}".format(where, name))
    if "items" in node:
        if isinstance(node["items"], list):
            raise SpecError("{}.items: tuple validation is outside the subset".format(where))
        walk_schema(node["items"], where + ".items")
    additional = node.get("additionalProperties")
    if isinstance(additional, dict):
        walk_schema(additional, where + ".additionalProperties")
    if "oneOf" in node:
        variants = node["oneOf"]
        if not isinstance(variants, list) or not variants:
            raise SpecError("{}.oneOf: must be a non-empty list".format(where))
        for index, sub in enumerate(variants):
            walk_schema(sub, "{}.oneOf[{}]".format(where, index))
    if "dependentRequired" in node:
        table = node["dependentRequired"]
        if not isinstance(table, dict):
            raise SpecError("{}.dependentRequired: not an object".format(where))
        for name, needed in table.items():
            if not isinstance(needed, list) or not all(isinstance(item, str) for item in needed):
                raise SpecError("{}.dependentRequired.{}: must be a list of strings".format(where, name))


def load_schema(spec_dir, rep):
    """Load and self-check ``schema/bridge-message.schema.json``."""
    rel = SCHEMA_DIR + "/" + SCHEMA_NAME
    rep.add(rel)
    path = spec_dir / SCHEMA_DIR / SCHEMA_NAME
    if not path.is_file():
        rep.fail(rel, "schema file is missing")
        return None
    try:
        schema = load_json(path)
    except SpecError as exc:
        rep.fail(rel, str(exc))
        return None
    try:
        if not isinstance(schema, dict):
            raise SpecError("schema is not an object")
        if schema.get("$schema") != JSON_SCHEMA_DIALECT:
            raise SpecError("$schema is not JSON Schema 2020-12")
        walk_schema(schema, "$")
        variants = schema.get("oneOf")
        if not isinstance(variants, list) or len(variants) != 4:
            raise SpecError("the root must be a oneOf of four message kinds")
        kinds = set()
        for variant in variants:
            kind = variant.get("properties", {}).get("kind", {}).get("const")
            if kind not in EXPECTED_KINDS:
                raise SpecError("a oneOf variant does not pin a known kind")
            kinds.add(kind)
        if kinds != EXPECTED_KINDS:
            raise SpecError(
                "the oneOf variants must pin kinds {}".format(sorted(EXPECTED_KINDS)))
    except SpecError as exc:
        rep.fail(rel, str(exc))
        return None
    return schema


# ---------------------------------------------------------------------------
# One message.
# ---------------------------------------------------------------------------


def canonical_size(value, where):
    """Return the UTF-8 byte length of the compact JSON form of *value*."""
    try:
        return len(json.dumps(value, sort_keys=True, separators=(",", ":"),
                              ensure_ascii=False, allow_nan=False).encode("utf-8"))
    except (TypeError, ValueError) as exc:
        raise SpecError("{}: not JSON-serialisable: {}".format(where, exc)) from exc


def check_binary(value, where):
    """Validate the base64 envelope of bridge.md 4 anywhere inside a result."""
    if isinstance(value, dict):
        if "encoding" not in value:
            for name, item in value.items():
                check_binary(item, "{}.{}".format(where, name))
            return
        if set(value) != {"encoding", "data"}:
            raise SpecError("{}: a binary value has exactly encoding and data".format(where))
        if value["encoding"] != "base64":
            raise SpecError("{}: encoding is reserved for the base64 marker".format(where))
        data = value["data"]
        if not isinstance(data, str) or not data:
            raise SpecError("{}: data must be a non-empty base64 string".format(where))
        if len(data) % 4 != 0 or BASE64_RE.fullmatch(data) is None:
            raise SpecError("{}: data is not padded standard base64".format(where))
        if len(data) > MAX_BASE64_CHARS:
            raise SpecError(
                "{}: data has {} characters, above the {} of the 512 KiB cap".format(
                    where, len(data), MAX_BASE64_CHARS))
        try:
            raw = base64.b64decode(data, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise SpecError("{}: data is not base64: {}".format(where, exc)) from exc
        if len(raw) > MAX_BINARY_BYTES:
            raise SpecError(
                "{}: data decodes to {} bytes, above the 512 KiB cap".format(where, len(raw)))
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            check_binary(item, "{}[{}]".format(where, index))


def check_error(error, where):
    if not isinstance(error, dict):
        raise SpecError("{}: error is not an object".format(where))
    code = error.get("code")
    if error.get("retryable") is True and code not in RETRYABLE_CODES:
        raise SpecError("{}: code {} is not retryable".format(where, code))


def check_instance(instance, direction, schema, where):
    """Check one message: shape, kind/direction, schema, caps, binary, retry flag."""
    if not isinstance(instance, dict):
        raise SpecError("{}: a bridge message is a JSON object".format(where))
    if "result" in instance and "error" in instance:
        raise SpecError("{}: a message must not carry both result and error".format(where))
    kind = instance.get("kind")
    allowed = KINDS_BY_DIRECTION[direction]
    if kind not in allowed:
        raise SpecError("{}: kind {!r} is not allowed in direction {} (allowed: {})".format(
            where, kind, direction, ", ".join(allowed)))
    validate_json(instance, schema, where)
    cap = MAX_REQUEST_BYTES if kind in ("request", "oneway") else MAX_RESPONSE_BYTES
    size = canonical_size(instance, where)
    if size > cap:
        raise SpecError("{}: serialised size {} exceeds the {} byte cap of {}".format(
            where, size, cap, kind))
    if "error" in instance:
        check_error(instance["error"], where + ".error")
    if "result" in instance:
        check_binary(instance["result"], where + ".result")


# ---------------------------------------------------------------------------
# One vector: entries plus the cross-message invariants.
# ---------------------------------------------------------------------------


def vector_entries(doc):
    """Return ``[(direction, instance)]`` for a single-message or sequence vector."""
    direction = doc["direction"]
    instance = doc["instance"]
    if direction != "sequence":
        return [(direction, instance)]
    if not isinstance(instance, list) or not instance:
        raise SpecError("a sequence vector is a non-empty list of {direction, instance} entries")
    if len(instance) > MAX_SEQUENCE_ENTRIES:
        raise SpecError("a sequence vector holds at most {} entries".format(MAX_SEQUENCE_ENTRIES))
    entries = []
    for index, entry in enumerate(instance):
        if not isinstance(entry, dict) or set(entry) != {"direction", "instance"}:
            raise SpecError(
                "sequence entry[{}] must be exactly {{direction, instance}}".format(index))
        if entry["direction"] not in MESSAGE_DIRECTIONS:
            raise SpecError("sequence entry[{}] direction {!r} is not a message direction".format(
                index, entry["direction"]))
        entries.append((entry["direction"], entry["instance"]))
    return entries


def check_sequence(entries, rel):
    """Enforce the invariants that span messages of one sequence."""
    requests = {}
    terminals = {}
    saw_oneway = False
    for index, (_, instance) in enumerate(entries):
        kind = instance.get("kind") if isinstance(instance, dict) else None
        if kind == "oneway":
            saw_oneway = True
        if kind != "request":
            continue
        request_id = instance["requestId"]
        if request_id in requests:
            raise SpecError("{}: duplicate requestId {!r} in one sequence".format(rel, request_id))
        requests[request_id] = (index, instance["method"])
    for index, (_, instance) in enumerate(entries):
        kind = instance.get("kind") if isinstance(instance, dict) else None
        if kind not in ("response", "error"):
            continue
        request_id = instance["requestId"]
        if request_id not in requests:
            if saw_oneway and not requests:
                raise SpecError(
                    "{}: entry[{}] answers {!r}, but a oneway message must not be answered".format(
                        rel, index, request_id))
            raise SpecError("{}: entry[{}] {} has no request in this sequence".format(
                rel, index, kind))
        request_index, request_method = requests[request_id]
        if request_index > index:
            raise SpecError("{}: entry[{}] terminal precedes its request {!r}".format(
                rel, index, request_id))
        if request_id in terminals:
            raise SpecError("{}: requestId {!r} has more than one terminal".format(
                rel, request_id))
        terminals[request_id] = kind
        if instance["method"] != request_method:
            raise SpecError(
                "{}: entry[{}] method {!r} does not match the request method {!r}".format(
                    rel, index, instance["method"], request_method))


def check_vector(path, spec_dir, rep, schema, names):
    rel = str(path.relative_to(spec_dir))
    rep.add(rel)
    try:
        doc = load_json(path)
        if not isinstance(doc, dict):
            raise SpecError("vector is not a JSON object")
        if set(doc) != VECTOR_MEMBERS:
            raise SpecError("vector members must be exactly name/direction/schema/instance/notes")
        name = doc["name"]
        if not isinstance(name, str) or not name:
            raise SpecError("name is not a non-empty string")
        if name in names:
            raise SpecError("duplicate vector name {!r}, already used by {}".format(name, names[name]))
        names[name] = rel
        if path.stem != name:
            raise SpecError("file name {!r} must equal the vector name {!r}".format(path.stem, name))
        if doc["direction"] not in DIRECTIONS:
            raise SpecError("direction {!r} is not one of {}".format(doc["direction"], DIRECTIONS))
        if doc["schema"] != SCHEMA_NAME:
            raise SpecError("schema must be {!r}".format(SCHEMA_NAME))
        notes = doc["notes"]
        if not isinstance(notes, str) or not notes.strip():
            raise SpecError("notes must cite a file:line or a bridge.md section")
        entries = vector_entries(doc)
        for index, (direction, instance) in enumerate(entries):
            check_instance(instance, direction, schema, "{} entry[{}]".format(rel, index))
        check_sequence(entries, rel)
    except SpecError as exc:
        rep.fail(rel, str(exc))


def check_vectors(spec_dir, rep, schema):
    vector_dir = spec_dir / VECTOR_DIR
    paths = sorted(vector_dir.glob("*.json")) if vector_dir.is_dir() else []
    if len(paths) < MINIMUM_VECTORS:
        rep.add(VECTOR_DIR)
        rep.fail(VECTOR_DIR, "at least {} bridge vectors are required, found {}".format(
            MINIMUM_VECTORS, len(paths)))
    names = {}
    for path in paths:
        check_vector(path, spec_dir, rep, schema, names)


# ---------------------------------------------------------------------------
# The document.
# ---------------------------------------------------------------------------


def check_doc(spec_dir, rep):
    rep.add(DOC_NAME)
    path = spec_dir / DOC_NAME
    if not path.is_file():
        rep.fail(DOC_NAME, "bridge.md is missing")
        return
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        rep.fail(DOC_NAME, "cannot read: {}".format(exc))
        return
    lines = len(text.splitlines())
    if lines > DOC_LINE_CAP:
        rep.fail(DOC_NAME, "{} lines exceeds the {} line cap".format(lines, DOC_LINE_CAP))
    for needle in (SCHEMA_DIR + "/" + SCHEMA_NAME, "channel.md", "requestId"):
        if needle not in text:
            rep.fail(DOC_NAME, "does not mention {!r}".format(needle))


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description="page-host bridge golden checker")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[3],
        help="repository root containing spec/v1 (default: the checkout of this script)")
    args = parser.parse_args(argv)
    spec_dir = (args.root / "spec" / "v1").resolve()
    if not spec_dir.is_dir():
        print("error: {} is not a directory".format(spec_dir), file=sys.stderr)
        return 2
    rep = Reporter()
    schema = load_schema(spec_dir, rep)
    if schema is not None:
        check_vectors(spec_dir, rep, schema)
    check_doc(spec_dir, rep)
    errors = rep.emit()
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
