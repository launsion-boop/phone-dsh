#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared-fixture checker for spec/device/v1/ble-secure-session.md (secure-session-v1).

This file is a spec checker, not runtime conformance. It (1) pins the exact bytes
of every reviewed golden file, (2) validates every vector against the JSON
Schemas in spec/device/v1/schema, and (3) replays every vector through a small
reference oracle written from the normative text, so a semantically wrong edit
that is re-hashed still fails. The Swift and firmware implementations must run
the same files through their real parsers, state machines and stores.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
import unittest
from pathlib import Path

import spec_golden

DEVICE = Path(__file__).resolve().parents[2] / "device" / "v1"
GOLDEN = DEVICE / "golden"
SCHEMA = DEVICE / "schema"

# Reviewed fixture revision secure-session-v1. Changing a vector requires a new
# contract revision recorded in the change record, then updating these digests.
FROZEN = {
    "ble-secure-identifiers.jsonl": "3451c5eab7cd02bcb6a3d95f20f242df2fb5b07ff2929dbdc33df7f6bb205cf0",
    "ble-secure-enrollment-lines.jsonl": "bce3c67bd5b1e0e0d5ce96f29978b8709c3d4a480ec946ecfed6d2384aa5198b",
    "ble-secure-enrollment-states.jsonl": "f44e40a1d15c670620a72f1bd48b35633852ba45a7eb620860b1d773392088de",
    "ble-secure-certificates.jsonl": "053ac7374f86e4e34311714eca7c4f002bc7c6ddb60543ce02ef606bffb35d30",
    "ble-secure-frames.jsonl": "3818e1d0ae08b070143893faa214520321076d9110a7df409c6ee2f3dcfc1f8b",
    "ble-secure-messages.jsonl": "ede654362f70d36aede67b6f4b25ebafcaab10f0b608dca58a6bcb325eb45b6a",
    "ble-secure-session-sequences.jsonl": "44eed40f9b117ba712b8fbfd950c248846271b9cad1042e6cadfd88785d1dce9",
    "ble-secure-recovery.jsonl": "42dfeb7f1a54edcb02e48956f68bad9fcf5b281802b113a0a6f310d9e3d9f6c5",
    "ble-secure-task-intents.jsonl": "23cb3da179fcd94736935060bea4c4203b5b9ce269c95e9da2976597fd2995a1",
    "ble-secure-task-store-cases.jsonl": "28a7fb88dd62a0b509b4ede9bf73d5a9243da90ea83c947b11740f09908aa040",
}

HEX = frozenset("0123456789abcdef")
P256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
MAX_FRAME = 4096
CONSOLE_MAX = 384


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

class Invalid(Exception):
    """A vector input the normative rules reject."""


def _no_dup(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise Invalid("duplicate member")
        out[key] = value
    return out


def _reject_constant(name):
    raise Invalid("non-JSON constant " + name)


def _scan_strings(value):
    if isinstance(value, str):
        if "\x00" in value:
            raise Invalid("NUL")
        try:
            value.encode("utf-8")
        except UnicodeEncodeError:
            raise Invalid("unpaired surrogate")
    elif isinstance(value, dict):
        for key, item in value.items():
            _scan_strings(key)
            _scan_strings(item)
    elif isinstance(value, list):
        for item in value:
            _scan_strings(item)


def strict_json(data: bytes):
    """§7.2 payload decoding: UTF-8, no BOM, one JSON value, no duplicates/NUL/surrogates."""
    if data.startswith(b"\xef\xbb\xbf"):
        raise Invalid("BOM")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise Invalid("invalid UTF-8")
    try:
        value = json.loads(text, object_pairs_hook=_no_dup, parse_constant=_reject_constant)
    except json.JSONDecodeError:
        raise Invalid("JSON syntax")
    _scan_strings(value)
    return value


def read_rows(name):
    data = (GOLDEN / name).read_bytes()
    assert data.endswith(b"\n") and b"\r" not in data, name
    rows = [json.loads(line, object_pairs_hook=spec_golden._pairs_no_duplicates)
            for line in data.decode("utf-8").split("\n")[:-1]]
    return data, rows


def schema(name):
    return json.loads((SCHEMA / name).read_text(encoding="utf-8"))


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


# ---------------------------------------------------------------------------
# §2 identifiers
# ---------------------------------------------------------------------------

def is_hex(text, length):
    return isinstance(text, str) and len(text) == length and set(text) <= HEX


def public_key_fingerprint(hex_text):
    """Return the 64-hex fingerprint of a SEC1 uncompressed P-256 point or raise Invalid(reason)."""
    if not isinstance(hex_text, str) or len(hex_text) % 2 or any(c not in "0123456789abcdefABCDEF" for c in hex_text):
        raise Invalid("not_hex")
    if hex_text != hex_text.lower():
        raise Invalid("uppercase")
    raw = bytes.fromhex(hex_text)
    if len(raw) != 65:
        raise Invalid("length")
    if raw[0] != 4:
        raise Invalid("not_uncompressed")
    x = int.from_bytes(raw[1:33], "big")
    y = int.from_bytes(raw[33:], "big")
    if x >= P256_P or y >= P256_P:
        raise Invalid("coordinate_range")
    if (y * y - (x * x * x - 3 * x + P256_B)) % P256_P:
        raise Invalid("not_on_curve")
    return sha(raw)


IDENT_RE = {"device": re.compile(r"ble:[0-9a-f]{64}"), "phone": re.compile(r"phone:[0-9a-f]{64}")}
BOARD_TOKEN = re.compile(r"pdsh-board-v1:([0-9a-fA-F]{64}):([0-9a-fA-F]{32})")
PHONE_TOKEN = re.compile(r"pdsh-phone-v1:([0-9a-f]{64})")


def parse_board_token(text):
    """§3.4 phone input: trim ASCII space/tab/CR/LF at both ends, accept either hex case."""
    trimmed = text.strip(" \t\r\n")
    match = BOARD_TOKEN.fullmatch(trimmed)
    if not match:
        raise Invalid("syntax")
    return match.group(1).lower(), match.group(2).lower()


# ---------------------------------------------------------------------------
# §3 console grammar
# ---------------------------------------------------------------------------

CMD_FIELDS = {
    "status": [], "begin": [], "phone": ["eid", "phone"], "commit": ["eid", "device", "phone"],
    "abort": ["eid"], "revoke": ["eid", "device", "phone"], "identity-reset": [],
}
RESP_FIELDS = {
    "status": ["state", "ctx", "device", "phone", "eid", "rev"],
    "begun": ["eid", "device"],
    "staged": ["eid", "device", "phone", "token"],
    "press": ["eid", "action", "timeout_s"],
    "committed": ["eid", "device", "phone", "rev"],
    "aborted": ["eid"],
    "revoked": ["eid", "device", "phone", "rev"],
    "reset": ["device"],
    "error": ["code", "cmd"],
}
STATES = ("none", "committed", "revoked", "key_lost", "key_unavailable", "record_corrupt")
CTXS = ("idle", "begun", "staged", "press")
ACTIONS = ("commit", "revoke", "identity-reset")
CONSOLE_CODES = ("syntax", "busy", "occupied", "no_session", "state", "eid_mismatch", "value_mismatch",
                 "same_key", "timeout", "storage", "button_unavailable", "key_lost", "key_unavailable",
                 "record_corrupt")
REV_RE = re.compile(r"0|[1-9][0-9]{0,9}")


def _value_ok(direction, verb, name, value, fields):
    if name == "eid":
        return is_hex(value, 32) or (direction == "board" and verb in ("status", "press") and value == "-")
    if name in ("device", "phone"):
        return is_hex(value, 64) or (direction == "board" and verb == "status" and value == "-")
    if name == "rev":
        return bool(REV_RE.fullmatch(value)) and int(value) <= 4294967295
    if name == "state":
        return value in STATES
    if name == "ctx":
        return value in CTXS
    if name == "action":
        return value in ACTIONS
    if name == "timeout_s":
        return value == "30"
    if name == "token":
        return value == "pdsh-board-v1:%s:%s" % (fields.get("device"), fields.get("eid"))
    if name == "code":
        return value in CONSOLE_CODES
    if name == "cmd":
        return value == "-" or value in CMD_FIELDS
    return False


def parse_console(raw: bytes, direction: str):
    """Return None (not addressed), ('err', verb_or_dash) or ('ok', verb, fields)."""
    prefix = b"pdsh-enroll" if direction == "host" else b"pdsh-enroll-r"
    if not raw.endswith(b"\n") or b"\n" in raw[:-1]:
        raise AssertionError("one LF-terminated line per call")
    line = raw[:-1]
    if line.endswith(b"\r"):
        line = line[:-1]
    first = line.split(b" ", 1)[0]
    if first != prefix:
        return None
    tokens = line.split(b" ")
    verb_bytes = tokens[1] if len(tokens) > 1 else b""
    table = CMD_FIELDS if direction == "host" else RESP_FIELDS
    verb = verb_bytes.decode("ascii", "replace")
    echo = verb if verb in table else "-"
    if not 1 <= len(line) <= CONSOLE_MAX or any(b < 0x20 or b > 0x7E for b in line):
        return ("err", echo)
    if any(t == b"" for t in tokens) or verb not in table:
        return ("err", echo)
    names = table[verb]
    rest = [t.decode("ascii") for t in tokens[2:]]
    if len(rest) != len(names):
        return ("err", echo)
    fields = {}
    for name, token in zip(names, rest):
        key, sep, value = token.partition("=")
        if not sep or key != name or value == "":
            return ("err", echo)
        fields[name] = value
    for name in names:
        if not _value_ok(direction, verb, name, fields[name], fields):
            return ("err", echo)
    return ("ok", verb, fields)


def console_line(verb, **fields):
    names = RESP_FIELDS[verb]
    assert set(fields) == set(names), (verb, fields)
    return " ".join(["pdsh-enroll-r", verb] + ["%s=%s" % (n, fields[n]) for n in names])


# ---------------------------------------------------------------------------
# §3 board enrollment oracle
# ---------------------------------------------------------------------------

class Board:
    def __init__(self, given):
        self.state = given["state"]
        self.device = given.get("device")
        self.phone = given.get("phone")
        self.eid = given.get("eid")
        self.rev = given.get("rev", 0)
        self.button = given.get("button", True)
        self.eids = list(given.get("eids", []))
        self.new_keys = list(given.get("new_keys", []))
        self.ctx = {"kind": "idle"}
        self.fail_next_write = False
        self.ram_revoked = False

    def durable(self):
        return {"state": self.state, "device": self.device, "phone": self.phone, "eid": self.eid, "rev": self.rev}

    def _err(self, code, cmd):
        return console_line("error", code=code, cmd=cmd)

    def _abort(self):
        self.ctx = {"kind": "idle"}

    def _status(self):
        shows_record = self.state in ("committed", "revoked")
        return console_line("status", state=self.state, ctx=self.ctx["kind"],
                            device=self.device if self.state not in ("key_lost", "key_unavailable") else "-",
                            phone=self.phone if shows_record else "-",
                            eid=self.eid if shows_record else "-", rev=str(self.rev))

    def line(self, raw: bytes):
        parsed = parse_console(raw, "host")
        if parsed is None:
            return None
        if self.ctx["kind"] == "press":
            self._abort()
            return self._err("busy", parsed[1])
        if parsed[0] == "err":
            return self._err("syntax", parsed[1])
        _, verb, f = parsed
        if verb == "status":
            return self._status()
        if self.state in ("key_lost", "key_unavailable", "record_corrupt") and verb != "identity-reset":
            self._abort()
            return self._err(self.state, verb)
        if verb == "begin":
            if self.ctx["kind"] != "idle":
                self._abort()
                return self._err("busy", verb)
            if self.state == "committed":
                return self._err("occupied", verb)
            if not self.button:
                return self._err("button_unavailable", verb)
            eid = self.eids.pop(0)
            self.ctx = {"kind": "begun", "eid": eid}
            return console_line("begun", eid=eid, device=self.device)
        if verb == "phone":
            if self.ctx["kind"] == "idle":
                return self._err("no_session", verb)
            if self.ctx["kind"] != "begun":
                self._abort()
                return self._err("state", verb)
            if f["eid"] != self.ctx["eid"]:
                self._abort()
                return self._err("eid_mismatch", verb)
            if f["phone"] == self.device:
                self._abort()
                return self._err("same_key", verb)
            self.ctx = {"kind": "staged", "eid": f["eid"], "phone": f["phone"]}
            return console_line("staged", eid=f["eid"], device=self.device, phone=f["phone"],
                                token="pdsh-board-v1:%s:%s" % (self.device, f["eid"]))
        if verb == "commit":
            if self.ctx["kind"] == "idle":
                return self._err("no_session", verb)
            if self.ctx["kind"] != "staged":
                self._abort()
                return self._err("state", verb)
            if f["eid"] != self.ctx["eid"]:
                self._abort()
                return self._err("eid_mismatch", verb)
            if f["device"] != self.device or f["phone"] != self.ctx["phone"]:
                self._abort()
                return self._err("value_mismatch", verb)
            self.ctx = {"kind": "press", "action": "commit", "eid": f["eid"], "phone": f["phone"]}
            return console_line("press", eid=f["eid"], action="commit", timeout_s="30")
        if verb == "abort":
            if self.ctx["kind"] == "idle":
                return self._err("no_session", verb)
            if f["eid"] != self.ctx["eid"]:
                self._abort()
                return self._err("eid_mismatch", verb)
            self._abort()
            return console_line("aborted", eid=f["eid"])
        if verb == "revoke":
            if self.ctx["kind"] != "idle":
                self._abort()
                return self._err("busy", verb)
            if self.state != "committed":
                return self._err("state", verb)
            if (f["eid"], f["device"], f["phone"]) != (self.eid, self.device, self.phone):
                return self._err("value_mismatch", verb)
            self.ctx = {"kind": "press", "action": "revoke", "eid": self.eid}
            return console_line("press", eid=self.eid, action="revoke", timeout_s="30")
        if verb == "identity-reset":
            if self.ctx["kind"] != "idle":
                self._abort()
                return self._err("busy", verb)
            if self.state == "committed":
                return self._err("occupied", verb)
            if not self.button:
                return self._err("button_unavailable", verb)
            self.ctx = {"kind": "press", "action": "identity-reset", "eid": "-"}
            return console_line("press", eid="-", action="identity-reset", timeout_s="30")
        raise AssertionError(verb)

    def event(self, name):
        if name == "press":
            if self.ctx["kind"] != "press":
                return None
            ctx, self.ctx = self.ctx, {"kind": "idle"}
            failing, self.fail_next_write = self.fail_next_write, False
            if ctx["action"] == "commit":
                if failing:
                    return self._err("storage", "commit")
                self.state, self.eid, self.phone, self.rev = "committed", ctx["eid"], ctx["phone"], self.rev + 1
                self.ram_revoked = False
                return console_line("committed", eid=self.eid, device=self.device, phone=self.phone, rev=str(self.rev))
            if ctx["action"] == "revoke":
                self.ram_revoked = True
                if failing:
                    return self._err("storage", "revoke")
                self.state, self.rev = "revoked", self.rev + 1
                return console_line("revoked", eid=self.eid, device=self.device, phone=self.phone, rev=str(self.rev))
            if failing:
                return self._err("storage", "identity-reset")
            self.device = self.new_keys.pop(0)
            self.state, self.phone, self.eid, self.rev = "none", None, None, 0
            return console_line("reset", device=self.device)
        if name == "press_timeout":
            if self.ctx["kind"] != "press":
                return None
            action = self.ctx["action"]
            self._abort()
            return self._err("timeout", action)
        if name == "context_expired":
            if self.ctx["kind"] not in ("begun", "staged"):
                return None
            self._abort()
            return self._err("timeout", "-")
        if name == "reboot":
            self._abort()
            self.ram_revoked = False
            return None
        if name == "fail_next_write":
            self.fail_next_write = True
            return None
        raise AssertionError(name)


# ---------------------------------------------------------------------------
# §3.4 phone enrollment oracle (single device record + the phone key)
# ---------------------------------------------------------------------------

class Phone:
    def __init__(self, given):
        self.key = given["key"]              # absent | present | lost
        self.phone = given.get("phone")      # 64 hex when a key exists
        self.next_phone = list(given.get("new_keys", []))
        rec = given.get("record")
        self.record = dict(rec) if rec else None
        self.fail_next_write = False

    def snapshot(self):
        return {"key": self.key, "phone": self.phone, "record": copy.deepcopy(self.record)}

    def _write(self, record):
        failing, self.fail_next_write = self.fail_next_write, False
        if failing:
            raise Invalid("storage")
        self.record = record

    def op(self, step):
        name = step["op"]
        try:
            return self._op(name, step)
        except Invalid as exc:
            return str(exc)

    def _op(self, name, step):
        rec = self.record
        if name == "show_token":
            if self.key == "lost":
                raise Invalid("phone_key_lost")
            if self.key == "absent":
                self.key, self.phone = "present", self.next_phone.pop(0)
            return "pdsh-phone-v1:" + self.phone
        if name == "enter_token":
            device, eid = parse_board_token(step["token"])
            if self.key == "lost":
                raise Invalid("phone_key_lost")
            if self.key == "absent":
                raise Invalid("no_phone_key")
            if device == self.phone:
                raise Invalid("same_key")
            if rec and rec["state"] == "corrupt":
                raise Invalid("record_corrupt")
            if rec and rec["device"] != device:
                raise AssertionError("single-record oracle")
            if rec and rec["state"] == "committed":
                raise Invalid("occupied")
            if rec and rec["state"] == "staged":
                if rec["eid"] == eid and rec["phone"] == self.phone:
                    return "ok"
                raise Invalid("busy")
            rev = rec["rev"] + 1 if rec else 1
            self._write({"state": "staged", "device": device, "phone": self.phone, "eid": eid, "rev": rev})
            return "ok"
        if name in ("confirm", "abort", "forget"):
            if self.key == "lost":
                raise Invalid("phone_key_lost")
            if not rec:
                raise Invalid("state")
            if rec["state"] == "corrupt":
                raise Invalid("record_corrupt")
            if name == "confirm":
                if rec["state"] != "staged":
                    raise Invalid("state")
                if step["eid"] != rec["eid"] or step["device"] != rec["device"]:
                    raise Invalid("value_mismatch")
                self._write(dict(rec, state="committed", rev=rec["rev"] + 1))
                return "ok"
            allowed = ("staged",) if name == "abort" else ("staged", "committed")
            if rec["state"] not in allowed:
                raise Invalid("state")
            self._write(dict(rec, state="revoked", rev=rec["rev"] + 1))
            return "ok"
        if name == "restart":
            return "ok"
        if name == "fail_next_write":
            self.fail_next_write = True
            return "ok"
        if name == "key_missing":
            self.key = "lost" if rec else "absent"
            if self.key == "absent":
                self.phone = None
            return "ok"
        if name == "reset_phone_key":
            if rec and rec["state"] in ("staged", "committed"):
                self._write(dict(rec, state="revoked", rev=rec["rev"] + 1))
            self.key, self.phone = "present", self.next_phone.pop(0)
            return "ok"
        if name == "session_eligible":
            ok = (self.key == "present" and rec is not None and rec["state"] == "committed"
                  and rec["phone"] == self.phone)
            return "yes" if ok else "no"
        raise AssertionError(name)


# ---------------------------------------------------------------------------
# §7 framing and messages
# ---------------------------------------------------------------------------

def decode_frames(chunks, eof):
    buf = b""
    out = []
    for chunk in chunks:
        buf += chunk
        while len(buf) >= 2:
            size = buf[0] | (buf[1] << 8)
            if size == 0 or size > MAX_FRAME:
                return out, "limit"
            if len(buf) < 2 + size:
                break
            out.append(buf[2:2 + size])
            buf = buf[2 + size:]
    if eof and buf:
        return out, "truncated"
    return out, None


C2S = ("ready_req", "next", "accept", "complete", "fail", "status", "err")
S2C = ("ready_ack", "next_r", "r", "status_r", "err")


def validate_message(payload: bytes, direction: str, message_schema):
    value = strict_json(payload)
    try:
        spec_golden.validate_json(value, message_schema, "message")
    except spec_golden.SpecError:
        raise Invalid("schema")
    allowed = C2S if direction == "c2s" else S2C
    if value["t"] not in allowed:
        raise Invalid("direction")
    if value["t"] == "err" and direction == "c2s" and value["re"] != 0:
        raise Invalid("client err re")
    if value["t"] == "complete" and len(value["output"].encode("utf-8")) > 1024:
        raise Invalid("output bytes")
    if value["t"] == "fail" and len(value["failure"]["message"].encode("utf-8")) > 256:
        raise Invalid("message bytes")
    if value["t"] == "next_r" and (value["task"] is None) != (value["phase"] is None):
        raise Invalid("task/phase")
    if value["t"] == "status_r":
        terminal = value["phase"] in ("completed", "failed")
        if ("outcome" in value) != (terminal and value["mine"]):
            raise Invalid("outcome presence")
        if value["phase"] in ("unknown", "queued") and value["mine"]:
            raise Invalid("mine")
        if "outcome" in value and (("output" in value["outcome"]) != (value["phase"] == "completed")):
            raise Invalid("outcome kind")
    return value


# ---------------------------------------------------------------------------
# §8 device session oracle
# ---------------------------------------------------------------------------

def outcome_of(msg):
    if msg["t"] == "complete":
        return "completed", {"output": msg["output"], "truncated": msg["truncated"]}
    return "failed", {"failure": msg["failure"]}


class DeviceSession:
    def __init__(self, given):
        self.record = dict(given["record"])
        self.peer = given["peer_phone"]
        self.sc = given["sc"]
        self.store = copy.deepcopy(given["store"])
        self.fail_next_write = False
        self.closed = False
        self.state = "verified"
        self.last = 0
        self.revoked = False

    def handshake(self):
        if self.record["state"] != "committed" or self.peer != self.record["phone"]:
            self.closed = True
            return "reject"
        return "accept"

    def _close(self, re_, code):
        self.closed = True
        return {"send": {"v": 1, "t": "err", "re": re_, "code": code}, "close": True}

    def _slot(self, task_id):
        for slot in self.store:
            if slot["task"]["id"] == task_id:
                return slot
        return None

    def _write(self, apply):
        failing, self.fail_next_write = self.fail_next_write, False
        if failing:
            return False
        apply()
        return True

    def event(self, name):
        if name == "fail_next_write":
            self.fail_next_write = True
            return {"send": None, "close": False}
        if self.closed:
            return {"send": None, "close": False}
        if name == "revoke":
            self.revoked = True
            return self._close(0, "revoked")
        if name in ("idle_timeout", "ready_timeout"):
            return self._close(0, "timeout")
        raise AssertionError(name)

    def recv(self, msg):
        if self.closed:
            return {"send": None, "close": False}
        t = msg["t"]
        if t not in C2S:
            return self._close(0, "malformed")
        if t == "err":
            self.closed = True
            return {"send": None, "close": True}
        seq = msg["seq"]
        if self.state == "verified":
            if t != "ready_req":
                return self._close(seq, "not_ready")
            if seq != 1:
                return self._close(seq, "bad_sequence")
            mine = ("ble:" + self.record["device"], "phone:" + self.record["phone"], self.record["eid"])
            if (msg["device"], msg["phone"], msg["eid"]) != mine:
                return self._close(seq, "record_mismatch")
            self.state, self.last = "ready", 1
            return {"send": {"v": 1, "t": "ready_ack", "re": 1, "device": msg["device"], "phone": msg["phone"],
                             "eid": msg["eid"], "cc": msg["cc"], "sc": self.sc}, "close": False}
        if t == "ready_req" or seq != self.last + 1:
            return self._close(seq, "bad_sequence")
        if msg["sc"] != self.sc:
            return self._close(seq, "bad_challenge")
        if self.revoked or self.record["state"] != "committed":
            return self._close(seq, "revoked")
        self.last = seq
        me = "phone:" + self.peer

        def reply(body):
            body = dict({"v": 1, "re": seq}, **body)
            return {"send": body, "close": False}

        def soft(code):
            return reply({"t": "err", "code": code})

        if t == "next":
            for slot in self.store:
                if slot["phase"] == "queued" or (slot["phase"] == "accepted" and slot.get("by") == me):
                    return reply({"t": "next_r", "task": slot["task"], "phase": slot["phase"]})
            return reply({"t": "next_r", "task": None, "phase": None})
        slot = self._slot(msg["id"])
        if slot is None:
            if t == "status":
                return reply({"t": "status_r", "phase": "unknown", "mine": False})
            return soft("unknown_task")
        if slot["task"]["idempotency_key"] != msg["idem"]:
            return soft("conflict")
        owner = slot.get("by") == me
        if t == "status":
            body = {"t": "status_r", "phase": slot["phase"], "mine": owner and slot["phase"] != "queued"}
            if slot["phase"] in ("completed", "failed") and owner:
                body["outcome"] = slot["outcome"]
            return reply(body)
        if t == "accept":
            if slot["phase"] == "queued":
                def apply():
                    slot["phase"], slot["by"] = "accepted", me
                if not self._write(apply):
                    return self._close(seq, "storage")
                return reply({"t": "r", "result": "applied", "phase": "accepted"})
            if not owner:
                return soft("wrong_owner")
            if slot["phase"] == "accepted":
                return reply({"t": "r", "result": "duplicate", "phase": "accepted"})
            return soft("invalid_transition")
        phase, outcome = outcome_of(msg)
        if slot["phase"] == "queued":
            return soft("invalid_transition")
        if not owner:
            return soft("wrong_owner")
        if slot["phase"] == "accepted":
            def apply():
                slot["phase"], slot["outcome"] = phase, outcome
            if not self._write(apply):
                return self._close(seq, "storage")
            return reply({"t": "r", "result": "applied", "phase": phase})
        if slot["phase"] == phase and slot["outcome"] == outcome:
            return reply({"t": "r", "result": "duplicate", "phase": phase})
        return soft("conflict")


class PhoneSession:
    """§8.2 phone readiness checks for a delivered ready_ack."""

    def __init__(self, given):
        self.expect = given

    def ack(self, msg):
        e = self.expect
        if msg["t"] != "ready_ack" or msg["re"] != 1:
            return "close"
        if (msg["device"], msg["phone"], msg["eid"], msg["cc"]) != (e["device"], e["phone"], e["eid"], e["cc"]):
            return "close"
        return "ready"


# ---------------------------------------------------------------------------
# §9 recovery and §10 intents, store
# ---------------------------------------------------------------------------

def recovery_decision(action, args, status):
    """§9.3: what a phone does with a persisted intent after a lost reply.

    applied      the device state proves this exact transition happened;
    resend       the device state proves it did not happen and the precondition
                 still holds: resend the identical persisted arguments;
    retry_query  no authoritative answer (no session, fatal session error):
                 keep the intent, query again in a later session;
    unresolved   definitive mismatch: keep the intent, never resend, user action.
    """
    if status.get("t") == "err":
        return "unresolved" if status["code"] == "conflict" else "retry_query"
    if status.get("t") != "status_r":
        return "retry_query"
    phase, mine = status["phase"], status["mine"]
    if action == "accept":
        if phase == "accepted" and mine:
            return "applied"
        if phase == "queued":
            return "resend"
        return "unresolved"
    expected_phase = "completed" if action == "complete" else "failed"
    expected = ({"output": args["output"], "truncated": args["truncated"]} if action == "complete"
                else {"failure": args["failure"]})
    if phase in ("completed", "failed") and mine:
        return "applied" if phase == expected_phase and status.get("outcome") == expected else "unresolved"
    if phase == "accepted" and mine:
        return "resend"
    return "unresolved"


INTENT_ARGS = {"accept": {"id", "idem"}, "complete": {"id", "idem", "output", "truncated"},
               "fail": {"id", "idem", "failure"}}


def intent_expected(device_id, phone_id, action, args):
    if set(args) != INTENT_ARGS[action]:
        raise Invalid("arguments do not match action")
    msg_id = sha(device_id.encode("utf-8") + b"\x00" + args["idem"].encode("utf-8"))
    return {"v": 1, "msg_id": msg_id, "device_id": device_id, "phone_id": phone_id, "task_id": args["id"],
            "action": action, "idem": args["idem"], "arguments_sha256": sha(canonical(args))}


def store_doc_valid(doc, version, store_schema, v1_schema):
    try:
        spec_golden.validate_json(doc, store_schema if version == 2 else v1_schema, "store")
    except spec_golden.SpecError:
        return False
    ids, keys = set(), set()
    for slot in doc["slots"]:
        terminal = slot["phase"] in ("completed", "failed")
        if terminal != ("outcome" in slot):
            return False
        if version == 2 and slot["phase"] == "queued" and "by" in slot:
            return False
        if terminal and ("output" in slot["outcome"]) != (slot["phase"] == "completed"):
            return False
        if slot["task"]["id"] in ids or slot["task"]["idempotency_key"] in keys:
            return False
        ids.add(slot["task"]["id"])
        keys.add(slot["task"]["idempotency_key"])
    return True


def store_selection(case, store_schema, v1_schema):
    v1, v2 = case["nvs"].get("tasks_v1"), case["nvs"].get("tasks_v2")
    if v2 is not None:
        if v2 == "unreadable" or not store_doc_valid(v2, 2, store_schema, v1_schema):
            return "disabled", None
        return "use_v2", v2["slots"]
    if v1 is not None:
        if v1 == "unreadable" or not store_doc_valid(v1, 1, store_schema, v1_schema):
            return "disabled", None
        return "migrate_v1", [{k: v for k, v in slot.items()} for slot in v1["slots"]]
    return "empty", []


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class FrozenFixtureTests(unittest.TestCase):
    def test_every_fixture_byte_pinned(self):
        for name, digest in FROZEN.items():
            self.assertEqual(sha((GOLDEN / name).read_bytes()), digest, name)

    def test_every_schema_parses_and_uses_supported_keywords(self):
        supported = {"$schema", "$id", "title", "description", "type", "const", "enum", "pattern",
                     "minLength", "maxLength", "minimum", "maximum", "required", "properties",
                     "additionalProperties", "items", "minItems", "maxItems", "uniqueItems", "oneOf",
                     "propertyNames", "dependentRequired"}

        def walk(node, where):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key not in supported and where[-1:] != ["properties"]:
                        self.fail("%s uses unsupported keyword %s" % ("/".join(where), key))
                    walk(value, where + [key])
            elif isinstance(node, list):
                for item in node:
                    walk(item, where)

        for path in sorted(SCHEMA.glob("ble-secure-*.schema.json")):
            walk(json.loads(path.read_text(encoding="utf-8")), [path.name])


class IdentifierTests(unittest.TestCase):
    def test_vectors(self):
        _, rows = read_rows("ble-secure-identifiers.jsonl")
        sch = schema("ble-secure-identifier-vector.schema.json")
        kinds = {}
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            kinds.setdefault(row["kind"], []).append(row["valid"])
            if row["kind"] == "public_key":
                try:
                    got = public_key_fingerprint(row["hex"])
                    self.assertTrue(row["valid"], row["name"])
                    self.assertEqual(got, row["fingerprint"], row["name"])
                    self.assertEqual("ble:" + got, row["device_id"], row["name"])
                    self.assertEqual("phone:" + got, row["phone_id"], row["name"])
                except Invalid as exc:
                    self.assertFalse(row["valid"], row["name"])
                    self.assertEqual(str(exc), row["reason"], row["name"])
            elif row["kind"] == "identifier":
                ok = bool(IDENT_RE[row["role"]].fullmatch(row["text"]))
                self.assertEqual(ok, row["valid"], row["name"])
            elif row["kind"] == "eid":
                self.assertEqual(is_hex(row["text"], 32), row["valid"], row["name"])
            elif row["kind"] == "board_token":
                try:
                    device, eid = parse_board_token(row["input"])
                    self.assertTrue(row["valid"], row["name"])
                    self.assertEqual({"device": device, "eid": eid}, row["normalized"], row["name"])
                except Invalid:
                    self.assertFalse(row["valid"], row["name"])
            else:
                self.assertEqual(bool(PHONE_TOKEN.fullmatch(row["input"])), row["valid"], row["name"])
        for kind, values in kinds.items():
            self.assertIn(True, values, kind)
            self.assertIn(False, values, kind)
        self.assertEqual(set(kinds), {"public_key", "identifier", "eid", "board_token", "phone_token"})


class ConsoleGrammarTests(unittest.TestCase):
    def test_lines(self):
        _, rows = read_rows("ble-secure-enrollment-lines.jsonl")
        sch = schema("ble-secure-enrollment-line.schema.json")
        seen = set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            parsed = parse_console(bytes.fromhex(row["bytes_hex"]), row["dir"])
            if row["addressed"] is False:
                self.assertIsNone(parsed, row["name"])
                continue
            self.assertIsNotNone(parsed, row["name"])
            if row["valid"]:
                self.assertEqual(parsed[0], "ok", row["name"])
                self.assertEqual({"verb": parsed[1], "fields": parsed[2]}, row["parsed"], row["name"])
                seen.add((row["dir"], parsed[1]))
            else:
                self.assertEqual(parsed, ("err", row["echo"]), row["name"])
        self.assertTrue({("host", v) for v in CMD_FIELDS} <= seen)
        self.assertTrue({("board", v) for v in RESP_FIELDS} <= seen)

    def test_mutated_line_is_rejected(self):
        line = b"pdsh-enroll phone eid=" + b"a" * 32 + b" phone=" + b"b" * 64 + b"\n"
        self.assertEqual(parse_console(line, "host")[0], "ok")
        for bad in (line.replace(b"phone=", b"Phone="), line.replace(b" phone=", b"  phone="),
                    line.replace(b"a" * 32, b"A" * 32), line.replace(b"\n", b"\t\n"),
                    line.replace(b"\n", b" \n"), line.replace(b"phone ", b"phone eid=" + b"a" * 32 + b" ", 1)):
            self.assertEqual(parse_console(bad, "host")[0], "err", bad)


class EnrollmentStateTests(unittest.TestCase):
    def test_board_and_phone_sequences(self):
        _, rows = read_rows("ble-secure-enrollment-states.jsonl")
        sch = schema("ble-secure-enrollment-state-vector.schema.json")
        record_schema = schema("ble-secure-enrollment-record.schema.json")
        names = set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            names.add(row["name"])
            if row["side"] == "board":
                board = Board(row["given"])
                for index, step in enumerate(row["steps"]):
                    where = "%s step %d" % (row["name"], index)
                    if "line" in step:
                        out = board.line(step["line"].encode("ascii") + b"\n")
                    else:
                        out = board.event(step["event"])
                    self.assertEqual(out, step["out"], where)
                    self.assertEqual(board.durable(), step["durable"], where)
                    if board.state in ("committed", "revoked"):
                        spec_golden.validate_json(
                            {"v": 1, "side": "board", "state": board.state, "device": "ble:" + board.device,
                             "phone": "phone:" + board.phone, "eid": board.eid, "rev": board.rev},
                            record_schema, where)
                    if "session_authority" in step:
                        authority = board.state == "committed" and not board.ram_revoked
                        self.assertEqual(authority, step["session_authority"], where)
            else:
                phone = Phone(row["given"])
                for index, step in enumerate(row["steps"]):
                    where = "%s step %d" % (row["name"], index)
                    self.assertEqual(phone.op(step), step["result"], where)
                    self.assertEqual(phone.snapshot(), step["after"], where)
                    rec = phone.record
                    if rec and rec["state"] != "corrupt":
                        spec_golden.validate_json(
                            {"v": 1, "side": "phone", "state": rec["state"], "device": "ble:" + rec["device"],
                             "phone": "phone:" + rec["phone"], "eid": rec["eid"], "rev": rec["rev"]},
                            record_schema, where)
        required = {"board-happy-commit", "board-replug-during-staging", "board-concurrent-begin",
                    "board-replayed-commit", "board-press-timeout", "board-commit-storage-failure",
                    "board-revoke-closes-session", "board-key-lost", "phone-happy-commit",
                    "phone-crash-while-staged", "phone-concurrent-enrollment", "phone-key-lost"}
        self.assertTrue(required <= names, required - names)


class CertificateTests(unittest.TestCase):
    def test_profile_vectors(self):
        _, rows = read_rows("ble-secure-certificates.jsonl")
        sch = schema("ble-secure-certificate-vector.schema.json")
        reasons = set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            chain = [bytes.fromhex(item) for item in row["chain_hex"]]
            if row["accept"]:
                self.assertEqual(len(chain), 1, row["name"])
                self.assertLessEqual(len(chain[0]), 1024, row["name"])
                point = bytes.fromhex(row["spki_point_hex"])
                self.assertEqual(public_key_fingerprint(row["spki_point_hex"]), row["pin"], row["name"])
                self.assertIn(point, chain[0], row["name"])
                self.assertNotIn("reason", row)
            else:
                reasons.add(row["reason"])
                if row["reason"] == "chain_length":
                    self.assertGreater(len(chain), 1, row["name"])
                if row["reason"] == "no_certificate":
                    self.assertEqual(chain, [], row["name"])
                if row["reason"] == "oversize":
                    self.assertGreater(len(chain[0]), 1024, row["name"])
                if row["reason"] == "pin_mismatch":
                    self.assertNotEqual(public_key_fingerprint(row["spki_point_hex"]), row["pin"], row["name"])
                    self.assertIn(bytes.fromhex(row["spki_point_hex"]), chain[0], row["name"])
        self.assertEqual(reasons, set(sch["properties"]["reason"]["enum"]))


class FrameTests(unittest.TestCase):
    def test_frames(self):
        _, rows = read_rows("ble-secure-frames.jsonl")
        sch = schema("ble-secure-frame-vector.schema.json")
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            out, err = decode_frames([bytes.fromhex(c) for c in row["chunks_hex"]], row["eof"])
            self.assertEqual([p.hex() for p in out], row["payloads_hex"], row["name"])
            self.assertEqual(err, row["error"], row["name"])
        self.assertEqual({row["error"] for row in rows}, {None, "limit", "truncated"})

    def test_split_invariance(self):
        payload = b'{"v":1,"t":"next","seq":2,"sc":"' + b"0" * 64 + b'"}'
        stream = len(payload).to_bytes(2, "little") + payload
        for cut in range(len(stream) + 1):
            out, err = decode_frames([stream[:cut], stream[cut:]], True)
            self.assertEqual((out, err), ([payload], None), cut)


class MessageTests(unittest.TestCase):
    def test_messages(self):
        _, rows = read_rows("ble-secure-messages.jsonl")
        vsch = schema("ble-secure-message-vector.schema.json")
        msch = schema("ble-secure-message.schema.json")
        types = set()
        for row in rows:
            spec_golden.validate_json(row, vsch, row["name"])
            payload = bytes.fromhex(row["payload_hex"])
            try:
                value = validate_message(payload, row["dir"], msch)
                self.assertTrue(row["valid"], row["name"])
                self.assertEqual(value["t"], row["t"], row["name"])
                types.add((row["dir"], value["t"]))
            except Invalid:
                self.assertFalse(row["valid"], row["name"])
        self.assertEqual(types, {("c2s", t) for t in C2S} | {("s2c", t) for t in S2C})

    def test_schema_rejects_unknown_member(self):
        msch = schema("ble-secure-message.schema.json")
        good = {"v": 1, "t": "next", "seq": 2, "sc": "0" * 64}
        spec_golden.validate_json(good, msch, "good")
        for bad in (dict(good, extra=1), dict(good, v=2), dict(good, seq=0), dict(good, seq=65536),
                    dict(good, sc="0" * 63), dict(good, t="nxt")):
            with self.assertRaises(spec_golden.SpecError):
                spec_golden.validate_json(bad, msch, "bad")


class SessionSequenceTests(unittest.TestCase):
    def test_sequences(self):
        _, rows = read_rows("ble-secure-session-sequences.jsonl")
        sch = schema("ble-secure-session-sequence.schema.json")
        msch = schema("ble-secure-message.schema.json")
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            if row["side"] == "phone":
                session = PhoneSession(row["given"])
                for step in row["steps"]:
                    spec_golden.validate_json(step["recv"], msch, row["name"])
                    self.assertEqual(session.ack(step["recv"]), step["expect"], row["name"])
                continue
            session = DeviceSession(row["given"])
            self.assertEqual(session.handshake(), row["handshake"], row["name"])
            for index, step in enumerate(row["steps"]):
                where = "%s step %d" % (row["name"], index)
                if "recv" in step:
                    spec_golden.validate_json(step["recv"], msch, where)
                    got = session.recv(step["recv"])
                else:
                    got = session.event(step["event"])
                self.assertEqual(got, step["expect"], where)
                if got["send"] is not None:
                    spec_golden.validate_json(got["send"], msch, where)
            self.assertEqual(session.store, row["final_store"], row["name"])


class RecoveryTests(unittest.TestCase):
    def test_decisions(self):
        _, rows = read_rows("ble-secure-recovery.jsonl")
        sch = schema("ble-secure-recovery-vector.schema.json")
        decisions = set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            got = recovery_decision(row["action"], row["args"], row["status"])
            self.assertEqual(got, row["decision"], row["name"])
            decisions.add(got)
        self.assertEqual(decisions, {"applied", "resend", "unresolved", "retry_query"})


class IntentTests(unittest.TestCase):
    def test_intents(self):
        _, rows = read_rows("ble-secure-task-intents.jsonl")
        sch = schema("ble-secure-task-intent.schema.json")
        for row in rows:
            record = row["record"]
            try:
                spec_golden.validate_json(record, sch, row["name"])
                expected = intent_expected(record["device_id"], record["phone_id"], record["action"], row["args"])
                ok = expected == record
            except (spec_golden.SpecError, Invalid):
                ok = False
            self.assertEqual(ok, row["valid"], row["name"])


class StoreTests(unittest.TestCase):
    def test_store_selection(self):
        _, rows = read_rows("ble-secure-task-store-cases.jsonl")
        sch = schema("ble-secure-task-store.schema.json")
        v1 = schema("ble-task-store.schema.json")
        vsch = schema("ble-secure-task-store-case.schema.json")
        results = set()
        for row in rows:
            spec_golden.validate_json(row, vsch, row["name"])
            result, view = store_selection(row, sch, v1)
            self.assertEqual(result, row["result"], row["name"])
            self.assertEqual(view, row["view"], row["name"])
            results.add(result)
        self.assertEqual(results, {"use_v2", "migrate_v1", "empty", "disabled"})


if __name__ == "__main__":
    unittest.main()
