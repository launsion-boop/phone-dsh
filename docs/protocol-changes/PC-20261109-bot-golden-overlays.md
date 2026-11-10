# Bot golden 覆盖文件整理（P26/P27）

```yaml
change: PC-20261109-bot-golden-overlays
contracts: [P26, P27]
status: implemented
breaking: false
version_decision: Test-fixture reorganisation only. No P25 event envelope, schema, wire value, error code or runtime behaviour changes; the merged case set is unchanged. Upstream golden files return to their exact `bf4075b0` export and every phone-only case moves to the existing/new `<name>.phone.json` overlays.
base: fd7d87632122ecae1613e8a9b2c15b84f72f50fa
contract_revision: spec/bot/v1/README.md@golden-overlays-v1
```

Protocol impact: P26; P27; P25: none — `event-envelope.json`、`dshbot-pin.json` 与事件 envelope 未改；P07: none — `device-task-result` 只是把既有 golden 例子移到覆盖文件，device task/journal/grant 契约不变；P09: none — 无页面、token 或 UI 契约改动。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 审计发现 `spec/bot/v1/golden/` 的上游导出文件被手机端开发直接追加：`held-inbox.json` 有 `deviceTaskResult`/`agentHeld`/非法 `device-task-result`，`row-protocol.json` 有 `cardAnswer`/`invalidActions`，`tool-effects.json` 有 BLE `nativeMcp`/`nativeMcpNote`。重跑 `export-vectors.mjs` 会覆盖这些用例；`export-manifest.json` 也缺 `card-payload.phone.json`、没有 `sha256`，且把 `bot-attachments.json` 错误地当成导出器产物之外的清单项。期望：上游文件逐字节等于导出；手机用例只在同名 `.phone.json`；加载器合并两者；清单和校验器能证明这一点。
- **Coordinator / contract owner / implementer / reviewer-integrator:** `bm-spec` 单元依 AGENTS.md §3 产出本记录。Owning contracts：P26 `spec/bot/v1/README.md`、`held-inbox-item.schema.json`、`tool-effects`/`held-inbox` golden 与覆盖文件；P27 `row*` golden 与覆盖文件。
- **Affected ends:** `spec/bot/v1/**`、`spec/tools/bot/**`、Swift `Tests/PhoneDSHBotTests` 的 golden 加载 helper、`plugins/tests` 的 golden helper、`scripts/ci/check.sh`。无生产代码、Worker、Kotlin、Rust 或固件改动。
- **Upstream reference:** dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`，验证时只读 `/Users/leilangsheng/Desktop/dsh-bot/.claude/worktrees/mystifying-albattani-1fbe1a`。

## 2. 移动的条目

逐文件重新导出并与仓库 diff，只有以下三个上游文件有非上游内容：

| 上游文件 | 移出的非上游内容 | 目标覆盖文件 |
| --- | --- | --- |
| `golden/held-inbox.json` | `valid.deviceTaskResult`、`valid.agentHeld`、`invalid` 中 `id=device-task-result-invalid`（`status=timeout` 反例） | 新建 `golden/held-inbox.phone.json` |
| `golden/row-protocol.json` | `valid.cardAnswer`、`invalidActions` 两条（`nonce-card-answer-text`、`nonce-card-answer-custom`） | 并入 `golden/row-protocol.phone.json` |
| `golden/tool-effects.json` | `nativeMcp` 六条 BLE 工具与 `nativeMcpNote` | 并入 `golden/tool-effects.phone.json` |

其余上游 golden（`approval-patterns`、`bot-attachments`、`bot-profile`、`card-payload`、`context-lint`、`context-profiles`、`event-envelope`、`fish-director`、`llm-ledger`、`memory-*`、`model-purpose-policy`、`row-projection`、`tool-catalog`、`volatile-context`、`wake-routine`、`watchdog`）重新导出后零差异。

同时修正一个此前未登记的手写文件：`golden/bot-attachments.json` 本来就是可以从上游 `attachments.cjs` + `dshTranscript.cjs` 生成的 P27 fixture，但 `export-vectors.mjs` 没有导出它，清单却把它列为生成物。本变更扩展导出器生成该文件；生成结果与仓库原文件逐字节相同，因此不再存在“清单里的非导出 golden”。

## 3. 覆盖文件与合并语义

格式沿用 `card-payload.phone.json`/`row-protocol.phone.json` 既有形状：`schemaVersion`、`vector`、`source.checkout`、可选 `upstream`、`delta`，然后是与上游同名的 case 容器。

合并实现于三处并保持同一语义：

- Python：`spec/tools/bot/golden_overlay.py`（`merged_fixture` / `assert_append_only`）。
- Swift：`Tests/PhoneDSHBotTests/GoldenFixtureSupport.swift`（`BotGoldenFixture.mergedObject` / `mergedData`）。
- TypeScript：`plugins/tests/bot-golden.ts`（`readBotGoldenMerged`）。

规则：

1. 对象的 case 容器（如 `valid` 字典）按键合并；同名键由覆盖文件替换（按 id 覆盖）。
2. 数组的 case 容器（如 `valid`、`invalid`、`invalidActions`、`nativeMcp`）按 identity 追加或替换：identity 依次取 `name`、`id`、`nonce`、`action.nonce`；无 identity 的条目只在完全相同时去重。覆盖文件只能增加或按 identity 替换，不能删除上游用例。
3. `schemaVersion`、`vector`、`source`、`upstream`、`delta` 是文档元数据，不参与合并；合并结果保留上游元数据（例如 `vector` 仍是 `tool-effects`）。
4. 读取 golden 的测试通过合并加载器取得完整用例集；只读上游文件的测试仍只覆盖上游批次。

现有测试的读取点同步为：`RowTestSupport.golden` 与 `wp6Golden` 使用合并加载器，`BotGoldenVectorTests` 的 BLE 向量读取合并后的 `tool-effects`，TS `bot-identity-approval.test.ts` 使用 `readBotGoldenMerged('tool-effects')`。`RowProtocolGoldenTests` 的附件反例切片从合并后的 `invalidActions` 按 `reason` 前缀筛选，仍精确保留原来的 2 条附件反例。

## 4. 清单与校验

`export-manifest.json` 现在由导出器生成以下字段：

- `source.checkout`：固定 `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`。
- `files`：`golden/*.json` 全量（27 个）。
- `upstream`：本轮导出器写出的 22 个文件（含 `bot-attachments.json`，不再有手写导出文件）。
- `phoneOverlays`：全部 5 个 `*.phone.json`。
- `sha256`：每个文件精确字节的 SHA-256。

新增 `spec/tools/bot/check_golden.py`：

- 默认离线模式（CI）：清单与文件集合一致、`upstream ∪ phoneOverlays = files`、每个摘要匹配、每个覆盖文件 `upstream` 指向上游文件、`vector`/`source` 正确、`assert_append_only` 通过、合并结果非空。
- `--checkout <path> --sha ...`：真实运行 `export-vectors.mjs` 到临时目录，要求每个上游文件逐字节相同、`upstream` 清单相同、摘要相同。CI 没有私有 checkout，离线模式不会冒称已证明“上游 = 原样导出”。
- `scripts/ci/check.sh` 的 `phone-spec` 阶段现在运行 `validate_vectors.py`（合并 fixture）与 `check_golden.py` 离线模式；导出器在 `--out` 时也拒绝既非导出也非 `.phone.json` 的手写 golden。

`validate_vectors.py` 改为对 `held-inbox`、`row-protocol`、`tool-effects` 读取合并结果，并逐覆盖文件执行 append-only 检查；`held-inbox.agentHeld` 也新增了 schema 校验。

## 5. 兼容性与用例数

这些是测试 fixture，不是线上 wire 或持久化格式；不改任何运行时读取者。对测试的影响：

| 用例集 | Before | After（合并） |
| --- | --- | --- |
| `held-inbox` | `valid` 6 + `invalid` 3 = 9 | `valid` 4+2 + `invalid` 2+1 = 9 |
| `row-protocol` + `.phone` | 上游 10 + 覆盖 5 = 15 | 合并 `valid` 8 + `invalidActions` 4 + `invalid` 2 + `projection` 1 = 15 |
| `tool-effects` + `.phone` | 上游 29（21+2+6） + 覆盖 3 = 32 | 合并 24+2+6 = 32 |
| `card-payload` + `.phone` | 14 + 8 = 22 | 14 + 8 = 22（不变） |
| `tool-catalog` | 27（16+5+6） | 27（不变） |

Swift `PhoneDSHBotTests` 的测试函数与执行数均为 376，前后不减少；TS bot 测试 52 个（51 pass、1 既有 skip）。所有共享 fixture 仍由真实 decoder/validator/classifier/inbox 读取。

## 6. 实测记录

环境：worktree `bm-spec`，HEAD `fd7d87632122ecae1613e8a9b2c15b84f72f50fa`，上游 SHA `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`。

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 重新导出并逐文件 diff | `node spec/tools/bot/export-vectors.mjs --checkout <上游> --sha bf4075b0... --out /tmp/bm-spec-export2`，再对 `golden/*.json` 逐一 `diff` | PASS：22 个上游文件零差异；5 个 `.phone.json` 只存在于仓库 |
| golden 校验（含真实导出） | `python3 spec/tools/bot/check_golden.py --root . --checkout <上游> --sha bf4075b0...` | PASS：27 files / 22 upstream / 5 overlays；fresh export byte-identical |
| golden 校验（离线） | `python3 spec/tools/bot/check_golden.py --root .` | PASS |
| mutation：篡改上游字节 | 在 `held-inbox.json` 末尾追加空行后运行离线校验 | PASS（正确 FAIL：`sha256 mismatch`）；恢复后 PASS |
| mutation：手写未知 golden | 临时加入 `manual-probe.json` | PASS（正确 FAIL：`files != golden/*.json`）；删除后 PASS |
| Python vectors | `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（schemas、正例、反例） |
| Swift Bot tests | `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS：376 tests，0 failures |
| TS typecheck | `cd plugins && npm run typecheck` | PASS |
| TS bot tests | `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` | PASS：52 tests，51 pass，1 既有 skip，0 fail |
| CI | `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS：phone-spec 17s、phone-cross-tree 17s；8/8 invariants；registry byte-identical；0 breaking schema；87 mutation tests OK |
| 再导出幂等 | 在仓库内再运行一次 `export-vectors.mjs --out spec/bot/v1`，比较 `git diff`/`git status` | PASS：tracked diff 与 status 均不变 |
| whitespace | `git diff --check` | PASS |

Not verified: 无。本变更不涉及 App build、模拟器、真机或 Worker bundle；未运行这些未受影响的检查。

## 7. 剩余风险

- `spec/README.md` §4 的 P26/P27 触发 glob 没有逐个列出新的 `held-inbox.phone.json`（以及既有 `tool-effects.phone.json`/`tool-catalog.phone.json`）。本单元路径权限只到 `spec/bot/v1/**`，未改 `spec/README.md`/`spec/registry.json`；`phone-cross-tree` 的 registry 检查保持通过，但“只改该覆盖文件”不会自动触发 P26。建议 contract owner 在下次 baseline 更新时把 `spec/bot/v1/golden/*.phone.json` 加入 P26/P27 triggers。
- `bot-attachments.json` 现在由 exporter 生成，但它的内容仍依赖上游 `attachments.cjs`/`dshTranscript.cjs`；上游 pin 升级时必须重跑 exporter 并审查生成 diff。离线 CI 只能证明 manifest 摘要未变，`--checkout` 模式才能证明与上游一致。

## 8. 修订记录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| `golden-overlays-v1` | `bm-spec` | 把手工追加的 P26/P27 golden 用例移入 `.phone.json`，恢复上游导出、修正 manifest 与加载器，并补上覆盖文件校验 | Swift tests、TS tests、spec/CI owner |
