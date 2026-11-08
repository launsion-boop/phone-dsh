#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import argparse
import datetime as dt
import json
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


def selftest():
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
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if args.output_dir is None:
        parser.error("--output-dir is required")
    if args.write_not_run:
        summary = write_not_run(args.output_dir, args.reason or "prerequisite unavailable")
    else:
        summary = analyze(args.output_dir, args.acquisition_error)
    print(json.dumps({"status": summary["status"], "conclusion": summary["conclusion"],
                      "summary": str(args.output_dir / "summary.json")}, sort_keys=True))
    raise SystemExit(0 if summary["status"] == "PASS" else (3 if summary["status"] == "NOT_RUN" else 1))


if __name__ == "__main__":
    main()
