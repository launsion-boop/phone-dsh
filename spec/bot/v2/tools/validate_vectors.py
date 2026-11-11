#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the phoneDSH-owned Bot v2 schemas and their shared vectors.

The v2 tree owns memory, wake markers and proactive delivery. Its schema and
golden files were copied byte-for-byte from ``spec/bot/v1`` at the ownership
handover; ``spec/tools/bot/export-vectors.mjs`` no longer writes them. The v1
validator calls :func:`main` as well, so the existing ``phone-spec`` stage
covers both trees without a second CI stage.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))

from spec.v1.tools.spec_golden import validate_json  # noqa: E402
from spec.tools.bot.golden_overlay import (  # noqa: E402
    assert_append_only,
    load_json,
    merged_fixture,
)

BOT = ROOT / "spec" / "bot" / "v2"
GOLDEN_GLOB = "*.json"


def load(name: str):
    return load_json(BOT / "golden" / f"{name}.json")


def load_merged(name: str):
    return merged_fixture(load(name), load_json(BOT / "golden" / f"{name}.phone.json"))


def check_overlays() -> None:
    """Every v2 overlay extends its named upstream and never deletes a case."""
    for overlay_path in sorted((BOT / "golden").glob("*.phone.json")):
        overlay = load_json(overlay_path)
        base_name = overlay_path.name[:-len(".phone.json")] + ".json"
        declared = overlay.get("upstream")
        if isinstance(declared, str):
            declared_names = [declared]
        elif isinstance(declared, dict):
            declared_names = list(declared.values())
        elif isinstance(declared, list) and all(isinstance(item, str) for item in declared):
            declared_names = declared
        else:
            raise AssertionError(f"{overlay_path.name}: invalid upstream reference")
        if declared_names != [base_name]:
            raise AssertionError(f"{overlay_path.name}: upstream must be [{base_name!r}]")
        if overlay.get("vector") != overlay_path.name[:-5]:
            raise AssertionError(f"{overlay_path.name}: vector must be {overlay_path.name[:-5]!r}")
        upstream = load(base_name[:-len(".json")])
        if overlay.get("source", {}).get("checkout") != upstream.get("source", {}).get("checkout"):
            raise AssertionError(f"{overlay_path.name}: source.checkout differs from {base_name}")
        assert_append_only(upstream, overlay, overlay_path.name)
        if not merged_fixture(upstream, overlay):
            raise AssertionError(f"{overlay_path.name}: merged fixture is empty")


def schema(name: str):
    return load_json(BOT / name)


def check(instance, schema_name: str, where: str) -> None:
    validate_json(instance, schema(schema_name), where)


def check_many(instances, schema_name: str, where: str) -> None:
    for index, instance in enumerate(instances):
        check(instance, schema_name, f"{where}[{index}]")


def rejects(instance, schema_name: str, where: str) -> None:
    try:
        check(instance, schema_name, where)
    except Exception:
        return
    raise AssertionError(f"{where}: negative fixture unexpectedly validates")


def main() -> int:
    check_overlays()

    check_many(load("memory-fact")["valid"], "memory-fact.schema.json", "memory-fact")
    check(load("memory-injection")["valid"], "memory-injection.schema.json", "memory-injection")
    recall = load("memory-recall")
    check_many(recall["valid"], "memory-recall.schema.json", "memory-recall")
    check_many(recall["invalid"], "memory-recall.schema.json", "memory-recall.invalid")

    check(load("wake-routine")["valid"], "wake-routine.schema.json", "wake-routine")
    check(load("wake-routine")["valid"]["quietDefer"], "routine.schema.json", "routine")

    notifications = load("routine-notification")
    for name, case in notifications["valid"].items():
        check(case, "routine-notification.schema.json", f"routine-notification.{name}")
    for index, case in enumerate(notifications["invalid"]):
        rejects(case, "routine-notification.schema.json", f"routine-notification.invalid[{index}]")

    held_fixture = load_merged("held-inbox")
    held = held_fixture["valid"]
    check(held["enqueued"]["item"], "held-inbox-item.schema.json", "held-item")
    check(held["deviceTaskResult"], "held-inbox-item.schema.json", "held-device-task-result")
    check(held["agentHeld"], "held-inbox-item.schema.json", "held-agent-held")
    check_many(held["staged"]["items"], "held-inbox-item.schema.json", "held-staged")
    for index, case in enumerate(held_fixture["invalid"]):
        rejects(case, "held-inbox-item.schema.json", f"held.invalid[{index}]")

    print("bot v2 vectors: PASS (memory, wake, routine delivery, routine notification, "
          "held inbox; schema-positive and negative vectors)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - one actionable gate line
        print(f"bot v2 vectors: FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
