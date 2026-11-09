#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the PCLink v1 schema samples and the workspace/1 endpoint inventory.

This checker uses the repository's existing JSON-Schema subset validator
(spec/v1/tools/spec_golden.py) rather than a second implementation.  It does not
verify cryptography: ``vectors.mjs --check`` owns the shared golden vectors.
"""
from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC_ROOT = HERE.parent  # spec/pclink/v1
REPO_ROOT = SPEC_ROOT.parents[2]


def check_display_name(value, where):
    """The normative name rule the JSON-Schema subset cannot express."""
    if not isinstance(value, str):
        return
    encoded = value.encode("utf-8")
    if not 1 <= len(encoded) <= 64:
        raise ValueError("%s: name is %d UTF-8 bytes, expected 1..64" % (where, len(encoded)))
    if unicodedata.normalize("NFC", value) != value:
        raise ValueError("%s: name is not NFC-normalized" % where)
    for char in value:
        code = ord(char)
        if code < 0x20 or 0x7F <= code <= 0x9F or unicodedata.category(char) == "Cf":
            raise ValueError("%s: name contains a control/format character U+%04X" % (where, code))


def check_names(value, where="$"):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("name", "peerName"):
                check_display_name(child, "%s.%s" % (where, key))
            check_names(child, "%s.%s" % (where, key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            check_names(child, "%s[%d]" % (where, index))


def load_validator():
    tools = REPO_ROOT / "spec" / "v1" / "tools"
    sys.path.insert(0, str(tools))
    from spec_golden import SpecError, validate_json  # type: ignore
    return SpecError, validate_json


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def check(root: Path):
    SpecError, validate_json = load_validator()
    spec_root = root / "spec" / "pclink" / "v1"
    schema_dir = spec_root / "schema"
    schemas = {path.name: load_json(path) for path in sorted(schema_dir.glob("*.schema.json"))}
    if not schemas:
        raise SpecError("no PCLink v1 schemas")
    samples = load_json(spec_root / "golden" / "schema-samples.json")
    if set(samples) != {"format", "format_version", "valid", "invalid"}:
        raise SpecError("schema-samples.json has an unexpected top-level shape")
    if samples["format"] != "pclink-v1-schema-samples" or samples["format_version"] != 1:
        raise SpecError("schema-samples.json has the wrong format/version")

    seen_valid = set()
    seen_invalid = set()
    for row in samples["valid"]:
        if set(row) != {"schema", "name", "value"}:
            raise SpecError("valid sample must have schema/name/value")
        name = row["schema"]
        if name not in schemas:
            raise SpecError("valid sample names an unknown schema: " + name)
        seen_valid.add(name)
        try:
            check_names(row["value"], "%s#%s" % (name, row["name"]))
            validate_json(row["value"], schemas[name], "%s#%s" % (name, row["name"]))
        except ValueError as exc:
            raise SpecError("valid sample rejected (%s): %s" % (name, exc)) from exc
        except SpecError as exc:
            raise SpecError("valid sample rejected (%s): %s" % (name, exc)) from exc
    for row in samples["invalid"]:
        if set(row) != {"schema", "name", "value", "reason"}:
            raise SpecError("invalid sample must have schema/name/value/reason")
        name = row["schema"]
        if name not in schemas:
            raise SpecError("invalid sample names an unknown schema: " + name)
        seen_invalid.add(name)
        rejected = False
        try:
            check_names(row["value"], "%s#%s" % (name, row["name"]))
        except ValueError:
            rejected = True
        try:
            validate_json(row["value"], schemas[name], "%s#%s" % (name, row["name"]))
        except SpecError:
            rejected = True
        if not rejected:
            raise SpecError("invalid sample accepted (%s#%s): %s" % (name, row["name"], row["reason"]))

    missing = set(schemas) - seen_valid
    if missing:
        raise SpecError("schemas without a valid sample: " + ", ".join(sorted(missing)))
    missing = set(schemas) - seen_invalid
    if missing:
        raise SpecError("schemas without an invalid sample: " + ", ".join(sorted(missing)))

    inventory = load_json(spec_root / "endpoints.json")
    validate_json(inventory, schemas["endpoints.schema.json"], "endpoints.json")
    if inventory["v"] != 1 or inventory["suite"] != "workspace/1":
        raise SpecError("endpoints.json version/suite")
    if inventory["dshTestedRange"] != ">=0.2.2-rc.1 <0.3.0":
        raise SpecError("endpoints.json dshTestedRange changed")
    if inventory["defaultRetry"] != "unsafe":
        raise SpecError("endpoints.json defaultRetry must be unsafe")
    names = set()
    for endpoint in inventory["endpoints"]:
        name = endpoint["name"]
        if name in names:
            raise SpecError("duplicate endpoint " + name)
        names.add(name)
        if endpoint["kind"] == "stream" and endpoint["retry"] != "read":
            raise SpecError("%s: every v1 stream is read-only" % name)
        if endpoint["phoneOnly"] != name.startswith("phone/"):
            raise SpecError("%s: phoneOnly does not match the phone/ namespace" % name)
        for source in endpoint.get("sources", []):
            path, _, line = source.rpartition(":")
            if not path or not line.isdigit():
                raise SpecError("%s: malformed source %r" % (name, source))
            if not (root / path).is_file():
                raise SpecError("%s: source file does not exist: %s" % (name, path))
            if int(line) < 1:
                raise SpecError("%s: source line must be positive" % name)
    for required, retry in {
        "session/prompt": "idempotent",
        "$events/result": "unsafe",
        "session/follow": "read",
        "workspace/follow": "read",
        "session/list": "read",
    }.items():
        rows = [endpoint for endpoint in inventory["endpoints"] if endpoint["name"] == required]
        if not rows or rows[0]["retry"] != retry:
            raise SpecError("%s: expected retry %s" % (required, retry))
    return len(schemas), len(samples["valid"]), len(samples["invalid"]), len(inventory["endpoints"])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(REPO_ROOT), help="repository root")
    args = parser.parse_args(argv)
    try:
        schemas, valid, invalid, endpoints = check(Path(args.root).resolve())
    except Exception as exc:  # noqa: BLE001 - one line failure for CI
        print("FAIL PCLink schema samples: %s" % exc)
        return 1
    print("PASS PCLink schema samples: %d schemas, %d valid, %d invalid, %d endpoints"
          % (schemas, valid, invalid, endpoints))
    return 0


if __name__ == "__main__":
    sys.exit(main())
