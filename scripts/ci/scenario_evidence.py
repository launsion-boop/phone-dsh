#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Attempt history, capability index and evidence verification for G2 runs.

The scenario runners write one mutable ``<results>/<id>/`` directory per
scenario.  That directory is convenient for a single run but destructive on a
rerun: the Swift runner deletes its own artifacts in ``prepareDirectories`` and
the simulator driver used to delete the whole directory before pulling new
results.  This module adds the missing staging lifecycle around those writes:

* ``archive`` moves the current attempt's evidence into
  ``<results>/<id>/history/a<NNN>/`` and freezes its status, usage and judge
  snapshot in ``attempt.json`` before a rerun can overwrite it;
* ``clear-current`` removes only the mutable current artifacts, never
  ``history/`` or the index;
* ``archive`` also updates the capability index before it moves anything, so an
  early exit (a failed build or a runner that never writes a report) can never
  leave ``current`` pointing at a report that is no longer there;
* ``finalize`` repairs a missing ``.git`` from ``workspace.tar`` (G2-FIX-110),
  records ``staging_repairs`` and the attempt snapshot in ``report.json``, and
  refreshes ``<results>/.capability-index.json`` from the current report;
* ``verify`` checks the selected scenario's terminal evidence and writes
  ``evidence_missing.json`` instead of letting an incomplete TIMEOUT/abort pass
  silently (G2-FIX-128). A JSON document that is not a valid scenario report
  (non-object, unknown status, missing required fields) is a structure error,
  never an ``UNKNOWN`` pass.

Attempt numbers come from the index's persistent ``next_attempt`` counter, not
from the archived directories, so deleting old ``history/a<NNN>`` entries can
never make the next run reuse a number. Only relative paths, status, usage and a
redacted judge snapshot are written to the index; no credentials and no host
absolute paths are stored.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import posixpath
import re
import shutil
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

VERSION = 1
INDEX_NAME = ".capability-index.json"
INDEX_LOCK_NAME = ".capability-index.lock"
HISTORY_NAME = "history"
ATTEMPT_PATTERN = re.compile(r"^a([0-9]{3,})$")
SCENARIO_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

# Current artifacts owned by one run.  ``history`` is deliberately absent.
CURRENT_ARTIFACTS = (
    "report.json",
    "transcript.jsonl",
    "workspace.tar",
    "host",
    "scratch",
    "check-workspace",
    "bodies",
    "scenario.json",
    "judge.json",
    "judge.md",
    "evidence_missing.json",
)

COMMON_REQUIRED = ("report.json", "transcript.jsonl")
DEFERRED_STATUSES = {"SKIP", "INFRA"}
REPORT_STRUCTURE_CODE = "REPORT_STRUCTURE"

# The report shape the Swift runner writes (and the simulator host phase
# rewrites).  Keeping the required set here means every consumer -- verify,
# finalize, index refresh and the batch report check -- rejects the same
# malformed document instead of letting an unknown status through as UNKNOWN.
REPORT_STATUSES = frozenset(
    {"PASS", "FAIL", "TIMEOUT", "BUDGET", "ERROR", "SKIP", "INFRA", "PENDING_HOST"}
)
REPORT_REQUIRED_FIELDS = (
    "id",
    "status",
    "assertions",
    "turns",
    "perturbations",
    "usage",
    "console_errors",
    "host_states",
)
REPORT_LIST_FIELDS = (
    "assertions",
    "turns",
    "perturbations",
    "console_errors",
    "host_states",
)
REPORT_OBJECT_FIELDS = ("usage",)

# Capability-index ``current`` states.  ``ARCHIVED`` points at the frozen
# attempt (whose report exists); ``CLEARED`` deliberately has no report path.
CURRENT_STATE_CURRENT = "CURRENT"
CURRENT_STATE_PENDING = "PENDING"
CURRENT_STATE_ARCHIVED = "ARCHIVED"
CURRENT_STATE_CLEARED = "CLEARED"

HOST_REQUIRED = (
    "host/materialized/workspace",
    "host/wal",
    "host/journal.xljournal",
    "host/response-log",
    "host/fence.json",
)
HOST_DIRECTORIES = {
    "host/materialized/workspace",
    "host/wal",
    "host/response-log",
}

HOST_PATH_RE = re.compile(
    r"(?<![\w.-])/(?:Users|home|private|var/folders|tmp|work|root)/[^\s\"'`<>),;\]]*"
)
SECRET_RE = re.compile(r"sk-[A-Za-z0-9]{8,}")
BEARER_RE = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{8,}")


class EvidenceError(RuntimeError):
    """A fail-loud evidence error with an optional stable code."""

    def __init__(self, message, code="EVIDENCE", missing=None):
        super().__init__(message)
        self.code = code
        self.missing = list(missing or [])


# --------------------------------------------------------------------- basics


def utcnow():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def validate_scenario_id(scenario_id):
    """Return a path-safe scenario id or raise ``ValueError``.

    Mirrors the Swift runner's rule plus the no-``.``/``..`` guard: the id is
    the only untrusted component joined under ``--results``.
    """

    if not isinstance(scenario_id, str) or not SCENARIO_ID_PATTERN.fullmatch(scenario_id):
        raise ValueError("scenario id is not path-safe: {!r}".format(scenario_id))
    if scenario_id in (".", ".."):
        raise ValueError("scenario id is not path-safe: {!r}".format(scenario_id))
    return scenario_id


def scenario_paths(results_root, scenario_id):
    validate_scenario_id(scenario_id)
    root = Path(results_root).resolve()
    directory = root / scenario_id
    return {
        "root": root,
        "directory": directory,
        "history": directory / HISTORY_NAME,
        "index": root / INDEX_NAME,
    }


def relative_to_results(results_root, path):
    """A POSIX relative path from ``results_root``; rejects escapes."""

    root = Path(results_root).resolve()
    candidate = Path(path).resolve()
    try:
        relative = candidate.relative_to(root)
    except ValueError as exc:
        raise EvidenceError(
            "evidence path escapes the results directory: {}".format(path)
        ) from exc
    return relative.as_posix()


def _read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def _read_json_optional(path):
    try:
        return _read_json(path), None
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as exc:
        return None, str(exc)


def _assertion_is_pass(assertion):
    """The shared Worker/host rule: NOT_EXECUTED and pending_host never pass."""

    return (
        isinstance(assertion, dict)
        and assertion.get("status") not in ("NOT_EXECUTED", "pending_host")
        and assertion.get("ok") is True
    )


INCOMPLETE_RUN_STATUSES = frozenset({"TIMEOUT", "BUDGET", "ERROR", "INFRA"})


def _turn_has_ended(turn):
    """The Swift gate's terminal-turn fact: a non-empty string ``ended``."""

    ended = turn.get("ended")
    return isinstance(ended, str) and bool(ended.strip())


def _run_completion_errors(report):
    """Why the report's own facts say the run did not complete.

    A current report carries the runner-computed ``run_completed`` fact.  A
    legacy report without it is reconstructed from its terminal status and
    turns, exactly like ``ScenarioRunCompletion.from`` in the Swift gate; a
    missing field is never an assumed completion.  A failed assertion verdict
    is not here: ``FAIL`` is decided after the run completed.
    """

    if not isinstance(report, dict):
        return []
    problems = []
    recorded = report.get("run_incomplete_reason")
    if report.get("run_completed") is False:
        detail = "run_completed is false"
        if isinstance(recorded, str) and recorded.strip():
            detail += " ({})".format(recorded.strip())
        problems.append(detail)
        return problems
    status = report.get("status")
    if isinstance(status, str) and status in INCOMPLETE_RUN_STATUSES:
        problems.append("the run ended with status {}".format(status))
    turns = report.get("turns")
    if isinstance(turns, list):
        turn_objects = [turn for turn in turns if isinstance(turn, dict)]
        undelivered = sum(
            1 for turn in turn_objects if turn.get("delivered") is False
        )
        if undelivered:
            problems.append(
                "{} scenario turn(s) were not delivered".format(undelivered)
            )
        delivered = [
            turn for turn in turn_objects if turn.get("delivered") is not False
        ]
        open_turns = sum(1 for turn in delivered if not _turn_has_ended(turn))
        if open_turns:
            problems.append(
                "{} delivered turn(s) have no terminal turn/end (ended is null)".format(
                    open_turns
                )
            )
        terminal = [
            turn["terminal_reason"]
            for turn in delivered
            if isinstance(turn.get("terminal_reason"), str)
            and turn["terminal_reason"].strip()
            and turn["terminal_reason"] != "completed"
        ]
        if terminal:
            unique = sorted(set(terminal))
            problems.append(
                "{} delivered turn(s) ended with terminal reason(s): {}".format(
                    len(terminal), ", ".join(unique)
                )
            )
    if isinstance(recorded, str) and recorded.strip():
        problems.append(
            "the report records run_incomplete_reason: {}".format(recorded.strip())
        )
    return problems


def _pass_contradiction_errors(report):
    """A PASS label must not stand over a non-passing assertion or run.

    The Swift writer derives PASS only when every assertion passed and the run
    completed.  An older or forged report can still claim PASS beside an
    explicit NOT_EXECUTED, a pending host evaluation, ``ok: false`` or an
    incomplete run (notably a cached Worker PASS followed by a failed
    ``host.stop()``).  That contradiction is a report structure error, so
    ``verify`` and ``report-check`` fail closed together instead of counting
    the document as a passing result.
    """

    if report.get("status") != "PASS":
        return []
    errors = []
    completion_errors = _run_completion_errors(report)
    if completion_errors:
        errors.append(
            "report.json status PASS has an incomplete run: {}".format(
                "; ".join(completion_errors)
            )
        )
    assertions = report.get("assertions")
    if not isinstance(assertions, list):
        return errors
    for index, assertion in enumerate(assertions):
        if not isinstance(assertion, dict):
            continue
        status = assertion.get("status")
        if status == "NOT_EXECUTED":
            errors.append(
                "report.json status PASS has assertion {} NOT_EXECUTED "
                "(NOT_EXECUTED is not a pass)".format(index)
            )
        elif status == "pending_host":
            errors.append(
                "report.json status PASS has assertion {} pending_host".format(index)
            )
        elif assertion.get("ok") is not True:
            errors.append(
                "report.json status PASS has assertion {} not ok".format(index)
            )
    return errors


def _effective_report_status(report):
    """Return the status a PASS report's own assertions can support.

    Non-PASS statuses are run-level verdicts (TIMEOUT/BUDGET/ERROR/SKIP/INFRA)
    and keep their label.  A PASS is trusted only when every assertion is a
    completed pass; otherwise the effective verdict is FAIL.  ``check_reports``
    uses this instead of the raw label so a stale PASS cannot select exit 0.
    """

    status = report.get("status", "UNKNOWN") if isinstance(report, dict) else "UNKNOWN"
    if status != "PASS":
        return status
    if _run_completion_errors(report):
        return "FAIL"
    assertions = report.get("assertions")
    if not isinstance(assertions, list):
        return status
    if all(_assertion_is_pass(item) for item in assertions):
        return status
    return "FAIL"


def report_structure_errors(report, expected_id=None):
    """Return why a report document is not a valid scenario result.

    A syntactically valid JSON ``[]``, ``null`` or string is a failed report,
    not a report whose status happens to be unknown.  The same applies to an
    invented status or to a missing field the report check and the host phase
    rely on, so every caller fails closed instead of treating ``UNKNOWN`` as a
    pass.  When ``expected_id`` is given, the document's ``id`` must name that
    scenario; a report written for another id cannot certify this one.
    """

    if not isinstance(report, dict):
        return [
            "report.json is not a JSON object (got {})".format(
                type(report).__name__
            )
        ]

    errors = []
    for field in REPORT_REQUIRED_FIELDS:
        if field not in report:
            errors.append(
                "report.json is missing required field: {}".format(field)
            )
    identifier = report.get("id")
    if "id" in report and (
        not isinstance(identifier, str) or not identifier.strip()
    ):
        errors.append("report.json field 'id' is not a non-empty string")
    elif expected_id is not None and identifier != expected_id:
        errors.append(
            "report.json id {!r} does not match scenario directory {!r}".format(
                identifier, expected_id
            )
        )
    status = report.get("status")
    if "status" in report:
        if not isinstance(status, str):
            errors.append("report.json field 'status' is not a string")
        elif status not in REPORT_STATUSES:
            errors.append(
                "report.json has unknown status: {!r}".format(status)
            )
    for field in REPORT_LIST_FIELDS:
        if field in report and not isinstance(report[field], list):
            errors.append(
                "report.json field '{}' is not a list".format(field)
            )
    for field in REPORT_OBJECT_FIELDS:
        if field in report and not isinstance(report[field], dict):
            errors.append(
                "report.json field '{}' is not an object".format(field)
            )
    nested_objects = {"assertions", "turns", "perturbations"}
    nested_strings = {"console_errors", "host_states"}
    for field in nested_objects | nested_strings:
        values = report.get(field)
        if not isinstance(values, list):
            continue
        for index, item in enumerate(values):
            if field in nested_objects and not isinstance(item, dict):
                errors.append(
                    "report.json {} item {} is not an object".format(field, index)
                )
                continue
            if field in nested_strings and not isinstance(item, str):
                errors.append(
                    "report.json {} item {} is not a string".format(field, index)
                )
                continue
            if field == "assertions":
                if "ok" not in item or not isinstance(item.get("ok"), bool):
                    errors.append(
                        "report.json assertion {} field 'ok' is not a boolean".format(
                            index
                        )
                    )
                errors.extend(_worker_command_errors(
                    item,
                    index,
                    expected_id if isinstance(expected_id, str) and expected_id
                    else report.get("id"),
                ))
    errors.extend(_pass_contradiction_errors(report))
    return errors


WORKER_COMMAND_RECEIPT = "pdsh-worker-command/1"


def _is_int(value):
    """JSON integer, excluding Python's boolean subclass of int."""

    return isinstance(value, int) and not isinstance(value, bool)


def _worker_command_errors(assertion, index, expected_scenario_id=None):
    """Validate the evidence a `worker_command` assertion must carry.

    A Worker assertion is not host acceptance: its receipt proves the command
    ran on the live Worker's immutable VFS fork, with no model request and no
    live-workspace or journal side effect. `NOT_EXECUTED` is the only state
    that may omit a receipt (the run did not complete, so no Worker observation
    exists). That state is never a pass: it must say ``ok: false``, must not
    claim ``worker_evaluated`` and must not retain a receipt from an earlier
    evaluation (the completion gate drops the cached observation).

    Receipt authenticity and the scenario outcome are separate facts. A failed
    execution (non-zero exit, timeout or cancellation) must be reported as a
    scenario failure (`ok: false`); only that inconsistency is a structure
    error, so an expected TIMEOUT/FAIL report keeps its complete evidence.
    """

    if assertion.get("type") != "worker_command":
        return []
    prefix = "report.json assertion {} (worker_command)".format(index)
    if assertion.get("status") == "NOT_EXECUTED":
        errors = []
        if assertion.get("ok") is not False:
            errors.append(prefix + " NOT_EXECUTED must be ok:false")
        worker_evaluated = assertion.get("worker_evaluated")
        if worker_evaluated is not None and worker_evaluated is not False:
            errors.append(prefix + " NOT_EXECUTED must not be worker_evaluated")
        if assertion.get("worker_receipt") is not None:
            errors.append(prefix + " NOT_EXECUTED must not retain a worker_receipt")
        return errors
    errors = []
    if assertion.get("worker_evaluated") is not True:
        errors.append(prefix + " has no worker_evaluated: true")
    receipt = assertion.get("worker_receipt")
    if not isinstance(receipt, dict):
        errors.append(prefix + " has no worker_receipt object")
        return errors
    if receipt.get("protocol") != WORKER_COMMAND_RECEIPT:
        errors.append(prefix + " receipt protocol is not " + WORKER_COMMAND_RECEIPT)
    location = receipt.get("location")
    if not isinstance(location, dict):
        errors.append(prefix + " receipt has no location object")
    else:
        if location.get("kind") != "worker":
            errors.append(prefix + " receipt location.kind is not worker")
        # A desktop/Node simulation reports `surface-process`; only the live
        # Worker's ordered channel may certify a Worker acceptance.
        if location.get("carrier") != "ordered-channel":
            errors.append(prefix + " receipt location.carrier is not ordered-channel")
        if location.get("worker_vfs") is not True:
            errors.append(prefix + " receipt location.worker_vfs is not true")
        if location.get("host_process") is not False:
            errors.append(prefix + " receipt location.host_process is not false")
        if location.get("fork") != "memory-vfs":
            errors.append(prefix + " receipt location.fork is not memory-vfs")
    source = receipt.get("source")
    if not isinstance(source, dict):
        errors.append(prefix + " receipt has no source object")
    else:
        if source.get("kind") != "worker-vfs-fork" or source.get("fork") is not True:
            errors.append(prefix + " receipt source is not an immutable Worker VFS fork")
        if not isinstance(source.get("digest"), str) or not source.get("digest"):
            errors.append(prefix + " receipt source has no digest")
        mseq_start = source.get("source_mseq_start")
        mseq_end = source.get("source_mseq_end")
        mseq_valid = True
        for field, value in (("source_mseq_start", mseq_start),
                             ("source_mseq_end", mseq_end)):
            if not _is_int(value) or value < 0:
                errors.append(prefix + " receipt source.{} is missing".format(field))
                mseq_valid = False
        if source.get("source_frozen") is not True:
            errors.append(prefix + " receipt source.source_frozen is not true")
        missing_roots = source.get("missing_roots")
        if (not isinstance(missing_roots, list)
                or any(not isinstance(path, str) or not path for path in missing_roots)):
            errors.append(prefix + " receipt source.missing_roots is missing or malformed")
        elif missing_roots:
            errors.append(prefix + " receipt source.missing_roots is not empty: "
                          + ", ".join(missing_roots))
        if mseq_valid and mseq_start != mseq_end:
            errors.append(prefix + " receipt source mseq is not one frozen watermark")
        missing_roots = source.get("missing_roots")
        if not isinstance(missing_roots, list):
            errors.append(prefix + " receipt source.missing_roots is not a string array")
        elif not all(isinstance(root, str) and root for root in missing_roots):
            errors.append(prefix + " receipt source.missing_roots is not a string array")
        elif missing_roots:
            errors.append(
                prefix + " receipt source.missing_roots is not empty: "
                + ", ".join(missing_roots)
            )
    binding = receipt.get("binding")
    if not isinstance(binding, dict):
        errors.append(prefix + " receipt has no binding object")
    else:
        if binding.get("assertion_index") != index:
            errors.append(prefix + " receipt assertion_index does not match")
        for field in ("scenario_id", "session_id"):
            if not isinstance(binding.get(field), str) or not binding.get(field):
                errors.append(prefix + " receipt binding.{} is missing".format(field))
        if (isinstance(expected_scenario_id, str) and expected_scenario_id
                and binding.get("scenario_id") != expected_scenario_id):
            errors.append(prefix + " receipt binding.scenario_id does not match the report id")
        if not _is_int(binding.get("turn")) or binding.get("turn") < 0:
            errors.append(prefix + " receipt binding.turn is missing")
        watermark = binding.get("completion_watermark")
        if not _is_int(watermark) or watermark < 0:
            errors.append(prefix + " receipt binding.completion_watermark is missing")
    if receipt.get("model_requests") != 0:
        errors.append(prefix + " receipt model_requests is not 0")
    if receipt.get("live_workspace_unchanged") is not True:
        errors.append(prefix + " receipt live_workspace_unchanged is not true")
    execution = receipt.get("execution")
    if not isinstance(execution, dict):
        errors.append(prefix + " receipt has no execution object")
    else:
        for field in ("program", "cwd"):
            if not isinstance(execution.get(field), str) or not execution.get(field):
                errors.append(prefix + " receipt execution.{} is missing".format(field))
        for field in ("exit_code", "budget_ms", "duration_ms"):
            if not _is_int(execution.get(field)):
                errors.append(prefix + " receipt execution.{} is not an integer".format(field))
        if _is_int(execution.get("budget_ms")) and execution["budget_ms"] <= 0:
            errors.append(prefix + " receipt execution.budget_ms is not positive")
        for field in ("timed_out", "cancelled"):
            if not isinstance(execution.get(field), bool):
                errors.append(prefix + " receipt execution.{} is not a boolean".format(field))
        for field in ("stdout", "stderr"):
            if not isinstance(execution.get(field), str):
                errors.append(prefix + " receipt execution.{} is not a string".format(field))
        # The receipt must match the assertion's explicit request facts. New
        # reports carry all three; older reports without them still get the
        # receipt's own type checks above.
        for field in ("program", "cwd"):
            declared = assertion.get(field)
            if declared is not None:
                if not isinstance(declared, str) or not declared:
                    errors.append(prefix + " assertion {} is not a string".format(field))
                elif execution.get(field) != declared:
                    errors.append(
                        prefix + " receipt execution.{} {!r} does not match assertion {} {!r}".format(
                            field, execution.get(field), field, declared
                        )
                    )
        declared_budget = assertion.get("timeout_ms")
        if declared_budget is not None:
            if not _is_int(declared_budget) or declared_budget <= 0:
                errors.append(prefix + " assertion timeout_ms is not a positive integer")
            elif execution.get("budget_ms") != declared_budget:
                errors.append(
                    prefix + " receipt execution.budget_ms {!r} does not match assertion timeout_ms {!r}".format(
                        execution.get("budget_ms"), declared_budget
                    )
                )
        failed_execution = (
            (_is_int(execution.get("exit_code")) and execution["exit_code"] != 0)
            or execution.get("timed_out") is True
            or execution.get("cancelled") is True
        )
        if failed_execution and assertion.get("ok") is True:
            errors.append(
                prefix + " marks a failed execution ok:true "
                "(exit_code={!r}, timed_out={!r}, cancelled={!r})".format(
                    execution.get("exit_code"),
                    execution.get("timed_out"),
                    execution.get("cancelled"),
                )
            )
    side_effects = receipt.get("side_effects")
    if not isinstance(side_effects, dict):
        errors.append(prefix + " receipt has no side_effects object")
    else:
        if side_effects.get("isolated") is not True:
            errors.append(prefix + " receipt side_effects.isolated is not true")
        if side_effects.get("live_workspace") is not False:
            errors.append(prefix + " receipt side_effects.live_workspace is not false")
        if side_effects.get("journal") is not False:
            errors.append(prefix + " receipt side_effects.journal is not false")
    return errors


def _write_json_atomic(path, document):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=str(path.parent), prefix=path.name + ".", delete=False
    )
    temporary = Path(handle.name)
    try:
        with handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _path_exists(path):
    return os.path.lexists(str(path))


@contextlib.contextmanager
def _index_lock(results_root):
    """Serialize the read/modify/write of the shared index across lanes."""

    path = Path(results_root) / INDEX_LOCK_NAME
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        try:
            import fcntl

            fcntl.flock(descriptor, fcntl.LOCK_EX)
        except (ImportError, OSError):
            pass
        yield
    finally:
        os.close(descriptor)


def _sanitize(value):
    """Strip credentials and host absolute paths from an index snapshot."""

    if isinstance(value, str):
        value = SECRET_RE.sub("<redacted>", value)
        value = BEARER_RE.sub("Bearer <redacted>", value)
        return HOST_PATH_RE.sub("<host-path>", value)
    if isinstance(value, list):
        return [_sanitize(item) for item in value]
    if isinstance(value, dict):
        return {_sanitize(key): _sanitize(item) for key, item in value.items()}
    return value


def _judge_snapshot(scenario_directory, report):
    """The judge output for this attempt, if the batch orchestrator wrote one."""

    judge_path = scenario_directory / "judge.json"
    if judge_path.is_file():
        document, error = _read_json_optional(judge_path)
        if error is None:
            return _sanitize(document)
    if isinstance(report, dict) and "judge" in report:
        return _sanitize(report["judge"])
    return None


def _usage_snapshot(report):
    if isinstance(report, dict):
        usage = report.get("usage")
        if isinstance(usage, dict):
            return _sanitize(usage)
    return {}


def _status_snapshot(report):
    if isinstance(report, dict) and isinstance(report.get("status"), str):
        return report["status"]
    return "UNKNOWN"


# --------------------------------------------------------------- attempt dirs


def next_attempt_number(history_directory, minimum=1):
    """First unused ``a<NNN>`` at or above ``minimum``.

    The archive command no longer uses this as its allocator: the persistent
    index counter owns attempt numbers so that deleting history cannot restart
    the sequence.  It remains the directory-collision guard for callers that
    need one, and it still never reuses an existing archive directory.
    """

    history_directory = Path(history_directory)
    highest = 0
    try:
        entries = list(history_directory.iterdir())
    except FileNotFoundError:
        entries = []
    for entry in entries:
        match = ATTEMPT_PATTERN.match(entry.name)
        if match and entry.is_dir():
            highest = max(highest, int(match.group(1)))
    return max(highest + 1, int(minimum or 1))


def _matching_item_names(scenario_directory):
    return [name for name in CURRENT_ARTIFACTS if _path_exists(scenario_directory / name)]


def _history_numbers(results_root, scenario_id):
    """Every ``a<NNN>`` directory, including a partially written archive."""

    history = scenario_paths(results_root, scenario_id)["history"]
    numbers = set()
    try:
        entries = list(history.iterdir())
    except FileNotFoundError:
        entries = []
    for entry in entries:
        match = ATTEMPT_PATTERN.match(entry.name)
        if match and entry.is_dir():
            numbers.add(int(match.group(1)))
    return numbers


def _scenario_entry(index, scenario_id):
    entry = index["scenarios"].get(scenario_id)
    if not isinstance(entry, dict):
        entry = {}
    if not isinstance(entry.get("attempts"), list):
        entry["attempts"] = []
    index["scenarios"][scenario_id] = entry
    return entry


def _next_attempt_value(entry, attempts, history_numbers=None):
    """The smallest safe number for a *new* attempt.

    The persistent ``next_attempt`` counter is authoritative.  History and the
    current attempt only raise it for indexes written before the counter
    existed, so GC of ``history/`` cannot lower it.
    """

    values = [1]
    counter = entry.get("next_attempt")
    if isinstance(counter, int) and counter > 0:
        values.append(counter)
    values.append(max((item.get("attempt", 0) for item in attempts), default=0) + 1)
    if history_numbers:
        values.append(max(history_numbers, default=0) + 1)
    current = entry.get("current")
    if isinstance(current, dict):
        number = current.get("attempt")
        if isinstance(number, int) and number > 0:
            values.append(number + 1)
    return max(values)


def _allocate_current_attempt_number(entry, attempts, report):
    """Number a fresh current report without reusing an archived attempt."""

    next_value = _next_attempt_value(entry, attempts)
    current = entry.get("current")
    current_number = (
        current.get("attempt")
        if isinstance(current, dict)
        and current.get("state") == CURRENT_STATE_CURRENT
        and isinstance(current.get("attempt"), int)
        and current["attempt"] > 0
        else None
    )
    report_number = None
    if isinstance(report, dict):
        candidate = report.get("attempt")
        if isinstance(candidate, int) and candidate > 0:
            report_number = candidate
    if current_number is not None:
        # A repeated finalize of the same report keeps its number.
        return current_number
    if report_number is not None and report_number >= next_value:
        # The report was numbered by a finalize whose index write did not land;
        # keep that explicit number instead of allocating a second one.
        return report_number
    return next_value


def _base_current_paths(results_root, paths):
    return {
        "directory": relative_to_results(results_root, paths["directory"]),
        "history": relative_to_results(results_root, paths["history"]),
        "index": relative_to_results(results_root, paths["index"]),
    }


def _existing_artifact_paths(results_root, directory, artifact_keys):
    result = {}
    for name, key in artifact_keys.items():
        target = directory / name
        if _path_exists(target):
            result[key] = relative_to_results(results_root, target)
    return result


def _resolve_index_path(results_root, value):
    """Resolve a relative index path, rejecting anything outside the results."""

    if not isinstance(value, (str, os.PathLike)):
        return None
    text = os.fspath(value)
    if not text:
        return None
    try:
        candidate = (Path(results_root) / text).resolve()
        relative_to_results(results_root, candidate)
    except (OSError, ValueError, EvidenceError):
        return None
    return candidate


def _archived_attempt_directory(results_root, paths, current):
    """The frozen ``history/a<NNN>`` directory an ARCHIVED pointer describes.

    Older indexes stored the live ``<results>/<id>`` as ``paths.directory`` even
    in the ARCHIVED state.  The frozen attempt is the parent of the existing
    ``paths.report`` (``history/a<NNN>/report.json``), so prefer that and use a
    frozen ``paths.directory`` only as the fallback.
    """

    if not isinstance(current, dict):
        return None
    current_paths = current.get("paths")
    if not isinstance(current_paths, dict):
        return None
    live_directory = paths["directory"].resolve()
    history_directory = paths["history"].resolve()
    candidates = []
    report = current_paths.get("report")
    if isinstance(report, str):
        candidates.append(Path(report).parent)
    directory = current_paths.get("directory")
    if isinstance(directory, str):
        candidates.append(Path(directory))
    for candidate in candidates:
        resolved = _resolve_index_path(results_root, candidate)
        if resolved is None or resolved == live_directory:
            continue
        if resolved.parent != history_directory:
            continue
        if not ATTEMPT_PATTERN.match(resolved.name) or not resolved.is_dir():
            continue
        return resolved
    return None


ARTIFACT_KEYS = {
    "report.json": "report",
    "transcript.jsonl": "transcript",
    "workspace.tar": "workspace_tar",
    "host": "host",
    "scratch": "scratch",
    "check-workspace": "check_workspace",
    "bodies": "bodies",
    "scenario.json": "scenario",
    "judge.json": "judge",
    "judge.md": "judge_markdown",
    "evidence_missing.json": "evidence_missing",
}


def _current_report_snapshot(results_root, paths, report):
    current_paths = _base_current_paths(results_root, paths)
    current_paths.update(
        _existing_artifact_paths(
            results_root,
            paths["directory"],
            ARTIFACT_KEYS,
        )
    )
    return {
        "state": CURRENT_STATE_CURRENT,
        "attempt": None,
        "status": _status_snapshot(report),
        "usage": _usage_snapshot(report),
        "judge": _judge_snapshot(paths["directory"], report),
        "paths": current_paths,
        "archived_at": None,
    }


def _archived_current(results_root, paths, record, attempt_directory=None):
    if attempt_directory is None:
        attempt_directory = paths["root"] / record["paths"]["directory"]
    current_paths = _base_current_paths(results_root, paths)
    # ARCHIVED is self-describing: ``paths.directory`` is the frozen attempt,
    # not the live scenario directory.  A later finalize with no new report can
    # then keep pointing at history/a<NNN> even if older indexes only retained
    # the frozen report path.
    current_paths["directory"] = relative_to_results(
        results_root, attempt_directory
    )
    current = {
        "state": CURRENT_STATE_ARCHIVED,
        "attempt": record["attempt"],
        "status": record.get("status", "UNKNOWN"),
        "usage": _sanitize(record.get("usage") or {}),
        "judge": _sanitize(record.get("judge")),
        "paths": current_paths,
        "archived_at": record.get("archived_at"),
    }
    for name, key in ARTIFACT_KEYS.items():
        target = attempt_directory / name
        if _path_exists(target):
            current["paths"][key] = relative_to_results(results_root, target)
    return current


def _refreshed_archived_current(results_root, paths, current):
    """Refresh an ARCHIVED pointer, or return ``None`` if its report is gone."""

    attempt_directory = _archived_attempt_directory(results_root, paths, current)
    if attempt_directory is None:
        return None
    if not (attempt_directory / "report.json").is_file():
        return None
    number = current.get("attempt") if isinstance(current, dict) else None
    if not isinstance(number, int) or number <= 0:
        match = ATTEMPT_PATTERN.match(attempt_directory.name)
        number = int(match.group(1)) if match else 0
    return _archived_current(
        results_root,
        paths,
        {
            "attempt": number,
            "status": current.get("status", "UNKNOWN"),
            "usage": current.get("usage") or {},
            "judge": current.get("judge"),
            "archived_at": current.get("archived_at"),
            "paths": {
                "directory": relative_to_results(
                    results_root, attempt_directory
                )
            },
        },
        attempt_directory=attempt_directory,
    )


def _cleared_current(results_root, paths, previous_current=None, attempts=None):
    number = 0
    if isinstance(previous_current, dict):
        candidate = previous_current.get("attempt")
        if isinstance(candidate, int) and candidate > 0:
            number = candidate
    if not number and attempts:
        number = max((item.get("attempt", 0) for item in attempts), default=0)
    return {
        "state": CURRENT_STATE_CLEARED,
        "attempt": number,
        "status": "UNKNOWN",
        "usage": {},
        "judge": None,
        "paths": _base_current_paths(results_root, paths),
        "archived_at": None,
    }


def _pending_current(results_root, paths, previous_current=None, attempts=None):
    """A safe pre-deletion marker with no artifact (especially report) paths."""

    current = _cleared_current(results_root, paths, previous_current, attempts)
    current["state"] = CURRENT_STATE_PENDING
    return current


def archive_attempt(results_root, scenario_id, source=None):
    """Freeze the current attempt under ``history/a<NNN>/``.

    Returns the attempt record, or ``None`` when there is nothing to archive.
    A new attempt directory is created with ``mkdir`` (never reused), so an
    existing archive can never be overwritten by a concurrent or repeated call.

    The index is switched to ``PENDING`` *before* the report moves and to
    ``ARCHIVED`` only once the frozen report exists, so an early exit between
    those steps leaves no ``current`` path pointing at a non-existent report.
    """

    paths = scenario_paths(results_root, scenario_id)
    directory = paths["directory"]
    if not directory.is_dir():
        return None
    present = _matching_item_names(directory)
    if not present:
        return None

    report_path = directory / "report.json"
    report, report_error = _read_json_optional(report_path)
    status = _status_snapshot(report)
    usage = _usage_snapshot(report)
    judge = _judge_snapshot(directory, report)
    report_errors = (
        report_structure_errors(report, expected_id=scenario_id)
        if report is not None or report_path.exists()
        else []
    )
    if report_errors:
        # Preserve malformed evidence for diagnosis, but never publish its
        # embedded PASS/FAIL as the archived attempt's verdict.
        status = "UNKNOWN"
    archived_at = utcnow()

    history = paths["history"]
    history.mkdir(parents=True, exist_ok=True)
    history_numbers = _history_numbers(results_root, scenario_id)

    with _index_lock(paths["root"]):
        index = _load_index(paths["root"])
        entry = _scenario_entry(index, scenario_id)
        attempts = _attempt_entries(results_root, scenario_id)
        next_value = _next_attempt_value(entry, attempts, history_numbers)

        current = entry.get("current")
        current_number = (
            current.get("attempt")
            if isinstance(current, dict)
            and current.get("state") == CURRENT_STATE_CURRENT
            and isinstance(current.get("attempt"), int)
            and current["attempt"] > 0
            else None
        )
        report_number = None
        if isinstance(report, dict):
            candidate = report.get("attempt")
            if isinstance(candidate, int) and candidate > 0:
                report_number = candidate
        if current_number is not None:
            number = current_number
        elif report_number is not None and report_number >= next_value:
            number = report_number
        else:
            number = next_value
        while (history / "a{:03d}".format(number)).exists():
            number += 1

        entry["current"] = {
            "state": CURRENT_STATE_PENDING,
            "attempt": number,
            "status": "UNKNOWN",
            "usage": {},
            "judge": None,
            "paths": _base_current_paths(results_root, paths),
            "archived_at": None,
        }
        entry["attempts"] = attempts
        entry["next_attempt"] = max(
            int(entry.get("next_attempt") or 1), number + 1
        )
        index["version"] = VERSION
        index["updated_at"] = utcnow()
        _write_json_atomic(paths["index"], _sanitize(index))

        attempt_directory = history / "a{:03d}".format(number)
        attempt_directory.mkdir()

        moved = []
        for name in present:
            source_path = directory / name
            destination = attempt_directory / name
            shutil.move(str(source_path), str(destination))
            moved.append(name)

        attempt_report, attempt_report_error = _read_json_optional(
            attempt_directory / "report.json"
        )
        if attempt_report is not None:
            status = _status_snapshot(attempt_report)
            usage = _usage_snapshot(attempt_report)
            judge = _judge_snapshot(attempt_directory, attempt_report)
            report_errors = report_structure_errors(
                attempt_report, expected_id=scenario_id
            )
            if report_errors:
                status = "UNKNOWN"

        record = {
            "version": VERSION,
            "scenario": scenario_id,
            "attempt": number,
            "status": status,
            "usage": usage,
            "judge": judge,
            "archived_at": archived_at,
            "source": source,
            "paths": {
                "directory": relative_to_results(results_root, attempt_directory),
                **{
                    ARTIFACT_KEYS.get(name, name): relative_to_results(
                        results_root, attempt_directory / name
                    )
                    for name in moved
                },
            },
        }
        if report_error or attempt_report_error:
            record["report_error"] = report_error or attempt_report_error
        elif not (attempt_directory / "report.json").is_file():
            record["report_error"] = "report.json is missing from archived attempt"
        if report_errors:
            record["report_errors"] = list(report_errors)
        _write_json_atomic(attempt_directory / "attempt.json", record)

        # Re-read the index inside the same lock: the PENDING marker was
        # already persisted, and this second write is the atomic hand-off to
        # the frozen attempt whose report now exists.
        index = _load_index(paths["root"])
        entry = _scenario_entry(index, scenario_id)
        attempts = _attempt_entries(results_root, scenario_id)
        if (attempt_directory / "report.json").is_file():
            entry["current"] = _archived_current(
                results_root, paths, record, attempt_directory=attempt_directory
            )
        else:
            # Partial artifacts are preserved as history for diagnosis, but an
            # ARCHIVED current pointer means a frozen report is available.
            # Keep the monotonic attempt number without publishing a report
            # path that does not exist.
            entry["current"] = _cleared_current(
                results_root, paths, entry.get("current"), attempts
            )
        entry["attempts"] = attempts
        entry["next_attempt"] = max(
            int(entry.get("next_attempt") or 1), number + 1
        )
        index["version"] = VERSION
        index["updated_at"] = utcnow()
        _write_json_atomic(paths["index"], _sanitize(index))
    return record


def clear_current(results_root, scenario_id):
    """Remove only mutable current artifacts, preserving history and index.

    A safe ``PENDING`` marker with no artifact paths is persisted *before* the
    first ``unlink``/``rmtree`` and ``CLEARED`` only after the removal, so an
    interrupted clear can never leave ``current.paths.report`` pointing at a
    deleted live report.  An ``ARCHIVED`` pointer is refreshed from its frozen
    ``history/a<NNN>`` directory; if garbage collection removed that report, the
    stale artifact entries are dropped and the state becomes ``CLEARED``.
    """

    paths = scenario_paths(results_root, scenario_id)
    directory = paths["directory"]
    index_exists = paths["index"].is_file()
    history_exists = paths["history"].is_dir()
    if not directory.is_dir() and not index_exists and not history_exists:
        return []

    removed = []
    with _index_lock(paths["root"]):
        index = _load_index(paths["root"])
        entry = _scenario_entry(index, scenario_id)
        attempts = _attempt_entries(results_root, scenario_id)
        current = entry.get("current")
        if (
            isinstance(current, dict)
            and current.get("state") == CURRENT_STATE_ARCHIVED
        ):
            refreshed = _refreshed_archived_current(
                results_root, paths, current
            )
            entry["current"] = (
                refreshed
                if refreshed is not None
                else _cleared_current(results_root, paths, current, attempts)
            )
        else:
            entry["current"] = _pending_current(
                results_root, paths, current, attempts
            )
        entry["attempts"] = attempts
        entry["next_attempt"] = max(
            int(entry.get("next_attempt") or 1),
            _next_attempt_value(entry, attempts),
        )
        index["version"] = VERSION
        index["updated_at"] = utcnow()
        _write_json_atomic(paths["index"], _sanitize(index))

        if directory.is_dir():
            for name in CURRENT_ARTIFACTS:
                target = directory / name
                if not _path_exists(target):
                    continue
                if target.is_dir() and not target.is_symlink():
                    shutil.rmtree(target)
                else:
                    target.unlink()
                removed.append(name)

        index = _load_index(paths["root"])
        entry = _scenario_entry(index, scenario_id)
        attempts = _attempt_entries(results_root, scenario_id)
        current = entry.get("current")
        if (
            isinstance(current, dict)
            and current.get("state") == CURRENT_STATE_ARCHIVED
        ):
            refreshed = _refreshed_archived_current(
                results_root, paths, current
            )
            entry["current"] = (
                refreshed
                if refreshed is not None
                else _cleared_current(results_root, paths, current, attempts)
            )
        else:
            entry["current"] = _cleared_current(
                results_root, paths, current, attempts
            )
        entry["attempts"] = attempts
        entry["next_attempt"] = max(
            int(entry.get("next_attempt") or 1),
            _next_attempt_value(entry, attempts),
        )
        index["version"] = VERSION
        index["updated_at"] = utcnow()
        _write_json_atomic(paths["index"], _sanitize(index))
    return removed


def _attempt_entries(results_root, scenario_id):
    """Read frozen attempt records from ``history/`` (never from the index)."""

    paths = scenario_paths(results_root, scenario_id)
    history = paths["history"]
    entries = []
    try:
        candidates = sorted(history.iterdir())
    except FileNotFoundError:
        return entries
    for candidate in candidates:
        match = ATTEMPT_PATTERN.match(candidate.name)
        if not match or not candidate.is_dir():
            continue
        number = int(match.group(1))
        record, error = _read_json_optional(candidate / "attempt.json")
        if record is None:
            report, _report_error = _read_json_optional(candidate / "report.json")
            record = {
                "version": VERSION,
                "scenario": scenario_id,
                "attempt": number,
                "status": _status_snapshot(report),
                "usage": _usage_snapshot(report),
                "judge": _judge_snapshot(candidate, report),
                "archived_at": datetime.fromtimestamp(
                    candidate.stat().st_mtime, timezone.utc
                ).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            }
            if error:
                record["read_error"] = error
        entries.append(
            {
                "attempt": number,
                "status": record.get("status", "UNKNOWN"),
                "usage": _sanitize(record.get("usage") or {}),
                "judge": _sanitize(record.get("judge")),
                "archived_at": record.get("archived_at"),
                "path": relative_to_results(results_root, candidate),
            }
        )
    return entries


# ---------------------------------------------------------------- index/refresh


def _load_index(results_root):
    path = Path(results_root) / INDEX_NAME
    document, error = _read_json_optional(path)
    if not isinstance(document, dict):
        document = {}
    if not isinstance(document.get("scenarios"), dict):
        document["scenarios"] = {}
    document.setdefault("version", VERSION)
    return document


def _current_attempt_number(existing_index, scenario_id, attempts):
    """Compatibility wrapper for callers of the old allocator."""

    entry = existing_index.get("scenarios", {}).get(scenario_id, {})
    if not isinstance(entry, dict):
        entry = {}
    return _next_attempt_value(entry, attempts)


def refresh_index(results_root, scenario_id, staging_repairs=None):
    """Refresh the shared index (and the report attempt snapshot) from disk.

    A missing or structurally invalid report never becomes ``current``: a
    missing report leaves a safe ``CLEARED``/``ARCHIVED`` entry, and malformed
    JSON is a fail-loud structure error so the batch report check can return
    its own diagnostic exit code instead of a generic evidence failure.
    """

    paths = scenario_paths(results_root, scenario_id)
    directory = paths["directory"]
    report_path = directory / "report.json"

    with _index_lock(paths["root"]):
        report, report_error = _read_json_optional(report_path)
        if report_error:
            raise EvidenceError(
                "cannot read report.json: {}".format(report_error),
                code=REPORT_STRUCTURE_CODE,
            )
        if report is not None or report_path.exists():
            structure_errors = report_structure_errors(
                report, expected_id=scenario_id
            )
            if structure_errors:
                raise EvidenceError(
                    "; ".join(structure_errors), code=REPORT_STRUCTURE_CODE
                )
        index = _load_index(paths["root"])
        entry = _scenario_entry(index, scenario_id)
        attempts = _attempt_entries(results_root, scenario_id)

        if report is not None:
            number = _allocate_current_attempt_number(entry, attempts, report)
            history_numbers = _history_numbers(results_root, scenario_id)
            while number in history_numbers:
                number += 1
            current = _current_report_snapshot(results_root, paths, report)
            current["attempt"] = number
            status = current["status"]
            usage = current["usage"]
            judge = current["judge"]
            entry["current"] = current
            entry["next_attempt"] = max(
                int(entry.get("next_attempt") or 1), number + 1
            )
            report["attempt"] = number
            report["attempt_snapshot"] = {
                "number": number,
                "history": [item["path"] for item in attempts],
                "index": relative_to_results(results_root, paths["index"]),
            }
            if staging_repairs:
                report["staging_repairs"] = _sanitize(staging_repairs)
            _write_json_atomic(report_path, report)
        else:
            current = entry.get("current")
            refreshed = None
            if (
                isinstance(current, dict)
                and current.get("state") == CURRENT_STATE_ARCHIVED
            ):
                # Keep pointing at the frozen report, deriving its
                # history/a<NNN> parent from paths.report for older indexes.
                refreshed = _refreshed_archived_current(
                    results_root, paths, current
                )
            if refreshed is not None:
                current = refreshed
            else:
                # No live report and no surviving frozen report: never leave a
                # dangling artifact path behind.
                current = _cleared_current(
                    results_root, paths, current, attempts
                )
            entry["current"] = current
            status = _status_snapshot(None)
            usage = {}
            judge = None
            number = current.get("attempt", 0) if isinstance(current, dict) else 0
            entry["next_attempt"] = max(
                int(entry.get("next_attempt") or 1),
                _next_attempt_value(entry, attempts),
            )

        entry["attempts"] = attempts
        index["version"] = VERSION
        index["updated_at"] = utcnow()
        _write_json_atomic(paths["index"], _sanitize(index))
        return {
            "scenario": scenario_id,
            "attempt": number,
            "status": status,
            "usage": usage,
            "judge": judge,
            "attempts": attempts,
            "staging_repairs": staging_repairs or [],
        }


# ------------------------------------------------------------------ git repair


def _git_required_from_scenario(results_root, scenario_id, fixtures_root=None):
    paths = scenario_paths(results_root, scenario_id)
    scenario, _error = _read_json_optional(paths["directory"] / "scenario.json")
    if not isinstance(scenario, dict):
        return False
    workspace = scenario.get("workspace")
    if not isinstance(workspace, dict):
        return False
    files = workspace.get("files")
    if isinstance(files, dict):
        for name in files:
            if name == ".git" or name.startswith(".git/"):
                return True
    fixture = workspace.get("fixture")
    if fixture:
        root = Path(fixtures_root) if fixtures_root else (
            Path(__file__).resolve().parent / "scenarios" / "fixtures"
        )
        spec, _spec_error = _read_json_optional(
            root / str(fixture) / "fixture.json"
        )
        if isinstance(spec, dict) and isinstance(spec.get("git"), dict):
            return True
    return False


def _normalized_member_name(name):
    value = name.replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    value = value.rstrip("/")
    if not value:
        return ""
    if value.startswith("/"):
        raise EvidenceError(
            "unsafe workspace.tar member (absolute path): {}".format(name),
            code="G2-FIX-110",
        )
    parts = [part for part in value.split("/") if part not in ("", ".")]
    if ".." in parts:
        raise EvidenceError(
            "unsafe workspace.tar member (parent traversal): {}".format(name),
            code="G2-FIX-110",
        )
    return "/".join(parts)


def _validate_link_target(member_name, linkname):
    if linkname.startswith("/"):
        raise EvidenceError(
            "unsafe workspace.tar symlink target: {} -> {}".format(member_name, linkname),
            code="G2-FIX-110",
        )
    base = posixpath.dirname(member_name) or "."
    target = posixpath.normpath(posixpath.join(base, linkname))
    if target != ".git" and not target.startswith(".git/"):
        raise EvidenceError(
            "unsafe workspace.tar symlink escapes .git: {} -> {}".format(
                member_name, linkname
            ),
            code="G2-FIX-110",
        )
    return target


def inspect_workspace_tar(tar_path):
    """Return ``(git_members, has_git)`` after validating every .git member.

    Member names are normalised; absolute paths, ``..`` traversal, hard links
    and escaping symlinks are rejected before anything is extracted.
    """

    try:
        archive = tarfile.open(tar_path, "r:*")
    except (OSError, tarfile.TarError) as exc:
        raise EvidenceError(
            "cannot read workspace.tar: {}".format(exc), code="G2-FIX-110"
        ) from exc
    members = []
    with archive:
        for member in archive.getmembers():
            normalized = _normalized_member_name(member.name)
            if not normalized:
                continue
            if normalized != ".git" and not normalized.startswith(".git/"):
                continue
            if normalized == ".git" and not member.isdir():
                raise EvidenceError(
                    "unsafe workspace.tar member (.git is not a directory): {}".format(
                        member.name
                    ),
                    code="G2-FIX-110",
                )
            if member.issym():
                _validate_link_target(normalized, member.linkname)
            elif member.islnk():
                raise EvidenceError(
                    "unsafe workspace.tar hard link in .git: {}".format(member.name),
                    code="G2-FIX-110",
                )
            elif not (member.isfile() or member.isdir()):
                raise EvidenceError(
                    "unsafe workspace.tar member type in .git: {}".format(member.name),
                    code="G2-FIX-110",
                )
            members.append((normalized, member))
    return members, bool(members)


def _extract_git_tree(tar_path, target_directory):
    """Extract only ``.git`` from a validated tar into a fresh directory."""

    target_directory = Path(target_directory)
    parent = target_directory.parent
    parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=".git-restore-", dir=str(parent)))
    try:
        with tarfile.open(tar_path, "r:*") as archive:
            by_name = {member.name: member for member in archive.getmembers()}
            git_members, _has_git = inspect_workspace_tar(tar_path)
            for normalized, member in git_members:
                original = by_name[member.name]
                relative = normalized[len(".git"):].lstrip("/")
                if not relative:
                    continue
                destination = temp / relative
                if original.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                if original.issym():
                    _validate_link_target(normalized, original.linkname)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    os.symlink(original.linkname, destination)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                extracted = archive.extractfile(original)
                if extracted is None:
                    raise EvidenceError(
                        "workspace.tar .git member has no body: {}".format(original.name),
                        code="G2-FIX-110",
                    )
                with open(destination, "wb") as handle:
                    shutil.copyfileobj(extracted, handle)
                os.chmod(destination, original.mode & 0o777)
        if _path_exists(target_directory):
            shutil.rmtree(temp)
            return False
        os.replace(temp, target_directory)
        return True
    finally:
        if temp.exists():
            shutil.rmtree(temp, ignore_errors=True)


def reconcile_workspace_git(
    results_root, scenario_id, fixtures_root=None, require_git=None
):
    """Repair a pulled materialized/check tree that lost ``.git`` (G2-FIX-110).

    The tar is the evidence of record.  When it contains ``.git`` but a pulled
    tree does not, only ``.git`` is extracted there; non-``.git`` files are never
    overwritten.  When ``.git`` is expected (a git fixture or explicit
    ``require_git``) and neither the tar nor the materialized tree has it, the
    run fails loud instead of inventing a history.
    """

    paths = scenario_paths(results_root, scenario_id)
    directory = paths["directory"]
    if require_git is None:
        report, _report_error = _read_json_optional(directory / "report.json")
        if _status_snapshot(report) in DEFERRED_STATUSES:
            return []
        require_git = _git_required_from_scenario(results_root, scenario_id, fixtures_root)

    tar_path = directory / "workspace.tar"
    materialized = directory / "host" / "materialized" / "workspace"
    check_workspace = directory / "check-workspace"
    materialized_has_git = _path_exists(materialized / ".git")
    check_has_git = _path_exists(check_workspace / ".git")
    check_exists = check_workspace.is_dir()

    if not tar_path.is_file():
        if require_git or materialized_has_git or check_has_git:
            raise EvidenceError(
                "G2-FIX-110: workspace.tar is missing, so a materialized .git "
                "cannot be reconciled",
                code="G2-FIX-110",
                missing=["workspace.tar"],
            )
        return []

    git_members, tar_has_git = inspect_workspace_tar(tar_path)
    if not tar_has_git:
        if require_git or materialized_has_git or check_has_git:
            raise EvidenceError(
                "G2-FIX-110: workspace.tar and host/materialized/workspace both "
                "lack .git; refusing to fabricate git history",
                code="G2-FIX-110",
            )
        return []

    repairs = []
    targets = []
    if materialized.is_dir() and not materialized_has_git:
        targets.append((materialized, "host/materialized/workspace"))
    if check_exists and not check_has_git:
        targets.append((check_workspace, "check-workspace"))
    for target, label in targets:
        if _extract_git_tree(tar_path, target / ".git"):
            repairs.append(
                {
                    "artifact": "{}/.git".format(label),
                    "source": "workspace.tar",
                    "reason": "pulled tree lost .git; restored only .git from the "
                    "workspace archive (G2-FIX-110)",
                    "members": len(git_members),
                }
            )
    return repairs


# ------------------------------------------------------------------ verification


def _required_for_status(status):
    if status in DEFERRED_STATUSES:
        return list(COMMON_REQUIRED) + ["scenario.json"], True
    return list(COMMON_REQUIRED), False


def _check_path(directory, relative):
    target = directory / relative
    if relative in HOST_DIRECTORIES:
        return target.is_dir()
    return target.is_file()


def _evidence_exists(directory, relative):
    if relative == "host/overlay-*.tar":
        return any((directory / "host").glob("overlay-*.tar"))
    return _check_path(directory, relative)


def verify_scenario(
    results_root, scenario_id, fixtures_root=None, require_git=None, reconcile=True
):
    """Check one scenario's terminal evidence and write evidence_missing.json.

    Returns a result dict with ``ok``, ``missing``, ``not_applicable`` and
    ``staging_repairs``.  A missing or invalid artifact is never treated as a
    pass, and the function does not create placeholder evidence.
    """

    paths = scenario_paths(results_root, scenario_id)
    directory = paths["directory"]
    report_path = directory / "report.json"
    report, report_error = _read_json_optional(report_path)
    status = _status_snapshot(report)
    structure_errors = []
    if report_error:
        structure_errors.append("cannot read report.json: {}".format(report_error))
    elif report is not None or report_path.exists():
        structure_errors = report_structure_errors(
            report, expected_id=scenario_id
        )
    required, deferred = _required_for_status(status)
    required = list(required)
    if structure_errors:
        # Never negotiate a smaller evidence set because the document was
        # malformed; the normal terminal set still has to be present, and the
        # structure errors alone already make this fail closed.
        required = list(COMMON_REQUIRED) + list(HOST_REQUIRED)
        required.extend(("host/overlay-*.tar", "workspace.tar"))
        deferred = False
    elif not deferred:
        required.extend(HOST_REQUIRED)
        required.append("host/overlay-*.tar")
        required.append("workspace.tar")

    missing = []
    not_applicable = {}
    staging_repairs = []
    errors = list(structure_errors)
    if report is None and not report_path.exists():
        missing.append("report.json")

    if deferred:
        reason = "{} runs carry report/transcript/scenario evidence only".format(status)
        for artifact in HOST_REQUIRED + ("host/overlay-*.tar", "workspace.tar"):
            not_applicable[artifact] = reason

    if reconcile and isinstance(report, dict) and not structure_errors and not deferred:
        try:
            staging_repairs = reconcile_workspace_git(
                results_root, scenario_id, fixtures_root=fixtures_root, require_git=require_git
            )
        except EvidenceError as exc:
            errors.append(str(exc))
            missing.extend(exc.missing)
            if exc.code == "G2-FIX-110":
                not_applicable.setdefault("git", "G2-FIX-110: {}".format(exc))

    for relative in required:
        if relative == "report.json" and report is None:
            continue
        if not _evidence_exists(directory, relative):
            missing.append(relative)

    missing = sorted(set(missing))
    result = {
        "version": VERSION,
        "scenario": scenario_id,
        "status": status,
        "ok": not missing and not errors,
        "missing": missing,
        "required": sorted(set(required)),
        "not_applicable": not_applicable,
        "staging_repairs": staging_repairs,
        "checked_at": utcnow(),
    }
    if structure_errors:
        result["code"] = REPORT_STRUCTURE_CODE
        result["errors"] = errors
    elif errors:
        result["errors"] = errors

    missing_path = directory / "evidence_missing.json"
    if result["ok"]:
        if missing_path.exists():
            missing_path.unlink()
    else:
        _write_json_atomic(missing_path, result)
    return result


# --------------------------------------------------------------- report check


def _expected_report_ids(catalog, only="", tag="", target=""):
    wanted = {item.strip() for item in (only or "").split(",") if item.strip()}
    expected = []
    scenarios = catalog.get("scenarios", []) if isinstance(catalog, dict) else []
    if not isinstance(scenarios, list):
        return expected
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            continue
        scenario_id = scenario.get("id")
        if not isinstance(scenario_id, str) or not scenario_id:
            continue
        if wanted and scenario_id not in wanted:
            continue
        if tag and tag not in (scenario.get("tags") or []):
            continue
        if target == "macos" and scenario.get("target") == "sim":
            continue
        if target == "sim" and scenario.get("target") == "macos":
            continue
        expected.append(scenario_id)
    return expected


def check_reports(catalog_path, results_path, only="", tag="", target=""):
    """Return ``(exit_code, lines)`` for the batch report gate.

    Exit 4 means the selected result tree is structurally unusable (missing or
    unreadable report, non-object JSON, unknown status, missing required
    field); exit 5 is a real scenario verdict (FAIL/TIMEOUT/BUDGET/ERROR or an
    un-finalized PENDING_HOST); exit 6 is runner-INFRA.  Keeping structure
    errors separate means a failed verify can no longer mask them as evidence
    exit 1.
    """

    lines = []
    try:
        catalog = json.loads(Path(catalog_path).read_text(encoding="utf-8"))
    except Exception as error:  # noqa: BLE001 - diagnostics only
        lines.append(
            "scenarios: FAIL: cannot read the catalog for the report check: "
            "{}".format(error)
        )
        return 4, lines
    if not isinstance(catalog, dict):
        lines.append(
            "scenarios: FAIL: catalog is not a JSON object: {}".format(catalog_path)
        )
        return 4, lines

    expected = _expected_report_ids(catalog, only, tag, target)
    root = Path(results_path)
    # Read exactly the selected scenario's own report path.  Scanning every
    # ``<results>/*/report.json`` let an unselected stale/bad report fail the
    # gate and let a report in another directory that merely claimed the id
    # stand in for a selected scenario that wrote nothing.
    reports = {}
    missing = []
    for scenario_id in expected:
        try:
            validate_scenario_id(scenario_id)
        except ValueError as error:
            lines.append(
                "scenarios: FAIL: invalid expected scenario id: {}".format(error)
            )
            return 4, lines
        report_path = root / scenario_id / "report.json"
        if not report_path.is_file():
            missing.append(scenario_id)
            continue
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
        except Exception as error:  # noqa: BLE001 - diagnostics only
            lines.append(
                "scenarios: FAIL: unreadable report {}: {}".format(
                    report_path, error
                )
            )
            return 4, lines
        structure_errors = report_structure_errors(report, expected_id=scenario_id)
        if structure_errors:
            lines.append(
                "scenarios: FAIL: invalid report {}: {}".format(
                    report_path, "; ".join(structure_errors)
                )
            )
            return 4, lines
        reports[scenario_id] = report

    for scenario_id in missing:
        lines.append(
            "scenarios: FAIL: {} was selected but wrote no report".format(
                scenario_id
            )
        )
    if missing:
        return 4, lines

    # Never let a raw PASS label select exit 0: the report's own assertions
    # must support it.  report_structure_errors already rejects the
    # contradiction; this keeps the final-status summary honest even if a
    # caller bypasses that check.
    statuses = {
        scenario_id: _effective_report_status(report)
        for scenario_id, report in reports.items()
    }

    if reports:
        lines.append("scenarios: reports")
        for scenario_id, report in reports.items():
            assertions = report.get("assertions", [])
            passed = sum(
                1 for item in assertions if _assertion_is_pass(item)
            )
            host_evaluated = sum(
                1 for item in assertions if item.get("host_evaluated")
            )
            worker_evaluated = sum(
                1 for item in assertions if item.get("worker_evaluated")
            )
            notes = []
            if host_evaluated:
                notes.append("{} host-evaluated".format(host_evaluated))
            if worker_evaluated:
                notes.append("{} worker-evaluated".format(worker_evaluated))
            note = ", " + ", ".join(notes) if notes else ""
            lines.append(
                "  {:<12} {:<12} {}/{} assertion(s){}".format(
                    scenario_id,
                    statuses[scenario_id],
                    passed,
                    len(assertions),
                    note,
                )
            )
        counts = {}
        for status in statuses.values():
            counts[status] = counts.get(status, 0) + 1
        summary = ", ".join(
            "{} {}".format(status, count)
            for status, count in sorted(counts.items())
        )
        lines.append(
            "scenarios: {} report(s): {}".format(len(reports), summary)
        )
    else:
        lines.append("scenarios: FAIL: no report.json was written")
        return 4, lines

    # The exit code follows the final status, not just report existence. SKIP is
    # a recorded environment deferral (locked Mac console) and keeps the existing
    # gate behaviour; a scenario verdict and an un-finalized PENDING_HOST report
    # fail the batch. INFRA (G2-FIX-65) is a runner-capability result, not a
    # product verdict: it fails the batch with its own message and its own exit
    # code so it is never read as a recovery failure.
    infra = {
        scenario_id: report
        for scenario_id, report in reports.items()
        if statuses[scenario_id] == "INFRA"
    }
    bad = {
        scenario_id: statuses[scenario_id]
        for scenario_id in reports
        if statuses[scenario_id] not in ("PASS", "SKIP", "INFRA")
    }
    if infra:
        lines.append(
            "scenarios: RUNNER-INFRA: the execution target cannot run these "
            "scenarios (no product verdict was produced):"
        )
        for scenario_id, report in sorted(infra.items()):
            detail = report.get("runner_infra")
            if not detail:
                details = [
                    "{}/{}: {}".format(
                        item.get("at"), item.get("kind"), item.get("detail", "")
                    )
                    for item in report.get("perturbations", [])
                    if item.get("status") == "runner_infra"
                ]
                detail = "; ".join(details) or "no runner-infra detail"
            lines.append("  {}: {}".format(scenario_id, detail))
    if bad:
        pending = [
            scenario_id
            for scenario_id, status in bad.items()
            if status == "PENDING_HOST"
        ]
        if pending:
            lines.append(
                "scenarios: FAIL: workspace_command assertion(s) are still "
                "pending host evaluation for: " + ", ".join(sorted(pending))
            )
        lines.append(
            "scenarios: FAIL: final status(es): "
            + ", ".join(
                "{}={}".format(scenario_id, status)
                for scenario_id, status in sorted(bad.items())
            )
        )
        return 5, lines
    if infra:
        return 6, lines
    return 0, lines


# ------------------------------------------------------------------------ CLI


def _split_ids(value):
    ids = [item.strip() for item in (value or "").split(",") if item.strip()]
    for scenario_id in ids:
        validate_scenario_id(scenario_id)
    return ids


def _cmd_archive(args):
    failed = 0
    for scenario_id in _split_ids(args.ids):
        try:
            record = archive_attempt(args.results, scenario_id, source=args.source)
        except (EvidenceError, OSError, ValueError) as exc:
            print("scenario_evidence: {}: archive failed: {}".format(scenario_id, exc))
            failed = 1
            continue
        if record is None:
            print("scenario_evidence: {}: no current evidence to archive".format(scenario_id))
        else:
            print(
                "scenario_evidence: {}: archived attempt {} -> {}".format(
                    scenario_id, record["attempt"], record["paths"]["directory"]
                )
            )
    return failed


def _cmd_clear(args):
    failed = 0
    for scenario_id in _split_ids(args.ids):
        try:
            removed = clear_current(args.results, scenario_id)
        except (EvidenceError, OSError, ValueError) as exc:
            print("scenario_evidence: {}: clear failed: {}".format(scenario_id, exc))
            failed = 1
            continue
        print(
            "scenario_evidence: {}: cleared current artifacts: {}".format(
                scenario_id, ", ".join(removed) if removed else "(none)"
            )
        )
    return failed


def _cmd_finalize(args):
    failed = 0
    for scenario_id in _split_ids(args.ids):
        repairs = []
        git_error = None
        if args.reconcile_git:
            try:
                repairs = reconcile_workspace_git(
                    args.results,
                    scenario_id,
                    fixtures_root=args.fixtures_root,
                    require_git=args.require_git,
                )
            except EvidenceError as exc:
                git_error = exc
                repairs = [{
                    "artifact": "workspace.tar/.git",
                    "code": exc.code,
                    "error": str(exc),
                }]
        try:
            info = refresh_index(
                args.results,
                scenario_id,
                staging_repairs=repairs,
            )
        except (EvidenceError, OSError, ValueError) as exc:
            print("scenario_evidence: {}: finalize failed: {}".format(scenario_id, exc))
            failed = 1
            continue
        if git_error is not None:
            print(
                "scenario_evidence: {}: attempt {} {} indexed, git reconciliation "
                "failed: {}".format(
                    scenario_id, info["attempt"], info["status"], git_error
                )
            )
            failed = 1
            continue
        repairs_count = len(info.get("staging_repairs") or [])
        print(
            "scenario_evidence: {}: attempt {} {} indexed{}".format(
                scenario_id,
                info["attempt"],
                info["status"],
                ", {} staging repair(s)".format(repairs_count) if repairs_count else "",
            )
        )
    return failed


def _cmd_verify(args):
    failed = 0
    for scenario_id in _split_ids(args.ids):
        try:
            result = verify_scenario(
                args.results,
                scenario_id,
                fixtures_root=args.fixtures_root,
                require_git=args.require_git,
                reconcile=args.reconcile_git,
            )
        except (EvidenceError, OSError, ValueError) as exc:
            print("scenario_evidence: {}: verify failed: {}".format(scenario_id, exc))
            failed = 1
            continue
        if result["ok"]:
            print(
                "scenario_evidence: {}: {} evidence complete".format(
                    scenario_id, result["status"]
                )
            )
        else:
            detail = ", ".join(result["missing"])
            if result.get("errors"):
                detail = (detail + "; " if detail else "") + "; ".join(result["errors"])
            if result.get("code") == REPORT_STRUCTURE_CODE:
                label = "REPORT STRUCTURE INVALID"
            else:
                label = "EVIDENCE INCOMPLETE"
            print(
                "scenario_evidence: {}: {} {}: {}".format(
                    scenario_id,
                    result["status"],
                    label,
                    detail or "unknown",
                )
            )
            print(
                "scenario_evidence: {}: wrote {}".format(
                    scenario_id, "evidence_missing.json"
                )
            )
            failed = 1
    return failed


def _cmd_report_check(args):
    code, lines = check_reports(
        args.catalog,
        args.results,
        only=args.only,
        tag=args.tag,
        target=args.target,
    )
    for line in lines:
        print(line)
    return code


def _build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(subparser):
        subparser.add_argument("--results", required=True)
        subparser.add_argument("--ids", required=True)
        subparser.add_argument("--source", default=None)
        subparser.add_argument("--fixtures-root", default=None)
        subparser.add_argument(
            "--require-git", dest="require_git", action="store_const", const=True,
            default=None,
        )
        subparser.add_argument(
            "--no-require-git", dest="require_git", action="store_const", const=False
        )
        subparser.add_argument(
            "--no-reconcile-git", dest="reconcile_git", action="store_false"
        )

    archive = subparsers.add_parser("archive", help="freeze the current attempt")
    add_common(archive)
    archive.set_defaults(func=_cmd_archive)

    clear = subparsers.add_parser(
        "clear-current", help="remove mutable current artifacts, keep history"
    )
    add_common(clear)
    clear.set_defaults(func=_cmd_clear)

    finalize = subparsers.add_parser(
        "finalize", help="repair git, write report snapshot and refresh the index"
    )
    add_common(finalize)
    finalize.set_defaults(func=_cmd_finalize)

    verify = subparsers.add_parser(
        "verify", help="check terminal evidence and write evidence_missing.json"
    )
    add_common(verify)
    verify.set_defaults(func=_cmd_verify)

    report_check = subparsers.add_parser(
        "report-check", help="batch status/structure gate for selected reports"
    )
    report_check.add_argument("--catalog", required=True)
    report_check.add_argument("--results", required=True)
    report_check.add_argument("--only", default="")
    report_check.add_argument("--tag", default="")
    report_check.add_argument("--target", default="")
    report_check.set_defaults(func=_cmd_report_check)
    return parser


def main(argv=None):
    parser = _build_parser()
    args = parser.parse_args(argv)
    if not hasattr(args, "reconcile_git"):
        args.reconcile_git = True
    try:
        return args.func(args)
    except ValueError as exc:
        print("scenario_evidence: invalid argument: {}".format(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
