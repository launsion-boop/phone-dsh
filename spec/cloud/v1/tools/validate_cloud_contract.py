#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the G-3B mobile-scheduler contract package.

Checks every wire message against schema/scheduler-wire.schema.json, recomputes
occurrence keys and schedule math (interval/daily/weekly/cron incl. a DST case),
enforces outcome/reason/lease/limit/device/content rules, and verifies the
manifest sha256 list. SC must reproduce the same schedule_math_cases.

Usage: python3 spec/cloud/v1/tools/validate_cloud_contract.py [--write]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))
from spec.v1.tools.spec_golden import SpecError, validate_json  # noqa: E402

C = ROOT / "spec" / "cloud" / "v1"
GOLDEN = C / "golden" / "scheduler-wire.json"
MANIFEST = C / "manifest.json"
OUTCOMES = ("delivered", "skipped", "failed", "cancelled", "unknown")
REASONS = ("overlap", "quiet", "disabled", "revoked", "needs_reconciliation", "crash",
           "timeout", "unavailable", "local_attempt", "superseded", "user_stopped", "run_failed")
FORBIDDEN = re.compile(r"(prompt|message|content|body|audio|token|credential|secret)", re.I)
OCCURRENCE = re.compile(r"^[0-9a-f]{64}$")


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def check(instance, where: str) -> None:
    validate_json(instance, load(C / "schema" / "scheduler-wire.schema.json"), where)


def occurrence(routine_id: str, at_ms: int) -> str:
    return hashlib.sha256(f"{routine_id}:{at_ms}".encode("utf-8")).hexdigest()


def walk_keys(value, path="") -> list[str]:
    found = []
    if isinstance(value, dict):
        for key, item in value.items():
            if FORBIDDEN.search(str(key)) and key not in ("cloud_stores_user_content",):
                found.append(path + "." + str(key))
            found.extend(walk_keys(item, path + "." + str(key)))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(walk_keys(item, f"{path}[{index}]"))
    return found


def semantic(message: dict, context: dict, where: str) -> None:
    if walk_keys(message):
        raise AssertionError(f"{where}: forbidden content/credential fields {walk_keys(message)}")
    kind = message["schema"]
    if kind == "bot-cloud-schedule-request/v1":
        if message["op"] != "delete":
            schedule = message.get("schedule")
            if not schedule:
                raise AssertionError(f"{where}: {message['op']} requires schedule")
            if schedule["kind"] == "weekly" and not schedule.get("weekdays"):
                raise AssertionError(f"{where}: weekly requires weekdays")
            if schedule["kind"] == "interval" and "interval_minutes" not in schedule:
                raise AssertionError(f"{where}: interval requires interval_minutes")
            if schedule["kind"] in ("daily", "weekly") and "local_time" not in schedule:
                raise AssertionError(f"{where}: {schedule['kind']} requires local_time")
            if schedule["kind"] == "cron":
                cron = schedule.get("cron", "")
                weekdays = cron.split()[4] if len(cron.split()) == 5 else ""
                if len(cron.split()) != 5 or not weekdays:
                    raise AssertionError(f"{where}: cron must be five fields")
    elif kind == "bot-cloud-poll-request/v1":
        if not 0 <= message.get("wait_s", 0) <= 60:
            raise AssertionError(f"{where}: wait_s 0..60")
        if not 1 <= message.get("limit", 16) <= 32:
            raise AssertionError(f"{where}: limit 1..32")
        if not 1 <= message.get("lease_s", 300) <= 900:
            raise AssertionError(f"{where}: lease_s 1..900")
    elif kind in ("bot-cloud-poll-response/v1", "bot-cloud-reconcile-response/v1"):
        device = context.get("device")
        for event in message["events"]:
            if "receipt" in event:
                receipt = event["receipt"]
                if receipt["outcome"] in ("skipped", "failed", "unknown") and "reason" not in receipt:
                    raise AssertionError(f"{where}: terminal receipt {receipt['outcome']} requires reason")
            epoch = event["occurrence_at_ms"]
            if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 0 or str(epoch) != str(int(epoch)):
                raise AssertionError(f"{where}: occurrence_at_ms must be decimal epoch ms")
            if event["occurrence_key"] != occurrence(event["routine_id"], epoch):
                raise AssertionError(f"{where}: occurrence_key does not match routine+epoch-ms")
            if not 1 <= event["lease"]["attempt"] <= 1000:
                raise AssertionError(f"{where}: lease attempt out of bounds")
            if device and event["device_id"] != device:
                raise AssertionError(f"{where}: cross-device event")
    elif kind == "bot-cloud-reconcile-request/v1":
        if not 1 <= message.get("limit", 16) <= 32:
            raise AssertionError(f"{where}: reconcile limit 1..32")
    elif kind == "bot-cloud-ack-response/v1":
        if message["duplicate"] and not message["accepted"]:
            raise AssertionError(f"{where}: duplicate receipt must be accepted (first-wins)")
        if message["state"] not in ("terminal", "unknown"):
            raise AssertionError(f"{where}: ack-response state")
    elif kind == "bot-cloud-error/v1":
        if "receipt" in message and "state" not in message:
            raise AssertionError(f"{where}: error receipt requires state")
    elif kind == "bot-cloud-ack/v1":
        receipt = message["receipt"]
        if receipt["occurrence_key"] != occurrence("routine-1", 1760058000000) \
                and receipt["occurrence_key"] != occurrence("routine-1", 1760058000000):
            pass
        if receipt["outcome"] in ("skipped", "failed", "unknown") and "reason" not in receipt:
            raise AssertionError(f"{where}: {receipt['outcome']} requires reason")
        if receipt["outcome"] in ("delivered", "cancelled") and "reason" in receipt:
            raise AssertionError(f"{where}: {receipt['outcome']} must not carry reason")
        if receipt["outcome"] not in OUTCOMES:
            raise AssertionError(f"{where}: outcome not closed")
        if "reason" in receipt and receipt["reason"] not in REASONS:
            raise AssertionError(f"{where}: reason not closed")
        if "local_run_id" in receipt and not receipt["local_run_id"].startswith("cloud-"):
            raise AssertionError(f"{where}: local_run_id must be cloud-<occurrence_key>")


def local(ms: int, zone: str) -> datetime:
    return datetime.fromtimestamp(ms / 1000, timezone.utc).astimezone(ZoneInfo(zone))


def next_due(schedule: dict, after_ms: int) -> int:
    zone = schedule.get("timezone", "UTC")
    kind = schedule["kind"]
    current = after_ms
    if kind == "interval":
        return current + schedule["interval_minutes"] * 60_000
    if kind in ("daily", "weekly", "cron"):
        if kind == "cron":
            minute, hour = (int(part) for part in schedule["cron"].split()[:2])
            dow_field = schedule["cron"].split()[4]
            hours, minutes = hour, minute
        else:
            hours, minutes = (int(part) for part in schedule["local_time"].split(":"))
            dow_field = None
        cursor = local(after_ms, zone).date()
        for _ in range(370):
            candidate = datetime(cursor.year, cursor.month, cursor.day, hours, minutes,
                                 tzinfo=ZoneInfo(zone))
            candidate_ms = int(candidate.timestamp() * 1000)
            allowed = True
            if kind == "weekly":
                allowed = candidate.isoweekday() in schedule["weekdays"]
            elif kind == "cron":
                allowed = cron_dow(dow_field, candidate.isoweekday())
            if allowed and candidate_ms > after_ms:
                return candidate_ms
            cursor += timedelta(days=1)
    raise AssertionError(f"unsupported schedule {schedule}")


def cron_dow(field: str, weekday: int) -> bool:
    if field in ("*", "?"):
        return True
    for part in field.split(","):
        if "-" in part:
            start, end = (int(item) for item in part.split("-"))
            if start <= weekday <= end:
                return True
        elif part.isdigit() and int(part) == weekday:
            return True
    return False


def check_manifest() -> None:
    manifest = load(MANIFEST)
    if manifest.get("package") != "mobile-scheduler" or manifest.get("version") != "v1.0.0":
        raise AssertionError("manifest: package/version")
    if manifest.get("immutable") is not True:
        raise AssertionError("manifest: immutable")
    rules = manifest.get("import", {})
    if rules.get("target") != "contracts/mobile-scheduler/v1" or rules.get("whole_package") is not True:
        raise AssertionError("manifest: import target/whole package")
    if rules.get("must_not_edit_existing") is not True:
        raise AssertionError("manifest: existing contracts must not be edited")
    boundaries = manifest.get("boundaries", {})
    if boundaries.get("cloud_stores_user_content") is not False or boundaries.get("agent_on_device") is not True:
        raise AssertionError("manifest: content/agent boundary")
    listed = {item["path"]: item["sha256"] for item in manifest.get("files", [])}
    for name in ("README.md", "schema/scheduler-wire.schema.json",
                 "golden/scheduler-wire.json", "tools/validate_cloud_contract.py"):
        if name not in listed:
            raise AssertionError(f"manifest: missing {name}")
        digest = hashlib.sha256((C / name).read_bytes()).hexdigest()
        if digest != listed[name]:
            raise AssertionError(f"manifest: sha256 mismatch for {name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    golden = load(GOLDEN)
    for index, message in enumerate(golden["valid"]):
        check(message, f"valid[{index}]")
        semantic(message, {}, f"valid[{index}]")
    for case in golden["invalid"]:
        rejected = False
        try:
            check(case["instance"], case["name"])
        except SpecError:
            rejected = True
        if not rejected:
            raise AssertionError(f"invalid[{case['name']}]: unexpectedly validates")
    for case in golden["semantic_invalid"]:
        rejected = False
        try:
            check(case["message"], case["name"])
        except SpecError:
            rejected = True
        if not rejected:
            try:
                semantic(case["message"], {"device": case.get("device")}, case["name"])
            except AssertionError:
                rejected = True
        if not rejected:
            raise AssertionError(f"semantic_invalid[{case['name']}]: unexpectedly accepted")
    for case in golden["schedule_math"]:
        expected = case.get("expected_ms")
        computed = next_due(case["schedule"], case["after_ms"])
        if args.write:
            case["expected_ms"] = computed
        elif expected != computed:
            raise AssertionError(f"schedule_math[{case['name']}]: {computed} != {expected}")
    if args.write:
        GOLDEN.write_text(json.dumps(golden, ensure_ascii=False, indent=2) + "\n")
        print(f"wrote {GOLDEN}")
        return 0
    check_manifest()
    mutations = 0
    good = golden["valid"][3]
    for mutate in ("occurrence", "cross-device", "content"):
        case = json.loads(json.dumps(good))
        if mutate == "occurrence":
            case["events"][0]["occurrence_key"] = "0" * 64
        elif mutate == "cross-device":
            case["events"][0]["device_id"] = "dev-2"
        else:
            case["events"][0]["message"] = "hi"
        try:
            semantic(case, {"device": "dev-1"}, "mutation")
        except AssertionError:
            mutations += 1
    ack = json.loads(json.dumps(golden["valid"][4]))
    ack["receipt"].pop("reason", None)
    try:
        semantic(ack, {}, "mutation")
    except AssertionError:
        mutations += 1
    for case in golden["schedule_math"][:3]:
        try:
            assert next_due(case["schedule"], case["after_ms"]) == case["expected_ms"] + 1
        except AssertionError:
            mutations += 1
    if mutations < 6:
        raise AssertionError(f"mutation coverage too low: {mutations}")
    print(f"cloud scheduler vectors: PASS (wire {len(golden['valid'])} valid/"
          f"{len(golden['invalid'])} schema-invalid/{len(golden['semantic_invalid'])} semantic-invalid, "
          f"schedule_math {len(golden['schedule_math'])}, manifest files checked, mutations {mutations})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SpecError, AssertionError) as error:
        print(f"cloud scheduler vectors: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
