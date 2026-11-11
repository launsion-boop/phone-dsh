#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Independent encoder and conformance checker for the phone-dsh-v1 specification.

The tool shares no code with the Swift or TypeScript codecs. It re-encodes every golden frame
from its semantic ``fields`` (canonical JSON for JSON payloads), recomputes CRC32C, validates the
JSON payload schemas with a small built-in validator, checks the documentation coverage rules of
D16, and validates the WAL vectors, the WAL replay-semantics vectors, the manifest schema and the
handoff endpoint schemas. ``--full`` makes the WAL, exec, handoff and budgets documents, the manifest
schema, the WAL vectors and the replay vectors mandatory.

Usage:
    python3 spec/v1/tools/spec_golden.py [--spec-dir DIR] [--full]

Exit code 0 on success, 1 on any mismatch, 2 on a usage or I/O error.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants fixed by the contract.
# ---------------------------------------------------------------------------

HEADER_MAGIC = 0x5A4C
HEADER_LEN = 16
MAX_FRAME_LEN = 16 * 1024 * 1024
MAX_API_BODY = 4 * 1024 * 1024
MAX_FILE_BYTES = 15 * 1024 * 1024
U64_MAX = 0xFFFFFFFFFFFFFFFF
U32_MAX = 0xFFFFFFFF

WAL_MAGIC = b"XLWAL1\x00\x00"
WAL_HEADER_PREFIX_LEN = 36
WAL_HEADER_LEN = 40
WAL_FORMAT = 1
WAL_EPOCH_CLOSE_OP = 0xFF

# Hand-computed 40-byte WAL header: magic | format 1 | reserved 0 | first_mseq 1 |
# 16 zero boot_id bytes | crc32c of the preceding 36 bytes.
WAL_HEADER_CONSTANT_HEX = (
    "584c57414c310000000100000000000000000001000000000000000000000000000000000b0f9536"
)
WAL_HEADER_CONSTANT_CRC32C = 0x0B0F9536
WAL_SEGMENT_RE = re.compile(r"^wal/[0-9]{8}\.[0-9]{6}\.xlwal$")
WAL_VECTOR_FILES = ("segment-1.json", "segment-epoch-only.json")
WAL_LIFECYCLE_DIR = "golden/wal/lifecycle"
WAL_LIFECYCLE_VECTOR_FILES = (
    "unclosed-epoch-below-watermark.json",
    "unclosed-epoch-above-watermark.json",
    "unlisted-stale-relisted.json",
    "unlisted-adopted-tail.json",
    "crash-tail-epoch-above-durable.json",
)
WAL_LIFECYCLE_SEGMENT_RE = re.compile(r"^wal/([0-9]{8})\.([0-9]{6})\.xlwal$")
WAL_LIFECYCLE_EXPECTED_KEYS = {
    "fast_path",
    "verification_pass",
    "has_unclosed_history",
    "replay_records",
    "materialized_upto_mseq",
    "newest_close_segment",
    "dropped_segments",
    "retained_segments",
    "relisted_segments",
    "adopted_tail_segments",
}
WAL_REPLAY_SCHEMA_NAME = "wal-replay.schema.json"
WAL_REPLAY_VECTOR_FILES = (
    "append-full-write-settles.json",
    "append-truncate-settles.json",
    "append-remove-settles.json",
    "append-ancestor-remove-settles.json",
    "live-repair-write-settles.json",
    "recovery-rebuilds-from-wal.json",
    "append-already-applied-skips.json",
    "intervening-append-covered-settles.json",
    "settled-watermark-waits-for-cover.json",
    "append-only-stays-held.json",
    "cover-before-append-stays-held.json",
    "cover-other-path-stays-held.json",
    "dependent-append-not-covered-stays-held.json",
    "retained-not-from-one-stays-failed.json",
)
WAL_REPLAY_VERDICTS = (
    "applied",
    "skipped-idempotent",
    "settled-superseded",
    "mismatch-held",
    "already-materialized",
)
WAL_REPLAY_COVERS = (
    "complete-write",
    "truncate",
    "remove",
    "ancestor-remove",
    "repair-write",
)
MANIFEST_SCHEMA_NAME = "manifest.schema.json"
MANIFEST_FIELDS = (
    "format",
    "boot_id",
    "materialized_upto_mseq",
    "last_mseq",
    "last_durable_epoch",
    "segments",
)

# Hand-computed 16-byte header for type 0x11, seq 1, payload len 9:
# 5a4c | 11 | 00 | 0000000000000001 | 00000009
FRAME_HEADER_CONSTANT_HEX = "5a4c1100000000000000000100000009"

TYPE_NAMES = {
    0x01: "HELLO",
    0x10: "VFS_MUT",
    0x11: "VFS_ACK",
    0x12: "VFS_BARRIER",
    0x13: "VFS_RESYNC",
    0x20: "EXEC_REQ",
    0x21: "EXEC_EVT",
    0x22: "EXEC_CTL",
    0x30: "JOURNAL",
    0x31: "JOURNAL_ACK",
    0x40: "API_REQ",
    0x41: "API_RES",
    0x42: "API_END",
    0x43: "API_ABORT",
    0x50: "LIFECYCLE",
    0x60: "CONSOLE",
    0x70: "FENCE",
    0x7F: "ERROR",
}

JSON_FRAME_TYPES = frozenset({0x01, 0x20, 0x21, 0x22, 0x50, 0x60, 0x70, 0x7F})

CORE_SCHEMAS = (
    "hello.schema.json",
    "exec-req.schema.json",
    "exec-ctl.schema.json",
    "lifecycle.schema.json",
    "fence.schema.json",
    "error.schema.json",
    "console.schema.json",
    "api-request-head.schema.json",
    "api-response-head.schema.json",
)

# A core schema is exercised by at least one vector of these frame types.
SCHEMA_VECTORS = {
    "hello.schema.json": (0x01,),
    "exec-req.schema.json": (0x20,),
    "exec-ctl.schema.json": (0x22,),
    "lifecycle.schema.json": (0x50,),
    "fence.schema.json": (0x70,),
    "error.schema.json": (0x7F,),
    "console.schema.json": (0x60,),
    "api-request-head.schema.json": (0x40,),
    "api-response-head.schema.json": (0x41,),
}

FRAME_SCHEMAS = {
    0x01: "hello.schema.json",
    0x20: "exec-req.schema.json",
    0x22: "exec-ctl.schema.json",
    0x50: "lifecycle.schema.json",
    0x70: "fence.schema.json",
    0x7F: "error.schema.json",
    0x60: "console.schema.json",
}

# Document line caps (D16). The three Android-port documents carry their own cap so the
# "short normative, long explanatory" discipline survives outside the original five.
LINE_CAPS = {
    # D16 amendment: the VFS_ACK level-2 rule was scoped and JOURNAL_ACK's level
    # clarified. Both were silent ambiguities a port had to resolve, and resolving
    # them per implementation is how two hosts end up disagreeing on the wire.
    "channel.md": 365,
    # D16 amendment (2026-10-31): the WAL recovery rules had drifted behind the
    # reference implementation in three places (stale-segment retention, the
    # reconcile trigger, the manifest-range rule). Writing them down needs lines;
    # the cap moves 320 -> 340 rather than leaving the document wrong.
    # D16 amendment: the seven readings a port had to infer for §9 (compaction timing,
    # which segment is "the newest close", what proves an epoch durable, the fsync for a
    # removed path, whether the close record is charged, how much to drop, and whether
    # the 512 MiB is per workspace) are contract text now.
    # D16 amendment (2026-11-04): CCR-1 freezes the fourth D9 verdict,
    # `superseded`: a later complete write or remove of the path (or an
    # ancestor) settles an appended record before the base check. The rule
    # needs its priority, its "only covered bytes" limit and the live-repair
    # settlement; CCR-2 also writes the boot resync order into §5.1/§7.2. Round
    # 2 of the review made settlement conservative: a settled record is passed
    # by the contiguous watermark only once its cover is applied and inside the
    # same prefix, so §5.1, §6.2, §7, §7.1 and §10 all need that rule. This is
    # new normative text, not prose, and deleting another rule to make room is
    # not an option. The cap moves 374 -> 412 (the 398 freeze plus the
    # conservative-settlement sentences and their manifest invariant).
    # D16 amendment (2026-11-09, PC-20261109-wal-durable-epoch-truncation):
    # §9's decided reading now states that a listed epoch at or below
    # `last_durable_epoch` is durable without its own retained close record and
    # is not "unclosed history" for §10. The cap moves 412 -> 416.
    # D16 amendment (2026-11-12, PC-20261112-w4-writepath-append):
    # §11 registers the read-only session projection (W1), §12 fixes the
    # epoch-close reclamation trigger (W3), and §13 fixes the watermark and
    # idle-epoch reading (W4). These are contract rules, not prose. The cap
    # moves 416 -> 510.
    "wal.md": 510,
    # D16 amendment: `unsupported` was defined as "only an unadvertised argv[0]", but the
    # host also refuses request shapes it cannot honour (no stdin channel, protocol-level
    # refusal). The implementation and the spec disagreed; the spec was the narrower one.
    # D16 amendment (2026-11-12, PC-20261112-w2/w4): §7 fixes step and journal
    # retention; §8 fixes the append-only durable record formats. The cap moves
    # 232 -> 300.
    "exec.md": 300,
    "handoff.md": 200,
    # D16 amendment (2026-11-12, PC-20261112-w0/w2/w3): §7 adds the target
    # performance rows, §8 makes the existing journal prune rule precise, §9 adds
    # the aggregate host-internal budget and its five levels. The cap moves
    # 200 -> 320.
    "budgets.md": 320,
    # D16 amendment: §12 is **new normative text**, not a document that outgrew its
    # cap. It gives a home to a contract that had none: `ubuntu.exec` /
    # `ubuntu.status` / `ubuntu.fetch`, the job state machine with its exhaustive
    # transition table and boot mapping, the two audit fields (`egress` and
    # `authorityExited`, which may not be merged), the artifact ingest limits and
    # the failure table that reuses the existing provider vocabulary. The cap moves
    # 200 -> 487 because that text exists nowhere else, and a shorter version would
    # leave the two ports free to disagree about a security surface. The duplicated
    # cap in `tools/bridge_check.py` now reads this value instead of restating it.
    "bridge.md": 487,
    # D16 amendment: the two release-blocking rules move from "known gap" to
    # "enforced", which needs lines to say what is now required.
    # D16 amendment: the redirect, refusal-surface and number-rendering rules the
    # Kotlin port had to infer are now written down.
    # D16 amendment (2026-11-12, PC-20261112-w3/w7): §11 fixes response-log
    # retention, §12 the content-key recipe, §13 streaming arrival and the delta
    # merge bound. The cap moves 240 -> 330.
    "gateway-security.md": 330,
    # D16 amendment (2026-10-31): the UiState `kind` vocabulary gained `context`
    # (an injected user-role block). A new legal kind needs one sentence saying
    # what it carries and which member names the injector; the alternative is a
    # kind no reader can interpret. The cap moves 180 -> 182.
    "trajectory.md": 182,
}

REQUIRED_DOCS = ("README.md", "channel.md")
FULL_DOCS = ("wal.md", "exec.md", "handoff.md", "budgets.md")

# Handoff endpoint schemas (D15): one request and one response file per endpoint plus the shared
# error envelope. The binary endpoints carry their metadata as canonical JSON inside the body
# (handoff.md §3-§5).
HANDOFF_ENDPOINTS = (
    (
        "/v1/handoff/fence",
        "handoff-fence-request.schema.json",
        "handoff-fence-response.schema.json",
    ),
    (
        "/v1/handoff/snapshot",
        "handoff-snapshot-request.schema.json",
        "handoff-snapshot-response.schema.json",
    ),
    (
        "/v1/handoff/segments",
        "handoff-segments-request.schema.json",
        "handoff-segments-response.schema.json",
    ),
    (
        "/v1/handoff/reclaim",
        "handoff-reclaim-request.schema.json",
        "handoff-reclaim-response.schema.json",
    ),
)
HANDOFF_ERROR_SCHEMA = "handoff-error.schema.json"
HANDOFF_SCHEMAS = tuple(
    name for _, request, response in HANDOFF_ENDPOINTS for name in (request, response)
) + (HANDOFF_ERROR_SCHEMA,)
HANDOFF_SCHEMA_PREFIX = "handoff-"
# 272 MiB: the 256 MiB WAL quota plus the tar headers of the segment bundle.
MAX_HANDOFF_PAYLOAD = 285212672
HANDOFF_DECISION_NUMBERS = (14, 15, 16)
DECISION_SECTION_RE = re.compile(r"§(\d+)(?:\s*[\u2013-]\s*§?(\d+))?")
DECISION_FILE_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:md|py)")

ERROR_CODES = (
    "BAD_MAGIC",
    "BAD_SEQ",
    "BAD_MSEQ",
    "BAD_PATH",
    "BAD_PAYLOAD",
    "FENCE_STALE",
    "VFS_CONFLICT",
    "RING_TIMEOUT",
    "PROTO_MISMATCH",
)

# EXEC_EVT follows the exec-bridge v1 event types and exit statuses (spec/exec-bridge-v1 §4.1).
EXEC_EVENT_TYPES = ("start", "output", "exit", "quiescent", "error")
EXEC_EXIT_STATUSES = ("exited", "signaled", "cancelled", "timed_out", "rejected", "failed")

WORKER_CAPS = ["channel/1", "vfs-sink/1", "journal/1", "api/1"]
HOST_REQUIRED_CAPS = {"channel/1", "wal/1", "exec/1"}
ACCELERATOR_RE = re.compile(r"^accelerator:[A-Za-z0-9._-]{1,64}$")

PATH_RE = re.compile(r"^/dsh/(home|workspace)(/[^/]+)+$")
IDENT_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
IDEM_KEY_RE = re.compile(r"^[0-9a-f]{64}$")
IDEM_ENV_KEY_RE = re.compile(r"^xl1-[0-9a-f]{32}$")
BOOT_ID_RE = re.compile(r"^[0-9a-f]{32}$")
HEX_RE = re.compile(r"^[0-9a-f]*$")
OWNER_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
FRAME_FILE_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*-\d+\.json$")
SCHEMA_REF_RE = re.compile(r"schema/([A-Za-z0-9._-]+\.schema\.json)")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


class SpecError(Exception):
    """A mismatch in a checked artifact."""


# ---------------------------------------------------------------------------
# CRC32C: Castagnoli, reflected, init/xorout 0xFFFFFFFF.
# ---------------------------------------------------------------------------


def _crc32c_table():
    table = []
    for index in range(256):
        crc = index
        for _ in range(8):
            crc = (crc >> 1) ^ 0x82F63B78 if crc & 1 else crc >> 1
        table.append(crc & 0xFFFFFFFF)
    return table


_CRC32C_TABLE = _crc32c_table()


def crc32c(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc = _CRC32C_TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


# ---------------------------------------------------------------------------
# Header and canonical JSON.
# ---------------------------------------------------------------------------


def encode_header(type_byte, seq, payload_len):
    if isinstance(type_byte, bool) or not isinstance(type_byte, int) or not 0 <= type_byte <= 0xFF:
        raise SpecError("type byte out of range")
    if isinstance(seq, bool) or not isinstance(seq, int) or not 1 <= seq <= U64_MAX:
        raise SpecError("seq outside 1..2^64-1")
    if not 1 <= payload_len <= MAX_FRAME_LEN:
        raise SpecError("payload length outside 1..16 MiB")
    return struct.pack(">HBBQI", HEADER_MAGIC, type_byte, 0, seq, payload_len)


def _walk_json(value, where):
    if isinstance(value, float):
        raise SpecError(f"{where}: canonical JSON allows integers only")
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise SpecError(f"{where}: non-string member name")
            _walk_json(item, f"{where}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _walk_json(item, f"{where}[{index}]")


def canonical_json(value, where="value"):
    _walk_json(value, where)
    try:
        text = json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
        )
    except (TypeError, ValueError) as exc:
        raise SpecError(f"{where}: cannot encode canonical JSON: {exc}") from exc
    return text.encode("utf-8")


# ---------------------------------------------------------------------------
# WAL header and record encoders (independent of the Swift/TypeScript codecs).
# ---------------------------------------------------------------------------


def encode_wal_header(format_value, reserved, first_mseq, boot_id, where="wal.header"):
    """Encode the 40-byte WAL segment header and return ``(crc32c, bytes)``."""

    if _uint(format_value, 16, where + ".format") != WAL_FORMAT:
        raise SpecError(where + ".format: WAL format must be 1")
    if _uint(reserved, 16, where + ".reserved") != 0:
        raise SpecError(where + ".reserved: reserved must be 0")
    mseq = _uint(first_mseq, 64, where + ".first_mseq", minimum=1)
    if not isinstance(boot_id, bytes):
        raise SpecError(where + ".boot_id: expected bytes")
    if len(boot_id) != 16:
        raise SpecError(where + ".boot_id: boot_id must be 16 bytes")
    prefix = WAL_MAGIC + struct.pack(">HHQ", WAL_FORMAT, 0, mseq) + bytes(boot_id)
    if len(prefix) != WAL_HEADER_PREFIX_LEN:
        raise SpecError(where + ": WAL header prefix is not 36 bytes")
    crc = crc32c(prefix)
    return crc, prefix + struct.pack(">I", crc)


def encode_wal_record(mseq, body, where="wal.record"):
    """Encode one WAL record ``len u32 | crc32c u32 | mseq u64 | body``.

    Returns ``(crc32c_of_payload, record_bytes)``.
    """

    if not isinstance(body, bytes):
        raise SpecError(where + ": body must be bytes")
    payload = struct.pack(">Q", _uint(mseq, 64, where + ".mseq")) + body
    if len(payload) > U32_MAX:
        raise SpecError(where + ": WAL record payload exceeds u32")
    crc = crc32c(payload)
    return crc, struct.pack(">II", len(payload), crc) + payload


# ---------------------------------------------------------------------------
# Small JSON Schema 2020-12 validator (the subset used by this spec).
# ---------------------------------------------------------------------------


def _json_type_ok(value, type_name):
    if type_name == "object":
        return isinstance(value, dict)
    if type_name == "array":
        return isinstance(value, list)
    if type_name == "string":
        return isinstance(value, str)
    if type_name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if type_name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if type_name == "boolean":
        return isinstance(value, bool)
    if type_name == "null":
        return value is None
    return False


def _json_equal(left, right):
    if isinstance(left, bool) or isinstance(right, bool):
        return isinstance(left, bool) and isinstance(right, bool) and left == right
    return left == right


def validate_json(instance, schema, where, path="$"):
    """Validate *instance* against the supported JSON Schema subset."""

    if not isinstance(schema, dict):
        raise SpecError(f"{where}: schema at {path} is not an object")

    if "oneOf" in schema:
        variants = schema["oneOf"]
        if not isinstance(variants, list) or not variants:
            raise SpecError(f"{where}: malformed oneOf at {path}")
        matches = 0
        reasons = []
        for variant in variants:
            try:
                validate_json(instance, variant, where, path)
            except SpecError as exc:
                reasons.append(str(exc))
                continue
            matches += 1
        if matches != 1:
            detail = f"; first mismatch: {reasons[0]}" if reasons else ""
            raise SpecError(
                f"{where}: {path} matches {matches} oneOf variants, expected exactly 1{detail}"
            )
        return

    expected = schema.get("type")
    if expected is not None:
        names = expected if isinstance(expected, list) else [expected]
        if not any(_json_type_ok(instance, name) for name in names):
            raise SpecError(
                f"{where}: {path} has type {type(instance).__name__}, expected {names}"
            )

    if "const" in schema and not _json_equal(instance, schema["const"]):
        raise SpecError(f"{where}: {path} value {instance!r} is not {schema['const']!r}")

    if "enum" in schema:
        choices = schema["enum"]
        if not isinstance(choices, list) or not any(
            _json_equal(instance, choice) for choice in choices
        ):
            raise SpecError(f"{where}: {path} value {instance!r} not in enum")

    if isinstance(instance, str):
        pattern = schema.get("pattern")
        if isinstance(pattern, str) and re.fullmatch(pattern, instance) is None:
            raise SpecError(f"{where}: {path} value {instance!r} does not match {pattern!r}")
        minimum_length = schema.get("minLength")
        if isinstance(minimum_length, int) and len(instance) < minimum_length:
            raise SpecError(f"{where}: {path} is shorter than {minimum_length}")
        maximum_length = schema.get("maxLength")
        if isinstance(maximum_length, int) and len(instance) > maximum_length:
            raise SpecError(f"{where}: {path} is longer than {maximum_length}")

    if isinstance(instance, int) and not isinstance(instance, bool):
        minimum = schema.get("minimum")
        if isinstance(minimum, int) and instance < minimum:
            raise SpecError(f"{where}: {path} is below {minimum}")
        maximum = schema.get("maximum")
        if isinstance(maximum, int) and instance > maximum:
            raise SpecError(f"{where}: {path} is above {maximum}")

    if isinstance(instance, dict):
        required = schema.get("required", [])
        if not isinstance(required, list):
            raise SpecError(f"{where}: malformed required at {path}")
        for name in required:
            if name not in instance:
                raise SpecError(f"{where}: {path} missing required member {name!r}")
        properties = schema.get("properties", {})
        if not isinstance(properties, dict):
            raise SpecError(f"{where}: malformed properties at {path}")
        names = schema.get("propertyNames")
        if isinstance(names, dict):
            for name in instance:
                validate_json(name, names, where, f"{path} member name")
        dependent_required = schema.get("dependentRequired", {})
        if not isinstance(dependent_required, dict):
            raise SpecError(f"{where}: malformed dependentRequired at {path}")
        for name, needed in dependent_required.items():
            if not isinstance(needed, list) or not all(isinstance(item, str) for item in needed):
                raise SpecError(f"{where}: malformed dependentRequired at {path}.{name}")
            if name not in instance:
                continue
            for other in needed:
                if other not in instance:
                    raise SpecError(
                        f"{where}: {path} member {name!r} requires {other!r}"
                    )
        additional = schema.get("additionalProperties", True)
        for name, value in instance.items():
            if name in properties:
                validate_json(value, properties[name], where, f"{path}.{name}")
            elif additional is False:
                raise SpecError(f"{where}: {path} has unexpected member {name!r}")
            elif isinstance(additional, dict):
                validate_json(value, additional, where, f"{path}.{name}")

    if isinstance(instance, list):
        minimum_items = schema.get("minItems")
        if isinstance(minimum_items, int) and len(instance) < minimum_items:
            raise SpecError(f"{where}: {path} has fewer than {minimum_items} items")
        maximum_items = schema.get("maxItems")
        if isinstance(maximum_items, int) and len(instance) > maximum_items:
            raise SpecError(f"{where}: {path} has more than {maximum_items} items")
        if schema.get("uniqueItems") is True:
            for left in range(len(instance)):
                for right in range(left + 1, len(instance)):
                    if _json_equal(instance[left], instance[right]):
                        raise SpecError(f"{where}: {path} violates uniqueItems")
        if "items" in schema:
            for index, item in enumerate(instance):
                validate_json(item, schema["items"], where, f"{path}[{index}]")


# ---------------------------------------------------------------------------
# JSON loading: reject duplicate member names everywhere.
# ---------------------------------------------------------------------------


def _pairs_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SpecError(f"duplicate JSON member {key!r}")
        result[key] = value
    return result


def load_json(path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SpecError(f"cannot read: {exc}") from exc
    except UnicodeDecodeError as exc:
        raise SpecError(f"not UTF-8: {exc}") from exc
    try:
        return json.loads(text, object_pairs_hook=_pairs_no_duplicates)
    except SpecError:
        raise
    except json.JSONDecodeError as exc:
        raise SpecError(f"invalid JSON: {exc}") from exc


# ---------------------------------------------------------------------------
# Primitive field helpers.
# ---------------------------------------------------------------------------


def _uint(value, bits, where, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int):
        raise SpecError(f"{where}: expected an integer")
    maximum = (1 << bits) - 1
    if value < minimum or value > maximum:
        raise SpecError(f"{where}: {value} outside {minimum}..{maximum}")
    return value


def _string(value, where):
    if not isinstance(value, str):
        raise SpecError(f"{where}: expected a string")
    return value


def _boolean(value, where):
    if not isinstance(value, bool):
        raise SpecError(f"{where}: expected a boolean")
    return value


def _mapping(value, where, keys):
    if not isinstance(value, dict):
        raise SpecError(f"{where}: expected an object")
    missing = keys - set(value)
    if missing:
        raise SpecError(f"{where}: missing members {sorted(missing)}")
    extra = set(value) - keys
    if extra:
        raise SpecError(f"{where}: unexpected members {sorted(extra)}")
    return value


def _hex_bytes(value, where):
    text = _string(value, where)
    if not HEX_RE.match(text):
        raise SpecError(f"{where}: hex string must be lowercase hex")
    if len(text) % 2 != 0:
        raise SpecError(f"{where}: hex string has odd length")
    try:
        return bytes.fromhex(text)
    except ValueError as exc:
        raise SpecError(f"{where}: invalid hex: {exc}") from exc


def _identifier(value, where):
    text = _string(value, where)
    if not IDENT_RE.match(text):
        raise SpecError(f"{where}: {text!r} violates D6 identifier grammar")
    return text


def _boot_id(value, where):
    text = _string(value, where)
    if not BOOT_ID_RE.match(text):
        raise SpecError(f"{where}: boot_id must be 32 lowercase hex characters")
    return text


def _owner(value, where):
    text = _string(value, where)
    if not OWNER_RE.match(text):
        raise SpecError(f"{where}: {text!r} is not a valid fence owner label")
    return text


def check_path(value, where):
    path = _string(value, where)
    try:
        raw = path.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise SpecError(f"{where}: path is not valid UTF-8: {exc}") from exc
    if "\x00" in path or not PATH_RE.match(path):
        raise SpecError(f"{where}: {path!r} violates the D4 path grammar")
    if any(component in ("", ".", "..") for component in path.split("/")[3:]):
        raise SpecError(f"{where}: {path!r} has a forbidden path component")
    if len(raw) > 0xFFFF:
        raise SpecError(f"{where}: path exceeds the u16 length field")
    return path


# ---------------------------------------------------------------------------
# Payload encoders.
# ---------------------------------------------------------------------------


def encode_mutation_body(fields, where):
    """Wire body of a mutation without the leading mseq (WAL record body)."""

    if not isinstance(fields, dict):
        raise SpecError(f"{where}: fields must be an object")
    keys = {"op", "mode", "mflags", "append_from", "path", "data_len", "data_hex"}
    if "mseq" in fields:
        keys.add("mseq")
    fields = _mapping(fields, where, keys)
    op = _uint(fields["op"], 8, f"{where}.op")
    if op not in (1, 2, 3, 4):
        raise SpecError(f"{where}.op: mutation op must be 1, 2, 3 or 4")
    mode = _uint(fields["mode"], 32, f"{where}.mode")
    if mode > 0o7777:
        raise SpecError(f"{where}.mode: permission bits above 0o7777")
    mflags = _uint(fields["mflags"], 8, f"{where}.mflags")
    if mflags & ~0x03:
        raise SpecError(f"{where}.mflags: only bits 0 and 1 exist")
    append_from = _uint(fields["append_from"], 64, f"{where}.append_from")
    path = check_path(fields["path"], f"{where}.path")
    data = _hex_bytes(fields["data_hex"], f"{where}.data_hex")
    data_len = _uint(fields["data_len"], 32, f"{where}.data_len")
    if data_len != len(data):
        raise SpecError(f"{where}: data_len {data_len} != decoded data length {len(data)}")
    appended = bool(mflags & 0x02)
    if appended:
        if op != 1:
            raise SpecError(f"{where}: only a write may set the appended bit")
    elif append_from != 0:
        raise SpecError(f"{where}: append_from must be 0 when not appended")
    if op == 3 and mode != 0:
        raise SpecError(f"{where}: remove must carry mode 0")
    if op != 1:
        if mflags != 0 or append_from != 0 or data:
            raise SpecError(f"{where}: mkdir/remove/chmod carry no data, flags or append_from")
    if op == 1 and len(data) > MAX_FILE_BYTES:
        raise SpecError(f"{where}: mutation data exceeds the 15 MiB file cap")
    path_bytes = path.encode("utf-8")
    body = (
        struct.pack(">BIBQH", op, mode, mflags, append_from, len(path_bytes))
        + path_bytes
        + struct.pack(">I", len(data))
        + data
    )
    if len(body) + 8 > MAX_FRAME_LEN:
        raise SpecError(f"{where}: mutation frame exceeds the 16 MiB frame cap")
    return body


def encode_epoch_close_body(fields, where):
    """WAL epoch-close body (used by the optional WAL vectors)."""

    fields = _mapping(fields, where, {"mseq", "op", "wall_ms", "durable_upto"})
    if _uint(fields["op"], 8, f"{where}.op") != WAL_EPOCH_CLOSE_OP:
        raise SpecError(f"{where}.op: epoch-close op must be 0xFF")
    wall_ms = _uint(fields["wall_ms"], 64, f"{where}.wall_ms")
    durable = _uint(fields["durable_upto"], 64, f"{where}.durable_upto")
    mseq = _uint(fields["mseq"], 64, f"{where}.mseq")
    if mseq != durable:
        raise SpecError(f"{where}: epoch-close mseq must equal durable_upto (D7)")
    return mseq, struct.pack(">BQQ", 0xFF, wall_ms, durable)


def encode_frame_payload(type_byte, fields, where):
    if type_byte in JSON_FRAME_TYPES:
        if not isinstance(fields, dict):
            raise SpecError(f"{where}: JSON frame fields must be an object")
        return canonical_json(fields, where)

    if not isinstance(fields, dict):
        raise SpecError(f"{where}: fields must be an object")

    if type_byte == 0x10:  # VFS_MUT
        fields = _mapping(
            fields,
            where,
            {"mseq", "op", "mode", "mflags", "append_from", "path", "data_len", "data_hex"},
        )
        mseq = _uint(fields["mseq"], 64, f"{where}.mseq", minimum=1)
        return struct.pack(">Q", mseq) + encode_mutation_body(fields, where)

    if type_byte == 0x11:  # VFS_ACK
        fields = _mapping(fields, where, {"level", "upto_mseq"})
        level = _uint(fields["level"], 8, f"{where}.level")
        if level not in (1, 2):
            raise SpecError(f"{where}.level: ack level must be 1 or 2")
        return struct.pack(">BQ", level, _uint(fields["upto_mseq"], 64, f"{where}.upto_mseq"))

    if type_byte == 0x12:  # VFS_BARRIER
        fields = _mapping(fields, where, {"want_level", "upto_mseq"})
        level = _uint(fields["want_level"], 8, f"{where}.want_level")
        if level not in (1, 2):
            raise SpecError(f"{where}.want_level: barrier level must be 1 or 2")
        return struct.pack(">BQ", level, _uint(fields["upto_mseq"], 64, f"{where}.upto_mseq"))

    if type_byte == 0x13:  # VFS_RESYNC
        fields = _mapping(fields, where, {"path"})
        path = check_path(fields["path"], f"{where}.path").encode("utf-8")
        return struct.pack(">H", len(path)) + path

    if type_byte == 0x30:  # JOURNAL
        fields = _mapping(fields, where, {"jseq", "session_id", "record_hex"})
        jseq = _uint(fields["jseq"], 64, f"{where}.jseq", minimum=1)
        session = _identifier(fields["session_id"], f"{where}.session_id").encode("utf-8")
        record = _hex_bytes(fields["record_hex"], f"{where}.record_hex")
        if not record:
            raise SpecError(f"{where}: journal record must not be empty")
        return struct.pack(">QH", jseq, len(session)) + session + record

    if type_byte == 0x31:  # JOURNAL_ACK
        fields = _mapping(fields, where, {"level", "session_id", "upto_jseq"})
        level = _uint(fields["level"], 8, f"{where}.level")
        if level not in (1, 2):
            raise SpecError(f"{where}.level: ack level must be 1 or 2")
        session = _identifier(fields["session_id"], f"{where}.session_id").encode("utf-8")
        return (
            struct.pack(">BH", level, len(session))
            + session
            + struct.pack(">Q", _uint(fields["upto_jseq"], 64, f"{where}.upto_jseq"))
        )

    if type_byte == 0x40:  # API_REQ
        fields = _mapping(fields, where, {"req_id", "head", "body_hex"})
        req_id = _uint(fields["req_id"], 32, f"{where}.req_id")
        if not isinstance(fields["head"], dict):
            raise SpecError(f"{where}.head: expected a JSON object")
        head = canonical_json(fields["head"], f"{where}.head")
        if not head:
            raise SpecError(f"{where}.head: head must not be empty")
        body = _hex_bytes(fields["body_hex"], f"{where}.body_hex")
        if len(body) > MAX_API_BODY:
            raise SpecError(f"{where}: API_REQ body exceeds 4 MiB")
        payload = struct.pack(">II", req_id, len(head)) + head + body
        if len(payload) > MAX_FRAME_LEN:
            raise SpecError(f"{where}: API_REQ exceeds the frame cap")
        return payload

    if type_byte == 0x41:  # API_RES
        fields = _mapping(fields, where, {"req_id", "head", "body_hex"})
        req_id = _uint(fields["req_id"], 32, f"{where}.req_id")
        head_value = fields["head"]
        if head_value is None:
            head = b""
        elif isinstance(head_value, dict):
            head = canonical_json(head_value, f"{where}.head")
        else:
            raise SpecError(f"{where}.head: expected an object or null")
        body = _hex_bytes(fields["body_hex"], f"{where}.body_hex")
        payload = struct.pack(">II", req_id, len(head)) + head + body
        if len(payload) > MAX_FRAME_LEN:
            raise SpecError(f"{where}: API_RES exceeds the frame cap")
        return payload

    if type_byte == 0x42:  # API_END
        fields = _mapping(fields, where, {"req_id"})
        return struct.pack(">I", _uint(fields["req_id"], 32, f"{where}.req_id"))

    if type_byte == 0x43:  # API_ABORT
        fields = _mapping(fields, where, {"req_id", "reason"})
        req_id = _uint(fields["req_id"], 32, f"{where}.req_id")
        reason = _string(fields["reason"], f"{where}.reason")
        return struct.pack(">I", req_id) + canonical_json({"reason": reason}, f"{where}.reason")

    raise SpecError(f"{where}: no encoder for type byte 0x{type_byte:02X}")


def encode_frame(type_byte, seq, fields, where):
    payload = encode_frame_payload(type_byte, fields, where)
    return encode_header(type_byte, seq, len(payload)) + payload


# ---------------------------------------------------------------------------
# Reporting: one line per checked file.
# ---------------------------------------------------------------------------


class Reporter:
    def __init__(self):
        self.entries = {}

    def add(self, rel):
        self.entries.setdefault(rel, [])

    def fail(self, rel, message):
        self.add(rel)
        self.entries[rel].append(message)

    def emit(self):
        errors = 0
        for rel in sorted(self.entries):
            messages = self.entries[rel]
            if messages:
                errors += len(messages)
                print("FAIL {}: {}".format(rel, " | ".join(messages)))
            else:
                print("ok {}".format(rel))
        print("{} files checked, {} error(s)".format(len(self.entries), errors))
        return errors


# ---------------------------------------------------------------------------
# Documentation, schemas and coverage.
# ---------------------------------------------------------------------------


def read_text(spec_dir, rel, rep):
    rep.add(rel)
    try:
        return (spec_dir / rel).read_text(encoding="utf-8")
    except OSError as exc:
        rep.fail(rel, "cannot read: {}".format(exc))
        return ""
    except UnicodeDecodeError as exc:
        rep.fail(rel, "not UTF-8: {}".format(exc))
        return ""


def check_docs(spec_dir, rep, full):
    texts = {}
    for name in REQUIRED_DOCS:
        texts[name] = read_text(spec_dir, name, rep)
    for name in LINE_CAPS:
        path = spec_dir / name
        if not path.is_file():
            if full and name in FULL_DOCS:
                rep.fail(name, "required by --full but missing")
            continue
        if name not in texts:
            texts[name] = read_text(spec_dir, name, rep)
        lines = len(texts[name].splitlines())
        if lines > LINE_CAPS[name]:
            rep.fail(name, "{} lines exceeds the D16 cap of {}".format(lines, LINE_CAPS[name]))
    if full and not (spec_dir / "golden" / "wal").is_dir():
        rep.add("golden/wal")
        rep.fail("golden/wal", "required by --full but missing")
    return texts


DECISION_COUNT = 20
INTERNAL_TASK_ID = "W0" + "-SPEC"
D16_REQUIRED_TEXT = "wal.md ≤ 320"


def _split_table_row(line):
    """Split a Markdown table row on unescaped pipes."""

    if not line.startswith("|") or not line.rstrip().endswith("|"):
        return None
    cells = []
    current = []
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\" and index + 1 < len(line) and line[index + 1] == "|":
            current.append("|")
            index += 2
            continue
        if char == "|":
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        index += 1
    cells.append("".join(current).strip())
    if len(cells) < 3:
        return None
    return cells[1:-1]


def check_decisions(readme, rep):
    if "Decisions" not in readme:
        rep.fail("README.md", "README has no Decisions section")
        return {}
    found = {}
    for line in readme.splitlines():
        cells = _split_table_row(line)
        if cells is None or len(cells) != 3:
            continue
        match = re.fullmatch(r"D(\d+)", cells[0])
        if not match:
            continue
        number = int(match.group(1))
        summary = cells[1]
        where = cells[2]
        if number in found:
            rep.fail("README.md", "decision D{} listed more than once".format(number))
        if not summary:
            rep.fail("README.md", "decision D{} has no summary".format(number))
        found[number] = (summary, where)
    missing = sorted(set(range(1, DECISION_COUNT + 1)) - set(found))
    if missing:
        rep.fail("README.md", "Decisions table is missing {}".format(missing))
    extra = sorted(set(found) - set(range(1, DECISION_COUNT + 1)))
    if extra:
        rep.fail("README.md", "Decisions table has out-of-range entries {}".format(extra))
    for number, (_, where) in sorted(found.items()):
        if not where or (".md" not in where and "tools/" not in where):
            rep.fail("README.md", "decision D{} does not name an implementing section".format(number))
    d16 = found.get(16, ("", ""))[0]
    if D16_REQUIRED_TEXT not in d16:
        rep.fail("README.md", "decision D16 must state {}".format(D16_REQUIRED_TEXT))
    # D4's quoted wording still carries the pre-revision 15 MiB single-file cap.
    # The large-file budget revision moves the cap to the budgets.md §4 tier
    # table and keeps 15 MiB only as the per-mutation bound; the D4 row must say
    # where the binding limit now lives, or readers see two caps.
    d4_summary, d4_where = found.get(4, ("", ""))
    if "budgets.md §4" not in d4_summary and "budgets.md" not in d4_where:
        rep.fail("README.md", "decision D4 must point at the budgets.md §4 single-file revision")
    return found


def check_schemas(spec_dir, rep, texts):
    schema_dir = spec_dir / "schema"
    present = set()
    if schema_dir.is_dir():
        present = {path.name for path in schema_dir.glob("*.schema.json")}
    schemas = {}
    for name in sorted(present):
        rel = "schema/" + name
        rep.add(rel)
        try:
            schema = load_json(schema_dir / name)
        except SpecError as exc:
            rep.fail(rel, str(exc))
            continue
        if not isinstance(schema, dict):
            rep.fail(rel, "schema is not an object")
            continue
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            rep.fail(rel, "$schema is not JSON Schema 2020-12")
            continue
        schemas[name] = schema
    for name in CORE_SCHEMAS:
        if name not in present:
            rep.fail("schema/" + name, "core schema file is missing")
    docs = "\n".join(texts.values())
    referenced = set(SCHEMA_REF_RE.findall(docs))
    for name in sorted(present):
        if name not in referenced and name in CORE_SCHEMAS:
            rep.fail("schema/" + name, "core schema is not referenced by any document")
    for name in CORE_SCHEMAS:
        if name not in referenced:
            rep.fail("README.md", "core schema {} is not referenced by any document".format(name))
    return schemas


def check_frame_vector(spec_dir, path, rep, schemas, coverage):
    rel = str(path.relative_to(spec_dir))
    rep.add(rel)
    try:
        doc = load_json(path)
        if not isinstance(doc, dict):
            raise SpecError("vector is not a JSON object")
        expected_members = {"type", "type_byte", "seq", "fields", "payload_hex", "frame_hex"}
        if set(doc) != expected_members:
            raise SpecError(
                "vector members must be exactly type/type_byte/seq/fields/payload_hex/frame_hex"
            )
        type_name = doc["type"]
        type_byte = doc["type_byte"]
        seq = doc["seq"]
        if isinstance(type_byte, bool) or not isinstance(type_byte, int):
            raise SpecError("type_byte must be an integer")
        if type_byte not in TYPE_NAMES:
            raise SpecError("unknown type byte 0x{:02X}".format(type_byte))
        if type_name != TYPE_NAMES[type_byte]:
            raise SpecError("type {!r} does not match byte 0x{:02X}".format(type_name, type_byte))
        if isinstance(seq, bool) or not isinstance(seq, int) or not 1 <= seq <= U64_MAX:
            raise SpecError("seq must be an integer in 1..2^64-1")
        if type_byte == 0x01 and seq != 1:
            raise SpecError("HELLO must be seq 1 (D1)")
        if not FRAME_FILE_RE.match(path.name):
            raise SpecError("file name must be <type-name>-<n>.json")
        fields = doc["fields"]
        if not isinstance(fields, dict):
            raise SpecError("fields must be an object")

        expected_payload = encode_frame_payload(type_byte, fields, rel)
        payload = _hex_bytes(doc["payload_hex"], rel + ".payload_hex")
        if payload != expected_payload:
            raise SpecError(
                "payload mismatch: stored {}, encoded {}".format(
                    payload.hex(), expected_payload.hex()
                )
            )
        expected_frame = encode_header(type_byte, seq, len(expected_payload)) + expected_payload
        frame = _hex_bytes(doc["frame_hex"], rel + ".frame_hex")
        if frame != expected_frame:
            raise SpecError("frame mismatch: stored {}, encoded {}".format(frame.hex(), expected_frame.hex()))

        schema_name = FRAME_SCHEMAS.get(type_byte)
        if schema_name is not None:
            if schema_name not in schemas:
                raise SpecError("schema {} is unavailable".format(schema_name))
            validate_json(fields, schemas[schema_name], rel)

        if type_byte == 0x01:
            check_hello(fields, rel)
        elif type_byte == 0x20:
            check_exec_req(fields, rel)
        elif type_byte == 0x21:
            check_exec_event(fields, rel)
        elif type_byte == 0x30:
            if not _hex_bytes(fields.get("record_hex"), rel + ".fields.record_hex"):
                raise SpecError("journal record must not be empty")
        elif type_byte == 0x40:
            if "api-request-head.schema.json" not in schemas:
                raise SpecError("api-request-head schema is unavailable")
            validate_json(fields.get("head"), schemas["api-request-head.schema.json"], rel + ".head")
            _uint(fields.get("req_id"), 32, rel + ".fields.req_id")
        elif type_byte == 0x41:
            head = fields.get("head")
            if head is not None:
                if "api-response-head.schema.json" not in schemas:
                    raise SpecError("api-response-head schema is unavailable")
                validate_json(head, schemas["api-response-head.schema.json"], rel + ".head")
            _uint(fields.get("req_id"), 32, rel + ".fields.req_id")
        elif type_byte == 0x42:
            _uint(fields.get("req_id"), 32, rel + ".fields.req_id")
        elif type_byte == 0x43:
            _uint(fields.get("req_id"), 32, rel + ".fields.req_id")
            _string(fields.get("reason"), rel + ".fields.reason")

        coverage.setdefault(type_byte, []).append(doc)
    except SpecError as exc:
        rep.fail(rel, str(exc))


def check_hello(fields, rel):
    role = fields.get("role")
    caps = fields.get("caps")
    if role == "worker":
        if caps != WORKER_CAPS:
            raise SpecError("worker HELLO caps must be exactly {}".format(WORKER_CAPS))
    elif role == "host":
        if not isinstance(caps, list) or not all(isinstance(cap, str) for cap in caps):
            raise SpecError("host HELLO caps must be an array of strings")
        missing = HOST_REQUIRED_CAPS - set(caps)
        if missing:
            raise SpecError("host HELLO is missing capabilities {}".format(sorted(missing)))
        for cap in caps:
            if cap not in HOST_REQUIRED_CAPS and not ACCELERATOR_RE.match(cap):
                raise SpecError("host HELLO has an unknown capability {!r}".format(cap))
        next_mseq = _uint(fields.get("next_mseq"), 64, rel + ".fields.next_mseq", minimum=1)
        acked = _uint(fields.get("acked_mseq"), 64, rel + ".fields.acked_mseq")
        durable = _uint(fields.get("durable_mseq"), 64, rel + ".fields.durable_mseq")
        if next_mseq != acked + 1:
            raise SpecError("host HELLO next_mseq must equal acked_mseq + 1")
        if durable > acked:
            raise SpecError("host HELLO durable_mseq must not exceed acked_mseq")
    else:
        raise SpecError("HELLO role must be host or worker")
    fence = fields.get("fence")
    if not isinstance(fence, dict):
        raise SpecError("HELLO fence must be an object")
    _owner(fence.get("owner"), rel + ".fields.fence.owner")
    _uint(fence.get("generation"), 64, rel + ".fields.fence.generation")
    _uint(fence.get("wal_seq"), 64, rel + ".fields.fence.wal_seq")
    _boot_id(fields.get("boot_id"), rel + ".fields.boot_id")


def check_exec_req(fields, rel):
    """Check the D10 idem_key derivation pinned by the EXEC_REQ golden vector."""

    idem = fields.get("idem_key")
    if not isinstance(idem, str) or not IDEM_KEY_RE.match(idem):
        raise SpecError(rel + ".fields.idem_key must be 64 lowercase hex characters")
    env = fields.get("env")
    if env is None:
        env = {}
    if not isinstance(env, dict):
        raise SpecError(rel + ".fields.env must be an object")
    journal_key = env.get("XL_IDEMPOTENCY_KEY")
    if journal_key is None:
        # The fallback first segment (session_id/turn_id/step_id) is not on the wire,
        # so a vector without XL_IDEMPOTENCY_KEY cannot be re-derived here.
        return
    if not isinstance(journal_key, str) or not IDEM_ENV_KEY_RE.match(journal_key):
        raise SpecError(rel + ".fields.env.XL_IDEMPOTENCY_KEY must look like xl1-<32 hex>")
    env_hash = hashlib.sha256(canonical_json(env, rel + ".fields.env")).hexdigest()
    material = (
        journal_key.encode("utf-8")
        + b"\x1f"
        + canonical_json(fields.get("argv"), rel + ".fields.argv")
        + b"\x1f"
        + _string(fields.get("cwd"), rel + ".fields.cwd").encode("utf-8")
        + b"\x1f"
        + env_hash.encode("ascii")
    )
    expected = hashlib.sha256(material).hexdigest()
    if idem != expected:
        raise SpecError(rel + ".fields.idem_key does not match the D10 derivation")


def check_exec_event(fields, rel):
    event_type = fields.get("type")
    if event_type not in EXEC_EVENT_TYPES:
        raise SpecError("EXEC_EVT type must be {}".format("/".join(EXEC_EVENT_TYPES)))
    _identifier(fields.get("exec_id"), rel + ".fields.exec_id")
    seq = fields.get("seq")
    if isinstance(seq, bool) or not isinstance(seq, int) or seq < 0:
        raise SpecError("EXEC_EVT seq must be a non-negative integer")
    if event_type == "output":
        if fields.get("stream") not in ("stdout", "stderr"):
            raise SpecError("EXEC_EVT output stream must be stdout or stderr")
        _string(fields.get("data"), rel + ".fields.data")
    if event_type == "exit":
        for name in ("status", "quiescent"):
            if name not in fields:
                raise SpecError("EXEC_EVT exit event is missing {}".format(name))
        if fields.get("status") not in EXEC_EXIT_STATUSES:
            raise SpecError(
                "EXEC_EVT exit status must be {}".format("/".join(EXEC_EXIT_STATUSES))
            )
        _boolean(fields.get("quiescent"), rel + ".fields.quiescent")
    if event_type == "error":
        _string(fields.get("code"), rel + ".fields.code")
        _string(fields.get("message"), rel + ".fields.message")


def check_coverage(rep, coverage, schemas):
    expected = set(TYPE_NAMES)
    present = set(coverage)
    if present != expected:
        missing = sorted("0x{:02X}".format(value) for value in expected - present)
        rep.fail("golden/frames", "no golden frame for type bytes {}".format(missing))

    mutations = coverage.get(0x10, [])

    def mutation_fields(doc):
        return doc.get("fields", {})

    if not any(
        mutation_fields(doc).get("op") == 1
        and mutation_fields(doc).get("append_from", 0) > 0
        and mutation_fields(doc).get("mflags", 0) & 0x02
        for doc in mutations
    ):
        rep.fail("golden/README.md", "missing VFS_MUT appended variant with append_from > 0")
    if not any(
        mutation_fields(doc).get("op") == 1 and _is_non_utf8(mutation_fields(doc).get("data_hex"))
        for doc in mutations
    ):
        rep.fail("golden/README.md", "missing VFS_MUT variant with non-UTF-8 data")
    if not any(mutation_fields(doc).get("op") == 3 for doc in mutations):
        rep.fail("golden/README.md", "missing VFS_MUT remove variant")
    if not any(mutation_fields(doc).get("op") == 4 for doc in mutations):
        rep.fail("golden/README.md", "missing VFS_MUT chmod variant")

    api_res = coverage.get(0x41, [])
    if not any(doc.get("fields", {}).get("head") is None for doc in api_res):
        rep.fail("golden/README.md", "missing API_RES continuation with head_len 0")
    if not any(
        isinstance(doc.get("fields", {}).get("head"), dict)
        and doc.get("fields", {}).get("body_hex") == ""
        for doc in api_res
    ):
        rep.fail("golden/README.md", "missing API_RES with a zero-length body")

    hellos = coverage.get(0x01, [])
    roles = {doc.get("fields", {}).get("role") for doc in hellos}
    if not {"host", "worker"} <= roles:
        rep.fail("golden/README.md", "HELLO needs a host and a worker variant")
    if not any(isinstance(doc.get("fields", {}).get("head"), dict) for doc in api_res):
        rep.fail("golden/README.md", "API_RES needs a first chunk with a head object")

    for name, type_bytes in sorted(SCHEMA_VECTORS.items()):
        if not any(coverage.get(type_byte) for type_byte in type_bytes):
            rep.fail("golden/README.md", "schema {} is not referenced by a vector".format(name))


def _is_non_utf8(data_hex):
    if not isinstance(data_hex, str):
        return False
    try:
        data = bytes.fromhex(data_hex)
    except ValueError:
        return False
    try:
        data.decode("utf-8")
        return False
    except UnicodeDecodeError:
        return True


# ---------------------------------------------------------------------------
# WAL golden vectors.
# ---------------------------------------------------------------------------


def check_wal_vector(spec_dir, path, rep, state):
    rel = str(path.relative_to(spec_dir))
    rep.add(rel)
    try:
        doc = load_json(path)
        if not isinstance(doc, dict):
            raise SpecError("WAL vector is not an object")
        if set(doc) != {"header", "records", "file_hex"}:
            raise SpecError("WAL vector members must be exactly header/records/file_hex")
        header = doc["header"]
        if not isinstance(header, dict):
            raise SpecError("header must be an object")
        if set(header) != {
            "format",
            "reserved",
            "first_mseq",
            "boot_id_hex",
            "header_crc32c",
            "header_hex",
        }:
            raise SpecError(
                "header members must be exactly format/reserved/first_mseq/"
                "boot_id_hex/header_crc32c/header_hex"
            )
        fmt = _uint(header["format"], 16, rel + ".header.format")
        reserved = _uint(header["reserved"], 16, rel + ".header.reserved")
        first_mseq = _uint(header["first_mseq"], 64, rel + ".header.first_mseq", minimum=1)
        boot = _hex_bytes(header["boot_id_hex"], rel + ".header.boot_id_hex")
        if len(boot) != 16:
            raise SpecError("header.boot_id_hex must be exactly 16 bytes")
        header_crc, header_bytes = encode_wal_header(
            fmt, reserved, first_mseq, boot, rel + ".header"
        )
        if _uint(header["header_crc32c"], 32, rel + ".header.header_crc32c") != header_crc:
            raise SpecError("header crc32c does not match the computed value")
        header_hex = _hex_bytes(header["header_hex"], rel + ".header.header_hex")
        if len(header_hex) != WAL_HEADER_LEN:
            raise SpecError("header_hex must decode to exactly 40 bytes")
        if header_hex != header_bytes:
            raise SpecError("header_hex does not match the header fields")

        records = doc["records"]
        if not isinstance(records, list) or not records:
            raise SpecError("records must be a non-empty array")
        record_bytes = []
        mutation_mseqs = []
        appended = 0
        removes = 0
        epoch_durable = None
        epoch_index = None
        for index, record in enumerate(records):
            where = "{}.records[{}]".format(rel, index)
            if not isinstance(record, dict):
                raise SpecError(where + ": record must be an object")
            if set(record) != {"kind", "fields", "crc32c", "record_hex"}:
                raise SpecError(where + ": members must be exactly kind/fields/crc32c/record_hex")
            fields = record["fields"]
            if record["kind"] == "mutation":
                if not isinstance(fields, dict) or "mseq" not in fields:
                    raise SpecError(where + ": mutation fields need mseq")
                mseq = _uint(fields["mseq"], 64, where + ".mseq", minimum=1)
                body = encode_mutation_body(fields, where)
                crc, expected = encode_wal_record(mseq, body, where)
                mutation_mseqs.append(mseq)
                appended += 1 if int(fields["mflags"]) & 0x02 else 0
                removes += 1 if int(fields["op"]) == 3 else 0
            elif record["kind"] == "epoch_close":
                if epoch_index is not None:
                    raise SpecError(where + ": a segment holds at most one epoch-close record")
                epoch_index = index
                mseq, body = encode_epoch_close_body(fields, where)
                crc, expected = encode_wal_record(mseq, body, where)
                epoch_durable = mseq
            else:
                raise SpecError(where + ".kind must be mutation or epoch_close")
            if _uint(record["crc32c"], 32, where + ".crc32c") != crc:
                raise SpecError(where + ": crc32c does not match the computed value")
            stored = _hex_bytes(record["record_hex"], where + ".record_hex")
            if stored != expected:
                raise SpecError(where + ": record_hex does not match the record fields")
            if len(stored) < 8 or int.from_bytes(stored[0:4], "big") != len(stored) - 8:
                raise SpecError(where + ": record len field does not cover mseq + body")
            record_bytes.append(stored)

        if epoch_index is not None and epoch_index != len(records) - 1:
            raise SpecError("the epoch-close record must be the last record of its segment")
        if mutation_mseqs:
            if mutation_mseqs[0] != first_mseq:
                raise SpecError("header.first_mseq must equal the first mutation mseq")
            for previous, current in zip(mutation_mseqs, mutation_mseqs[1:]):
                if current != previous + 1:
                    raise SpecError("mutation mseq values must be consecutive")
            if epoch_durable is not None and epoch_durable != mutation_mseqs[-1]:
                raise SpecError(
                    "epoch-close durable_upto must equal the last mutation mseq of its segment"
                )
        elif epoch_durable is not None and first_mseq <= epoch_durable:
            raise SpecError(
                "a segment with only an epoch-close record needs first_mseq > durable_upto (D7)"
            )

        file_bytes = header_bytes + b"".join(record_bytes)
        if _hex_bytes(doc["file_hex"], rel + ".file_hex") != file_bytes:
            raise SpecError("file_hex does not equal header_hex followed by every record_hex")
        state["mutations"] += len(mutation_mseqs)
        state["epochs"] += 1 if epoch_index is not None else 0
        state["appended"] += appended
        state["removes"] += removes
        if epoch_durable is not None and not mutation_mseqs:
            state["epoch_only"].append((rel, first_mseq, epoch_durable))
    except SpecError as exc:
        rep.fail(rel, str(exc))


def check_wal_vectors(spec_dir, rep, full):
    """Validate every WAL vector and the cross-vector coverage rules.

    The checks run whenever ``golden/wal`` exists; ``--full`` additionally makes the directory
    mandatory.
    """

    wal_dir = spec_dir / "golden" / "wal"
    state = {
        "mutations": 0,
        "epochs": 0,
        "files": 0,
        "appended": 0,
        "removes": 0,
        "epoch_only": [],
        "names": set(),
    }
    if not wal_dir.is_dir():
        return state
    paths = sorted(wal_dir.glob("*.json"))
    for path in paths:
        state["files"] += 1
        state["names"].add(path.name)
        check_wal_vector(spec_dir, path, rep, state)

    if state["files"] == 0:
        if full:
            rep.fail("golden/wal", "no WAL vector")
        return state
    missing = [name for name in WAL_VECTOR_FILES if name not in state["names"]]
    if missing:
        rep.fail("golden/wal", "required WAL vectors are missing: {}".format(missing))
    if state["mutations"] < 3:
        rep.fail("golden/wal", "fewer than 3 mutation records across all WAL vectors")
    if state["appended"] < 1:
        rep.fail("golden/wal", "no appended write (mflags bit1) in any WAL vector")
    if state["removes"] < 1:
        rep.fail("golden/wal", "no remove (op 3) record in any WAL vector")
    if state["epochs"] < 1:
        rep.fail("golden/wal", "no epoch-close record in any WAL vector")
    if not any(first > durable for _, first, durable in state["epoch_only"]):
        rep.fail(
            "golden/wal",
            "no epoch-only segment with first_mseq > durable_upto (D7)",
        )
    return state


# ---------------------------------------------------------------------------
# WAL segment lifecycle vectors (wal.md §7.2, §9, §10): the manifest-based
# droppable rule and the recovery fast path.
# ---------------------------------------------------------------------------


def _wal_lifecycle_parse_segment(file_hex, where):
    """Decode one golden segment independently and verify every CRC."""

    raw = _hex_bytes(file_hex, where + ".file_hex")
    if not raw:
        return {
            "zero_length": True,
            "first_mseq": 0,
            "last_mseq": 0,
            "has_epoch_close": False,
            "mutations": [],
            "close": None,
        }
    if len(raw) < WAL_HEADER_LEN:
        raise SpecError(where + ": a non-empty segment is shorter than its 40-byte header")
    if raw[:8] != WAL_MAGIC:
        raise SpecError(where + ": segment magic is not XLWAL1")
    fmt = struct.unpack(">H", raw[8:10])[0]
    reserved = struct.unpack(">H", raw[10:12])[0]
    first_mseq = struct.unpack(">Q", raw[12:20])[0]
    boot = raw[20:36]
    header_crc = struct.unpack(">I", raw[36:40])[0]
    if fmt != WAL_FORMAT:
        raise SpecError(where + ": segment format is not 1")
    if reserved != 0:
        raise SpecError(where + ": segment reserved is not 0")
    if first_mseq < 1:
        raise SpecError(where + ": segment first_mseq is below 1")
    if len(boot) != 16:
        raise SpecError(where + ": segment boot_id is not 16 bytes")
    if crc32c(raw[:36]) != header_crc:
        raise SpecError(where + ": segment header CRC32C does not match")

    mutations = []
    close = None
    offset = WAL_HEADER_LEN
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise SpecError(where + ": truncated record header")
        length = struct.unpack(">I", raw[offset:offset + 4])[0]
        if length < 8 or offset + 8 + length > len(raw):
            raise SpecError(where + ": record len does not fit the file")
        payload = raw[offset + 8:offset + 8 + length]
        stored_crc = struct.unpack(">I", raw[offset + 4:offset + 8])[0]
        if crc32c(payload) != stored_crc:
            raise SpecError(where + ": record CRC32C does not match")
        mseq = struct.unpack(">Q", payload[:8])[0]
        body = payload[8:]
        if body and body[0] == WAL_EPOCH_CLOSE_OP:
            if close is not None:
                raise SpecError(where + ": more than one epoch-close record")
            if len(body) != 17:
                raise SpecError(where + ": epoch-close body is not 17 bytes")
            wall_ms, durable = struct.unpack(">QQ", body[1:])
            if mseq != durable:
                raise SpecError(where + ": epoch-close mseq must equal durable_upto")
            close = {"mseq": mseq, "wall_ms": wall_ms, "durable_upto": durable}
        else:
            if close is not None:
                raise SpecError(where + ": a record follows the epoch-close record")
            mutations.append(mseq)
        offset += 8 + length
    if mutations:
        if mutations[0] != first_mseq:
            raise SpecError(where + ": first mutation does not equal header.first_mseq")
        for previous, current in zip(mutations, mutations[1:]):
            if current != previous + 1:
                raise SpecError(where + ": mutation mseq values are not consecutive")
        if close is not None and close["durable_upto"] != mutations[-1]:
            raise SpecError(where + ": close durable_upto is not the last mutation")
    elif close is not None and first_mseq <= close["durable_upto"]:
        raise SpecError(where + ": idle-close segment needs first_mseq > durable_upto")
    return {
        "zero_length": False,
        "first_mseq": first_mseq,
        "last_mseq": mutations[-1] if mutations else 0,
        "has_epoch_close": close is not None,
        "mutations": mutations,
        "close": close,
    }


def _wal_lifecycle_manifest(doc, rel, schemas):
    manifest = doc.get("manifest")
    if not isinstance(manifest, dict):
        raise SpecError(rel + ".manifest must be an object")
    schema = schemas.get(MANIFEST_SCHEMA_NAME)
    if schema is None:
        raise SpecError("manifest schema is required by the lifecycle vectors")
    validate_json(manifest, schema, rel + ".manifest")
    watermark = _uint(
        manifest["materialized_upto_mseq"], 64, rel + ".manifest.materialized_upto_mseq"
    )
    last_mseq = _uint(manifest["last_mseq"], 64, rel + ".manifest.last_mseq")
    durable = _uint(
        manifest["last_durable_epoch"], 64, rel + ".manifest.last_durable_epoch"
    )
    if watermark > last_mseq:
        raise SpecError(rel + ".manifest: materialized_upto_mseq is above last_mseq")
    entries = manifest["segments"]
    if not isinstance(entries, list):
        raise SpecError(rel + ".manifest.segments must be an array")
    listed = {}
    order = []
    for index, entry in enumerate(entries):
        where = "{}.manifest.segments[{}]".format(rel, index)
        if not isinstance(entry, dict):
            raise SpecError(where + " must be an object")
        match = WAL_LIFECYCLE_SEGMENT_RE.fullmatch(entry.get("file", ""))
        if match is None:
            raise SpecError(where + ".file is not wal/<epoch>.<segment>.xlwal")
        epoch = int(match.group(1))
        number = int(match.group(2))
        if _uint(entry["epoch"], 32, where + ".epoch") != epoch:
            raise SpecError(where + ": epoch disagrees with the file name")
        first = _uint(entry["first_mseq"], 64, where + ".first_mseq", minimum=1)
        last = _uint(entry["last_mseq"], 64, where + ".last_mseq")
        if last != 0 and last < first:
            raise SpecError(where + ": first_mseq is above last_mseq")
        key = (epoch, number)
        if key in listed:
            raise SpecError(where + ": duplicate segment")
        listed[entry["file"]] = entry
        order.append(key)
    if order != sorted(order):
        raise SpecError(rel + ".manifest.segments must be in <epoch,segment> order")
    if listed:
        highest = max(entry["last_mseq"] for entry in listed.values())
        if last_mseq < highest:
            raise SpecError(rel + ".manifest: last_mseq is below a listed segment range")
    return manifest, watermark, last_mseq, durable, listed


def check_wal_lifecycle_vector(spec_dir, path, rep, schemas, state):
    rel = str(path.relative_to(spec_dir))
    rep.add(rel)
    try:
        doc = load_json(path)
        if not isinstance(doc, dict):
            raise SpecError("lifecycle vector is not an object")
        if set(doc) != {"id", "title", "manifest", "segments", "expected"}:
            raise SpecError("members must be exactly id/title/manifest/segments/expected")
        _string(doc["id"], rel + ".id")
        _string(doc["title"], rel + ".title")
        manifest, watermark, last_mseq, durable, listed = _wal_lifecycle_manifest(
            doc, rel, schemas
        )
        raw_segments = doc["segments"]
        if not isinstance(raw_segments, list) or not raw_segments:
            raise SpecError(rel + ".segments must be a non-empty array")
        facts = []
        seen = set()
        for index, raw in enumerate(raw_segments):
            where = "{}.segments[{}]".format(rel, index)
            if not isinstance(raw, dict):
                raise SpecError(where + " must be an object")
            if set(raw) != {"file", "file_hex", "first_mseq", "last_mseq", "has_epoch_close"}:
                raise SpecError(
                    where + " members must be exactly file/file_hex/first_mseq/last_mseq/has_epoch_close"
                )
            match = WAL_LIFECYCLE_SEGMENT_RE.fullmatch(raw["file"])
            if match is None:
                raise SpecError(where + ".file is not wal/<epoch>.<segment>.xlwal")
            if raw["file"] in seen:
                raise SpecError(where + ": duplicate segment file")
            seen.add(raw["file"])
            decoded = _wal_lifecycle_parse_segment(raw["file_hex"], where)
            if _uint(raw["first_mseq"], 64, where + ".first_mseq") != decoded["first_mseq"]:
                raise SpecError(where + ": first_mseq disagrees with the file")
            if _uint(raw["last_mseq"], 64, where + ".last_mseq") != decoded["last_mseq"]:
                raise SpecError(where + ": last_mseq disagrees with the file")
            has_close = raw["has_epoch_close"]
            if not isinstance(has_close, bool) or has_close != decoded["has_epoch_close"]:
                raise SpecError(where + ": has_epoch_close disagrees with the file")
            decoded["file"] = raw["file"]
            decoded["epoch"] = int(match.group(1))
            decoded["number"] = int(match.group(2))
            facts.append(decoded)
        missing = sorted(set(listed) - seen)
        if missing:
            raise SpecError(rel + ": a listed segment is absent from the vector: " + repr(missing))
        for fact in facts:
            entry = listed.get(fact["file"])
            if entry is None:
                continue
            if fact["first_mseq"] != entry["first_mseq"]:
                raise SpecError(rel + ": manifest first_mseq disagrees with " + fact["file"])
            if fact["last_mseq"] != entry["last_mseq"]:
                raise SpecError(rel + ": manifest last_mseq disagrees with " + fact["file"])

        closed = [fact for fact in facts if fact["has_epoch_close"]]
        newest = max(closed, key=lambda fact: (fact["epoch"], fact["number"])) if closed else None
        newest_file = newest["file"] if newest is not None else None
        all_mutations = sorted(
            mseq
            for fact in facts
            if not fact["zero_length"]
            for mseq in fact["mutations"]
        )
        tail_mutations = [mseq for mseq in all_mutations if mseq > watermark]
        if tail_mutations:
            if tail_mutations[0] != watermark + 1:
                raise SpecError(rel + ": retained WAL tail does not start at the watermark + 1")
            for previous, current in zip(tail_mutations, tail_mutations[1:]):
                if current != previous + 1:
                    raise SpecError(rel + ": retained WAL tail has a hole")
        effective_tail = max([last_mseq, watermark] + all_mutations)
        if effective_tail > watermark and (
            not tail_mutations or tail_mutations[-1] != effective_tail
        ):
            raise SpecError(rel + ": retained mutations do not cover the effective tail")

        has_unclosed = any(
            not fact["zero_length"]
            and (
                fact["file"] not in listed
                or fact["epoch"] > durable
            )
            for fact in facts
        )
        dropped = set()
        for fact in facts:
            if fact["zero_length"]:
                if fact["file"] not in listed:
                    dropped.add(fact["file"])
                continue
            if fact["file"] not in listed:
                continue
            if fact["epoch"] > durable:
                continue
            if any(mseq > watermark for mseq in fact["mutations"]):
                continue
            if newest_file is not None and fact["file"] == newest_file:
                continue
            dropped.add(fact["file"])
        retained = [
            fact["file"]
            for fact in facts
            if not fact["zero_length"] and fact["file"] not in dropped
        ]
        relisted = [name for name in retained if name not in listed]
        adopted = [
            name
            for name in relisted
            if any(
                fact["file"] == name and any(mseq > watermark for mseq in fact["mutations"])
                for fact in facts
            )
        ]
        fast_path = not has_unclosed and not tail_mutations
        computed = {
            "fast_path": fast_path,
            "verification_pass": not fast_path,
            "has_unclosed_history": has_unclosed,
            "replay_records": len(tail_mutations),
            "materialized_upto_mseq": max([watermark] + all_mutations),
            "newest_close_segment": newest_file,
            "dropped_segments": sorted(dropped),
            "retained_segments": sorted(retained),
            "relisted_segments": sorted(relisted),
            "adopted_tail_segments": sorted(adopted),
        }

        expected = doc["expected"]
        if not isinstance(expected, dict):
            raise SpecError(rel + ".expected must be an object")
        if set(expected) != WAL_LIFECYCLE_EXPECTED_KEYS:
            raise SpecError(
                rel + ".expected members must be exactly " + repr(sorted(WAL_LIFECYCLE_EXPECTED_KEYS))
            )
        for key, value in expected.items():
            if computed[key] != value:
                raise SpecError(
                    "{}.expected.{}: got {!r}, expected {!r}".format(
                        rel, key, computed[key], value
                    )
                )

        state["files"] += 1
        state["fast_path"] += 1 if fast_path else 0
        state["tail_replay"] += 1 if tail_mutations else 0
        state["unclosed_dropped"] += 1 if (
            fast_path
            and any(
                not fact["zero_length"]
                and not fact["has_epoch_close"]
                and fact["file"] in dropped
                and fact["file"] in listed
                for fact in facts
            )
        ) else 0
        state["relisted"] += 1 if relisted else 0
        state["adopted"] += 1 if adopted else 0
        state["newest_close_kept"] += 1 if (
            newest_file is not None and newest_file not in dropped
        ) else 0
    except SpecError as exc:
        rep.fail(rel, str(exc))


def check_wal_lifecycle_vectors(spec_dir, rep, schemas, full):
    """Validate the §9/§10 lifecycle vectors and their coverage."""

    directory = spec_dir / WAL_LIFECYCLE_DIR
    state = {
        "files": 0,
        "fast_path": 0,
        "tail_replay": 0,
        "unclosed_dropped": 0,
        "relisted": 0,
        "adopted": 0,
        "newest_close_kept": 0,
    }
    if not directory.is_dir():
        if full:
            rep.add(WAL_LIFECYCLE_DIR)
            rep.fail(WAL_LIFECYCLE_DIR, "required by --full but missing")
        return state
    paths = sorted(directory.glob("*.json"))
    names = {path.name for path in paths}
    missing = [name for name in WAL_LIFECYCLE_VECTOR_FILES if name not in names]
    for path in paths:
        check_wal_lifecycle_vector(spec_dir, path, rep, schemas, state)
    if state["files"] == 0:
        if full:
            rep.fail(WAL_LIFECYCLE_DIR, "no lifecycle vector")
        return state
    if missing:
        rep.fail(
            WAL_LIFECYCLE_DIR,
            "required lifecycle vectors are missing: {}".format(missing),
        )
    if state["fast_path"] < 1:
        rep.fail(WAL_LIFECYCLE_DIR, "no vector proves the unclosed-epoch fast path")
    if state["tail_replay"] < 1:
        rep.fail(WAL_LIFECYCLE_DIR, "no vector retains and replays a crash tail")
    if state["unclosed_dropped"] < 1:
        rep.fail(
            WAL_LIFECYCLE_DIR,
            "no vector drops a listed unclosed epoch at or below last_durable_epoch",
        )
    if state["relisted"] < 1:
        rep.fail(WAL_LIFECYCLE_DIR, "no vector re-lists an unlisted stale segment")
    if state["adopted"] < 1:
        rep.fail(WAL_LIFECYCLE_DIR, "no vector adopts an unlisted tail segment")
    if state["newest_close_kept"] < 1:
        rep.fail(WAL_LIFECYCLE_DIR, "no vector keeps the newest epoch-close segment")
    return state


# ---------------------------------------------------------------------------
# WAL replay semantics vectors (§5.1, §6.2, §7.2, §10).
# ---------------------------------------------------------------------------


def _wal_replay_content(value, where):
    """Decode one fixture content object into bytes."""

    if not isinstance(value, dict):
        raise SpecError(where + ": content must be an object")
    if set(value) == {"content_utf8"}:
        return _string(value["content_utf8"], where + ".content_utf8").encode("utf-8")
    if set(value) == {"content_hex"}:
        return _hex_bytes(value["content_hex"], where + ".content_hex")
    raise SpecError(where + ": content must be exactly content_utf8 or content_hex")


def _wal_replay_tree(value, where):
    """Decode a path -> contents object into bytes and reject file/directory conflicts."""

    if not isinstance(value, dict):
        raise SpecError(where + ": expected an object")
    tree = {}
    for path, content in value.items():
        checked = check_path(path, where + ".path")
        if checked in tree:
            raise SpecError(where + ": duplicate path " + checked)
        tree[checked] = _wal_replay_content(content, where + "." + checked)
    for left in tree:
        for right in tree:
            if left != right and _is_ancestor_path(left, right):
                raise SpecError(
                    where + ": " + left + " is a file and an ancestor of " + right
                )
    return tree


def _is_ancestor_path(ancestor, path):
    return path.startswith(ancestor + "/")


def _record_covers(record, path):
    """True when the record establishes the final state of *path*."""

    if record["op"] == 1 and not record["appended"] and record["path"] == path:
        return True
    return record["op"] == 3 and (
        record["path"] == path or _is_ancestor_path(record["path"], path)
    )


def _find_cover(records, index):
    """Index of the earliest later record that covers *records[index]*, or None."""

    path = records[index]["path"]
    for later in range(index + 1, len(records)):
        if _record_covers(records[later], path):
            return later
    return None


def _cover_label_matches(label, records, index, cover_index):
    cover = records[cover_index]
    path = records[index]["path"]
    if label in ("complete-write", "truncate", "repair-write"):
        return cover["op"] == 1 and not cover["appended"] and cover["path"] == path
    if label == "remove":
        return cover["op"] == 3 and cover["path"] == path
    if label == "ancestor-remove":
        return cover["op"] == 3 and _is_ancestor_path(cover["path"], path)
    return False


def _wal_replay_watermark(statuses, candidates):
    """Highest legal watermark after a replay prefix.

    A watermark is legal only when every record at or below it is applied,
    skipped, already materialized, or settled by a cover whose own mseq is at
    or below the watermark. The last condition is the conservative settlement
    rule: the cover must be inside the claimed prefix, not merely applied to
    the copy. Every manifest write obeys this rule (wal.md section 6.2 and 7.1).
    """

    def legal(watermark):
        for status in statuses:
            if status["mseq"] > watermark:
                continue
            verdict = status["verdict"]
            if verdict in ("applied", "skipped-idempotent", "already-materialized"):
                continue
            if (
                verdict == "settled-superseded"
                and status["superseded_by_mseq"] <= watermark
            ):
                continue
            return False
        return True

    legal_candidates = [candidate for candidate in candidates if legal(candidate)]
    return max(legal_candidates) if legal_candidates else 0


def _wal_replay(records, copy, watermark):
    """Reference replay used only to validate the fixture's expected result.

    It is deliberately independent of the Swift/Kotlin state machines. The
    superseded rule is applied before the D9 base check, so a covered append is
    settled even when its base happens to match; the later cover establishes the
    final state. A held path is not materialized further until a repair, while
    records of other paths may still be applied (wal.md §5.1).

    It also returns the highest legal watermark after each record. A settled
    record cannot be passed before its cover's mseq is inside the same prefix,
    even when the cover was applied and an intervening record of another path
    is still unresolved. That is the per-step oracle for fixture
    ``watermark_steps`` and for the manifest invariant.
    """

    tree = dict(copy)
    statuses = []
    steps = []
    held = set()
    failed = False
    for index, record in enumerate(records):
        mseq = record["mseq"]
        if mseq <= watermark:
            statuses.append({"mseq": mseq, "verdict": "already-materialized"})
        else:
            path = record["path"]
            if record["op"] == 1 and record["appended"]:
                cover_index = _find_cover(records, index)
                if cover_index is not None:
                    statuses.append(
                        {
                            "mseq": mseq,
                            "verdict": "settled-superseded",
                            "superseded_by_mseq": records[cover_index]["mseq"],
                        }
                    )
                elif path in held:
                    statuses.append({"mseq": mseq, "verdict": "mismatch-held"})
                    failed = True
                else:
                    current = tree.get(path)
                    data = record["data"]
                    append_from = record["append_from"]
                    if current is None:
                        statuses.append({"mseq": mseq, "verdict": "mismatch-held"})
                        held.add(path)
                        failed = True
                    elif len(current) == append_from:
                        tree[path] = current + data
                        statuses.append({"mseq": mseq, "verdict": "applied"})
                    elif (
                        len(current) >= append_from + len(data)
                        and current[append_from : append_from + len(data)] == data
                    ):
                        statuses.append(
                            {"mseq": mseq, "verdict": "skipped-idempotent"}
                        )
                    else:
                        statuses.append({"mseq": mseq, "verdict": "mismatch-held"})
                        held.add(path)
                        failed = True
            elif record["op"] == 1:
                tree[path] = record["data"]
                statuses.append({"mseq": mseq, "verdict": "applied"})
            else:
                for present in list(tree):
                    if present == path or _is_ancestor_path(path, present):
                        del tree[present]
                statuses.append({"mseq": mseq, "verdict": "applied"})
        candidates = [watermark] + [
            entry["mseq"] for entry in records[: index + 1]
        ]
        steps.append(
            {
                "mseq": mseq,
                "materialized_upto_mseq": _wal_replay_watermark(statuses, candidates),
            }
        )

    final_candidates = [watermark] + [record["mseq"] for record in records]
    final_watermark = _wal_replay_watermark(statuses, final_candidates)
    return statuses, steps, tree, final_watermark, failed


def _parse_wal_replay_records(doc_records, where):
    if not isinstance(doc_records, list) or not doc_records:
        raise SpecError(where + ": records must be a non-empty array")
    records = []
    for index, raw in enumerate(doc_records):
        at = "{}[{}]".format(where, index)
        if not isinstance(raw, dict):
            raise SpecError(at + ": record must be an object")
        required = {"mseq", "op", "path", "appended"}
        allowed = required | {"append_from", "data"}
        missing = required - set(raw)
        extra = set(raw) - allowed
        if missing:
            raise SpecError(at + ": missing members " + str(sorted(missing)))
        if extra:
            raise SpecError(at + ": unexpected members " + str(sorted(extra)))
        mseq = _uint(raw["mseq"], 64, at + ".mseq", minimum=1)
        op = _uint(raw["op"], 8, at + ".op")
        if op not in (1, 3):
            raise SpecError(at + ".op: replay vectors admit only write (1) and remove (3)")
        path = check_path(raw["path"], at + ".path")
        appended = _boolean(raw["appended"], at + ".appended")
        append_from = _uint(raw.get("append_from", 0), 64, at + ".append_from")
        data = (
            _wal_replay_content(raw["data"], at + ".data") if "data" in raw else b""
        )
        if op == 3:
            if appended:
                raise SpecError(at + ": a remove cannot be appended")
            if append_from != 0 or data:
                raise SpecError(at + ": a remove carries no append_from or data")
        elif appended:
            if "append_from" not in raw:
                raise SpecError(at + ": an appended write needs append_from")
            if "data" not in raw:
                raise SpecError(at + ": an appended write needs data")
        else:
            if append_from != 0:
                raise SpecError(at + ": a complete write has append_from 0")
            if "data" not in raw:
                raise SpecError(at + ": a complete write needs data")
        records.append(
            {
                "mseq": mseq,
                "op": op,
                "path": path,
                "appended": appended,
                "append_from": append_from,
                "data": data,
            }
        )
    for previous, current in zip(records, records[1:]):
        if current["mseq"] != previous["mseq"] + 1:
            raise SpecError(where + ": retained mutation mseq values must be contiguous")
    return records


def _parse_wal_replay_verdicts(value, records, where):
    if not isinstance(value, list) or len(value) != len(records):
        raise SpecError(where + ": must carry one verdict per retained record")
    verdicts = []
    for index, (raw, record) in enumerate(zip(value, records)):
        at = "{}[{}]".format(where, index)
        if not isinstance(raw, dict):
            raise SpecError(at + ": verdict must be an object")
        required = {"mseq", "verdict"}
        allowed = required | {"cover", "superseded_by_mseq"}
        missing = required - set(raw)
        extra = set(raw) - allowed
        if missing:
            raise SpecError(at + ": missing members " + str(sorted(missing)))
        if extra:
            raise SpecError(at + ": unexpected members " + str(sorted(extra)))
        mseq = _uint(raw["mseq"], 64, at + ".mseq", minimum=1)
        if mseq != record["mseq"]:
            raise SpecError(
                at + ".mseq: expected {} for retained record {}".format(
                    record["mseq"], index
                )
            )
        verdict = _string(raw["verdict"], at + ".verdict")
        if verdict not in WAL_REPLAY_VERDICTS:
            raise SpecError(at + ".verdict: not a WAL replay verdict")
        parsed = {"mseq": mseq, "verdict": verdict}
        if verdict == "settled-superseded":
            cover = _string(raw.get("cover", ""), at + ".cover")
            if cover not in WAL_REPLAY_COVERS:
                raise SpecError(at + ".cover: not a replay cover kind")
            parsed["cover"] = cover
            parsed["superseded_by_mseq"] = _uint(
                raw.get("superseded_by_mseq"), 64, at + ".superseded_by_mseq", minimum=1
            )
        elif "cover" in raw or "superseded_by_mseq" in raw:
            raise SpecError(at + ": cover only belongs to a settled-superseded verdict")
        verdicts.append(parsed)
    return verdicts


def _parse_wal_replay_watermark_steps(value, records, initial, where):
    if not isinstance(value, list) or not value:
        raise SpecError(where + ": watermark_steps must be a non-empty array")
    if len(value) > len(records):
        raise SpecError(where + ": more watermark_steps than retained records")
    steps = []
    for index, raw in enumerate(value):
        at = "{}[{}]".format(where, index)
        _mapping(raw, at, {"mseq", "materialized_upto_mseq"})
        mseq = _uint(raw["mseq"], 64, at + ".mseq", minimum=1)
        if mseq != records[index]["mseq"]:
            raise SpecError(
                at
                + ".mseq: watermark_steps must follow the retained records in order;"
                + " expected {}".format(records[index]["mseq"])
            )
        watermark = _uint(
            raw["materialized_upto_mseq"],
            64,
            at + ".materialized_upto_mseq",
            minimum=0,
        )
        if watermark < initial:
            raise SpecError(
                at + ".materialized_upto_mseq: below the input manifest watermark"
            )
        if watermark > max(initial, mseq):
            raise SpecError(
                at
                + ".materialized_upto_mseq: cannot exceed the input watermark or the"
                + " record's mseq"
            )
        if steps and watermark < steps[-1]["materialized_upto_mseq"]:
            raise SpecError(at + ".materialized_upto_mseq: must not decrease")
        steps.append({"mseq": mseq, "materialized_upto_mseq": watermark})
    return steps


def _check_wal_replay_watermark_steps(declared, computed, verdicts, where):
    """Check the manifest invariant at each declared checkpoint.

    A settled record at mseq m may not be passed while its covering record's
    mseq is still above the recorded watermark; that is the conservative
    settlement rule of wal.md section 6.2. The exact reference value is then
    compared so a vector cannot declare a lower or higher step by accident.
    """

    if len(declared) > len(computed):
        raise SpecError(where + ": watermark_steps exceeds the replayed records")
    for index, (declared_step, computed_step) in enumerate(zip(declared, computed)):
        watermark = declared_step["materialized_upto_mseq"]
        for verdict in verdicts:
            if (
                verdict["verdict"] == "settled-superseded"
                and verdict["mseq"] <= watermark
                and verdict["superseded_by_mseq"] > watermark
            ):
                raise SpecError(
                    "{}[{}].materialized_upto_mseq: {} passes settled record {}"
                    " before its covering record {} is applied".format(
                        where,
                        index,
                        watermark,
                        verdict["mseq"],
                        verdict["superseded_by_mseq"],
                    )
                )
        if watermark != computed_step["materialized_upto_mseq"]:
            raise SpecError(
                "{}[{}].materialized_upto_mseq: declared {} but the replay"
                " computes {}".format(
                    where,
                    index,
                    watermark,
                    computed_step["materialized_upto_mseq"],
                )
            )


def _check_wal_replay_verdicts(declared, computed, records, where):
    if len(declared) != len(computed):
        raise SpecError(where + ": verdict count differs from the retained records")
    for index, (expected, actual) in enumerate(zip(declared, computed)):
        if expected["mseq"] != actual["mseq"] or expected["verdict"] != actual["verdict"]:
            raise SpecError(
                "{}[{}]: declared {} but replay computes {}".format(
                    where, index, expected, actual
                )
            )
        if actual["verdict"] != "settled-superseded":
            continue
        if expected["superseded_by_mseq"] != actual["superseded_by_mseq"]:
            raise SpecError(
                "{}[{}].superseded_by_mseq: declared {} but the next cover is {}".format(
                    where,
                    index,
                    expected["superseded_by_mseq"],
                    actual["superseded_by_mseq"],
                )
            )
        cover_index = next(
            (
                position
                for position, record in enumerate(records)
                if record["mseq"] == actual["superseded_by_mseq"]
            ),
            None,
        )
        if cover_index is None or not _cover_label_matches(
            expected["cover"], records, index, cover_index
        ):
            raise SpecError(
                "{}[{}].cover: does not match the covering record".format(where, index)
            )


def _check_wal_replay_result(declared, computed, records, where):
    _check_wal_replay_verdicts(
        declared["records"], computed["records"], records, where + ".records"
    )
    if declared["materialized_upto_mseq"] != computed["materialized_upto_mseq"]:
        raise SpecError(
            where
            + ".materialized_upto_mseq: declared {} but replay computes {}".format(
                declared["materialized_upto_mseq"],
                computed["materialized_upto_mseq"],
            )
        )
    watermark = declared["materialized_upto_mseq"]
    for verdict in declared["records"]:
        if (
            verdict["verdict"] == "settled-superseded"
            and verdict["mseq"] <= watermark
            and verdict["superseded_by_mseq"] > watermark
        ):
            raise SpecError(
                where
                + ".materialized_upto_mseq: {} passes settled record {} before its"
                " covering record {} is applied".format(
                    watermark, verdict["mseq"], verdict["superseded_by_mseq"]
                )
            )
    if declared["failed"] != computed["failed"]:
        raise SpecError(
            where
            + ".failed: declared {} but replay computes {}".format(
                declared["failed"], computed["failed"]
            )
        )


def check_wal_replay_vector(spec_dir, path, rep, schemas, state):
    rel = str(path.relative_to(spec_dir))
    rep.add(rel)
    try:
        doc = load_json(path)
        if not isinstance(doc, dict):
            raise SpecError("WAL replay vector is not an object")
        schema = schemas.get(WAL_REPLAY_SCHEMA_NAME)
        if schema is not None:
            validate_json(doc, schema, rel)
        _mapping(
            doc,
            rel,
            {
                "id",
                "title",
                "materialized_upto_mseq",
                "copy",
                "records",
                "expected",
            },
        )
        fixture_id = _string(doc["id"], rel + ".id")
        if fixture_id != path.stem:
            raise SpecError(rel + ".id: must equal the file name")
        _string(doc["title"], rel + ".title")
        watermark = _uint(
            doc["materialized_upto_mseq"], 64, rel + ".materialized_upto_mseq"
        )
        copy = _wal_replay_tree(doc["copy"], rel + ".copy")
        records = _parse_wal_replay_records(doc["records"], rel + ".records")
        if watermark > records[0]["mseq"] and records[0]["mseq"] != 1:
            raise SpecError(
                rel
                + ": a retained sequence starting above 1 needs a watermark below its first mseq"
            )
        if records[0]["mseq"] > 1 and watermark < records[0]["mseq"] - 1:
            raise SpecError(
                rel
                + ": a retained sequence starting above 1 leaves an mseq hole above the watermark"
            )

        expected = doc["expected"]
        if not isinstance(expected, dict):
            raise SpecError(rel + ".expected: expected an object")
        required = {"records", "materialized_upto_mseq", "tree", "failed"}
        allowed = required | {"rebuilt_from_wal", "copy_replay", "watermark_steps"}
        missing = required - set(expected)
        extra = set(expected) - allowed
        if missing:
            raise SpecError(rel + ".expected: missing members " + str(sorted(missing)))
        if extra:
            raise SpecError(rel + ".expected: unexpected members " + str(sorted(extra)))
        expected_verdicts = _parse_wal_replay_verdicts(
            expected["records"], records, rel + ".expected.records"
        )
        expected_watermark = _uint(
            expected["materialized_upto_mseq"],
            64,
            rel + ".expected.materialized_upto_mseq",
        )
        expected_tree = _wal_replay_tree(expected["tree"], rel + ".expected.tree")
        expected_failed = _boolean(expected["failed"], rel + ".expected.failed")
        rebuilt = _boolean(
            expected.get("rebuilt_from_wal", False), rel + ".expected.rebuilt_from_wal"
        )
        expected_steps = (
            _parse_wal_replay_watermark_steps(
                expected["watermark_steps"],
                records,
                0 if rebuilt else watermark,
                rel + ".expected.watermark_steps",
            )
            if "watermark_steps" in expected
            else []
        )

        copy_statuses, copy_steps, copy_tree, copy_watermark, copy_failed = _wal_replay(
            records, copy, watermark
        )
        copy_result = {
            "records": copy_statuses,
            "materialized_upto_mseq": copy_watermark,
            "failed": copy_failed,
        }
        if "copy_replay" in expected:
            raw_copy = expected["copy_replay"]
            if not isinstance(raw_copy, dict):
                raise SpecError(rel + ".expected.copy_replay: expected an object")
            _mapping(
                raw_copy,
                rel + ".expected.copy_replay",
                {"records", "materialized_upto_mseq", "failed"},
            )
            declared_copy = {
                "records": _parse_wal_replay_verdicts(
                    raw_copy["records"], records, rel + ".expected.copy_replay.records"
                ),
                "materialized_upto_mseq": _uint(
                    raw_copy["materialized_upto_mseq"],
                    64,
                    rel + ".expected.copy_replay.materialized_upto_mseq",
                ),
                "failed": _boolean(
                    raw_copy["failed"], rel + ".expected.copy_replay.failed"
                ),
            }
            _check_wal_replay_result(
                declared_copy, copy_result, records, rel + ".expected.copy_replay"
            )
        elif rebuilt:
            raise SpecError(
                rel + ".expected.copy_replay: required when rebuilt_from_wal is true"
            )
        else:
            declared_copy = None

        if rebuilt:
            if records[0]["mseq"] != 1:
                raise SpecError(
                    rel + ".expected.rebuilt_from_wal: the retained WAL must start at mseq 1"
                )
            if not copy_failed:
                raise SpecError(
                    rel
                    + ".expected.rebuilt_from_wal: the copy replay must leave a resync to rebuild"
                )
            final_statuses, final_steps, final_tree, final_watermark, final_failed = (
                _wal_replay(records, {}, 0)
            )
        else:
            if "copy_replay" in expected:
                raise SpecError(
                    rel
                    + ".expected.copy_replay: only valid when rebuilt_from_wal is true"
                )
            final_statuses = copy_statuses
            final_steps = copy_steps
            final_tree = copy_tree
            final_watermark = copy_watermark
            final_failed = copy_failed

        _check_wal_replay_result(
            {
                "records": expected_verdicts,
                "materialized_upto_mseq": expected_watermark,
                "failed": expected_failed,
            },
            {
                "records": final_statuses,
                "materialized_upto_mseq": final_watermark,
                "failed": final_failed,
            },
            records,
            rel + ".expected",
        )
        if expected_steps:
            _check_wal_replay_watermark_steps(
                expected_steps,
                final_steps,
                expected_verdicts,
                rel + ".expected.watermark_steps",
            )
            state["watermark_steps"] += 1
            for step in expected_steps:
                for verdict in expected_verdicts:
                    if (
                        verdict["verdict"] == "settled-superseded"
                        and verdict["mseq"] == step["mseq"]
                        and verdict["superseded_by_mseq"] > step["mseq"]
                        and step["materialized_upto_mseq"] < verdict["mseq"]
                    ):
                        state["settled_waits"] += 1
        if expected_tree != final_tree:
            raise SpecError(
                rel
                + ".expected.tree: declared does not equal the replayed materialized tree"
            )
        if rebuilt and final_failed:
            raise SpecError(
                rel + ".expected.rebuilt_from_wal: a successful rebuild cannot stay Failed"
            )

        state["settled"] += sum(
            1 for verdict in final_statuses if verdict["verdict"] == "settled-superseded"
        )
        state["skipped"] += sum(
            1 for verdict in final_statuses if verdict["verdict"] == "skipped-idempotent"
        )
        state["held"] += sum(
            1 for verdict in final_statuses if verdict["verdict"] == "mismatch-held"
        )
        state["applied"] += sum(
            1 for verdict in final_statuses if verdict["verdict"] == "applied"
        )
        state["already"] += sum(
            1 for verdict in final_statuses if verdict["verdict"] == "already-materialized"
        )
        if declared_copy is not None:
            state["already"] += sum(
                1
                for verdict in declared_copy["records"]
                if verdict["verdict"] == "already-materialized"
            )
        state["rebuilt"] += 1 if rebuilt else 0
        state["failed"] += 1 if final_failed else 0
        state["passed"] += 1 if not final_failed else 0
        for verdict in expected_verdicts + (
            declared_copy["records"] if declared_copy is not None else []
        ):
            if verdict.get("superseded_by_mseq") is not None:
                state["covers"].add(verdict["cover"])
    except SpecError as exc:
        rep.fail(rel, str(exc))


def check_wal_replay_vectors(spec_dir, rep, schemas, full):
    """Validate the WAL replay-semantics vectors and their cross-vector coverage."""

    replay_dir = spec_dir / "golden" / "wal" / "replay"
    state = {
        "files": 0,
        "settled": 0,
        "skipped": 0,
        "held": 0,
        "applied": 0,
        "already": 0,
        "rebuilt": 0,
        "failed": 0,
        "passed": 0,
        "watermark_steps": 0,
        "settled_waits": 0,
        "covers": set(),
        "names": set(),
    }
    if not replay_dir.is_dir():
        if full:
            rep.fail("golden/wal/replay", "no WAL replay vector")
        return state
    if WAL_REPLAY_SCHEMA_NAME not in schemas:
        rep.add("schema/" + WAL_REPLAY_SCHEMA_NAME)
        rep.fail(
            "schema/" + WAL_REPLAY_SCHEMA_NAME,
            "WAL replay schema is required but missing",
        )
    paths = sorted(replay_dir.glob("*.json"))
    state["files"] = len(paths)
    state["names"] = {path.name for path in paths}
    for path in paths:
        check_wal_replay_vector(spec_dir, path, rep, schemas, state)
    if state["files"] == 0:
        if full:
            rep.fail("golden/wal/replay", "no WAL replay vector")
        return state
    missing = [name for name in WAL_REPLAY_VECTOR_FILES if name not in state["names"]]
    if missing:
        rep.fail(
            "golden/wal/replay",
            "required WAL replay vectors are missing: {}".format(missing),
        )
    if state["settled"] < 1:
        rep.fail("golden/wal/replay", "no settled-superseded verdict")
    if state["skipped"] < 1:
        rep.fail("golden/wal/replay", "no skipped-idempotent verdict")
    if state["held"] < 1:
        rep.fail("golden/wal/replay", "no mismatch-held verdict")
    if state["applied"] < 1:
        rep.fail("golden/wal/replay", "no applied verdict")
    if state["already"] < 1:
        rep.fail("golden/wal/replay", "no already-materialized verdict")
    if state["rebuilt"] < 1:
        rep.fail("golden/wal/replay", "no rebuilt_from_wal vector")
    if state["failed"] < 1 or state["passed"] < 1:
        rep.fail("golden/wal/replay", "vectors must cover both Failed and non-Failed outcomes")
    if state["watermark_steps"] < 1:
        rep.fail("golden/wal/replay", "no vector declares watermark_steps")
    if state["settled_waits"] < 1:
        rep.fail(
            "golden/wal/replay",
            "no vector proves a settled record holds the watermark before its cover",
        )
    for cover in ("complete-write", "truncate", "remove", "ancestor-remove", "repair-write"):
        if cover not in state["covers"]:
            rep.fail("golden/wal/replay", "no settled cover of kind " + cover)
    return state


# ---------------------------------------------------------------------------
# manifest.json schema.
# ---------------------------------------------------------------------------


def _manifest_samples():
    """One valid and several invalid manifest instances for the schema self-test."""

    valid = {
        "format": 1,
        "boot_id": "00112233445566778899aabbccddeeff",
        "materialized_upto_mseq": 46,
        "last_mseq": 46,
        "last_durable_epoch": 3,
        "segments": [
            {
                "file": "wal/00000003.000000.xlwal",
                "epoch": 3,
                "first_mseq": 42,
                "last_mseq": 46,
            }
        ],
    }
    empty = {
        "format": 1,
        "boot_id": "ffeeddccbbaa99887766554433221100",
        "materialized_upto_mseq": 0,
        "last_mseq": 0,
        "last_durable_epoch": 0,
        "segments": [],
    }

    def mutate(name, change):
        sample = copy.deepcopy(valid)
        change(sample)
        return name, sample

    invalid = [
        mutate("format", lambda s: s.update(format=2)),
        mutate("boot_id", lambda s: s.update(boot_id="00112233")),
        mutate("materialized_upto_mseq", lambda s: s.update(materialized_upto_mseq=-1)),
        mutate("last_mseq", lambda s: s.update(last_mseq=-1)),
        mutate("missing last_mseq", lambda s: s.pop("last_mseq")),
        mutate("last_durable_epoch", lambda s: s.update(last_durable_epoch=-1)),
        mutate("segments", lambda s: s.update(segments={})),
        mutate("segment file", lambda s: s["segments"][0].update(file="wal/3.0.xlwal")),
        mutate("segment last_mseq", lambda s: s["segments"][0].pop("last_mseq")),
        mutate("extra member", lambda s: s.update(extra=1)),
        mutate("resync member", lambda s: s.update(needs_resync=[])),
    ]
    return [valid, empty], invalid


def check_manifest_schema(rep, schemas, texts, full):
    rel = "schema/" + MANIFEST_SCHEMA_NAME
    schema = schemas.get(MANIFEST_SCHEMA_NAME)
    if schema is None:
        if full:
            rep.add(rel)
            rep.fail(rel, "manifest schema is required by --full but missing")
        return
    try:
        if schema.get("type") != "object":
            raise SpecError("manifest schema must describe an object")
        required = schema.get("required")
        if not isinstance(required, list) or set(required) != set(MANIFEST_FIELDS):
            raise SpecError(
                "manifest schema required members must be exactly {}".format(list(MANIFEST_FIELDS))
            )
        properties = schema.get("properties")
        if not isinstance(properties, dict) or set(properties) != set(MANIFEST_FIELDS):
            raise SpecError(
                "manifest schema properties must be exactly {}".format(list(MANIFEST_FIELDS))
            )
        if schema.get("additionalProperties") is not False:
            raise SpecError("manifest schema must set additionalProperties to false")
        valid, invalid = _manifest_samples()
        for sample in valid:
            validate_json(sample, schema, rel)
        for label, sample in invalid:
            try:
                validate_json(sample, schema, rel)
            except SpecError:
                continue
            raise SpecError("manifest schema accepted an invalid sample: " + label)
        if full and "schema/" + MANIFEST_SCHEMA_NAME not in texts.get("wal.md", ""):
            raise SpecError("wal.md does not reference schema/" + MANIFEST_SCHEMA_NAME)
    except SpecError as exc:
        rep.fail(rel, str(exc))


# ---------------------------------------------------------------------------
# Handoff endpoint schemas (D15) and D14-D16 section references (D16).
# ---------------------------------------------------------------------------


def _expect_schema_members(schema, members, where):
    if schema.get("type") != "object":
        raise SpecError(where + " must describe an object")
    required = schema.get("required")
    if not isinstance(required, list) or set(required) != set(members):
        raise SpecError("{} required members must be exactly {}".format(where, list(members)))
    properties = schema.get("properties")
    if not isinstance(properties, dict) or set(properties) != set(members):
        raise SpecError("{} properties must be exactly {}".format(where, list(members)))
    if schema.get("additionalProperties") is not False:
        raise SpecError(where + " must set additionalProperties to false")


def _check_fence_schema(schema, owner, where):
    _expect_schema_members(schema, ("owner", "generation", "wal_seq"), where)
    if schema["properties"]["owner"].get("const") != owner:
        raise SpecError(where + '.owner must be const "{}"'.format(owner))


def _check_token(schema, where):
    if schema.get("type") != "string" or schema.get("pattern") != "^[0-9a-f]{32}$":
        raise SpecError(where + " must be a 32-character lowercase hex token")


def _check_sha256(schema, where):
    if schema.get("type") != "string" or schema.get("pattern") != "^[0-9a-f]{64}$":
        raise SpecError(where + " must be a lowercase sha256")


def _check_segment_list(schema, where):
    if schema.get("type") != "array" or not isinstance(schema.get("items"), dict):
        raise SpecError(where + " must be an array of segment descriptors")
    item = schema["items"]
    _expect_schema_members(item, ("file", "first_mseq", "last_mseq", "bytes"), where + "[]")
    pattern = item["properties"]["file"].get("pattern")
    if pattern != "^wal/[0-9]{8}\\.[0-9]{6}\\.xlwal$":
        raise SpecError(where + " file pattern does not match the WAL segment name")


def _check_binary_metadata(schema, name, base_field):
    properties = schema["properties"]
    if properties["payload_bytes"].get("maximum") != MAX_HANDOFF_PAYLOAD:
        raise SpecError(
            name + ".payload_bytes maximum must be {}".format(MAX_HANDOFF_PAYLOAD)
        )
    _check_sha256(properties["payload_sha256"], name + ".payload_sha256")
    if properties[base_field].get("type") != "integer":
        raise SpecError(name + "." + base_field + " must be an integer")


def _handoff_samples():
    """Valid and invalid instances for every handoff endpoint schema."""

    zero = "0" * 64
    remote_fence = {"owner": "remote", "generation": 4, "wal_seq": 57}
    phone_fence = {"owner": "phone", "generation": 5, "wal_seq": 60}
    segment = {
        "file": "wal/00000003.000000.xlwal",
        "first_mseq": 40,
        "last_mseq": 57,
        "bytes": 4096,
    }
    returned = {
        "file": "wal/00000004.000000.xlwal",
        "first_mseq": 58,
        "last_mseq": 60,
        "bytes": 2048,
    }
    valid = {
        "handoff-fence-request.schema.json": [
            {"expected_generation": 3, "wal_seq": 57},
            {"expected_generation": 0, "wal_seq": 0},
        ],
        "handoff-fence-response.schema.json": [
            {"fence": remote_fence, "reclaim_token": "ab" * 16}
        ],
        "handoff-snapshot-request.schema.json": [
            {
                "generation": 4,
                "materialized_upto_mseq": 42,
                "wal_seq": 57,
                "payload_bytes": 1048576,
                "payload_sha256": zero,
            }
        ],
        "handoff-snapshot-response.schema.json": [
            {"materialized_upto_mseq": 42, "fence": remote_fence, "snapshot_sha256": zero}
        ],
        "handoff-segments-request.schema.json": [
            {
                "generation": 4,
                "base_mseq": 42,
                "wal_seq": 57,
                "segments": [segment],
                "payload_bytes": 4096,
                "payload_sha256": zero,
            },
            {
                "generation": 4,
                "base_mseq": 57,
                "wal_seq": 57,
                "segments": [],
                "payload_bytes": 0,
                "payload_sha256": zero,
            },
        ],
        "handoff-segments-response.schema.json": [
            {"base_mseq": 42, "applied_mseq": 57, "wal_seq": 57, "admission": "open"},
            {"base_mseq": 42, "applied_mseq": 42, "wal_seq": 57, "admission": "closed"},
        ],
        "handoff-reclaim-request.schema.json": [{"reclaim_token": "cd" * 16}],
        "handoff-reclaim-response.schema.json": [
            {
                "fence": phone_fence,
                "base_mseq": 57,
                "segments": [returned],
                "payload_bytes": 2048,
                "payload_sha256": zero,
            }
        ],
        "handoff-error.schema.json": [
            {
                "error": {
                    "code": "segments_gap",
                    "message": "expected mseq 51",
                    "applied_mseq": 50,
                    "expected_mseq": 51,
                }
            }
        ],
    }
    invalid = {
        "handoff-fence-request.schema.json": [
            ("missing expected_generation", {"wal_seq": 57}),
            ("negative generation", {"expected_generation": -1, "wal_seq": 57}),
            ("extra member", {"expected_generation": 1, "wal_seq": 2, "owner": "phone"}),
        ],
        "handoff-fence-response.schema.json": [
            ("uppercase token", {"fence": remote_fence, "reclaim_token": "AB" * 16}),
            (
                "wrong owner",
                {"fence": dict(remote_fence, owner="phone"), "reclaim_token": "ab" * 16},
            ),
            ("missing token", {"fence": remote_fence}),
        ],
        "handoff-snapshot-request.schema.json": [
            (
                "missing base",
                {
                    "generation": 4,
                    "wal_seq": 57,
                    "payload_bytes": 1,
                    "payload_sha256": zero,
                },
            ),
            (
                "payload too large",
                {
                    "generation": 4,
                    "materialized_upto_mseq": 42,
                    "wal_seq": 57,
                    "payload_bytes": MAX_HANDOFF_PAYLOAD + 1,
                    "payload_sha256": zero,
                },
            ),
            (
                "uppercase hash",
                {
                    "generation": 4,
                    "materialized_upto_mseq": 42,
                    "wal_seq": 57,
                    "payload_bytes": 1,
                    "payload_sha256": "A" * 64,
                },
            ),
        ],
        "handoff-snapshot-response.schema.json": [
            (
                "wrong owner",
                {
                    "materialized_upto_mseq": 42,
                    "fence": dict(remote_fence, owner="phone"),
                    "snapshot_sha256": zero,
                },
            ),
            ("missing fence", {"materialized_upto_mseq": 42, "snapshot_sha256": zero}),
        ],
        "handoff-segments-request.schema.json": [
            (
                "bad segment file",
                {
                    "generation": 4,
                    "base_mseq": 42,
                    "wal_seq": 57,
                    "segments": [dict(segment, file="wal/3.0.xlwal")],
                    "payload_bytes": 4096,
                    "payload_sha256": zero,
                },
            ),
            (
                "missing segment bytes",
                {
                    "generation": 4,
                    "base_mseq": 42,
                    "wal_seq": 57,
                    "segments": [
                        {
                            "file": segment["file"],
                            "first_mseq": 40,
                            "last_mseq": 57,
                        }
                    ],
                    "payload_bytes": 4096,
                    "payload_sha256": zero,
                },
            ),
            (
                "payload too large",
                {
                    "generation": 4,
                    "base_mseq": 42,
                    "wal_seq": 57,
                    "segments": [segment],
                    "payload_bytes": MAX_HANDOFF_PAYLOAD + 1,
                    "payload_sha256": zero,
                },
            ),
        ],
        "handoff-segments-response.schema.json": [
            (
                "bad admission",
                {"base_mseq": 42, "applied_mseq": 57, "wal_seq": 57, "admission": "maybe"},
            ),
            (
                "missing applied_mseq",
                {"base_mseq": 42, "wal_seq": 57, "admission": "open"},
            ),
            (
                "negative applied_mseq",
                {"base_mseq": 42, "applied_mseq": -1, "wal_seq": 57, "admission": "closed"},
            ),
        ],
        "handoff-reclaim-request.schema.json": [
            ("short token", {"reclaim_token": "cd" * 15}),
            ("uppercase token", {"reclaim_token": "CD" * 16}),
            ("extra generation", {"reclaim_token": "cd" * 16, "expected_generation": 4}),
        ],
        "handoff-reclaim-response.schema.json": [
            (
                "wrong owner",
                {
                    "fence": dict(phone_fence, owner="remote"),
                    "base_mseq": 57,
                    "segments": [returned],
                    "payload_bytes": 2048,
                    "payload_sha256": zero,
                },
            ),
            (
                "missing base",
                {
                    "fence": phone_fence,
                    "segments": [returned],
                    "payload_bytes": 2048,
                    "payload_sha256": zero,
                },
            ),
        ],
        "handoff-error.schema.json": [
            ("unknown code", {"error": {"code": "nope", "message": "x"}}),
            ("missing message", {"error": {"code": "internal"}}),
            ("extra member", {"error": {"code": "internal", "message": "x", "extra": 1}}),
        ],
    }
    return valid, invalid


def _check_handoff_schema_shape(name, schema):
    if name == HANDOFF_ERROR_SCHEMA:
        _expect_schema_members(schema, ("error",), name)
        error = schema["properties"]["error"]
        if not isinstance(error, dict) or error.get("type") != "object":
            raise SpecError(name + ": error must be an object schema")
        if set(error.get("required", [])) != {"code", "message"}:
            raise SpecError(name + ": error required members must be code and message")
        if error.get("additionalProperties") is not False:
            raise SpecError(name + ": error must set additionalProperties to false")
        codes = error.get("properties", {}).get("code", {}).get("enum")
        expected = {
            "unauthorized",
            "fence_conflict",
            "stale_generation",
            "snapshot_conflict",
            "segments_gap",
            "bad_request",
            "payload_mismatch",
            "internal",
        }
        if not isinstance(codes, list) or set(codes) != expected:
            raise SpecError(name + ": error code enum does not match handoff.md §6")
        return
    if name == "handoff-fence-request.schema.json":
        _expect_schema_members(schema, ("expected_generation", "wal_seq"), name)
        return
    if name == "handoff-fence-response.schema.json":
        _expect_schema_members(schema, ("fence", "reclaim_token"), name)
        _check_fence_schema(schema["properties"]["fence"], "remote", name + ".fence")
        _check_token(schema["properties"]["reclaim_token"], name + ".reclaim_token")
        return
    if name == "handoff-snapshot-request.schema.json":
        _expect_schema_members(
            schema,
            (
                "generation",
                "materialized_upto_mseq",
                "wal_seq",
                "payload_bytes",
                "payload_sha256",
            ),
            name,
        )
        _check_binary_metadata(schema, name, "materialized_upto_mseq")
        return
    if name == "handoff-snapshot-response.schema.json":
        _expect_schema_members(
            schema, ("materialized_upto_mseq", "fence", "snapshot_sha256"), name
        )
        _check_fence_schema(schema["properties"]["fence"], "remote", name + ".fence")
        _check_sha256(schema["properties"]["snapshot_sha256"], name + ".snapshot_sha256")
        return
    if name == "handoff-segments-request.schema.json":
        _expect_schema_members(
            schema,
            (
                "generation",
                "base_mseq",
                "wal_seq",
                "segments",
                "payload_bytes",
                "payload_sha256",
            ),
            name,
        )
        _check_segment_list(schema["properties"]["segments"], name + ".segments")
        _check_binary_metadata(schema, name, "base_mseq")
        return
    if name == "handoff-segments-response.schema.json":
        _expect_schema_members(
            schema, ("base_mseq", "applied_mseq", "wal_seq", "admission"), name
        )
        admission = schema["properties"]["admission"]
        if admission.get("enum") != ["open", "closed"]:
            raise SpecError(name + ": admission enum must be open/closed")
        return
    if name == "handoff-reclaim-request.schema.json":
        _expect_schema_members(schema, ("reclaim_token",), name)
        _check_token(schema["properties"]["reclaim_token"], name + ".reclaim_token")
        return
    if name == "handoff-reclaim-response.schema.json":
        _expect_schema_members(
            schema,
            ("fence", "base_mseq", "segments", "payload_bytes", "payload_sha256"),
            name,
        )
        _check_fence_schema(schema["properties"]["fence"], "phone", name + ".fence")
        _check_segment_list(schema["properties"]["segments"], name + ".segments")
        _check_binary_metadata(schema, name, "base_mseq")
        return
    raise SpecError(name + ": unknown handoff schema")


def check_handoff_schemas(spec_dir, rep, schemas, texts, full):
    schema_dir = spec_dir / "schema"
    present = set()
    if schema_dir.is_dir():
        present = {
            path.name for path in schema_dir.glob(HANDOFF_SCHEMA_PREFIX + "*.schema.json")
        }
    if not full and not present and not (spec_dir / "handoff.md").is_file():
        return
    text = texts.get("handoff.md", "")
    for name in HANDOFF_SCHEMAS:
        if name not in present:
            rel = "schema/" + name
            rep.add(rel)
            rep.fail(
                rel,
                "handoff schema is required{} but missing".format(
                    " by --full" if full else ""
                ),
            )
    for name in sorted(present - set(HANDOFF_SCHEMAS)):
        rep.fail("schema/" + name, "unexpected handoff schema file")
    valid_samples, invalid_samples = _handoff_samples()
    for name in HANDOFF_SCHEMAS:
        rel = "schema/" + name
        schema = schemas.get(name)
        if schema is None:
            continue
        try:
            _check_handoff_schema_shape(name, schema)
            for sample in valid_samples[name]:
                validate_json(sample, schema, rel)
            for label, sample in invalid_samples[name]:
                try:
                    validate_json(sample, schema, rel)
                except SpecError:
                    continue
                raise SpecError("accepted an invalid sample: " + label)
            if "schema/" + name not in text:
                raise SpecError("handoff.md does not reference schema/" + name)
        except SpecError as exc:
            rep.fail(rel, str(exc))
    for endpoint, _, _ in HANDOFF_ENDPOINTS:
        if endpoint not in text:
            rep.fail("handoff.md", "does not document {}".format(endpoint))


def _decision_sections(where):
    sections = []
    for match in DECISION_SECTION_RE.finditer(where):
        first = int(match.group(1))
        last = int(match.group(2)) if match.group(2) else first
        if last < first:
            raise SpecError("reversed section range")
        sections.extend(range(first, last + 1))
    return sections


def _has_section(text, number):
    return re.search(r"(?m)^#{1,3}\s+" + str(number) + r"\.", text) is not None


def check_decision_references(spec_dir, found, texts, rep):
    required = {
        14: ("budgets.md", None),
        15: ("handoff.md", None),
        16: ("README.md", "tools/spec_golden.py"),
    }
    for number in HANDOFF_DECISION_NUMBERS:
        if number not in found:
            continue
        _, where = found[number]
        target, extra = required[number]
        named = target in where or (target == "README.md" and "README" in where)
        if not named:
            rep.fail("README.md", "decision D{} does not point at {}".format(number, target))
            continue
        if extra is not None:
            if extra not in where:
                rep.fail("README.md", "decision D{} does not point at {}".format(number, extra))
            if not (spec_dir / extra).is_file():
                rep.fail("README.md", "decision D{} points at missing {}".format(number, extra))
        try:
            sections = _decision_sections(where)
        except SpecError as exc:
            rep.fail("README.md", "decision D{}: {}".format(number, exc))
            continue
        if not sections:
            rep.fail("README.md", "decision D{} names no section".format(number))
            continue
        target_text = texts.get(target)
        if target_text is None:
            target_text = read_text(spec_dir, target, rep)
        for section in sections:
            if not _has_section(target_text, section):
                rep.fail(
                    "README.md",
                    "decision D{} points at {} §{}, but that section is absent".format(
                        number, target, section
                    ),
                )
        for ref in DECISION_FILE_RE.findall(where):
            if ref in (target, extra):
                continue
            if not (spec_dir / ref).is_file():
                rep.fail("README.md", "decision D{} points at missing {}".format(number, ref))


# ---------------------------------------------------------------------------
# WAL and exec document coverage (D8, D11, D16-D20).
# ---------------------------------------------------------------------------

WAL_DOC_TOKENS = (
    "XLWAL1",
    "wal/<epoch:08d>.<segment:06d>.xlwal",
    "F_FULLFSYNC",
    "manifest.json",
    "reconcile.inprogress",
    "materialized.staging",
    "WAL_CORRUPT",
    "schema/manifest.schema.json",
    WAL_HEADER_CONSTANT_HEX,
    # D8: the watermark is strictly contiguous, the repair request is immediate, the manifest
    # persists no resync state and an unrepaired mismatch fails at the next epoch close.
    "strictly contiguous watermark",
    "VFS_RESYNC",
    "at once",
    "next epoch close",
    "No resync state is persisted in the manifest",
    "never discarded",
    # Conservative settlement (CCR-1 round 2): a settled record is passed only once its cover is
    # applied and inside the same contiguous prefix; a settled record whose cover is above the
    # watermark still blocks it. The manifest schema is not changed.
    "covering record has been applied to the materialized copy",
    "has been applied at or below the recorded watermark",
    "cover's `mseq` is at most the watermark",
    # D17: the never-reused high-water formula.
    "max(last_mseq, WAL tail) + 1",
    "`last_mseq`",
    # D18: materialized files first, then every WAL segment, then the manifest, then compaction.
    "fsync the changed materialized copy",
    "every segment file written in this epoch",
    "happen only after this order has completed",
    # D19: a torn tail is truncated and logged; a non-tail CRC failure fails the host.
    "truncated to the last complete",
    "the truncation is logged",
    "not at the tail",
    # BUG-1: a zero-length segment has no header and no record; it is dropped with a
    # diagnostic, never promoted to WAL_CORRUPT. Header damage in a non-zero file still fails.
    "WAL_EMPTY_SEGMENT_DROPPED segment=<n>",
    "zero-length segment",
    # BUG-1 shapes 2 and 3: a legal large record cut short is a torn tail, and an
    # adopted epoch may span several unlisted segments of the same epoch.
    "a tail-search work budget",
    "only the first is",
    # D11: the materialized copy plus the WAL tail are the reconcile inputs.
    "never the WAL alone",
    "all of its recorded mutations have",
    "adopted tail",
)

EXEC_DOC_TOKENS = (
    "XL_IDEMPOTENCY_KEY",
    "0x1F",
    "idem_key",
    "requires_mseq",
    "grace_ms",
    "accelerator:rg",
    "steps/",
    "Idempotency-Key",
    "handoff.md",
    "budgets.md",
    # D20: the canonical rg EXEC_REQ requests workspace-write; an accelerator is accepted read-only
    # and never rejected for that reason.
    "workspace-write",
    "read-only regardless",
    "never rejected",
    # D20: step_id is the 1-based decimal ordinal of the tool call within the turn; one step
    # identity is shared by the dedup ledger and the step records.
    "One step id per call",
    "store the same decimal",
    "decimal ordinal of the tool call",
    "(session_id, turn_id, step_id)",
    # D20: model_streaming belongs to the turn, not to one tool call.
    "belongs to\n  the turn",
)

# Rules that earlier revisions stated ambiguously. Both spellings must stay out of the documents:
# a residual copy would reintroduce the contradiction the review reported even if the new wording
# is also present.
WAL_FORBIDDEN_TOKENS = (
    "dropped silently when all of its recorded mutations have",
    "needs_resync",
    "needs-resync",
    "applied to the materialized copy or deferred",
    "its bytes are settled, the watermark may pass it",
    "settled-superseded by a later retained record; a strictly contiguous watermark",
)
EXEC_FORBIDDEN_TOKENS = (
    "`step_id` is the call's `XL_IDEMPOTENCY_KEY`",
    "its `XL_IDEMPOTENCY_KEY` when",
)


def check_wal_docs(texts, rep, full):
    if not full:
        return
    for name, tokens in (("wal.md", WAL_DOC_TOKENS), ("exec.md", EXEC_DOC_TOKENS)):
        text = texts.get(name, "")
        missing = [token for token in tokens if token not in text]
        if missing:
            rep.fail(name, "lacks required contract text: {}".format(missing))
    for name, tokens in (("wal.md", WAL_FORBIDDEN_TOKENS), ("exec.md", EXEC_FORBIDDEN_TOKENS)):
        text = texts.get(name, "")
        superseded = [token for token in tokens if token in text]
        if superseded:
            rep.fail(name, "still contains a superseded rule: {}".format(superseded))


# Handoff and budget document coverage (D14, D15, D16). The tokens are the contract phrases that
# a reworded document must keep; they are not a substitute for the schemas.
HANDOFF_DOC_TOKENS = (
    "expected_generation",
    "reclaim_token",
    "materialized_upto_mseq",
    "base_mseq",
    "applied_mseq",
    "payload_sha256",
    "payload_bytes",
    "snapshot_sha256",
    "fence.wal_seq",
    "24 h",
    "401",
    "TLS",
    "Bearer",
    "Cache-Control: no-store",
    "uncompressed",
    "generation + 1",
    "`applied_mseq == fence.wal_seq`",
    "owner: phone",
    "`mseq ≤ applied`",
    "D15",
    "D17",
)

BUDGETS_DOC_TOKENS = (
    "Running",
    "Draining",
    "Parked",
    "Recovering",
    "Backoff",
    "HandingOff",
    "Remote",
    "Reclaiming",
    "Failed",
    "20 s",
    "scenePhase",
    "thermalState",
    "NWPathMonitor",
    "WebContent termination",
    # The §4 tier rows are the budget-derived constants; keep this list in step
    # with the normative table. The superseded rows (engine heap 320 MB, VFS
    # split 160 / 50 / 50 MB, fixed 2 h planned restart) are history in the §6
    # revision note and in the restart-policy revision; they are not required
    # contract text, and the rows that replaced them are pinned instead.
    "832 MB",
    "448 MB",
    "388 MB",
    "540 MB",
    "230 MB",
    "256 MB",
    "192 MB",
    "144 MB",
    "260 MB",
    "200 MB",
    "96 MB",
    "288 / 50 / 50 MB",
    "120 / 40 / 40 MB",
    "80 / 32 / 32 MB",
    "48 / 24 / 24 MB",
    "64 MiB",
    "48 MiB",
    "32 MiB",
    "16 MiB",
    "128 MiB",
    "150 MB",
    "140 MB",
    "120 MB",
    "100 MB",
    "50 %",
    "≤ 2",
    "thermal fair",
    "p95 < 5 ms",
    "policy triggers, at a tool-call boundary",
    "0.05 s/MB",
    "256 MiB",
    # §5 pins the WAL quota row itself, not just the value: the same number also
    # appears in the revision note, so a bare "512 MiB" token cannot tell the
    # normative quota row from its history.
    "| WAL segments | 512 MiB |",
    "ENOSPC",
)


def check_handoff_docs(texts, rep, full):
    if not full:
        return
    for name, tokens in (("handoff.md", HANDOFF_DOC_TOKENS), ("budgets.md", BUDGETS_DOC_TOKENS)):
        if name not in texts:
            continue
        text = texts[name]
        missing = [token for token in tokens if token not in text]
        if missing:
            rep.fail(name, "lacks required contract text: {}".format(missing))





def run_constants(rep):
    rel = "tools/spec_golden.py"
    rep.add(rel)
    try:
        if crc32c(b"123456789") != 0xE3069283:
            raise SpecError("crc32c known answer failed")
        if encode_header(0x11, 1, 9).hex() != FRAME_HEADER_CONSTANT_HEX:
            raise SpecError("hand-computed frame header constant failed")
        if len(WAL_MAGIC) != 8:
            raise SpecError("WAL magic is not 8 bytes")
        if not WAL_SEGMENT_RE.match("wal/00000003.000000.xlwal"):
            raise SpecError("WAL segment naming pattern rejects a valid name")
        if WAL_SEGMENT_RE.match("wal/3.0.xlwal"):
            raise SpecError("WAL segment naming pattern accepts an invalid name")
        wal_crc, wal_header = encode_wal_header(1, 0, 1, bytes(16))
        if len(wal_header) != WAL_HEADER_LEN:
            raise SpecError("WAL header is not 40 bytes")
        if wal_header.hex() != WAL_HEADER_CONSTANT_HEX:
            raise SpecError("hand-computed WAL header constant failed")
        if wal_crc != WAL_HEADER_CONSTANT_CRC32C:
            raise SpecError("hand-computed WAL header crc32c constant failed")
        if len(HANDOFF_SCHEMAS) != 9 or len(set(HANDOFF_SCHEMAS)) != 9:
            raise SpecError("handoff schema table must name 9 unique files")
        if MAX_HANDOFF_PAYLOAD != 272 * 1024 * 1024:
            raise SpecError("MAX_HANDOFF_PAYLOAD is not 272 MiB")
        for name in HANDOFF_SCHEMAS:
            if not name.startswith(HANDOFF_SCHEMA_PREFIX):
                raise SpecError("handoff schema name lacks the handoff- prefix")
        for name, value in TYPE_NAMES.items():
            if not 0 < name <= 0x7F:
                raise SpecError("frame type byte out of range")
            if name == 0x10 and value != "VFS_MUT":
                raise SpecError("frame type table is corrupted")
    except SpecError as exc:
        rep.fail(rel, str(exc))


def check_hygiene(spec_dir, rep):
    for path in sorted(spec_dir.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(spec_dir))
        if "__pycache__" in rel or rel.endswith(".pyc"):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if "/" + "Users/" in text:
            rep.fail(rel, "contains an absolute local user path")
        if EMAIL_RE.search(text):
            rep.fail(rel, "contains an e-mail address")


def check_spec(spec_dir, full):
    rep = Reporter()
    run_constants(rep)

    texts = check_docs(spec_dir, rep, full)
    found = check_decisions(texts.get("README.md", ""), rep)

    golden_readme = read_text(spec_dir, "golden/README.md", rep)
    texts["golden/README.md"] = golden_readme
    schemas = check_schemas(spec_dir, rep, texts)

    coverage = {}
    frames_dir = spec_dir / "golden" / "frames"
    frame_paths = sorted(frames_dir.glob("*.json")) if frames_dir.is_dir() else []
    if not frame_paths:
        rep.fail("golden/frames", "golden/frames contains no vectors")
    for path in frame_paths:
        check_frame_vector(spec_dir, path, rep, schemas, coverage)

    check_coverage(rep, coverage, schemas)
    for token in ("data_hex", "body_hex", "record_hex", "boot_id_hex"):
        if token not in golden_readme:
            rep.fail("golden/README.md", "does not document the {} convention".format(token))

    check_wal_vectors(spec_dir, rep, full)
    check_wal_lifecycle_vectors(spec_dir, rep, schemas, full)
    check_wal_replay_vectors(spec_dir, rep, schemas, full)
    check_manifest_schema(rep, schemas, texts, full)
    check_handoff_schemas(spec_dir, rep, schemas, texts, full)
    check_decision_references(spec_dir, found, texts, rep)
    check_wal_docs(texts, rep, full)
    check_handoff_docs(texts, rep, full)
    # W0/W2/W3/W4/W7 contract cases: their envelope is a schema; the per-vector
    # law lives in the dedicated checker. The import is lazy so the dedicated
    # checker can reuse this module's validator without a circular import.
    from plan_cases_check import run as run_plan_cases  # noqa: E402
    for rel, message in run_plan_cases(spec_dir):
        rep.add(rel)
        if message != "ok":
            rep.fail(rel, message)
    for name, text in texts.items():
        if INTERNAL_TASK_ID in text:
            rep.fail(name, "contains an internal task identifier")
    check_hygiene(spec_dir, rep)

    test_tool = spec_dir / "tools" / "test_spec_golden.py"
    rep.add("tools/test_spec_golden.py")
    if not test_tool.is_file():
        rep.fail("tools/test_spec_golden.py", "mutation test file is missing")
    return rep.emit()


def main(argv=None):
    parser = argparse.ArgumentParser(description="phone-dsh-v1 golden checker")
    parser.add_argument(
        "--spec-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="spec/v1 directory (default: the directory containing this script)",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="require the WAL, exec, handoff and budgets documents, the manifest, handoff and "
        "replay schemas and the WAL and replay vectors",
    )
    args = parser.parse_args(argv)
    spec_dir = args.spec_dir.resolve()
    if not (spec_dir / "README.md").is_file():
        print("FAIL {}: README.md not found".format(spec_dir), file=sys.stderr)
        return 2
    try:
        errors = check_spec(spec_dir, args.full)
    except SpecError as exc:
        print("FAIL: {}".format(exc), file=sys.stderr)
        return 1
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
