#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
python3 - "$repo" "$@" <<'PY'
import pathlib
import platform
import subprocess
import sys
import tempfile
import uuid

repo = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
if args not in ([], ['--ios-simulator']):
    print('usage: legacy-inspection-ui-test.sh [--ios-simulator]', file=sys.stderr)
    sys.exit(2)
simulator = bool(args)
scripts = repo / 'examples/probe-app/scripts'
model = repo / 'examples/probe-app/PhoneDSHProbe/LegacyTaskInspectionModel.swift'
fixture = repo / 'spec/device/v1/golden/legacy-task-inspection-ui.jsonl'


def code_for(error):
    code = error.returncode
    return code if code >= 0 else 128 - code


def run():
    with tempfile.TemporaryDirectory(prefix='pdsh-inspection-ui.') as directory:
        tmp = pathlib.Path(directory)
        binary = tmp / 'legacy-inspection-ui-test'
        if not simulator:
            subprocess.run([
                'swiftc', '-emit-library', '-emit-module', '-module-name', 'PhoneDSHDeviceTasks',
                str(scripts / 'legacy-inspection-ui-stub.swift'),
                '-o', str(tmp / 'libPhoneDSHDeviceTasks.dylib'),
            ], check=True)
            subprocess.run([
                'swiftc', '-parse-as-library', '-I', str(tmp), '-L', str(tmp), '-lPhoneDSHDeviceTasks',
                '-Xlinker', '-rpath', '-Xlinker', str(tmp), str(model),
                str(scripts / 'legacy-inspection-ui-harness.swift'), '-o', str(binary),
            ], check=True)
            subprocess.run([str(binary), str(fixture)], check=True)
            return 0

        if platform.machine() != 'arm64':
            print('iOS 18.4 simulator harness requires an arm64 host', file=sys.stderr)
            return 1
        sdk = subprocess.run(
            ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'],
            check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()
        target = 'arm64-apple-ios18.4-simulator'
        stub = tmp / 'PhoneDSHDeviceTasks.o'
        subprocess.run([
            'xcrun', 'swiftc', '-sdk', sdk, '-target', target, '-parse-as-library',
            '-emit-module', '-emit-object', '-module-name', 'PhoneDSHDeviceTasks',
            '-emit-module-path', str(tmp / 'PhoneDSHDeviceTasks.swiftmodule'),
            str(scripts / 'legacy-inspection-ui-stub.swift'), '-o', str(stub),
        ], check=True)
        subprocess.run([
            'xcrun', 'swiftc', '-sdk', sdk, '-target', target, '-parse-as-library',
            '-I', str(tmp), str(model), str(scripts / 'legacy-inspection-ui-harness.swift'),
            str(stub), '-o', str(binary),
        ], check=True)

        device = None
        booted = False
        result = 0
        try:
            created = subprocess.run([
                'xcrun', 'simctl', 'create', 'pdsh-inspection-ui-' + str(uuid.uuid4()),
                'com.apple.CoreSimulator.SimDeviceType.iPhone-16',
                'com.apple.CoreSimulator.SimRuntime.iOS-18-4',
            ], check=True, text=True, stdout=subprocess.PIPE).stdout.strip()
            # Only the exact newly-created simulator UUID is eligible for cleanup.
            device = str(uuid.UUID(created))
            subprocess.run(['xcrun', 'simctl', 'boot', device], check=True)
            booted = True
            subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'], check=True)
            subprocess.run(['xcrun', 'simctl', 'spawn', device, str(binary), str(fixture)], check=True)
        except subprocess.CalledProcessError as error:
            print('simulator command failed:', error, file=sys.stderr)
            result = code_for(error)
        except KeyboardInterrupt:
            print('simulator test interrupted', file=sys.stderr)
            result = 130
        finally:
            if device is not None:
                for operation in ('shutdown', 'delete'):
                    try:
                        completed = subprocess.run(['xcrun', 'simctl', operation, device])
                        cleanup_code = completed.returncode
                        if cleanup_code < 0:
                            cleanup_code = 128 - cleanup_code
                    except OSError as error:
                        print('simulator cleanup failed:', error, file=sys.stderr)
                        cleanup_code = 1
                    # Shutdown of a never-booted test simulator can fail; still
                    # try deletion and preserve the original test failure.
                    if cleanup_code and (operation != 'shutdown' or booted):
                        print('failed to ' + operation + ' test simulator ' + device, file=sys.stderr)
                        if not result:
                            result = cleanup_code
        return result


try:
    sys.exit(run())
except subprocess.CalledProcessError as error:
    print('command failed:', error, file=sys.stderr)
    sys.exit(code_for(error))
except KeyboardInterrupt:
    print('test interrupted', file=sys.stderr)
    sys.exit(130)
PY
