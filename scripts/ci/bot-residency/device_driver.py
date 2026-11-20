#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request


def utcnow():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(text):
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


class DeviceDriver:
    def __init__(self, args):
        self.args = args
        self.out = args.output_dir.resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.commands = self.out / "commands"
        self.commands.mkdir(exist_ok=True)
        self.command_index = 0
        self.kills = []
        self.lock_samples = []
        self.state = None
        self.plan = None
        self.acquisition_error = None
        self.last_lock_sample = 0.0
        self.last_announced_phase = None

    def devicectl(self, arguments, quiet=False):
        self.command_index += 1
        stem = f"{self.command_index:06d}"
        json_path = self.commands / f"{stem}.json"
        log_path = self.commands / f"{stem}.log"
        command = ["xcrun", "devicectl", *arguments,
                   "--json-output", str(json_path), "--log-output", str(log_path)]
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        try:
            document = json.loads(json_path.read_text(encoding="utf-8"))
        except Exception:
            document = None
        if completed.returncode != 0 and not quiet:
            detail = log_path.read_text(encoding="utf-8", errors="replace")[-2000:]
            print(f"devicectl failed ({arguments[0]} {arguments[1]}): {detail}", file=sys.stderr)
        return completed.returncode, document

    def device_arguments(self, *arguments):
        return [*arguments, "--device", self.args.device]

    def pull_file(self, name, destination="live"):
        target = self.out / destination
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        source = f"Documents/BotResidencySpike/{self.args.run_id}/{name}"
        rc, _ = self.devicectl(self.device_arguments(
            "device", "copy", "from", "--domain-type", "appDataContainer",
            "--domain-identifier", self.args.bundle_id,
            "--source", source, "--destination", str(target)), quiet=True)
        if rc != 0:
            return None
        matches = list(target.rglob(name))
        if not matches:
            return None
        try:
            return json.loads(matches[0].read_text(encoding="utf-8"))
        except Exception:
            return None

    def sample_lock_state(self):
        rc, document = self.devicectl(self.device_arguments(
            "device", "info", "lockState"), quiet=True)
        locked, key_path = self.extract_locked(document) if rc == 0 else (None, None)
        sample = {"at": utcnow(), "locked": locked, "keyPath": key_path,
                  "readSucceeded": rc == 0}
        self.lock_samples.append(sample)
        with (self.out / "lock-samples.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(sample, sort_keys=True) + "\n")

    @classmethod
    def extract_locked(cls, document):
        candidates = []

        def walk(value, path=""):
            if isinstance(value, dict):
                for key, child in value.items():
                    walk(child, f"{path}.{key}" if path else key)
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    walk(child, f"{path}[{index}]")
            elif "lock" in path.rsplit(".", 1)[-1].lower():
                candidates.append((path, value))

        walk(document)
        for path, value in candidates:
            if isinstance(value, bool):
                return value, path
            if isinstance(value, str):
                folded = value.strip().lower()
                if folded in {"locked", "true", "yes", "1"}:
                    return True, path
                if folded in {"unlocked", "false", "no", "0"}:
                    return False, path
        return None, None

    @staticmethod
    def dictionaries(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from DeviceDriver.dictionaries(child)
        elif isinstance(value, list):
            for child in value:
                yield from DeviceDriver.dictionaries(child)

    @classmethod
    def webcontent_process(cls, document, pid):
        for record in cls.dictionaries(document):
            scalar_text = []

            def collect(value):
                if isinstance(value, dict):
                    for child in value.values():
                        collect(child)
                elif isinstance(value, list):
                    for child in value:
                        collect(child)
                elif isinstance(value, (str, int, float, bool)):
                    scalar_text.append(str(value))

            collect(record)
            if not any("webcontent" in text.lower() for text in scalar_text):
                continue
            for key, value in record.items():
                normalized = key.replace("_", "").replace("-", "").lower()
                if normalized not in {"pid", "processid", "processidentifier"}:
                    continue
                candidates = [value]
                if isinstance(value, dict):
                    candidates.extend(value.values())
                if any(str(candidate) == str(pid) for candidate in candidates):
                    return record
        return None

    def refresh_state(self):
        state = self.pull_file("state.json")
        if state is not None:
            self.state = state
            phase = state.get("phase")
            if phase != self.last_announced_phase:
                self.last_announced_phase = phase
                print(f"app phase={phase} detail={state.get('detail')}", flush=True)
            if state.get("runStartedAt") and self.plan is None:
                self.plan = self.pull_file("plan.json")
                if self.plan is not None:
                    self.prepare_kills()
        return self.state

    def prepare_kills(self):
        started = parse_time(self.plan["startedAt"])
        self.kills = [{
            "id": action["id"],
            "scheduledOffsetSeconds": action["offsetSeconds"],
            "scheduledAt": dt.datetime.fromtimestamp(
                started + action["offsetSeconds"], dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "status": "pending",
        } for action in self.plan.get("kills", [])]
        write_json(self.out / "kill-results.json", self.kills)
        print(f"loaded {len(self.kills)} seeded WebContent kills", flush=True)

    def run_kill(self, kill):
        self.refresh_state()
        kill["attemptedAt"] = utcnow()
        pid = (self.state or {}).get("webContentPID")
        kill["pid"] = pid
        if not isinstance(pid, int) or pid <= 0:
            kill["status"] = "unavailable"
            kill["reason"] = "no live WebContent PID; P6 may be holding recovery until foreground"
        else:
            rc, processes = self.devicectl(self.device_arguments(
                "device", "info", "processes"), quiet=True)
            record = self.webcontent_process(processes, pid) if rc == 0 else None
            if record is None:
                kill["status"] = "identity-unverified"
                kill["reason"] = "devicectl did not prove that the app-reported PID is a live WebContent process"
            else:
                kill["processRecord"] = record
                rc, result = self.devicectl(self.device_arguments(
                    "device", "process", "signal", "--pid", str(pid), "--signal", "9"))
                kill["signalCommandSucceeded"] = rc == 0
                kill["status"] = "signal-sent" if rc == 0 else "signal-failed"
                if rc != 0:
                    kill["reason"] = "devicectl SIGKILL failed"
                kill["commandOutcome"] = (result or {}).get("info", {}).get("outcome")
        print(f"{kill['id']}: {kill['status']} pid={kill.get('pid')} {kill.get('reason', '')}", flush=True)
        write_json(self.out / "kill-results.json", self.kills)

    def final_pull(self):
        target = self.out / "device"
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        rc, _ = self.devicectl(self.device_arguments(
            "device", "copy", "from", "--domain-type", "appDataContainer",
            "--domain-identifier", self.args.bundle_id,
            "--source", f"Documents/BotResidencySpike/{self.args.run_id}",
            "--destination", str(target)))
        if rc != 0:
            self.acquisition_error = "could not pull the app evidence directory"
        return list(target.rglob("app-report.json"))

    def write_host_report(self):
        write_json(self.out / "host-report.json", {
            "schema": "phonedsh-bot-residency-host/1",
            "runID": self.args.run_id,
            "durationSeconds": self.args.duration_seconds,
            "expectedKillCount": self.args.kill_webcontent,
            "startedAt": self.args.started_at,
            "endedAt": utcnow(),
            "acquisitionError": self.acquisition_error,
            "killResults": self.kills,
            "lockSampleCount": len(self.lock_samples),
            "lockSamplesReadSucceeded": sum(1 for sample in self.lock_samples if sample["readSucceeded"]),
        })

    def run(self):
        deadline = time.monotonic() + self.args.timeout_seconds
        try:
            while time.monotonic() < deadline:
                now = time.monotonic()
                if now - self.last_lock_sample >= 5:
                    self.sample_lock_state()
                    self.last_lock_sample = now
                self.refresh_state()
                wall = time.time()
                for kill in self.kills:
                    if kill["status"] == "pending" and wall >= parse_time(kill["scheduledAt"]):
                        self.run_kill(kill)
                terminal = (self.state or {}).get("phase") in {"complete", "aborted"}
                kills_settled = all(kill["status"] != "pending" for kill in self.kills)
                if terminal and kills_settled:
                    time.sleep(1)
                    break
                time.sleep(self.args.poll_seconds)
            else:
                self.acquisition_error = "device run exceeded the driver timeout"
            reports = self.final_pull()
            for _ in range(5):
                if reports or self.acquisition_error:
                    break
                time.sleep(1)
                reports = self.final_pull()
            if not reports and not self.acquisition_error:
                self.acquisition_error = "app-report.json is missing"
            return 0 if reports else 1
        except Exception as error:
            self.acquisition_error = f"device driver failed: {error}"
            self.final_pull()
            return 1
        finally:
            self.write_host_report()


class EngineWakeDriver:
    """Host side of the engine-first-launch wake measurement.

    The app owns the scenarios and writes ``engine-wake-state.json`` /
    ``engine-wake-report.json``. This driver only polls that state, performs the
    LAN probes the app asks for, prints the instructions for an external APNs /
    board trigger, and pulls the final evidence. It never invents a trigger.
    """

    def __init__(self, args):
        self.args = args
        self.out = args.output_dir.resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        self.commands = self.out / "commands"
        self.commands.mkdir(exist_ok=True)
        self.command_index = 0
        self.state = None
        self.last_state_key = None
        self.last_trigger_key = None
        self.acquisition_error = None
        self.lan_probes = []
        self.probe_attempts = {}
        self.last_probe_at = 0.0
        self.last_pushed_trigger = None
        self.started_at = utcnow()

    def devicectl(self, arguments, quiet=False):
        self.command_index += 1
        stem = f"{self.command_index:06d}"
        json_path = self.commands / f"{stem}.json"
        log_path = self.commands / f"{stem}.log"
        command = ["xcrun", "devicectl", *arguments,
                   "--json-output", str(json_path), "--log-output", str(log_path)]
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        try:
            document = json.loads(json_path.read_text(encoding="utf-8"))
        except Exception:
            document = None
        if completed.returncode != 0 and not quiet:
            detail = log_path.read_text(encoding="utf-8", errors="replace")[-2000:]
            print(f"devicectl failed ({arguments[0]} {arguments[1]}): {detail}", file=sys.stderr)
        return completed.returncode, document

    def device_arguments(self, *arguments):
        return [*arguments, "--device", self.args.device]

    def simulator_container(self):
        completed = subprocess.run(
            ["xcrun", "simctl", "get_app_container", self.args.simulator_udid,
             self.args.bundle_id, "data"],
            text=True, capture_output=True, check=False)
        if completed.returncode != 0:
            return None
        path = Path(completed.stdout.strip())
        return path if path.is_dir() else None

    def pull_file(self, name, destination="live"):
        target = self.out / destination
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        if self.args.platform == "simulator":
            root = self.simulator_container()
            if root is None:
                return None
            source = root / "Documents" / "BotResidencySpike" / self.args.run_id / name
            if not source.exists():
                return None
            shutil.copy2(source, target / name)
        else:
            source = f"Documents/BotResidencySpike/{self.args.run_id}/{name}"
            rc, _ = self.devicectl(self.device_arguments(
                "device", "copy", "from", "--domain-type", "appDataContainer",
                "--domain-identifier", self.args.bundle_id,
                "--source", source, "--destination", str(target)), quiet=True)
            if rc != 0:
                return None
        matches = list(target.rglob(name))
        if not matches:
            return None
        try:
            return json.loads(matches[0].read_text(encoding="utf-8"))
        except Exception:
            return None

    @staticmethod
    def probe_url(host, port, scenario):
        return f"http://{host}:{port}/engine-wake?scenario={scenario}"

    def probe(self, pending):
        scenario = pending.get("scenario")
        port = pending.get("port")
        host = self.args.lan_host or pending.get("lanHost")
        attempt = self.probe_attempts.get(pending.get("id"), 0) + 1
        self.probe_attempts[pending.get("id")] = attempt
        record = {
            "scenario": scenario,
            "probeID": pending.get("id"),
            "attempt": attempt,
            "sentAt": utcnow(),
            "host": host,
            "port": port,
            "reachable": False,
        }
        if not host or not isinstance(port, int) or port <= 0:
            record["error"] = ("no --lan-host and the app did not report a reachable "
                              "address; pass --lan-host <device-LAN-IP>")
            record["skipped"] = True
            self.lan_probes.append(record)
            print(f"lan-probe {pending.get('id')}: SKIPPED — {record['error']}", flush=True)
            self.last_probe_at = time.monotonic()
            return
        url = self.probe_url(host, port, scenario)
        started = time.monotonic()
        try:
            with urllib.request.urlopen(url, timeout=self.args.probe_timeout_seconds) as response:
                body = response.read(64).decode("utf-8", "replace")
                record["httpStatus"] = response.status
                record["body"] = body
                record["reachable"] = 200 <= response.status < 300
        except urllib.error.HTTPError as error:
            record["httpStatus"] = error.code
            record["error"] = f"HTTP {error.code}"
        except Exception as error:
            record["error"] = str(error)
        record["elapsedMs"] = round((time.monotonic() - started) * 1000, 3)
        record["completedAt"] = utcnow()
        self.lan_probes.append(record)
        print(f"lan-probe {pending.get('id')} #{attempt} {scenario}: "
              f"reachable={record['reachable']} elapsed={record.get('elapsedMs')}ms "
              f"{record.get('error', '')}", flush=True)
        self.last_probe_at = time.monotonic()

    def service_probe(self, state):
        if not isinstance(state, dict):
            return
        pending = state.get("pendingProbe")
        if not isinstance(pending, dict) or not pending.get("id"):
            return
        now = time.monotonic()
        delay = pending.get("probeDelaySeconds")
        delay = delay if isinstance(delay, (int, float)) else 0
        first_probe = self.probe_attempts.get(pending.get("id"), 0) == 0
        if first_probe and now - self.last_probe_at < delay:
            return
        if not first_probe and now - self.last_probe_at < 2.0:
            return
        self.probe(pending)

    def announce(self, state):
        if not isinstance(state, dict):
            return
        phase = state.get("phase")
        scenario = state.get("currentScenario")
        key = (phase, scenario, state.get("detail"))
        if key != self.last_state_key:
            self.last_state_key = key
            print(f"engine-wake phase={phase} scenario={scenario} "
                  f"detail={state.get('detail')}", flush=True)
        trigger = state.get("pendingTrigger")
        if isinstance(trigger, dict) and trigger.get("id"):
            trigger_key = trigger.get("id")
            if trigger_key != self.last_trigger_key:
                self.last_trigger_key = trigger_key
                print("", flush=True)
                print(f"== ACTION REQUIRED: {trigger_key} ==", flush=True)
                print(trigger.get("instructions") or
                      "Trigger the wake on the device, then leave the device idle.", flush=True)
                print("", flush=True)

    def service_trigger(self, state):
        """Simulator only: inject the content-available push the app is waiting for.

        On a physical device the operator sends the APNs test push; the script
        must not pretend it can create one, so this method is a no-op there.
        """
        if self.args.platform != "simulator" or not self.args.simctl_push_udid:
            return
        trigger = state.get("pendingTrigger")
        if not isinstance(trigger, dict) or trigger.get("kind") != "push":
            return
        key = trigger.get("id")
        if key == self.last_pushed_trigger:
            return
        payload = self.out / "push-payload.json"
        if not payload.exists():
            write_json(payload, {
                "Simulator Target Bundle": self.args.bundle_id,
                "aps": {"content-available": 1},
                "pdsh": {"kind": "engine-wake", "trigger": key},
            })
        completed = subprocess.run(
            ["xcrun", "simctl", "push", self.args.simctl_push_udid,
             self.args.bundle_id, str(payload)],
            text=True, capture_output=True, check=False)
        if completed.returncode == 0:
            self.last_pushed_trigger = key
            print(f"simctl push sent for {key}", flush=True)
        else:
            print(f"simctl push failed for {key}: {completed.stderr.strip()}", file=sys.stderr)

    def final_pull(self):
        target = self.out / "device"
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        if self.args.platform == "simulator":
            root = self.simulator_container()
            if root is None:
                self.acquisition_error = "could not locate the simulator app container"
                return []
            source = root / "Documents" / "BotResidencySpike" / self.args.run_id
            if not source.is_dir():
                self.acquisition_error = f"simulator evidence directory is missing: {source}"
                return []
            shutil.copytree(source, target / "run")
        else:
            rc, _ = self.devicectl(self.device_arguments(
                "device", "copy", "from", "--domain-type", "appDataContainer",
                "--domain-identifier", self.args.bundle_id,
                "--source", f"Documents/BotResidencySpike/{self.args.run_id}",
                "--destination", str(target)))
            if rc != 0:
                self.acquisition_error = "could not pull the app evidence directory"
        return list(target.rglob("engine-wake-report.json"))

    def write_host_report(self):
        write_json(self.out / "host-report.json", {
            "schema": "phonedsh-engine-wake-host/1",
            "mode": "engine-wake",
            "runID": self.args.run_id,
            "startedAt": self.started_at,
            "endedAt": utcnow(),
            "acquisitionError": self.acquisition_error,
            "platform": self.args.platform,
            "lanHost": self.args.lan_host,
            "lanProbes": self.lan_probes,
            "lastPhase": (self.state or {}).get("phase") if isinstance(self.state, dict) else None,
        })

    def run(self):
        deadline = time.monotonic() + self.args.timeout_seconds
        while time.monotonic() < deadline:
            state = self.pull_file("engine-wake-state.json")
            if state is not None:
                self.state = state
                self.announce(state)
                self.service_trigger(state)
                self.service_probe(state)
                if state.get("phase") in {"complete", "aborted"}:
                    self.final_pull()
                    if list((self.out / "device").rglob("engine-wake-report.json")):
                        break
            time.sleep(self.args.poll_seconds)
        else:
            self.acquisition_error = "device run exceeded the driver timeout"
        reports = self.final_pull()
        for _ in range(5):
            if reports or self.acquisition_error:
                break
            time.sleep(1)
            reports = self.final_pull()
        if not reports and not self.acquisition_error:
            self.acquisition_error = "engine-wake-report.json is missing"
        self.write_host_report()
        return 0 if reports else 1


def selftest():
    document = {"result": {"processes": [
        {"processIdentifier": 42, "executable": "/System/Library/com.apple.WebKit.WebContent"},
        {"processIdentifier": 43, "executable": "/usr/libexec/notifyd"},
    ]}}
    assert DeviceDriver.webcontent_process(document, 42) is not None
    assert DeviceDriver.webcontent_process(document, 43) is None
    assert DeviceDriver.webcontent_process(document, 44) is None
    nested = {"result": {"lockState": {"isLocked": True}}}
    assert DeviceDriver.extract_locked(nested) == (True, "result.lockState.isLocked")
    nested["result"]["lockState"]["isLocked"] = False
    assert DeviceDriver.extract_locked(nested) == (False, "result.lockState.isLocked")
    assert DeviceDriver.extract_locked({"result": {}}) == (None, None)
    assert EngineWakeDriver.probe_url("192.168.1.8", 8123, "lan-resident") == \
        "http://192.168.1.8:8123/engine-wake?scenario=lan-resident"
    print("bot-residency device driver selftest: PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("residency", "engine-wake"), default="residency")
    parser.add_argument("--platform", choices=("device", "simulator"), default="device")
    parser.add_argument("--device")
    parser.add_argument("--simulator-udid")
    parser.add_argument("--simctl-push-udid")
    parser.add_argument("--bundle-id")
    parser.add_argument("--run-id")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--duration-seconds", type=int)
    parser.add_argument("--kill-webcontent", type=int)
    parser.add_argument("--timeout-seconds", type=int)
    parser.add_argument("--poll-seconds", type=float, default=2.0)
    parser.add_argument("--lan-host",
                        help="engine-wake: device LAN address used for the listener probes")
    parser.add_argument("--probe-timeout-seconds", type=float, default=3.0)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    required = ["bundle_id", "run_id", "output_dir", "timeout_seconds"]
    if args.platform == "simulator":
        required.append("simulator_udid")
    else:
        required.append("device")
    if args.mode == "residency":
        required += ["duration_seconds", "kill_webcontent"]
    for name in required:
        if getattr(args, name) is None:
            parser.error(f"--{name.replace('_', '-')} is required")
    if args.poll_seconds < 0.25:
        parser.error("--poll-seconds must be at least 0.25")
    if args.mode == "engine-wake":
        if args.probe_timeout_seconds <= 0:
            parser.error("--probe-timeout-seconds must be positive")
        if args.platform == "simulator" and args.simctl_push_udid is None:
            args.simctl_push_udid = args.simulator_udid
        raise SystemExit(EngineWakeDriver(args).run())
    args.started_at = utcnow()
    raise SystemExit(DeviceDriver(args).run())


if __name__ == "__main__":
    main()
