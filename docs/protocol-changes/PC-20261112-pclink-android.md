# PC-20261112-pclink-android — Android as a second PCLink v1 phone end

## 0. 摘要（機器可讀，保持這個格式）

```yaml
change: PC-20261112-pclink-android
contracts: [P28, P09, P18, P08, P12]
status: frozen
breaking: false
version_decision: 不改 wire／版本；PCLink 仍是 pclink-v1.6，Android 是同一批 v1.6 位元組的第二個 phone 實作。本次只加平台映射、身分儲存措辭、驗收命令與一列相容性，無新欄位、新 capability、新錯誤碼或新 frame
base: 56e7b6ceb5e66bcce72e7e6be53c5df674b22927
contract_revision: cb0bfd279baa1144c12e68d56f88b41087a2081a
```

本單原為 **draft**（AGENTS.md §3.1 的 contract freeze 之前一步）；P28 contract owner 已套用
§2 條款與 §4 platform 條目，現在是 frozen revision（見 §7）。實作在
[`docs/design/android-pclink-port.md`](../design/android-pclink-port.md) 的 C0–C5 檢查點。

## 1. 識別與角色

- **Trigger → 現況 → 期望**
  - Trigger：`spec/README.md` §7 GAP-35 記著 Android 沒有 PCLink；`spec/pclink/v1/README.md:2130`
    明文寫「Android is out of scope for v1」。Android 樹的模組表沒有 `PhoneDSHPCLink`
    （`android/README.md` 的 16/16 表；`spec/platform/android-module-map.json` 只有 16 個 Swift
    模組，不含 `PhoneDSHPCLink`），`:net` 只有 loopback/gateway/ADB，`:dsh` 是本機 host 與走 loopback `/api` 的
    `DshTurnClient`（`android/dsh/src/main/kotlin/com/phonedsh/dsh/turn/DshTurnClient.kt:109`），
    沒有 relay WebSocket、E2E 或配對。
  - 現況：PCLink v1 的 consumer 只有 iOS（`Sources/PhoneDSHPCLink/**`，7,687 行）與 App 接線
    （`examples/probe-app/PhoneDSHProbe/{PCPairingPage,ConnectedComputerPage,PCDrawerSection,PCLinkWorkspace}.swift`，
    `examples/probe-app/ProbeKit/Backends/{PCWorkspaceBackend,WorkspaceStorage}.swift`）。
  - 期望：Android 用同一批 `pclink-v1.6` 位元組實作第二個 phone（QR/manual 配對、E2E、
    `workspace/1`、快取、抽屜/配對頁/已連接的電腦頁），並把 Android 專屬的平台差異登記到
    `spec/platform`。**不改 relay、PC plugin 或 iOS。**
- **Coordinator / contract owner**：P28 owner（本單作者只起草，不套用 spec）。
  Implementers：C0 = P12/P08 owner；C1–C4 = `:pclink` Kotlin workers；C5 = Android UI/App worker。
  Reviewer-integrator：不得是同一端的實作者（AGENTS.md §3.4）。
- **Owning spec / schema / fixtures**：`spec/pclink/v1/README.md`（§1、§2.2、§5.6、§9.1、§10、
  §11、§12、§13）、`spec/pclink/v1/{schema,golden,endpoints.json}`（本次**不改**）、
  `spec/README.md` §3.1 P28/P18/P09/P08/P12 列與 §4 trigger 表、§7 GAP-35、
  `spec/platform/{README.md,whitelist.json}`、`spec/platform/android-module-map.json`、
  `android/README.md`、`android/settings.gradle.kts`、`android/tools/structure_check.py`。
- **受影響的 producer／consumer（逐端）**
  - Relay（Node，`relay/**`）：不改。Android 只是另一個 `role:"phone"` 的 WebSocket client。
  - PC plugin/CLI（Node，`pclink/**`）：不改。Android 的 `pair.*`、`session.init/resp/confirm`、
    `rpc.*` 位元組與 iOS 相同；PC 不能在協定上分辨兩者。
  - iOS（`Sources/PhoneDSHPCLink/**`、`examples/probe-app/**`）：不改。Android 不與 iOS 直接通訊。
  - Android（新）：`:pclink`（JVM，protocol）、`:app`（接線、camera、Keystore adapter）、
    `:lib`（四個頁面/元件）。
  - P12/P08/P18/P09 的登記面：見 §4 與 §5。

## 2. 契約 delta

只列要改的條款；未變語義引用 owning clause，不複製整份協議。

| 項目 | Before → After／依據條款 |
| --- | --- |
| 「phone」的定義 | `"Phone" is the iOS app` → iOS **或** Android，見 §2.1.1 |
| P28 完成條件 | 「C/D ends」→ C/D **與 Android client**，見 §2.1.1 |
| 身分私鑰儲存 | iOS-only Keychain 段落 → 分平台（iOS Keychain；Android Keystore 包裝的 software seed），見 §2.1.2 |
| peer metadata 顯示 | 只規定 out-of-range 警告 → 明定 phone 必須把已驗證的 `dsh.version`/`app.*` 交給 UI 顯示，見 §2.1.3 |
| `relay.offline` 關聯 | 只說 `peer_offline` → 只有帶 `id` 的 `relay.offline` 能證明該 frame 未送達；只有 `sid` 時走 session-lost 分類，見 §2.1.4 |
| UI reachability | 只有 `connecting`/`offline` → 三態 `online/reconnecting/offline`（`reconnecting` 含 bounded grace），見 §2.1.5 |
| 新 client ↔ pre-v1.6 PC | 宣稱「Interoperates」→ **CONTRACT CHANGE REQUEST CCR-1**：v1.6 client 不顯示指紋，pre-v1.6 PC 的 compare-the-phone 無法完成；owner 二選一，見 §2.3 |
| Android 驗收 | 「Android is out of scope for v1」→ Android 命令區塊與 GAP-35 關閉條件，見 §2.1.6 |
| Decision 7 | iOS Keychain 身分 → 加 Android Keystore 包裝，見 §2.1.7 |
| Registry | P28 的 implementation ends 加 `android/pclink/**`；P18/P09/P12 各加 Android 路徑與證據，見 §2.1.8 |
| `spec/platform` | 新增三條 Android 差異（身分 seed、前景 relay、Doze 網路），見 §4 |
| wire／schema／golden | **不變**（本單不新增、不刪除任何欄位/向量；Android 必須逐位元組通過既有 golden） |

自檢（對照 `spec/README.md` §5.1）：沒有新增第二種表達（Android 仍用同一 `machineId`、
`pair.*`、`session.*`、`e2e`、`workspace/1`）；沒有新欄位；沒有放寬或收緊兩端都讀的訊息；
沒有新增 enum/錯誤碼/capability；沒有刪除或重用任何名稱或編號。唯一的語義爭議是 §11 的
pre-v1.6 PC 相容列，已按要求寫成 CCR，不在本單自行裁定。

### 2.1 要套用的條款（quote → replacement）

行號以本單 base `56e7b6ce` 的 `spec/pclink/v1/README.md` 為準。Owner 套用時請同時更新
`spec/registry.json`（`registry_build.py --write`）與 `contract_revision`。

#### 2.1.1 「phone」與完成條件（lines 3–4, 13–14, 20）

> ```text
> Status: `target` — frozen contract; the B relay is implemented in this branch,
> but P28 stays `target` until the C/D ends and the runtime evidence exist.
> ```

> ```text
> PCLink is the pair of a relay plane and an end-to-end plane between one iPhone
> and one PC running `dsh web` through a PC plugin.
> ```

> ```text
> Key words MUST, MUST NOT, SHOULD and MAY are normative. "Phone" is the iOS app;
> ```

Replace with:

```text
Status: `target` — frozen contract; the B relay is implemented in this branch,
but P28 stays `target` until the C/D ends, the Android client and the runtime
evidence on every end exist.
```

```text
PCLink is the pair of a relay plane and an end-to-end plane between one iOS or
Android phone and one PC running `dsh web` through a PC plugin.
```

```text
Key words MUST, MUST NOT, SHOULD and MAY are normative. "Phone" is the iOS or
Android app (the two are independent implementations of this contract and never
talk to each other); "PC" is the PC plugin inside the `dsh web` process; "relay"
is the public or self-hosted relay.
```

#### 2.1.2 身分私鑰（§2.2, lines 247–256）

> ```text
> Private keys: the PC stores a raw 32-byte Ed25519 seed at
> `$DSH_HOME/pclink/identity.key` mode 0600. The phone stores the raw seed in the
> Keychain (service `dsh-pclink`, account `identity-v1`, accessibility
> `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable). The
> phone key is software Keychain key material (Ed25519 is not a Secure Enclave
> algorithm); a root/jailbreak compromise is outside the threat model. A missing
> phone key while a pairing record exists is not silently regenerated: the app
> shows re-pair. A missing PC key while pairing records exist regenerates the
> identity, making every old record stale; the plugin MUST NOT silently reuse or
> rewrite them.
> ```

Replace with:

```text
Private keys: the PC stores a raw 32-byte Ed25519 seed at
`$DSH_HOME/pclink/identity.key` mode 0600. The phone stores the raw 32-byte
seed in the platform secure store:

- **iOS:** Keychain (service `dsh-pclink`, account `identity-v1`,
  accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not
  synchronizable).
- **Android:** the seed is generated in app code (CSPRNG) and stored as a
  32-byte value through the `:platform` `SecureStore`. The Android
  implementation of that SPI wraps the value with an AES-256-GCM key held in
  AndroidKeyStore, writes the ciphertext under `noBackupFilesDir`, and reports
  the measured `SecurityLevel` (`SOFTWARE`/`TEE`/`STRONGBOX`). AndroidKeyStore
  at the contract's `minSdk 26` has no Ed25519 key type, so the identity key
  itself is software key material and only the wrapping key can be
  hardware-backed; the app MUST NOT claim a hardware-backed phone identity.
  An unreadable value (`SecureLookup.Unreadable`, e.g. a key invalidated after a
  credential/OS change) is fail-closed, never treated as `Absent`.

The phone key is software key material (Ed25519 is not a Secure Enclave
algorithm and is not an AndroidKeyStore key type at minSdk 26); a
root/jailbreak compromise is outside the threat model. A missing phone key
while a pairing record exists is not silently regenerated: the app shows
re-pair. A missing PC key while pairing records exist regenerates the identity,
making every old record stale; the plugin MUST NOT silently reuse or rewrite
them.
```

**Android semantic obligations (for the implementer, not new wire):** seed is
exactly 32 bytes; one identity per app install; never exported, logged or
backed up (`android:allowBackup="false"` is already set at
`android/app/src/main/AndroidManifest.xml:116`); a present pairing record with a
missing/unreadable seed shows re-pair and MUST NOT auto-pair or auto-delete the
record. This mirrors `Sources/PhoneDSHPCLink/PCLinkIdentity.swift:71-136` and
`android/platform-android/src/main/kotlin/com/phonedsh/platform/android/AndroidSecureStore.kt:93-180`.

#### 2.1.3 已驗證的 peer metadata 必須可顯示（§5.6, lines 1403–1406）

> ```text
> `app.name` (1–64) and `app.version` (1–32, `[0-9A-Za-z.+-]`) are display
> metadata. `name` is 1–64 UTF-8 bytes, NFC, no C0/C1/`Cf` characters (review
> L4); both `app.name` and `name` are display-only and are normalized/checked
> before display, never used for routing or authorization.
> ```

Append after that paragraph:

```text
The phone MUST expose the verified `dsh.version`, and `app.name`/`app.version`
when present, to its UI as the connected PC's build facts; an out-of-range
`dsh.version` adds the "版本未验证" warning but MUST NOT hide the actual
version. The PC's own version is never inferred from `install`, a pairing
record or a relay claim. This is the D-stage `PCLinkClientStatus.peerDshVersion`
obligation (PC-20261110-pclink-ios-app §4.7.1 CCR-2), promoted here so the
Android "已连接的电脑" page has the same source of truth.
```

#### 2.1.4 `relay.offline` 的關聯規則（§9.1 row + §10 bullet）

> §9.1 line 1877:
> ```text
> | `peer_offline` | relay (`relay.offline` frame) / client | target not connected; the frame was not delivered | show PC offline; retry read/idempotent after reconnect; unsafe was not delivered |
> ```

> §10 lines 1960–1962:
> ```text
> - In-flight unary calls follow §7. A definitive `rpc.result` received before the
>   close wins; otherwise `read` retries, `idempotent` retries with identical DSH
>   arguments, `unsafe` becomes `unknown_outcome`.
> ```

Append to §10 (and reference from the §9.1 row):

```text
- **`relay.offline` correlation.** A `relay.offline` that carries `id` (and
  optionally `streamId`) identifies one frame that was not delivered: the
  matching call/stream is `peer_offline` and, for `read`/`idempotent`, may be
  retried per §7. A `relay.offline` with only `sid` says nothing about a
  specific in-flight frame: an `unsafe` call/stream already sent becomes
  `unknown_outcome` (never `peer_offline`) and is not resent; `read`/`idempotent`
  calls still follow §7. This is the D-stage fix recorded in
  PC-20261110-pclink-ios-app §4.9.1 item 4 and is promoted because a second
  client must make the same distinction.
```

#### 2.1.5 UI reachability 三態（§10, lines 1941–1946）

> ```text
> - `connecting` and `offline` are distinct phone states (v1.6 clarification,
>   PC-20261110-pclink-foreground-resume-presence). `connecting` means the phone
>   is dialing or handshaking, including the bounded resume above; `offline`
>   means one dial already failed, or the connection dropped without a
>   phone-initiated resume. While `connecting`, the phone MUST NOT present
>   `电脑离线`; it presents its connecting copy instead.
> ```

Replace with:

```text
- The phone's reachability projection has exactly three values: `online`,
  `reconnecting`, `offline`. `reconnecting` covers the dialing/handshaking
  state above plus a bounded grace after a dropped socket while a reconnect is
  still in flight; the reference value for that grace is **8 s**
  (PC-20261110-pclink-workspace-cache §2, frozen for P09/P18). `offline`
  requires either one dial to have failed or the grace to expire. While
  `reconnecting`, the phone MUST NOT present `电脑离线`; it presents its
  connecting/reconnecting copy instead. `connecting` remains the narrower
  transport state used by the client; it is not a fourth UI value.
```

If the owner decides the 8 s value belongs only to P09 (not P28), keep the
three-value sentence in §10 and move the parenthetical to the P09 contract.
Android C5 must use one shared constant either way; the design uses the P09
value.

#### 2.1.6 Android 驗收與 GAP-35（§12, lines 2129–2134）

> ```text
> The D-stage App wiring additionally needs the P09 page/source changes and the
> P12 `Package.swift` declaration; those are separate changes. Android is out of
> scope for v1 and its missing drawer actions are tracked as GAP-35. The P09 page
> contract changes for the redesigned pairing page and the "connected computer"
> page are part of the same branch (`spec/ui/v1/pages/pc-pairing.json`,
> `connected-computer.json`); they do not change any wire byte.
> ```

Replace with:

````text
The D-stage App wiring additionally needs the P09 page/source changes and the
P12 `Package.swift` declaration; those are separate changes. The Android client
is a second phone implementation of the same v1.6 bytes; its missing drawer
actions, pairing page and "connected computer" page are GAP-35 and are
implemented by the Android parity work, not by a wire change. The P09 page
contract changes for the redesigned pairing page and the "connected computer"
page are part of the same branch (`spec/ui/v1/pages/pc-pairing.json`,
`connected-computer.json`); they do not change any wire byte.

Android acceptance (run from the implementer's branch; a missing toolchain is
SKIP/INCOMPLETE, never PASS):

```sh
# Android client (P28 Kotlin, JVM tests read the same golden files from disk)
bash android/tools/with-android-toolchain.sh ./gradlew :pclink:test --no-daemon
node spec/pclink/v1/tools/vectors.mjs --check
python3 spec/pclink/v1/tools/check_samples.py --root .
bash scripts/ci/check.sh --only phone-android-structure,phone-android-tests,phone-cross-tree

# Pages + App wiring (after C5)
bash android/tools/with-rust-toolchain.sh cargo build --locked --manifest-path shell/Cargo.toml -p pdsh-jni
bash android/tools/with-android-toolchain.sh ./gradlew :lib:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug --no-daemon
python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json
```

A real Android device/emulator E2E with a real relay and `dsh web` is required
before P28 moves to `implemented` for this end; JVM tests and a passing page
checker are not device evidence. Android runtime evidence does not close the
existing iOS/PC/relay evidence requirements.
````

#### 2.1.7 Decision 7（§13, lines 2164–2166）

> ```text
> 7. The phone identity is a software Keychain Ed25519 key, not a Secure Enclave
>    key (Ed25519 is not supported there). A stolen unlocked phone is full owner
>    access; the handling is **revoke all pairings, then `rotate-identity`**.
> ```

Replace with:

```text
7. The phone identity is a software Ed25519 key, not a hardware identity: iOS
   keeps the raw seed in the Keychain (Ed25519 is not a Secure Enclave
   algorithm); Android keeps the raw seed encrypted by an AndroidKeyStore
   AES-GCM key (AndroidKeyStore has no Ed25519 key type at minSdk 26, and the
   measured security level is reported rather than assumed). A stolen unlocked
   phone is full owner access; the handling is **revoke all pairings, then
   `rotate-identity`**.
```

#### 2.1.8 Registry rows（`spec/README.md` §3.1、§4、§7）

Owner applies these as text, then runs `python3 spec/tools/registry_build.py --root . --write`.

1. §3.1 P28 row (`spec/README.md:89`): add the Android implementation end and
   evidence, e.g. after the Swift/App sentence:
   `Kotlin android/pclink/**`（`target`；`com.phonedsh.pclink`，JVM，讀
   `spec/pclink/v1/golden/**` 的 `PclinkGolden*Test`）`+ android/app/**/pc/**`
   and `android/lib/.../page/{PCPairingPage,ConnectedComputerPage}.kt`（P09）；
   evidence: `:pclink` JVM tests, `page_structure_check.py`, real-device E2E.
2. §4 P28 trigger (`spec/README.md:131`): add
   `android/pclink/**`、`android/app/src/main/kotlin/com/phonedsh/probe/pc/**`、
   `android/lib/src/main/kotlin/com/phonedsh/ui/page/{PCPairingPage,ConnectedComputerPage}.kt`、
   `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PcDrawer*.kt`.
   Keep `spec/pclink/v1/**`; the owner may also add `relay/**`, `pclink/**`,
   `Sources/PhoneDSHPCLink/**`, `Tests/PhoneDSHPCLinkTests/**` when B/C/D land
   (the existing note at that row says so).
3. §4 P18 trigger (`spec/README.md:121`): add
   `android/pclink/src/main/kotlin/com/phonedsh/pclink/PclinkPairingStore.kt`、
   `android/app/src/main/kotlin/com/phonedsh/probe/pc/PcWorkspaceStorage.kt`、
   `android/app/src/main/kotlin/com/phonedsh/probe/pc/PcDiagnosticsLog.kt`、
   `android/app/src/main/kotlin/com/phonedsh/probe/ChatSessionStore.kt`（scoped current session）。
   P18 owns the local keys; P28 does not duplicate them.
4. §4 P12 trigger (`spec/README.md:115`): add `android/settings.gradle.kts`
   (it is currently not listed; the module set is a P12 surface).
5. §7 GAP-35 (`spec/README.md:227`): append the closure evidence:
   `page_structure_check.py --baseline` must report only the pre-existing
   GAP-32(d) `files` row (7 → 1) and the Android build must pass
   `:lib`/`:app` JVM tests + `:app:assembleDebug`; real-device drawer/pairing
   evidence is still required before the GAP closes.
6. §3.1 P08 row: add the three `spec/platform/whitelist.json` ids from §4.
7. §3.1 P09 row: add `android/lib/.../page/{PCPairingPage,ConnectedComputerPage}.kt`
   and `android/lib/.../nav/PcDrawer*.kt` as the Android implementation of the
   existing page contracts; the contracts themselves do not change.

Registry fragments to quote/append (same file/line as above):

> P28 row current fragment: `Swift Sources/PhoneDSHPCLink/** + Tests/PhoneDSHPCLinkTests/**（target；Package.swift 為 P12），App 接線在 examples/probe-app/**（P09/P27）`
> → append: `Kotlin android/pclink/**（target；com.phonedsh.pclink，JVM）與 android/app/**/pc/**、android/lib/.../page/{PCPairingPage,ConnectedComputerPage}.kt（P09）；證據為 :pclink JVM tests、page_structure_check.py 與真機 E2E。`

> P28 trigger current fragment: `spec/pclink/v1/**（B/C/D 落地後由 contract owner 在同一列加入 relay/**、pclink/**、Sources/PhoneDSHPCLink/**、Tests/PhoneDSHPCLinkTests/** 的 trigger；本 A 冻结不包含实现目录）`
> → append inside the parenthesis: `、android/pclink/**、android/app/src/main/kotlin/com/phonedsh/probe/pc/**、android/lib/src/main/kotlin/com/phonedsh/ui/page/{PCPairingPage,ConnectedComputerPage}.kt、android/lib/src/main/kotlin/com/phonedsh/ui/nav/PcDrawer*.kt`.

> P18 trigger current fragment: `、android/net/src/main/kotlin/com/phonedsh/account/**`
> → append: `、android/pclink/src/main/kotlin/com/phonedsh/pclink/PclinkPairingStore.kt、android/app/src/main/kotlin/com/phonedsh/probe/pc/PcWorkspaceStorage.kt、android/app/src/main/kotlin/com/phonedsh/probe/pc/PcDiagnosticsLog.kt、android/app/src/main/kotlin/com/phonedsh/probe/ChatSessionStore.kt`.

> P12 trigger current fragment: `android/README.md、android/tools/structure_check.py、android/tools/test_structure_check.py`
> → append: `、android/settings.gradle.kts`.

### 2.2 只存在於 `PC-20261110-*`、Android 必須用的項目

「只存在於變更單」指 `spec/pclink/v1` 沒有、而 Android 若要與 iOS 行為一致就必須有一份
權威。分成三類，**不要全部塞進 P28**：wire/transport 語義進 P28；本地持久化進 P18；
頁面/文案進 P09。這一分法就是 AGENTS.md §1 的 one-authority-per-boundary。

| # | 項目 | 目前唯一出處 | Android 為何需要 | 應提升到 | 本單動作 |
| --- | --- | --- | --- | --- | --- |
| 1 | 已驗證 peer DSH/app metadata 必須提供給 UI（CCR-2） | `PC-20261110-pclink-ios-app.md` §4.7.1 CCR-2；`Sources/PhoneDSHPCLink/PCLinkClient.swift:80-82` | 「已連接的電腦」要顯示實際 DSH 版本，不能只顯示「驗證範圍內」 | **P28 §5.6** | §2.1.3 已給 replacement |
| 2 | `relay.offline` 帶 `id` vs 只帶 `sid` 的分類（`peer_offline` vs `unknown_outcome`） | `PC-20261110-pclink-ios-app.md` §4.9.1 item 4；`Sources/PhoneDSHPCLink/PCLinkClient.swift:1355-1388` | Android 若把所有 offline 都當 `peer_offline`，已送出的 unsafe action 會被誤判為未執行 | **P28 §9.1/§10** | §2.1.4 已給 replacement |
| 3 | 三態 reachability（`online/reconnecting/offline`）與 8 s grace | `PC-20261110-pclink-workspace-cache.md` §2；`examples/probe-app/PhoneDSHProbe/PCLinkWorkspace.swift:96-110` | 抽屜/聊天頁不能在回前台重撥時顯示「電腦離線」 | **P28 §10**（8 s 可留 P09） | §2.1.5 已給 replacement |
| 4 | 離線可讀快取：先畫 `session/list`/transcript 快照、cached-list strip、cache-preview gate | `PC-20261110-pclink-workspace-cache.md` §2 | 冷啟動/離線時抽屜不能空白；切換已快取會話要先有內容 | **P18 + P09**（已在 `spec/README.md:79` 的 P18 列） | Android 專屬 key/格式需 P18 追加（見 §2.2.1） |
| 5 | 抽屜 phase 判定 `phase(selected:hasRecord:presence:)`、`showsStateCard(pcRowCount:)`（PC 只用自己的列）、`cachedListNote` | `PC-20261110-pclink-workspace-cache.md` §2；`examples/probe-app/ProbeKit/Backends/PCWorkspaceBackend.swift:656-694` | 未配對 PC 段不得渲染手機列表，否則會出現「PC 標題下手機會話」 | **P09**（`home-drawer` 的 sectionNote/行為） | P09 owner 追加；本單只引用 |
| 6 | PC 工作區分組：`workspace/follow` membership 優先，其次最長 cwd 前綴，其餘「未分組」 | `PC-20261110-pclink-ios-app.md` §4.11；`examples/probe-app/ProbeKit/Backends/PCWorkspaceBackend.swift:718-750` | Android 抽屜要與 iOS 同一分組，不能再用單一「PC 工作區 · <電腦名>」 | **P09**（`home-drawer`） | P09 owner 追加；本單只引用 |
| 7 | PC backend 能力隱藏：`phoneOnlyEndpoints=false`、`supportsHostLifecycle=false`、`localFilePreview=false` | `PC-20261110-pclink-ios-app.md` §4.3；`examples/probe-app/ProbeKit/Backends/PCWorkspaceBackend.swift:147-156` | PC 段不得啟動手機 Bot/設備/本機檔案預覽；PC 沒有 host lifecycle | **P09 + P18**（`phoneOnly` 的 wire 部分已在 P28 §7） | P09/P18 owner 追加；P28 不動 |
| 8 | 配對完成後頁面自動進 PC 工作區 / `pairingUpdates()` | `PC-20261110-pclink-ios-app.md` §4.7.1；P28 §11 line 2008 已說 "may auto-close" | Android 配對頁要能自動完成，不必第二次點擊 | **P28 §11 已涵蓋 / P09 頁面** | 不需新 P28 條款 |
| 9 | 前景 resume ≤1 s、`connecting` 不顯示離線 | `PC-20261110-pclink-foreground-resume-presence.md` §2；P28 §10 lines 1930–1946 | Android `ON_START` 重撥要快且文案正確 | **P28 §10 已涵蓋** | 不需新條款（§2.1.5 只補三態） |
| 10 | `PCLinkWorkspaceText` 的離線原因/快取/copy 字串、`PCLinkManualCodeInput.format` | `PhoneDSHProbe/PCLinkWorkspace.swift`、`ProbeKit/Backends/PCWorkspaceBackend.swift:454-560` | 兩端文案一致；手動碼輸入時自動分組 | **P09**（page contract / UiStrings） | P09 owner 追加；本單只列 |
| 11 | `pclink-diag.log` 內容/輪替/大小 | `PC-20261110-pclink-workspace-cache.md` §2；`examples/probe-app/ProbeKit/PCLinkDiagnosticsLog.swift:74-90` | Android 需要等價的本機診斷（不含標題/訊息/金鑰） | **P18** | P18 owner 追加 Android 檔名/路徑 |
| 12 | transcript snapshot envelope/caps/200 檔淘汰/`isExcludedFromBackup` | `PC-20261110-pclink-workspace-cache.md` §2；`examples/probe-app/ProbeKit/Backends/WorkspaceStorage.swift:487-565` | Android 的 PC 轉錄快取要有界、可回滾 | **P18**（`spec/README.md:79` 已有 iOS 條目） | P18 owner 追加 Android scope/路徑 |
| 13 | `phone-dsh.drawer.backend`、`<scope>/<sessionID>` 鍵、一次性遷移 | `PC-20261110-pclink-ios-app.md` §2；`examples/probe-app/ProbeKit/Backends/WorkspaceStorage.swift:20-90` | Android 也要記住手機/PC 選擇，且同 ID 兩端不覆寫 | **P18**（已登記 iOS 條目） | P18 owner 追加 Android 鍵/預設/遷移 |
| 14 | PC roster snapshot key/envelope/read/clear | `PC-20261110-pclink-pc-roster-snapshot.md` §2；`examples/probe-app/ProbeKit/Backends/WorkspaceStorage.swift:58` | Android 冷啟動要先畫 PC 清單 | **P18** | P18 owner 追加 Android 格式（不可直接複製 Swift `ChatSessionSnapshot` 型別） |

#### 2.2.1 結論：P28 只需提升 #1–#3

#4–#14 已經有權威（P18 在 `spec/README.md` §3.1，P09 在 `spec/ui/v1/pages/**`），把它們再抄進
`spec/pclink/v1` 會變成第二份表達，違反 AGENTS.md §1.1。Android 需要的是：

- P18：把 iOS-only 的本地 key/格式補上 **Android 的實作路徑與值域**（不是複製一份 iOS 格式）。
  最小追加：`pclink.identity-v1` 之外的四個鍵（drawer backend、current session scope、
  roster snapshot、transcript snapshot）在 Android 的檔名/路徑、清除時機、未知版本忽略規則；
  `pclink-diag.log` 的 Android 路徑與 256 KiB×2 輪替。
- P09：在 `home-drawer` 的 `sectionNote` 補 Android 的 phase/grouping/cached-list 行為，
  以及 `pc-pairing`/`connected-computer` 的 Android screen 由 `extract_ios_pages.py --write`
  自動登記（見 §5 C5）。
- P28：只做 #1–#3 與平台/驗收/相容列。

### 2.3 CONTRACT CHANGE REQUEST

```text
CONTRACT CHANGE REQUEST
Contract: P28 @ pclink-v1.6
Clause:   spec/pclink/v1/README.md §11 line 2007 vs §1 lines 137–140 and §4.6
          lines 1066–1071
Problem:  The §11 row says a new (v1.6) App interoperates with a pre-v1.6 PC
          that "still compare[s] the phone": the old PC CLI "still shows its
          fingerprint prompt", and the App's waiting copy must be mode-neutral.
          But §1 says "The phone's pairing page likewise no longer displays a
          fingerprint for comparison", and §4.6 says "The pairing page itself
          MUST NOT show a fingerprint card or instruct the user to type a
          fingerprint into the PC." The pre-v1.6 PC shows only the verified
          phone name while pending (v1.2 pending-peer redaction, §4.4/§8.2) and
          requires the operator to type the phone-displayed fingerprint
          (PC-20261109-pclink-v1 §2, v1.2 row). A v1.6 client therefore has no
          value to show the old PC operator, so the claimed interoperability
          cannot be completed; the exchange always ends in the old PC's 120 s
          approval timeout. This is a UI/compatibility contradiction, not a
          wire defect: pair.hello/auth/confirm/final bytes are unaffected.
Proposal: Smallest delta: replace the §11 row with "new client (v1.6) → pre-v1.6
          PC: not supported for a new pairing; the client reports the 120 s
          timeout with an upgrade hint, and the user upgrades the PC plugin.
          An already-paired v1.5 record still works (same E2E bytes)." Keep
          §4.6's no-fingerprint rule. Alternative (owner's call): allow a
          collapsed, mode-neutral "本机指纹" line on the waiting page only when
          the PC has not confirmed within N seconds, and relax §4.6 by one
          sentence; that preserves old-PC pairing but reintroduces a
          fingerprint on the page.
Affects:  Android C2/C5 (pairing page waiting state and timeout copy); iOS
          (same page, same contract); PC plugin/CLI documentation (the
          pre-v1.6 prompt is now an unsupported peer); P09 pc-pairing page.
Until the owner rules, C2 implements the v1.6 path and the timeout+upgrade
hint only; it MUST NOT display a fingerprint card or auto-delete the record.
```

**Status: resolved — option (a).** Owner decision: a v1.6 client does not
support a new pairing with a pre-v1.6 PC; it reports the 120 s approval timeout
with an upgrade hint for the PC plugin, and an already-paired v1.5 record keeps
working (same E2E bytes). Reason: the pre-v1.6 PC still requires a
phone-displayed fingerprint, while §4.6 forbids the v1.6 pairing page from
showing one, so the old exchange always ends in that timeout. This writes down
what iOS already does; there is no iOS code change and §4.6 is unchanged. The
§11 row is replaced accordingly in this revision. C2 implements the timeout +
upgrade hint only; it MUST NOT display a fingerprint card or auto-delete the
record.

## 3. 相容性與發佈

### 3.1 為何沒有 wire change

Android 送出的每一個位元組都由既有條款定義，且必須逐位元組通過
`spec/pclink/v1/golden/pclink-v1-vectors.json`：

| 位元組面 | 條款 | Android 做法（與 iOS 相同） |
| --- | --- | --- |
| `machineId` | §2.2 lines 214–226 | `lower(base32_nopad(sha256(rawPub)))[0:26]` |
| relay auth transcript | §3.2 lines 404–409 | `"pclink-v1/relay-auth" \|\| 0x00 \|\| UTF8(relay) \|\| 0x00 \|\| nonce_raw_32` |
| QR URI / manual code | §4.1–§4.2 lines 664–710 | 同一 query 集合、`%20`、80-bit Crockford |
| rendezvous / pair MAC | §4.3–§4.4 lines 711–910 | origin-bound hash、`canonical_json`、HKDF/HMAC |
| handshake transcripts | §5.2 lines 1187–1228 | `T_init`/`T_resp`/`T_confirm` 的 raw bytes |
| AEAD nonce/AAD | §5.4 lines 1264–1312 | `00000000\|\|u64be(seq)`、固定 AAD 字串 |
| inner messages | §6 lines 1415–1629 | 同一封閉物件與 chunk 規則 |
| endpoints | `endpoints.json`（57 條） | 嵌入同一張表，測試逐列比對 |

**沒有發現需要新欄位、新 frame、新 capability 或新錯誤碼的 Android 需求。** Android 的
`role` 仍是 `"phone"`；PC 的 `relay.allow` 仍只按 machineId；relay 不認識平台。唯一需要
owner 裁決的是 §2.3 的 pre-v1.6 PC 配對（UI/相容，不是 wire）。

### 3.2 相容性矩陣

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| **Android v1.6 → relay v1（現有）** | 支援。`peer.auth`、`relay.allow`、`relay.offline`、心跳/關閉碼完全不變；relay 只看到另一個 `role:"phone"`。測試：C3 的 `FakeRelay` + 本機真實 relay 的 `relay/pair` 流程（C4）。 |
| **Android v1.6 → PC plugin v1.6（main）** | 支援。QR 與 manual 配對、E2E、`workspace/1`、chunk、rekey、replay 全部走既有 golden；PC 的 `approvedVia:"qr"\|"manual"`、`pairingMode` 由 PC/phone 各自記錄。測試：C2 的 `FakePc` + C4 的 in-memory transport；真實 `dsh web` 整合屬裝置階段。 |
| **Android v1.6 → PC plugin v1.5（已部署）** | **已配對的 E2E 支援**（bytes 相同；PC 的 legacy `cli\|webui` record 仍可用）；**新的 compare-the-phone 配對不支援**，見 CCR-1。Android 不得顯示指紋卡；逾時顯示升級提示。測試：C2 的 timeout/拒絕/已配對 record 三條。 |
| **new client (v1.6) → pre-v1.6 PC** | **新的配對不支援。** Client 回報 120 s approval timeout 並提示升級 PC plugin；已配對的 v1.5 record 仍可用（same E2E bytes）。理由：pre-v1.6 PC 要求 operator 輸入 phone-displayed fingerprint，而 v1.6 client 依 §4.6 不顯示 fingerprint。測試：C2 的 timeout／已配對 record 兩條。 |
| **iOS v1.6 → PC（現有）** | 不變。本單不動 iOS。 |
| **Android ↔ iOS** | 無直接鏈路；兩者都是同一 PC 的 phone，PC 最多 1024 條 record。Android 必須顯示 `pclink.notice{kind:"paired"}`；PC 對其他 phone 的 notice 行為不變。測試：C4/C5 的 notice 顯示。 |
| **old → new（Android 首次發佈）** | Android 先前沒有任何 PCLink 資料；沒有 migration。App 既有的 P18 手機鍵不受影響；新的 PC scope 鍵是新增。 |
| **new → old（Android 回滾到無 PCLink 的 build）** | 舊 build 忽略 `pclink/` 目錄（與 §11 "A build without PCLink ignores the directory" 相同）；PC 上的 record 仍在，使用者需在 PC `pclink unpair`。Android 本機 record 被移除不影響 PC。測試：C4 的 store 缺失/壞值/未知版本。 |
| **persisted v1.5 PC record → Android** | 可用（E2E bytes 不變）；新的配對受 CCR-1 限制。Android 不需要讀 PC 的 `pairs.json`。 |
| **persisted v1.6 PC record → rolled-back pre-v1.6 PC** | 既有 fail-closed 規則不變（pre-v1.6 validator 拒絕 `qr\|manual`）；Android 不改變此結果。 |
| **version / adapter** | 不加版本、不加 adapter。Android 與 iOS 都送 `v:1`、suite `pclink-x25519-ed25519-chacha20poly1305-1`、`workspace/1`；未知 capability 仍被忽略。 |

### 3.3 發佈順序與回滾

1. Owner 套 §2 條款 + §4 platform 三條（同一 revision）。
2. C0 加 `:pclink` 模組與 module-map/README（P12），不啟用任何 UI。
3. C1–C4 在 `:pclink` 內落地；不影響 iOS/PC/relay。
4. C5 加頁面與 App 接線（`:lib`/`:app`），P09 owner 重新產生兩個頁面契約的 `android` 映射。
5. 回滾：移除 `:app` 的 PCLink 接線 → 抽屜回到手機 only；`:pclink` 與 P18 鍵可留（死資料，
   下次解除配對清除）。PC record 不會被 Android 回滾刪除；使用者在 PC unpair。
6. 版本：`pclink-v1.6` 不升；本次是平台/實作擴充，不改 wire。若 owner 在 CCR-1 選擇
   「放寬 §4.6 允許舊 PC 顯示指紋」，那仍是 UI 條款變更，不需新 wire 版本。

## 4. 要登記到 `spec/platform` 的三條差異

以下 JSON 物件可直接追加到 `spec/platform/whitelist.json`（陣列）。三條都是 `os-forced`，
`evidence_level: not-verified`（尚無 Android 真機 PCLink 證據；`rationale` 必須含「未验证」，
checker 會檢查，見 `spec/platform/README.md` §4）。`spec_ref` 的節號在
`spec/pclink/v1/README.md` 是實際標題；`baseline` 檔案存在。

```json
[
  {
    "id": "platform.pclink-identity-seed",
    "capability": "security.secret-store",
    "ios": "Keychain 保存 raw 32-byte Ed25519 seed（service dsh-pclink, account identity-v1, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, 不同步）",
    "android": "app 產生 32-byte seed，經 :platform SecureStore 以 AndroidKeyStore AES-256-GCM 金鑰包裝，密文寫 noBackupFilesDir；SecurityLevel 實測回報；Unreadable 一律 fail-closed，有 pairing record 時不得自動重生",
    "divergence_class": "os-forced",
    "rationale": "SecItem 不存在；minSdk 26 的 AndroidKeyStore 也沒有 Ed25519 key type，所以身分金鑰只能是 software seed，只有包裝金鑰可能硬體背書。語義不變：32-byte RFC 8032 seed、每次安裝一個身分、不自動重生、不備份/不同步；不得宣稱硬體身分。未验证：尚無 Android 真機的 Keystore 失效/StrongBox 降級證據。",
    "spec_ref": "spec/pclink/v1/README.md §2.2",
    "android_mechanism": "AndroidKeyStore AES/GCM/NoPadding",
    "evidence_level": "not-verified",
    "baseline": "Sources/PhoneDSHPCLink/PCLinkIdentity.swift"
  },
  {
    "id": "platform.pclink-foreground-relay",
    "capability": "network.relay-socket",
    "ios": "URLSessionWebSocketTask（PCLinkRelayClient）在前景持有 relay socket；App 進背景時 socket 被 suspend，回前景走 §10 bounded resume",
    "android": "Ktor CIO WebSocket 只在 App 前景或回合的 foreground service 執行期間持有；ProcessLifecycleOwner ON_STOP 關閉 socket，ON_START 呼叫 foregroundResumed()，下一次重撥 ≤1 s ±20 %；不在背景承諾收訊",
    "divergence_class": "os-forced",
    "rationale": "Android 的背景執行限制/Doze 不允許無界背景 socket；PCLink 本來就是 demand-driven（relay 10 分鐘 idle、PC 15 分鐘 idle、無 queue、無 push），關閉後按 §10 重連不改變可觀測語義：重連必重新 handshake、不補送、durable event 由 stream recovery 補。未验证：尚無真機前景/背景切換與 relay drop 證據。",
    "spec_ref": "spec/pclink/v1/README.md §10",
    "android_mechanism": "ProcessLifecycleOwner + Ktor CIO WebSocket",
    "evidence_level": "not-verified",
    "baseline": "Sources/PhoneDSHPCLink/PCLinkRelayClient.swift"
  },
  {
    "id": "platform.pclink-doze-network",
    "capability": "network.relay-socket",
    "ios": "沒有 Doze；OS 可 suspend App/socket，但沒有 Android 的 idle network/maintenance window",
    "android": "Doze/App Standby 會延後網路與 maintenance；client 把任何 socket 遺失當一般斷線，按 §10 jitter 重連；不排 exact alarm、不請求 battery optimization exemption、不加背景 keepalive",
    "divergence_class": "os-forced",
    "rationale": "Doze 是 Android 獨有的 OS 政策。契約已明確沒有 server push/queue，只有 demand reconnect；Android 不得用 keepalive/alarm/whitelist 假造 liveness。liveness 下降如實呈現 offline，回前景或使用者重試時恢復。未验证：尚無真機 Doze 進入/退出與 heartbeat 逾時證據。",
    "spec_ref": "spec/pclink/v1/README.md §10",
    "android_mechanism": "PowerManager.isDeviceIdleMode + ConnectivityManager",
    "evidence_level": "not-verified",
    "baseline": "Sources/PhoneDSHPCLink/PCLinkRelayClient.swift"
  }
]
```

Owner 同時要修 `spec/platform/README.md` 的漂移：line 21 說「20 條」但陣列現在是 28 條；
§9 line 191 說 `not-verified` 只有 2 條，追加後是 5 條。這是既有的文件漂移，不是本單造成；
套用本單時一併改成實際數字（28 + 3 = 31）。`platform_check.py` 的
`REQUIRED_PRIMITIVES`/`REQUIRED_MANDATES` 是必填清單，額外條目不會破壞覆蓋率，不需要改
checker 常數。

## 5. 分工與證據

檢查點、owned paths、goldens、命令與大小的完整版在
[`docs/design/android-pclink-port.md`](../design/android-pclink-port.md) §6。這裡只列
contract-owner 需要知道的邊界。C0 正由平行 worker 進行中；本凍結不等待 C0 落地。

| 檢查點 | Owner | 獨占路徑（摘要） | 主要 goldens | 命令 → 期望 |
| --- | --- | --- | --- | --- |
| C0 登記 | P12/P08 owner | `android/settings.gradle.kts`、`android/pclink/build.gradle.kts`、`spec/platform/android-module-map.json`、`android/README.md`、`android/tools/structure_check.py`(+test) | 無（結構） | `structure_check.py` → 13/14，唯一失敗是既有的 `readme-map`（Bot/Venus 未登記），非 C0 造成；`:pclink:test` → PASS |
| C1 frames+auth+vectors | `:pclink` worker A | `android/pclink/src/main/kotlin/com/phonedsh/pclink/{PclinkJson,PclinkEncoding,PclinkCrypto,PclinkWireValidation,PclinkLimits,PclinkErrors,PclinkEndpoints,PclinkValidation,PclinkIdentity}.kt` + 對應 test | `golden/pclink-v1-vectors.json` 的 identities/relay_auth/canonical_json/json_boundary/frames；`golden/schema-samples.json`；`endpoints.json` | `:pclink:test --tests '*GoldenVectorCryptoTest' ...` → PASS；`vectors.mjs --check` → PASS |
| C2 pairing+E2E | worker B | `PclinkQr.kt`、`PclinkPairing.kt`、`PclinkPairingStore.kt`、`PclinkE2e.kt`、`PclinkHandshake.kt`、`PclinkClient.kt`（state/pairing）+ pairing/handshake tests | vectors 的 pairing/handshake/invalid(qr/manual/pair_mac/handshake_*/x25519/aead/seq/reject/record/approval)；schema-samples pairing records | `:pclink:test --tests '*GoldenVectorPairingTest' --tests '*PclinkPairingFlowTest'` → PASS |
| C3 relay transport | worker C | `PclinkWebSocket.kt`、`PclinkRelayClient.kt`、`PclinkPacer.kt` + relay/pacing tests | vectors relay_auth/frames/invalid(origin/replay/unknown_code/frame)；§3.8 常數 | `:pclink:test --tests '*PclinkRelayClientTest' --tests '*PclinkPacingTest'` → PASS |
| C4 workspace/1 + cache | worker D | `PclinkRpc.kt`、`PclinkDshTransport.kt`、`PclinkRosterCache.kt`、`PclinkPresence.kt` + transport/cache tests | vectors chunking/invalid(chunk/seq/cross_sid/first_frame)；`endpoints.json` | `:pclink:test --tests '*PclinkDshTransportTest' --tests '*PclinkRpcChunkingTest' --tests '*PclinkRosterCacheTest'` → PASS |
| C5 pages + App | worker E | `android/lib/.../page/{PCPairingPage,ConnectedComputerPage}.kt`、`android/lib/.../nav/PcDrawer*.kt`、`HomeDrawer.kt`、`SettingsPage.kt`、`UiStrings.kt`、`android/app/.../pc/**`、manifest | `spec/ui/v1/pages/{pc-pairing,connected-computer,home-drawer,settings}.json`；`_baseline.json` | `:lib:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug` → PASS；`page_structure_check --baseline` → **1**（只剩 GAP-32(d) `files`） |

**共享 fixtures**：`spec/pclink/v1/golden/pclink-v1-vectors.json`（valid + 56 crypto negatives
+ 26 state-machine model samples）、`golden/schema-samples.json`（19 schemas, 33 valid/33 invalid）、
`endpoints.json`（57 endpoints）。Android 測試必須從磁碟讀，不能手抄；`:pclink` 的
`build.gradle.kts` 以 `systemProperty("pdsh.repo.root", ...)` 指向 repo root（同
`android/core/build.gradle.kts:30` 與 `android/lib/build.gradle.kts` 的 test 設定）。
**沒有** P18 的共享 golden；C4 的 cache 測試以 `PC-20261110-pclink-*` 的正反例為 fixture，
不宣稱跨端 conformance。

**真實 producer/consumer**：C3 的 `FakeRelay` 必須用 module 的真實 crypto/state machine；
C4 的 `FakePc` 必須跑真實 `PclinkE2e`；C5 的頁面測試用 fake state，但 App 接線的
`PclinkClient` 必須是真實 instance。真機 relay + `dsh web` E2E 是關閉 P28/GAP-35 的必要
證據，JVM 測試不算。

## 6. 剩餘風險與未決

1. **CCR-1（pre-v1.6 PC）**：owner 未裁決前，Android 只支援 v1.6 PC 的新配對；已配對的
   E2E 不受影響。這是本單唯一的契約阻塞。
2. **P12 模組登記**：`spec/platform/android-module-map.json` 與 `android/README.md` 目前
   沒有 `PhoneDSHPCLink`；`android/tools/structure_check.py:47-61` 的 `EXPECTED_MODULES` 是硬編碼 13 個，
   加 `:pclink` 必須同步改 checker 與其測試。這是 C0 的前置，不是 C1 的工作。
3. **P09 page 契約的 `android.file`**：`extract_ios_pages.py` 會自動找到
   `fun PCPairingPage(`/`fun ConnectedComputerPage(`，但 `spec/ui/v1/pages/*.json` 的
   `android` 區塊目前是 `file:null, match:"missing"`；C5 完成後必須由 P09 owner 跑
   `extract_ios_pages.py --root .` 重新產生，否則 `page_structure_check` 仍報 missing。
4. **Android Keystore 真機行為**：StrongBox/TEE 降級、credential 變更、備份還原、OEM
   差異都未验证；`not-verified` 平台條目不得當作承諾。
5. **Doze/前景 service**：Android 的 relay socket 只在窄窗口存活；若產品要求在背景接收
   approval，必須另立 P03/P08 變更（foreground service 類型、通知、電池），本單不承諾。
6. **`ProbeEngineViewModel.kt` 的共享衝突**：C5 需要在 composition root 加 PC backend，
   這個檔案可能同時被其他 wave-2 worker 修改；C5 必須在開工前 rebase，且只加最小的
   backend 選擇 seam。
7. **Kotlin/BC 的 strict JSON 差異**：`org.json` 不接受重複 key 偵測/嚴格 UTF-8；必須自寫
   parser（C1），不能借用 `org.json`。canonical JSON 的 key 排序必須按 Unicode scalar /
   UTF-8 byte，不能用 Kotlin `String.compareTo`（UTF-16 code unit）。
8. **Ktor client 依賴**：目前 repo 只有 Ktor server 與 test client（`android/net/build.gradle.kts:34-36`）；
   把 `ktor-client-cio`/`ktor-client-websockets` 3.2.3 放進 `:pclink` 是新的 main 依賴，
   需在 C0 的 build 檔審查 TLS/憑證/代理行為；若真機 TLS 行為不符，退回 OkHttp 是另一個
   dependency 決策，不在本單凍結。
9. **無真機證據**：本單所有 Android 命令在 CI/JVM 上最多證明 codec/state machine；真機
   Keystore、Doze、camera QR、public WSS 都必須另跑，結果如實記 `NOT_RUN`/`NOT_VERIFIED`。

## 7. 修訂紀錄

| revision | 由誰 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| draft-1 | 本單作者（非 owner） | 初稿：Android 納入 P28 的條款、P18/P09 提升清單、platform 三條、C0–C5 分工；提出 CCR-1（pre-v1.6 PC 配對） | P28 owner、P09/P18/P08/P12 owner、Android parity |
| frozen-1 | P28 contract owner（contract revision `cb0bfd27`） | Owner applied §2.1 and CCR-1 option (a): v1.6 client 不支援與 pre-v1.6 PC 的新配對（回報 120 s timeout + 升級提示），已配對 v1.5 record 仍可用；wire／版本不變（`pclink-v1.6`）；Android 維持 `target`／in progress，未宣告 conformance | P09/P18/P08/P12 owner、Android parity、iOS/PC/relay |
