#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import tempfile

CONTRACT_REVISION = "b5192c4a3eedd94ac4878bc0270684f7854ac273"


def utcnow():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def timestamp(text):
    if not text:
        return None
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def load_jsonl(path):
    if not path.exists():
        return []
    result = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result


def ccr(contract, clause, problem, proposal, affects):
    return (f"CONTRACT CHANGE REQUEST\n"
            f"Contract: {contract} @ {CONTRACT_REVISION}   Clause: {clause}\n"
            f"Problem: {problem}\n"
            f"Proposal: {proposal}   Affects: {affects}\n")


def verify_lock(app, samples, duration):
    started = timestamp(app.get("runStartedAt"))
    ended = timestamp(app.get("lockEndedAt"))
    target = started + duration if started is not None else None
    protected_proof = (app.get("protectedDataLockObserved") is True
                       and app.get("observedLockSeconds", 0) >= duration
                       and app.get("durationReachedAt") is not None
                       and (ended is None or target is None or ended >= target))
    usable = [sample for sample in samples
              if sample.get("readSucceeded") and sample.get("locked") is not None
              and timestamp(sample.get("at")) is not None]
    host_proof = False
    if started is not None and target is not None and usable:
        relevant = [sample for sample in usable
                    if started - 15 <= timestamp(sample["at"]) <= target + 15]
        locked = [sample for sample in relevant if sample["locked"] is True]
        unlocked = [sample for sample in relevant
                    if sample["locked"] is False and started <= timestamp(sample["at"]) <= target]
        if locked and not unlocked:
            first = timestamp(locked[0]["at"])
            last = timestamp(locked[-1]["at"])
            host_proof = last - first >= max(0, duration - 15)
    return protected_proof or host_proof, protected_proof, host_proof


def analyze(output_dir, acquisition_error=None):
    output_dir = output_dir.resolve()
    host_path = output_dir / "host-report.json"
    host = read_json(host_path, {}) or {}
    reports = list((output_dir / "device").rglob("app-report.json"))
    app = read_json(reports[0], None) if reports else None
    samples = load_jsonl(output_dir / "lock-samples.jsonl")
    acquisition_error = acquisition_error or host.get("acquisitionError")
    checks = []

    def check(name, passed, detail):
        checks.append({"name": name, "passed": bool(passed), "detail": detail})

    if app is None:
        config = None
        duration = host.get("durationSeconds", 0)
        expected_events = 0
        expected_kills = host.get("expectedKillCount", 0)
        events = []
        recoveries = []
        kills = host.get("killResults", [])
        check("app-report", False, acquisition_error or "app-report.json is missing")
    else:
        config = app.get("configuration") or {}
        duration = config.get("durationSeconds", 0)
        expected_events = config.get("eventCount", 0)
        expected_kills = config.get("killCount", 0)
        events = app.get("events", [])
        recoveries = app.get("recoveries", [])
        kills = host.get("killResults", [])
        check("app-report", not acquisition_error and app.get("status") == "COMPLETE",
              acquisition_error or app.get("reason") or app.get("status", "unknown"))

    lock_ok, protected_proof, host_proof = verify_lock(app or {}, samples, duration)
    check("locked-duration", app is not None and lock_ok,
          f"observed={app.get('observedLockSeconds') if app else None}s required={duration}s "
          f"protectedData={protected_proof} devicectl={host_proof}")

    expected_ids = [f"event-{index:03d}" for index in range(1, expected_events + 1)]
    actual_ids = [event.get("id") for event in events]
    injected_ids = [event.get("id") for event in events if event.get("injectedAt")]
    delivered_ids = [event.get("id") for event in events if event.get("deliveredAt")]
    check("event-injection", sorted(injected_ids) == expected_ids,
          f"injected={len(injected_ids)}/{expected_events}")
    check("event-delivery", sorted(delivered_ids) == expected_ids and sorted(actual_ids) == expected_ids,
          f"delivered={len(delivered_ids)}/{expected_events}")
    duplicates = [event.get("id") for event in events
                  if len(event.get("userSequenceNumbers", [])) != 1
                  or event.get("successfulToolResults") != 1
                  or event.get("finalAssistantMessages") != 1]
    check("event-exactly-once", not duplicates,
          "unique user seq, one successful tool result, and one final assistant message required; "
          f"violations={duplicates}")
    latencies = [event.get("deliveryLatencySeconds") for event in events]
    late = [event.get("id") for event in events
            if not isinstance(event.get("deliveryLatencySeconds"), (int, float))
            or event.get("deliveryLatencySeconds") < 0
            or event.get("deliveryLatencySeconds") > 30]
    finite_latencies = [value for value in latencies if isinstance(value, (int, float))]
    check("delivery-within-30s", not late,
          f"late-or-unmeasured={late} max={max(finite_latencies) if finite_latencies else None}s")
    model_requests = (app or {}).get("modelRequestCount", 0)
    check("webcontent-llm-loop", model_requests >= expected_events * 2,
          f"scripted model requests={model_requests}; at least two per event required")

    expected_kill_ids = [f"kill-{index:03d}" for index in range(1, expected_kills + 1)]
    sent = [kill for kill in kills if kill.get("status") == "signal-sent"]
    check("webcontent-sigkill", sorted(kill.get("id") for kill in sent) == expected_kill_ids,
          f"confirmed devicectl SIGKILL={len(sent)}/{expected_kills}; "
          f"states={[(kill.get('id'), kill.get('status')) for kill in kills]}")
    recovered = [recovery for recovery in recoveries
                 if recovery.get("recoveredAt") and recovery.get("helloAfter", 0) > recovery.get("helloBefore", 0)]
    check("recovery-hello", len(recovered) >= expected_kills,
          f"replacement HELLO recovered={len(recovered)}/{expected_kills}")
    associations = []
    for index, kill in enumerate(sent):
        if index >= len(recoveries):
            associations.append((kill.get("id"), "no termination"))
            continue
        attempted = timestamp(kill.get("attemptedAt"))
        terminated = timestamp(recoveries[index].get("terminatedAt"))
        if attempted is None or terminated is None or not 0 <= terminated - attempted <= 60:
            associations.append((kill.get("id"), "termination not within 60s of SIGKILL"))
    check("kill-termination-association", not associations,
          f"unassociated={associations}")

    p6_violations = (app or {}).get("p6ViolationCount", 0)
    check("p6-background-gate", p6_violations == 0,
          f"violations={p6_violations} deferred={(app or {}).get('p6DeferredCount', 0)}")

    requests = []
    if (app or {}).get("helloFailureCount", 0):
        requests.append(("P01", ccr(
            "P01", "spec/v1/channel.md#HELLO and replacement-Worker recovery",
            f"The device run recorded {(app or {}).get('helloFailureCount')} HELLO/lease failure(s); see app-events.jsonl and app-report.json.",
            "WP0 owner must identify and freeze the smallest compatible HELLO recovery correction; WP1 made no local protocol change.",
            "Swift host and Worker, with Rust/Kotlin codec review as applicable")))
    if (app or {}).get("p15FailureCount", 0):
        requests.append(("P15", ccr(
            "P15", "Sources/PhoneDSH/PhoneDSHRecovery.swift#bounded recovery write-open",
            f"The device run recorded {(app or {}).get('p15FailureCount')} recovery-route failure(s); see app-events.jsonl and app-report.json.",
            "WP0 owner must define the smallest compatible recovery-route correction; WP1 made no local endpoint or payload change.",
            "Swift PhoneDSHRecovery and plugins/surface-phone recovery controller")))
    check("hello-and-p15-errors", not requests,
          f"helloFailures={(app or {}).get('helloFailureCount', 0)} "
          f"p15Failures={(app or {}).get('p15FailureCount', 0)}")

    p6_blocked = ((app or {}).get("p6DeferredCount", 0) > 0
                  and len(sent) < expected_kills
                  and any(kill.get("status") in {"unavailable", "identity-unverified"} for kill in kills))
    if p6_blocked:
        requests.append(("P08", ccr(
            "P08", "Sources/PhoneDSH/PhoneDSHHost.swift#recoverAfterTermination P6 foreground gate",
            "A background WebContent termination was deferred, leaving no live replacement for the remaining random kills. The current P6 rule therefore prevents the required three-kill locked-window run.",
            "Decide whether Bot may recover under its explicit keep-alive lease with a bounded background recovery contract, or reject the WebContent-resident architecture; do not weaken P6 globally without a frozen delta.",
            "WP0 contract owner, WP10 lifecycle implementer, Swift host, and Bot runtime")))

    status = "PASS" if checks and all(item["passed"] for item in checks) else "FAIL"
    for contract, text in requests:
        (output_dir / f"ccr-{contract}.txt").write_text(text, encoding="utf-8")
    summary = {
        "schema": "phonedsh-bot-residency/1",
        "generatedAt": utcnow(),
        "status": status,
        "conclusion": "go" if status == "PASS" else "no-go",
        "contractRevision": CONTRACT_REVISION,
        "configuration": config,
        "device": read_json(output_dir / "device.json", None),
        "checks": checks,
        "metrics": {
            "lockedSeconds": (app or {}).get("observedLockSeconds"),
            "eventsInjected": len(injected_ids),
            "eventsDelivered": len(delivered_ids),
            "maximumDeliveryLatencySeconds": max(finite_latencies) if finite_latencies else None,
            "sigkillsConfirmed": len(sent),
            "recoveriesObserved": len(recoveries),
            "maximumRecoverySeconds": max([r["recoverySeconds"] for r in recovered
                                           if isinstance(r.get("recoverySeconds"), (int, float))], default=None),
            "maximumRecoveryWorkSeconds": max([r["recoveryWorkSeconds"] for r in recovered
                                               if isinstance(r.get("recoveryWorkSeconds"), (int, float))], default=None),
            "p6DeferredCount": (app or {}).get("p6DeferredCount", 0),
            "p6ViolationCount": p6_violations,
            "helloFailureCount": (app or {}).get("helloFailureCount", 0),
            "p15FailureCount": (app or {}).get("p15FailureCount", 0),
            "scriptedModelRequests": model_requests,
        },
        "ccrFiles": [f"ccr-{contract}.txt" for contract, _ in requests],
        "evidenceStatus": "physical-device" if app is not None else "incomplete-device-evidence",
        "realModel": False,
    }
    write_json(output_dir / "summary.json", summary)
    return summary


def write_not_run(output_dir, reason):
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    summary = {
        "schema": "phonedsh-bot-residency/1",
        "generatedAt": utcnow(),
        "status": "NOT_RUN",
        "conclusion": "NOT_RUN",
        "contractRevision": CONTRACT_REVISION,
        "reason": reason,
        "device": read_json(output_dir / "device.json", None),
        "realModel": False,
        "evidenceStatus": "no-device-run",
    }
    write_json(output_dir / "summary.json", summary)
    return summary


# --------------------------------------------------------------------------
# Engine-first-launch wake measurement (plan §2.4, docs/perf/engine-wake)
# --------------------------------------------------------------------------

# Keep in sync with docs/perf/engine-wake/README.md and the provisional
# constants in spec/host/v1 (contracts unit). If the frozen golden exists the
# real values are read from there instead.
DEFAULT_ENGINE_WAKE_THRESHOLDS = {
    "minLeaseForColdBootMs": 20000,
    "minLeaseForResumeMs": 8000,
    "parkMarginMs": 5000,
}

ENGINE_WAKE_SCENARIOS = (
    "push-cold-start",
    "push-parked-resume",
    "bgprocessing-cold-start",
    "board-wake-cold-start",
    "lan-resident",
    "lan-suspended",
)
# Cold *engine* boot samples used for the lease recommendation. The board
# control runs with the audio-resident process already alive, so it is a cold
# engine boot but not a cold process.
ENGINE_WAKE_COLD_SCENARIOS = {
    "push-cold-start", "bgprocessing-cold-start", "board-wake-cold-start",
}
ENGINE_WAKE_PROCESS_COLD_SCENARIOS = {
    "push-cold-start", "bgprocessing-cold-start",
}
ENGINE_WAKE_TRIGGERS = {
    "apns-content-available", "simctl-push", "bgprocessing", "board-audio",
    "lan-http", "external",
}


def percentile_nearest_rank(values, percent):
    """Nearest-rank percentile over the real samples; None for an empty list."""
    ordered = sorted(value for value in values if isinstance(value, (int, float)))
    if not ordered:
        return None
    rank = max(1, math.ceil(percent / 100.0 * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


def ceil_to_step(value, step=1000):
    return int(math.ceil(float(value) / step)) * step


def load_engine_wake_thresholds(path):
    """Read the frozen constants, falling back to the plan's provisional values."""
    document = read_json(path, {}) if path is not None else {}
    constants = document.get("constants") if isinstance(document, dict) else None
    result = dict(DEFAULT_ENGINE_WAKE_THRESHOLDS)
    found = False
    if isinstance(constants, dict):
        for key in DEFAULT_ENGINE_WAKE_THRESHOLDS:
            value = constants.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
                result[key] = int(value)
                found = True
    result["source"] = str(path) if found and path is not None else "provisional-plan"
    return result


def engine_wake_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0


def engine_wake_attempt_valid(attempt):
    return (
        isinstance(attempt, dict)
        and engine_wake_number(attempt.get("wakeToHostStartMs"))
        and bool(attempt.get("hostStartReturnedAt"))
        and attempt.get("anchorInWindowAfterBoot") is True
        and not attempt.get("error")
    )


def engine_wake_probes(host, scenario_id):
    probes = host.get("lanProbes") if isinstance(host, dict) else None
    if not isinstance(probes, list):
        return []
    return [probe for probe in probes
            if isinstance(probe, dict) and probe.get("scenario") == scenario_id
            and probe.get("sentAt")]


def engine_wake_scenario_verdict(scenario, host, thresholds):
    """Return (status, reason, samples) for one measured scenario.

    status is PASS, FAIL or NOT_RUN. A missing scenario / empty attempt list is
    an unexecuted scenario, never a pass.
    """
    scenario_id = scenario.get("id") if isinstance(scenario, dict) else None
    attempts = scenario.get("attempts") if isinstance(scenario, dict) else None
    attempts = attempts if isinstance(attempts, list) else []
    samples = [attempt.get("wakeToHostStartMs") for attempt in attempts
               if isinstance(attempt, dict)
               and engine_wake_number(attempt.get("wakeToHostStartMs"))]
    if not attempts:
        return "NOT_RUN", "no measured attempt for this scenario", samples

    invalid = []
    setup_mismatch = []
    for index, attempt in enumerate(attempts):
        if not engine_wake_attempt_valid(attempt):
            invalid.append(index + 1)
            continue
        trigger = attempt.get("trigger")
        if trigger is not None and trigger not in ENGINE_WAKE_TRIGGERS:
            invalid.append(index + 1)
            continue
        if scenario_id in ENGINE_WAKE_PROCESS_COLD_SCENARIOS and attempt.get("processWasRunning") is True:
            setup_mismatch.append(index + 1)
            continue
        if scenario_id == "push-parked-resume":
            if attempt.get("hostStateBefore") != "parked" or attempt.get("decision") != "resume":
                setup_mismatch.append(index + 1)
        if scenario_id == "board-wake-cold-start" and attempt.get("residentAudio") is not True:
            setup_mismatch.append(index + 1)
        if scenario_id == "push-cold-start" and attempt.get("sceneConnectedAtTrigger") is False \
                and attempt.get("offscreenWindowUsed") is not True:
            setup_mismatch.append(index + 1)
    if invalid:
        return "FAIL", f"invalid attempt(s): {invalid}", samples
    if setup_mismatch and len(setup_mismatch) == len(attempts):
        return "NOT_RUN", (
            "the scenario was not exercised as specified (attempt(s) "
            f"{setup_mismatch}: warm process, host not parked, no resident audio, "
            "or no offscreen window)"), samples

    if scenario_id == "lan-resident":
        probes = engine_wake_probes(host, scenario_id)
        if not probes:
            return "NOT_RUN", "no LAN probe was performed; pass --lan-host or --lan-url", samples
        if any(probe.get("reachable") is True for probe in probes):
            return "PASS", f"resident listener answered {sum(1 for p in probes if p.get('reachable') is True)}/{len(probes)} probes", samples
        return "FAIL", "resident listener never answered while the app was running", samples

    if scenario_id == "lan-suspended":
        probes = engine_wake_probes(host, scenario_id)
        if not probes:
            return "NOT_RUN", "no LAN probe was performed; pass --lan-host or --lan-url", samples
        reachable = [probe for probe in probes if probe.get("reachable") is True]
        if reachable:
            return "FAIL", ("the local listener answered while the app should be suspended; "
                            "the process was not suspended or the listener kept the app alive"), samples
        if not any(attempt.get("trigger") in {"apns-content-available", "external"}
                   for attempt in attempts if isinstance(attempt, dict)):
            return "FAIL", "the cloud-task push fallback was not observed after the unreachable probe", samples
        return "PASS", f"listener unreachable on {len(probes)} probe(s); push fallback measured", samples

    return "PASS", f"{len(attempts)} valid measured attempt(s)", samples


def analyze_engine_wake(output_dir, thresholds_path=None, acquisition_error=None):
    output_dir = output_dir.resolve()
    thresholds = load_engine_wake_thresholds(thresholds_path)
    host = read_json(output_dir / "host-report.json", {}) or {}
    reports = list(output_dir.rglob("engine-wake-report.json"))
    report = read_json(reports[0], None) if reports else None
    device = read_json(output_dir / "device.json", None)
    acquisition_error = acquisition_error or host.get("acquisitionError")

    device_class = None
    if isinstance(report, dict):
        device_class = report.get("deviceClass")
    if device_class is None and isinstance(device, dict):
        device_class = device.get("deviceClass")
    physical = device_class == "physical"

    checks = []

    def check(name, passed, detail):
        checks.append({"name": name, "passed": bool(passed), "detail": detail})

    if report is None:
        check("engine-wake-report", False, acquisition_error or "engine-wake-report.json is missing")
    else:
        check("engine-wake-report", report.get("schema") == "phonedsh-engine-wake/1",
              f"schema={report.get('schema')}")
        check("physical-device", physical,
              f"deviceClass={device_class!r}; simulator results are NOT_RUN, never device evidence")

    by_id = {}
    if isinstance(report, dict) and isinstance(report.get("scenarios"), list):
        for scenario in report["scenarios"]:
            if isinstance(scenario, dict) and scenario.get("id"):
                by_id[scenario["id"]] = scenario

    scenario_results = []
    for scenario_id in ENGINE_WAKE_SCENARIOS:
        scenario = by_id.get(scenario_id)
        if not physical:
            status, reason, samples = "NOT_RUN", "no physical-device measurement", []
        elif scenario is None:
            status, reason, samples = "NOT_RUN", "scenario was not present in the report", []
        else:
            status, reason, samples = engine_wake_scenario_verdict(scenario, host, thresholds)
        scenario_results.append({
            "id": scenario_id,
            "status": status,
            "p50Ms": percentile_nearest_rank(samples, 50),
            "p95Ms": percentile_nearest_rank(samples, 95),
            "samples": len(samples),
            "reason": reason,
        })
        check(f"scenario:{scenario_id}", status == "PASS",
              f"{status} — {reason}")

    cold_samples = []
    resume_samples = []
    for scenario_id in ENGINE_WAKE_SCENARIOS:
        if not physical:
            break
        scenario = by_id.get(scenario_id)
        if scenario is None:
            continue
        for attempt in scenario.get("attempts") or []:
            if not isinstance(attempt, dict):
                continue
            value = attempt.get("wakeToHostStartMs")
            if not engine_wake_number(value):
                continue
            if scenario_id in ENGINE_WAKE_COLD_SCENARIOS:
                cold_samples.append(value)
            elif scenario_id == "push-parked-resume":
                resume_samples.append(value)

    margin = thresholds["parkMarginMs"]
    suggestions = {
        "minLeaseForColdBootMs": (
            ceil_to_step(percentile_nearest_rank(cold_samples, 95) + margin)
            if cold_samples else None),
        "minLeaseForResumeMs": (
            ceil_to_step(percentile_nearest_rank(resume_samples, 95) + margin)
            if resume_samples else None),
        "parkMarginMs": margin,
        "formula": "ceil_to_1000(p95(wake→hostStartReturn) + parkMarginMs); "
                   "device samples only, simulator excluded",
        "coldSamples": len(cold_samples),
        "resumeSamples": len(resume_samples),
    }

    statuses = [result["status"] for result in scenario_results]
    if not physical or report is None:
        status = "NOT_RUN"
    elif "FAIL" in statuses:
        status = "FAIL"
    elif all(item == "PASS" for item in statuses):
        status = "PASS"
    else:
        status = "NOT_RUN"

    summary = {
        "schema": "phonedsh-engine-wake-summary/1",
        "generatedAt": utcnow(),
        "status": status,
        "conclusion": "go" if status == "PASS" else ("no-go" if status == "FAIL" else "NOT_RUN"),
        "contractRevision": (report or {}).get("contractRevision") if isinstance(report, dict) else None,
        "configuration": (report or {}).get("configuration") if isinstance(report, dict) else None,
        "device": device,
        "deviceClass": device_class,
        "thresholds": thresholds,
        "suggestions": suggestions,
        "scenarios": scenario_results,
        "checks": checks,
        "reason": acquisition_error,
        "evidenceStatus": ("physical-device" if physical
                           else "simulator-not-device-evidence" if device_class == "simulator"
                           else "incomplete-device-evidence"),
        "realModel": False,
    }
    write_json(output_dir / "summary.json", summary)
    return summary


def write_engine_wake_not_run(output_dir, reason):
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    summary = {
        "schema": "phonedsh-engine-wake-summary/1",
        "generatedAt": utcnow(),
        "status": "NOT_RUN",
        "conclusion": "NOT_RUN",
        "device": read_json(output_dir / "device.json", None),
        "deviceClass": None,
        "thresholds": load_engine_wake_thresholds(None),
        "suggestions": None,
        "scenarios": [{"id": scenario_id, "status": "NOT_RUN", "p50Ms": None,
                       "p95Ms": None, "samples": 0, "reason": reason}
                      for scenario_id in ENGINE_WAKE_SCENARIOS],
        "checks": [],
        "reason": reason,
        "evidenceStatus": "no-device-run",
        "realModel": False,
    }
    write_json(output_dir / "summary.json", summary)
    return summary


def engine_wake_selftest():
    with tempfile.TemporaryDirectory(prefix="engine-wake-analyze-") as temporary:
        root = Path(temporary)
        thresholds_path = root / "engine-launch.json"
        write_json(thresholds_path, {"constants": {
            "minLeaseForColdBootMs": 20000,
            "minLeaseForResumeMs": 8000,
            "parkMarginMs": 5000,
        }})

        def attempt(value, **overrides):
            base = {
                "attempt": 1,
                "trigger": "apns-content-available",
                "triggeredAt": "2026-11-20T00:00:00Z",
                "hostStartReturnedAt": "2026-11-20T00:00:02Z",
                "wakeToHostStartMs": value,
                "hostStateBefore": "absent",
                "decision": "boot",
                "processWasRunning": False,
                "sceneConnectedAtTrigger": False,
                "offscreenWindowUsed": True,
                "anchorInWindowAfterBoot": True,
                "residentAudio": False,
                "error": None,
            }
            base.update(overrides)
            return base

        def fixture(name, scenarios, device_class="physical", probes=None):
            directory = root / name
            report_dir = directory / "device" / "run"
            report_dir.mkdir(parents=True)
            report = {
                "schema": "phonedsh-engine-wake/1",
                "runID": name,
                "generatedAt": "2026-11-20T00:00:00Z",
                "contractRevision": "test",
                "deviceClass": device_class,
                "configuration": {"scenarios": list(ENGINE_WAKE_SCENARIOS)},
                "scenarios": scenarios,
            }
            write_json(report_dir / "engine-wake-report.json", report)
            write_json(directory / "host-report.json", {
                "mode": "engine-wake", "lanProbes": probes or [],
                "acquisitionError": None,
            })
            return analyze_engine_wake(directory, thresholds_path)

        cold_values = [18000, 19000, 21000]
        scenarios = [
            {"id": "push-cold-start",
             "attempts": [attempt(value, attempt=index + 1)
                          for index, value in enumerate(cold_values)]},
            {"id": "push-parked-resume",
             "attempts": [attempt(5000, trigger="apns-content-available",
                                  hostStateBefore="parked", decision="resume")]},
            {"id": "bgprocessing-cold-start",
             "attempts": [attempt(22000, trigger="bgprocessing")]},
            {"id": "board-wake-cold-start",
             "attempts": [attempt(4000, trigger="board-audio", residentAudio=True)]},
            {"id": "lan-resident",
             "attempts": [attempt(300, trigger="lan-http", hostStateBefore="running",
                                  decision="ready", processWasRunning=True)]},
            {"id": "lan-suspended",
             "attempts": [attempt(2500, trigger="apns-content-available")]},
        ]
        probes = [
            {"scenario": "lan-resident", "sentAt": "2026-11-20T00:00:00Z", "reachable": True},
            {"scenario": "lan-suspended", "sentAt": "2026-11-20T00:01:00Z", "reachable": False},
        ]
        passing = fixture("pass", scenarios, probes=probes)
        assert passing["status"] == "PASS", passing
        assert passing["scenarios"][0]["p50Ms"] == 19000, passing["scenarios"][0]
        assert passing["scenarios"][0]["p95Ms"] == 21000, passing["scenarios"][0]
        # p95 cold = 22000 (all three cold scenarios), + 5000 park margin.
        assert passing["suggestions"]["minLeaseForColdBootMs"] == 27000, passing["suggestions"]
        assert passing["suggestions"]["minLeaseForResumeMs"] == 10000, passing["suggestions"]

        simulator = fixture("simulator", scenarios, device_class="simulator", probes=probes)
        assert simulator["status"] == "NOT_RUN", simulator
        assert all(item["status"] == "NOT_RUN" for item in simulator["scenarios"])

        broken = [dict(scenario) for scenario in scenarios]
        broken[0] = {"id": "push-cold-start",
                     "attempts": [attempt(18000, anchorInWindowAfterBoot=False)]}
        failed = fixture("failed", broken, probes=probes)
        assert failed["status"] == "FAIL", failed
        assert failed["scenarios"][0]["status"] == "FAIL"

        warm = [dict(scenario) for scenario in scenarios]
        warm[0] = {"id": "push-cold-start",
                   "attempts": [attempt(18000, processWasRunning=True)]}
        not_cold = fixture("warm", warm, probes=probes)
        assert not_cold["status"] == "NOT_RUN", not_cold
        assert not_cold["scenarios"][0]["status"] == "NOT_RUN"

        missing = fixture("missing", scenarios[:2], probes=probes)
        assert missing["status"] == "NOT_RUN", missing

        reachable = fixture("reachable", scenarios, probes=[
            {"scenario": "lan-resident", "sentAt": "2026-11-20T00:00:00Z", "reachable": True},
            {"scenario": "lan-suspended", "sentAt": "2026-11-20T00:01:00Z", "reachable": True},
        ])
        assert reachable["status"] == "FAIL", reachable
        assert next(item for item in reachable["scenarios"]
                    if item["id"] == "lan-suspended")["status"] == "FAIL"

        not_run = write_engine_wake_not_run(root / "not-run", "no physical device")
        assert not_run["status"] == "NOT_RUN"
    print("engine-wake analyzer selftest: PASS")


def selftest():
    engine_wake_selftest()
    with tempfile.TemporaryDirectory(prefix="bot-residency-analyze-") as temporary:
        root = Path(temporary)

        def fixture(name, mutate=None):
            directory = root / name
            app_dir = directory / "device" / "run"
            app_dir.mkdir(parents=True)
            started = timestamp("2026-11-06T00:00:00Z")
            config = {"runID": "run", "durationSeconds": 7200,
                      "eventCount": 2, "killCount": 2, "seed": 1}
            events = []
            for index in range(2):
                injected = started + index * 100
                events.append({
                    "id": f"event-{index + 1:03d}", "injectedAt": dt.datetime.fromtimestamp(injected, dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                    "deliveredAt": dt.datetime.fromtimestamp(injected + 2, dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                    "deliveryLatencySeconds": 2,
                    "userSequenceNumbers": [index + 1], "successfulToolResults": 1,
                    "finalAssistantMessages": 1,
                })
            recoveries = []
            kills = []
            for index in range(2):
                terminated = started + 200 + index * 100
                recoveries.append({
                    "index": index + 1,
                    "terminatedAt": dt.datetime.fromtimestamp(terminated, dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                    "recoveredAt": dt.datetime.fromtimestamp(terminated + 2, dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                    "helloBefore": index + 1, "helloAfter": index + 2,
                    "wasForeground": True,
                })
                kills.append({
                    "id": f"kill-{index + 1:03d}", "status": "signal-sent",
                    "attemptedAt": dt.datetime.fromtimestamp(terminated - 1, dt.timezone.utc).isoformat().replace("+00:00", "Z"),
                })
            app = {
                "configuration": config, "status": "COMPLETE",
                "runStartedAt": "2026-11-06T00:00:00Z",
                "runEndedAt": "2026-11-06T02:00:01Z",
                "durationReachedAt": "2026-11-06T02:00:00Z",
                "observedLockSeconds": 7201,
                "protectedDataLockObserved": True,
                "protectedDataUnlockObserved": True,
                "lockEndedAt": "2026-11-06T02:00:01Z",
                "p6DeferredCount": 0, "p6ViolationCount": 0,
                "helloFailureCount": 0, "p15FailureCount": 0,
                "modelRequestCount": 4, "events": events, "recoveries": recoveries,
            }
            host = {"durationSeconds": 7200, "expectedKillCount": 2,
                    "killResults": kills, "acquisitionError": None}
            if mutate:
                mutate(app, host)
            write_json(app_dir / "app-report.json", app)
            write_json(directory / "host-report.json", host)
            return analyze(directory)

        passing = fixture("pass")
        assert passing["status"] == "PASS", passing

        def missing_event(app, host):
            app["events"][0]["deliveredAt"] = None
            app["events"][0]["deliveryLatencySeconds"] = None

        missing = fixture("missing", missing_event)
        assert missing["status"] == "FAIL"
        assert not next(check for check in missing["checks"] if check["name"] == "event-delivery")["passed"]

        def blocked(app, host):
            app["recoveries"] = app["recoveries"][:1]
            app["recoveries"][0]["wasForeground"] = False
            app["p6DeferredCount"] = 1
            host["killResults"][1]["status"] = "unavailable"

        p6 = fixture("p6", blocked)
        assert p6["status"] == "FAIL"
        assert "ccr-P08.txt" in p6["ccrFiles"]

        not_run = write_not_run(root / "not-run", "no available physical device")
        assert not_run["status"] == "NOT_RUN"
    print("bot-residency analyzer selftest: PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--acquisition-error")
    parser.add_argument("--write-not-run", action="store_true")
    parser.add_argument("--reason")
    parser.add_argument("--engine-wake", action="store_true",
                        help="analyse the engine-first-launch wake evidence instead of WP1 residency")
    parser.add_argument("--thresholds", type=Path,
                        help="engine-wake: frozen spec/host/v1/golden/engine-launch.json")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if args.output_dir is None:
        parser.error("--output-dir is required")
    if args.engine_wake:
        if args.write_not_run:
            summary = write_engine_wake_not_run(
                args.output_dir, args.reason or "prerequisite unavailable")
        else:
            summary = analyze_engine_wake(args.output_dir, args.thresholds,
                                          args.acquisition_error)
    elif args.write_not_run:
        summary = write_not_run(args.output_dir, args.reason or "prerequisite unavailable")
    else:
        summary = analyze(args.output_dir, args.acquisition_error)
    print(json.dumps({"status": summary["status"], "conclusion": summary["conclusion"],
                      "summary": str(args.output_dir / "summary.json")}, sort_keys=True))
    raise SystemExit(0 if summary["status"] == "PASS" else (3 if summary["status"] == "NOT_RUN" else 1))


if __name__ == "__main__":
    main()
