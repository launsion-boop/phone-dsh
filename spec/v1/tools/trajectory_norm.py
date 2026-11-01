#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Normalize Harness trajectories and UiState sequences (phone-dsh-v1).

This tool is the executable half of ``spec/v1/trajectory.md``. It normalizes two JSONL
artifacts through the same five ordered stages and the same platform-noise rule table:

* ``trajectory/1`` rows: one Harness event per line.
* ``ui-state/1`` rows: one projected UiState node per line.

The pure core is ``normalize(lines, rules)``. The command-line interface is::

    python3 spec/v1/tools/trajectory_norm.py --input F --output F [--root R]
    python3 spec/v1/tools/trajectory_norm.py --check-golden --root .
    python3 spec/v1/tools/trajectory_norm.py --input F --output F --stats

Python 3.9, standard library only. JSON Schema validation is delegated to the existing checker in
``spec_golden.py``; this file does not implement a second validator.
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import posixpath
import re
import sys
import tempfile
from decimal import Decimal, InvalidOperation, ROUND_HALF_EVEN
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
TOOLS_DIR = REPO_ROOT / "spec" / "v1" / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from spec_golden import SpecError, load_json, validate_json  # noqa: E402

KIND_TRAJECTORY = "trajectory"
KIND_UI_STATE = "ui-state"

SCHEMA_FILES = {
    KIND_TRAJECTORY: "trajectory.schema.json",
    KIND_UI_STATE: "ui-state-sequence.schema.json",
}
SCHEMA_VERSIONS = {
    "trajectory/1": KIND_TRAJECTORY,
    "ui-state/1": KIND_UI_STATE,
}

# Stage 2 and the reverse-re-evaluation thresholds of trajectory.md §3 and §8.
WINDOW = 16
RULE_CAP = 12
RULE_GROWTH_LIMIT = 3

# Stage 1 strip domain (trajectory.md §2).
STRIP_MEMBERS = frozenset(
    {
        "time",
        "timestamp",
        "wallClock",
        "wallMs",
        "occurredAt",
        "mono",
        "monotonic",
        "monotonicMs",
        "machAbsolute",
        "mach_absolute_time",
        "uptimeMs",
        "pid",
        "processID",
        "processId",
        "port",
        "socketPort",
        "localPort",
        "remotePort",
        "memory",
        "memoryBytes",
        "memoryMB",
        "rssBytes",
        "cpu",
        "cpuPercent",
        "cpuTimeMs",
    }
)
DROP_TYPES = frozenset({"metric/sample", "perf/sample", "debug/clock", "host/heartbeat"})
REQUEST_ID_MEMBERS = frozenset({"requestId", "request_id", "reqId"})
PATH_MEMBERS = frozenset({"path", "cwd", "workspace", "root", "filePath", "target"})

# Stage 4 numeric domains (trajectory.md §5).
DURATION_MS_MEMBERS = frozenset(
    {
        "durationMs",
        "elapsedMs",
        "latencyMs",
        "ttftMs",
        "turnDurationMs",
        "toolDurationMs",
    }
)
SIZE_MEMBERS = frozenset(
    {
        "bytes",
        "sizeBytes",
        "bytesIn",
        "bytesOut",
        "payloadBytes",
        "contentBytes",
    }
)
RATIO_MEMBERS = frozenset({"percent", "ratio"})

# UiState stable-id grammar (trajectory.md §7).
SURFACES = frozenset(
    {
        "bubble",
        "tool-row",
        "thinking-pill",
        "approval-card",
        "composer",
        "fail-loud-banner",
    }
)
KIND_DEPTH = {
    "root": "root",
    "session": "session",
    "turn": "turn",
    "turn-event": "event",
    "bubble": "slot",
    "context": "slot",
    "tool-row": "slot",
    "thinking-pill": "slot",
    "approval-card": "slot",
    "composer": "slot",
    "fail-loud-banner": "slot",
    "status": "slot",
}

# Stage 3 platform-noise whitelist (trajectory.md §4). The table is normative here and
# mirrored in the document; rules are applied in ascending id code-point order.
RULES = [
    {
        "id": "android-java-frame",
        "platforms": ["android"],
        "pattern": r"(?m)^[ \t]+at [A-Za-z0-9_.$]+\([A-Za-z0-9_.]+\.(?:java|kt):\d+\)[ \t\r]*(?:\n)?",
        "replacement": "",
        "reason": "JVM stack frames are runtime-specific",
    },
    {
        "id": "android-thread-tag",
        "platforms": ["android"],
        "pattern": r"\bthread=(?:main|RenderThread|DefaultDispatcher-worker-\d+)\b",
        "replacement": "thread=<worker>",
        "reason": "thread names are scheduler detail",
    },
    {
        "id": "both-crlf",
        "platforms": ["both"],
        "pattern": r"\r\n?",
        "replacement": "\n",
        "reason": "line endings are an encoding detail",
    },
    {
        "id": "both-embedded-utc",
        "platforms": ["both"],
        "pattern": r"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\b",
        "replacement": "<timestamp>",
        "reason": "a wall clock embedded in text",
    },
    {
        "id": "both-loopback-port",
        "platforms": ["both"],
        "pattern": r"\b(?:127\.0\.0\.1|localhost|\[::1\]):\d{2,5}\b",
        "replacement": "loopback:<port>",
        "reason": "ephemeral loopback port",
    },
    {
        "id": "both-pid-tag",
        "platforms": ["both"],
        "pattern": r"\bpid[=:]\d+\b",
        "replacement": "pid=<removed>",
        "reason": "process id in a log line",
    },
    {
        "id": "both-uuid",
        "platforms": ["both"],
        "pattern": r"(?<!Application/)\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
        "replacement": "<uuid>",
        "reason": "install/run-scoped identifier",
    },
    {
        "id": "ios-container-uuid",
        "platforms": ["ios"],
        "pattern": r"/var/mobile/Containers/Data/Application/[0-9A-Fa-f-]{36}\b",
        "replacement": "/app-container",
        "reason": "container UUID changes per install",
    },
    {
        "id": "ios-mach-time",
        "platforms": ["ios"],
        "pattern": r"\bmach_absolute_time=\d+\b",
        "replacement": "mach_absolute_time=<removed>",
        "reason": "monotonic clock in a log line",
    },
]

_ISO_PREFIX_RE = re.compile(
    r"(?:/private)?/var/mobile/Containers/Data/Application/[^/\s\"']+/"
    r"(?:Documents|Library|tmp)/(workspace|home|tmp)"
)
_ANDROID_PREFIX_RE = re.compile(
    r"/data/(?:user/0|data)/[^/\s\"']+/files/(workspace|home|tmp)"
)
_UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
_REQUEST_SUFFIX_RE = re.compile(r"(?i)(?:[-_:])(?:[0-9a-f]{6,32}|[0-9]{6,20})$")
_HEX_ONLY_RE = re.compile(r"[0-9a-fA-F]{8,64}")
_SIZE_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*(B|KiB|MiB|GiB)\s*$")
_PLAIN_INT_RE = re.compile(r"^[0-9]+$")
_SLOT_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
_RANDOM_SLOT_RE = re.compile(r"(?:^|[-_])[0-9a-f]{8,}$")

MICRO = Decimal("1E-6")
MILLI = Decimal("1E-3")
UNIT = Decimal("1E0")
TEN_MS = Decimal("1E1")
SIZE_MULTIPLIERS = {
    "B": Decimal(1),
    "KiB": Decimal(1024),
    "MiB": Decimal(1024 * 1024),
    "GiB": Decimal(1024 * 1024 * 1024),
}


class NormError(Exception):
    """A normalization rule was violated; the input is not silently repaired."""

    def __init__(self, code, where, message):
        super().__init__("{} at {}: {}".format(code, where, message))
        self.code = code
        self.where = where
        self.message = message


class _Stats(object):
    def __init__(self):
        self.data = {
            "inputLines": 0,
            "blankLines": 0,
            "outputLines": 0,
            "droppedLines": 0,
            "removedMembers": {},
            "pathRewrites": 0,
            "requestIdRewrites": 0,
            "ruleHits": {},
            "numberRewrites": 0,
            "window": WINDOW,
            "ruleCount": len(RULES),
            "ruleCap": RULE_CAP,
            "ruleGrowthLimit": RULE_GROWTH_LIMIT,
        }

    def bump(self, name, amount=1):
        self.data[name] = self.data.get(name, 0) + amount

    def member(self, name):
        removed = self.data["removedMembers"]
        removed[name] = removed.get(name, 0) + 1

    def rule(self, rule_id):
        hits = self.data["ruleHits"]
        hits[rule_id] = hits.get(rule_id, 0) + 1

    def export(self, kind):
        result = dict(self.data)
        result["kind"] = kind
        result["removedMembers"] = dict(sorted(result["removedMembers"].items()))
        result["ruleHits"] = dict(sorted(result["ruleHits"].items()))
        return result


def _reject_constant(value):
    raise ValueError("non-finite JSON number {!r}".format(value))


def _no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON member {!r}".format(key))
        result[key] = value
    return result


def parse_json_text(text, where):
    """Parse one JSON value, rejecting duplicate members and non-finite numbers."""

    try:
        return json.loads(
            text,
            object_pairs_hook=_no_duplicates,
            parse_constant=_reject_constant,
        )
    except (ValueError, TypeError) as exc:
        raise NormError("BAD_JSON", where, str(exc)) from exc


_SCHEMA_CACHE = {}


def load_schemas(root=None):
    """Load the two schemas from ``<root>/spec/v1/schema`` (cached by resolved root)."""

    base = Path(root) if root is not None else REPO_ROOT
    schema_dir = base / "spec" / "v1" / "schema"
    cache_key = str(schema_dir.resolve())
    if cache_key in _SCHEMA_CACHE:
        return _SCHEMA_CACHE[cache_key]
    schemas = {}
    for kind, name in SCHEMA_FILES.items():
        path = schema_dir / name
        try:
            schema = load_json(path)
        except (OSError, SpecError) as exc:
            raise NormError("SCHEMA", str(path), str(exc)) from exc
        schemas[kind] = schema
    _SCHEMA_CACHE[cache_key] = schemas
    return schemas


def _validate_row(row, schema, kind, where):
    try:
        validate_json(row, schema, where, "$")
    except SpecError as exc:
        raise NormError("SCHEMA", where, str(exc)) from exc
    version = row.get("schemaVersion")
    expected = KIND_TRAJECTORY if kind == KIND_TRAJECTORY else KIND_UI_STATE
    if SCHEMA_VERSIONS.get(version) != expected:
        raise NormError(
            "SCHEMA",
            where,
            "schemaVersion {!r} does not match {}".format(version, kind),
        )


def _detect_kind(rows):
    if not rows:
        return KIND_TRAJECTORY
    version = rows[0].get("schemaVersion")
    kind = SCHEMA_VERSIONS.get(version)
    if kind is None:
        raise NormError("UNKNOWN_KIND", "line 1", "unknown schemaVersion {!r}".format(version))
    return kind


def _replace_host_prefixes(text):
    def repl(match):
        return "/dsh/" + match.group(1)

    text = _ANDROID_PREFIX_RE.sub(repl, text)
    return _ISO_PREFIX_RE.sub(repl, text)


def _canonical_path(value, where):
    if not isinstance(value, str):
        raise NormError("UNPORTABLE_PATH", where, "path member is not a string")
    value = _replace_host_prefixes(value)
    if not value:
        return value
    if value.startswith("/dsh/"):
        parts = value.split("/")
        if len(parts) < 3 or parts[2] not in ("home", "workspace", "tmp"):
            raise NormError("UNPORTABLE_PATH", where, "unknown /dsh root in {!r}".format(value))
        for part in parts[3:]:
            if not part or part in (".", "..") or "\x00" in part:
                raise NormError("UNPORTABLE_PATH", where, "invalid segment in {!r}".format(value))
        if len(value) > 512:
            raise NormError("UNPORTABLE_PATH", where, "path is longer than 512 characters")
        return value
    if value.startswith("/"):
        raise NormError("UNPORTABLE_PATH", where, "absolute host path cannot be normalized")
    normalized = posixpath.normpath(value)
    if normalized == ".." or normalized.startswith("../"):
        raise NormError("UNPORTABLE_PATH", where, "relative path escapes its root")
    return normalized


def _normalize_request_id(value, where):
    if not isinstance(value, str):
        raise NormError("BAD_REQUEST_ID", where, "request id is not a string")
    stripped = value.strip()
    if not stripped:
        return None
    # A UUID or a bare hex run is an install/run identifier, never a stable stem, so the
    # classification happens on the value *before* suffix removal. Removing a trailing
    # [-_:]<hex|digits> group first would turn a standard UUID into a plausible-looking stem
    # (trajectory.md §2 says a UUID is removed, so the suffix removal must not pre-empt it).
    if _UUID_RE.fullmatch(stripped) or _HEX_ONLY_RE.fullmatch(stripped):
        return None
    stem = _REQUEST_SUFFIX_RE.sub("", stripped)
    if not stem:
        return None
    return stem


def _strip_value(value, stats, where, key=None):
    if isinstance(value, dict):
        for name in list(value.keys()):
            child_where = "{}.{}".format(where, name)
            if name in STRIP_MEMBERS:
                del value[name]
                stats.member(name)
            elif name in REQUEST_ID_MEMBERS:
                original = value[name]
                normalized = _normalize_request_id(original, child_where)
                if normalized is None:
                    del value[name]
                else:
                    value[name] = normalized
                if normalized != original:
                    stats.bump("requestIdRewrites")
            elif name in PATH_MEMBERS and isinstance(value[name], str):
                original = value[name]
                value[name] = _canonical_path(original, child_where)
                if value[name] != original:
                    stats.bump("pathRewrites")
            else:
                value[name] = _strip_value(value[name], stats, child_where, name)
        return value
    if isinstance(value, list):
        for index, item in enumerate(value):
            value[index] = _strip_value(
                item, stats, "{}[{}]".format(where, index), key
            )
        return value
    if isinstance(value, str):
        replaced = _replace_host_prefixes(value)
        if replaced != value:
            stats.bump("pathRewrites")
        return replaced
    return value


def _capture_platform(row, override, where):
    platform = row.pop("platform", None)
    if platform is None:
        platform = override
    elif override is not None and platform != override:
        raise NormError(
            "PLATFORM_CONFLICT",
            where,
            "row platform {!r} conflicts with override {!r}".format(platform, override),
        )
    if platform is None:
        platform = "both"
    if platform not in ("ios", "android", "both"):
        raise NormError("PLATFORM", where, "unsupported platform {!r}".format(platform))
    return platform


def _validate_rules(rules):
    if not isinstance(rules, (list, tuple)):
        raise NormError("RULES", "rules", "rule table is not a list")
    seen = set()
    validated = []
    for index, rule in enumerate(rules):
        where = "rules[{}]".format(index)
        if not isinstance(rule, dict):
            raise NormError("RULES", where, "rule is not an object")
        required = ("id", "platforms", "pattern", "replacement", "reason")
        for name in required:
            if name not in rule:
                raise NormError("RULES", where, "rule has no {!r}".format(name))
        rule_id = rule["id"]
        if not isinstance(rule_id, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", rule_id):
            raise NormError("RULES", where, "invalid rule id {!r}".format(rule_id))
        if rule_id in seen:
            raise NormError("RULES", where, "duplicate rule id {!r}".format(rule_id))
        seen.add(rule_id)
        platforms = rule["platforms"]
        if not isinstance(platforms, list) or not platforms:
            raise NormError("RULES", where, "platforms is not a non-empty list")
        if any(item not in ("ios", "android", "both") for item in platforms):
            raise NormError("RULES", where, "unsupported platform in {!r}".format(platforms))
        if "both" in platforms and len(platforms) != 1:
            raise NormError("RULES", where, "'both' must be the only entry")
        pattern = rule["pattern"]
        if not isinstance(pattern, str) or not pattern or len(pattern) > 256:
            raise NormError("RULES", where, "pattern is empty or too long")
        try:
            compiled = re.compile(pattern)
        except re.error as exc:
            raise NormError("RULES", where, "pattern does not compile: {}".format(exc)) from exc
        if compiled.search("") is not None:
            raise NormError("RULES", where, "pattern matches the empty string")
        replacement = rule["replacement"]
        if not isinstance(replacement, str):
            raise NormError("RULES", where, "replacement is not a string")
        reason = rule["reason"]
        if not isinstance(reason, str) or not reason.strip():
            raise NormError("RULES", where, "reason is empty")
        validated.append(
            {
                "id": rule_id,
                "platforms": tuple(platforms),
                "pattern": pattern,
                "replacement": replacement,
                "reason": reason,
                "compiled": compiled,
            }
        )
    if len(validated) > RULE_CAP:
        raise NormError(
            "RULE_CAP",
            "rules",
            "{} rules exceed the cap of {}; take §8.3 signal ①".format(len(validated), RULE_CAP),
        )
    return sorted(validated, key=lambda item: item["id"])


def _apply_rules(value, rules, platform, stats, where):
    if isinstance(value, dict):
        for name in list(value.keys()):
            value[name] = _apply_rules(
                value[name], rules, platform, stats, "{}.{}".format(where, name)
            )
        return value
    if isinstance(value, list):
        for index, item in enumerate(value):
            value[index] = _apply_rules(
                item, rules, platform, stats, "{}[{}]".format(where, index)
            )
        return value
    if not isinstance(value, str):
        return value
    for rule in rules:
        if "both" not in rule["platforms"] and platform not in rule["platforms"]:
            continue
        replaced, count = rule["compiled"].subn(rule["replacement"], value)
        if count:
            stats.rule(rule["id"])
            value = replaced
    return value


def _decimal(value, where, what):
    try:
        decimal = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise NormError("BAD_NUMBER", where, "{} is not a number".format(what)) from exc
    if not decimal.is_finite():
        raise NormError("BAD_NUMBER", where, "{} is not finite".format(what))
    return decimal


def _size_decimal(value, where):
    if isinstance(value, bool):
        raise NormError("BAD_NUMBER", where, "boolean is not a byte count")
    if isinstance(value, int):
        return Decimal(value)
    if isinstance(value, float):
        return _decimal(value, where, "byte count")
    if isinstance(value, str):
        match = _SIZE_RE.fullmatch(value)
        if match:
            return Decimal(match.group(1)) * SIZE_MULTIPLIERS[match.group(2)]
        if _PLAIN_INT_RE.fullmatch(value):
            return Decimal(value)
    raise NormError("BAD_NUMBER", where, "byte count is not a number with a known unit")


def _quantize(decimal, target, where):
    try:
        return decimal.quantize(target, rounding=ROUND_HALF_EVEN)
    except InvalidOperation as exc:
        raise NormError("BAD_NUMBER", where, "number cannot be quantized") from exc


def _normalize_number(value, key, where, stats):
    if isinstance(value, bool):
        return value
    if key in DURATION_MS_MEMBERS:
        decimal = _decimal(value, where, "duration")
        quantized = _quantize(decimal, TEN_MS, where)
        if quantized == 0:
            quantized = Decimal(0)
        normalized = int(quantized)
    elif key in SIZE_MEMBERS:
        normalized = int(_quantize(_size_decimal(value, where), UNIT, where))
        if normalized < 0:
            raise NormError("BAD_NUMBER", where, "byte count is negative")
    elif key in RATIO_MEMBERS:
        quantized = _quantize(_decimal(value, where, "ratio"), MILLI, where)
        if quantized == 0:
            quantized = Decimal(0)
        normalized = int(quantized) if quantized == quantized.to_integral_value() else float(quantized)
    else:
        if isinstance(value, int):
            return value
        decimal = _decimal(value, where, "number")
        quantized = _quantize(decimal, MICRO, where)
        if quantized == 0:
            quantized = Decimal(0)
        normalized = int(quantized) if quantized == quantized.to_integral_value() else float(quantized)
    if normalized != value:
        stats.bump("numberRewrites")
    return normalized


def _normalize_numbers(value, stats, where, key=None):
    if isinstance(value, dict):
        for name in list(value.keys()):
            value[name] = _normalize_numbers(
                value[name], stats, "{}.{}".format(where, name), name
            )
        return value
    if isinstance(value, list):
        for index, item in enumerate(value):
            value[index] = _normalize_numbers(
                item, stats, "{}[{}]".format(where, index), None
            )
        return value
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float, str)):
        if key in SIZE_MEMBERS and isinstance(value, str):
            return _normalize_number(value, key, where, stats)
        if isinstance(value, (int, float)):
            return _normalize_number(value, key, where, stats)
    return value


def _order_trajectory(rows, stats):
    groups = {}
    for arrival, row in enumerate(rows):
        try:
            session = row["sessionID"]
            turn = row["turnID"]
            seq = row["seq"]
        except KeyError as exc:
            raise NormError("ORDER", "row {}".format(arrival + 1), "missing {}".format(exc)) from exc
        groups.setdefault((session, turn), []).append((arrival, seq, row))
    ordered = []
    for group_key in sorted(groups.keys()):
        group = groups[group_key]
        seen = []
        for arrival, seq, _row in group:
            insert_at = bisect.bisect_right(seen, seq)
            late_by = len(seen) - insert_at
            if late_by > WINDOW:
                raise NormError(
                    "OUT_OF_WINDOW",
                    "{}/{}".format(group_key[0], group_key[1]),
                    "seq {} arrived after {} higher seq rows (window {})".format(
                        seq, late_by, WINDOW
                    ),
                )
            bisect.insort(seen, seq)
        seqs = [seq for _arrival, seq, _row in group]
        if len(set(seqs)) != len(seqs):
            raise NormError(
                "DUPLICATE_SEQ",
                "{}/{}".format(group_key[0], group_key[1]),
                "a seq appears twice",
            )
        group.sort(key=lambda item: (item[1], item[0]))
        ordered.extend(row for _arrival, _seq, row in group)
    stats.data["groups"] = len(groups)
    return ordered


def _parse_node_id(node_id, where):
    if node_id == "root":
        return ("root",)
    parts = node_id.split("/")
    if len(parts) < 2 or parts[0] != "session":
        raise NormError("UNSTABLE_NODE_ID", where, "node id is not a session path")
    session = parts[1]
    if len(parts) == 2:
        return ("session", session)
    if len(parts) < 4 or parts[2] != "turn":
        raise NormError("UNSTABLE_NODE_ID", where, "node id is not a turn path")
    turn = parts[3]
    if len(parts) == 4:
        return ("turn", session, turn)
    if len(parts) < 6 or parts[4] != "event":
        raise NormError("UNSTABLE_NODE_ID", where, "node id is not an event path")
    try:
        seq = int(parts[5])
    except ValueError as exc:
        raise NormError("UNSTABLE_NODE_ID", where, "event segment is not an integer") from exc
    if len(parts) == 6:
        return ("event", session, turn, seq)
    if len(parts) == 7:
        slot = parts[6]
        if not _SLOT_RE.fullmatch(slot):
            raise NormError("UNSTABLE_NODE_ID", where, "slot is not a semantic role")
        if (
            _UUID_RE.fullmatch(slot)
            or _HEX_ONLY_RE.fullmatch(slot)
            or _RANDOM_SLOT_RE.search(slot)
        ):
            raise NormError("UNSTABLE_NODE_ID", where, "slot looks like a random identifier")
        return ("slot", session, turn, seq, slot)
    raise NormError("UNSTABLE_NODE_ID", where, "node id is deeper than the grammar")


def _expected_parent(parsed):
    depth = parsed[0]
    if depth in ("root", "session"):
        return "root"
    if depth == "turn":
        return "session/{}".format(parsed[1])
    if depth == "event":
        return "session/{}/turn/{}".format(parsed[1], parsed[2])
    if depth == "slot":
        return "session/{}/turn/{}/event/{}".format(parsed[1], parsed[2], parsed[3])
    raise NormError("UNSTABLE_NODE_ID", "node", "unknown node depth")


def _check_uistate_node(row, where):
    node_id = row["nodeID"]
    parent_id = row["parentID"]
    parsed = _parse_node_id(node_id, where)
    expected = _expected_parent(parsed)
    if parent_id != expected:
        raise NormError(
            "UNSTABLE_NODE_ID",
            where,
            "parentID {!r} is not {!r} for node {!r}".format(parent_id, expected, node_id),
        )
    expected_depth = KIND_DEPTH.get(row["kind"])
    if expected_depth != parsed[0]:
        raise NormError(
            "UNSTABLE_NODE_ID",
            where,
            "kind {!r} does not match node depth {!r}".format(row["kind"], parsed[0]),
        )
    if parsed[0] != "root" and parsed[1] != row["sessionID"]:
        raise NormError("UNSTABLE_NODE_ID", where, "node id disagrees with sessionID")
    if parsed[0] in ("turn", "event", "slot") and parsed[2] != row["turnID"]:
        raise NormError("UNSTABLE_NODE_ID", where, "node id disagrees with turnID")
    if parsed[0] in ("event", "slot") and parsed[3] != row["seq"]:
        raise NormError("UNSTABLE_NODE_ID", where, "node id disagrees with seq")
    # `trajectory.md` §7: "structural nodes use `seq = 0`". The depth check above
    # only compared seq for event/slot rows, so a structural row could carry any seq
    # and still normalize — nothing in the sequence changes, which is exactly why the
    # gap survived: the field was validated only where it was load-bearing.
    if parsed[0] in ("root", "session", "turn") and row["seq"] != 0:
        raise NormError(
            "UNSTABLE_NODE_ID",
            where,
            "structural node {!r} must use seq = 0, got {}".format(row["kind"], row["seq"]),
        )
    if row["surface"] != "none" and row["surface"] not in SURFACES:
        raise NormError("SURFACE", where, "unknown signature surface {!r}".format(row["surface"]))


def _order_uistate(rows, stats):
    seen_ids = set()
    for index, row in enumerate(rows):
        where = "row {}".format(index + 1)
        _check_uistate_node(row, where)
        if row["nodeID"] in seen_ids:
            raise NormError("UNSTABLE_NODE_ID", where, "duplicate nodeID {!r}".format(row["nodeID"]))
        seen_ids.add(row["nodeID"])
    groups = {}
    for arrival, row in enumerate(rows):
        groups.setdefault((row["sessionID"], row["turnID"]), []).append((arrival, row))
    ordered = []
    for group_key in sorted(groups.keys()):
        group = groups[group_key]
        seen = []
        for arrival, row in group:
            seq = row["seq"]
            insert_at = bisect.bisect_right(seen, seq)
            late_by = len(seen) - insert_at
            if late_by > WINDOW:
                raise NormError(
                    "OUT_OF_WINDOW",
                    "{}/{}".format(group_key[0], group_key[1]),
                    "seq {} arrived after {} higher seq rows (window {})".format(
                        seq, late_by, WINDOW
                    ),
                )
            bisect.insort(seen, seq)
        group.sort(key=lambda item: (item[1]["seq"], item[1]["nodeID"], item[0]))
        ordered.extend(row for _arrival, row in group)
    positions = {row["nodeID"]: index for index, row in enumerate(ordered)}
    for index, row in enumerate(ordered):
        if row["nodeID"] == "root":
            continue
        parent = row["parentID"]
        if parent not in positions:
            raise NormError(
                "UNSTABLE_NODE_ID",
                "row {}".format(index + 1),
                "parent {!r} is not in the sequence".format(parent),
            )
        if positions[parent] >= index:
            raise NormError(
                "UNSTABLE_NODE_ID",
                "row {}".format(index + 1),
                "parent {!r} does not precede its child".format(parent),
            )
    stats.data["groups"] = len(groups)
    return ordered


def _canonical_line(row, where):
    try:
        line = json.dumps(
            row,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    except (TypeError, ValueError) as exc:
        raise NormError("OUTPUT", where, str(exc)) from exc
    if "\n" in line or "\r" in line:
        raise NormError("OUTPUT", where, "canonical line contains a raw newline")
    return line


def normalize(
    lines,
    rules=None,
    kind=None,
    platform=None,
    stats=None,
    schemas=None,
):
    """Normalize JSONL rows and return canonical lines (no trailing newline).

    ``lines`` is an iterable of text lines or one text blob. ``rules`` defaults to the
    normative ``RULES`` table. ``kind`` is auto-detected from ``schemaVersion`` when it is
    ``None``. The function is pure apart from reading the schemas from the default tree when
    ``schemas`` is not supplied.
    """

    if rules is None:
        rules = RULES
    validated_rules = _validate_rules(rules)
    if stats is None:
        stats = _Stats()
    elif not isinstance(stats, _Stats):
        raise NormError("STATS", "stats", "stats must be a _Stats instance")
    stats.data["ruleCount"] = len(validated_rules)
    if isinstance(lines, str):
        lines = lines.splitlines()
    rows = []
    for number, line in enumerate(lines, 1):
        if isinstance(line, bytes):
            try:
                line = line.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise NormError("BAD_JSON", "line {}".format(number), str(exc)) from exc
        if number == 1 and line.startswith("\ufeff"):
            line = line[1:]
        line = line.rstrip("\n")
        if line.endswith("\r"):
            line = line[:-1]
        if not line.strip():
            stats.data["blankLines"] += 1
            continue
        rows.append(parse_json_text(line, "line {}".format(number)))
        stats.data["inputLines"] += 1
    if not rows:
        stats.data = stats.export(kind or KIND_TRAJECTORY)
        return []
    detected = _detect_kind(rows)
    if kind is not None and kind != detected:
        raise NormError(
            "UNKNOWN_KIND",
            "input",
            "declared kind {!r} does not match {}".format(kind, detected),
        )
    kind = detected
    if schemas is None:
        schemas = load_schemas()
    schema = schemas[kind]
    for index, row in enumerate(rows, 1):
        _validate_row(row, schema, kind, "row {}".format(index))
    prepared = []
    platform_by_row = {}
    for index, row in enumerate(rows, 1):
        where = "row {}".format(index)
        row_platform = _capture_platform(row, platform, where)
        if kind == KIND_TRAJECTORY and row.get("type") in DROP_TYPES:
            stats.data["droppedLines"] += 1
            continue
        _strip_value(row, stats, where)
        prepared.append(row)
        platform_by_row[id(row)] = row_platform
    if kind == KIND_TRAJECTORY:
        ordered = _order_trajectory(prepared, stats)
        # Stage 3 follows the platform captured from each row. Stage 2 may reorder rows, so
        # indexing the captured platforms by prepared position would apply a neighbour's
        # platform after a reorder (the bug this association replaces).
        ordered_platforms = [platform_by_row[id(row)] for row in ordered]
        for row, row_platform in zip(ordered, ordered_platforms):
            _apply_rules(row.get("data", {}), validated_rules, row_platform, stats, "data")
            _normalize_numbers(row.get("data", {}), stats, "data")
    else:
        ordered = _order_uistate(prepared, stats)
        ordered_platforms = [platform_by_row[id(row)] for row in ordered]
        for row, row_platform in zip(ordered, ordered_platforms):
            if "text" in row:
                row["text"] = _apply_rules(
                    row["text"], validated_rules, row_platform, stats, "text"
                )
            _apply_rules(row.get("props", {}), validated_rules, row_platform, stats, "props")
            _normalize_numbers(row.get("props", {}), stats, "props")
    output = [_canonical_line(row, "row {}".format(index + 1)) for index, row in enumerate(ordered)]
    stats.data["outputLines"] = len(output)
    stats.data = stats.export(kind)
    return output


def encode_lines(lines):
    """Encode canonical lines as JSONL bytes: one newline after every non-empty output."""

    if not lines:
        return b""
    return ("\n".join(lines) + "\n").encode("utf-8")


def _read_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise NormError("IO", str(path), str(exc)) from exc


def _write_bytes_atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        "wb", dir=str(path.parent), prefix=path.name + ".", delete=False
    )
    temporary = Path(handle.name)
    try:
        with handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temporary), str(path))
    finally:
        if temporary.exists():
            temporary.unlink()


def _load_case_notes(case_dir):
    path = case_dir / "notes.json"
    try:
        notes = load_json(path)
    except (OSError, SpecError) as exc:
        raise NormError("GOLDEN", str(path), str(exc)) from exc
    if not isinstance(notes, dict):
        raise NormError("GOLDEN", str(path), "notes.json is not an object")
    case_kind = notes.get("kind")
    if case_kind not in ("equivalent", "real-difference"):
        raise NormError("GOLDEN", str(path), "kind must be equivalent or real-difference")
    expected = notes.get("expected")
    if not isinstance(expected, dict) or set(expected) != {"ios", "android"}:
        raise NormError("GOLDEN", str(path), "expected must map ios and android")
    for platform_name, name in expected.items():
        if not isinstance(name, str) or "/" in name or not name.endswith(".jsonl"):
            raise NormError("GOLDEN", str(path), "bad expected file for {}".format(platform_name))
    if case_kind == "equivalent":
        if expected["ios"] != expected["android"]:
            raise NormError("GOLDEN", str(path), "equivalent case must use one expected file")
    else:
        if expected["ios"] == expected["android"]:
            raise NormError("GOLDEN", str(path), "real difference must use two expected files")
        difference = notes.get("semanticDifference")
        if not isinstance(difference, list) or not difference:
            raise NormError("GOLDEN", str(path), "real difference must name the semantic difference")
        if not isinstance(notes.get("whyNotNoise"), str) or not notes["whyNotNoise"].strip():
            raise NormError("GOLDEN", str(path), "real difference must explain whyNotNoise")
    return notes


def _read_case_lines(case_dir, platform_name):
    path = case_dir / "{}.jsonl".format(platform_name)
    return _read_text(path).splitlines()


def check_golden(root):
    """Run every golden case; return ``(ok, stats_by_case, messages)``."""

    base = Path(root)
    golden = base / "spec" / "v1" / "golden" / "trajectory"
    if not golden.is_dir():
        return False, {}, ["GOLDEN {}: directory is missing".format(golden)]
    cases = sorted(path for path in golden.iterdir() if path.is_dir())
    if not cases:
        return False, {}, ["GOLDEN {}: no cases".format(golden)]
    schemas = load_schemas(base)
    messages = []
    per_case = {}
    passed = 0
    for case_dir in cases:
        name = case_dir.name
        try:
            notes = _load_case_notes(case_dir)
            ios_lines = _read_case_lines(case_dir, "ios")
            android_lines = _read_case_lines(case_dir, "android")
            ios_stats = _Stats()
            android_stats = _Stats()
            ios_once = normalize(
                ios_lines, RULES, kind=KIND_TRAJECTORY, stats=ios_stats, schemas=schemas
            )
            android_once = normalize(
                android_lines, RULES, kind=KIND_TRAJECTORY, stats=android_stats, schemas=schemas
            )
            ios_twice = normalize(ios_lines, RULES, kind=KIND_TRAJECTORY, schemas=schemas)
            android_twice = normalize(
                android_lines, RULES, kind=KIND_TRAJECTORY, schemas=schemas
            )
            if ios_once != ios_twice or android_once != android_twice:
                raise NormError("DETERMINISM", name, "two runs differ")
            expected_ios = _read_text(case_dir / notes["expected"]["ios"]).splitlines()
            expected_android = _read_text(case_dir / notes["expected"]["android"]).splitlines()
            # Expected files must themselves be canonical and schema-valid.
            if normalize(expected_ios, RULES, kind=KIND_TRAJECTORY, schemas=schemas) != expected_ios:
                raise NormError("GOLDEN", name, "ios expected file is not canonical")
            if normalize(
                expected_android, RULES, kind=KIND_TRAJECTORY, schemas=schemas
            ) != expected_android:
                raise NormError("GOLDEN", name, "android expected file is not canonical")
            ios_bytes = encode_lines(ios_once)
            android_bytes = encode_lines(android_once)
            expected_ios_bytes = (case_dir / notes["expected"]["ios"]).read_bytes()
            expected_android_bytes = (case_dir / notes["expected"]["android"]).read_bytes()
            if ios_bytes != expected_ios_bytes:
                raise NormError("GOLDEN", name, "normalize(ios) != ios expected bytes")
            if android_bytes != expected_android_bytes:
                raise NormError("GOLDEN", name, "normalize(android) != android expected bytes")
            if notes["kind"] == "equivalent":
                if ios_bytes != android_bytes:
                    raise NormError("GOLDEN", name, "equivalent case normalized differently")
                detail = "equivalent shared expected={}".format(len(expected_ios))
            else:
                if ios_bytes == android_bytes:
                    raise NormError(
                        "GOLDEN", name, "real difference was washed away by normalization"
                    )
                detail = "real-difference preserved ios={} android={}".format(
                    len(expected_ios), len(expected_android)
                )
            passed += 1
            per_case[name] = {
                "kind": notes["kind"],
                "ios": ios_stats.export(KIND_TRAJECTORY),
                "android": android_stats.export(KIND_TRAJECTORY),
            }
            messages.append(
                "PASS golden/trajectory/{}: {} (input ios={} android={})".format(
                    name, detail, len(ios_lines), len(android_lines)
                )
            )
        except NormError as exc:
            messages.append("FAIL golden/trajectory/{}: {}".format(name, exc))
    messages.append(
        "SUMMARY {}/{} cases passed; rules={}/{}; window={}".format(
            passed, len(cases), len(RULES), RULE_CAP, WINDOW
        )
    )
    return passed == len(cases), per_case, messages


def main(argv=None):
    parser = argparse.ArgumentParser(description="phone-dsh trajectory / UiState normalizer")
    parser.add_argument("--input", type=Path, help="input JSONL file")
    parser.add_argument("--output", type=Path, help="output JSONL file")
    parser.add_argument(
        "--root",
        type=Path,
        default=REPO_ROOT,
        help="repository root (default: the tree containing this tool)",
    )
    parser.add_argument(
        "--kind",
        choices=("auto", KIND_TRAJECTORY, KIND_UI_STATE),
        default="auto",
        help="row kind; auto reads schemaVersion",
    )
    parser.add_argument("--platform", choices=("ios", "android"), default=None)
    parser.add_argument("--check-golden", action="store_true", help="run all golden cases")
    parser.add_argument("--stats", action="store_true", help="print normalization counters")
    args = parser.parse_args(argv)
    root = args.root.resolve()

    if args.check_golden:
        ok, per_case, messages = check_golden(root)
        for message in messages:
            print(message)
        if args.stats:
            print(
                "STATS "
                + json.dumps(per_case, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
            )
        return 0 if ok else 1

    if args.input is None or args.output is None:
        parser.error("--input and --output are required unless --check-golden is used")
    kind = None if args.kind == "auto" else args.kind
    schemas = load_schemas(root)
    text = _read_text(args.input)
    stats = _Stats()
    first = normalize(
        text.splitlines(),
        RULES,
        kind=kind,
        platform=args.platform,
        stats=stats,
        schemas=schemas,
    )
    second = normalize(
        text.splitlines(),
        RULES,
        kind=kind,
        platform=args.platform,
        schemas=schemas,
    )
    if first != second:
        print("FAIL: normalization is not deterministic", file=sys.stderr)
        return 2
    _write_bytes_atomic(args.output, encode_lines(first))
    if args.stats:
        print(json.dumps(stats.export(stats.data.get("kind", kind or KIND_TRAJECTORY)),
                         ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except NormError as exc:
        print("FAIL: {}".format(exc), file=sys.stderr)
        sys.exit(1)
