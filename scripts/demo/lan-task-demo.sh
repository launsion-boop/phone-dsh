#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Local, opt-in physical-iPhone demonstration. This is test infrastructure,
# not a production TLS bypass or a switch enabling the shipped task UI.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
products="${PDSH_DEMO_PRODUCTS:-/tmp/pdsh-lzz-device-build/Build/Products}"
phone="${PDSH_DEMO_PHONE:-}"
host="${PDSH_DEMO_HOST:-$(ipconfig getifaddr en0 2>/dev/null || true)}"
if [[ $# -gt 1 ]]; then
  printf '用法：%s [设备发给手机的文本任务]\n' "$0" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  task=$1
else
  printf '设备要交给手机 DSH 的任务：'
  IFS= read -r task
fi
if [[ -z "$task" || -z "$host" || -z "$phone" ]]; then
  printf '缺少任务、局域网 IPv4 或 iPhone UDID；请设置 PDSH_DEMO_PHONE，必要时设置 PDSH_DEMO_HOST。\n' >&2
  exit 2
fi
python3 - "$host" "$task" <<'PY'
import ipaddress, sys
address = ipaddress.ip_address(sys.argv[1])
text = sys.argv[2]
if address.version != 4 or address.is_loopback or address.is_unspecified or not (address.is_private or address.is_link_local):
    raise SystemExit('PDSH_DEMO_HOST 必须是手机可访问的私有局域网 IPv4')
if not 1 <= len(text.encode('utf-8')) <= 768 or any(ord(c) < 32 and c not in '\n\r\t' for c in text):
    raise SystemExit('任务须为 1–768 UTF-8 字节，且不含控制字符')
PY
for binary in python3 openssl xcodebuild rg; do
  command -v "$binary" >/dev/null || { printf '缺少依赖：%s\n' "$binary" >&2; exit 2; }
done
[[ -d "$products" ]] || { printf '缺少真机测试产品目录：%s\n' "$products" >&2; exit 2; }

umask 077
# The local dashboard reads this persistent private DB. Never clear previous
# tasks; each run creates a fresh ID. The DB may contain private task text.
state="$(python3 - "${PDSH_DEMO_STATE_DB:-/tmp/pdsh-prototype-lan-demo/state.sqlite}" <<'PYDB'
from pathlib import Path
import os, stat, sys
p = Path(sys.argv[1]).expanduser().absolute()
p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
parent = p.parent.stat()
if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) & 0o077:
    raise SystemExit('演示数据库目录必须属于当前用户且权限为 0700')
if p.is_symlink(): raise SystemExit('演示数据库不能是符号链接')
if p.exists():
    st = p.stat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
        raise SystemExit('演示数据库必须属于当前用户且权限为 0600')
else:
    fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
print(p)
PYDB
)"
work="$(mktemp -d "${TMPDIR:-/tmp}/pdsh-lan-demo.XXXXXXXX")"
server_pid=''
test_pid=''
xctestrun=''
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  if [[ -n "$test_pid" ]]; then kill "$test_pid" 2>/dev/null || true; wait "$test_pid" 2>/dev/null || true; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
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
if p.name.startswith('pdsh-lan-demo.') and p.is_dir(): shutil.rmtree(p)
PY
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

port="${PDSH_DEMO_PORT:-$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('', 0))
    print(sock.getsockname()[1])
PY
)}"
task_id="demo-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$work/key.pem" -out "$work/cert.pem" \
  -subj "/CN=$host" -addext "subjectAltName=IP:$host" >"$work/openssl.log" 2>&1
openssl x509 -in "$work/cert.pem" -outform DER -out "$work/cert.der"
openssl rand -hex 32 > "$work/token"
python3 "$root/examples/lan-mcp-device/taskctl.py" --state "$state" \
  submit --id "$task_id" --text "$task" > /dev/null
python3 "$root/examples/lan-mcp-device/server.py" \
  --cert "$work/cert.pem" --key "$work/key.pem" --token-file "$work/token" \
  --hostname "$host" --listen "$host" --port "$port" --state "$state" \
  >"$work/server.log" 2>&1 &
server_pid=$!
for _ in {1..100}; do
  if rg -q 'Listening on TLS port' "$work/server.log"; then break; fi
  kill -0 "$server_pid" 2>/dev/null || { printf '局域网参考设备启动失败。\n' >&2; exit 1; }
  sleep 0.1
done
rg -q 'Listening on TLS port' "$work/server.log" || { printf '局域网参考设备启动超时。\n' >&2; exit 1; }

# xctestrun must sit beside the build products: __TESTROOT__ resolves there.
xctestrun="$products/pdsh-lan-demo-$task_id.xctestrun"
python3 - "$products" "$xctestrun" "$work" "$host" "$port" "$task_id" <<'PY'
from pathlib import Path
import base64, os, plistlib, sys
products, output, work = map(Path, sys.argv[1:4])
host, port, task_id = sys.argv[4:]
files = sorted(products.glob('PhoneDSHDevice_iphoneos*-arm64.xctestrun'))
if len(files) != 1:
    raise SystemExit('请先构建唯一的 PhoneDSHDevice 真机测试产品')
config = plistlib.loads(files[0].read_bytes())
env = config['PhoneDSHDeviceTests']['EnvironmentVariables']
env.update({
    'PDSH_TEST_LAN_HOST': host,
    'PDSH_TEST_LAN_PORT': port,
    'PDSH_TEST_LAN_TOKEN': (work / 'token').read_text().strip(),
    'PDSH_TEST_LAN_CERT': base64.b64encode((work / 'cert.der').read_bytes()).decode(),
    'PDSH_TEST_LAN_TASK_ID': task_id,
    'PDSH_TEST_LAN_EXPECT_ANY': '1',
    'PDSH_TEST_LAN_TIMEOUT_SECONDS': '120',
})
with output.open('xb') as stream:
    os.fchmod(stream.fileno(), 0o600)
    plistlib.dump(config, stream)
PY

printf '\n演示：Mac 参考设备 → iPhone phoneDSH → 真实配置的模型 → 设备回执\n'
printf '设备任务：%s\n' "$task"
printf '演示记录保存在本机私有数据库：%s\n' "$state"
printf '等待手机接收任务（手机需解锁并处于前台）……\n'
xcodebuild test-without-building -xctestrun "$xctestrun" \
  -destination "id=$phone" \
  -only-testing:PhoneDSHDeviceTests/RealDeviceTaskModelTests/testLANManagerGrantAndForegroundLifecycle \
  -parallel-testing-enabled NO -resultBundlePath "$work/result.xcresult" >"$work/xcode.log" 2>&1 &
test_pid=$!
set +e
python3 -u - "$state" "$task_id" "$test_pid" <<'PY'
import json, os, sqlite3, sys, time
path, task_id, process = sys.argv[1], sys.argv[2], int(sys.argv[3])
last = None
deadline = time.monotonic() + 150
while time.monotonic() < deadline:
    try:
        with sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=0.5) as db:
            row = db.execute('SELECT phase, terminal FROM tasks WHERE id=?', (task_id,)).fetchone()
    except sqlite3.Error:
        row = None
    if row:
        phase, terminal = row
        if phase != last:
            print({'pending': '设备：等待手机领取', 'queued': '设备：等待手机领取', 'accepted': '手机：已接收，正在执行',
                   'terminal': '设备：已收到最终回执'}.get(phase, f'状态：{phase}'), flush=True)
            last = phase
        if phase == 'terminal' and terminal:
            receipt = json.loads(terminal)
            if receipt.get('action') != 'complete':
                print('设备收到失败回执：', json.dumps(receipt.get('body'), ensure_ascii=False), flush=True)
                raise SystemExit(1)
            body = receipt.get('body') or {}
            output = body.get('output')
            if not isinstance(output, str) or not output:
                print('设备收到的完成结果为空。', flush=True)
                raise SystemExit(1)
            print('\n手机 DSH 返回：\n' + output, flush=True)
            if body.get('truncated'): print('\n（结果按协议上限截断）', flush=True)
            raise SystemExit(0)
    try: os.kill(process, 0)
    except ProcessLookupError: break
    time.sleep(0.5)
print('未观察到设备最终回执。', flush=True)
raise SystemExit(1)
PY
monitor_result=$?
wait "$test_pid"
test_result=$?
test_pid=''
set -e
if [[ $test_result -ne 0 ]]; then
  printf '\n真机测试未通过（退出码 %s）：\n' "$test_result" >&2
  python3 - "$work/xcode.log" <<'PY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text(errors='replace').splitlines():
    if 'error: -[PhoneDSHDeviceTests.' in line or '** TEST EXECUTE' in line:
        print(line)
PY
  exit "$test_result"
fi
if [[ $monitor_result -ne 0 ]]; then exit "$monitor_result"; fi
printf '\n参考设备回执和 iPhone 真机测试均已验证。\n'
printf '演示使用模拟 LAN 设备、测试内连接状态替身和临时证书 pin；正式 App 的 TLS 信任策略未改变。\n'
