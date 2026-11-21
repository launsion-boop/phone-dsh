#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared-fixture checker for spec/device/v1/device-panel.md.

This file is a spec checker, not runtime conformance. It (1) pins the exact
reviewed content of both golden files, (2) validates every vector against the
JSON Schemas in spec/device/v1/schema, and (3) replays every vector through a
small reference oracle written from the normative text, so a semantically wrong
edit that is re-hashed still fails. The Swift and Kotlin hosts must run the same
files through their real classifier and descriptor evaluator.
"""

from __future__ import annotations

import hashlib
import json
import math
import unittest
from pathlib import Path

import spec_golden

DEVICE = Path(__file__).resolve().parents[2] / "device" / "v1"
GOLDEN = DEVICE / "golden"
SCHEMA = DEVICE / "schema"

# Reviewed fixture revision device-panel-v1.1 (property titles, required editors first). Changing a vector requires a new
# contract revision and an update here.
FROZEN = {
    "device-panel-mapping.jsonl": "909b6f67b261fdce27ea4b231a36ed8961510e84e48f81ccf6ff9d9ad27ee9b0",
    "device-panel-descriptor-cases.jsonl": "1fc97537363f7d85f05a169cf18aa04045fba59d78f0180c399ab471a04f0224",
}

MAX_DESCRIPTOR_BYTES = 16384
MAX_DEPTH = 16
MAX_PROPERTIES = 16
MAX_OPTIONS = 32
MAX_OPTION_LENGTH = 64
MAX_TITLE_LENGTH = 20
SAFE_INTEGER = 2 ** 53 - 1


def load_rows(name):
    return [json.loads(line) for line in (GOLDEN / name).read_text(encoding="utf-8").splitlines()]


def load_schema(name):
    return json.loads((SCHEMA / name).read_text(encoding="utf-8"))


def digest(rows):
    data = "\n".join(json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False) for row in rows)
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


# --- reference oracle (device-panel.md §2, §4.2) -----------------------------


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def is_integral(value):
    return is_number(value) and float(value).is_integer() and abs(value) <= SAFE_INTEGER


def root_shape(schema):
    """Return (properties, required) when the root has the closed supported form."""
    if not isinstance(schema, dict) or not set(schema) <= {"type", "properties", "required", "additionalProperties"}:
        return None
    if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
        return None
    properties = schema.get("properties")
    if not isinstance(properties, dict) or len(properties) > MAX_PROPERTIES:
        return None
    required = schema.get("required", [])
    if (not isinstance(required, list) or not all(isinstance(name, str) for name in required)
            or len(set(required)) != len(required) or not set(required) <= set(properties)):
        return None
    return properties, required


def title_ok(title):
    return (isinstance(title, str) and 1 <= len(title) <= MAX_TITLE_LENGTH
            and not any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in title))


def editor_for(prop):
    if not isinstance(prop, dict):
        return None
    titled = "title" in prop
    if titled and not title_ok(prop["title"]):
        return None
    keys, kind = set(prop) - {"title"}, prop.get("type")
    editor = None
    if kind == "boolean" and keys == {"type"}:
        editor = {"kind": "toggle"}
    elif kind in ("integer", "number") and keys == {"type", "minimum", "maximum"}:
        low, high = prop["minimum"], prop["maximum"]
        check = is_integral if kind == "integer" else is_number
        if check(low) and check(high) and low < high:
            editor = {"kind": "slider", "integer": kind == "integer", "min": low, "max": high}
    elif kind == "string" and keys == {"type", "enum"}:
        options = prop["enum"]
        if (isinstance(options, list) and 1 <= len(options) <= MAX_OPTIONS
                and all(isinstance(item, str) and 1 <= len(item) <= MAX_OPTION_LENGTH for item in options)
                and len(set(options)) == len(options)):
            editor = {"kind": "picker", "options": options}
    if editor is not None and titled:
        editor["title"] = prop["title"]
    return editor


def classify(schema):
    shape = root_shape(schema)
    if shape is None:
        return "agent_only", []
    properties, required = shape
    editors = []
    # Required editors first, then optional; each group by code point.
    for arg in sorted(properties, key=lambda name: (name not in required, name)):
        editor = editor_for(properties[arg])
        if editor is None:
            if arg in required:
                return "agent_only", []
            continue
        editors.append({"arg": arg, **editor, "required": arg in required})
    return "editors", editors


def value_ok(value, prop):
    """Preset validation subset: type, enum, minimum, maximum."""
    if not isinstance(prop, dict) or not set(prop) <= {"type", "enum", "minimum", "maximum", "title"}:
        return None
    kind = prop.get("type")
    if kind not in ("boolean", "integer", "number", "string", "object"):
        return None
    if "enum" in prop and not isinstance(prop["enum"], list):
        return None
    for bound in ("minimum", "maximum"):
        if bound in prop and (kind not in ("integer", "number") or not is_number(prop[bound])):
            return None
    typed = {"boolean": lambda v: isinstance(v, bool), "integer": is_integral, "number": is_number,
             "string": lambda v: isinstance(v, str), "object": lambda v: isinstance(v, dict)}[kind](value)
    if not typed:
        return False
    if "enum" in prop and not any(type(value) is type(item) and value == item for item in prop["enum"]):
        return False
    if "minimum" in prop and value < prop["minimum"]:
        return False
    if "maximum" in prop and value > prop["maximum"]:
        return False
    return True


class Duplicate(Exception):
    pass


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise Duplicate(key)
        result[key] = value
    return result


def depth(value):
    if isinstance(value, dict):
        return 1 + max((depth(item) for item in value.values()), default=0)
    if isinstance(value, list):
        return 1 + max((depth(item) for item in value), default=0)
    return 0


def refuse_constant(_name):
    raise ValueError("NaN and Infinity are not JSON")


def evaluate(text, device_id, tools, schema):
    if len(text.encode("utf-8")) > MAX_DESCRIPTOR_BYTES:
        return "too_large"
    try:
        value = json.loads(text, object_pairs_hook=pairs, parse_constant=refuse_constant)
    except Duplicate:
        return "duplicate_key"
    except (ValueError, RecursionError):
        return "invalid_json"
    if depth(value) > MAX_DEPTH:
        return "invalid_json"
    if not isinstance(value, dict):
        return "schema"
    if "v" in value and not (type(value["v"]) is int and value["v"] == 1):
        return "unsupported_version"
    try:
        spec_golden.validate_json(value, schema, "descriptor")
    except spec_golden.SpecError:
        return "schema"
    if value["device_id"] != device_id:
        return "device_mismatch"
    advertised = {tool["name"]: tool["inputSchema"] for tool in tools}
    for control in value["controls"]:
        if control["tool"] not in advertised:
            return "tool_not_advertised"
        input_schema = advertised[control["tool"]]
        if "preset" not in control:
            if classify(input_schema)[0] != "editors":
                return "tool_not_supported"
            continue
        shape = root_shape(input_schema)
        if shape is None:
            return "tool_not_supported"
        properties, required = shape
        if any(value_ok(None, prop) is None for prop in properties.values()):
            return "tool_not_supported"
        preset = control["preset"]
        if not set(preset) <= set(properties) or not set(required) <= set(preset):
            return "preset_invalid"
        if not all(value_ok(item, properties[name]) for name, item in preset.items()):
            return "preset_invalid"
    return "ok"


# --- tests -------------------------------------------------------------------


class DevicePanelMappingTests(unittest.TestCase):
    def setUp(self):
        self.rows = load_rows("device-panel-mapping.jsonl")
        self.schema = load_schema("device-panel-mapping-vector.schema.json")

    def test_vectors_match_schema_digest_and_oracle(self):
        self.assertEqual(digest(self.rows), FROZEN["device-panel-mapping.jsonl"])
        self.assertEqual(len(self.rows), len({row["name"] for row in self.rows}))
        for row in self.rows:
            spec_golden.validate_json(row, self.schema, row["name"])
            render, editors = classify(row["input_schema"])
            self.assertEqual((render, editors), (row["render"], row["editors"]), row["name"])
            if row["render"] == "agent_only":
                self.assertEqual(row["editors"], [], row["name"])
        kinds = {editor["kind"] for row in self.rows for editor in row["editors"]}
        self.assertEqual(kinds, {"toggle", "slider", "picker"})
        self.assertTrue(any(row["render"] == "agent_only" for row in self.rows))
        self.assertTrue(any(row["render"] == "editors" and not row["editors"] for row in self.rows))

    def test_vector_schema_rejects_mutations(self):
        base = next(row for row in self.rows if row["editors"])
        for bad in ({**base, "extra": True}, {**base, "render": "controls"},
                    {key: value for key, value in base.items() if key != "editors"},
                    {**base, "editors": [{"arg": "on", "kind": "switch", "required": True}]},
                    {**base, "editors": [{"arg": "on", "kind": "toggle"}]},
                    {**base, "editors": [{"arg": "on", "kind": "slider", "required": True}]}):
            with self.assertRaises(spec_golden.SpecError):
                spec_golden.validate_json(bad, self.schema, "mutation")

    def test_oracle_is_sensitive_to_each_rule(self):
        closed = {"type": "object", "properties": {"on": {"type": "boolean"}}, "required": ["on"],
                  "additionalProperties": False}
        self.assertEqual(classify(closed)[0], "editors")
        for mutate in (lambda s: s.pop("additionalProperties"),
                       lambda s: s.update(additionalProperties=True),
                       lambda s: s.update(type="array"),
                       lambda s: s.update(oneOf=[]),
                       lambda s: s.update(required=["missing"]),
                       lambda s: s["properties"]["on"].update(description="x"),
                       lambda s: s["properties"].update(on={"type": "string"})):
            changed = json.loads(json.dumps(closed))
            mutate(changed)
            self.assertEqual(classify(changed), ("agent_only", []))


class DevicePanelDescriptorTests(unittest.TestCase):
    def setUp(self):
        self.rows = load_rows("device-panel-descriptor-cases.jsonl")
        self.case_schema = load_schema("device-panel-descriptor-case.schema.json")
        self.schema = load_schema("device-panel-descriptor.schema.json")

    def test_cases_match_schema_digest_and_oracle(self):
        self.assertEqual(digest(self.rows), FROZEN["device-panel-descriptor-cases.jsonl"])
        self.assertEqual(len(self.rows), len({row["name"] for row in self.rows}))
        for row in self.rows:
            spec_golden.validate_json(row, self.case_schema, row["name"])
            self.assertEqual(evaluate(row["descriptor"], row["device_id"], row["tools"], self.schema),
                             row["result"], row["name"])
        self.assertEqual({row["result"] for row in self.rows},
                         set(self.case_schema["properties"]["result"]["enum"]))

    def test_descriptor_schema_rejects_mutations(self):
        good = json.loads(next(row for row in self.rows if row["result"] == "ok")["descriptor"])
        spec_golden.validate_json(good, self.schema, "good")
        control = good["controls"][0]
        for bad in ({**good, "extra": 1}, {**good, "v": 2}, {**good, "controls": []},
                    {**good, "controls": [control] * 33}, {**good, "title": ""}, {**good, "title": "x" * 41},
                    {**good, "device_id": "a\nb"}, {key: value for key, value in good.items() if key != "device_id"},
                    {**good, "controls": [{**control, "script": "alert(1)"}]},
                    {**good, "controls": [{**control, "label": "tab\there"}]},
                    {**good, "controls": [{**control, "preset": []}]},
                    {**good, "controls": [{key: value for key, value in control.items() if key != "label"}]}):
            with self.assertRaises(spec_golden.SpecError):
                spec_golden.validate_json(bad, self.schema, "mutation")

    def test_case_schema_rejects_mutations(self):
        base = self.rows[0]
        for bad in ({**base, "extra": True}, {**base, "result": "accepted"}, {**base, "descriptor": {}},
                    {key: value for key, value in base.items() if key != "tools"}):
            with self.assertRaises(spec_golden.SpecError):
                spec_golden.validate_json(bad, self.case_schema, "mutation")


if __name__ == "__main__":
    unittest.main()
