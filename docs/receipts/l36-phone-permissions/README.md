# L36 — 把 `:domain` 的设备能力读数接到「手机权限」页

> 范围：`android/domain/.../device/AndroidHostPermissions.kt`（新增读数）、
> `AndroidDeviceCapabilities.kt`（补一个免 manifest 的 `platformFacts(context)`，读法不变）、
> `android/app/.../probe/HostPhonePermissions.kt`（新增：23 行映射）、
> `HostNavFacts.kt` / `ProbeEngineViewModel.kt`（读数进宿主快照）、`HostShell.kt`（一行过期注释）、
> `android/lib/.../ui/nav/PdshNavFacts.kt` + `PdshNavHost.kt`（**只接线**：facts 多一个字段，
> 路由把 `PhonePermissionsFacts()` 换成 `facts.phonePermissions`），`android/app/build.gradle.kts`
> （`:app` 的 JVM 测试依赖），以及本目录。
> **未改**：`spec/**`、`Sources/**`、`examples/**`、`plugins/**`、`shell/**`、`android/core/**`、
> `android/dsh/**`、`android/engine/**`、`preview/**`、**任何页面实现文件**——特别是
> `PhonePermissionsPage.kt`（`git status` 对它零改动）。**没有任何 git 写操作。**
> 设备：自建 AVD `pdsh_l36`（android-35 / google_apis / pixel_6 / 1080×2400@420，端口 **5680**，
> `-no-window`），用完已删（5556 / 5558 / 5670–5678 未触碰）。截图见 `screens/`。

---

## 0. 结论

1. **「手机权限」页第一次有了真实读数**：宿主的 `PdshNavFacts.phonePermissions` 来自
   `AndroidHostPermissions`（合并 manifest 的权限、授权态、设备管理员否决、通知 app-op、
   DND 访问、硬件/服务存在性），经 `HostPhonePermissions` 逐行映射成页面的七个状态之一。
   页面文件一行未改，只换了路由传进去的 facts。
2. **读得到的报真状态**：`通知`（POST_NOTIFICATIONS + app-op）、`专注模式`（DND 访问）、
   `设备状态`（常开），以及"设备真的没有这项能力"的 `当前设备不可用`——实测该 AVD 上
   `运动与健身`（无计步传感器）、`面容确认`（有指纹硬件但无安全锁屏）、`提醒事项`/`实时活动`/
   `快捷指令`/`家庭`（Android 无此框架）。
3. **读不到的保持不报**：合并 manifest 只声明了 `INTERNET` + WorkManager 带的
   `POST_NOTIFICATIONS`/`FOREGROUND_SERVICE` 等，`READ_CONTACTS`/`CAMERA`/`RECORD_AUDIO`/
   `ACCESS_FINE_LOCATION`/`ACTIVITY_RECOGNITION`/媒体/蓝牙权限一律没声明。没有声明就没有
   OS 授权态可读，于是 15 行不给状态——**不拿「当前设备不可用」冒充**（设备明明有相机）。
4. **`audit` 保持 `null`**：本宿主没有能力使用审计（引擎的 tool 调用不报它用了哪个设备能力，
   设备连接页的发话是内存 fixture），页面显示「宿主没有报告使用审计，暂不判断有没有记录。」
5. **`LocalDeviceManifest` 没换**：`PdshNavHost.kt` 的 demo manifest 是刻意的 fixture（见 §5）。
6. **`AndroidDeviceCapabilities` 现在有生产引用了**：新增的 `platformFacts(context)` 被
   `ProbeEngineViewModel.hostReadings()` 调用（读数半边进生产），manifest 那半边仍没有真实
   manifest 可发布（见 §5、§8）。
7. 验证：`:lib:compileDebugKotlin`、`:lib:testDebugUnitTest`、`:app:assembleDebug`、
   `:app:testDebugUnitTest`（9 个新测试）、`:domain:testDebugUnitTest` 全绿；`:domain` 的
   6 个新 instrumented 测试在 5680 上跑过。

---

## 1. 23 项逐条对照

图例：**已允许**=`Authorized`、**未请求**=`NotDetermined`、**已拒绝**=`Denied`、
**受系统限制**=`Restricted`、**当前设备不可用**=`Unavailable`。`—` = 不报状态（页面不画状态行）。

| # | 能力 | Android 的真实读数 | 报什么 | 理由 |
|---|------|--------------------|--------|------|
| 1 | 通讯录 | `READ_CONTACTS` 是否声明/授权 | —（本 App 未声明）；声明且授权→已允许 | 未声明时系统报不出授权态；设备有联系人数据，不能报不可用 |
| 2 | 日历 | `READ_CALENDAR` | 同上 | 同上 |
| 3 | 提醒事项 | 无：Android 没有系统提醒事项框架/数据库 | 当前设备不可用 | 平台没有这项能力（不是权限问题） |
| 4 | 健康 | Health Connect **存在性对 App 不可见**（见 §4） | — | 本 App 未声明任何 health 权限；模块存在性读不到，不猜 |
| 5 | 照片 | API 33+ `READ_MEDIA_IMAGES`，以下 `READ_EXTERNAL_STORAGE` | —（未声明）；授权→已允许 | Android 14+ 的部分授权（`READ_MEDIA_VISUAL_USER_SELECTED`）不映射 `Limited`：系统不给已选数量，`部分允许（N）` 的 N 是编的 |
| 6 | 相机 | `FEATURE_CAMERA_ANY` + `CAMERA` | 无硬件→不可用；有硬件未声明→— | 该 AVD 有 `camera.any` |
| 7 | 麦克风 | `FEATURE_MICROPHONE` + `RECORD_AUDIO` | 同上 | 该 AVD 有麦克风 |
| 8 | 语音识别 | `SpeechRecognizer.isRecognitionAvailable` + `RECORD_AUDIO` | 无识别服务→不可用；有服务未声明→— | 该 AVD 有识别服务（AiAiSpeechRecognitionService），故不报不可用 |
| 9 | 定位 | `FEATURE_LOCATION` + `ACCESS_FINE/COARSE` | 无→不可用；有未声明→— | 该 AVD 有 GPS |
| 10 | 运动与健身 | 计步传感器 + `ACTIVITY_RECOGNITION` | 无传感器→不可用；有未声明→— | 该 AVD **没有**计步传感器 → 实测不可用 |
| 11 | 蓝牙 | `FEATURE_BLUETOOTH` + 适配器 + `BLUETOOTH_SCAN`(31+)/`BLUETOOTH` | 无适配器→不可用；有未声明→— | 该 AVD 有蓝牙 feature |
| 12 | 本地网络 | 无：Android 没有局域网授权 | — | 没有任何授权态可读；不拿「已允许」冒充（见 §4 的页面副作用） |
| 13 | 通知 | `POST_NOTIFICATIONS`(33+) 声明/授权 + `areNotificationsEnabled()` | 授权且 app-op 开→已允许；app-op 关→已拒绝；已声明未授权→未请求 | 唯一"读完能真的变绿"的行：`pm grant` 后实测变已允许，`pm revoke` 后回到无状态 |
| 14 | 面容确认 | 生物识别硬件 + `KeyguardManager.isDeviceSecure` | 无硬件或无安全锁屏→不可用；两者都有→— | 它本来就不是系统授权（页面自己的说明），可测的只有"能不能做" |
| 15 | 专注模式 | `isNotificationPolicyAccessGranted` | 有 DND 访问→已允许；无→未请求 | 读免打扰状态需要这个访问权；本 App 从未申请过 |
| 16 | 实时活动 | 无：API 35 没有公开的 live-activity API | 当前设备不可用 | 平台没有（Android 16 的 Live Updates 是通知样式，不是本行说的"活动"） |
| 17 | 快捷指令 | 无：Android 没有系统级跨 App 快捷指令 | 当前设备不可用 | 平台没有 |
| 18 | 文件与文件夹 | SAF，按 URI 授权 | — | 还没选过目录，没有授权态 |
| 19 | 剪贴板 | 无权限；Android 10+ 仅前台可读 | — | 平台策略，不是本机授权态；不据此报已允许 |
| 20 | 设备状态 | 无需权限，宿主确实在读型号/API/时间 | 已允许（页面照旧显示常开） | 没有任何东西 gate 它 |
| 21 | 后台定位 | `ACCESS_BACKGROUND_LOCATION`(29+) | 无定位→不可用；有未声明→— | 同定位 |
| 22 | 家庭 | 无：Android 没有 HomeKit | 当前设备不可用 | 平台没有 |
| 23 | 音乐 | MediaStore 音频 + 第 3 方播放器 | — | 没有"系统音乐目录"服务，但 MediaStore 那条路存在，不敢说整机没有 |

页面可见结果（实测，见 `screens/`）：`提醒事项`/`运动与健身`/`面容确认`/`实时活动`/`快捷指令`/`家庭`
= 当前设备不可用；`设备状态` = 常开；`通知` = 已允许（`pm grant` 后）/ 无状态（`pm revoke` 后）；
其余 18 行不画状态行（16 行没读 + `通知`/`专注模式` 两行未请求）。

---

## 2. 在 Android 上**不存在**的状态怎么处理

| 状态 | Android 对应物 | 本车道怎么报 |
|------|----------------|--------------|
| `Limited`（部分允许 N） | Android 14+ 有 `READ_MEDIA_VISUAL_USER_SELECTED`（13 只有全有/全无） | **不映射**：系统不告诉 App 已选数量，`部分允许（N）` 的 N 只能编。测试 `aPartialPhotoGrantIsNotFabricatedAsLimited` 钉住 |
| `Restricted`（家长控制） | `DevicePolicyManager.getPermissionGrantState(admin, pkg, perm) == DENIED` | **真映射**：只有"有活跃 admin 且明确否决该权限"才报受系统限制；无 admin = 无限制（读数，不是默认） |
| `Requested`（已请求但结果不可观察） | 无：Android 的请求回调是即时的 | **不报**（除非将来出现"请求发出但结果不可读"的 API） |
| `NotDetermined`（未请求） | Android 无公开的"是否问过"标记（`PackageManager.getPermissionFlags` 是 `@SystemApi`） | **只在两种情形报**：① 权限已声明、未授权，且本 App 从不调 `requestPermissions`（`未请求` 因此为真）；② 没有 DND 访问。这是 android 与 iOS 模型差距最大的一处，见 §8 |
| `Unavailable`（当前设备不可用） | 硬件/OS 版本没有 | **只在平台层面缺失时报**：无硬件、无服务、Android 没有该框架。**不**用于"本 App 没声明该权限"——设备有相机时说相机不可用是假话 |

---

## 3. 接线：数据怎么从设备走到页面

```
AndroidDeviceCapabilities.platformFacts(context)   // :domain，本次新增的免 manifest 入口
        └─ AndroidPlatformFacts(sdkInt, display, webView, foregroundService, memory)
AndroidHostPermissions(context, platform).read()   // :domain，本次新增
        └─ HostPermissionReadings（声明/授权/管理员否决/通知 app-op/DND/硬件…）
HostPhonePermissions.phonePermissionsFacts(...)    // :app，本次新增：23 行映射，audit = null
        └─ PhonePermissionsFacts(statuses = …)
PdshNavFacts.phonePermissions                      // :lib 新字段，默认 PhonePermissionsFacts()
        └─ PhonePermissionsRoute(facts) → PhonePermissionsScreenState.from(facts.phonePermissions)
```

页面与 `PhonePermissionsPage.kt` 零改动。

---

## 4. 顺带查出来的三个页面/模型缺陷（本车道不改页面）

1. **`statuses` 表达不了"逐行未知"**。`Map<PhoneCapability, PhoneCapabilityStatus>` 的值不可为
   null，而页面把"缺失的键"当成 `NotDetermined`（`PhonePermissionsPage.kt:604`），
   `NotDetermined` 又不画状态行（`:650`）。所以：
   * 想显示「未知」→ 只能整个 `statuses = null`（那就所有行都未知，读到的也没了）；
   * 想显示读到的行 → 没读的行只能是"不画状态行"（页面语义上是 `未请求`，且行变成可点）。
   本车道选了后者，并把 16 个没读的行排除在 map 之外；**它们不会印「未知」二字**。
   要真正的逐行未知，`PhonePermissionsFacts.statuses` 得允许 null 值或加一个"未读"状态——页面文件。
2. **`本地网络` 会给一个假承诺**。缺失的键 → `NotDetermined`，而页面特判本地网络打印
   `未验证 · 点击测试`（`:641`）。本宿主没有那个"点击测试"，这个标签是页面替我们许的。
   测试 `anUnreadLocalNetworkRowStillPrintsThePagesClickTestLabel` 把这一行为钉住而不是藏起来。
3. **`健康` 的"存在性"普通 App 读不到**。Android 11+ 的包可见性对 `getPackageInfo` 和
   `getPermissionInfo` 都生效：adb shell 能看到 `android.permission.health.READ_EXERCISE_ROUTE`，
   App 里同样的查询返回 NameNotFound。本车道第一版用 `READ_STEPS` 探测，实测把**装有 Health
   Connect** 的 AVD 报成了 `当前设备不可用`——已删掉该读数（截图前的回归），现在该行不报状态。
   要真检测，需要 `<queries>` 或 `androidx.health.connect:connect-client`。

---

## 5. `LocalDeviceManifest` 与 demo manifest：没换，理由

* `PdshNavHost.kt:1123` 的 `demoDeviceManifest` 是**设备连接演示**的 fixture：一部 ESP32
  （`esp32-8c4f01`，`audio.tts/opus`、`render.pixel/64×64/rgb565`），旁边的
  `DeviceConnectionRoute`/`DeviceSessionRoute` 都带「演示数据」横幅。它描述的是**对端设备**。
* `LocalDeviceManifest.of(identity, capabilities, facts)` 描述的是**本机作为被发现的设备**，
  需要 `LocalDeviceIdentity`（deviceId / protocol / limits / pairing）——这些是本仓在
  `LocalDeviceManifest` 里明确拒绝"发明"的输入（"A guessed max_frame_bytes is a contract
  defect"）。拿它去填 ESP32 fixture，等于把手机发布成一部 ESP32。
* 所以：**fixture 保留**（刻意，不是偷懒），判断写在 `HostPhonePermissionsTest` 之外的
  代码注释里没有改动 demo 代码；`AndroidDeviceCapabilities` 的读数半边则通过
  `platformFacts(context)` 进了生产（`ProbeEngineViewModel.hostReadings()`），
  manifest 那半边仍然只有测试与（将来）设备连接器会用——本机没有可发布的真实 manifest。

---

## 6. 设备证据

自建 AVD `pdsh_l36`（android-35，端口 5680），装 `app-debug.apk`，抽屉 → 设置 → 「手机权限」tab。

| 截图 | 看到什么 |
|------|----------|
| `screens/01-top.png` | 个人信息组：`提醒事项` = 当前设备不可用（灰、开关禁用）；`通讯录`/`日历`/`健康`/`照片`/`相机`/`麦克风`/`语音识别` = 无状态行（未读） |
| `screens/02-notifications-granted.png` | `通知` = **已允许**（`adb shell pm grant … POST_NOTIFICATIONS` 之后）；`面容确认`/`实时活动`/`快捷指令` = 当前设备不可用；`专注模式` 无状态；`本地网络` = 未验证 · 点击测试 |
| `screens/03-notifications-revoked.png` | 同一 APK、同一路径，`pm revoke` 后 `通知` 回到**无状态行**（未请求）——读数真的在动 |
| `screens/04-bottom-audit.png` | `设备状态` = 常开；`家庭` = 当前设备不可用；`最近使用审计` = 「宿主没有报告使用审计，暂不判断有没有记录。」 |

状态不是全「未知」：至少 `常开` 1 行、`当前设备不可用` 6 行、`已允许` 1 行（grant 后）是页面
自己画出来的字。

---

## 7. 测试与验证

新增（JVM，`:app`）`HostPhonePermissionsTest`（9 个用例，逐条断言 23 行）：
`thisAppsOwnShapeReportsOnlyWhatItCanDefend`（本 App 真实形状）、
`aDeviceWithoutTheHardwareSaysUnavailable`（无硬件设备）、
`aHostThatDeclaresAndHoldsEverythingReportsAuthorized`（全声明全授权 → 13 行已允许，证明映射没卡在未知）、
`aGrantedPermissionWithNotificationsSwitchedOffIsDenied`、`aDeviceAdminDenialIsRestricted`、
`aPartialPhotoGrantIsNotFabricatedAsLimited`、`anUnreadRowPrintsNoLineWhileAWholeUnreadMapPrintsUnknown`、
`anUnreadLocalNetworkRowStillPrintsThePagesClickTestLabel`、`theHostReportsNoAuditAndNoEnabledCapability`。

新增（instrumented，`:domain`）`AndroidHostPermissionsTest`（6 个）：声明集 = `PackageManager` 的答案、
授权集 = `checkSelfPermission`、硬件 feature = `hasSystemFeature`、通知 app-op = `NotificationManager`、
API level = `Build.VERSION.SDK_INT`、无 admin 则无策略否决。在 5680 上 6/6 通过。

```
cd android
./gradlew :lib:compileDebugKotlin :lib:testDebugUnitTest     # BUILD SUCCESSFUL
./gradlew :app:assembleDebug                                 # BUILD SUCCESSFUL
./gradlew :app:testDebugUnitTest                             # 9/9
./gradlew :domain:testDebugUnitTest                          # 全绿（117 个既有用例）
```

---

## 8. open questions

1. **逐行「未知」需要页面模型支持**（§4-1）。现在的折中：没读的行不画状态行、行可点。
2. **"未请求 vs 已拒绝"在 Android 上不可读**。本宿主从不 `requestPermissions`，所以"声明了但没
   授权"报 `未请求` 目前为真；一旦哪条车道接上真实的权限请求（`Activity` 里的
   `requestPermissions` + `shouldShowRequestPermissionRationale`），这个分支必须重做。
3. **`未请求` 的行会打开确认弹窗**，而路由的 `onConfirmRequest` 目前只关弹窗（没有请求实现）。
   接了请求之后再来一次这个页面的验收。
4. **Health Connect 需要 `<queries>` 或 `connect-client`** 才能读到存在性（§4-3）。
5. **`本地网络` 的 `未验证 · 点击测试`** 需要宿主真的做一次 LAN 探测，或者页面换文案。
6. **`AndroidDeviceCapabilities` 的 manifest 半边仍无生产入口**：本机没有可发布的
   `DeviceManifest`（identity/limits/pairing 是"将来的设备连接器"的选择）。要么设备连接器接上，
   要么把这个类明确标成 connector-only。
