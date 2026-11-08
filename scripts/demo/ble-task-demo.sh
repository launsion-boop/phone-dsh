#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Controlled local prototype: paired Mac reference peer + real iPhone Worker.
# This does not enable product BLE tasks, authenticate third-party peripherals,
# modify production grants, or claim ESP32 hardware task support.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
products="${PDSH_DEMO_PRODUCTS:-/tmp/pdsh-lzz-device-build/Build/Products}"
phone="${PDSH_DEMO_PHONE:-}"
result_file='/tmp/pdsh-prototype-ble-result.json'
# This fixed path is dedicated to this prototype; never delete arbitrary paths.
python3 - <<'PY'
from pathlib import Path
p = Path('/tmp/pdsh-prototype-ble-result.json')
if p.exists() or p.is_symlink(): p.unlink()
PY
if [[ $# -ne 0 ]]; then
  printf '用法：PDSH_DEMO_PHONE=<iPhone UDID> %s\n' "$0" >&2
  exit 2
fi
if [[ -z "$phone" ]]; then
  printf '缺少 iPhone UDID；请设置 PDSH_DEMO_PHONE。\n' >&2
  exit 2
fi
for binary in python3 swiftc clang codesign xcodebuild rg; do
  command -v "$binary" >/dev/null || { printf '缺少依赖：%s\n' "$binary" >&2; exit 2; }
done
[[ -d "$products" ]] || { printf '缺少真机测试产品目录：%s\n' "$products" >&2; exit 2; }
umask 077
work="$(mktemp -d "${TMPDIR:-/tmp}/pdsh-ble-demo.XXXXXXXX")"
peer_pid=''
test_pid=''
xctestrun=''
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [[ -n "$test_pid" ]]; then kill "$test_pid" 2>/dev/null || true; wait "$test_pid" 2>/dev/null || true; fi
  if [[ -n "$peer_pid" ]]; then kill "$peer_pid" 2>/dev/null || true; wait "$peer_pid" 2>/dev/null || true; fi
  if [[ -n "$xctestrun" ]]; then python3 - "$xctestrun" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
if p.exists(): p.unlink()
PY
  fi
  python3 - "$work" <<'PY'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.name.startswith('pdsh-ble-demo.') and p.is_dir(): shutil.rmtree(p)
PY
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Avoid silently connecting to an old PDSHRT process from an earlier run.
if pgrep -f '/PDSHRadio.app/Contents/MacOS/PDSHRadio' >/dev/null; then
  printf '已有蓝牙测试外设运行；请先停止旧的 PDSHRadio，再重试。\n' >&2
  exit 1
fi
PDSH_TEST_INSECURE=0 PDSH_TEST_BLE_DEMO_RESULT="$result_file" \
  bash "$root/firmware/tests/run-macos-radio-peer.sh" >"$work/peer.log" 2>&1 &
peer_pid=$!
for _ in {1..200}; do
  if rg -q 'advertising ok' "$work/peer.log"; then break; fi
  kill -0 "$peer_pid" 2>/dev/null || { printf '蓝牙参考外设启动失败。\n' >&2; tail -10 "$work/peer.log" >&2; exit 1; }
  sleep 0.1
done
rg -q 'advertising ok' "$work/peer.log" || { printf '蓝牙参考外设启动超时。\n' >&2; exit 1; }

# XCTest expands __TESTROOT__ relative to this file, so place it beside products.
xctestrun="$products/pdsh-ble-demo-$(python3 -c 'import uuid; print(uuid.uuid4().hex)').xctestrun"
python3 - "$products" "$xctestrun" <<'PY'
from pathlib import Path
import os, plistlib, sys
products, output = map(Path, sys.argv[1:])
files = sorted(products.glob('PhoneDSHDevice_iphoneos*-arm64.xctestrun'))
if len(files) != 1:
    raise SystemExit('请先构建唯一的 PhoneDSHDevice 真机测试产品')
config = plistlib.loads(files[0].read_bytes())
config['PhoneDSHDeviceTests']['EnvironmentVariables']['PDSH_TEST_BLE_PROTOTYPE'] = '1'
with output.open('xb') as stream:
    os.fchmod(stream.fileno(), 0o600)
    plistlib.dump(config, stream)
PY

printf '\n蓝牙演示：已配对的 Mac C 参考设备 → iPhone phoneDSH → 真实配置的模型 → 设备回执\n'
printf '固定测试任务：Hello from device\n'
printf '手机需解锁并处于前台；如出现系统配对提示请核对后确认。\n'
xcodebuild test-without-building -xctestrun "$xctestrun" \
  -destination "id=$phone" \
  -only-testing:PhoneDSHDeviceTests/PrototypeBLERadioDemoTests/testMacBluetoothReferenceDeviceDispatchesRealModelTask \
  -parallel-testing-enabled NO -resultBundlePath "$work/result.xcresult" >"$work/xcode.log" 2>&1 &
test_pid=$!
set +e
wait "$test_pid"
test_result=$?
test_pid=''
set -e
if [[ $test_result -ne 0 ]]; then
  printf '蓝牙真机演示失败（退出码 %s）：\n' "$test_result" >&2
  python3 - "$work/xcode.log" <<'PY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text(errors='replace').splitlines():
    if 'error: -[PhoneDSHDeviceTests.' in line or '** TEST EXECUTE' in line:
        print(line)
PY
  exit "$test_result"
fi
python3 - "$result_file" <<'PY'
from pathlib import Path
import json, sys
p = Path(sys.argv[1])
try: data = json.loads(p.read_text())
except (OSError, ValueError) as error: raise SystemExit(f'未读取到 C 参考设备终态：{error}')
if data.get('transport') != 'ble' or data.get('device') != 'PDSHRT' or data.get('phase') != 'completed':
    raise SystemExit('C 参考设备未提供完成回执')
if data.get('task') != 'Hello from device' or not isinstance(data.get('output'), str) or not data['output']:
    raise SystemExit('C 参考设备任务或输出无效')
print('\n设备真实接收的手机 DSH 回答：\n' + data['output'])
PY
printf '\nMac C 参考设备本地回执与 iPhone 真机测试均已验证。\n'
printf '演示使用受控 Mac 参考外设与测试旁路；不是实体 ESP32 任务验收或生产设备认证。\n'
