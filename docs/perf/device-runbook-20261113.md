<!-- SPDX-License-Identifier: MIT -->
# 真機三畫像基線：一次性執行手冊

日期：2026-11-13
目的：**用一個 session 把 `spec/v1/budgets.md` §7 的七列 `待基线` 變成有依據的數值。**

Protocol impact: none — documentation only

---

## 0. 為什麼只有真機能翻轉這些列

`PC-20261112-w0-baseline-budgets` 明文寫：

> 三個畫像欄的值一律是字面 `待基线`，**不得填入估算、代測或其他裝置的數字**。
> …**不得以 token 估算、舊裝置數字或模擬器數字填寫**；不得把 `target` 列當成已實現門檻。
> `target → implemented` 需要**三畫像的真機基線報告**，不是 spec checker 通過。

所以模擬器、合成夾具、單元測試都**不能**取代這一步。本手冊只解「怎麼把這一步做完」。

## 1. 前置

| 項目 | 要求 | 現況 |
| --- | --- | --- |
| 裝置 | 一台已配對的 iPhone／iPad，連線後 `xcrun devicectl list devices` 的 State 要可用 | 已配對兩台（iPhone Air `321FACB9-…`、iPad Pro 13" M4 `3EE934E9-…`），目前 `unavailable` = 未連線 |
| 簽名 | 有效的開發團隊；**必須簽名建置**（見 §2 的陷阱） | — |
| DSH checkout | `PDSH_DSH_CHECKOUT` 指向 pinned checkout，用於打包 Worker bundle | — |
| 模型 | 真模型或 scripted SSE upstream 皆可；**兩者都要在報告裡寫明** | 模擬器那次用的是 scripted upstream |
| 工具鏈 | Xcode 26.5、XcodeGen、Python 3（跑 `scripts/perf/`） | 本機具備 |

## 2. 建置（唯一正確的方式：簽名）

```bash
cd examples/probe-app
xcodegen generate
xcodebuild build \
  -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/pdsh-device-dd \
  -allowProvisioningUpdates
```

**陷阱（已在模擬器上實測）**：`CODE_SIGNING_ALLOWED=NO` 的產物**可以編譯但讀不到 Keychain**，
首次啟動會出現 `provider seed failed: keychain(-34018)`（`errSecMissingEntitlement`），因此
**無法持有模型憑據、跑不出回合**。不要用那個變體做量測。

Worker bundle 是 gitignored 的：`examples/probe-app/Bundle/worker`，依
`examples/probe-app/Bundle/README.md` 產生。缺它會在建置的 `CpResource` 步驟失敗。

## 3. 安裝與啟動

```bash
UDID=<device-udid>
APP=/tmp/pdsh-device-dd/Build/Products/Debug-iphoneos/PhoneDSHProbe.app
xcrun devicectl device install app --device "$UDID" "$APP"

# 啟動並帶環境變數；--terminate-existing 保證乾淨的一次執行
xcrun devicectl device process launch --device "$UDID" --terminate-existing \
  -e '{"PDSH_CHAT_AUTOSTART":"1","PDSH_CHAT_AUTOPROMPT":"<probe prompt>","PDSH_SEED_PROVIDER_KIND":"…","PDSH_SEED_PROVIDER_BASE_URL":"…","PDSH_SEED_PROVIDER_MODEL":"…","PDSH_SEED_PROVIDER_KEY":"…"}' \
  dev.phone-dsh.probe
```

`devicectl` 也接受 `DEVICECTL_CHILD_*` 前綴的呼叫端環境變數（與模擬器的 `SIMCTL_CHILD_*` 同義）；
用 `-e` 時會覆蓋那些前綴。變數名稱以 `examples/probe-app/README.md` 與 `PhoneDSHProbe` 的
fixture 入口為準，不要照抄猜測。

## 4. 夾具（三個畫像）

```bash
for p in light typical heavy; do
  python3 scripts/perf/generate_container.py --profile "$p" --output "/tmp/fixture-$p"
done
```

- `light`：20 會話 / 50 MB 工作區；`typical`：150 / 150 MB；`heavy`：500 / 288 MiB。
- 夾具生成是**確定性**的（同 seed 位元組相同），已在 CI 與本機驗過。
- 注入到裝置上的 app 容器：`devicectl device copy to --domain-type appDataContainer
  --domain-identifier dev.phone-dsh.probe --source /tmp/fixture-$p/materialized
  --destination …`。

> **NOT_VERIFIED**：這一步（把夾具注入真機 app 容器、且不與 app 自身狀態衝突）我**沒有**在裝置上
> 驗過。模擬器那次是用 app 自己的 fixture 入口跑回合，不是注入合成夾具。首次執行時要先把
> app 的 host root 實際佈局印出來確認（模擬器實測是 `Documents/chat-host/{wal,response-log,
> steps,exec,materialized}`，**不是** `Documents/materialized`），再決定 destination。

## 5. 採集

```bash
# a) 容器整包取出
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier dev.phone-dsh.probe \
  --source . --destination /tmp/container-$p

# b) 每回合的 I/O 數字（PR #147 接的線）
grep turn-io /tmp/container-$p/Documents/boot-timings.log

# c) 容器位元組足跡（PR #146/#155 修過的分類器）
python3 scripts/perf/measure_container.py /tmp/container-$p > /tmp/measure-$p.json

# d) 回合結果與錯誤
grep -E "Turn ended|error" /tmp/container-$p/Documents/chat-status.log | tail
```

`turn-io` 一行長這樣（模擬器實測）：

```text
turn-io 2026-11-12T16:34:26Z boot=… session=… turn=1 outcome=completed fsync_calls=10 bytes_written=90789
```

## 6. 指標 ← 命令對應

| §7 列 | 怎麼得到 | 備註 |
| --- | --- | --- |
| Cold start to sendable | 裝置日誌時間戳：process start → 首則使用者訊息進 outbox 並投影 | 需要帶時間戳的 log |
| First token latency | 同上：prompt 被接受 → 第一個 model token 到頁面 | 需要真模型或可標註的 scripted upstream |
| fsync calls per turn | `turn-io` 的 `fsync_calls` | 只涵蓋 `PhoneDSHLog` 的 store（steps／exec／response-log 未計），是**下界** |
| Bytes written per turn | `turn-io` 的 `bytes_written` | 同上 |
| Idle 10 min: wakeups | **只能 Instruments**（Energy／CPU 取樣） | 沒有 in-app 儀器 |
| Idle 10 min: bytes written | 容器量測前後差 ＋ 一次定期 epoch close | 需固定 10 分鐘窗 |
| Host internal storage steady state | `measure_container.py` 的 `total_bytes` | 對照 §9 的公式（工作區本體的倍數） |

三畫像各跑一次 → 每個 cell 取同一畫像多次執行的中位數，並在報告裡寫明次數。

## 7. 翻轉流程（誰能改）

真機報告齊備後，**由契約 owner**（不是實作方）依 `AGENTS.md` §3.1 寫一份變更單，
把對應列的 `待基线` 換成數值，同步更新 `spec/v1/golden/plan/perf-targets.json` 的 valid 列。
在那之前任何人不得改那兩個檔案——包含不要用模擬器數字「先填一下」。

## 8. 我實際驗過 / 沒驗過

**驗過（模擬器＋本機）**
- `CODE_SIGNING_ALLOWED=NO` 的 Keychain 失敗（`keychain(-34018)`）
- `turn-io` 真的會被寫出且數字非零（兩個真實回合）
- 容器匯出後 `measure_container.py` 能分類（含 `caches`、`app-support`）
- `generate_container.py` 三畫像可重現、位元組一致
- `devicectl` 的 `install` / `process launch -e` / `copy to|from` / `info files --domain-type
  appDataContainer` 語法（本機 `--help` 核對，**未**在裝置上執行）

**沒驗過（首次執行時要當成未知）**
- 真機安裝、啟動、簽名流程
- 夾具注入真機容器的可行性與正確 destination
- 真機的 `turn-io` 數字、容器佈局是否與模擬器一致
- jetsam、功耗、熱、系統回收、APFS 實體配置
- 十次以上重複取中位數的穩定性

## 9. 已知陷阱

1. **簽名**：無簽名建置跑不了回合（§2）。
2. **Worker bundle**：gitignored，缺它建置失敗。
3. **`plugins/node_modules` 會過期**：`PhoneDSHADBTests` 的 3 個案例會因為缺
   `@deepseek-ai/dsh-tool-executor-native` 與 `@modelcontextprotocol/client` 而失敗；修法
   `cd plugins && npm ci`。
4. **`.build` 陳舊物件**：跨分支切換後 `swift test` 可能連結失敗並引用舊簽名，
   `swift package clean` 後重建即可。
5. **`Package.resolved` 會被 SwiftPM 重寫**（掉 swift-cmark 等 pin），跑完要 `git restore`。
