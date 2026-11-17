#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reference oracle for the phone task queue (P05, spec/v1/cloud-tasks.md).

Judges golden/cloud-tasks/cases.json: closed message shapes, the sealing AAD, the HPKE
vectors (RFC 9180 base mode, DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM), the
submit decision, the task state machine, pull clamping and the phone admission mapping.
The HPKE cases need the `cryptography` package; without it they are skipped, not passed.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import unittest
from pathlib import Path

try:  # pragma: no cover - availability differs per machine
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    HAVE_CRYPTO = True
except Exception:  # noqa: BLE001
    HAVE_CRYPTO = False

# The importing repository keeps the package flat; it points this at its copy of the cases.
CASES = Path(os.environ.get("PDSH_CLOUD_TASK_CASES")
             or Path(__file__).resolve().parents[1] / "golden" / "cloud-tasks" / "cases.json")

ID = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
DEVICE_ID = re.compile(r"^dev-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PUSH_TOKEN = re.compile(r"^[0-9a-f]{64,200}$")
B64URL = re.compile(r"^[A-Za-z0-9_-]+$")
MAX_INT = 9007199254740991
SUITE = "hpke-p256-sha256-aes128gcm"
INFO = b"pdsh-phone-task/v1"
MIN_TTL_MS, MAX_TTL_MS = 60000, 604800000
MAX_PENDING = 256
REJECT_REASONS = {"invalid", "conflict", "target_missing", "decrypt_failed", "key_unknown"}
FAIL_REASONS = {"target_missing", "not_authorized", "retry_exhausted", "run_failed", "expired",
                "cancelled"}
TERMINAL = {"completed", "failed", "unknown", "rejected", "expired", "cancelled"}


def b64url_decode(text):
    if not isinstance(text, str) or not B64URL.match(text):
        raise ValueError("not base64url")
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


# --------------------------------------------------------------------------- shapes

def _closed(obj, required, optional=()):
    if not isinstance(obj, dict):
        raise ValueError("not an object")
    keys = set(obj)
    if not set(required) <= keys or not keys <= set(required) | set(optional):
        raise ValueError("members")


def _id(value):
    if not isinstance(value, str) or not ID.match(value):
        raise ValueError("id")


def _int(value, low=0, high=MAX_INT):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError("integer")


def _target(value):
    _closed(value, ("kind", "id"))
    if value["kind"] not in ("dsh-session", "bot"):
        raise ValueError("target kind")
    _id(value["id"])


def _sealed(value):
    _closed(value, ("enc", "ct"))
    if len(b64url_decode(value["enc"])) != 65:
        raise ValueError("enc")
    if not 17 <= len(b64url_decode(value["ct"])) <= 16400:
        raise ValueError("ct")


def _key(value):
    _closed(value, ("key_id", "suite", "public_key"))
    _id(value["key_id"])
    if value["suite"] != SUITE:
        raise ValueError("suite")
    point = b64url_decode(value["public_key"])
    if len(point) != 65 or point[0] != 4:
        raise ValueError("public key")


def check_message(message):
    """Raise ValueError unless `message` is a valid request body of this contract."""
    if not isinstance(message, dict):
        raise ValueError("not an object")
    schema = message.get("schema")
    if schema == "phone-device/v1":
        _closed(message, ("schema", "platform", "app_version", "key", "push"))
        if message["platform"] not in ("ios", "android"):
            raise ValueError("platform")
        if not isinstance(message["app_version"], str) or not 1 <= len(message["app_version"]) <= 32:
            raise ValueError("app_version")
        _key(message["key"])
        push = message["push"]
        if push is not None:
            _closed(push, ("provider", "environment", "topic", "token"))
            if push["provider"] != "apns" or message["platform"] != "ios":
                raise ValueError("push provider")
            if push["environment"] not in ("development", "production"):
                raise ValueError("push environment")
            if not isinstance(push["topic"], str) or not re.match(r"^[A-Za-z0-9.-]{1,155}$", push["topic"]):
                raise ValueError("push topic")
            if not isinstance(push["token"], str) or not PUSH_TOKEN.match(push["token"]):
                raise ValueError("push token")
    elif schema == "phone-task-submit/v1":
        _closed(message, ("schema", "device_id", "request_id", "key_id", "target",
                          "expires_at_ms", "sealed"))
        if not isinstance(message["device_id"], str) or not DEVICE_ID.match(message["device_id"]):
            raise ValueError("device_id")
        _id(message["request_id"])
        _id(message["key_id"])
        _target(message["target"])
        _int(message["expires_at_ms"])
        _sealed(message["sealed"])
    elif schema == "phone-task-ack/v1":
        _closed(message, ("schema", "device_id", "acks"))
        if not isinstance(message["device_id"], str) or not DEVICE_ID.match(message["device_id"]):
            raise ValueError("device_id")
        acks = message["acks"]
        if not isinstance(acks, list) or not 1 <= len(acks) <= 16:
            raise ValueError("acks")
        for ack in acks:
            if not isinstance(ack, dict):
                raise ValueError("ack")
            state = ack.get("state")
            if state == "admitted":
                _closed(ack, ("task_id", "state", "admission_id"))
                if not isinstance(ack["admission_id"], str) or not HEX64.match(ack["admission_id"]):
                    raise ValueError("admission_id")
            elif state == "rejected":
                _closed(ack, ("task_id", "state", "reason"))
                if ack["reason"] not in REJECT_REASONS:
                    raise ValueError("reason")
            elif state == "failed":
                _closed(ack, ("task_id", "state", "reason"))
                if ack["reason"] not in FAIL_REASONS:
                    raise ValueError("reason")
            elif state in ("expired", "completed", "unknown"):
                _closed(ack, ("task_id", "state"))
            else:
                raise ValueError("ack state")
            _id(ack["task_id"])
    else:
        raise ValueError("unknown schema")


# --------------------------------------------------------------------------- sealing

def aad(device_id, key_id, request_id, target, expires_at_ms) -> bytes:
    return "\n".join(["pdsh-phone-task/v1", device_id, key_id, request_id, target["kind"],
                      target["id"], str(expires_at_ms)]).encode("utf-8")


def _extract(salt: bytes, ikm: bytes) -> bytes:
    return hmac.new(salt or b"\x00" * 32, ikm, hashlib.sha256).digest()


def _expand(prk: bytes, info: bytes, length: int) -> bytes:
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


KEM_SUITE = b"KEM" + (0x0010).to_bytes(2, "big")
HPKE_SUITE = b"HPKE" + (0x0010).to_bytes(2, "big") + (0x0001).to_bytes(2, "big") + (0x0001).to_bytes(2, "big")


def _labeled_extract(suite, salt, label, ikm):
    return _extract(salt, b"HPKE-v1" + suite + label + ikm)


def _labeled_expand(suite, prk, label, info, length):
    return _expand(prk, length.to_bytes(2, "big") + b"HPKE-v1" + suite + label + info, length)


def _key_and_nonce(dh: bytes, enc: bytes, recipient_public: bytes, info: bytes):
    eae_prk = _labeled_extract(KEM_SUITE, b"", b"eae_prk", dh)
    shared = _labeled_expand(KEM_SUITE, eae_prk, b"shared_secret", enc + recipient_public, 32)
    psk_id_hash = _labeled_extract(HPKE_SUITE, b"", b"psk_id_hash", b"")
    info_hash = _labeled_extract(HPKE_SUITE, b"", b"info_hash", info)
    context = b"\x00" + psk_id_hash + info_hash
    secret = _labeled_extract(HPKE_SUITE, shared, b"secret", b"")
    return (_labeled_expand(HPKE_SUITE, secret, b"key", context, 16),
            _labeled_expand(HPKE_SUITE, secret, b"base_nonce", context, 12))


def _private(scalar_hex: str):
    return ec.derive_private_key(int(scalar_hex, 16), ec.SECP256R1())


def _point(key) -> bytes:
    numbers = key.public_key().public_numbers() if hasattr(key, "public_key") else key.public_numbers()
    return b"\x04" + numbers.x.to_bytes(32, "big") + numbers.y.to_bytes(32, "big")


def _public(point: bytes):
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), point)


def seal(ephemeral_hex: str, recipient_public: bytes, plaintext: bytes, associated: bytes):
    ephemeral = _private(ephemeral_hex)
    enc = _point(ephemeral)
    dh = ephemeral.exchange(ec.ECDH(), _public(recipient_public))
    key, nonce = _key_and_nonce(dh, enc, recipient_public, INFO)
    return enc, AESGCM(key).encrypt(nonce, plaintext, associated)


def open_sealed(recipient_hex: str, enc: bytes, ciphertext: bytes, associated: bytes) -> bytes:
    recipient = _private(recipient_hex)
    dh = recipient.exchange(ec.ECDH(), _public(enc))
    key, nonce = _key_and_nonce(dh, enc, _point(recipient), INFO)
    return AESGCM(key).decrypt(nonce, ciphertext, associated)


# --------------------------------------------------------------------------- decisions

def decide_submit(case):
    request, now = case["request"], case["now"]
    try:
        check_message(request)
    except ValueError:
        return {"status": 400, "code": "invalid_request"}
    device = case["devices"].get(request["device_id"])
    if device is None:
        return {"status": 404, "code": "not_found"}
    for existing in case.get("existing", []):
        if (existing["device_id"], existing["request_id"]) == (request["device_id"], request["request_id"]):
            if existing["request"] == request:
                return {"status": 200, "duplicate": True, "task_id": existing["task_id"]}
            return {"status": 409, "code": "request_conflict"}
    ttl = request["expires_at_ms"] - now
    if ttl < MIN_TTL_MS or ttl > MAX_TTL_MS:
        return {"status": 400, "code": "invalid_expiry"}
    if device["key_id"] != request["key_id"]:
        return {"status": 409, "code": "key_mismatch"}
    if case.get("pending", 0) >= MAX_PENDING:
        return {"status": 429, "code": "queue_full"}
    return {"status": 201, "duplicate": False}


def apply_ack(state, admission_id, ack):
    """Return (accepted, duplicate, state_after) for one ack against one task."""
    want = ack["state"]
    if state == "pending":
        if want in ("admitted", "rejected", "expired"):
            return True, False, want
        return False, False, state
    if state == "admitted":
        if want == "admitted":
            return (True, True, state) if ack["admission_id"] == admission_id else (False, False, state)
        if want in ("completed", "failed", "unknown"):
            return True, False, want
        return False, False, state
    if want == state:
        return True, True, state
    return False, False, state


def clamp_pull(query):
    def pick(name, low, high, default):
        value = query.get(name, default)
        return max(low, min(high, value))
    return {"limit": pick("limit", 1, 16, 16), "lease_s": pick("lease_s", 5, 900, 300),
            "wait_s": pick("wait_s", 0, 60, 0)}


def phone_ack(case):
    """What the phone sends for one pulled task (None = no ack, let the lease expire)."""
    task, now = case["task"], case["now"]
    if task["expires_at_ms"] - now < 1000:
        return {"state": "expired"}
    if not case["has_key"]:
        return {"state": "rejected", "reason": "key_unknown"}
    if not case["opens"]:
        return {"state": "rejected", "reason": "decrypt_failed"}
    if not case["target_exists"]:
        return {"state": "rejected", "reason": "target_missing"}
    result = case["admission"]
    if result in ("admitted", "duplicate"):
        return {"state": "admitted", "admission_id": case["admission_id"]}
    if result in ("invalid", "conflict"):
        return {"state": "rejected", "reason": result}
    return None


def terminal_ack(stage, reason=None):
    """The ack the phone sends for a terminal admission record (cloud-tasks.md §7)."""
    if stage in ("completed", "unknown"):
        return {"state": stage}
    if stage in ("expired", "cancelled"):
        return {"state": "failed", "reason": stage}
    if reason in ("target_missing", "not_authorized", "retry_exhausted"):
        return {"state": "failed", "reason": reason}
    return {"state": "failed", "reason": "run_failed"}


def decode_pull_element(element):
    """Raise ValueError unless a pulled task element has every member the phone needs."""
    if not isinstance(element, dict):
        raise ValueError("not an object")
    for name in ("task_id", "request_id", "key_id"):
        _id(element.get(name))
    # Responses are open at every level (§1): only the named members are judged.
    target = element.get("target")
    if not isinstance(target, dict):
        raise ValueError("target")
    _target({"kind": target.get("kind"), "id": target.get("id")})
    _int(element.get("expires_at_ms"))
    _int(element.get("created_at_ms"))
    sealed = element.get("sealed")
    if not isinstance(sealed, dict):
        raise ValueError("sealed")
    _sealed({"enc": sealed.get("enc"), "ct": sealed.get("ct")})
    lease = element.get("lease")
    if not isinstance(lease, dict):
        raise ValueError("lease")
    _id(lease.get("lease_id"))
    _int(lease.get("attempt"), 1)
    _int(lease.get("expires_at_ms"))


def pull_element_ack(element):
    """(decodes, ack) for one element of a pull response."""
    try:
        decode_pull_element(element)
        return True, None
    except ValueError:
        task_id = element.get("task_id") if isinstance(element, dict) else None
        if isinstance(task_id, str) and ID.match(task_id):
            return False, {"state": "rejected", "reason": "invalid"}
        return False, None


class CloudTaskTests(unittest.TestCase):
    def setUp(self) -> None:
        self.cases = json.loads(CASES.read_text(encoding="utf-8"))

    def test_constants(self) -> None:
        self.assertEqual(self.cases["constants"], {
            "suite": SUITE, "info": INFO.decode("ascii"), "minTtlMs": MIN_TTL_MS,
            "maxTtlMs": MAX_TTL_MS, "maxPending": MAX_PENDING, "maxTextBytes": 16384,
            "maxDevices": 8, "push": {"aps": {"content-available": 1},
                                      "pdsh": {"v": 1, "kind": "phone-tasks"}}})

    def test_valid_messages(self) -> None:
        schemas = set()
        for case in self.cases["messages"]["valid"]:
            check_message(case["message"])
            schemas.add(case["message"]["schema"])
        self.assertEqual(schemas, {"phone-device/v1", "phone-task-submit/v1", "phone-task-ack/v1"})

    def test_invalid_messages(self) -> None:
        self.assertGreaterEqual(len(self.cases["messages"]["invalid"]), 20)
        for case in self.cases["messages"]["invalid"]:
            with self.assertRaises(ValueError, msg=case["id"]):
                check_message(case["message"])

    def test_aad(self) -> None:
        for case in self.cases["aad"]:
            built = aad(case["device_id"], case["key_id"], case["request_id"], case["target"],
                        case["expires_at_ms"])
            self.assertEqual(built.decode("utf-8"), case["aad"])

    @unittest.skipUnless(HAVE_CRYPTO, "cryptography package not installed")
    def test_hpke_vectors(self) -> None:
        self.assertGreaterEqual(len(self.cases["sealing"]["valid"]), 3)
        for case in self.cases["sealing"]["valid"]:
            associated = case["aad"].encode("utf-8")
            plaintext = case["plaintext"].encode("utf-8")
            recipient_public = b64url_decode(case["recipient_public_key"])
            self.assertEqual(_point(_private(case["recipient_private_scalar"])), recipient_public)
            enc, ciphertext = seal(case["ephemeral_private_scalar"], recipient_public, plaintext,
                                   associated)
            self.assertEqual(b64url_encode(enc), case["sealed"]["enc"], case["id"])
            self.assertEqual(b64url_encode(ciphertext), case["sealed"]["ct"], case["id"])
            opened = open_sealed(case["recipient_private_scalar"], b64url_decode(case["sealed"]["enc"]),
                                 b64url_decode(case["sealed"]["ct"]), associated)
            self.assertEqual(opened, plaintext, case["id"])

    @unittest.skipUnless(HAVE_CRYPTO, "cryptography package not installed")
    def test_hpke_rejections(self) -> None:
        self.assertGreaterEqual(len(self.cases["sealing"]["invalid"]), 4)
        for case in self.cases["sealing"]["invalid"]:
            with self.assertRaises(Exception, msg=case["id"]):
                open_sealed(case["recipient_private_scalar"], b64url_decode(case["sealed"]["enc"]),
                            b64url_decode(case["sealed"]["ct"]), case["aad"].encode("utf-8"))

    @unittest.skipUnless(HAVE_CRYPTO, "cryptography package not installed")
    def test_opened_bytes_that_are_not_a_task_text(self) -> None:
        self.assertGreaterEqual(len(self.cases["sealing"]["not_text"]), 2)
        for case in self.cases["sealing"]["not_text"]:
            opened = open_sealed(case["recipient_private_scalar"], b64url_decode(case["sealed"]["enc"]),
                                 b64url_decode(case["sealed"]["ct"]), case["aad"].encode("utf-8"))
            self.assertEqual(opened.hex(), case["plaintext_hex"], case["id"])
            try:
                is_text = 1 <= len(opened) <= 16384 and bool(opened.decode("utf-8"))
            except UnicodeDecodeError:
                is_text = False
            self.assertFalse(is_text, case["id"])
            self.assertEqual(case["ack"], {"state": "rejected", "reason": "decrypt_failed"})

    def test_registration_key_rule(self) -> None:
        outcomes = set()
        for case in self.cases["registration"]:
            _key(case["key"])
            registered = case["registered"]
            swap = (registered is not None and case["same_account"]
                    and registered["key_id"] == case["key"]["key_id"]
                    and registered["public_key"] != case["key"]["public_key"])
            result = {"status": 409, "code": "key_mismatch"} if swap else {"status": 200}
            outcomes.add(result["status"])
            self.assertEqual(result, case["result"], case["id"])
        self.assertEqual(outcomes, {200, 409})

    def test_submit_decisions(self) -> None:
        seen = set()
        for case in self.cases["submit"]:
            outcome = decide_submit(case)
            seen.add(outcome.get("code", outcome["status"]))
            for key, value in case["result"].items():
                self.assertEqual(outcome.get(key), value, case["id"])
        self.assertEqual(seen, {201, 200, "invalid_request", "not_found", "request_conflict",
                                "invalid_expiry", "key_mismatch", "queue_full"})

    def test_ack_state_machine(self) -> None:
        states = set()
        for case in self.cases["acks"]:
            states.add(case["state"])
            check_message({"schema": "phone-task-ack/v1",
                           "device_id": "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a",
                           "acks": [case["ack"]]})
            accepted, duplicate, after = apply_ack(case["state"], case.get("admission_id"),
                                                   case["ack"])
            self.assertEqual({"accepted": accepted, "duplicate": duplicate, "state": after},
                             case["result"], case["id"])
        self.assertEqual(states, {"pending", "admitted"} | TERMINAL)

    def test_pull_clamp(self) -> None:
        for case in self.cases["pull"]:
            self.assertEqual(clamp_pull(case["query"]), case["effective"], case)

    def test_phone_admission_mapping(self) -> None:
        outcomes = set()
        for case in self.cases["phone"]:
            ack = phone_ack(case)
            outcomes.add(None if ack is None else ack.get("reason", ack["state"]))
            self.assertEqual(ack, case["ack"], case["id"])
        self.assertEqual(outcomes, {None, "admitted", "expired", "key_unknown", "decrypt_failed",
                                    "target_missing", "invalid", "conflict"})


    def test_terminal_mapping(self) -> None:
        states = set()
        for case in self.cases["terminal"]:
            ack = terminal_ack(case["stage"], case.get("reason"))
            states.add(ack.get("reason", ack["state"]))
            self.assertEqual(ack, case["ack"], case)
            check_message({"schema": "phone-task-ack/v1",
                           "device_id": "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a",
                           "acks": [dict(ack, task_id="t-1")]})
        self.assertEqual(states, {"completed", "unknown", "expired", "cancelled", "target_missing",
                                  "not_authorized", "retry_exhausted", "run_failed"})

    def test_pull_elements(self) -> None:
        kinds = set()
        for case in self.cases["pull_elements"]:
            decodes, ack = pull_element_ack(case["element"])
            kinds.add("ok" if decodes else ("rejected" if ack else "skipped"))
            self.assertEqual((decodes, ack), (case["decodes"], case["ack"]), case["id"])
        self.assertEqual(kinds, {"ok", "rejected", "skipped"})


if __name__ == "__main__":
    unittest.main()
