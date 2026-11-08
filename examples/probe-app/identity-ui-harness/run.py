#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build and run the isolated identity presentation on a new simulator."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MIN_FREE = 2 * 1024 ** 3


def free_space(paths):
    for path in paths:
        if shutil.disk_usage(path).free < MIN_FREE:
            raise RuntimeError(f"less than 2 GiB free on {path}")


def child_processes(root_pid):
    """Find only descendants of the command started by this runner."""
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    pairs = [tuple(map(int, line.split())) for line in output.splitlines() if line.strip()]
    parents, result = {root_pid}, []
    while parents:
        children = {pid for pid, parent in pairs if parent in parents and pid not in result}
        result.extend(children)
        parents = children
    return result


def monitored(args, log, paths, timeout=900):
    free_space(paths)
    print(f"Running {args[0]}; log: {log}", flush=True)
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                free_space(paths)
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"command timed out after {timeout}s; see {log}")
                time.sleep(3)
        except BaseException:
            if process.poll() is None:
                # xcodebuild can spawn simctl in another process group. Stop
                # only descendants of our own command before stopping its
                # group, so a timed-out test does not leave an orphan behind.
                try:
                    descendants = child_processes(process.pid)
                except (OSError, subprocess.CalledProcessError, ValueError):
                    descendants = []
                for child in reversed(descendants):
                    try:
                        os.kill(child, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise
        if process.returncode != 0:
            raise RuntimeError(f"command failed ({process.returncode}); see {log}")


def choose_simulator(runtime_id, device_id):
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
    def version(runtime):
        return tuple(int(part) for part in runtime["version"].split("."))
    available = [r for r in data["runtimes"] if r.get("isAvailable")
                 and r.get("platform") == "iOS" and version(r) >= (17, 0)
                 and (not r.get("supportedArchitectures") or platform.machine() in r["supportedArchitectures"])]
    if runtime_id:
        available = [r for r in available if r["identifier"] == runtime_id]
    available.sort(key=version, reverse=True)
    for runtime in available:
        phones = [d for d in runtime.get("supportedDeviceTypes", []) if d.get("productFamily") == "iPhone"]
        if device_id:
            phones = [d for d in phones if d["identifier"] == device_id]
        if phones:
            return runtime["identifier"], phones[0]["identifier"]
    raise RuntimeError("no available iOS 17+ simulator runtime with a supported iPhone; install one or choose valid IDs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", help="available iOS simulator runtime identifier")
    parser.add_argument("--device-type", help="iPhone simulator device type identifier")
    parser.add_argument("--output-parent", type=Path, default=Path(tempfile.gettempdir()),
                        help="existing directory for a new, retained output directory")
    parser.add_argument("--package-cache", type=Path,
                        help="existing Xcode source-package cache to reuse (Xcode may update it)")
    args = parser.parse_args()
    for command in ("xcodegen", "xcodebuild", "xcrun"):
        if not shutil.which(command):
            raise RuntimeError(f"missing required tool: {command}")
    parent = args.output_parent.resolve(strict=True)
    if not parent.is_dir():
        raise RuntimeError("output parent must be an existing directory")
    if args.package_cache and not args.package_cache.resolve(strict=True).is_dir():
        raise RuntimeError("package cache must be an existing directory")
    runtime, device_type = choose_simulator(args.runtime, args.device_type)
    work = Path(tempfile.mkdtemp(prefix="pdsh-identity-ui-", dir=parent))
    paths = (work, REPO) + ((args.package_cache.resolve(),) if args.package_cache else ())
    print(f"Retained output: {work}\nRuntime: {runtime}\nDevice type: {device_type}", flush=True)

    # The checked-in spec uses relative paths. XcodeGen's local package path
    # is relative to the generated project, so resolve just that path in this
    # private copy when generating the project outside the checkout.
    original = (HERE / "project.yml").read_text(encoding="utf-8")
    marker = "    path: ../../..\n"
    if original.count(marker) != 1:
        raise RuntimeError("unexpected project spec package path")
    spec = work / "project.yml"
    spec.write_text(original.replace(marker, "    path: " + json.dumps(str(REPO)) + "\n"), encoding="utf-8")
    # XcodeGen emits these root-level harness references relative to the
    # generated project directory. Copy only our three test sources there;
    # the product page files remain references to the checkout itself.
    for name in ("Host.swift", "DeviceTaskManagerStub.swift", "IdentityUITests.swift"):
        shutil.copy2(HERE / name, work / name)
    monitored(["xcodegen", "generate", "--spec", str(spec), "--project", str(work),
               "--project-root", str(HERE)], work / "generate.log", paths)
    derived = work / "DerivedData"
    build = ["xcodebuild", "-project", str(work / "IdentityUIHarness.xcodeproj"), "-scheme", "IdentityUI",
             "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
             "-derivedDataPath", str(derived), "-jobs", "2", "CODE_SIGNING_ALLOWED=NO"]
    package_cache = args.package_cache.resolve() if args.package_cache else work / "SourcePackages"
    build += ["-clonedSourcePackagesDirPath", str(package_cache)]
    build += ["build-for-testing"]
    monitored(build, work / "build.log", paths)
    runs = list((derived / "Build" / "Products").glob("*.xctestrun"))
    if len(runs) != 1:
        raise RuntimeError(f"expected one .xctestrun, found {len(runs)}")

    simulator = None
    try:
        free_space(paths)
        # Do not let an interrupt land between creating the simulator and
        # recording the UUID needed by the finally block.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            created = subprocess.check_output(["xcrun", "simctl", "create", "pdsh-identity-ui-" + str(uuid.uuid4()),
                                               device_type, runtime], text=True).strip()
            simulator = str(uuid.UUID(created)).upper()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        print(f"Created task simulator: {simulator}", flush=True)
        monitored(["xcrun", "simctl", "boot", simulator], work / "boot.log", paths)
        monitored(["xcrun", "simctl", "bootstatus", simulator, "-b"], work / "bootstatus.log", paths)
        monitored(["xcodebuild", "-xctestrun", str(runs[0]), "-destination", f"platform=iOS Simulator,id={simulator}",
                   "-only-testing:IdentityUITests/IdentityUITests",
                   "-resultBundlePath", str(work / "result.xcresult"), "test-without-building"],
                  work / "test.log", paths, timeout=180)
        print("Identity UI test passed", flush=True)
    finally:
        if simulator:
            try:
                subprocess.run(["xcrun", "simctl", "shutdown", simulator], check=False, timeout=30)
            except subprocess.TimeoutExpired:
                print(f"Shutdown timed out for task simulator {simulator}; attempting deletion", file=sys.stderr)
            subprocess.run(["xcrun", "simctl", "delete", simulator], check=True, timeout=30)
            print(f"Deleted task simulator: {simulator}", flush=True)


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupt)
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        print(f"identity UI harness failed: {error}", file=sys.stderr)
        sys.exit(1)
