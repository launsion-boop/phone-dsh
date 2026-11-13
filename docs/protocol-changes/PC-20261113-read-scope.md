<!-- SPDX-License-Identifier: MIT -->
# PC-20261113-read-scope — capabilities.json states the read boundary is global

## 0. 摘要

```yaml
change: PC-20261113-read-scope
contracts: [P18]
status: draft
breaking: false
version_decision: 无版本变更。`/dsh/home/capabilities.json` 与 `AGENTS.md` 只新增两个自述字段和一行散文；`pdsh-capabilities/1` schema 仍由生成器自己消费，没有任何跨进程 wire 或持久化格式变化。
base: 175fe3f586393df660e77e8ab6fc0ddd157e81b9
contract_revision: 本单所属 commit（draft）——`plugins/worker-entry/src/capabilities.ts` 的 `paths.read_scope` / `paths.read_scope_note` 与 `## Paths and /tmp` 一行
```

## 1. 识别与角色

- **Trigger → 现况 → 期望。** 2026-11-13 的真机实测：Bot 在 `/dsh/workspace` 下能读取其它会话的工作区（例如 `unslop-probe/AGENTS.md`），写权限却被限制在 `/dsh/workspace/.dshbot/agents/<bot>`。`capabilities.json` 的 `paths` 只列了持久化根，没有说读是全局的；模型与用户只能各自猜。期望：在能力清单里明确写「read/grep/glob 能读到本 VFS 内所有会话的 workspace/home 路径；写由宿主策略单独限制」，让「读是全局的」成为可引用的事实。
- **Coordinator / contract owner**：本 worktree（`plugins/worker-entry/src/capabilities.ts` 是登记表里的 P18 owner）。**Implementer**：同一处生成器；没有其他端需要改。
- **Owning spec / fixtures / schema**：登记表 P18（`/dsh/home/capabilities.json`：`plugins/worker-entry/src/capabilities.ts`）。机器可读文档没有独立 schema 文件；`CapabilityManifestDocument` 是生成器的类型。测试在 `plugins/worker-entry/src/capability-manifest.test.ts`。
- **受影响的 producer / consumer**：
  - Producer：Worker boot 的 `buildCapabilityManifest`（同一份输入生成 `AGENTS.md` 与 `capabilities.json`）。
  - Consumer：被注入 `$DSH_HOME/AGENTS.md` 的模型，以及任何读 `capabilities.json` 的排障者。没有代码 decoder 读 `paths.read_scope`；新增字段对旧读者是未知字段，按 JSON 的常规忽略。
  - 未被本修訂要求：DSH 的 `read`/`grep`/`glob` 实现（pinned DSH，零 patch）、Bot 工具白名单、任何 session 挂载。真正的会话级读边界属于 P14/P15，需要单独变更单；本单只消除「清单沉默」。

## 2. 契约 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| `paths.read_scope` | 不存在 → `"global"`（`'global' \| 'session'` 类型）。依据 P18 的 manifest 生成器。 |
| `paths.read_scope_note` | 不存在 → 一句可引用的话：`read`/`grep`/`glob` 能到 `/dsh/workspace` 与 `/dsh/home` 下每个会话；写由宿主策略单独限制。 |
| `AGENTS.md` 的 `## Paths and /tmp` | 只有持久化根与 `/tmp` 说明 → 增加一行「Reads are global … Writes are confined separately by the host policy.」 |
| 读/写语义 | **不变**。读仍是 VFS 全局；写仍由宿主工具策略限制。本单不新增、不放宽任何权限。 |
| schema tag | `pdsh-capabilities/1` 不变；字段是加法。 |
| 其它字段 | `workspace`、`home`、`image_readonly`、`tmp`、`persisted`、`volatile`、`limits`、`network`、`recovery` 全部逐字不变。 |

**自檢（spec/README.md §5.1）。** 没有新增第二种表达：`read_scope` 是机器可读的同一句话，Markdown 是给模型的那一份；两者不矛盾。没有放寬或收緊任何權限：`global` 描述的是今天的真实行为，不是新的授权。没有新 enum/错误码；`'session'` 是保留值，当前生成器只发 `'global'`。没有删除或重用任何名称。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 Worker 生成的清单没有这两个字段；读清单的模型/人只少一条事实，没有行为差异。 |
| new → old | 新清单多两个字段；旧读者按未知字段忽略（没有严格 schema decoder）。`AGENTS.md` 多一行，仍在 8 KiB 预算内。 |
| new → new | 同一份 `capability-manifest.test.ts` 断言 `read_scope`、note 和 Markdown 行；生成器仍是纯函数，同输入同字节。 |
| persisted old data → new／rollback | 不適用：`capabilities.json` 是每次 boot 的派生物，按内容哈希重写；回滚只是回到没有该字段的版本，不迁移任何状态。 |

- **版本決定**：不升版本。这是模型可读的说明性加法，不是跨端字节。
- **部署順序**：生成器（本 commit）→ 重建 Worker bundle/image（`node plugins/worker-entry/build.mjs`、`PDSH_DSH_CHECKOUT=… node plugins/scripts/pack-image.mjs`）→ App 内 Worker 下次 boot 写出新清单。旧 bundle 继续写旧清单，不需要兼容层。
- **`target` 與仍保留的差異**：真正的 session 级读边界仍是 `target`，归 P14/P15；本单**不**声称已实现边界，只声称清单不再沉默。

## 4. 分工與證據

- **本單獨占路徑**：`plugins/worker-entry/src/capabilities.ts`、`plugins/worker-entry/src/capability-manifest.test.ts`、本单。
- **共享 fixtures**：无新增 fixture；`manifestInput()` 的默认输入就是正例。负例由现有「no VFS_MUT second boot」「Markdown 预算」测试覆盖。
- **各端真實 proof**：
  - `node --test worker-entry/src/capability-manifest.test.ts` → 20 passed（含新增的 read-scope 用例）。
  - `bash scripts/ci/check.sh --only phone-bundle-fresh` → 需在重建 bundle/image 后复跑。
  - App 端注入的 `AGENTS.md` 预算：现有 `markdown <= AGENTS_MD_MAX_BYTES` 断言仍通过。
- **剩餘風險**：`read_scope: 'session'` 目前没有生产者；如果未来做 session 边界，必须同时改这里和真正的工具策略，不能只改清单。清单是自述，不是执行点。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1（本檔） | 本 worktree | 2026-11-13 交接单 P2-4：读侧无会话边界，至少让 capabilities.json 明确读是全局的。 | 模型（AGENTS.md）、排障者（capabilities.json）；P14/P15 owner 保留真正边界的设计 |
