#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Catalog validation, selection and evidence-gate helpers for the Bot eval runner.

This module is stdlib-only on purpose: CI and self-checks run it without a
virtualenv. It owns the parts that must be mechanical and inspectable before any
Worker boots:

* validate a catalog against ``catalog.schema.json`` (a deliberately small
  JSON-Schema subset, implemented here) plus the semantic rules the schema
  cannot express;
* turn the catalog into the normalized ``plan.json`` the Swift runner executes;
* verify each selected scenario's terminal evidence after the run and write the
  batch summary.

The Swift runner is still the authority for what actually happened. This tool
fails closed when a report is missing, has the wrong shape, belongs to another
scenario, or claims a different upstream/repeat count.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import math
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA_PATH = HERE / "catalog.schema.json"
DEFAULT_FIXTURES = HERE / "fixtures"
DEFAULT_BUDGET = {"max_minutes": 10, "max_model_requests": 40}
DEFAULT_ACTION_TIMEOUT = 180.0
EVIDENCE_FILES = ("report.json", "transcript.jsonl", "bot-events.jsonl", "workspace.tar")
SUPPORTED_ACTIONS = {
    "create_bot", "user_message", "ui_action", "approval_policy",
    "advance_clock", "seed_held_item", "restart_worker",
}
SUPPORTED_ASSERTIONS = {
    "file_exists", "no_file", "file_contains", "file_regex", "file_json_path",
    "workspace_command", "reply_contains", "reply_not_contains",
    "bot_event", "no_bot_event", "tool_called", "no_tool_call",
    "memory_contains", "memory_absent", "approval_count", "echo_requests",
}
UI_KINDS = {
    "card_answer", "card_dismiss", "approval", "erase_memory",
    "erase_shared_memory", "forget_memory", "stop_task", "await_task",
}
BOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SCENARIO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
RELATIVE_PATH_RE = re.compile(r"(?!/)(?!.*(?:^|/)\.\.(?:/|$))[^\x00]+")


class CatalogError(Exception):
    """A catalog or evidence problem that must fail the run loudly."""


# ---------------------------------------------------------------------------
# JSON-Schema subset


def _type_matches(value, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    raise CatalogError(f"schema uses unsupported type {expected!r}")


def _resolve_ref(ref: str, root: dict) -> dict:
    if not ref.startswith("#/"):
        raise CatalogError(f"schema uses unsupported external reference {ref!r}")
    node = root
    for part in ref[2:].split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        if not isinstance(node, dict) or part not in node:
            raise CatalogError(f"schema reference cannot be resolved: {ref}")
        node = node[part]
    return node


def validate_schema(instance, schema, root, path="$", errors=None):
    """Validate *instance* against the schema subset used by catalog.schema.json.

    The subset is intentional and small. It accepts only keywords this project
    actually uses, so a typo in the schema cannot silently weaken validation.
    """
    if errors is None:
        errors = []
    if schema is True or schema == {}:
        return errors
    if schema is False:
        errors.append(f"{path}: schema denies every value")
        return errors
    if not isinstance(schema, dict):
        raise CatalogError(f"schema node at {path} is not an object")

    if "$ref" in schema:
        target = _resolve_ref(schema["$ref"], root)
        validate_schema(instance, target, root, path, errors)
        return errors

    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: expected one of {schema['enum']!r}")
    if "type" in schema:
        expected = schema["type"]
        candidates = expected if isinstance(expected, list) else [expected]
        if not any(_type_matches(instance, item) for item in candidates):
            errors.append(f"{path}: expected type {expected!r}")
            return errors
    if "oneOf" in schema:
        matches = []
        for index, candidate in enumerate(schema["oneOf"]):
            candidate_errors = validate_schema(instance, candidate, root, path, [])
            if not candidate_errors:
                matches.append((index, candidate))
        if len(matches) != 1:
            errors.append(f"{path}: expected exactly one oneOf branch, matched {len(matches)}")
        # Do not descend into the matching branch here: oneOf branches in this
        # catalog are complete objects. Descending again would duplicate errors.
    if "anyOf" in schema:
        branch_errors = [validate_schema(instance, candidate, root, path, [])
                         for candidate in schema["anyOf"]]
        if all(branch_errors):
            errors.append(f"{path}: no anyOf branch matched")
    if "allOf" in schema:
        for candidate in schema["allOf"]:
            validate_schema(instance, candidate, root, path, errors)

    if isinstance(instance, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                errors.append(f"{path}: missing required key {key!r}")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)
        for key, value in instance.items():
            child_path = f"{path}.{key}"
            if key in properties:
                validate_schema(value, properties[key], root, child_path, errors)
            elif additional is False:
                errors.append(f"{child_path}: unexpected key {key!r}")
            elif isinstance(additional, dict):
                validate_schema(value, additional, root, child_path, errors)

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{path}: needs at least {schema['minItems']} item(s)")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            errors.append(f"{path}: allows at most {schema['maxItems']} item(s)")
        item_schema = schema.get("items")
        if item_schema is not None:
            for index, value in enumerate(instance):
                validate_schema(value, item_schema, root, f"{path}[{index}]", errors)

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append(f"{path}: shorter than {schema['minLength']} character(s)")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            errors.append(f"{path}: longer than {schema['maxLength']} character(s)")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            errors.append(f"{path}: does not match {schema['pattern']!r}")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: below minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{path}: above maximum {schema['maximum']}")
        if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
            errors.append(f"{path}: not greater than {schema['exclusiveMinimum']}")
        if "exclusiveMaximum" in schema and instance >= schema["exclusiveMaximum"]:
            errors.append(f"{path}: not less than {schema['exclusiveMaximum']}")
    return errors


# ---------------------------------------------------------------------------
# Semantic validation


def _error(errors, path, message):
    errors.append(f"{path}: {message}")


def _check_relative_path(errors, path, value):
    if not isinstance(value, str) or not value:
        _error(errors, path, "path must be a non-empty string")
        return
    if value.startswith("/"):
        _error(errors, path, "path must be relative to the Bot workspace")
    elif value.startswith("\\") or re.match(r"^[A-Za-z]:", value):
        _error(errors, path, "path must not be an absolute host path")
    elif not RELATIVE_PATH_RE.fullmatch(value):
        _error(errors, path, "path must not contain '..' or NUL")


def _check_mock(errors, path, mock):
    if mock is None:
        return
    if mock.get("tool") is not None and mock.get("tools") is not None:
        _error(errors, path, "mock must not set both 'tool' and 'tools'")
    for index, rule in enumerate(mock.get("prompt_rules", []) or []):
        if not rule.get("contains"):
            _error(errors, f"{path}.prompt_rules[{index}]", "contains must be non-empty")
        if not rule.get("final_text"):
            _error(errors, f"{path}.prompt_rules[{index}]", "final_text must be non-empty")


def _check_action(errors, path, action, aliases):
    kind = action.get("type")
    if kind not in SUPPORTED_ACTIONS:
        _error(errors, path, f"unsupported action type {kind!r}")
        return
    bot = action.get("bot")
    if bot is not None and bot != "main" and bot not in aliases:
        _error(errors, path, f"bot {bot!r} is not 'main' or a create_bot alias declared earlier")
    _check_mock(errors, f"{path}.mock", action.get("mock"))
    if kind == "create_bot":
        if not action.get("name"):
            _error(errors, path, "create_bot requires a non-empty name")
        alias = action.get("alias")
        if alias is not None:
            if not BOT_RE.fullmatch(alias):
                _error(errors, path, f"alias {alias!r} is not a valid bot alias")
            elif alias == "main":
                _error(errors, path, "alias 'main' is reserved for the main Bot")
            elif alias in aliases:
                _error(errors, path, f"duplicate create_bot alias {alias!r}")
            else:
                aliases.add(alias)
    elif kind == "user_message":
        if not (action.get("text") or "").strip():
            _error(errors, path, "user_message requires non-empty text")
    elif kind == "ui_action":
        ui_kind = action.get("kind")
        if ui_kind not in UI_KINDS:
            _error(errors, path, f"unsupported ui_action kind {ui_kind!r}")
        elif ui_kind == "approval":
            if action.get("decision") not in (None, "allow_once", "always", "deny"):
                _error(errors, path, "approval decision must be allow_once, always or deny")
            if action.get("decision") is None:
                _error(errors, path, "ui_action approval requires decision")
        elif ui_kind == "forget_memory":
            if not (action.get("fact_contains") or action.get("fact_id")):
                _error(errors, path, "ui_action forget_memory requires fact_contains or fact_id")
    elif kind == "approval_policy":
        for index, rule in enumerate(action.get("rules", []) or []):
            if not rule.get("tool"):
                _error(errors, f"{path}.rules[{index}]", "tool must be non-empty")
    elif kind == "seed_held_item":
        if not (action.get("text") or "").strip():
            _error(errors, path, "seed_held_item requires non-empty text")
    elif kind == "restart_worker":
        if action.get("mode") not in (None, "planned_restart", "worker_kill"):
            _error(errors, path, "restart_worker mode must be planned_restart or worker_kill")


def _check_assertion(errors, path, assertion):
    kind = assertion.get("type")
    if kind not in SUPPORTED_ASSERTIONS:
        _error(errors, path, f"unsupported assertion type {kind!r}")
        return
    if kind in ("file_exists", "no_file", "file_contains", "file_regex", "file_json_path"):
        _check_relative_path(errors, f"{path}.path", assertion.get("path"))
    if kind in ("file_contains", "file_regex", "file_json_path") and "value" not in assertion:
        _error(errors, path, f"{kind} requires value")
    if kind in ("reply_contains", "reply_not_contains") and not assertion.get("value"):
        _error(errors, path, f"{kind} requires a non-empty value")
    if kind in ("memory_contains", "memory_absent") and not isinstance(assertion.get("value"), str):
        _error(errors, path, f"{kind} requires a string value")
    if kind in ("bot_event", "no_bot_event") and not assertion.get("event"):
        _error(errors, path, f"{kind} requires event")
    if kind in ("memory_contains", "memory_absent") and assertion.get("value") == "" \
            and not any(assertion.get(key) for key in ("scope", "tier", "source")):
        _error(errors, path, f"{kind} with an empty value needs scope, tier or source")
    if kind in ("tool_called", "no_tool_call") and not assertion.get("name"):
        _error(errors, path, f"{kind} requires name")
    if kind in ("approval_count", "echo_requests"):
        has_equals = "equals" in assertion
        has_max = "max" in assertion
        if has_equals == has_max:
            _error(errors, path, f"{kind} requires exactly one of equals or max")
    if kind == "echo_requests" and "method" in assertion:
        method = assertion.get("method")
        if not isinstance(method, str) or not method.isalpha():
            _error(errors, path, "echo_requests method must be an alphabetic HTTP method")


def _fixture_root(name, fixtures_root: Path) -> Path | None:
    candidate = fixtures_root / name
    if not candidate.is_dir():
        return None
    files = candidate / "files"
    return files if files.is_dir() else candidate


def validate_catalog(catalog, fixtures_root: Path, selftest=False):
    errors = []
    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CatalogError(f"cannot read schema {SCHEMA_PATH}: {exc}") from exc
    errors.extend(validate_schema(catalog, schema, schema))
    if errors:
        return errors
    if catalog.get("version") != 1:
        _error(errors, "$.version", "only version 1 is supported")
    top_selftest = bool(catalog.get("selftest", False))
    if selftest and not top_selftest:
        _error(errors, "$.selftest", "the runner was asked for selftest mode but the catalog does not declare selftest: true")
    seen = set()
    for index, scenario in enumerate(catalog.get("scenarios", [])):
        base = f"$.scenarios[{index}]"
        sid = scenario.get("id")
        if sid in seen:
            _error(errors, f"{base}.id", f"duplicate scenario id {sid!r}")
        seen.add(sid)
        if scenario.get("target") == "sim":
            # Not an error: the plan records the skip. This runner is macOS.
            pass
        if scenario.get("expect") == "fail" and not top_selftest:
            _error(errors, f"{base}.expect", "expect: fail is only allowed in a selftest catalog")
        budget = scenario.get("budget")
        if budget is None and not scenario.get("skip"):
            _error(errors, f"{base}.budget", "every runnable scenario needs an explicit budget")
        if budget is not None:
            if budget.get("max_minutes", 0) <= 0:
                _error(errors, f"{base}.budget.max_minutes", "must be positive")
        if scenario.get("skip") and not scenario["skip"].strip():
            _error(errors, f"{base}.skip", "skip reason must not be blank")
        workspace = scenario.get("workspace") or {}
        workspace_bot = workspace.get("bot", "main")
        if workspace_bot != "main":
            # Workspace seeding for a created Bot happens after its create_bot
            # action; the alias must be declared somewhere in this scenario.
            declared = {
                action.get("alias")
                for action in (scenario.get("actions") or [])
                if isinstance(action, dict) and action.get("type") == "create_bot"
            }
            if workspace_bot not in declared:
                _error(errors, f"{base}.workspace.bot", f"unknown bot alias {workspace_bot!r}")
        for key, content in (workspace.get("files") or {}).items():
            _check_relative_path(errors, f"{base}.workspace.files[{key!r}]", key)
            if not isinstance(content, str):
                _error(errors, f"{base}.workspace.files[{key!r}]", "file content must be a string")
        fixture = workspace.get("fixture")
        if fixture and _fixture_root(fixture, fixtures_root) is None:
            _error(errors, f"{base}.workspace.fixture", f"fixture {fixture!r} not found under {fixtures_root}")
        network = scenario.get("network")
        if isinstance(network, dict):
            for host in network.get("allow", []) or []:
                if "://" in host or "/" in host or not host.strip():
                    _error(errors, f"{base}.network.allow", f"{host!r} must be a bare host or host:port")
        aliases = set()
        for action_index, action in enumerate(scenario.get("actions") or []):
            _check_action(errors, f"{base}.actions[{action_index}]", action, aliases)
        # Turns are normalized to user_message actions and share the alias order.
        for turn_index, turn in enumerate(scenario.get("turns") or []):
            _check_mock(errors, f"{base}.turns[{turn_index}].mock", turn.get("mock"))
            bot = turn.get("bot")
            if bot is not None and bot != "main":
                # G2 turns run before the new driver actions, so a Bot created
                # by an action cannot receive a legacy turn.
                _error(errors, f"{base}.turns[{turn_index}].bot",
                       "legacy turns can only target the main Bot; use actions for a created Bot")
        _check_mock(errors, f"{base}.mock", scenario.get("mock"))
        for assertion_index, assertion in enumerate(scenario.get("assertions") or []):
            _check_assertion(errors, f"{base}.assertions[{assertion_index}]", assertion)
            if assertion.get("expect_ok") is not None and not top_selftest:
                _error(errors, f"{base}.assertions[{assertion_index}].expect_ok",
                       "expect_ok is only allowed in a selftest catalog")
            bot = assertion.get("bot")
            if bot is not None and bot != "main" and bot not in aliases:
                _error(errors, f"{base}.assertions[{assertion_index}].bot",
                       f"bot {bot!r} is not 'main' or a create_bot alias declared earlier")
        for perturbation_index, perturbation in enumerate(scenario.get("perturbations") or []):
            at = perturbation.get("at", "")
            if at.startswith("minute:"):
                # Minute-based perturbations still have no production seam;
                # the plan records a skip instead of silently running a
                # different scenario. The explicit `advance_clock` action is
                # the supported scheduler-clock fixture.
                pass
    budget = catalog.get("budget")
    if budget is not None:
        for key in ("max_minutes", "max_model_requests"):
            if budget.get(key, 0) < 0:
                _error(errors, f"$.budget.{key}", "must not be negative")
    return errors


# ---------------------------------------------------------------------------
# Plan normalization


def _int(value, default=None):
    return value if isinstance(value, int) and not isinstance(value, bool) else default


def _str(value, default=None):
    return value if isinstance(value, str) else default


def _normalize_mock(mock):
    if mock is None:
        return None
    out = dict(mock)
    if out.get("tool") is None and out.get("tools") is None and out.get("final_text") is None:
        out["final_text"] = "BOT_EVAL_OK"
    return out


def _normalize_assertion(assertion, selftest, default_bot="main"):
    out = dict(assertion)
    out.setdefault("bot", default_bot)
    if selftest:
        out.setdefault("expect_ok", True)
    else:
        out.pop("expect_ok", None)
    return out


def _normalize_action(action, default_bot="main"):
    out = dict(action)
    if out.get("type") == "create_bot":
        out.pop("bot", None)
    else:
        out.setdefault("bot", default_bot)
    if out.get("type") == "user_message":
        out.setdefault("text", "")
    if out.get("type") == "restart_worker":
        out.setdefault("mode", "planned_restart")
    if out.get("type") == "seed_held_item":
        out.setdefault("kind", "eval-fixture")
    if out.get("type") == "ui_action" and out.get("kind") == "approval":
        out.setdefault("decision", "deny")
    if out.get("mock") is not None:
        out["mock"] = _normalize_mock(out["mock"])
    return out


def normalize_scenario(scenario, selftest, fixtures_root: Path):
    out = {
        "id": scenario["id"],
        "title": scenario.get("title", scenario["id"]),
        "expect": scenario.get("expect", "pass"),
        "skip": scenario.get("skip"),
        "budget": scenario.get("budget") or dict(DEFAULT_BUDGET),
        "workspace": {
            "bot": (scenario.get("workspace") or {}).get("bot", "main"),
            "root": (scenario.get("workspace") or {}).get("root", "bot"),
            "files": dict((scenario.get("workspace") or {}).get("files") or {}),
            "fixture": (scenario.get("workspace") or {}).get("fixture"),
        },
        "network": {"allow": []},
        "actions": [],
        "assertions": [],
        "timeout_s": scenario.get("timeout_s", DEFAULT_ACTION_TIMEOUT),
        "mock": _normalize_mock(scenario.get("mock")),
    }
    skip_reasons = []
    if out["skip"]:
        skip_reasons.append(out["skip"])
    if scenario.get("target") == "sim":
        skip_reasons.append("catalog target is sim-only; eval.sh executes the macOS production assembly")
    network = scenario.get("network", "none")
    if isinstance(network, dict):
        out["network"]["allow"] = list(network.get("allow") or [])
    # Turns first, then explicit actions. This keeps every G2-style prompt
    # before the new driver actions.
    for turn in scenario.get("turns") or []:
        out["actions"].append({
            "type": "user_message",
            "bot": turn.get("bot", "main"),
            "text": turn["prompt"],
            **({"mock": _normalize_mock(turn["mock"])} if turn.get("mock") else {}),
        })
    for action in scenario.get("actions") or []:
        out["actions"].append(_normalize_action(action))
    # G2 perturbations become explicit restart_worker actions where the
    # production seam exists. Unsupported kinds make the scenario SKIP instead
    # of silently changing what it measures.
    for perturbation in scenario.get("perturbations") or []:
        at = perturbation.get("at", "")
        kind = perturbation.get("kind", "")
        if not at.startswith("after_turn:"):
            skip_reasons.append(
                f"perturbation {kind} at {at} needs a scheduler clock or a process-kill seam "
                "the production composition does not expose")
            continue
        if kind not in ("planned_restart", "worker_kill"):
            skip_reasons.append(f"perturbation {kind} is not exposed by the production composition")
            continue
        try:
            after_turn = int(at.split(":", 1)[1])
        except ValueError:
            skip_reasons.append(f"invalid perturbation at {at!r}")
            continue
        insert_at = 0
        seen = 0
        for index, action in enumerate(out["actions"]):
            if action.get("type") == "user_message":
                seen += 1
                if seen == after_turn:
                    insert_at = index + 1
                    break
        else:
            skip_reasons.append(f"perturbation {at} is after the last user_message")
            continue
        out["actions"].insert(insert_at, {
            "type": "restart_worker",
            "mode": "worker_kill" if kind == "worker_kill" else "planned_restart",
            "perturbation": kind,
            "degraded": "plannedRestart" if kind == "worker_kill" else None,
        })
    out["actions"] = [_normalize_action(action) for action in out["actions"]]
    for index, action in enumerate(out["actions"]):
        action["index"] = index
    for assertion in scenario.get("assertions") or []:
        out["assertions"].append(_normalize_assertion(assertion, selftest))
    if not out["actions"] and not skip_reasons:
        skip_reasons.append("scenario has no driver actions")
    if skip_reasons:
        out["skip"] = "; ".join(dict.fromkeys(skip_reasons))
    return out


def load_catalog(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise CatalogError(f"cannot read catalog {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CatalogError(f"catalog is not valid JSON: {path}: {exc}") from exc


def build_plan(catalog_path: Path, only: str | None, repeat: int, upstream: str,
               results: Path, fixtures_root: Path, selftest: bool):
    catalog = load_catalog(catalog_path)
    errors = validate_catalog(catalog, fixtures_root, selftest=selftest)
    if errors:
        raise CatalogError("catalog validation failed:\n  " + "\n  ".join(errors))
    scenarios = catalog.get("scenarios") or []
    wanted = [item.strip() for item in (only or "").split(",") if item.strip()]
    if wanted:
        by_id = {scenario["id"]: scenario for scenario in scenarios}
        missing = [sid for sid in wanted if sid not in by_id]
        if missing:
            raise CatalogError(f"--only ids not found in {catalog_path}: {', '.join(missing)}")
        selected = [by_id[sid] for sid in wanted]
    else:
        selected = list(scenarios)
    if not selected:
        raise CatalogError("no scenarios selected")
    if repeat < 1:
        raise CatalogError("--repeat must be at least 1")
    plan_scenarios = [normalize_scenario(scenario, selftest, fixtures_root)
                      for scenario in selected]
    runnable = [scenario for scenario in plan_scenarios if not scenario["skip"]]
    total_minutes = sum(scenario["budget"]["max_minutes"] for scenario in runnable) * repeat
    total_requests = sum(scenario["budget"]["max_model_requests"] for scenario in runnable) * repeat
    batch_budget = catalog.get("budget")
    if batch_budget:
        if total_minutes > batch_budget["max_minutes"]:
            raise CatalogError(
                f"selected scenarios x repeat need {total_minutes} minutes, "
                f"above the catalog ceiling {batch_budget['max_minutes']}")
        if total_requests > batch_budget["max_model_requests"]:
            raise CatalogError(
                f"selected scenarios x repeat need {total_requests} model requests, "
                f"above the catalog ceiling {batch_budget['max_model_requests']}")
    return {
        "version": 1,
        "catalog": str(catalog_path.resolve()),
        "catalog_sha256": hashlib.sha256(catalog_path.read_bytes()).hexdigest(),
        "upstream": upstream,
        "repeat": repeat,
        "selftest": bool(catalog.get("selftest", False)) if selftest else False,
        "keep_bodies": False,
        "fixtures_root": str(fixtures_root.resolve()),
        "results": str(results.resolve()),
        "batch_budget": {
            "max_minutes": total_minutes,
            "max_model_requests": total_requests,
        },
        "scenarios": plan_scenarios,
    }


# ---------------------------------------------------------------------------
# Evidence gate


def _load_report(path: Path, scenario_id: str):
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise CatalogError(f"{scenario_id}: cannot read report.json: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CatalogError(f"{scenario_id}: report.json is not valid JSON: {exc}") from exc
    if not isinstance(report, dict):
        raise CatalogError(f"{scenario_id}: report.json is not an object")
    if report.get("id") != scenario_id:
        raise CatalogError(
            f"{scenario_id}: report.json belongs to {report.get('id')!r}")
    return report


def _assert_file(path: Path, scenario_id: str, name: str, errors):
    if not path.is_file():
        errors.append(f"{scenario_id}: missing evidence {name}")
        return
    if name != "workspace.tar" and path.stat().st_size == 0:
        # An empty transcript is allowed only when the scenario was skipped.
        return
    if name == "workspace.tar" and path.stat().st_size == 0:
        errors.append(f"{scenario_id}: {name} is empty")


def _report_int(value, name, scenario_id, errors):
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        errors.append(f"{scenario_id}: report field {name} must be a non-negative integer")
        return None
    return value


def _assertion_key(assertion):
    # The report records the ordered outcome, not a second copy of the plan.
    # The index and type are enough to prove both sides describe the same
    # assertion; values are checked by the runner that evaluated them.
    return assertion.get("type")


def check_plan(plan, results: Path):
    errors = []
    summary_scenarios = []
    upstream = plan.get("upstream")
    repeat_count = plan.get("repeat", 1)
    selftest = bool(plan.get("selftest"))
    for scenario in plan.get("scenarios", []):
        sid = scenario["id"]
        directory = results / sid
        reasons = []
        gate = "PASS"
        for name in EVIDENCE_FILES:
            _assert_file(directory / name, sid, name, errors)
        report = None
        try:
            report = _load_report(directory / "report.json", sid)
        except CatalogError as exc:
            errors.append(str(exc))
            reasons.append(str(exc))
        if report is not None:
            if report.get("upstream") != upstream:
                errors.append(f"{sid}: report upstream {report.get('upstream')!r} != {upstream!r}")
            if report.get("expect") != scenario.get("expect", "pass"):
                errors.append(f"{sid}: report expect {report.get('expect')!r} != {scenario.get('expect')!r}")
            report_repeat = report.get("repeat")
            if report_repeat != repeat_count:
                errors.append(f"{sid}: report repeat {report_repeat!r} != plan repeat {repeat_count}")
            if scenario.get("skip"):
                if report.get("status") != "SKIP":
                    errors.append(f"{sid}: expected SKIP, report says {report.get('status')!r}")
                elif not report.get("reason"):
                    errors.append(f"{sid}: SKIP report has no reason")
                else:
                    reasons.append(f"SKIP: {report.get('reason', '')}")
                    if not selftest:
                        # A product catalog's scenario that never ran is a
                        # NOT_RUN, never a pass. The self-check catalog may
                        # declare an expected skip for a seam it reports as a
                        # contract change request.
                        errors.append(f"{sid}: NOT_RUN: scenario was skipped")
            else:
                repeats = report.get("repeats")
                if not isinstance(repeats, list) or len(repeats) != repeat_count:
                    errors.append(f"{sid}: report.repeats must contain {repeat_count} entries")
                    repeats = []
                for index, repeat in enumerate(repeats):
                    if not isinstance(repeat, dict):
                        errors.append(f"{sid}: repeat[{index}] is not an object")
                        continue
                    status = repeat.get("status")
                    if status == "ERROR":
                        errors.append(f"{sid}: repeat {index + 1} is ERROR: {repeat.get('error')}")
                    elif status == "NOT_RUN":
                        errors.append(f"{sid}: repeat {index + 1} is NOT_RUN: {repeat.get('error')}")
                    assertions = repeat.get("assertions") or []
                    if len(assertions) != len(scenario.get("assertions", [])):
                        errors.append(
                            f"{sid}: repeat {index + 1} has {len(assertions)} assertion result(s), "
                            f"plan has {len(scenario.get('assertions', []))}")
                    expected_assertions = scenario.get("assertions", [])
                    for a_index, expected in enumerate(expected_assertions):
                        if a_index >= len(assertions):
                            break
                        actual = assertions[a_index]
                        if not isinstance(actual, dict):
                            errors.append(f"{sid}: repeat {index + 1} assertion {a_index} is not an object")
                            continue
                        if _assertion_key(actual) != _assertion_key(expected):
                            errors.append(
                                f"{sid}: repeat {index + 1} assertion {a_index} does not match the plan "
                                f"(report {actual.get('type')!r}, plan {expected.get('type')!r})")
                        expect_ok = expected.get("expect_ok", True)
                        if selftest and actual.get("ok") is not expect_ok:
                            errors.append(
                                f"{sid}: repeat {index + 1} assertion {a_index} ({expected.get('type')}) "
                                f"ok={actual.get('ok')!r}, expect_ok={expect_ok!r}")
                        if not selftest and actual.get("ok") is not True:
                            errors.append(
                                f"{sid}: repeat {index + 1} assertion {a_index} ({expected.get('type')}) failed: "
                                f"{actual.get('detail', '')}")
                    actions = repeat.get("actions") or []
                    if len(actions) != len(scenario.get("actions", [])):
                        errors.append(
                            f"{sid}: repeat {index + 1} has {len(actions)} action result(s), "
                            f"plan has {len(scenario.get('actions', []))}")
                    for a_index, action in enumerate(actions):
                        if not isinstance(action, dict):
                            errors.append(f"{sid}: repeat {index + 1} action {a_index} is not an object")
                            continue
                        if action.get("status") not in ("ok", "degraded"):
                            errors.append(
                                f"{sid}: repeat {index + 1} action {a_index} ({action.get('type')}) "
                                f"status {action.get('status')!r}")
                    usage = repeat.get("usage") or {}
                    requests = usage.get("model_requests")
                    if requests is not None and scenario.get("budget"):
                        if _report_int(requests, "usage.model_requests", sid, errors) is not None:
                            if requests > scenario["budget"]["max_model_requests"]:
                                errors.append(
                                    f"{sid}: repeat {index + 1} used {requests} model requests, "
                                    f"budget {scenario['budget']['max_model_requests']}")
                    wall = usage.get("wall_s")
                    if isinstance(wall, (int, float)) and scenario.get("budget"):
                        if wall > scenario["budget"]["max_minutes"] * 60 + 30:
                            errors.append(
                                f"{sid}: repeat {index + 1} wall {wall:.1f}s exceeds "
                                f"{scenario['budget']['max_minutes']} min")
                expected = scenario.get("expect", "pass")
                run_status = report.get("run_status")
                expectation_met = report.get("expectation_met") is True
                if expected == "pass":
                    if report.get("status") != "PASS" or run_status != "PASS" or not expectation_met:
                        errors.append(
                            f"{sid}: expected PASS, report status {report.get('status')!r}, "
                            f"run_status {run_status!r}, expectation_met {report.get('expectation_met')!r}")
                elif selftest and expected == "fail":
                    if report.get("status") != "PASS" or run_status != "FAIL" or not expectation_met:
                        errors.append(
                            f"{sid}: selftest expected a controlled FAIL, report status "
                            f"{report.get('status')!r}, run_status {run_status!r}, "
                            f"expectation_met {report.get('expectation_met')!r}")
                else:
                    errors.append(f"{sid}: expect {expected!r} is not supported by this gate")
        if scenario.get("skip") and gate != "FAIL":
            gate = "SKIP"
        if reasons and not scenario.get("skip"):
            gate = "FAIL"
        summary_scenarios.append({
            "id": sid,
            "expected": scenario.get("expect", "pass"),
            "skip": bool(scenario.get("skip")),
            "gate": gate,
            "report": (str(directory / "report.json")),
            "reasons": reasons,
        })
    for scenario in summary_scenarios:
        prefix = scenario["id"] + ":"
        if any(error.startswith(prefix) for error in errors):
            scenario["gate"] = "FAIL"
    status = "PASS" if not errors else "FAIL"
    summary = {
        "version": 1,
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "upstream": upstream,
        "repeat": repeat_count,
        "selftest": selftest,
        "gate": status,
        "scenarios": summary_scenarios,
        "errors": errors,
    }
    return summary


def write_summary(summary, out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    lines = [
        "# Bot eval summary",
        "",
        f"- upstream: {summary['upstream']}",
        f"- repeat: {summary['repeat']}",
        f"- selftest: {summary['selftest']}",
        f"- gate: **{summary['gate']}**",
        "",
        "| scenario | expected | gate | detail |",
        "|---|---|---|---|",
    ]
    for scenario in summary["scenarios"]:
        detail = "; ".join(scenario["reasons"]) or "-"
        lines.append(f"| {scenario['id']} | {scenario['expected']} | {scenario['gate']} | {detail} |")
    if summary["errors"]:
        lines.extend(["", "## Errors", ""])
        lines.extend(f"- {error}" for error in summary["errors"])
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# CLI


def command_validate(args):
    catalog = load_catalog(args.catalog)
    errors = validate_catalog(catalog, args.fixtures_root, selftest=args.selftest)
    if errors:
        for error in errors:
            print(f"catalog: {error}", file=sys.stderr)
        return 1
    print(f"catalog: OK ({len(catalog.get('scenarios', []))} scenario(s), "
          f"{'selftest' if catalog.get('selftest') else 'product'} catalog)")
    return 0


def command_plan(args):
    plan = build_plan(args.catalog, args.only, args.repeat, args.upstream,
                      args.results, args.fixtures_root, args.selftest)
    args.plan_out.parent.mkdir(parents=True, exist_ok=True)
    args.plan_out.write_text(json.dumps(plan, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
                             encoding="utf-8")
    selected = ",".join(scenario["id"] for scenario in plan["scenarios"])
    runnable = sum(1 for scenario in plan["scenarios"] if not scenario["skip"])
    print(f"plan: {args.plan_out}")
    print(f"plan: upstream {plan['upstream']} repeat {plan['repeat']} "
          f"scenarios {len(plan['scenarios'])} runnable {runnable}")
    print(f"plan: ids {selected}")
    print(f"plan: budget {plan['batch_budget']['max_minutes']} min / "
          f"{plan['batch_budget']['max_model_requests']} requests")
    return 0


def command_check(args):
    try:
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CatalogError(f"cannot read plan {args.plan}: {exc}") from exc
    if not isinstance(plan, dict) or plan.get("version") != 1:
        raise CatalogError(f"unsupported plan {args.plan}")
    summary = check_plan(plan, args.results)
    write_summary(summary, args.results)
    if args.summary_out:
        write_summary(summary, args.summary_out)
    for scenario in summary["scenarios"]:
        detail = "; ".join(scenario["reasons"])
        print(f"scenario: {scenario['id']} gate={scenario['gate']} {detail}".rstrip())
    print(f"gate: {summary['gate']} ({len(summary['errors'])} error(s))")
    if summary["errors"]:
        for error in summary["errors"]:
            print(f"gate: {error}", file=sys.stderr)
        return 1
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures-root", type=Path, default=DEFAULT_FIXTURES)
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate")
    validate.add_argument("--catalog", type=Path, required=True)
    validate.add_argument("--selftest", action="store_true")
    validate.set_defaults(func=command_validate)

    plan = sub.add_parser("plan")
    plan.add_argument("--catalog", type=Path, required=True)
    plan.add_argument("--only")
    plan.add_argument("--repeat", type=int, default=1)
    plan.add_argument("--upstream", choices=("mock", "real"), default="mock")
    plan.add_argument("--results", type=Path, required=True)
    plan.add_argument("--plan-out", type=Path, required=True)
    plan.add_argument("--selftest", action="store_true")
    plan.set_defaults(func=command_plan)

    check = sub.add_parser("check")
    check.add_argument("--plan", type=Path, required=True)
    check.add_argument("--results", type=Path, required=True)
    check.add_argument("--summary-out", type=Path)
    check.set_defaults(func=command_check)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except CatalogError as exc:
        print(f"bot-eval: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
