<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-github-agent-credential — GitHub Agent 寫入憑證（host 接線）

## 0. 摘要（機器可讀）

```yaml
change: PC-20261112-github-agent-credential
contracts: [P09, P16, P18]
status: draft
breaking: false
version_decision: Additive host-only record and one Worker environment fact. No existing key, env or wire shape changes; an old host ignores the new Keychain record and an old Worker ignores PDSH_GITHUB_AUTH.
base: 20ef5ca4
contract_revision: pending
```

## 1. 識別與角色

- **Trigger → 現況 → 期望.** Worker 的 `github` 指令（PR #124）需要 host credential
  gateway 對 `api.github.com` 注入 credential，並以 `PDSH_GITHUB_AUTH` / `PDSH_GITHUB_WRITE`
  決定讀取與寫入 verbs 是否可用；目前 host 只有 model credential provider，對 allow-listed
  非 model host 回 `Credential.none`，所以 `commit` / `branch` / `pr` / `search` 一定 401。
- **Owner / implementer / reviewer.** host SDK（`Sources/PhoneDSH`）、probe App 設定頁；
  同一 PR 完成，無跨端 producer。P09 只新增 iOS 設定頁 `GitHubAgentSettingsPage`
  （`spec/ui/v1/pages/git-hub-agent-settings.json`）；Android 對應頁記為 later/GAP，
  不重定義既有設定頁。
- **Owning spec / schema.** 本單；`Sources/PhoneDSH/PhoneGitHubAgentSettings.swift` 是
  Keychain record、UserDefaults opt-in 與 provider 的單一 owner。

## 2. 契約 delta

| 項目 | Before → After |
| --- | --- |
| Keychain | 新增 service `dev.phone-dsh.github.agent`、account `access-token`；`AfterFirstUnlockThisDeviceOnly`；只存 fine-grained token，不進 Worker。 |
| UserDefaults | 新增 `phone-dsh.github.agent.allow-writes`（Bool，預設 false）；只有 true 且 token 存在時 host 才注入 `PDSH_GITHUB_AUTH=1`。 |
| Worker env | `PDSH_GITHUB_AUTH`（token 存在）與 `PDSH_GITHUB_WRITE`（token + 寫入開關）都為 `"1"` 或 `"0"`，由 host 決定；App 的 environment override 不能偽造 `"1"`。 |
| `/v1/http` | 不改。既有 allow-list、header strip、redirect scope、credential injection 全部照舊；`api.github.com` 只在 HTTPS + 443（或未帶 scheme/port 的舊 scope）取得 bearer。 |
| 其他 host | `CredentialProvider` 對非 `api.github.com` scope 一律 delegate 原有 provider；`api.github.com` 的非 HTTPS/非 443 scope 回 `.none`，不把 token 送出去。 |
| 讀取 | token 存在與否都不影響匿名 public read；`github` 的 write gate 仍由 Worker 的 `PDSH_GITHUB_AUTH` 決定。 |

自檢：沒有新增第二種 envelope、沒有改 `/v1/http` wire、沒有改動既有 Keychain record；
新欄位皆為 additive 且有缺省（未設定 = 唯讀）。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old host → new App | 舊 host 不讀新 Keychain；App 的 token 頁可存但舊 host 不注入，`github` 維持匿名/唯讀。 |
| new host → old App | 舊 App 沒有 token 頁，record 不存在；`PDSH_GITHUB_AUTH=0`。 |
| new → new | 存 token + 重啟 engine 後，`github` 的 `search` 可用；再開啟 write opt-in + 重啟後 `branch`/`commit`/`pr` 可用。token 權限不足時 GitHub 回 401（不刪 token）。 |
| persisted old data → new／rollback | 新 Keychain record 與 UserDefaults key 都可獨立刪除；rollback 後 host 不再注入，Worker 看到 `PDSH_GITHUB_AUTH=0`。 |

- 版本／adapter：無版本欄位；不新增第二個 credential provider 概念，wrapper 與既有
  `CredentialProvider` 介面一致。
- 發佈順序：host 先於 Worker #124；Worker 舊版忽略 `PDSH_GITHUB_AUTH`。
- 不在本單：把 Discover 的唯讀 connector token 自動升級為寫入；兩者是不同的 Keychain
  record，避免一個唯讀授權默默變成寫入授權。

## 4. 分工與證據

- 獨占路徑：`Sources/PhoneDSH/PhoneGitHubAgentSettings.swift`、
  `examples/probe-app/PhoneDSHProbe/GitHubAgentSettingsPage.swift`、
  `examples/probe-app/ProbeKit/ChatHostConfiguration.swift`。
- 驗收命令：
  - `swift test --filter GitHubAgentCredentialTests` → PASS（6 tests）
  - `swift test --filter PhoneDSHWorkerEnvironmentTests` → PASS
  - `xcodebuild -project examples/probe-app/PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED（以 XcodeGen 重新產生的 project；repo 既有的 `BotUIFormat`/`BotActivityPhrases` project membership 缺漏不在本單）
- 未驗證：真機 Keychain 解鎖時序、GitHub 真 token 的 write scope、App 重啟後 host 重建的 UI 流程。
- 剩餘風險：使用者給唯讀 token 並開啟 write opt-in 時，`commit` 會收到 GitHub 401；
  設定頁已寫明需要 Contents/Pull requests write，且 401 不會刪除 token。
