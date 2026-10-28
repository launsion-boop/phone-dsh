# @phone-dsh/dsh-feature-admin

MIT。只管理当前 DSH 镜像里**已经安装**的能力，不安装、不卸载、不更新任何包，
也不伪造插件行、skill 或 agent preset。

## 导出契约

| Face | 源码 | 作用 |
|---|---|---|
| `.` | `src/index.ts` | Host 插件，注册 `phone/featureAdmin` Typert Remote（service `featureAdmin`，namespace `phone`）。 |
| `./client` | `src/client/index.ts` → `lib/client.js` | 浏览器插件，向 DSH 自带 Plugins 设置页注册一个 `settings.plugins.tab`。 |
| `./cordis.patch.yml` | `cordis.patch.yml` | 供直接解析本包 patch 的消费者使用的备用行。 |
| `./package.json` | — | `dsh.client` 声明 `platform: web`。 |

同一个 Loader 行挂载 Host 半边；浏览器模块系统从同一个 manifest 的
`dsh.client` 读取 client 半边。

`exports["./client"].default` 指向 `./lib/client.js`：DSH 的 module table 把这个
`default` 字符串当作构建好的 page asset，直接按字节提供，不会在服务端转译
TypeScript。`types` 条件仍指向 `src/client/index.ts`，供 workspace 类型检查使用。
镜像 staging 前必须把构建入口 `src/client/index.ts` 输出为 `lib/client.js`（或
匹配的 `lib/client.*.js` chunk）。

manifest 只声明具体导出目标，刻意不带 `./src/*` 通配：镜像只发布 `lib/` 下的
构建产物，不发布源码树；通配路径会被 stager 当作字面量 `src/*` 复制而失败。

## Host 方法

所有方法返回：

```ts
type FeatureAdminResult<T> =
  | { ok: true; value: T }
  | { ok: false; code: 'unsupported' | 'invalid-request' | 'not-found' | 'conflict' | 'io-error' | 'internal'; reason: string; domainCode?: string }
```

| 方法 | 参数 | 真实来源 |
|---|---|---|
| `pluginList` | 无 | DSH `pluginInventory.list()`；额外返回 `platform`、`management`，以及默认保护 shipped 命名空间的逐行 `readOnlyReason`。Host inventory 或 `profileContext` 不能提供持久写入目标时，`management.available=false` 并给出原因，页面据此提前禁用开关，而不是点击后才失败。 |
| `pluginSetEnabled` | `entryId`, `enabled` | `@deepseek-ai/dsh-plugin-manager/src/patch.ts` 的 `writePluginEnabled`，原子写回当前 profile/home patch，保留注释、无关覆盖和 `!!js`，返回 `restartRequired` 与 `patchPath`。inventory 读取 → 层选择 → 写入 → composition 校验 → repair 全过程持有 `withFileLock(join(profile.dir, 'package.json'))`，与官方 plugin manager/config editor 使用同一把锁，因此两个并发启停不会互相覆盖。持锁后先快照 profile 与 home 两层 patch 的原字节；repair 写入、composition 读取或最终校验失败时原子恢复这两个文件，所以报错不会改变下次启动状态，也不会覆盖另一个已提交的启停。官方 writer 的 implied 只组合 bundle 与目标文件；写后 Host 会重新组合 bundle+profile+home+overlays 校验实际状态，若较早的 profile 覆盖仍生效，则显式写 home 层开关并再次校验。受保护的管理行返回 `conflict`，不会写入。 |
| `skillsList` | 无 | `/dsh/home/skills` 下扁平的普通 `.md` 文件。 |
| `skillsRead` | `name` | 通过 root realpath、symlink、越界校验后读取。 |
| `skillsWrite` | `name`, `content` | 同目录临时文件 + rename，随后让 `ctx.skills` 目录失效。 |
| `skillsDelete` | `name` | 同样校验后 unlink，并让目录失效。 |
| `agentPresets` | `{ request: { action: 'list' \| 'read' \| 'select', presetId?, sessionId? } }`，或扁平 `action`/`presetId`/`sessionId` | 官方 `ctx.agentPresets.remoteExportList()` / `readDocument()` / `select(agent, presetId)`。`select` 先要求 `sessionId` 属于真实 Host 管理的 Session 索引（`ctx.sessionController.list()`；若只挂了 store 则用 `ctx.sessions.list()`），并排除 subagent origin；未列出或仅 retained fallback 的 id 返回 `session/not-found`，不会先解析 Agent。 |

`profileContext` 缺失时 `pluginList` 返回 `management.available=false`，
`pluginSetEnabled` 返回 `unsupported`。`ctx.agentPresets` 缺失时三个动作都返回
`unsupported`，不会生成空 roster 或默认 preset。`ctx.skills` 缺失，或挂载的
registry 没有真实 catalog invalidator 时，写入/删除在落盘前拒绝，因为 slash
目录无法重新发现这个文件。

DSH 会先应用 profile patch，再应用 home patch。若目标行只由
`$DSH_HOME/cordis.patch.yml` 引入或覆盖，Host 会把同一个官方写入器指向 home
层；否则写入 launcher 提供的 profile patch。

DSH 0.2.1 没有公开的 `ctx.skills.invalidate()`。Host 会 feature-detect
registry 自己的 catalog 失效方法，并在写盘前要求它真实存在。只 emit
`skills/change` 不会清掉 registry 的 completed-catalog cache，因此没有
event-only 的成功回退：没有真实 invalidator 时返回 `unsupported`，文件不变。

## 路径规则

唯一根是 `/dsh/home/skills`。文件名必须是单个 kebab-case `*.md` basename。
Host 拒绝 NUL、反斜杠、`/`、绝对路径、`~`、`.`/`..` 段、非 `.md`、symlink
根、symlink 目标，以及任何 realpath 后落在根外的路径。列表会跳过非普通文件。

## 浏览器半边

client 通过页面现有的 `ctx.connection.rpc` 调用同一 `phone/<method>` 命名空间，
不新开 transport、session、聊天协议或 React 实例。tab 以 id
`phone-capabilities`、order `20` 注册到 `settings.plugins.tab`，提供：

- 真实 inventory 行与启用/停用开关；Host 标为 `readOnlyReason` 的行，以及
  `management.available=false` 时的所有行，只显示本地化的“受保护/不可用”标签，
  不渲染开关；Host 的英文技术原因只放在 `title` 属性；
- inventory 的每个 `fiberPhase` 都有本地化运行阶段；未来新增的未知阶段回退为
  已翻译的“未知”，不会把原始英文 token 塞进正文；
- skill 列表、Markdown 编辑、保存/删除；
- 官方 preset 列表、composition 查看、会话选择；选项来自
  `SessionListState.ids`（Host 列表成员），丢弃悬空行与 subagent origin 行，
  组件通过 `useSyncExternalStore` 订阅 `ctx.sessions.list`，所以 retained
  fallback 行不会成为目标，列表也不会过期；
- 常驻、由 locale 拥有的“重启生效”提示和“不能安装新包”平台边界；Host 的英文
  技术原因只放在 `title`，不作为中文界面正文。

保护策略是 shipped 命名空间默认拒绝：所有 `@deepseek-ai/*` 与
`@phone-dsh/*` 行都只读，除非列在 `TOGGLEABLE_PLUGIN_MODULES` 这个显式
allowlist 中。allowlist 只收不会带走页面、`/api` carrier 或它管理的
Agent/skill 服务的可选能力（例如 `dsh-office-to-pdf`、`dsh-schedule`、
`dsh-api-job-controller`、`dsh-workspace-files`）；其余 shipped 行保持启用，
未来镜像新增行也默认受保护，不需要再补一次名单。其他命名空间的行仍可切换，
因为它们不在本镜像的管理链路上。

管理链路有明确原因且永远不能从页面关掉：
`@phone-dsh/dsh-surface-phone`、`@deepseek-ai/dsh-host-webserver`、
`@phone-dsh/dsh-feature-admin`、`@deepseek-ai/dsh-host-plugin-inventory`、
`@deepseek-ai/dsh-api-gateway`、`@deepseek-ai/dsh-typert-registry`、
`@deepseek-ai/dsh-api-remote-access`、`@deepseek-ai/dsh-api-remotes`、
`@deepseek-ai/dsh-api-session-controller`、
`@deepseek-ai/dsh-api-settings-controller`、`@deepseek-ai/dsh-settings`、
`@deepseek-ai/dsh-client-modules`、`@deepseek-ai/dsh-client-connection`、
`@deepseek-ai/dsh-client-locale`、`@deepseek-ai/dsh-client-ui-layout`、
`@deepseek-ai/dsh-client-ui-renderer`、`@deepseek-ai/dsh-client-ui-settings`、
`@deepseek-ai/dsh-client-ui-settings-plugins`、
`@deepseek-ai/dsh-client-ui-settings-plugin-inventory`、
`@deepseek-ai/dsh-agent-preset-registry`、`@deepseek-ai/dsh-agent`、
`@deepseek-ai/dsh-session` 与 `@deepseek-ai/dsh-skill`。DSH 自带 inventory
投影不带 plugin manager 的 `readOnlyReason`，所以本包明确维护该策略并由 Host
强制执行，而不只是在页面隐藏按钮。行为测试会组合真实 base 与 phone profile
patch；任何 shipped 行没有显式 allowlist 却被判为可切换时测试直接失败。

## 最终集成必须做

1. 把 `phone-feature-admin` 加进 `plugins/package.json` workspaces 和最终
   `tsconfig`。
2. 在 `plugins/profile/phone.worker.cordis.patch.yml` 插入 phone 行。
   feature-admin 行同时挂 Host 与 client：
   ```yaml
   - id: feature-admin
     name: '@phone-dsh/dsh-feature-admin'
   ```
   包内 `cordis.patch.yml` 是同一行的备用声明。同一 profile 必须挂官方
   preset registry；否则 `ctx.agentPresets` 缺失，preset 区只能如实报
   `unsupported`：
   ```yaml
   - id: agent-preset-registry
     name: '@deepseek-ai/dsh-agent-preset-registry'
     config:
       default: standard
   ```
3. 把 `@deepseek-ai/dsh-web-app` 随包提供的 preset patch 文件按 web bundle
   自身顺序作为 bundle/patch 层应用：`presets/standard.patch.yml`、
   `presets/ptc.patch.yml`、`presets/minimal.patch.yml`、
   `presets/cordis.patch.yml`。它们声明 registry 可列出/选择的真实
   `@deepseek-ai/dsh-agent-preset` 行；只挂 registry 而不声明 preset 只会得到
   空 roster，不会伪造 preset。phone 镜像不 materialize `dsh-web-app` bundle，
   所以最终集成必须显式复制或应用这些文件；不能顺带复制 `web-runtime` 或
   创建第二个 `/api` carrier。
4. 用 DSH client build face 把 `src/client/index.ts` 构建为 `lib/client.js`
   （React external，复用页面 platform module table）。manifest 的
   `exports["./client"].default` 必须保持 `./lib/client.js`（或匹配的
   `lib/client.*.js` chunk）：DSH module table 把这个路径当作 page asset 按字节
   提供，不能指向 TypeScript 源码。它是 page asset，不能走 Worker lowering；
   镜像路径必须是 `node_modules/@phone-dsh/dsh-feature-admin/lib/client.js`，
   符合 DSH `PAGE_ASSETS`。
5. Host 半边按要求 import
   `@deepseek-ai/dsh-plugin-manager/src/patch.ts`。发布版 DSH 只带 `lib/`、
   不带 `src/`，当前 `scripts/pack-image.mjs` 又把所有 `@deepseek-ai/*` 保持
   external；最终镜像 staging 必须把这个模块、`yaml` 及其依赖 bundle 进 Host
   face（或随镜像提供 source face），否则 Worker 内解析失败。这是 build 契约，
   本包不能靠复制 DSH 代码绕过。
6. 不新增安装/卸载/market 方法。唯一的插件变更是 profile/home patch 的
   启停，Worker 重启后生效。

## 测试

```bash
PDSH_DSH_CHECKOUT=/dsh-reference node --test plugins/tests/phone-feature-admin.test.ts
```

使用真实临时 profile（bundle 层 + user patch，可选 home 层）、checkout 的官方
`writePluginEnabled` / `loadOverlayPatches` / `applyEntryPatches`、临时 skills
根里的真实文件和 symlink、缺少 `agentPresets` 的真实 ctx、真实 `SessionStore`
（attached 与 subagent Session）及其 Host `sessionController` catalog、可 resume
冷 Session 的 Typert `agent` lookup，以及官方 writer 会删除 switch-only home 行后
由 repair 分支补回的 profile+home 同 id 覆盖。两个 `pluginSetEnabled` 用
`Promise.all` 并发，必须在官方 profile 锁上串行且两项都持久化。另有一个冲突
launch overlay 让官方 writer 与 repair 分支都写完后才在最终校验失败：测试断言
失败调用返回 `conflict`、两层 patch 按原字节恢复，且另一个并发启停仍保留。测试
还检查 zh-CN 行文案（受保护/阶段本地化、英文原因只在 title）和 manifest
`exports["./client"]` 的 page asset 路径；并组合 checkout 的真实 `dsh-base`
patch 与 phone profile patch，任何 shipped 行没有显式 allowlist 却被判为可
切换时直接失败。它不跑 pnpm、不构建浏览器 bundle、不启动 WKWebView、不碰真实
DSH home。

## 平台边界

这不是远端 PC 包装器，也不是包安装器。iPhone 上镜像不可变，只允许改
profile/home patch 与扁平的 user skill 目录；页面每次都会展示该边界。
