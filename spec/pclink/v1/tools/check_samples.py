#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the PCLink v1 schema samples and the workspace/1 endpoint inventory.

This checker uses the repository's existing JSON-Schema subset validator
(spec/v1/tools/spec_golden.py) rather than a second implementation.  It also
independently re-checks the §2.3 ``json_boundary`` rows: strict wire JSON rejects
a literal NUL/BOM/duplicate/lone-surrogate/non-object root, a legal escaped
``\\u0000`` in a carried DSH value is preserved, and a PCLink-owned field
containing U+0000 is still rejected.  It does not verify cryptography:
``vectors.mjs --check`` owns the shared crypto vectors.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
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


def _contains_nul(value):
    if isinstance(value, str):
        return "\x00" in value
    if isinstance(value, list):
        return any(_contains_nul(child) for child in value)
    if isinstance(value, dict):
        return any(_contains_nul(key) or _contains_nul(child) for key, child in value.items())
    return False


def check_u0000_schema_samples(samples, SpecError):
    """Require the schema samples to keep both sides of the §2.3 boundary."""
    carried = []
    pclink_field = []
    for row in samples["valid"]:
        if row["schema"] != "inner-message.schema.json":
            continue
        value = row["value"]
        nested = value.get("args") if value.get("type") == "rpc.call" else None
        if value.get("type") == "rpc.stream.item":
            nested = value.get("value")
        if value.get("type") == "rpc.result":
            nested = value.get("result")
        if nested is not None and _contains_nul(nested):
            carried.append(row["name"])
    for row in samples["invalid"]:
        if row["schema"] != "inner-message.schema.json":
            continue
        value = row["value"]
        if _contains_nul(value.get("name")) or _contains_nul(value.get("peerName")):
            pclink_field.append(row["name"])
    if not carried:
        raise SpecError("schema samples have no valid carried DSH value with U+0000")
    if not pclink_field:
        raise SpecError("schema samples have no invalid PCLink field with U+0000")
    return len(carried), len(pclink_field)


def _object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate member %r" % (key,))
        result[key] = value
    return result


def _reject_json_constant(text):
    raise ValueError("non-finite number %s" % text)


def _assert_no_lone_surrogates(value):
    if isinstance(value, str):
        for char in value:
            if 0xD800 <= ord(char) <= 0xDFFF:
                raise ValueError("lone surrogate U+%04X" % ord(char))
    elif isinstance(value, list):
        for child in value:
            _assert_no_lone_surrogates(child)
    elif isinstance(value, dict):
        for key, child in value.items():
            _assert_no_lone_surrogates(key)
            _assert_no_lone_surrogates(child)


def parse_strict_wire(text, require_object=True):
    """Independent §2.3 wire reader: no literal NUL/BOM/duplicate/lone surrogate."""
    if not isinstance(text, str):
        raise ValueError("wire JSON is not text")
    if text == "":
        raise ValueError("empty wire JSON")
    if text.startswith("\ufeff"):
        raise ValueError("BOM is not allowed")
    if "\x00" in text:
        raise ValueError("literal NUL is not allowed")
    try:
        text.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise ValueError("invalid UTF-8: %s" % exc) from exc
    try:
        value = json.loads(
            text,
            object_pairs_hook=_object_without_duplicates,
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, ValueError) as exc:
        raise ValueError(str(exc)) from exc
    _assert_no_lone_surrogates(value)
    if require_object and not isinstance(value, dict):
        raise ValueError("JSON root must be an object")
    return value


def _wire_text(row):
    if "wire_hex" in row:
        raw = bytes.fromhex(row["wire_hex"])
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("wire_hex is not UTF-8: %s" % exc) from exc
    return row["wire"]


def _path_value(value, path):
    current = value
    for key in path:
        if isinstance(current, list) and isinstance(key, int) and 0 <= key < len(current):
            current = current[key]
        elif isinstance(current, dict) and key in current:
            current = current[key]
        else:
            raise ValueError("wire path %r is missing" % (path,))
    return current


def _require_nul(value, path):
    target = _path_value(value, path)
    if not isinstance(target, str) or "\x00" not in target:
        raise ValueError("decoded U+0000 was not preserved at %r" % (path,))


def _decode_b64url(text):
    if not isinstance(text, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", text):
        raise ValueError("not base64url")
    raw = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    if base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii") != text:
        raise ValueError("non-canonical base64url")
    return raw


def _field_rejects(rule, value):
    if rule == "name":
        try:
            check_display_name(value, "json_boundary")
        except ValueError:
            return True
        return False
    if rule == "machineId":
        return not (isinstance(value, str) and re.fullmatch(r"[a-z2-7]{26}", value))
    raise ValueError("unknown PCLink field rule %r" % rule)


def check_json_boundary(spec_root, inner_schema, validate_json, SpecError):
    """Re-check the §2.3 wire/carried rows with an independent reader."""
    golden = load_json(spec_root / "golden" / "pclink-v1-vectors.json")
    boundary = golden.get("json_boundary")
    if not isinstance(boundary, dict):
        raise SpecError("pclink-v1-vectors.json has no json_boundary section")
    passthrough = set(boundary.get("passthrough", []))
    accepted = boundary.get("accepted")
    rejected = boundary.get("rejected")
    if not isinstance(accepted, list) or not isinstance(rejected, list):
        raise SpecError("json_boundary needs accepted/rejected arrays")
    cases = set()
    for row in accepted:
        cases.add(row.get("case"))
        if row.get("expected") != "accept":
            raise SpecError("json_boundary accepted row %r is not accept" % row.get("case"))
        if row.get("passthrough") not in passthrough:
            raise SpecError("json_boundary row %r names an unknown passthrough" % row.get("case"))
        text = _wire_text(row)
        value = parse_strict_wire(text, require_object=True)
        nul_paths = row.get("nul_paths", [])
        for path in nul_paths:
            _require_nul(value, path)
        chunk_paths = row.get("chunk_data_nul_paths", [])
        if chunk_paths:
            decoded_text = _decode_b64url(value["data"]).decode("utf-8")
            decoded = parse_strict_wire(decoded_text, require_object=False)
            for path in chunk_paths:
                _require_nul(decoded, path)
        # The accepted rows must exercise the escaped spelling, not a raw NUL.
        if nul_paths and "\\u0000" not in text.lower():
            raise SpecError("json_boundary row %r does not use an escaped \\u0000" % row.get("case"))
        if chunk_paths and "\\u0000" not in decoded_text.lower():
            raise SpecError("json_boundary chunk row %r does not use an escaped \\u0000" % row.get("case"))

    for row in rejected:
        cases.add(row.get("case"))
        if row.get("expected") != "bad_frame":
            raise SpecError("json_boundary rejected row %r is not bad_frame" % row.get("case"))
        text = _wire_text(row)
        if row.get("failure") == "field":
            try:
                value = parse_strict_wire(text, require_object=True)
            except ValueError as exc:
                raise SpecError("json_boundary %r: wire rejected before the field rule: %s"
                                % (row.get("case"), exc)) from exc
            try:
                validate_json(value, inner_schema, "json_boundary#%s" % row.get("case"))
            except SpecError:
                schema_rejected = True
            else:
                schema_rejected = False
            field_rejected = _field_rejects(row.get("field_rule"), _path_value(value, row.get("field_path")))
            if not (schema_rejected and field_rejected):
                raise SpecError("json_boundary %r: PCLink field U+0000 was accepted" % row.get("case"))
            continue
        try:
            parse_strict_wire(text, require_object=True)
        except ValueError:
            continue
        raise SpecError("json_boundary row %r: wire JSON was accepted" % row.get("case"))

    required = {
        "carried-escaped-nul-rpc-args",
        "carried-escaped-nul-stream-open-args",
        "carried-escaped-nul-rpc-result",
        "carried-escaped-nul-stream-item",
        "carried-escaped-nul-stream-chunk",
        "carried-escaped-nul-result-chunk",
        "wire-literal-nul",
        "pclink-name-escaped-nul",
    }
    missing = required - cases
    if missing:
        raise SpecError("json_boundary is missing rows: " + ", ".join(sorted(missing)))
    return len(accepted), len(rejected)


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

    u0000_valid, u0000_invalid = check_u0000_schema_samples(samples, SpecError)
    if u0000_valid < 1 or u0000_invalid < 1:
        raise SpecError("U+0000 schema sample coverage")

    boundary_accepted, boundary_rejected = check_json_boundary(
        spec_root, schemas["inner-message.schema.json"], validate_json, SpecError)

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
    return (len(schemas), len(samples["valid"]), len(samples["invalid"]),
            len(inventory["endpoints"]), boundary_accepted, boundary_rejected)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(REPO_ROOT), help="repository root")
    args = parser.parse_args(argv)
    try:
        schemas, valid, invalid, endpoints, boundary_accepted, boundary_rejected = check(Path(args.root).resolve())
    except Exception as exc:  # noqa: BLE001 - one line failure for CI
        print("FAIL PCLink schema samples: %s" % exc)
        return 1
    print("PASS PCLink schema samples: %d schemas, %d valid, %d invalid, %d endpoints, "
          "%d JSON-boundary accepts, %d JSON-boundary rejects"
          % (schemas, valid, invalid, endpoints, boundary_accepted, boundary_rejected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
