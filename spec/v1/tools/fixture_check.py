#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validator for the language-neutral perturbation and mock-upstream fixtures.

The two fixture families under ``spec/v1/golden/`` are the machine-readable form of the kill-replay
matrix and of the mock-upstream script model: a runner that has never read the Swift tree can
implement the assertions from them. This tool validates the fixtures and nothing else; it is
independent of the Swift code base and only uses the JSON Schema validator of ``spec_golden.py``
(``validate_json``), so a schema fix lands in one place.

It checks, for every fixture:

* the file is valid JSON with no duplicate member names and validates against its schema;
* the file name equals the fixture ``id``, and every ``id`` is unique across both families;
* the ``at`` column is a logical clock (integer, non-decreasing, starting at 0, bounded by one
  hour), never a wall-clock timestamp;
* the perturbed state, the expected state and every intermediate state are D14 states;
* ``expected`` carries at least one assertion a machine can decide (a member that is neither
  absent nor ``unmeasured``) and every asserted member has an evidence entry. Both schemas already
  force one decidable member (the perturbation ``state`` and the upstream ``retry`` object), so this
  is the semantic backstop for a relaxed schema;
* ``evidence_level`` is the weakest evidence of the asserted members, so a fixture cannot claim
  stronger evidence than one of its own assertions;
* the cross-field laws of the two formats (settlement reason, tail shape, durability level, body
  framing, retry budget, truncation).

Usage:
    python3 spec/v1/tools/fixture_check.py [--root DIR]

``--root`` is the repository root (default: the parent of ``spec/v1``). Exit code 0 on success,
1 on any fixture failure, 2 on a usage or I/O error.
"""

from __future__ import annotations

import argparse
import collections
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from spec_golden import SpecError, load_json, validate_json  # noqa: E402

PERTURBATION_DIR = Path("golden") / "perturbations"
UPSTREAM_DIR = Path("golden") / "upstream"
PERTURBATION_SCHEMA = Path("schema") / "perturbation.schema.json"
UPSTREAM_SCHEMA = Path("schema") / "upstream-script.schema.json"

# budgets.md section 1: the host is always in exactly one of these states.
STATES = (
    "Running",
    "Draining",
    "Parked",
    "Recovering",
    "Backoff",
    "HandingOff",
    "Remote",
    "Reclaiming",
    "Failed",
)

# The perturbation verb table. The ten required verbs are the Android port's kill matrix; the
# eleventh covers the terminal stop seal, which is a teardown failure rather than a kill.
REQUIRED_VERBS = (
    "kill_9",
    "sigterm",
    "drain_timeout",
    "system_reclaim",
    "power_loss_torn_tail",
    "renderer_terminate",
    "force_stop_zero_callback",
    "planned_restart",
    "cold_start_after_reboot",
    "write_without_ack",
)
VERBS = REQUIRED_VERBS + ("stop_seal_failure",)

# Evidence strength, weakest last: evidence_level must be the weakest entry of field_evidence.
EVIDENCE = {"swift-test": 0, "swift-source": 1, "spec-only": 2, "NEW": 3}
UNMEASURED = "unmeasured"

PERTURBATION_ASSERTIONS = (
    "state",
    "state_path",
    "durability_level",
    "wal_tail",
    "journal_gap",
    "surfaced_to_user",
    "admission",
    "acked_prefix_preserved",
    "unacked_records_retained",
    "truncated_torn_tail",
    "materialized_equals_replay",
    "steps_open",
    "steps_abandoned",
    "settlement_reason",
    "late_completion_does_not_advance",
    "no_drain_before_kill",
    "worker_rehello",
    "boot_disposition",
    "fence_and_lifecycle_resent",
)
UPSTREAM_ASSERTIONS = (
    "caller_visible",
    "retry",
    "provider_error",
    "delivery_error",
    "response_log",
    "client_outcome",
)

# ModelGatewayConfiguration.standardModelEndpoints: the POST paths that are replay-safe.
MODEL_ENDPOINTS = ("/v1/messages", "/messages", "/v1/chat/completions", "/chat/completions")

# One hour of logical milliseconds. A wall-clock millisecond value cannot pass this bound.
MAX_LOGICAL_MS = 3600000


class Result:
    """Collected rows, failures and coverage counters for one run."""

    def __init__(self) -> None:
        self.rows = []
        self.errors = []
        self.verbs = collections.OrderedDict((verb, 0) for verb in VERBS)
        self.caller_visible = collections.OrderedDict()
        self.count = 0

    def ok(self, rel: str, detail: str) -> None:
        self.rows.append((rel, "ok", detail))

    def fail(self, rel: str, problems) -> None:
        self.rows.append((rel, "FAIL", ""))
        for problem in problems:
            self.errors.append((rel, problem))

    def emit(self) -> int:
        for rel, status, detail in self.rows:
            if status == "ok":
                print("ok {} ({})".format(rel, detail))
            else:
                print("FAIL {}".format(rel))
        for rel, problem in self.errors:
            if problem.startswith(rel + ":"):
                print("  " + problem)
            else:
                print("  {}: {}".format(rel, problem))
        self.print_coverage()
        print("{} fixture(s) checked, {} error(s)".format(self.count, len(self.errors)))
        return 1 if self.errors else 0

    def print_coverage(self) -> None:
        print("coverage matrix: perturbation verb x fixture count")
        missing = []
        width = max(len(verb) for verb in self.verbs)
        for verb, count in self.verbs.items():
            state = "covered" if count else "MISSING"
            if not count and verb in REQUIRED_VERBS:
                missing.append(verb)
            print("  {:<{width}}  {:>2}  {}".format(verb, count, state, width=width))
        required_missing = [verb for verb in REQUIRED_VERBS if not self.verbs[verb]]
        if required_missing:
            print("  missing required verb(s): {}".format(", ".join(required_missing)))
        else:
            print("  all {} required verb(s) covered".format(len(REQUIRED_VERBS)))
        if self.caller_visible:
            print("upstream coverage: caller_visible x fixture count")
            for kind, count in sorted(self.caller_visible.items()):
                print("  {}  {}".format(kind, count))


# ---------------------------------------------------------------------------
# Shared checks.
# ---------------------------------------------------------------------------


def check_timeline(doc, problems) -> None:
    timeline = doc.get("timeline")
    if not isinstance(timeline, list) or not timeline:
        problems.append("timeline is empty")
        return
    previous = None
    for index, step in enumerate(timeline):
        if not isinstance(step, dict):
            problems.append("timeline[{}] is not an object".format(index))
            continue
        at = step.get("at")
        if not isinstance(at, int) or isinstance(at, bool):
            problems.append("timeline[{}].at is not an integer logical tick".format(index))
            continue
        if at < 0 or at > MAX_LOGICAL_MS:
            problems.append(
                "timeline[{}].at {} is outside the logical clock range 0..{}".format(
                    index, at, MAX_LOGICAL_MS
                )
            )
        if index == 0 and at != 0:
            problems.append("timeline starts at at={} instead of 0".format(at))
        if previous is not None and at < previous:
            problems.append("timeline[{}].at {} goes backwards from {}".format(index, at, previous))
        previous = at


def check_evidence(doc, assertion_fields, problems) -> int:
    """Validate the expected members, their evidence and the weakest-evidence law.

    Returns the number of asserted members (the machine-decidable ones).
    """

    expected = doc.get("expected")
    if not isinstance(expected, dict):
        problems.append("expected is not an object")
        return 0
    evidence = expected.get("field_evidence", {})
    if not isinstance(evidence, dict):
        problems.append("expected.field_evidence is not an object")
        evidence = {}
    asserted = [
        name
        for name in assertion_fields
        if name in expected and expected[name] != UNMEASURED
    ]
    if not asserted:
        problems.append(
            "expected has no machine-checkable assertion: every member is absent or "
            "\"unmeasured\""
        )
    for name in asserted:
        if name not in evidence:
            problems.append("expected.{} has no field_evidence entry".format(name))
    for name in sorted(evidence):
        if name not in assertion_fields:
            problems.append("field_evidence names unknown member {!r}".format(name))
            continue
        if name not in expected:
            problems.append("field_evidence names expected.{} but expected does not set it".format(name))
            continue
        if expected[name] == UNMEASURED:
            problems.append(
                "expected.{} is \"unmeasured\" but field_evidence claims {}".format(
                    name, evidence[name]
                )
            )
    graded = [evidence[name] for name in asserted if name in evidence]
    if graded:
        weakest = max(graded, key=lambda value: EVIDENCE[value])
        if doc.get("evidence_level") != weakest:
            problems.append(
                "evidence_level {!r} is not the weakest asserted evidence {!r}".format(
                    doc.get("evidence_level"), weakest
                )
            )
    level = doc.get("evidence_level")
    if level == "NEW" and not doc.get("new_reason"):
        problems.append("evidence_level is NEW but new_reason is missing")
    if level != "NEW" and doc.get("new_reason"):
        problems.append("new_reason is only meaningful with evidence_level NEW")
    if doc.get("source") == "NEW" and level != "NEW":
        problems.append("source is NEW but evidence_level is {}".format(level))
    return len(asserted)


def check_admission_law(host_state, admission, where, problems) -> None:
    """budgets.md section 1: admission is open only in Running."""

    if admission == "open" and host_state != "Running":
        problems.append(
            "{}: admission open in state {} contradicts budgets.md section 1".format(
                where, host_state
            )
        )
    if admission == "closed" and host_state == "Running":
        problems.append(
            "{}: admission closed in Running contradicts budgets.md section 1".format(where)
        )


# ---------------------------------------------------------------------------
# Perturbation fixtures.
# ---------------------------------------------------------------------------


def check_perturbation(doc, rel, schema, result) -> None:
    result.count += 1
    problems = []
    try:
        validate_json(doc, schema, rel)
    except SpecError as exc:
        result.fail(rel, [str(exc)])
        return

    fixture_id = doc["id"]
    if rel.stem != fixture_id:
        problems.append("file name {!r} does not equal id {!r}".format(rel.stem, fixture_id))

    preconditions = doc["preconditions"]
    check_timeline(doc, problems)
    for index, step in enumerate(doc.get("timeline", [])):
        if isinstance(step, dict) and "expect_state" in step:
            if step["expect_state"] not in STATES:
                problems.append("timeline[{}].expect_state is not a D14 state".format(index))
    if preconditions.get("host_state") not in STATES:
        problems.append("preconditions.host_state is not a D14 state")
    else:
        check_admission_law(
            preconditions["host_state"], preconditions.get("admission"), "preconditions", problems
        )
    if preconditions.get("persisted_state") not in list(STATES) + ["absent"]:
        problems.append("preconditions.persisted_state is not a D14 state or \"absent\"")
    if preconditions.get("exec_in_flight") and not preconditions.get("open_steps", 1):
        problems.append("preconditions.exec_in_flight requires at least one open step")

    expected = doc["expected"]
    asserted = check_evidence(doc, PERTURBATION_ASSERTIONS, problems)

    path = expected.get("state_path")
    if isinstance(path, list) and path:
        if path[-1] != expected["state"]:
            problems.append(
                "state_path ends with {!r} but expected.state is {!r}".format(
                    path[-1], expected["state"]
                )
            )
        if expected["state"] not in path:
            problems.append("state_path does not contain expected.state")
    if "admission" in expected and expected["admission"] != UNMEASURED:
        check_admission_law(expected["state"], expected["admission"], "expected", problems)

    durability = expected["durability_level"]
    tail = expected["wal_tail"]
    if tail == "closed_epoch" and durability != "level_2":
        problems.append("wal_tail closed_epoch requires durability_level level_2")
    if durability == "level_2" and tail != "closed_epoch":
        problems.append("durability_level level_2 requires wal_tail closed_epoch")
    if durability == "level_1" and tail not in (
        "intact_open_epoch",
        "truncated_to_last_complete",
        "unchanged",
    ):
        problems.append("durability_level level_1 cannot be asserted with wal_tail {}".format(tail))
    truncated = expected.get("truncated_torn_tail")
    if truncated is True and tail != "truncated_to_last_complete":
        problems.append("truncated_torn_tail true requires wal_tail truncated_to_last_complete")
    if tail == "truncated_to_last_complete" and truncated is not True:
        problems.append("wal_tail truncated_to_last_complete requires truncated_torn_tail true")

    journal_gap = expected["journal_gap"]
    reason = expected.get("settlement_reason")
    if journal_gap == "step_abandoned":
        if reason not in ("worker-terminated", "planned-restart"):
            problems.append(
                "journal_gap step_abandoned requires a settlement_reason of worker-terminated "
                "or planned-restart"
            )
    elif reason in ("worker-terminated", "planned-restart"):
        problems.append("a settlement reason requires journal_gap step_abandoned")
    if journal_gap == "none" and "steps_open" in expected:
        before = preconditions.get("open_steps", 0)
        if expected["steps_open"] != before:
            problems.append(
                "journal_gap none leaves the journal unchanged: steps_open {} does not match the "
                "{} open step(s) of the preconditions".format(expected["steps_open"], before)
            )
    if journal_gap == "step_open" and expected.get("steps_open", 0) < 1:
        problems.append("journal_gap step_open requires at least one open step")
    if journal_gap in ("step_abandoned", "step_reconciled") and expected.get("steps_open", 0) != 0:
        problems.append("journal_gap {} requires steps_open 0".format(journal_gap))
    if journal_gap == "step_abandoned" and expected.get("steps_abandoned", 0) < 1:
        problems.append("journal_gap step_abandoned requires at least one abandoned step")
    if journal_gap == "step_reconciled" and expected.get("steps_abandoned", 0) != 0:
        problems.append("journal_gap step_reconciled requires steps_abandoned 0")
    for name in ("steps_open", "steps_abandoned"):
        if name in expected and expected[name] == UNMEASURED:
            problems.append("expected.{} must be an integer or absent, not unmeasured".format(name))

    if problems:
        result.fail(rel, problems)
        return

    result.verbs[doc["verb"]] += 1
    result.ok(
        rel,
        "verb={}, assertions={}".format(doc["verb"], asserted),
    )


# ---------------------------------------------------------------------------
# Mock-upstream fixtures.
# ---------------------------------------------------------------------------


def body_bytes(event) -> int:
    return sum(len(chunk.encode("utf-8")) for chunk in event["body_chunks"])


def check_script_event(event, index, problems) -> None:
    where = "script[{}]".format(index)
    status = event["status"]
    chunks = event["body_chunks"]
    frames = event.get("frames", "chunked")
    closes = event["closes"]
    declared = event.get("declared_content_length")
    truncated = event.get("truncated")
    total = body_bytes(event)

    if status == 0:
        if chunks:
            problems.append("{}: status 0 (reset before the head) cannot carry body bytes".format(where))
        if event.get("headers"):
            problems.append("{}: status 0 cannot carry response headers".format(where))
        if "frames" in event or declared is not None:
            problems.append("{}: status 0 cannot declare a body framing".format(where))
        if event["closes"] is not True:
            problems.append("{}: status 0 resets the connection, so closes must be true".format(where))
        return

    if frames == "content_length":
        if declared is None:
            problems.append("{}: content_length framing requires declared_content_length".format(where))
        else:
            if declared < total:
                problems.append(
                    "{}: declared_content_length {} is shorter than the {} body bytes it frames".format(
                        where, declared, total
                    )
                )
            if declared > total and truncated is not True:
                problems.append(
                    "{}: a short body ({}/{} bytes) must be marked truncated".format(
                        where, total, declared
                    )
                )
            if declared == total and truncated is True:
                problems.append(
                    "{}: truncated is true but the body is complete ({} bytes)".format(where, total)
                )
    else:
        if declared is not None:
            problems.append("{}: declared_content_length requires frames content_length".format(where))

    if closes is False:
        if frames != "chunked":
            problems.append("{}: a held-open connection cannot use content_length framing".format(where))
        if "stall_after_bytes" not in event:
            problems.append("{}: closes false requires stall_after_bytes".format(where))
        if truncated is True:
            problems.append("{}: truncated and closes false are contradictory".format(where))
    else:
        if "stall_after_bytes" in event:
            problems.append("{}: stall_after_bytes requires closes false".format(where))

    stall = event.get("stall_after_bytes")
    if isinstance(stall, int) and stall > total:
        problems.append(
            "{}: stall_after_bytes {} exceeds the {} scripted body bytes".format(
                where, stall, total
            )
        )
    if event.get("malformed") and not chunks:
        problems.append("{}: malformed needs body bytes to be malformed".format(where))


def check_upstream(doc, rel, schema, result) -> None:
    result.count += 1
    problems = []
    try:
        validate_json(doc, schema, rel)
    except SpecError as exc:
        result.fail(rel, [str(exc)])
        return

    fixture_id = doc["id"]
    if rel.stem != fixture_id:
        problems.append("file name {!r} does not equal id {!r}".format(rel.stem, fixture_id))

    match = doc["request_match"]
    if not any(match["path_suffix"].endswith(endpoint) for endpoint in MODEL_ENDPOINTS):
        problems.append(
            "request_match.path_suffix {!r} is not a replay-safe model endpoint".format(
                match["path_suffix"]
            )
        )

    for index, event in enumerate(doc["script"]):
        check_script_event(event, index, problems)

    expected = doc["expected"]
    asserted = check_evidence(doc, UPSTREAM_ASSERTIONS, problems)

    retry = expected["retry"]
    attempts = retry["attempts"]
    if retry["retried"] and attempts < 2:
        problems.append("retry.retried is true with attempts {}".format(attempts))
    if not retry["retried"] and attempts != 1:
        problems.append("retry.retried is false with attempts {}".format(attempts))
    delays = retry.get("delays_ms")
    if delays is not None and len(delays) != attempts - 1:
        problems.append(
            "retry.delays_ms has {} entries for {} attempts, expected {}".format(
                len(delays), attempts, attempts - 1
            )
        )
    trigger = retry.get("trigger")
    if trigger == "none" and retry["retried"]:
        problems.append("retry.trigger none contradicts retried true")
    if trigger in ("upstream_status", "transport_before_head", "budget_exhausted") and not retry["retried"]:
        problems.append("retry.trigger {} contradicts retried false".format(trigger))

    visible = expected["caller_visible"]
    provider = expected["provider_error"]
    if visible == "truncated_stream_then_error" and provider not in ("transport_failure", UNMEASURED):
        problems.append(
            "caller_visible truncated_stream_then_error requires provider_error transport_failure"
        )
    last = doc["script"][-1]
    if visible == "final_status_and_body":
        if not retry["retried"]:
            problems.append("caller_visible final_status_and_body requires a retry")
        if last["status"] == 0 or not 200 <= last["status"] <= 299:
            problems.append(
                "caller_visible final_status_and_body requires a 2xx last scripted response"
            )
    if visible == "error_without_body" and provider in ("none", UNMEASURED):
        problems.append("caller_visible error_without_body requires a provider_error cause")
    if visible == "delivery_timeout" and expected.get("delivery_error") != "PDSH_DELIVERY_TIMEOUT":
        problems.append(
            "caller_visible delivery_timeout requires delivery_error PDSH_DELIVERY_TIMEOUT"
        )
    if visible == "unmeasured" and provider != UNMEASURED:
        problems.append("caller_visible unmeasured requires provider_error unmeasured")

    if problems:
        result.fail(rel, problems)
        return

    result.caller_visible[visible] = result.caller_visible.get(visible, 0) + 1
    result.ok(rel, "attempts={}, assertions={}".format(attempts, asserted))


# ---------------------------------------------------------------------------
# Tree walk.
# ---------------------------------------------------------------------------


def load_schema(path):
    try:
        schema = load_json(path)
    except SpecError as exc:
        raise SystemExit("fixture_check: cannot read schema {}: {}".format(path, exc))
    if not isinstance(schema, dict):
        raise SystemExit("fixture_check: schema {} is not an object".format(path))
    return schema


def run(root: Path) -> Result:
    root = Path(root)
    spec_dir = root / "spec" / "v1"
    if not spec_dir.is_dir():
        raise SystemExit("fixture_check: {} is not a spec root".format(spec_dir))
    perturbation_schema = load_schema(spec_dir / PERTURBATION_SCHEMA)
    upstream_schema = load_schema(spec_dir / UPSTREAM_SCHEMA)

    result = Result()
    perturbation_dir = spec_dir / PERTURBATION_DIR
    upstream_dir = spec_dir / UPSTREAM_DIR
    perturbation_paths = sorted(perturbation_dir.glob("*.json")) if perturbation_dir.is_dir() else []
    upstream_paths = sorted(upstream_dir.glob("*.json")) if upstream_dir.is_dir() else []
    if not perturbation_paths:
        result.errors.append(("spec/v1/golden/perturbations", "no perturbation fixture found"))
    if not upstream_paths:
        result.errors.append(("spec/v1/golden/upstream", "no upstream fixture found"))

    documents = collections.OrderedDict()
    for path in perturbation_paths + upstream_paths:
        rel = str(path.relative_to(root))
        try:
            doc = load_json(path)
        except SpecError as exc:
            documents[rel] = None
            result.fail(rel, [str(exc)])
            continue
        if not isinstance(doc, dict):
            documents[rel] = None
            result.fail(rel, ["fixture is not a JSON object"])
            continue
        documents[rel] = doc

    seen = {}
    for rel, doc in documents.items():
        if doc is None:
            continue
        fixture_id = doc.get("id")
        if fixture_id in seen:
            result.errors.append(
                (rel, "id {!r} is already used by {}".format(fixture_id, seen[fixture_id]))
            )
        else:
            seen[fixture_id] = rel

    for path in perturbation_paths:
        rel = str(path.relative_to(root))
        doc = documents.get(rel)
        if doc is not None:
            check_perturbation(doc, path.relative_to(root), perturbation_schema, result)
    for path in upstream_paths:
        rel = str(path.relative_to(root))
        doc = documents.get(rel)
        if doc is not None:
            check_upstream(doc, path.relative_to(root), upstream_schema, result)

    for verb in REQUIRED_VERBS:
        if not result.verbs[verb]:
            result.errors.append(
                ("spec/v1/golden/perturbations", "required verb {!r} is not covered".format(verb))
            )
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="phone-dsh fixture checker")
    parser.add_argument(
        "--root",
        type=Path,
        default=TOOLS_DIR.parents[2],
        help="repository root (default: the directory that contains spec/v1)",
    )
    args = parser.parse_args(argv)
    try:
        result = run(args.root.resolve())
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2
    return result.emit()


if __name__ == "__main__":
    sys.exit(main())
