#!/usr/bin/env node
# SPDX-License-Identifier: MIT
/**
 * Assemble the official-screenshot manifest from cdp-capture.mjs reports.
 *
 * Writes `manifest.json` (machine) and `manifest.md` (human) next to the PNGs.
 * Every claim in the manifest is derived from a capture report or from the
 * harness environment; nothing is copied from the audit prose.
 *
 * Both artifacts are publishing artifacts: `redactText` strips the home
 * directory and the internal service spelling from everything written, and
 * `assertRedacted` refuses to write a file that still carries one.  What was
 * removed is recorded in `manifest.redactions` so a reader knows the capture
 * contained it.
 */
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, isAbsolute, relative, resolve } from 'node:path'
import { assertRedacted, countRedactions, redactText, redactionReport } from './redactions.mjs'

const STATE_BY_LABEL = {
  'hero-sessionless': {
    zh: '官方 Web UI 会话空态（hero）：未登录、未配置模型、无会话；已按用户操作关闭 PWA 安装提示、预览版说明、开始使用弹窗',
    en: 'sessionless hero: not signed in, no model selected, no session; first-run overlays dismissed by user clicks',
  },
  'auth-gate': {
    zh: '官方 Web UI 首次使用认证闸门：开始使用弹窗（登录 DeepSeek 账号 / 添加 API Key）',
    en: 'first-use auth gate: get-started dialog (sign in to DeepSeek or add an API key)',
  },
  'session-chat': {
    zh: '官方 Web UI 已打开的记录会话（真实 chat）：短 user 气泡 + 时间戳 + 本轮运行失败（MISSING_CREDENTIAL）+ composer；抽屉、分组、会话行均为真实点击',
    en: 'opened recorded session (real chat): short user bubble + timestamp + failed turn (MISSING_CREDENTIAL) + composer; drawer/group/session row opened by real clicks',
  },
  'session-chat-long-user-turn': {
    zh: '官方 Web UI 已打开的长 prompt 会话（滚动到 turn tail）：长文本/代码块 user 气泡 + 时间戳 + 本轮运行失败 + composer',
    en: 'opened recorded long-user-prompt session scrolled to its turn tail: long/code user bubble + timestamp + failed turn + composer',
  },
  'session-chat-tool': {
    zh: '官方 Web UI 富会话（官方记录 fixture 经 JsonlSessionPersistence 播种）：assistant 文本 `DONE` + 展开的 turn process / 工具组 / bash 工具卡（cwd + `echo TERMINAL_OK` + 输出 `TERMINAL_OK`）+ composer；所有展开均为真实点击',
    en: 'rich chat from an official recorded fixture seeded through JsonlSessionPersistence: assistant text `DONE` + expanded turn process / tool group / bash tool card (cwd + `echo TERMINAL_OK` + `TERMINAL_OK` output) + composer; every disclosure opened by a real click',
  },
  'session-question-answered': {
    zh: '官方问答卡（fixture 已作答态）：展开 turn process → 提问组 → 提问行后，`提问 · 1/1 已回答` 卡显示问题 `Which color do you prefer?` 与录音答案 `Blue` + 自定义回答 `Include accessibility notes`；**不是**待回答的 composer 提问面板（日志里没有未结算的 ask_user_question）',
    en: 'answered ask_user_question card from an official recorded fixture: after expanding turn process -> questions group -> question row, the `1/1 answered` card shows `Which color do you prefer?` with the recorded `Blue` plus custom `Include accessibility notes` answer; NOT the pending composer question panel (the log has no unsettled ask_user_question)',
  },
  'session-plan-approved': {
    zh: '官方计划卡（fixture 已批准态）：turn tail 中的计划卡 `Add `--greeting` flag to CLI` / `计划 · Markdown` / `打开`（`data-plan-card`），turn process 保持默认折叠；**不是**待审批的 `Plan review`（Approve / Request changes）接管面板',
    en: 'approved exit_plan_mode plan card from an official recorded fixture: the turn-tail plan card `Add `--greeting` flag to CLI` / `Plan · Markdown` / `Open` (`data-plan-card`) with the turn process left collapsed; NOT the pending `Plan review` (Approve / Request changes) takeover',
  },
  'session-subagent-spawn': {
    zh: '官方子智能体态（fixture 经 JsonlSessionPersistence 播种）：会话头把日志里的 `subagent/catalog` 投影成 **`1 个子智能体`** 计数按钮（`button[aria-haspopup="tree"]`，aria-label 同为 `1 个子智能体`）；展开 turn process → `已协调子智能体` 过程组 → `subagent` 工具行后，行卡显示 `创建子智能体` / `调用结果` / prompt 文本 / `● 已启动` / `智能体 ID`（`<sessionId>-child-2`）；另有 `思考` 推理行、`PARENT_DONE`、`子任务状态更新` turn trigger 卡、composer；所有展开均为真实点击',
    en: 'subagent state from an official recorded fixture seeded through JsonlSessionPersistence: the session header projects the logged `subagent/catalog` into a **`1 个子智能体`** count button (`button[aria-haspopup="tree"]`, same aria-label); after expanding the turn process -> `已协调子智能体` process group -> the `subagent` tool row, the card shows `创建子智能体` / `调用结果` / the prompt text / `● 已启动` / `智能体 ID` (`<sessionId>-child-2`), alongside reasoning rows, `PARENT_DONE`, the `子任务状态更新` turn trigger card and the composer; every disclosure opened by a real click',
  },
  'session-subagent-parallel': {
    zh: '官方并行子智能体态（同一 fixture 家族的 `subagent-parallel` 录音）：日志里有两条 `subagent/catalog`，同一会话头因此渲染 **`2 个子智能体`**；同一个 `已协调子智能体` 过程组里有两张 `subagent` 工具行（第一张展开显示 `智能体 ID …-child-2`，第二张保持折叠摘要），另有 `PARENT_DONE` 与 composer。与 `session-subagent-spawn` 只差 catalog 事件，用来证明头部计数是从日志派生的、不是写死的标签',
    en: 'parallel-subagent state from the official `subagent-parallel` recording: two logged `subagent/catalog` events make the same session header render **`2 个子智能体`**; one `已协调子智能体` process group holds two `subagent` tool rows (the first expanded with `智能体 ID …-child-2`, the second left as a collapsed summary), plus `PARENT_DONE` and the composer. It differs from `session-subagent-spawn` only in its catalog events, which is the evidence that the header count is derived from the log rather than a hardcoded label',
  },
}

const LIMITATIONS = [
  '会话截图来自**真实本地 DSH_HOME 的副本**（源目录只读，临时副本在截图后删除）：打开 V3 会话会在原地迁移成 V4，所以服务端从不指向真实 ~/.dsh。',
  '`session-chat-tool` 的 assistant 文本 / 工具卡**不是本机实时模型运行**产生的：它来自官方仓记录 fixture `snapshots/session/bash-tool-turn/session.v4.jsonl`，由 `seed-official-session.mjs` 通过官方格式读取器（`prepareSessionSnapshotFixtureForComparison` + `parseSessionLog`）和官方 `JsonlSessionPersistence.create/append/close` 写入副本；副本里被替换的是一个单轮 `MISSING_CREDENTIAL` 失败会话。',
  '该 fixture 的 `{{tools}}` 工具 schema 侧车没有被记录，官方读取器按 web e2e 的同一口径省略了 `request/header` 的 `tools`；工具行本身来自录音里的 `tool/call` + `tool/result` 事件，不是伪造的 DOM。',
  '本地其余记录会话都是**单轮**且以 `MISSING_CREDENTIAL` 失败结束；turn trigger 的其他形态 / 深色 仍没有官方像素。',
  '`session-subagent-spawn` 与 `session-subagent-parallel` 的子智能体内容**不是**本机实时运行：它们来自官方仓记录 fixture `snapshots/session/subagent-spawn-in-process/session.v4.jsonl` 与 `snapshots/session/subagent-parallel/session.v4.jsonl`，经官方格式读取器与官方 `JsonlSessionPersistence` 播种进临时 DSH_HOME 副本。',
  '两个 subagent fixture 的子会话 id 是**占位符实现**：`realizeSeedFixture` 把 `{{session:2}}` / `{{session:3}}` 展开成 `<sessionId>-child-2` / `-child-3`，而副本里并不存在这些子会话目录。因此截图证明的是**父会话头部计数 + 父转录里的 subagent 工具行**（`已启动` 的已结算状态），**不是**子会话转录；行内 `查看` 按钮对应的子会话在本地存储中不可打开，本轮没有点击它。',
  '头部计数是官方 projection 的产物：`subagent/catalog` 事件经 `subagentCatalog` projection 变成 `button[aria-haspopup="tree"]` 的 `N 个子智能体` 文案；计数断言（`1 个子智能体` / `2 个子智能体`）依赖当前中文界面，若 Web UI 切到英文会变成 `N subagent(s)`。',
  '两个 subagent 截图**没有打开**头部的 catalog 下拉树（`role="tree"` 子智能体会话面板）：截图证明的是计数按钮存在且可见，该下拉面板本身没有对应像素，也未伪造。',
  '子智能体截图里出现的 `已启动` / `智能体 ID` 卡片来自 fixture 的 `tool/result` 文本 `started subagent <childId>`；`turn/end` 为 `completed`，所以是**已结算**的工具行，不是运行中的 pending 行。',
  '`session-question-answered` 与 `session-plan-approved` 是**已结算**状态，不是 pending 接管态：官方 web fixture 的 `ask_user_question` / `exit_plan_mode` 都带 `tool/result`（已作答 / 已批准），因此只能证明已作答问答卡与已批准计划卡。待审批的 `Plan review`（Approve / Request changes）与待回答的 composer 提问面板没有对应的官方录制日志，**未截图，也未伪造**。',
  '`session-plan-approved` 的 turn process 保持默认折叠：`exit_plan_mode` 工具行位于折叠组内，截图证明的是 turn tail 的计划卡本身；`review.expected.md` 描述的待审批接管不在该日志中。',
  '两个 web fixture 里的 `{{timeContextTimestamp}}` / `{{clientTimeZone}}` / `{{elapsed}}` / `{{sourceRoot}}` / `{{webUrl}}` 是官方快照保留的展示占位符（官方 `realizeSeedFixture` 同样不替换），位于被折叠的 context 行，不出现在截图的卡片画面中。',
  'plan fixture 的 v4 header `createdAt` 在迁移时被重置为 0；播种时固定为同一 scenario 官方 v2 fixture 记录的 `1788240594856`，保证重复运行时转录时间戳与 PNG 一致。',
  '仍未登录：`data-signed-out="true"`，composer 显示「请选择模型」；首次使用弹窗必须先被真实关闭，才能进入会话列表。',
  '网页截图不含 iOS 状态栏（09:41/信号/电量）；状态栏属于 iOS 侧叠加层，不是 Web UI 的一部分。',
  '视口为 CSS 402×874、DPR3、light、mobile；截图是 1206×2622 物理像素，没有按 @3x 再乘一次。',
  '截图由无头 Chrome（DevTools Protocol）生成，字体回退到 macOS 系统栈（-apple-system / PingFang），与 iPhone 真机字形可能有细微差异。',
]

/** Project the session-open evidence recorded by cdp-capture.mjs. */
function sessionSummary(report) {
  if (!report.session) return null
  return {
    requestedId: report.session.requestedId,
    openedId: report.session.openedId,
    title: report.session.title,
    documentTitle: report.session.documentTitle,
    drawerClosedOverConversation: report.session.drawerClosed,
    followedTail: report.session.follow ?? null,
    scrolledToSelector: report.session.scrollTo ?? null,
    requiredSelectors: report.session.requiredSelectors ?? [],
    steps: report.session.steps ?? [],
    transcript: report.session.transcript ?? null,
    consoleGate: report.consoleGate ?? null,
    networkGate: report.networkGate ?? null,
  }
}

function parseArgs(argv) {
  const args = { outDir: null, reports: [], repo: null, commit: null, version: null, url: null, port: null, serverCommand: null, serverLog: null, node: null, chrome: null, generatedAt: null, commitVerified: false, sessionSource: null, sessionId: null, sessionLongId: null, sessionToolId: null, toolFixture: null, seedReport: null, questionSessionId: null, questionFixture: null, questionExpected: null, questionPendingExpected: null, questionSeedReport: null, planSessionId: null, planFixture: null, planExpected: null, planPendingExpected: null, planSeedReport: null, subagentSessionId: null, subagentFixture: null, subagentSeedReport: null, subagentParallelSessionId: null, subagentParallelFixture: null, subagentParallelSeedReport: null, sessionCapture: null, sessionUrl: null, sessionPort: null, sessionServerLog: null }
  const assign = {
    '--out-dir': (v) => { args.outDir = v },
    '--report': (v) => { args.reports.push(v) },
    '--repo': (v) => { args.repo = v },
    '--commit': (v) => { args.commit = v },
    '--version': (v) => { args.version = v },
    '--url': (v) => { args.url = v },
    '--port': (v) => { args.port = Number(v) },
    '--server-command': (v) => { args.serverCommand = v },
    '--server-log': (v) => { args.serverLog = v },
    '--node': (v) => { args.node = v },
    '--chrome': (v) => { args.chrome = v },
    '--session-source': (v) => { args.sessionSource = v },
    '--session-id': (v) => { args.sessionId = v },
    '--session-long-id': (v) => { args.sessionLongId = v },
    '--session-tool-id': (v) => { args.sessionToolId = v },
    '--tool-fixture': (v) => { args.toolFixture = v },
    '--seed-report': (v) => { args.seedReport = v },
    '--question-session-id': (v) => { args.questionSessionId = v },
    '--question-fixture': (v) => { args.questionFixture = v },
    '--question-expected': (v) => { args.questionExpected = v },
    '--question-pending-expected': (v) => { args.questionPendingExpected = v },
    '--question-seed-report': (v) => { args.questionSeedReport = v },
    '--plan-session-id': (v) => { args.planSessionId = v },
    '--plan-fixture': (v) => { args.planFixture = v },
    '--plan-expected': (v) => { args.planExpected = v },
    '--plan-pending-expected': (v) => { args.planPendingExpected = v },
    '--plan-seed-report': (v) => { args.planSeedReport = v },
    '--subagent-session-id': (v) => { args.subagentSessionId = v },
    '--subagent-fixture': (v) => { args.subagentFixture = v },
    '--subagent-seed-report': (v) => { args.subagentSeedReport = v },
    '--subagent-parallel-session-id': (v) => { args.subagentParallelSessionId = v },
    '--subagent-parallel-fixture': (v) => { args.subagentParallelFixture = v },
    '--subagent-parallel-seed-report': (v) => { args.subagentParallelSeedReport = v },
    '--session-capture': (v) => { args.sessionCapture = v },
    '--session-url': (v) => { args.sessionUrl = v },
    '--session-port': (v) => { args.sessionPort = Number(v) },
    '--session-server-log': (v) => { args.sessionServerLog = v },
    '--generated-at': (v) => { args.generatedAt = v },
  }
  for (let i = 0; i < argv.length; i += 1) {
    const handler = assign[argv[i]]
    if (!handler) throw new Error(`unknown argument: ${argv[i]}`)
    i += 1
    if (i >= argv.length) throw new Error(`missing value for ${argv[i - 1]}`)
    handler(argv[i])
  }
  if (!args.outDir) throw new Error('--out-dir is required')
  if (args.reports.length === 0) throw new Error('at least one --report is required')
  return args
}

function sha256(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex')
}

/** Read .git/HEAD with plain file reads (the audit forbids running git commands). */
function resolveGitHead(repo) {
  if (!repo) return null
  let gitdir = resolve(repo, '.git')
  if (!existsSync(gitdir)) return null
  try {
    if (!statSync(gitdir).isDirectory()) {
      const match = /^gitdir:\s*(.+)$/m.exec(readFileSync(gitdir, 'utf8'))
      if (!match) return null
      const target = match[1].trim()
      gitdir = isAbsolute(target) ? target : resolve(repo, target)
    }
    const head = readFileSync(resolve(gitdir, 'HEAD'), 'utf8').trim()
    if (!head.startsWith('ref: ')) return head
    const refFile = resolve(gitdir, head.slice('ref: '.length).trim())
    return existsSync(refFile) ? readFileSync(refFile, 'utf8').trim() : null
  } catch {
    return null
  }
}

function toOutRelative(outDir, file) {
  return isAbsolute(file) ? relative(outDir, file) : file
}

function consoleSummary(report) {
  const errors = report.console?.errors ?? []
  const exceptions = report.console?.exceptions ?? []
  const warnings = report.console?.warnings ?? []
  return {
    errorCount: errors.length,
    exceptionCount: exceptions.length,
    warningCount: warnings.length,
    errors: errors.slice(0, 20),
    exceptions: exceptions.slice(0, 20),
    warnings: warnings.slice(0, 20),
  }
}

function networkSummary(report) {
  const failures = report.network?.failures ?? []
  const httpErrors = report.network?.httpErrors ?? []
  return {
    failureCount: failures.length,
    httpErrorCount: httpErrors.length,
    failures: failures.slice(0, 20),
    httpErrors: httpErrors.slice(0, 20),
  }
}

/** Provenance of one seeded official fixture, derived from the seeder report. */
function fixtureSummary(reportPath, { label, tool, expected, pending }) {
  if (reportPath === null || !existsSync(reportPath)) return null
  const seed = JSON.parse(readFileSync(reportPath, 'utf8'))
  const call = (seed.toolCalls ?? []).find((entry) => entry.name === tool) ?? null
  const expectedFile = (file) => {
    if (file === null || file === undefined) return null
    return existsSync(file) ? { file, exists: true, sha256: sha256(file) } : { file, exists: false }
  }
  return {
    id: label,
    seeder: 'scripts/ios-parity/golden/seed-official-session.mjs',
    persistence: 'official @deepseek-ai/dsh-session-persistence-jsonl: new Context + plugin({root}) + create(meta) + append(events) + close()',
    fixture: seed.fixture,
    fixtureSha256: seed.fixtureSha256,
    fixtureRows: seed.fixtureRows,
    fixturePresentationPlaceholdersKeptLiteral: seed.presentationPlaceholdersKeptLiteral ?? [],
    replacedSessionId: seed.sessionId,
    replacedSessionCwd: seed.cwd,
    replacedSessionCwdSource: seed.cwdSource,
    replacedLogsInCopy: seed.replacedFiles,
    createdAtSource: seed.createdAtSource,
    title: seed.title,
    assistantText: seed.assistantText,
    toolCalls: seed.toolCalls ?? [],
    turnEnd: seed.turnEnd ?? null,
    header: seed.meta,
    events: seed.events,
    seededLog: {
      file: 'session.v4.jsonl.zstd',
      sha256: seed.seededLogSha256,
      bytes: seed.seededLogBytes,
      listStatus: seed.listStatus,
    },
    state: {
      rendered: call === null ? 'unknown' : (call.hasResult ? 'settled' : 'pending'),
      settledToolCall: call === null ? null : { name: call.name, hasResult: call.hasResult, resultText: call.resultText },
      expectedStateFile: expectedFile(expected),
      pendingStateFileNotRendered: expectedFile(pending),
    },
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  const outDir = resolve(args.outDir)
  mkdirSync(outDir, { recursive: true })

  const redact = (line) => line.replace(/token=[A-Za-z0-9_\-]+/g, 'token=<redacted>')
  const tailOf = (file) => (file && existsSync(file)
    ? readFileSync(file, 'utf8').trim().split('\n').slice(-30).map(redact)
    : [])
  const serverLogTail = tailOf(args.serverLog)
  const sessionServerLogTail = tailOf(args.sessionServerLog)
  // One entry per seeded fixture. The bash-tool-turn entry stays first so the
  // legacy `seededFixture` field keeps pointing at the original rich chat.
  const seededFixtures = [
    fixtureSummary(args.seedReport, { label: 'bash-tool-turn', tool: 'bash', expected: null, pending: null }),
    fixtureSummary(args.questionSeedReport, {
      label: 'question-composer-answered',
      tool: 'ask_user_question',
      expected: args.questionExpected,
      pending: args.questionPendingExpected,
    }),
    fixtureSummary(args.planSeedReport, {
      label: 'plan-review-approved',
      tool: 'exit_plan_mode',
      expected: args.planExpected,
      pending: args.planPendingExpected,
    }),
    fixtureSummary(args.subagentSeedReport, {
      label: 'subagent-spawn-in-process',
      tool: 'subagent',
      expected: null,
      pending: null,
    }),
    fixtureSummary(args.subagentParallelSeedReport, {
      label: 'subagent-parallel',
      tool: 'subagent',
      expected: null,
      pending: null,
    }),
  ].filter((entry) => entry !== null)
  const seededFixture = seededFixtures.find((entry) => entry.id === 'bash-tool-turn') ?? null

  const screenshots = []
  for (const reportPath of args.reports) {
    const report = JSON.parse(readFileSync(reportPath, 'utf8'))
    const shotPath = resolve(outDir, toOutRelative(outDir, report.screenshot.path))
    const shotRel = relative(outDir, shotPath)
    const state = STATE_BY_LABEL[report.label] ?? { zh: `未登记状态：${report.label}`, en: `unregistered state: ${report.label}` }
    screenshots.push({
      id: report.label,
      file: shotRel,
      state: state.zh,
      stateEn: state.en,
      width: report.screenshot.width,
      height: report.screenshot.height,
      deviceScaleFactor: report.target.viewport.dpr,
      cssViewport: report.target.viewport,
      colorScheme: report.target.colorScheme,
      bytes: statSync(shotPath).size,
      sha256: sha256(shotPath),
      capturedAt: report.createdAt,
      finalUrl: report.target.url,
      runtimeViewport: report.runtime?.viewport ?? null,
      interactions: report.interactions ?? [],
      requiredText: report.requiredText ?? null,
      observedBodyTextHead: (report.boot?.bodyTextHead ?? '').slice(0, 1200),
      console: consoleSummary(report),
      network: networkSummary(report),
      reportFile: relative(outDir, resolve(reportPath)),
      probe: report.probe ?? null,
      session: sessionSummary(report),
    })
  }

  const manifest = {
    schemaVersion: 1,
    kind: 'dsh-official-web-golden',
    generatedAt: args.generatedAt ?? new Date().toISOString(),
    official: {
      repo: args.repo,
      commit: args.commit,
      commitVerifiedByReadingGitHead: Boolean(args.commit && resolveGitHead(args.repo) === args.commit),
      version: args.version,
    },
    environment: {
      node: args.node,
      chrome: args.chrome,
      platform: `${process.platform}-${process.arch}`,
    },
    server: {
      command: args.serverCommand,
      host: '127.0.0.1',
      port: args.port,
      url: args.url,
      profile: 'web',
      dshHome: 'temporary pristine DSH_HOME, removed after capture (never the user profile)',
      logTail: serverLogTail,
      sessionServer: args.sessionUrl === null ? null : {
        url: args.sessionUrl,
        port: args.sessionPort,
        dshHome: 'temporary copy of the source DSH_HOME (source read-only), removed after capture',
        logTail: sessionServerLogTail,
      },
    },
    capture: {
      tool: 'scripts/ios-parity/golden/cdp-capture.mjs',
      protocol: 'Chrome DevTools Protocol (headless=new)',
      viewport: { width: 402, height: 874 },
      deviceScaleFactor: 3,
      expectedPng: { width: 1206, height: 2622 },
      mobileEmulation: true,
      colorScheme: 'light',
      onboardingDismissals: [
        'PWA install banner: button[aria-label="关闭提示"]',
        'preview notice: button with text 继续',
        'get-started dialog: button[aria-label="关闭"] (hero capture only)',
      ],
      sessionOpenPath: [
        'drawer: button[aria-label="菜单"]',
        'workspace group (ungrouped): [data-row-key="workspace:"]',
        'overflow: [data-row-key="overflow:"] (only when the row is past the list cap)',
        'session row: [data-row-key="session:<id>"]',
        'close drawer: button[aria-label="关闭面板"]',
        'open assertion: [data-conversation-session] === <id>',
        'transcript assertion: [data-chat-node-key] rows with a data-chat-flow-kind="user" row',
        'rich session only: [data-chat-node-key] must also contain visible assistant-step and tool-call rows',
        'rich session disclosures: button[data-turn-process] -> [data-chat-group-key] > div > button[aria-expanded] -> div[data-sample="bash"]',
        'question capture: [data-chat-node-key] must contain a visible [data-tool="ask_user_question"]; the expanded card must show the recorded custom answer text; no user-flow row is required beyond the fixture prompt',
        'plan capture: [data-chat-node-key] must contain a visible [data-plan-card] with the plan title; required flow kinds are command + tool-call + turn-tail (this turn opened through /plan, so there is no user row)',
        'subagent capture: the session header must show the logged catalog as a visible button[aria-haspopup="tree"] whose text/aria-label is 1 个子智能体, and [data-chat-node-key] must contain a visible [data-tool="subagent"] row; required flow kinds are user + assistant-step + tool-call',
        'parallel-subagent capture: same assertions with a 2 个子智能体 header count and two [data-tool="subagent"] rows in one process group',
        'new question/plan/subagent captures: --fail-on-console-error makes any console error or uncaught exception fail the capture',
        'two subagent captures: --fail-on-network-error makes any Network.loadingFailed (non-canceled) or HTTP >= 400 response fail the capture',
      ],
    },
    sessionFixture: args.sessionCapture === '0' ? {
      enabled: false,
      reason: 'SKIP_SESSION=1: hero + auth only, no DSH_HOME copy and no chat screenshot',
    } : {
      enabled: true,
      sourceDshHome: args.sessionSource,
      handling: 'copied into a separate temporary DSH_HOME and served by its own dsh web process; the source is only read (opening a V3 session migrates it in place, so no server ever runs against the real home)',
      shortSessionId: args.sessionId,
      longSessionId: args.sessionLongId,
      toolSessionId: args.sessionToolId,
      questionSessionId: args.questionSessionId,
      planSessionId: args.planSessionId,
      subagentSessionId: args.subagentSessionId,
      subagentParallelSessionId: args.subagentParallelSessionId,
      sessionTitles: screenshots.filter((shot) => shot.session).map((shot) => ({ id: shot.session.openedId, title: shot.session.title })),
      seededFixture,
      seededFixtures,
    },
    screenshots,
    consoleErrorsTotal: screenshots.reduce((sum, shot) => sum + shot.console.errorCount, 0),
    limitations: LIMITATIONS,
  }

  // Count the redactions on the body, then add the record of them, then write
  // the redacted text. Counting first keeps the declared numbers describing
  // the capture, not the note that describes the capture.
  const redactions = redactionReport(countRedactions(`${JSON.stringify(manifest, null, 2)}\n`))
  manifest.redactions = redactions
  const jsonText = redactText(`${JSON.stringify(manifest, null, 2)}\n`)
  assertRedacted(jsonText, 'manifest.json')
  writeFileSync(resolve(outDir, 'manifest.json'), jsonText)

  const lines = [
    '# 官方 DSH Web UI 截图清单',
    '',
    `生成时间：\`${manifest.generatedAt}\``,
    '',
    '## 来源',
    '',
    `- 官方仓：\`${manifest.official.repo}\``,
    `- commit：\`${manifest.official.commit}\`${manifest.official.commitVerifiedByReadingGitHead ? '（读取 `.git/HEAD` 校验）' : ''}`,
    `- 版本：\`${manifest.official.version}\``,
    `- 启动命令：\`${manifest.server.command}\``,
    `- 实际地址（hero/auth）：\`${manifest.server.url}\`（token 已脱敏；每次启动由 \`dsh web\` 打印）`,
    ...(manifest.server.sessionServer === null ? [] : [
      `- 实际地址（会话）：\`${manifest.server.sessionServer.url}\`（独立进程 + 独立 DSH_HOME 副本）`,
    ]),
    `- 运行环境：Node \`${manifest.environment.node}\`，\`${manifest.environment.chrome}\``,
    '',
    '## 视口合同',
    '',
    `- CSS 视口 **${manifest.capture.viewport.width}×${manifest.capture.viewport.height}**，DPR **${manifest.capture.deviceScaleFactor}**，light，mobile 模拟`,
    `- 输出 PNG **${manifest.capture.expectedPng.width}×${manifest.capture.expectedPng.height}**（CSS px × DPR）`,
    '',
    '## 截图',
    '',
    '| 文件 | 尺寸 | 状态 | SHA-256 |',
    '|---|---|---|---|',
    ...screenshots.map((shot) => `| \`${shot.file}\` | ${shot.width}×${shot.height} | ${shot.state} | \`${shot.sha256.slice(0, 16)}…\` |`),
    '',
  ]

  if (manifest.sessionFixture?.enabled) {
    lines.push(
      '## 会话 fixture（只读源 → 临时副本）',
      '',
      `- 源：\`${manifest.sessionFixture.sourceDshHome}\`（**只读**；打开 V3 会话会原地迁移，所以服务端不指向真实目录）`,
      `- 短会话：\`${manifest.sessionFixture.shortSessionId}\``,
      `- 长 prompt 会话：\`${manifest.sessionFixture.longSessionId}\``,
      `- 富会话（被 bash fixture 替换）：\`${manifest.sessionFixture.toolSessionId}\``,
      `- 问答卡会话（被 question fixture 替换）：\`${manifest.sessionFixture.questionSessionId}\``,
      `- 计划卡会话（被 plan fixture 替换）：\`${manifest.sessionFixture.planSessionId}\``,
      `- 子智能体会话（被 subagent-spawn-in-process fixture 替换）：\`${manifest.sessionFixture.subagentSessionId}\``,
      `- 并行子智能体会话（被 subagent-parallel fixture 替换）：\`${manifest.sessionFixture.subagentParallelSessionId}\``,
      `- 处理：${manifest.sessionFixture.handling}`,
      '- 会话里的 user 文本来自本地历史记录；截图与 body text 取证都只用于本次 402pt 审计。',
      '',
    )
    for (const seeded of manifest.sessionFixture.seededFixtures) {
      lines.push(
        `### 播种的官方记录 fixture：\`${seeded.id}\``,
        '',
        `- fixture：\`${seeded.fixture}\``,
        `- fixture SHA-256：\`${seeded.fixtureSha256}\`（${seeded.fixtureRows} 行）`,
        `- 播种器：\`${seeded.seeder}\``,
        `- 写入方式：${seeded.persistence}`,
        `- 替换的会话：\`${seeded.replacedSessionId}\`，cwd \`${seeded.replacedSessionCwd}\`（来源：${seeded.replacedSessionCwdSource}）`,
        `- 副本里被删除的旧日志：${seeded.replacedLogsInCopy.map((name) => `\`${name}\``).join('、') || '无'}`,
        `- 写入后的标题：\`${seeded.title}\`；assistant 文本：${seeded.assistantText.map((text) => `\`${text}\``).join('、')}`,
        `- 事件：${seeded.events.stored} 条（seq ${seeded.events.firstSeq}..${seeded.events.lastSeq}），类型：${Object.entries(seeded.events.byType).map(([type, count]) => `\`${type}\`×${count}`).join('、')}`,
        `- 生成的日志：\`${seeded.seededLog.file}\`，SHA-256 \`${seeded.seededLog.sha256}\`（${seeded.seededLog.bytes} bytes，list status \`${seeded.seededLog.listStatus}\`）`,
        `- 会话头：\`${JSON.stringify(seeded.header)}\`（createdAt 来源：${seeded.createdAtSource}）`,
        `- 工具调用：${seeded.toolCalls.map((call) => `\`${call.name}\` result=${String(call.hasResult)}`).join('、') || '无'}；turn end：\`${seeded.turnEnd?.type ?? '?'}\` / \`${seeded.turnEnd?.reason ?? '?'}\``,
      )
      if (seeded.state.expectedStateFile !== null) {
        lines.push(`- 已渲染状态的官方 a11y 契约：\`${seeded.state.expectedStateFile.file}\`${seeded.state.expectedStateFile.exists ? `（SHA-256 \`${seeded.state.expectedStateFile.sha256}\`）` : '（缺失）'}`)
      }
      if (seeded.state.pendingStateFileNotRendered !== null) {
        lines.push(`- **未渲染**的 pending 契约：\`${seeded.state.pendingStateFileNotRendered.file}\`${seeded.state.pendingStateFileNotRendered.exists ? `（SHA-256 \`${seeded.state.pendingStateFileNotRendered.sha256}\`）` : '（缺失）'}；fixture 日志带 \`tool/result\`，没有 pending 请求，故未伪造`)
      }
      if (seeded.fixturePresentationPlaceholdersKeptLiteral.length > 0) {
        lines.push(`- 保留字面量的展示占位符：${seeded.fixturePresentationPlaceholdersKeptLiteral.map((name) => `\`{{${name}}}\``).join('、')}（官方 \`realizeSeedFixture\` 同样不替换；位于折叠的 context 行）`)
      }
      lines.push('')
      lines.push(
        '> 该 fixture 是官方仓自带的记录，经官方格式读取器迁移后用官方 `JsonlSessionPersistence` 写入；' +
        '`{{tools}}` schema 侧车未被记录，按官方 web e2e 的同一口径省略。',
        '',
      )
    }
  }

  for (const shot of screenshots) {
    lines.push(`### \`${shot.file}\``, '')
    lines.push(`- 状态：${shot.state}`)
    lines.push(`- 最终 URL：\`${shot.finalUrl}\``)
    lines.push(`- 运行时视口：\`${shot.runtimeViewport?.innerWidth}×${shot.runtimeViewport?.innerHeight}@${shot.runtimeViewport?.dpr}\``)
    lines.push(`- 交互：${shot.interactions.length ? shot.interactions.map((i) => `**${i.kind ?? 'explicit'}** → ${i.clicked ? `\`${i.clicked.text || i.clicked.tag}\`` : '未命中'}`).join('；') : '无'}`)
    if (shot.requiredText) lines.push(`- 断言文本：\`${shot.requiredText.text}\` → ${shot.requiredText.found ? '命中' : '未命中'}`)
    if (shot.session) {
      lines.push(`- 会话：\`${shot.session.openedId}\`，标题 \`${shot.session.title}\``)
      lines.push(`- 打开路径：${shot.session.steps.map((step) => `**${step.kind}** → \`${step.selector}\`${step.ok ? '' : '（未命中）'}`).join('；')}`)
      lines.push(`- 抽屉已关闭：${shot.session.drawerClosedOverConversation ? '是' : '否'}；跟随 turn tail：${shot.session.followedTail ? '是' : '否'}${shot.session.scrolledToSelector ? `；滚动定位：\`${shot.session.scrolledToSelector.selector}\`（scrollTop ${shot.session.scrolledToSelector.scrollTop}）` : ''}`)
      lines.push(`- 转录断言：${shot.session.transcript?.rows} 行（flow kinds：${(shot.session.transcript?.flowKinds ?? []).join(' / ')}；可见：${(shot.session.transcript?.visibleFlowKinds ?? []).join(' / ')}；turns：${(shot.session.transcript?.turns ?? []).join(', ')}）`)
      if (shot.session.requiredSelectors.length > 0) {
        lines.push(`- 内容断言：${shot.session.requiredSelectors.map((entry) => `\`${entry.selector}\` ${entry.visibleCount}/${entry.count} 可见 → ${JSON.stringify((entry.text ?? '').slice(0, 160))}`).join('；')}`)
      }
    }
    lines.push(`- Console error：${shot.console.errorCount}，未捕获异常：${shot.console.exceptionCount}，warning：${shot.console.warningCount}${shot.session?.consoleGate?.enabled ? '（console gate 已启用并通过）' : ''}；网络失败：${shot.network.failureCount}，HTTP error：${shot.network.httpErrorCount}${shot.session?.networkGate?.enabled ? '（network gate 已启用并通过）' : ''}`)
    lines.push(`- 报告：\`${shot.reportFile}\``)
    lines.push('')
  }

  lines.push('## 已知限制', '')
  for (const item of LIMITATIONS) lines.push(`- ${item}`)
  lines.push('')
  lines.push('## 发布脱敏', '')
  lines.push(
    '生成器在写盘前对**整份产物**做一次文本替换（规则，不是字段清单），所以之后新增的字段也不会漏：',
    '',
  )
  if (manifest.redactions.length === 0) {
    lines.push('- 本次没有命中任何脱敏目标。')
  } else {
    for (const entry of manifest.redactions) {
      lines.push(`- \`${entry.kind}\`：${entry.replacements} 处 → \`${entry.with}\`。${entry.reason}`)
    }
  }
  lines.push('')
  lines.push('原始捕获值不在任何发布的产物里（`reports/*.json` 同样脱敏）；要复核只能重跑捕获。')
  lines.push('')
  lines.push('## 复现', '')
  lines.push('```bash')
  lines.push('scripts/ios-parity/golden/capture-official.sh')
  lines.push('# hero + auth + 七个会话状态（需本机 ~/.dsh 里有对应 session；其中五个会话由官方 fixture 播种）')
  lines.push('SKIP_SESSION=1 scripts/ios-parity/golden/capture-official.sh   # 只做 hero + auth')
  lines.push('# 可选环境变量：DSH_OFFICIAL_REPO / CHROME_BIN / NODE_BIN / DSH_GOLDEN_OUT_DIR')
  lines.push('#             DSH_GOLDEN_SESSION_HOME / DSH_GOLDEN_SESSION_ID / DSH_GOLDEN_SESSION_LONG_ID')
  lines.push('#             DSH_GOLDEN_TOOL_SESSION_ID / DSH_GOLDEN_TOOL_FIXTURE / KEEP_WORK_DIR=1')
  lines.push('#             DSH_GOLDEN_QUESTION_SESSION_ID / DSH_GOLDEN_QUESTION_FIXTURE / DSH_GOLDEN_QUESTION_EXPECTED')
  lines.push('#             DSH_GOLDEN_PLAN_SESSION_ID / DSH_GOLDEN_PLAN_FIXTURE / DSH_GOLDEN_PLAN_CREATED_AT / DSH_GOLDEN_PLAN_EXPECTED')
  lines.push('#             DSH_GOLDEN_SUBAGENT_SESSION_ID / DSH_GOLDEN_SUBAGENT_FIXTURE')
  lines.push('#             DSH_GOLDEN_SUBAGENT_PARALLEL_SESSION_ID / DSH_GOLDEN_SUBAGENT_PARALLEL_FIXTURE')
  lines.push('```')
  lines.push('')

  const mdText = redactText(`${lines.join('\n')}\n`)
  assertRedacted(mdText, 'manifest.md')
  writeFileSync(resolve(outDir, 'manifest.md'), mdText)
  console.log(`[write-manifest] wrote ${resolve(outDir, 'manifest.json')} and manifest.md (${screenshots.length} screenshots)`)
}

try {
  main()
} catch (error) {
  console.error(`[write-manifest] FAILED: ${error.message}`)
  process.exit(1)
}
