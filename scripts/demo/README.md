# phoneDSH 设备派任务原型演示

这是给现场联调用的**测试演示**：Mac 上运行 Python 模拟设备，iPhone 测试宿主调用真实 `DeviceTaskManager`、Worker 和手机已配置的模型，再把结果回传到 Mac 的设备数据库。它不打开正式 App 的设备派任务入口，不改变生产 TLS 策略，也不是实体硬件或蓝牙任务验收。

演示使用独立的短期自签证书、设备凭证和 SQLite；证书只由测试宿主的专用 delegate 固定，管理器的连接状态检查使用测试替身。脚本结束后删除临时凭证、证书和临时 xctestrun，停止自己启动的参考设备。为供本机演示看板读取，任务文本和结果保存在仅当前用户可访问的 `/tmp/pdsh-prototype-lan-demo/state.sqlite`；脚本不清空旧记录。可以使用 `PDSH_DEMO_STATE_DB` 指定另一个私有数据库，其父目录必须为 0700、文件为 0600。手机与 Mac 需要在同一局域网；iPhone 需要解锁、连接到 Mac，并已在原 App 中配置可用模型服务。

先使用 Xcode 构建 `PhoneDSHDevice` 真机测试目标，目标须包含 `RealDeviceTaskModelTests.testLANManagerGrantAndForegroundLifecycle` 及 `PDSH_TEST_LAN_EXPECT_ANY` 测试条件。详细签名步骤参见本机交接文档或项目的 XcodeGen 配置；不要把临时签名 spec、凭证或测试 xctestrun 提交。默认读取 `/tmp/pdsh-lzz-device-build/Build/Products`，可用 `PDSH_DEMO_PRODUCTS` 指定其他产品目录；测试产物必须已包含 Worker 资源。

```sh
# 提示输入设备任务，结果直接显示在终端。
PDSH_DEMO_PHONE='<iPhone UDID>' bash scripts/demo/lan-task-demo.sh

# 或直接指定一个任务。
PDSH_DEMO_PHONE='<iPhone UDID>' bash scripts/demo/lan-task-demo.sh '请用一句话介绍你能做什么。'
```

可通过 `PDSH_DEMO_HOST` 指定手机可访问的 Mac 局域网 IPv4，`PDSH_DEMO_PHONE` 指定 iPhone UDID，`PDSH_DEMO_PORT` 指定测试端口。必须提供 `PDSH_DEMO_PHONE`，默认尝试 `en0` 和一个临时端口；不要向外发布临时凭证。

设备收到结果后脚本会显示手机模型的实际输出；模型可能出现事实性错误，输出不能作为已经实现某种设备能力的证明。测试宿主在任务运行后还会执行连接授权、撤销、断线及前后台回归，因此最终 `真机测试` 结果可能晚几秒出现。只有任务记录在设备 SQLite 达到 `terminal/complete`、结果非空且 XCTest 成功，脚本才报告成功；模型故障、超时、空结果、环境不满足或测试失败都会返回非零。正常关闭后本地私有数据库仍保留任务和结果；若要分享结果，请在授权范围内复制终端中实际显示的内容。

## 蓝牙参考外设演示

蓝牙演示使用 **Mac 上的 `PDSHRT` 参考外设**，通过真实 BLE 无线连接和 C Link 状态机，将固定测试任务 `Hello from device` 交给 iPhone 上已配置的真实模型；设备收到并持久化在测试结果文件中的实际回复会显示在本机看板。它不代表实体 ESP32 已通过，也不是正式 App 的蓝牙任务授权。此测试在受控、人工配对的外设上直接使用测试通道，绕开了正式 `BLEDeviceStore` 的任务授权；正式产品针对 GAP-16 的 fail-closed 保持不变，不能用此演示推断设备身份认证已解决。

确保 iPhone 与 Mac 已配对，且无其他同名 `PDSHRT` 外设。推荐一键运行：

```sh
PDSH_DEMO_PHONE='<iPhone UDID>' bash scripts/demo/ble-task-demo.sh
```

脚本自动启动并停止加密参考外设，执行真机测试并展示 C 设备的真实回执。LAN 和 BLE 演示需要顺序运行，不能同时占用同一台 iPhone。看板只监听本机，运行：

```sh
python3 scripts/demo/prototype_board.py --db /tmp/pdsh-prototype-lan-demo/state.sqlite
# 在本机浏览器打开 http://127.0.0.1:18765/
```

也可以手动分步运行。先在一个终端前台启动加密测试 peer，保持该终端运行：

```sh
cd /path/to/phone-dsh
PDSH_TEST_BLE_DEMO_RESULT=/tmp/pdsh-prototype-ble-result.json \
  bash firmware/tests/run-macos-radio-peer.sh
```

另一个终端使用已构建的 `PhoneDSHDevice` 真机测试产品；`PDSH_DEMO_PRODUCTS` 和 `PDSH_DEMO_PHONE` 需按本机环境设置。下面生成的临时 xctestrun 必须放在 Products 目录旁，使 `__TESTROOT__` 正确解析：

```sh
export PDSH_DEMO_PRODUCTS='/path/to/DerivedData/Build/Products'
export PDSH_DEMO_PHONE='<iPhone UDID>'
BLE_RUN=$(python3 - <<'PYBLE'
from pathlib import Path
import os, plistlib, uuid
products = Path(os.environ['PDSH_DEMO_PRODUCTS'])
files = list(products.glob('PhoneDSHDevice_iphoneos*-arm64.xctestrun'))
assert len(files) == 1, files
config = plistlib.loads(files[0].read_bytes())
config['PhoneDSHDeviceTests']['EnvironmentVariables']['PDSH_TEST_BLE_PROTOTYPE'] = '1'
out = products / ('pdsh-ble-demo-' + uuid.uuid4().hex + '.xctestrun')
with out.open('xb') as stream:
    os.fchmod(stream.fileno(), 0o600)
    plistlib.dump(config, stream)
print(out)
PYBLE
)
xcodebuild test-without-building -xctestrun "$BLE_RUN" \
  -destination "id=$PDSH_DEMO_PHONE" \
  -only-testing:PhoneDSHDeviceTests/PrototypeBLERadioDemoTests/testMacBluetoothReferenceDeviceDispatchesRealModelTask \
  -parallel-testing-enabled NO -resultBundlePath /tmp/pdsh-ble-demo-next.xcresult
python3 - "$BLE_RUN" <<'PYCLEAN'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PYCLEAN
```

如系统弹出配对确认，须由用户核对后操作。测试应输出 `PDSH_BLE_DEMO_TASK` 和 `PDSH_BLE_DEMO_OUTPUT`，参考外设另外通过 `PDSH_TEST_BLE_DEMO_RESULT` 写出真实终态给看板。结果目录必须使用新的名称；失败要保留真实失败状态，不要将旧结果当作新一轮成功。测试结束后在 peer 终端按 Ctrl-C。
