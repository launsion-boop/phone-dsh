#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared-fixture checker for spec/device/v1/ble-secure-session.md (secure-session-v2).

This file is a spec checker, not runtime conformance. It (1) pins the exact bytes
of every reviewed golden file, (2) validates every vector against the JSON
Schemas in spec/device/v1/schema, and (3) replays every vector through a small
reference oracle written from the normative text, so a semantically wrong edit
that is re-hashed still fails. Certificate vectors are decided by an
independent DER parser and P-256 ECDSA verifier in this file (no third-party
dependency), never by their labels. The Swift and firmware implementations must
run the same files through their real parsers, state machines and stores.
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

# Reviewed fixture revision secure-session-v2. Changing a vector requires a new
# contract revision recorded in the change record, then updating these digests.
FROZEN = {
    "ble-secure-identifiers.jsonl": "9bbcd7aa0e84fbff657464272c5c516401a792b8398530e1089436bf70b91b9d",
    "ble-secure-enrollment-lines.jsonl": "4ba13dee9fec9bdf3de3c2a181f7cf35ee6ba57e876631c207defb1c8a1e6ed5",
    "ble-secure-enrollment-states.jsonl": "71100261257210fa9a96f965b5fa8614e12e587c30b97ecd9be8fcc6fe4b972d",
    "ble-secure-certificates.jsonl": "2bc94ec93590b0ca946bdd66a9fab1bfa3baf38cd5eda698658cd18933984ae8",
    "ble-secure-frames.jsonl": "3818e1d0ae08b070143893faa214520321076d9110a7df409c6ee2f3dcfc1f8b",
    "ble-secure-messages.jsonl": "7dbe12b8bead89a8da433315138060c20743dc782d57add72f3d351ce17c7250",
    "ble-secure-session-sequences.jsonl": "a2e0342318733a9ca1054d68203b0874580d1dc59b7f37a0b665649a63291d7f",
    "ble-secure-recovery.jsonl": "f1b16c785bfb06ba58f628e602ca7f02eeb88c36943efcd1d5a70364b925a22e",
    "ble-secure-task-intents.jsonl": "45c6e058b5110e414f61ec956bdf32e207246b8732881c97da04e0199f91964b",
    "ble-secure-task-store-cases.jsonl": "771e4d4fc448da0a4192025185b991be6794bee5786187f3d10f43998c7e0d7d",
    "ble-secure-coc-cases.jsonl": "3a1261f5521d262fe88b61e0e16563b0d2f48c75dbd0b4c933186a2b013548df",
    "ble-secure-conformance-matrix.jsonl": "1357245f80d1af191c9e8588528fe3e077d71a9c59d19cc66ea639e2ffb73a7e",
}

HEX = frozenset("0123456789abcdef")
P256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
P256_A = P256_P - 3
P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
P256_G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
          0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)
MAX_FRAME = 4096
CONSOLE_MAX = 384

# §3.3 / §8.1 timers (seconds). Fixture `elapse` events are interpreted with these.
ARM_HOLD_S = 5
CONFIRM_HOLD_S = 3
ARM_WINDOW_S = 300
PRESS_TIMEOUT_S = 30
READY_WAIT_S = 10
RESPONSE_WAIT_S = 10
BOARD_IDLE_S = 90
SESSION_LIFETIME_S = 600
GRANT_ACCEPT_WINDOW_S = 1800
GRANT_REPORT_EXTENSION_S = 600
MAX_FAILED_SESSION_ATTEMPTS = 3


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


def compact(value) -> bytes:
    """Fixture NVS text: compact JSON in the member order written in the fixture line."""
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


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
    "status": ["state", "mode", "ctx", "device", "phone", "eid", "rev"],
    "armed": ["window_s"],
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
MODES = ("locked", "armed")
CTXS = ("idle", "begun", "staged", "press")
ACTIONS = ("commit", "revoke", "identity-reset")
ARMED_VERBS = ("begin", "revoke", "identity-reset")
CONSOLE_CODES = ("syntax", "busy", "occupied", "no_session", "state", "eid_mismatch", "value_mismatch",
                 "same_key", "timeout", "storage", "controls_unavailable", "not_armed", "gesture",
                 "key_lost", "key_unavailable", "record_corrupt")
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
    if name == "mode":
        return value in MODES
    if name == "ctx":
        return value in CTXS
    if name == "action":
        return value in ACTIONS
    if name == "timeout_s":
        return value == str(PRESS_TIMEOUT_S)
    if name == "window_s":
        return value == str(ARM_WINDOW_S)
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
# §3.3 board enrollment oracle (enrollment mode, gestures, indicator)
# ---------------------------------------------------------------------------

GESTURES = ("arm_hold", "short_press", "confirm_hold", "held_across_press_line")


class Board:
    def __init__(self, given):
        self.state = given["state"]
        self.device = given.get("device")
        self.phone = given.get("phone")
        self.eid = given.get("eid")
        self.rev = given.get("rev", 0)
        self.button = given.get("button", True)
        self.indicator = given.get("indicator", True)
        self.eids = list(given.get("eids", []))
        self.new_keys = list(given.get("new_keys", []))
        self.mode = "locked"
        self.ctx = {"kind": "idle"}
        self.fail_next_write = False
        self.ram_revoked = False

    def durable(self):
        return {"state": self.state, "device": self.device, "phone": self.phone, "eid": self.eid, "rev": self.rev}

    def volatile(self):
        if self.mode == "locked":
            light = "off"
        elif self.ctx["kind"] == "press":
            light = "confirm"
        else:
            light = "armed"
        return {"mode": self.mode, "ctx": self.ctx["kind"], "indicator": light}

    def _disarm(self):
        self.ctx = {"kind": "idle"}
        self.mode = "locked"

    def _fail(self, code, cmd):
        """§3.3: every error response aborts the context and leaves enrollment mode."""
        self._disarm()
        return console_line("error", code=code, cmd=cmd)

    def _status(self):
        shows_record = self.state in ("committed", "revoked")
        return console_line("status", state=self.state, mode=self.mode, ctx=self.ctx["kind"],
                            device=self.device if self.state not in ("key_lost", "key_unavailable") else "-",
                            phone=self.phone if shows_record else "-",
                            eid=self.eid if shows_record else "-", rev=str(self.rev))

    def controls(self):
        return self.button and self.indicator

    def line(self, raw: bytes):
        parsed = parse_console(raw, "host")
        if parsed is None:
            return None
        if self.ctx["kind"] == "press":
            return self._fail("busy", parsed[1])
        if parsed[0] == "err":
            return self._fail("syntax", parsed[1])
        _, verb, f = parsed
        if verb == "status":
            return self._status()
        if self.state in ("key_lost", "key_unavailable", "record_corrupt") and verb != "identity-reset":
            return self._fail(self.state, verb)
        if verb in ARMED_VERBS:
            if not self.controls():
                return self._fail("controls_unavailable", verb)
            if self.mode != "armed":
                return self._fail("not_armed", verb)
        if verb == "begin":
            if self.ctx["kind"] != "idle":
                return self._fail("busy", verb)
            if self.state == "committed":
                return self._fail("occupied", verb)
            eid = self.eids.pop(0)
            self.ctx = {"kind": "begun", "eid": eid}
            return console_line("begun", eid=eid, device=self.device)
        if verb == "phone":
            if self.ctx["kind"] == "idle":
                return self._fail("no_session", verb)
            if self.ctx["kind"] != "begun":
                return self._fail("state", verb)
            if f["eid"] != self.ctx["eid"]:
                return self._fail("eid_mismatch", verb)
            if f["phone"] == self.device:
                return self._fail("same_key", verb)
            self.ctx = {"kind": "staged", "eid": f["eid"], "phone": f["phone"]}
            return console_line("staged", eid=f["eid"], device=self.device, phone=f["phone"],
                                token="pdsh-board-v1:%s:%s" % (self.device, f["eid"]))
        if verb == "commit":
            if self.ctx["kind"] == "idle":
                return self._fail("no_session", verb)
            if self.ctx["kind"] != "staged":
                return self._fail("state", verb)
            if f["eid"] != self.ctx["eid"]:
                return self._fail("eid_mismatch", verb)
            if f["device"] != self.device or f["phone"] != self.ctx["phone"]:
                return self._fail("value_mismatch", verb)
            self.ctx = {"kind": "press", "action": "commit", "eid": f["eid"], "phone": f["phone"]}
            return console_line("press", eid=f["eid"], action="commit", timeout_s=str(PRESS_TIMEOUT_S))
        if verb == "abort":
            if self.ctx["kind"] == "idle":
                return self._fail("no_session", verb)
            if f["eid"] != self.ctx["eid"]:
                return self._fail("eid_mismatch", verb)
            self._disarm()
            return console_line("aborted", eid=f["eid"])
        if verb == "revoke":
            if self.ctx["kind"] != "idle":
                return self._fail("busy", verb)
            if self.state != "committed":
                return self._fail("state", verb)
            if (f["eid"], f["device"], f["phone"]) != (self.eid, self.device, self.phone):
                return self._fail("value_mismatch", verb)
            self.ctx = {"kind": "press", "action": "revoke", "eid": self.eid}
            return console_line("press", eid=self.eid, action="revoke", timeout_s=str(PRESS_TIMEOUT_S))
        if verb == "identity-reset":
            if self.ctx["kind"] != "idle":
                return self._fail("busy", verb)
            if self.state == "committed":
                return self._fail("occupied", verb)
            self.ctx = {"kind": "press", "action": "identity-reset", "eid": "-"}
            return console_line("press", eid="-", action="identity-reset", timeout_s=str(PRESS_TIMEOUT_S))
        raise AssertionError(verb)

    def _confirm(self):
        ctx = self.ctx
        failing, self.fail_next_write = self.fail_next_write, False
        action = ctx["action"]
        if action == "commit":
            if failing:
                return self._fail("storage", "commit")
            self.state, self.eid, self.phone, self.rev = "committed", ctx["eid"], ctx["phone"], self.rev + 1
            self.ram_revoked = False
            self._disarm()
            return console_line("committed", eid=self.eid, device=self.device, phone=self.phone, rev=str(self.rev))
        if action == "revoke":
            self.ram_revoked = True
            if failing:
                return self._fail("storage", "revoke")
            self.state, self.rev = "revoked", self.rev + 1
            self._disarm()
            return console_line("revoked", eid=self.eid, device=self.device, phone=self.phone, rev=str(self.rev))
        if failing:
            return self._fail("storage", "identity-reset")
        self.device = self.new_keys.pop(0)
        self.state, self.phone, self.eid, self.rev = "none", None, None, 0
        self._disarm()
        return console_line("reset", device=self.device)

    def gesture(self, name):
        """Return (out, legacy_button). legacy_button: the press edge kept its ordinary meaning."""
        if not self.button:
            raise AssertionError("no button configured: no gesture can occur")
        if name == "held_across_press_line":
            return None, False
        if self.mode == "locked":
            if name == "arm_hold" and self.controls():
                self.mode = "armed"
                return console_line("armed", window_s=str(ARM_WINDOW_S)), True
            return None, True
        if self.ctx["kind"] != "press":
            return None, False
        if name == "short_press":
            return self._fail("gesture", self.ctx["action"]), False
        return self._confirm(), False

    def event(self, name):
        if name == "press_timeout":
            if self.ctx["kind"] != "press":
                return None
            return self._fail("timeout", self.ctx["action"])
        if name == "window_expired":
            if self.mode != "armed":
                return None
            return self._fail("timeout", "-")
        if name == "reboot":
            self._disarm()
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
# §6.2 certificate decision: independent DER parser and P-256 ECDSA verifier
# ---------------------------------------------------------------------------

OID_EC_PUBLIC_KEY = "1.2.840.10045.2.1"
OID_PRIME256V1 = "1.2.840.10045.3.1.7"
OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2"
OID_BASIC_CONSTRAINTS = "2.5.29.19"
OID_KEY_USAGE = "2.5.29.15"
OID_EXT_KEY_USAGE = "2.5.29.37"
CERT_REASONS = ("no_certificate", "chain_length", "oversize", "malformed", "curve", "pin_mismatch",
                "signature_algorithm", "bad_self_signature", "ca_true", "key_usage", "eku_present",
                "unknown_critical_extension")


class Malformed(Exception):
    pass


def der_read(data, pos=0):
    """Return (tag, content, full_tlv, next_pos) for one definite-length DER TLV."""
    if pos + 2 > len(data):
        raise Malformed("short")
    tag = data[pos]
    if tag & 0x1F == 0x1F:
        raise Malformed("high tag")
    first = data[pos + 1]
    head = 2
    if first < 0x80:
        length = first
    elif first == 0x80 or first > 0x84:
        raise Malformed("length form")
    else:
        count = first & 0x7F
        if pos + 2 + count > len(data):
            raise Malformed("short length")
        raw = data[pos + 2:pos + 2 + count]
        if raw[0] == 0 or (count == 1 and raw[0] < 0x80):
            raise Malformed("non-minimal length")
        length = int.from_bytes(raw, "big")
        head += count
    end = pos + head + length
    if end > len(data):
        raise Malformed("overrun")
    return tag, data[pos + head:end], data[pos:end], end


def der_children(content):
    items, pos = [], 0
    while pos < len(content):
        tag, body, full, pos = der_read(content, pos)
        items.append((tag, body, full))
    return items


def der_oid(body):
    if not body:
        raise Malformed("empty oid")
    first = body[0]
    parts = [str(min(first // 40, 2)), str(first - 40 * min(first // 40, 2))]
    value = 0
    for byte in body[1:]:
        value = (value << 7) | (byte & 0x7F)
        if not byte & 0x80:
            parts.append(str(value))
            value = 0
    if body[-1] & 0x80:
        raise Malformed("oid")
    return ".".join(parts)


def der_int(body):
    if not body or (len(body) > 1 and ((body[0] == 0 and body[1] < 0x80) or (body[0] == 0xFF and body[1] >= 0x80))):
        raise Malformed("integer")
    return int.from_bytes(body, "big", signed=True)


def _expect(item, tag):
    if item[0] != tag:
        raise Malformed("tag %02x != %02x" % (item[0], tag))
    return item


def _ec_add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0] and (p[1] + q[1]) % P256_P == 0:
        return None
    if p == q:
        lam = (3 * p[0] * p[0] + P256_A) * pow(2 * p[1], -1, P256_P) % P256_P
    else:
        lam = (q[1] - p[1]) * pow(q[0] - p[0], -1, P256_P) % P256_P
    x = (lam * lam - p[0] - q[0]) % P256_P
    return x, (lam * (p[0] - x) - p[1]) % P256_P


def _ec_mul(k, p):
    out = None
    while k:
        if k & 1:
            out = _ec_add(out, p)
        p = _ec_add(p, p)
        k >>= 1
    return out


def ecdsa_p256_verify(point_hex, message, signature_der):
    raw = bytes.fromhex(point_hex)
    q = (int.from_bytes(raw[1:33], "big"), int.from_bytes(raw[33:], "big"))
    tag, body, _, end = der_read(signature_der)
    if tag != 0x30 or end != len(signature_der):
        return False
    parts = der_children(body)
    if len(parts) != 2 or parts[0][0] != 0x02 or parts[1][0] != 0x02:
        return False
    r, s = der_int(parts[0][1]), der_int(parts[1][1])
    if not (1 <= r < P256_N and 1 <= s < P256_N):
        return False
    e = int.from_bytes(hashlib.sha256(message).digest(), "big")
    w = pow(s, -1, P256_N)
    point = _ec_add(_ec_mul(e * w % P256_N, P256_G), _ec_mul(r * w % P256_N, q))
    return point is not None and point[0] % P256_N == r


def parse_certificate(der):
    """Parse the §6.2 fields of an X.509 v3 certificate or raise Malformed."""
    tag, body, _, end = der_read(der)
    if tag != 0x30 or end != len(der):
        raise Malformed("certificate")
    top = der_children(body)
    if len(top) != 3:
        raise Malformed("certificate members")
    tbs, outer_alg, sig = _expect(top[0], 0x30), _expect(top[1], 0x30), _expect(top[2], 0x03)
    fields = der_children(tbs[1])
    if not fields or fields[0][0] != 0xA0:
        raise Malformed("not v3: version absent")
    version = der_children(fields[0][1])
    if len(version) != 1 or version[0][0] != 0x02 or der_int(version[0][1]) != 2:
        raise Malformed("not v3")
    if len(fields) < 7:
        raise Malformed("tbs members")
    _expect(fields[1], 0x02)
    inner_alg = _expect(fields[2], 0x30)
    for index in (3, 4, 5):
        _expect(fields[index], 0x30)
    spki = der_children(_expect(fields[6], 0x30)[1])
    if len(spki) != 2:
        raise Malformed("spki")
    alg = der_children(_expect(spki[0], 0x30)[1])
    key_bits = _expect(spki[1], 0x03)[1]
    if not alg or alg[0][0] != 0x06 or not key_bits or key_bits[0] != 0:
        raise Malformed("spki members")
    curve_ok = (der_oid(alg[0][1]) == OID_EC_PUBLIC_KEY and len(alg) == 2 and alg[1][0] == 0x06
                and der_oid(alg[1][1]) == OID_PRIME256V1)
    extensions = []
    rest = fields[7:]
    for item in rest:
        if item[0] not in (0x81, 0x82, 0xA3):
            raise Malformed("unexpected tbs member")
    ext_items = [item for item in rest if item[0] == 0xA3]
    if len(ext_items) > 1:
        raise Malformed("two extension blocks")
    if ext_items:
        wrapper = der_children(ext_items[0][1])
        if len(wrapper) != 1:
            raise Malformed("extensions wrapper")
        seen = set()
        for ext in der_children(_expect(wrapper[0], 0x30)[1]):
            parts = der_children(_expect(ext, 0x30)[1])
            if len(parts) not in (2, 3) or parts[0][0] != 0x06:
                raise Malformed("extension")
            oid = der_oid(parts[0][1])
            critical = False
            if len(parts) == 3:
                if _expect(parts[1], 0x01)[1] not in (b"\xff",):
                    raise Malformed("critical DEFAULT FALSE encoded")
                critical = True
            value = _expect(parts[-1], 0x04)[1]
            if oid in seen:
                raise Malformed("duplicate extension")
            seen.add(oid)
            extensions.append((oid, critical, value))
    outer = der_children(outer_alg[1])
    if not outer or outer[0][0] != 0x06:
        raise Malformed("signature algorithm")
    if not sig[1] or sig[1][0] != 0:
        raise Malformed("signature bits")
    return {"tbs": tbs[2], "inner_alg": inner_alg[2], "outer_alg": outer_alg[2],
            "outer_oid": der_oid(outer[0][1]), "outer_params": len(outer) > 1,
            "curve_ok": curve_ok, "point": key_bits[1:], "extensions": extensions, "signature": sig[1][1:]}


def certificate_decision(chain, pin):
    """§6.2: None if accepted, else the first failing reason in rule order."""
    if not chain:
        return "no_certificate"
    if len(chain) != 1:
        return "chain_length"
    der = chain[0]
    if len(der) > 1024:
        return "oversize"
    try:
        cert = parse_certificate(der)
    except (Malformed, ValueError, IndexError):
        return "malformed"
    if not cert["curve_ok"]:
        return "curve"
    try:
        fingerprint = public_key_fingerprint(cert["point"].hex())
    except Invalid:
        return "curve"
    if fingerprint != pin:
        return "pin_mismatch"
    if cert["outer_oid"] != OID_ECDSA_SHA256 or cert["outer_params"] or cert["inner_alg"] != cert["outer_alg"]:
        return "signature_algorithm"
    try:
        if not ecdsa_p256_verify(cert["point"].hex(), cert["tbs"], cert["signature"]):
            return "bad_self_signature"
    except (Malformed, ValueError):
        return "bad_self_signature"
    ext = {oid: (critical, value) for oid, critical, value in cert["extensions"]}
    if OID_BASIC_CONSTRAINTS in ext:
        try:
            tag, body, _, end = der_read(ext[OID_BASIC_CONSTRAINTS][1])
            members = der_children(body)
        except Malformed:
            return "malformed"
        if members and members[0][0] == 0x01 and members[0][1] != b"\x00":
            return "ca_true"
    if OID_KEY_USAGE not in ext:
        return "key_usage"
    try:
        tag, body, _, _ = der_read(ext[OID_KEY_USAGE][1])
    except Malformed:
        return "malformed"
    if tag != 0x03 or len(body) < 2 or not body[1] & 0x80:
        return "key_usage"
    if OID_EXT_KEY_USAGE in ext:
        return "eku_present"
    known = {OID_BASIC_CONSTRAINTS, OID_KEY_USAGE, OID_EXT_KEY_USAGE}
    if any(critical and oid not in known for oid, (critical, _) in ext.items()):
        return "unknown_critical_extension"
    return None


# ---------------------------------------------------------------------------
# §8.3 device session oracle
# ---------------------------------------------------------------------------

def outcome_of(msg):
    if msg["t"] == "complete":
        return "completed", {"output": msg["output"], "truncated": msg["truncated"]}
    return "failed", {"failure": msg["failure"]}


class DeviceSession:
    def __init__(self, given):
        self.record = dict(given["record"])        # current durable record (may be replaced)
        self.captured = dict(given["record"])      # captured at handshake completion (§8.3.1)
        self.peer = given["peer_phone"]
        self.sc = given["sc"]
        self.store = copy.deepcopy(given["store"])
        self.fail_next_write = False
        self.closed = False
        self.state = "verified"
        self.last = 0
        self.revoked = False
        self.now = 0
        self.last_request_at = 0

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

    def event(self, step):
        name = step["event"]
        if name == "fail_next_write":
            self.fail_next_write = True
            return {"send": None, "close": False}
        if name == "record_replaced":
            self.record = dict(step["record"])
            return {"send": None, "close": False}
        if self.closed:
            return {"send": None, "close": False}
        if name == "revoke":
            self.revoked = True
            return self._close(0, "revoked")
        if name == "elapse":
            self.now += step["seconds"]
            if self.now >= SESSION_LIFETIME_S:
                self.closed = True
                return {"send": None, "close": True}
            if self.state == "verified" and self.now >= READY_WAIT_S:
                return self._close(0, "timeout")
            if self.state == "ready" and self.now - self.last_request_at >= BOARD_IDLE_S:
                return self._close(0, "timeout")
            return {"send": None, "close": False}
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
            mine = ("ble:" + self.captured["device"], "phone:" + self.captured["phone"], self.captured["eid"])
            if (msg["device"], msg["phone"], msg["eid"]) != mine:
                return self._close(seq, "record_mismatch")
            self.state, self.last, self.last_request_at = "ready", 1, self.now
            return {"send": {"v": 1, "t": "ready_ack", "re": 1, "device": msg["device"], "phone": msg["phone"],
                             "eid": msg["eid"], "cc": msg["cc"], "sc": self.sc}, "close": False}
        if t == "ready_req" or seq != self.last + 1:
            return self._close(seq, "bad_sequence")
        if msg["sc"] != self.sc:
            return self._close(seq, "bad_challenge")
        if self.revoked or self.record != self.captured:
            return self._close(seq, "revoked")
        self.last, self.last_request_at = seq, self.now
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


# ---------------------------------------------------------------------------
# §8.2 phone session oracle (selection, readiness, correlation, grant, resend)
# ---------------------------------------------------------------------------

REQUEST_LEVEL = ("unknown_task", "invalid_transition", "conflict", "wrong_owner")
FATAL = ("malformed", "limit", "bad_sequence", "bad_challenge", "not_ready", "record_mismatch",
         "revoked", "storage", "timeout", "internal")
EXPECTED_R_PHASE = {"accept": "accepted", "complete": "completed", "fail": "failed"}
_TASK_SCHEMA = None


def task_valid(task):
    """Shape part of the task-delegation task rules (the phone runs its full validator)."""
    global _TASK_SCHEMA
    if _TASK_SCHEMA is None:
        _TASK_SCHEMA = schema("task.schema.json")
    try:
        spec_golden.validate_json(task, _TASK_SCHEMA, "task")
    except spec_golden.SpecError:
        return False
    return True


class PhoneSession:
    def __init__(self, given):
        self.phone = given["phone"]
        self.records = {r["device"]: dict(r) for r in given["records"]}
        self.selected = given["selected"]
        self.ccs = list(given["ccs"])
        self.parents = list(given.get("parents", []))
        self.state = "closed"
        self.grant = "none"
        self.grant_at = None
        self.now = 0
        self.ever_ready = False
        self.failed_attempts = 0
        self._reset_session()

    def _reset_session(self):
        self.last = 0
        self.sc = None
        self.cc = None
        self.outstanding = None
        self.sent_at = 0
        self.session_start = self.now
        self.next_suspended = False
        self.resend_armed = None

    def _out(self, result, send=None, close=False):
        return {"result": result, "send": send, "close": close, "state": self.state, "grant": self.grant}

    def _close(self, result, send=None, failed_attempt=False):
        self.state = "closed"
        if failed_attempt:
            self.failed_attempts += 1
            if self.failed_attempts >= MAX_FAILED_SESSION_ATTEMPTS:
                self.grant, self.grant_at = "none", None
        self._reset_session()
        return self._out(result, send, True)

    def _err(self, code):
        return {"v": 1, "t": "err", "re": 0, "code": code}

    def _end_generation(self, result):
        self.state = "closed"
        self.grant, self.grant_at = "none", None
        self.ever_ready = False
        self.failed_attempts = 0
        self._reset_session()
        return self._out(result, None, True)

    # -- events --------------------------------------------------------------
    def event(self, step):
        name = step["event"]
        if name == "handshake":
            rec = self.records.get(self.selected)
            if self.state != "closed" or rec is None or rec["state"] != "committed":
                return self._out("refused_not_eligible")
            self._reset_session()
            if step["server_key"] != self.selected:
                return self._close("pin_mismatch", failed_attempt=True)
            self.cc = self.ccs.pop(0)
            self.state, self.last = "ready_wait", 1
            self.outstanding = {"t": "ready_req", "seq": 1}
            self.sent_at = self.now
            msg = {"v": 1, "t": "ready_req", "seq": 1, "device": "ble:" + self.selected,
                   "phone": "phone:" + self.phone, "eid": rec["eid"], "cc": self.cc}
            return self._out("sent", msg)
        if name == "grant":
            if self.state != "ready" or not self.ever_ready:
                return self._out("refused_not_ready")
            self.grant, self.grant_at = "active", self.now
            return self._out("granted")
        if name in ("disconnect", "background", "forget", "record_changed", "key_lost"):
            return self._end_generation(name)
        if name == "set_last_seq":
            self.last = step["seq"]
            return self._out("ok")
        if name == "elapse":
            self.now += step["seconds"]
            if self.grant != "none":
                age = self.now - self.grant_at
                if age >= GRANT_ACCEPT_WINDOW_S + GRANT_REPORT_EXTENSION_S:
                    self.grant, self.grant_at = "none", None
                elif age >= GRANT_ACCEPT_WINDOW_S:
                    self.grant = "report_only"
            if self.state == "closed":
                return self._out("ok")
            if self.now - self.session_start >= SESSION_LIFETIME_S:
                return self._close("lifetime_expired")
            if self.outstanding and self.now - self.sent_at >= RESPONSE_WAIT_S:
                return self._close("response_timeout", self._err("timeout"),
                                   failed_attempt=self.state == "ready_wait")
            return self._out("ok")
        raise AssertionError(name)

    # -- requests ------------------------------------------------------------
    def request(self, req):
        op = req["op"]
        if self.state != "ready":
            return self._out("refused_not_ready")
        if self.outstanding:
            return self._out("refused_busy")
        if self.grant == "none":
            return self._out("refused_no_grant")
        if op in ("next", "accept") and self.grant != "active":
            return self._out("refused_window")
        if op == "next" and self.next_suspended:
            return self._out("refused_next_suspended")
        armed, self.resend_armed = self.resend_armed, None
        if req.get("resend") and armed != {k: v for k, v in req.items() if k != "resend"}:
            return self._out("refused_requery")
        if self.last >= 65535:
            return self._close("refused_seq_exhausted")
        self.last += 1
        msg = {"v": 1, "t": op, "seq": self.last, "sc": self.sc}
        msg.update({k: v for k, v in req.items() if k not in ("op", "resend", "intent")})
        self.outstanding = dict(req, seq=self.last)
        self.sent_at = self.now
        return self._out("sent", msg)

    # -- responses -----------------------------------------------------------
    def recv(self, msg):
        if self.state == "closed":
            return self._out("ignored")
        t = msg["t"]
        if self.state == "ready_wait":
            if t == "err":
                return self._close("fatal", failed_attempt=True)
            if t != "ready_ack" or msg["re"] != 1:
                return self._close("malformed", self._err("malformed"), failed_attempt=True)
            rec = self.records[self.selected]
            if (msg["device"], msg["phone"], msg["eid"]) != ("ble:" + self.selected, "phone:" + self.phone, rec["eid"]):
                return self._close("record_mismatch", self._err("record_mismatch"), failed_attempt=True)
            if msg["cc"] != self.cc:
                return self._close("bad_challenge", self._err("bad_challenge"), failed_attempt=True)
            self.state, self.sc, self.outstanding = "ready", msg["sc"], None
            self.ever_ready, self.failed_attempts = True, 0
            return self._out("ready")
        out = self.outstanding
        if t == "err" and msg["code"] in FATAL and (msg["re"] == 0 or (out and msg["re"] == out["seq"])):
            return self._close("fatal")
        if out is None or t == "ready_ack" or msg["re"] != out["seq"]:
            return self._close("malformed", self._err("malformed"))
        op = out["op"]
        self.outstanding = None
        if t == "err":
            if op in ("accept", "complete", "fail") and msg["code"] in REQUEST_LEVEL:
                return self._out("unresolved")
            if op == "status" and msg["code"] == "conflict":
                return self._out("unresolved")
            return self._close("malformed", self._err("malformed"))
        if op == "next":
            if t != "next_r":
                return self._close("malformed", self._err("malformed"))
            task = msg["task"]
            if task is None:
                return self._out("no_task")
            if not task_valid(task):
                return self._close("malformed", self._err("malformed"))
            for parent in self.parents:
                same_key = parent["idempotency_key"] == task["idempotency_key"]
                if (same_key and parent != task) or (parent["id"] == task["id"] and not same_key):
                    self.next_suspended = True
                    return self._out("local_conflict")
            return self._out("task_offered" if msg["phase"] == "queued" else "accepted_offer")
        if op in EXPECTED_R_PHASE:
            if t != "r" or msg["phase"] != EXPECTED_R_PHASE[op]:
                return self._close("malformed", self._err("malformed"))
            return self._out("applied")
        if t != "status_r":
            return self._close("malformed", self._err("malformed"))
        intent = out.get("intent")
        if intent is None:
            return self._out("status")
        decision = recovery_decision(intent["action"], intent["args"], msg, intent["phone_id"],
                                     "phone:" + self.phone)
        if decision == "resend":
            self.resend_armed = dict({"op": intent["action"]}, **intent["args"])
        return self._out("status_" + decision)


# ---------------------------------------------------------------------------
# §9 recovery and §10 intents, store
# ---------------------------------------------------------------------------

def recovery_decision(action, args, status, intent_phone_id, current_phone_id):
    """§9.3: what a phone does with a persisted intent after a lost reply.

    applied      the device state proves this exact transition happened;
    resend       the device state proves it did not happen and the precondition
                 still holds: resend the identical persisted arguments as the
                 very next request of the same session;
    retry_query  no authoritative answer (no session, fatal session error):
                 keep the intent, query again in a later session;
    unresolved   definitive mismatch: keep the intent, never resend, user action.
    """
    if intent_phone_id != current_phone_id:
        return "unresolved"
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
    """§10: returns (result, view, v1_sha256 the next v2 write must carry or None if no write)."""
    v1, v2 = case["nvs"].get("tasks_v1"), case["nvs"].get("tasks_v2")
    v1_digest = None if v1 is None or v1 == "unreadable" else sha(compact(v1))
    if v2 is not None:
        if v2 == "unreadable" or not store_doc_valid(v2, 2, store_schema, v1_schema):
            return "disabled", None, None
        if v1 is not None and (v1 == "unreadable" or v2["v1_sha256"] != v1_digest):
            return "disabled", None, None
        return "use_v2", v2["slots"], v2["v1_sha256"]
    if v1 is not None:
        if v1 == "unreadable" or not store_doc_valid(v1, 1, store_schema, v1_schema):
            return "disabled", None, None
        return "migrate_v1", [dict(slot) for slot in v1["slots"]], v1_digest
    return "empty", [], None


# ---------------------------------------------------------------------------
# §5 pre-authentication CoC credit oracle
# ---------------------------------------------------------------------------

class CocReceiver:
    def __init__(self, given):
        self.mtu, self.mps, self.buffers = given["mtu"], given["mps"], given["rx_kframes"]
        self.peer_credits = self.buffers
        self.held = 0
        self.closed = None
        self.partial = None          # [sdu_len, received, kframes]
        self.complete = []           # [(sdu_len, kframes)]

    def invariant(self):
        return self.closed is not None or self.peer_credits + self.held <= self.buffers

    def _close(self, reason):
        self.closed = reason
        self.held, self.partial, self.complete = 0, None, []
        return {"credits": 0, "close": reason, "delivered": []}

    def op(self, step):
        if self.closed:
            return {"credits": 0, "close": None, "delivered": []}
        if step["op"] == "kframe":
            info = step["payload_len"] + (2 if "sdu_len" in step else 0)
            if self.peer_credits == 0:
                return self._close("credit_overrun")
            self.peer_credits -= 1
            if info > self.mps:
                return self._close("kframe_oversize")
            if self.partial is None:
                if "sdu_len" not in step:
                    raise AssertionError("first K-frame must carry sdu_len")
                if step["sdu_len"] == 0:
                    return self._close("sdu_empty")
                if step["sdu_len"] > self.mtu:
                    return self._close("sdu_oversize")
                self.partial = [step["sdu_len"], 0, 0]
            elif "sdu_len" in step:
                raise AssertionError("continuation K-frame cannot carry sdu_len")
            self.partial[1] += step["payload_len"]
            self.partial[2] += 1
            self.held += 1
            if self.partial[1] > self.partial[0]:
                return self._close("sdu_overrun")
            if self.partial[1] == self.partial[0]:
                self.complete.append((self.partial[0], self.partial[2]))
                self.partial = None
            return {"credits": 0, "close": None, "delivered": []}
        if step["op"] == "consume":
            if not self.complete:
                return {"credits": 0, "close": None, "delivered": []}
            size, frames = self.complete.pop(0)
            self.held -= frames
            self.peer_credits += frames
            return {"credits": frames, "close": None, "delivered": [size]}
        raise AssertionError(step["op"])


# ---------------------------------------------------------------------------
# §13 conformance matrix: the cases each end must run outside fixed bytes
# ---------------------------------------------------------------------------

def _rows(area, ends, layers, items):
    return {name: {"area": area, "ends": ends, "layers": layers, "expect": expect, "alert": alert}
            for name, expect, alert in items}


BOTH, PHONE, BOARD = ["phone", "board"], ["phone"], ["board"]
REQUIRED_MATRIX = {}
REQUIRED_MATRIX.update(_rows("tls", BOTH, ["loopback"], [
    ("tls-version-1-2-only", "handshake_failed", "protocol_version"),
    ("tls-cipher-suite-other", "handshake_failed", None),
    ("tls-signature-scheme-other", "handshake_failed", None),
    ("tls-certificate-vectors", "certificate_vectors_match", "bad_certificate"),
    ("tls-negative-decision-aborts-handshake", "handshake_failed", "bad_certificate"),
    ("tls-key-update-received", "session_failed", None),
    ("tls-record-overflow", "session_failed", "record_overflow"),
    ("tls-record-sender-cap", "records_within_cap", None),
]))
REQUIRED_MATRIX.update(_rows("tls", BOARD, ["loopback"], [
    ("tls-group-other-no-hrr", "handshake_failed", "handshake_failure"),
    ("tls-key-share-missing", "handshake_failed", "handshake_failure"),
    ("tls-alpn-absent", "handshake_failed", "no_application_protocol"),
    ("tls-alpn-other", "handshake_failed", "no_application_protocol"),
    ("tls-client-certificate-empty", "handshake_failed", "certificate_required"),
    ("tls-psk-offered", "full_handshake_no_psk", None),
    ("tls-early-data-offered", "no_early_data_accepted", None),
    ("tls-no-ticket-sent", "no_ticket_sent", None),
    ("tls-no-half-rtt-data", "no_half_rtt_data", None),
    ("tls-client-flight-fits-input-buffer", "handshake_completes", None),
]))
REQUIRED_MATRIX.update(_rows("tls", PHONE, ["loopback"], [
    ("tls-alpn-not-selected", "handshake_failed", "no_application_protocol"),
    ("tls-server-group-other", "handshake_failed", None),
    ("tls-client-hello-profile", "client_hello_profile", None),
    ("tls-server-sends-ticket", "ticket_discarded", None),
    ("tls-half-rtt-data-before-ready", "session_failed", None),
]))
REQUIRED_MATRIX.update(_rows("coc", BOARD, ["host"], [
    ("coc-credit-vectors", "credit_vectors_match", None),
]))
REQUIRED_MATRIX.update(_rows("coc", BOARD, ["host", "device"], [
    ("coc-send-beyond-credits", "coc_closed_board_alive", None),
    ("coc-zero-length-sdu", "coc_closed_board_alive", None),
    ("coc-sdu-over-mtu", "coc_closed_board_alive", None),
    ("coc-kframe-over-mps", "coc_closed_board_alive", None),
    ("coc-garbage-instead-of-client-hello", "coc_closed_board_alive", None),
    ("coc-disconnect-during-queued-send", "no_duplicate_no_leak", None),
    ("coc-second-concurrent-coc", "second_coc_refused", None),
    ("coc-handshake-stall", "closed_after_timeout", None),
    ("coc-client-hello-flood-with-reconnect", "board_alive_bounded_memory", None),
]))
REQUIRED_MATRIX.update(_rows("coc", BOARD, ["device"], [
    ("coc-enrolled-phone-served-after-attacks", "enrolled_session_ok", None),
]))
REQUIRED_MATRIX.update(_rows("board", BOARD, ["host"], [
    ("board-identity-prove-retired", "prove_refused", None),
    ("board-deterministic-ecdsa", "signature_deterministic", None),
]))
REQUIRED_MATRIX.update(_rows("board", BOARD, ["device"], [
    ("board-entropy-before-secret-generation", "entropy_source_active", None),
]))
REQUIRED_MATRIX.update(_rows("physical", BOTH, ["device"], [
    ("physical-enroll-and-task-round-trip", "pass", None),
    ("physical-reconnect", "pass", None),
    ("physical-board-reboot-recovery", "pass", None),
    ("physical-phone-restart-recovery", "pass", None),
    ("physical-long-task-across-session-renewal", "pass", None),
    ("physical-unenrolled-phone", "rejected", None),
    ("physical-unenrolled-board", "rejected", None),
    ("physical-changed-device-key", "rejected", None),
    ("physical-revoked-board", "rejected", None),
    ("physical-forgotten-phone", "rejected", None),
    ("physical-mac-peer-without-device-key", "rejected", None),
    ("physical-two-enrolled-boards-swap", "rejected", None),
]))
REQUIRED_MATRIX.update(_rows("physical", BOARD, ["device"], [
    ("physical-short-press-never-arms", "pass", None),
    ("physical-short-press-aborts-confirmation", "pass", None),
    ("physical-indicator-visible-while-armed", "pass", None),
]))


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
        names, codes, gestures = set(), set(), set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            names.add(row["name"])
            if row["side"] == "board":
                board = Board(row["given"])
                for index, step in enumerate(row["steps"]):
                    where = "%s step %d" % (row["name"], index)
                    if "line" in step:
                        out = board.line(step["line"].encode("ascii") + b"\n")
                        self.assertNotIn("legacy_button", step, where)
                    elif step["event"] in GESTURES:
                        out, legacy = board.gesture(step["event"])
                        self.assertEqual(legacy, step["legacy_button"], where)
                        gestures.add((step["event"], board.mode if out is None else "-"))
                    else:
                        out = board.event(step["event"])
                        self.assertNotIn("legacy_button", step, where)
                    self.assertEqual(out, step["out"], where)
                    if out and " error " in out:
                        codes.add(parse_console(out.encode() + b"\n", "board")[2]["code"])
                        self.assertEqual(board.mode, "locked", where)
                    self.assertEqual(board.durable(), step["durable"], where)
                    self.assertEqual(board.volatile(), step["volatile"], where)
                    if board.mode == "locked":
                        self.assertEqual(board.ctx["kind"], "idle", where)
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
                    "board-revoke-closes-session", "board-key-lost", "board-console-locked-without-arming",
                    "board-short-press-never-authorizes", "board-hold-before-press-line",
                    "board-short-press-aborts-confirmation", "board-window-expires",
                    "board-no-indicator", "board-identity-reset-from-none", "board-identity-reset-from-revoked",
                    "board-identity-reset-storage-failure", "board-syntax-error-disarms",
                    "phone-happy-commit", "phone-crash-while-staged", "phone-concurrent-enrollment",
                    "phone-key-lost"}
        self.assertTrue(required <= names, required - names)
        self.assertTrue({"not_armed", "gesture", "controls_unavailable", "timeout", "storage", "busy",
                         "syntax"} <= codes, codes)
        self.assertTrue({("short_press", "locked"), ("held_across_press_line", "armed"),
                         ("arm_hold", "-"), ("confirm_hold", "-"), ("short_press", "-")} <= gestures, gestures)


class CertificateTests(unittest.TestCase):
    def test_profile_vectors(self):
        _, rows = read_rows("ble-secure-certificates.jsonl")
        sch = schema("ble-secure-certificate-vector.schema.json")
        reasons = set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            chain = [bytes.fromhex(item) for item in row["chain_hex"]]
            got = certificate_decision(chain, row["pin"])
            self.assertEqual(got is None, row["accept"], row["name"])
            self.assertEqual(got, row.get("reason"), row["name"])
            if chain and len(chain[0]) <= 1024:
                self.assertIn(bytes.fromhex(row["spki_point_hex"]), chain[0], row["name"])
            if got is not None:
                reasons.add(got)
        self.assertEqual(reasons, set(sch["properties"]["reason"]["enum"]))
        names = {row["name"] for row in rows}
        self.assertTrue({"not-before-far-future-ignored", "basic-constraints-absent", "x509-v1",
                         "compressed-spki-point", "off-curve-spki-point", "other-enrolled-device"} <= names)

    def test_decision_bites(self):
        _, rows = read_rows("ble-secure-certificates.jsonl")
        good = next(row for row in rows if row["name"] == "device-profile")
        der = bytearray(bytes.fromhex(good["chain_hex"][0]))
        self.assertIsNone(certificate_decision([bytes(der)], good["pin"]))
        der[-5] ^= 1
        self.assertEqual(certificate_decision([bytes(der)], good["pin"]), "bad_self_signature")
        self.assertEqual(certificate_decision([bytes.fromhex(good["chain_hex"][0])], "0" * 64), "pin_mismatch")


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
        phone_results, device_names, phone_names = set(), set(), set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            if row["side"] == "phone":
                phone_names.add(row["name"])
                session = PhoneSession(row["given"])
                for index, step in enumerate(row["steps"]):
                    where = "%s step %d" % (row["name"], index)
                    if "recv" in step:
                        spec_golden.validate_json(step["recv"], msch, where)
                        got = session.recv(step["recv"])
                    elif "request" in step:
                        got = session.request(step["request"])
                    else:
                        got = session.event(step)
                    self.assertEqual(got, step["expect"], where)
                    if got["send"] is not None:
                        spec_golden.validate_json(got["send"], msch, where)
                        validate_message(compact(got["send"]), "c2s", msch)
                    phone_results.add(got["result"])
                continue
            device_names.add(row["name"])
            session = DeviceSession(row["given"])
            self.assertEqual(session.handshake(), row["handshake"], row["name"])
            for index, step in enumerate(row["steps"]):
                where = "%s step %d" % (row["name"], index)
                if "recv" in step:
                    spec_golden.validate_json(step["recv"], msch, where)
                    got = session.recv(step["recv"])
                else:
                    got = session.event(step)
                self.assertEqual(got, step["expect"], where)
                if got["send"] is not None:
                    spec_golden.validate_json(got["send"], msch, where)
            self.assertEqual(session.store, row["final_store"], row["name"])
        self.assertTrue({"record-replaced-while-committed", "storage-failure-on-complete",
                         "storage-failure-on-fail", "lifetime-expires", "keepalive-status-keeps-session",
                         "idle-timeout"} <= device_names, device_names)
        self.assertTrue({"phone-two-boards-swap-rejected", "phone-response-wrong-re",
                         "phone-response-wrong-type", "phone-r-wrong-phase", "phone-first-send-request-error",
                         "phone-resend-not-next-request", "phone-seq-exhausted",
                         "phone-grant-survives-session-renewal", "phone-unsolicited-response"} <= phone_names,
                        phone_names)
        self.assertTrue({"ready", "pin_mismatch", "applied", "unresolved", "malformed", "fatal", "local_conflict",
                         "status_resend", "status_applied", "status_unresolved", "refused_requery",
                         "refused_no_grant", "refused_window", "refused_seq_exhausted", "response_timeout",
                         "lifetime_expired", "record_mismatch", "bad_challenge", "task_offered", "no_task",
                         "accepted_offer", "refused_next_suspended", "refused_busy"} <= phone_results,
                        phone_results)


class RecoveryTests(unittest.TestCase):
    def test_decisions(self):
        _, rows = read_rows("ble-secure-recovery.jsonl")
        sch = schema("ble-secure-recovery-vector.schema.json")
        decisions = set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            got = recovery_decision(row["action"], row["args"], row["status"], row["intent_phone_id"],
                                    row["current_phone_id"])
            self.assertEqual(got, row["decision"], row["name"])
            decisions.add(got)
        self.assertEqual(decisions, {"applied", "resend", "unresolved", "retry_query"})
        self.assertIn("phone-key-changed", {row["name"] for row in rows})


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
            result, view, digest = store_selection(row, sch, v1)
            self.assertEqual(result, row["result"], row["name"])
            self.assertEqual(view, row["view"], row["name"])
            self.assertEqual(digest, row["write_v1_sha256"], row["name"])
            results.add(result)
        self.assertEqual(results, {"use_v2", "migrate_v1", "empty", "disabled"})
        names = {row["name"] for row in rows}
        self.assertTrue({"v1-changed-after-migration", "v1-appeared-after-fresh-v2"} <= names)


class CocTests(unittest.TestCase):
    def test_credit_vectors(self):
        _, rows = read_rows("ble-secure-coc-cases.jsonl")
        sch = schema("ble-secure-coc-case.schema.json")
        reasons = set()
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            rx = CocReceiver(row["given"])
            self.assertEqual(rx.peer_credits, row["initial_credits"], row["name"])
            for index, step in enumerate(row["steps"]):
                got = rx.op(step["peer"])
                self.assertEqual(got, step["expect"], "%s step %d" % (row["name"], index))
                self.assertTrue(rx.invariant(), row["name"])
                if got["close"]:
                    reasons.add(got["close"])
        self.assertEqual(reasons, set(sch["properties"]["steps"]["items"]["properties"]["expect"]
                                       ["properties"]["close"]["enum"]) - {None})


class ConformanceMatrixTests(unittest.TestCase):
    def test_matrix(self):
        _, rows = read_rows("ble-secure-conformance-matrix.jsonl")
        sch = schema("ble-secure-conformance-case.schema.json")
        got = {}
        for row in rows:
            spec_golden.validate_json(row, sch, row["name"])
            self.assertNotIn(row["name"], got)
            got[row["name"]] = {k: row.get(k) for k in ("area", "ends", "layers", "expect", "alert")}
        self.assertEqual(got, REQUIRED_MATRIX)


if __name__ == "__main__":
    unittest.main()
