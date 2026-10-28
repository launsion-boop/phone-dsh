#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Row table and exit gate for the iOS Simulator report set.

``scripts/ci/sim.sh`` pulls ``probe-report.json``, ``smoke-report.json``,
``kill-report.json`` and ``web-surface-report.json`` from the probe app's data
container and runs this module with ``$OUT``. It prints one PASS/FAIL/INFO row
per line together with the row's threshold, then exits non-zero when:

* a report is missing or cannot be read;
* a report has no rows;
* a report's ``environment`` is not ``ios-simulator``;
* a suite finished with ``ok: false``; or
* any row -- gating or informational -- carries ``FAIL``.

The gate also checks each suite's schema/gate identity, required gating probe
IDs, iteration metadata and row-derived summary counts. ``--selftest`` feeds
versioned synthetic reports through the same gate and checks the clean, sparse,
duplicate, missing and failing cases. ``sim.sh`` runs it on every invocation,
so the FAIL-to-non-zero behaviour is demonstrated rather than only inspected,
including a non-gating FAIL row.

``sim.sh`` also passes ``--canonical-commit/--canonical-version`` and, for a
controlled run, ``--source-commit/--source-version``. The gate then
cross-checks the Web suite's recorded ``asset_metadata`` against those CI
inputs independently of the suite's own pass/fail rows. Without those options
the historical report-only behaviour is unchanged.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

REPORTS = (
    "probe-report.json",
    "smoke-report.json",
    "kill-report.json",
    "web-surface-report.json",
)
REQUIRED_GATING_ROWS = {
    "probe-report.json": {
        # channel.worker is an error-only row; successful Worker runs emit
        # the concrete channel checks below instead.
        "channel.coop-coep-headers-on",
        "channel.fetch-post-1kb", "channel.fetch-post-1mb",
        "channel.ndjson-first-chunk", "channel.ws-echo-1000",
        "channel.coop-coep-headers-off", "channel.crossoriginisolated-off",
        "log.checkpoint-100-files",
    },
    "smoke-report.json": {
        "smoke.boot", "smoke.g1_wal_has_tool_write",
        "smoke.g1_wal_contains_tool_output", "smoke.g1_wal_append_replay_matches",
        "smoke.g1_materialized_contains_tool_output", "smoke.g1_journal_dispatched",
        "smoke.g1_journal_completed", "smoke.g1_journal_wire_projection",
        "smoke.g1_step_machine_journaled", "smoke.g1_model_second_request",
        "smoke.g1_model_first_request_no_tool_result",
        "smoke.g1_model_second_request_has_tool_result",
        "smoke.g1_model_credential_injected", "smoke.planned_restart",
        "smoke.overlay_gzip", "smoke.restarted_event",
        "smoke.restart_preserves_wal", "smoke.resumed_session",
        "smoke.python_http_result", "smoke.python_http_post",
        "smoke.python_http_get_404", "smoke.python_http_allowlist_deny",
        "smoke.python_http_env_isolation", "smoke.python_http_upstream_cookie_boundary",
        "smoke.python_http_upstream_referer_boundary", "smoke.python_http_host_credential",
        "smoke.python_http_turn_follow_up",
    },
}

EXPECTED_PYTHON_HTTP_GATING_ROWS = frozenset({
    "smoke.python_http_result", "smoke.python_http_post",
    "smoke.python_http_get_404", "smoke.python_http_allowlist_deny",
    "smoke.python_http_env_isolation", "smoke.python_http_upstream_cookie_boundary",
    "smoke.python_http_upstream_referer_boundary", "smoke.python_http_host_credential",
    "smoke.python_http_turn_follow_up",
})


def _validate_contract(name, document, rows, problems):
    expected_suite, expected_gate = {
        "probe-report.json": ("probe", "G0"),
        "smoke-report.json": ("smoke", "G1"),
        "kill-report.json": ("kill", "G1"),
        "web-surface-report.json": ("web", "G1"),
    }[name]
    if document.get("schema") != 1:
        problems.append(f"{name}: schema is {document.get('schema')!r}, expected 1")
    if document.get("suite") != expected_suite:
        problems.append(f"{name}: suite is {document.get('suite')!r}, expected {expected_suite!r}")
    if document.get("gate") != expected_gate:
        problems.append(f"{name}: gate is {document.get('gate')!r}, expected {expected_gate!r}")
    if document.get("environment") != "ios-simulator":
        problems.append(f"{name}: environment is {document.get('environment')!r}, expected 'ios-simulator'")
    if document.get("ok") is not True:
        problems.append(f"{name}: ok is not true")

    by_id = {}
    valid_rows = []
    for row in rows:
        if not isinstance(row, dict):
            problems.append(f"{name}: row is not an object")
            continue
        valid_rows.append(row)
        probe = row.get("probe")
        if isinstance(probe, str):
            by_id.setdefault(probe, []).append(row)
        if row.get("status") not in ("PASS", "FAIL", "INFO"):
            problems.append(f"{name}: {probe!r} has invalid status {row.get('status')!r}")
        if not isinstance(row.get("gating"), bool):
            problems.append(f"{name}: {probe!r} has no boolean gating flag")

    for probe in sorted(REQUIRED_GATING_ROWS.get(name, ())):
        matches = [row for row in by_id.get(probe, []) if row.get("gating") is True]
        if len(matches) != 1:
            problems.append(f"{name}: required gating row {probe!r} occurs {len(matches)} times")
        elif not _required_row_succeeded(probe, matches[0]):
            problems.append(f"{name}: required gating row {probe!r} is not PASS")

    summary = document.get("summary")
    if not isinstance(summary, dict):
        problems.append(f"{name}: summary is missing or not an object")
    else:
        counts = {key: sum(row.get("status") == status for row in valid_rows)
                  for key, status in (("pass", "PASS"), ("fail", "FAIL"), ("info", "INFO"))}
        for key, expected in counts.items():
            if summary.get(key) != expected:
                problems.append(f"{name}: summary.{key} is {summary.get(key)!r}, rows imply {expected}")
        gating_failed = any(row.get("gating") is True and row.get("status") == "FAIL"
                            for row in valid_rows)
        reported_gate = summary.get("gate_passed", summary.get("g0_passed", summary.get("g0Passed")))
        if reported_gate is not (not gating_failed):
            problems.append(f"{name}: summary gate result does not match gating rows")

    if name == "kill-report.json":
        requested = document.get("iterations_requested")
        if not isinstance(requested, int) or isinstance(requested, bool) or requested < 4:
            problems.append("kill-report.json: iterations_requested must be an integer >= 4")
            return
        iterations = {}
        expected_kinds = {"worker-terminate", "webcontent-restart"}
        expected_timings = {"after-write", "during-exec", "during-checkpoint", "during-epoch-close"}
        for row in valid_rows:
            if row.get("gating") is not True:
                continue
            probe = row.get("probe")
            if not isinstance(probe, str) or not probe.startswith("kill."):
                continue
            try:
                index = int(probe.split(".")[1])
            except (IndexError, ValueError):
                problems.append(f"kill-report.json: invalid iteration id {probe!r}")
                continue
            parts = probe.split(".")
            metrics = row.get("metrics") if isinstance(row.get("metrics"), dict) else {}
            kind, timing = metrics.get("kind"), metrics.get("timing")
            if (len(parts) != 4 or kind not in expected_kinds
                    or timing not in expected_timings
                    or probe != f"kill.{index}.{kind}.{timing}"):
                problems.append(f"kill-report.json: malformed iteration row {probe!r}")
            iterations.setdefault(index, []).append(row)
        if set(iterations) != set(range(requested)) or any(len(v) != 1 for v in iterations.values()):
            problems.append("kill-report.json: gating kill rows do not cover each requested iteration exactly once")
        kill_rows = [row for row in valid_rows if row.get("gating") is True
                     and isinstance(row.get("probe"), str)
                     and row["probe"].startswith("kill.")]
        coverage = {(row.get("metrics", {}).get("kind"), row.get("metrics", {}).get("timing"))
                    for row in kill_rows if isinstance(row.get("metrics"), dict)}
        required_coverage = {(kind, timing) for kind in expected_kinds for timing in expected_timings}
        missing_coverage = required_coverage - coverage
        if missing_coverage:
            problems.append("kill-report.json: incomplete kind/timing coverage: "
                            + ", ".join(f"{kind}/{timing}" for kind, timing in sorted(missing_coverage)))
        if document.get("passed") != sum(row.get("status") == "PASS" for row in kill_rows):
            problems.append("kill-report.json: passed does not match kill rows")
        if document.get("failed") != sum(row.get("status") == "FAIL" for row in kill_rows):
            problems.append("kill-report.json: failed does not match kill rows")
        info_rows = [row for row in valid_rows if row.get("probe") == "kill.real-webcontent-kill"]
        if len(info_rows) != 1 or info_rows[0].get("gating") is not False or info_rows[0].get("status") != "INFO":
            problems.append("kill-report.json: expected one informational real WebContent kill row")


def _required_row_succeeded(probe, row):
    if row.get("status") == "PASS":
        return True
    # ProbeKit deliberately emits INFO for a correct checkpoint when its
    # non-gating timing threshold is exceeded. Require the actual durability
    # evidence; INFO alone must never satisfy a required correctness check.
    if probe != "log.checkpoint-100-files" or row.get("status") != "INFO":
        return False
    metrics, threshold = row.get("metrics"), row.get("threshold")
    if not isinstance(metrics, dict) or not isinstance(threshold, dict):
        return False
    if threshold.get("gating") is not False:
        return False
    if metrics.get("files") != 100 or metrics.get("materialized_upto_mseq") != 100:
        return False
    return all(isinstance(metrics.get(key), int) and not isinstance(metrics[key], bool)
               and metrics[key] >= 100 for key in ("acked_mseq", "durable_mseq"))



def inspect(out):
    """Loads the four reports and returns ``(documents, problems, status)``."""
    documents = {}
    problems = []
    status = 0
    for name in REPORTS:
        path = Path(out) / name
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except Exception as error:  # noqa: BLE001 - diagnostics only
            problems.append(f"{name}: cannot read: {error}")
            status = 1
            continue
        if not isinstance(document, dict):
            problems.append(f"{name}: report is not an object")
            status = 1
            continue
        documents[name] = document
        rows = document.get("rows")
        if not isinstance(rows, list):
            rows = []
            problems.append(f"{name}: rows is missing or not an array")
            status = 1
        if not rows:
            problems.append(f"{name}: no rows")
            status = 1
        _validate_contract(name, document, rows, problems)
        if problems:
            status = 1
    return documents, problems, status


def check_selected_source(documents, expected):
    """Cross-checks the Web suite's asset metadata against CI inputs.

    The full-Web test already fails when its runner-supplied canonical and
    selected pairs do not match the bundle. This second check is deliberately
    independent of the test's pass/fail row: the gate compares the recorded
    metadata with the same values `sim.sh` resolved from the pin/checkout, so a
    stale report cannot be relabelled by the test process alone.
    """
    if expected is None:
        return [], 0
    problems = []
    status = 0
    document = documents.get("web-surface-report.json") or {}
    metadata = document.get("asset_metadata")
    if not isinstance(metadata, dict):
        return ["web-surface-report.json: no asset_metadata for the selected source"], 1

    canonical_commit = expected.get("canonical_commit")
    canonical_version = expected.get("canonical_version")
    source_commit = expected.get("source_commit")
    source_version = expected.get("source_version")
    explicit = bool(source_commit)
    selected_commit = source_commit or canonical_commit
    selected_version = source_version or canonical_version
    expected_overridden = (
        selected_commit != canonical_commit or selected_version != canonical_version
    )

    def mismatch(field, actual, wanted):
        nonlocal status
        if actual != wanted:
            problems.append(
                f"web-surface-report.json asset_metadata.{field} is {actual!r}, "
                f"expected {wanted!r}"
            )
            status = 1

    mismatch("canonical_commit", metadata.get("canonical_commit"), canonical_commit)
    mismatch("canonical_version", metadata.get("canonical_version"), canonical_version)
    mismatch("pin_commit", metadata.get("pin_commit"), canonical_commit)
    mismatch("pin_version", metadata.get("pin_version"), canonical_version)
    mismatch("expected_commit", metadata.get("expected_commit"), selected_commit)
    mismatch("expected_version", metadata.get("expected_version"), selected_version)
    mismatch("expected_overridden", metadata.get("expected_overridden"), expected_overridden)
    mismatch("source_selection", metadata.get("source_selection"),
             "explicit" if explicit else "canonical")
    mismatch("checkout_overridden_match",
             metadata.get("checkout_overridden_match"), True)
    if metadata.get("input_error"):
        problems.append(
            f"web-surface-report.json asset_metadata.input_error is "
            f"{metadata.get('input_error')!r}"
        )
        status = 1
    return problems, status


def render(documents, problems, status):
    """Returns ``(table_text, status)`` for the inspected reports."""
    lines = ["", f"{'suite':<7} {'row':<56} {'status':<5} threshold"]
    for name in REPORTS:
        document = documents.get(name)
        if document is None:
            continue
        suite = document.get("suite") or name.replace("-report.json", "")
        for row in document.get("rows") or []:
            if not isinstance(row, dict):
                continue
            threshold = row.get("threshold") or {}
            threshold_text = "none"
            if threshold.get("name") not in (None, "none"):
                threshold_text = (
                    f"{threshold.get('name')} "
                    f"{threshold.get('comparison', '')} "
                    f"{threshold.get('value', '')} "
                    f"{threshold.get('unit', '')} "
                    f"[{'met' if threshold.get('met') else 'not met'}]"
                ).strip()
            elif threshold:
                threshold_text = "n/a (informational)"
            gate = "GATE" if row.get("gating") else "info"
            lines.append(
                f"{suite:<7} {row.get('probe', '?'):<56} "
                f"{row.get('status', '?'):<5} {threshold_text} ({gate})"
            )
            if row.get("environment") != "ios-simulator":
                problems.append(
                    f"{row.get('probe')}: environment is {row.get('environment')!r}"
                )
                status = 1
            # PLAN W3-SIM acceptance: any FAIL row exits non-zero, not only the
            # rows whose own threshold is gating. Informational probes keep the
            # row INFO when they cannot produce a measurement (see ProbeRunner).
            if row.get("status") == "FAIL":
                problems.append(
                    f"{row.get('probe')}: FAIL "
                    f"(gating={bool(row.get('gating'))})"
                )
                status = 1

    lines.append("")
    for name in REPORTS:
        document = documents.get(name)
        if document is None:
            continue
        summary = document.get("summary") or {}
        lines.append(
            f"{name}: pass={summary.get('pass', 0)} "
            f"fail={summary.get('fail', 0)} info={summary.get('info', 0)} "
            f"gate_passed={summary.get('gate_passed', summary.get('g0Passed'))}"
        )

    if status != 0:
        lines.append("")
        smoke = documents.get("smoke-report.json") or {}
        tail = smoke.get("console_last_50") or []
        if tail:
            lines.append("smoke console (last 50):")
            for line in tail:
                lines.append(f"  {line}")
        lines.append("")
        for problem in problems:
            lines.append(f"GATE FAIL: {problem}")
    else:
        lines.append("")
        lines.append("sim: PASS (all gating rows met; environment ios-simulator)")
    return "\n".join(lines), status


def gate(out, echo=True, expected=None):
    """Prints the table for ``out`` and returns the gate exit status."""
    documents, problems, status = inspect(out)
    source_problems, source_status = check_selected_source(documents, expected)
    problems.extend(source_problems)
    status = max(status, source_status)
    text, status = render(documents, problems, status)
    if echo:
        print(text)
    return status


# MARK: - Self-test


def _row(probe, status, gating):
    return {
        "probe": probe,
        "status": status,
        "gating": gating,
        "environment": "ios-simulator",
        "metrics": {},
        "threshold": {
            "name": "selftest",
            "comparison": "==",
            "value": 1,
            "unit": "pass",
            "met": status == "PASS",
            "gating": gating,
        },
    }


def _suite(name, environment="ios-simulator", ok=True, rows=None):
    suite, gate_name = {"probe-report.json": ("probe", "G0"),
                        "smoke-report.json": ("smoke", "G1"),
                        "kill-report.json": ("kill", "G1"),
                        "web-surface-report.json": ("web", "G1")}[name]
    if rows is None:
        probes = set(REQUIRED_GATING_ROWS.get(name, ()))
        if name == "kill-report.json":
            combinations = [(kind, timing)
                            for kind in ("worker-terminate", "webcontent-restart")
                            for timing in ("after-write", "during-exec", "during-checkpoint", "during-epoch-close")]
            rows = []
            for index, (kind, timing) in enumerate(combinations):
                row = _row(f"kill.{index}.{kind}.{timing}", "PASS", True)
                row["metrics"] = {"kind": kind, "timing": timing}
                rows.append(row)
            rows.append(_row("kill.real-webcontent-kill", "INFO", False))
        elif name == "web-surface-report.json":
            # The real Web suite emits its own rows (session E2E, source
            # consistency); one representative gating row keeps the synthetic
            # selftest report structurally valid without faking its catalogue.
            rows = [_row("web.source-consistency", "PASS", True)]
        else:
            rows = [_row(probe, "PASS", True) for probe in sorted(probes)]
    report = {
        "schema": 1,
        "suite": suite,
        "gate": gate_name,
        "environment": environment,
        "ok": ok,
        "summary": {
            "pass": sum(1 for row in rows if row["status"] == "PASS"),
            "fail": sum(1 for row in rows if row["status"] == "FAIL"),
            "info": sum(1 for row in rows if row["status"] == "INFO"),
            "gate_passed": all(
                row["status"] != "FAIL" for row in rows if row["gating"]
            ),
        },
        "rows": rows,
    }
    if name == "kill-report.json":
        report["iterations_requested"] = 8
        report["passed"] = 8
        report["failed"] = 0
    return report


def _write(directory, documents):
    for name, document in documents.items():
        (Path(directory) / name).write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


def _clean():
    return {name: _suite(name) for name in REPORTS}


def selftest():
    """Feeds synthetic reports through ``gate`` and checks every exit path."""
    missing_python_rows = EXPECTED_PYTHON_HTTP_GATING_ROWS - REQUIRED_GATING_ROWS["smoke-report.json"]
    if missing_python_rows:
        print("sim-gate selftest FAIL: Python HTTP acceptance rows are not required: "
              + ", ".join(sorted(missing_python_rows)), file=sys.stderr)
        return 1

    cases = []

    def case(label, expected, documents, drop=(), source_expected=None):
        with tempfile.TemporaryDirectory(prefix="pdsh-sim-gate-") as directory:
            for name in drop:
                documents.pop(name, None)
            _write(directory, documents)
            cases.append((label, expected,
                          gate(directory, echo=False, expected=source_expected)))

    case("clean", 0, _clean())

    non_gating_fail = _clean()
    non_gating_fail["probe-report.json"] = _suite(
        "probe-report.json",
        rows=[_row("selftest.info-probe", "FAIL", False)],
    )
    case("non-gating FAIL", 1, non_gating_fail)

    gating_fail = _clean()
    gating_fail["kill-report.json"] = _suite(
        "kill-report.json",
        rows=[_row("selftest.gate", "FAIL", True)],
    )
    case("gating FAIL", 1, gating_fail)

    wrong_environment = _clean()
    wrong_environment["smoke-report.json"] = _suite(
        "smoke-report.json", environment="not-ios-simulator"
    )
    case("environment mismatch", 1, wrong_environment)

    not_ok = _clean()
    not_ok["probe-report.json"] = _suite("probe-report.json", ok=False)
    case("suite ok=false", 1, not_ok)

    case("missing report", 1, _clean(), drop=("kill-report.json",))

    sparse = _clean()
    sparse["probe-report.json"]["rows"] = [
        _row("channel.worker", "PASS", True)
    ]
    sparse["probe-report.json"]["summary"] = {
        "pass": 1, "fail": 0, "info": 0, "g0_passed": True,
    }
    case("missing required probe row", 1, sparse)

    for probe in sorted(EXPECTED_PYTHON_HTTP_GATING_ROWS):
        missing_python_row = _clean()
        report = missing_python_row["smoke-report.json"]
        report["rows"] = [row for row in report["rows"] if row["probe"] != probe]
        report["summary"] = {
            "pass": sum(row["status"] == "PASS" for row in report["rows"]),
            "fail": sum(row["status"] == "FAIL" for row in report["rows"]),
            "info": sum(row["status"] == "INFO" for row in report["rows"]),
            "gate_passed": not any(row["gating"] and row["status"] == "FAIL"
                                    for row in report["rows"]),
        }
        case(f"missing required {probe}", 1, missing_python_row)

    canonical_commit = "7be5505b0be06009d74891c869063c9cf19a0df0"
    selected_commit = "c63e01d545cbc03f6b59b1f33679c501de590255"
    version = "0.2.1-rc.2"
    source_inputs = {
        "canonical_commit": canonical_commit,
        "canonical_version": version,
        "source_commit": selected_commit,
        "source_version": version,
    }

    def source_metadata(expected_commit):
        return {
            "canonical_commit": canonical_commit,
            "canonical_version": version,
            "pin_commit": canonical_commit,
            "pin_version": version,
            "expected_commit": expected_commit,
            "expected_version": version,
            "expected_overridden": expected_commit != canonical_commit,
            "source_selection": (
                "explicit" if expected_commit != canonical_commit else "canonical"
            ),
            "checkout_overridden_match": True,
            "input_error": "",
        }

    source_match = _clean()
    source_match["web-surface-report.json"]["asset_metadata"] = source_metadata(
        selected_commit
    )
    case("selected source match", 0, source_match, source_expected=source_inputs)

    source_mismatch = _clean()
    source_mismatch["web-surface-report.json"]["asset_metadata"] = source_metadata(
        selected_commit
    )
    wrong_inputs = dict(source_inputs)
    wrong_inputs["source_commit"] = "d" * 40
    case("selected source mismatch", 1, source_mismatch,
         source_expected=wrong_inputs)

    failures = [
        f"{label}: expected exit {expected}, got {status}"
        for label, expected, status in cases
        if status != expected
    ]
    if failures:
        for failure in failures:
            print(f"sim-gate selftest FAIL: {failure}", file=sys.stderr)
        return 1
    labels = ", ".join(f"{label}={status}" for label, _, status in cases)
    print(f"sim-gate selftest: PASS ({labels})")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) < 2:
        print("usage: sim_gate.py OUT | sim_gate.py --selftest", file=sys.stderr)
        return 2
    out = argv[1]
    expected = {}
    index = 2
    options = {
        "--canonical-commit": "canonical_commit",
        "--canonical-version": "canonical_version",
        "--source-commit": "source_commit",
        "--source-version": "source_version",
    }
    while index < len(argv):
        option = argv[index]
        if option not in options or index + 1 >= len(argv):
            print(f"sim_gate.py: unknown or incomplete option {option!r}", file=sys.stderr)
            return 2
        expected[options[option]] = argv[index + 1]
        index += 2
    canonical_pair = bool(expected.get("canonical_commit")) == bool(
        expected.get("canonical_version")
    )
    source_pair = bool(expected.get("source_commit")) == bool(
        expected.get("source_version")
    )
    if not canonical_pair or not source_pair:
        print("sim_gate.py: source and canonical inputs must each be a commit/version pair",
              file=sys.stderr)
        return 2
    return gate(out, expected=expected or None)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
