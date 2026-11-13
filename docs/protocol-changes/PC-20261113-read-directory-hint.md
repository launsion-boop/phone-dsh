<!-- SPDX-License-Identifier: MIT -->
# PC-20261113-read-directory-hint — append a glob/ls hint to `read`'s directory error

## 0. 摘要

```yaml
change: PC-20261113-read-directory-hint
contracts: [P26]
status: draft
breaking: false
version_decision: 不升版本。没有工具名、参数 schema、result envelope、错误码或 wire 字段变化；只在 `read` 的既有错误结果后追加一个 text block。`FS_NOT_REGULAR_FILE` 仍是 DSH 的代码。
base: 4864dfdc66dbcb4b8fd9efc83bb05dacaeb7e173
contract_revision: 本单所属 commit（draft）——`plugins/tool-fs-directory-hint/**` 与 `plugins/profile/phone.worker.cordis.patch.yml` 的 `tool-fs-directory-hint` insert row
```

## 1. 识别与角色

- **Trigger → 现况 → 期望。** 真机 `read /dsh/workspace` 返回 `Error: cannot read "…": not a regular file`（`FS_NOT_REGULAR_FILE`），没有提示改用 `glob`。期望：同一错误仍可被代码识别，但模型能看到「这是目录，用 glob 或 ls」。
- **Coordinator / contract owner**：本 worktree（phone profile 与 phone-local tool policy）。**Implementer**：`plugins/tool-fs-directory-hint` + profile 行。
- **Owning spec / fixtures / schema**：没有 schema 变更；`read` 由 pinned DSH `dsh-tool-fs` 拥有。P26 登记表覆盖 `plugins/profile/**`（工具面/profile 行）。测试：`plugins/tests/tool-fs-directory-hint.test.ts`。
- **受影响的 producer / consumer**：
  - Producer：Worker 的 `tools/post-execute` waterfall；新监听器只在 `exec.name === 'read'`、`result.isError === true`、content 匹配 `cannot read "…": not a regular file` 且还没有 hint 时追加。
  - Consumer：模型收到的失败结果 / Bot transcript 的错误文本。
  - **未被要求**：DSH `dsh-tool-fs` 源码（零 patch）；`read` 对目录直接返回目录条目（会改变工具语义）；其他工具的结果。

## 2. 契约 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| `read` 工具名 / 参数 schema / 结果状态 | **不变**。仍注册、仍 `isError: true`。 |
| 错误码 | **不变**：`FS_NOT_REGULAR_FILE`。 |
| 模型可见 content | `cannot read "…": not a regular file` → 同样内容 + 一个 `{type:"text", text:"Hint: this path is a directory; use glob (or \`bash ls\`) to list its entries."}` block。 |
| 幂等 | 已有 hint 的结果不再追加（单测覆盖）。 |
| 其他工具 / 非错误结果 | **不变**。 |
| 失败模式 | 如果 DSH 改了错误文案，正则不再匹配，结果是**原错误无 hint**；不会误改别的错误。 |

**自檢。** 没有新增工具、字段或错误码；没有放宽任何权限。没有复制 `read` 的实现，只消费 `tools/post-execute` 的公开 waterfall。上游仍可在 `dsh-tool-fs` 里给同一句话，本单的 hint 不会与其冲突（幂等检查）。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old profile → new plugin absent | 旧 Worker 没有该 row → 旧文案，行为不变。 |
| new profile → new plugin | 命中时多一个 text block；未命中时与旧行为逐字相同。 |
| new → old | 无持久化/ wire 变化；回滚只移除 row。 |
| persisted old data → new／rollback | 不適用：tool result 是运行时的，不落盘为可迁移格式。 |

- **版本決定**：不升版本。
- **部署順序**：与其他 Worker profile 行同包发布；没有 App 侧依赖。
- **`target` 與仍保留的差異**：上游 `dsh-tool-fs` 的文案修复仍是 proposal；phone 的 hint 是 policy 层，不是把 DSH 的实现改成返回目录条目。

## 4. 分工與證據

- **本單獨占路徑**：`plugins/tool-fs-directory-hint/**`、`plugins/profile/phone.worker.cordis.patch.yml`（该 row）、`plugins/package.json`、`plugins/tsconfig.json`、`plugins/package-lock.json`、`plugins/tests/tool-fs-directory-hint.test.ts`、`docs/upstream/2026-11-13-tool-fs-read-directory.md`、本单。
- **共享 fixtures**：无；单测伪造 `ToolExecutionResult` 的失败 content。
- **各端真實 proof**：
  - `cd plugins && node --test tests/tool-fs-directory-hint.test.ts` → **PASS**（4 tests）。
  - `npm run typecheck` → **PASS**。
  - `PDSH_DSH_CHECKOUT=… node --test scripts/profile.test.mjs` → **PASS**。
  - 真机 `read <dir>` → **NOT_VERIFIED**（本机模拟器；建议下一轮复测 R2）。
- **剩餘風險**：如果 DSH 改成另一种错误文案，hint 不再出现；这是有意的失败-静默（不误改其他错误）。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | 本 worktree | 2026-11-13 R2：read 目录错误不可操作；用 post-execute policy 追加 glob/ls hint，保留 DSH 错误身份。 | Worker/profile；upstream 仍保留文案修复提案 |
