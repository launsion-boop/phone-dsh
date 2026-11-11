// SPDX-License-Identifier: MIT
// Export language-neutral Bot conformance vectors from the read-only dsh-bot implementation.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const args = process.argv.slice(2);
function option(name, fallback = null) {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}
const checkout = path.resolve(required('--checkout'));
const expectedSHA = required('--sha');
const output = path.resolve(required('--out'));
function required(name) {
  const value = option(name);
  if (!value) throw new Error(`${name} is required`);
  return value;
}
const actualSHA = execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
if (actualSHA !== expectedSHA) throw new Error(`dsh-bot SHA mismatch: expected ${expectedSHA}, got ${actualSHA}`);
const source = { checkout: actualSHA };
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'phonedsh-bot-vectors-'));
const requireCJS = (relative) => require(path.join(checkout, relative));
const toolEffects = requireCJS('src/main/authz/toolEffects.cjs');
const approvalPatterns = requireCJS('src/main/approvalPatterns.cjs');
const envelope = requireCJS('src/main/events/envelope.cjs');

function loadExports(relative, names) {
  const filename = path.join(checkout, relative);
  const code = `${fs.readFileSync(filename, 'utf8')}\nglobalThis.__vectorExports = { ${names.join(',')} };`;
  const context = { require: (id) => id.startsWith('node:') ? require(id) : require(path.resolve(path.dirname(filename), id)),
    module: { exports: {} }, exports: {}, __filename: filename, __dirname: path.dirname(filename),
    process, console, Buffer, URL, URLSearchParams, setTimeout, clearTimeout, setInterval, clearInterval };
  context.globalThis = context;
  vm.runInNewContext(code, context, { filename });
  return context.__vectorExports;
}
const { RAW_TOOLS } = loadExports('src/main/mcp/dshbotServer.cjs', ['RAW_TOOLS']);
const { parseAttachmentBlock } = loadExports('src/main/dshTranscript.cjs', ['parseAttachmentBlock']);
const attachments = requireCJS('src/main/attachments.cjs');
const { CONTEXT_PROFILES, contextConfigYaml } = loadExports('src/main/prompt/assemble.cjs', ['CONTEXT_PROFILES', 'contextConfigYaml']);
const display = await import(pathToFileURL(path.join(checkout, 'src/renderer/lib/displayContract.js')).href);
const fishModel = await import(pathToFileURL(path.join(checkout, 'src/renderer/lib/fish/model.js')).href);
const agentModel = requireCJS('src/main/agents/model.cjs');
const { AgentRecords } = requireCJS('src/main/agents/store.cjs');
const { wireRecordFor } = requireCJS('src/main/transcriptWire.cjs');
const cardPayloads = requireCJS('src/main/cardPayloads.cjs');
const ledgerModule = requireCJS('src/main/ledger.cjs');
const purposes = requireCJS('src/main/llm/purposes.cjs');
const watchdog = requireCJS('src/main/watchdog/checks.cjs');
const watchdogConfig = requireCJS('src/main/watchdog/config.cjs');
const contextLint = requireCJS('src/main/eval/contextLint.cjs');

const exportedGolden = new Set();
function writeJSON(relative, value) {
  const filename = path.join(output, relative);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, `${JSON.stringify(value, null, 2)}\n`);
  if (relative.startsWith('golden/')) exportedGolden.add(path.basename(relative));
}
function vector(name, valid, invalid = []) {
  writeJSON(`golden/${name}.json`, { schemaVersion: 1, vector: name, source, valid, invalid });
}

// P27 user-message attachments. The upstream parser and prompt builder are the
// only authority; the vector records their real output so Swift can byte-match
// the block without copying a second prompt string. Like every other upstream
// batch, re-running this script must leave the file unchanged.
const attachmentItems = [
  {
    name: '周报.pdf',
    path: '/data/agents/main/attachments/m1/周报.pdf',
    size: 2048,
    mimeType: 'application/pdf',
    kind: attachments.kindFor('周报.pdf', 'application/pdf'),
  },
  {
    name: 'photo.jpg',
    path: '/data/agents/main/attachments/m1/photo.jpg',
    size: 1234567,
    mimeType: 'image/jpeg',
    kind: attachments.kindFor('photo.jpg', 'image/jpeg'),
  },
];
const attachmentText = '帮我看看这两个文件';
const attachmentBlock = attachments.attachmentPromptBlock(attachmentItems);
const attachmentPrompt = attachmentText + attachmentBlock;
const attachmentParseInputs = [
  attachmentPrompt,
  'no attachments here',
  attachmentBlock.replace(/^\n\n/, ''),
  `前缀\n\n${attachmentBlock.replace(/^\n\n/, '')}\n后缀`,
];
writeJSON('golden/bot-attachments.json', {
  source: {
    repo: 'launsion-boop/dsh-bot',
    commit: actualSHA,
    files: ['src/main/attachments.cjs', 'src/main/dshTranscript.cjs'],
  },
  limits: {
    maxAttachments: attachments.MAX_ATTACHMENTS,
    maxBytes: attachments.MAX_ATTACHMENT_BYTES,
  },
  promptBlock: { items: attachmentItems, text: attachmentText, prompt: attachmentPrompt },
  emptyBlock: attachments.attachmentPromptBlock([]),
  parse: attachmentParseInputs.map((input) => ({ input, output: parseAttachmentBlock(input) })),
  kindFor: [
    ['a.png', 'image/png'],
    ['b.HEIC', ''],
    ['c.mp3', ''],
    ['d.mov', ''],
    ['e.pdf', ''],
    ['f.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
    ['g.txt', 'text/plain'],
    ['h', ''],
  ].map(([name, mimeType]) => ({ name, mimeType, kind: attachments.kindFor(name, mimeType) })),
});
const P0_TOOL_NAMES = [
  'ask_user', 'show_next_steps', 'show_attachment', 'show_document', 'show_progress',
  'show_checklist', 'show_link', 'UpdateMemory', 'RecallMemory', 'Task', 'AwaitTask',
  'StopSubagent', 'UpdateRoutine', 'ListRoutines', 'RequestApproval', 'SendToUser',
];
const P1_TOOL_NAMES = ['show_table', 'show_callout', 'show_info', 'show_payload', 'show_library'];
const TOOL_NAMES = [...P0_TOOL_NAMES, ...P1_TOOL_NAMES];
const availableTools = new Map([...RAW_TOOLS, ...cardPayloads.mcpCardTools()].map((tool) => [tool.name, tool]));
for (const name of TOOL_NAMES) {
  if (!availableTools.has(name)) throw new Error(`Pinned tool is missing: ${name}`);
}
const toolsFor = (names) => names.map((name) => availableTools.get(name));
vector('tool-catalog', { p0: toolsFor(P0_TOOL_NAMES), p1: toolsFor(P1_TOOL_NAMES) },
  [{ name: 'GenerateImage', reason: 'excluded_platform_capability' },
    { name: 'MacWriteNotes', reason: 'excluded_platform_capability' },
    { name: 'CreateTeam', reason: 'excluded_scope' },
    { name: 'show_canvas', reason: 'excluded_scope' },
    { name: 'show_product', reason: 'excluded_scope' },
    { name: 'show_gift', reason: 'excluded_scope' }]);

vector('volatile-context', {
  request: { sessionId: 'gb-main' },
  response: {
    schemaVersion: 1,
    sessionId: 'gb-main',
    revision: 3,
    blocks: {
      variant: '简洁直接',
      persona: '你叫大肥鱼',
      memory: '## 记忆\n\n- 我喜欢简短回答',
      automation: '<automation_status>没有待处理例行任务</automation_status>',
    },
  },
}, [
  { request: { sessionId: '' }, reason: 'empty_session_id' },
  { request: { sessionId: 'gb-other' }, reason: 'cross_session_read_denied' },
  { error: { isError: true, message: 'context unavailable' }, reason: 'no_partial_or_stale_snapshot' },
]);

// This exporter is the read-only dsh-bot batch and must stay byte-identical on
// a fresh export. phoneDSH-only card inputs (the optional content-card `final`
// control flag and the option-id/recommended normalization) are deliberately
// not written here: they live in `spec/bot/v1/golden/card-payload.phone.json`
// and `tool-catalog.phone.json`, which the exporter never touches.
const cardInputs = [
  { tool: 'ask_user', args: { question: '继续吗？', options: [{ label: '继续', recommended: true }, { label: '停止' }] },
    card: { cardType: 'question', question: '继续吗？', options: [{ label: '继续', recommended: true }, { label: '停止' }] } },
  { tool: 'show_next_steps', args: { steps: [{ label: '查看结果', recommended: true }, '稍后再说'] },
    card: { cardType: 'steps', steps: [{ label: '查看结果', recommended: true }, { label: '稍后再说' }] } },
  { tool: 'show_attachment', args: { path: '/tmp/report.txt', caption: '报告' },
    card: { cardType: 'attachment', path: '/tmp/report.txt', caption: '报告' } },
  { tool: 'show_document', args: { title: '状态报告', content: '# 状态\n正常', summary: '当前状态' } },
  { tool: 'show_progress', args: { title: '生成报告', cardKey: 'report-1', state: 'running', steps: [{ label: '收集', state: 'done' }, { label: '撰写', state: 'active' }] } },
  { tool: 'show_checklist', args: { title: '发布检查', items: [{ text: '运行测试', done: true }, { text: '创建 PR' }] } },
  { tool: 'show_link', args: { links: [{ url: 'https://example.test/docs', title: '文档', site: 'example.test', kind: 'doc' }] } },
  { tool: 'show_table', args: { columns: [{ key: 'name', label: '名称' }, { key: 'count', label: '数量', type: 'number' }], rows: [{ name: 'A', count: 2 }] } },
  { tool: 'show_callout', args: { tone: 'warning', title: '注意', body: '仍有未验证项目。' } },
  { tool: 'show_info', args: { label: '状态', value: '进行中' } },
  { tool: 'show_payload', args: { files: [{ name: 'report.txt', size: 128 }] } },
  { tool: 'show_library', args: { botName: '大肥鱼', docCount: 2, docCountKnown: true } },
];
vector('card-payload', cardInputs.map((entry) => ({
  tool: entry.tool,
  args: entry.args,
  result: entry.card ? { ok: true, card: cardPayloads.normalizeCardPayload(entry.card) } : cardPayloads.buildCard(entry.tool, entry.args),
})), [
  { tool: 'show_progress', args: {}, result: cardPayloads.buildCard('show_progress', {}) },
  { tool: 'show_link', args: { links: [{ url: 'file:///etc/passwd' }] }, result: cardPayloads.buildCard('show_link', { links: [{ url: 'file:///etc/passwd' }] }) },
]);

const ledger = new ledgerModule.LlmLedger({ dataRoot: temporaryRoot, now: () => 1760000000000 });
ledger.record({
  ts: 1760000000000, botId: 'main', sessionId: 'gb-main', purpose: 'front-turn',
  model: 'deepseek-flash', provider: 'deepseek', inputTokens: 100, outputTokens: 20,
  cacheReadTokens: 40, cacheWriteTokens: 10, ttftMs: 125.4, durationMs: 900.2, status: 'ok',
});
await ledger.flush();
const ledgerFile = fs.readdirSync(path.join(temporaryRoot, 'ledger')).find((name) => /^llm-.*\.jsonl$/.test(name));
const ledgerRecord = JSON.parse(fs.readFileSync(path.join(temporaryRoot, 'ledger', ledgerFile), 'utf8').trim());
vector('llm-ledger', ledgerRecord, [{ field: 'cacheHitRatio', rule: 'cacheRead/(input+cacheRead+cacheWrite)' },
  { field: 'ttftMs', rule: 'omit_when_unavailable' }]);

const purposeRows = purposes.PURPOSES.map((purpose) => ({
  purpose,
  largeModelAllowed: purposes.allowsLargeModel(purpose),
  defaults: purposes.defaultsFor(purpose),
}));
let deniedPurpose;
try { purposes.assertModelAllowed('triage', 'deepseek-v4-pro'); } catch (error) {
  deniedPurpose = { purpose: error.purpose, model: error.model, code: error.code };
}
vector('model-purpose-policy', { purposes: purposeRows, largeModelPurposes: purposes.LARGE_MODEL_PURPOSES },
  deniedPurpose ? [deniedPurpose] : []);

const flagged = watchdog.runChecks({
  startedAt: 1, lastEventAt: 1, deadlineAt: 1,
  repeatedToolSignatureCount: 5, lastToolSignature: 'tool:digest',
  repeatedToolErrorCount: 3, lastToolErrorSignature: 'tool:error',
  tokens: 200001, costUsd: 0,
}, 1760000000000, watchdogConfig.DEFAULT_CONFIG);
vector('watchdog', {
  config: watchdogConfig.DEFAULT_CONFIG,
  flagged,
  mobile: [
    { check: 'webcontent_terminated', eventType: 'watchdog.flagged', observeOnly: true, oncePerUnit: true },
    { check: 'thermal_pressure', eventType: 'watchdog.flagged', observeOnly: true, oncePerUnit: true },
    { check: 'battery_pressure', eventType: 'watchdog.flagged', observeOnly: true, oncePerUnit: true },
  ],
}, [{ check: 'stop', reason: 'watchdog_is_observe_only' }]);

vector('context-profiles', {
  profiles: CONTEXT_PROFILES,
  yaml: { default: contextConfigYaml('default'), conservative: contextConfigYaml('conservative') },
}, [{ profile: 'unknown', resolution: 'default' }]);

vector('context-lint', contextLint.lintSession({
  tools: [{ name: 'example', description: 'example tool', inputSchema: { type: 'object' } }],
  thresholds: { toolCountWarn: 1, toolDefTokensWarn: 1, toolDefTokensError: 10000 },
  sessionId: 'gb-main',
}), []);

const validEvent = envelope.createEnvelope({
  type: 'routine.run_started', eventId: 'evt:routine-1', time: 1760000000000,
  origin: { kind: 'local', source: 'scheduler' }, traceId: 'trace-routine-1',
  principal: { botId: 'main', sessionId: 'gb-main--routine-daily', kind: 'routine', capabilities: [] },
  causationId: null, correlationId: 'daily', runId: 'run-1', attempt: 1,
  data: { routineId: 'daily', runId: 'run-1', attempt: 1, scheduledFor: 1760000000000, startedAt: 1760000000000 },
});
validEvent.commitSeq = 1;
vector('event-envelope',
  { event: validEvent, validation: envelope.validateEnvelope(validEvent) },
  [
    { event: { ...validEvent, commitSeq: undefined }, validation: envelope.validateEnvelope({ ...validEvent, commitSeq: undefined }) },
    { event: { ...validEvent, type: 'future.required' }, validation: envelope.validateEnvelope({ ...validEvent, type: 'future.required' }) },
    { event: { ...validEvent, schemaVersion: 2 }, validation: envelope.validateEnvelope({ ...validEvent, schemaVersion: 2 }) },
    { event: { ...validEvent, type: 'model.delta', commitSeq: 1 }, validation: envelope.validateEnvelope({ ...validEvent, type: 'model.delta', commitSeq: 1 }) },
  ]);

const effectCalls = TOOL_NAMES.map((name) => ({
  name,
  args: name === 'UpdateMemory'
    ? { action: 'write', fact: '我喜欢简短回答', tier: 'log', scope: 'agent' }
    : name === 'RecallMemory' ? { query: '简短', limit: 5 }
    : name === 'Task' ? { description: '检查状态', prompt: '只返回当前状态', async: true }
    : name === 'AwaitTask' || name === 'StopSubagent' ? { task_id: 'task-1' }
    : name === 'UpdateRoutine' ? { action: 'create', title: '晨间简报', prompt: '没有新结果就安静', schedule: '@daily' }
    : name === 'SendToUser' ? { message: '已完成' }
    : name === 'RequestApproval' ? { action: '删除旧文件', detail: '删除一个过期报告' }
    : name === 'show_next_steps' ? { steps: [{ label: '查看结果', recommended: true }, '稍后再说'] }
    : name === 'show_document' ? { title: '状态报告', content: '# 状态\n正常' }
    : name === 'show_attachment' ? { path: '/tmp/report.txt', caption: '报告' }
    : name === 'ask_user' ? { question: '要继续吗？', options: [{ label: '继续', recommended: true }, { label: '停止' }] }
    : {},
})).map((call) => ({
  ...call,
  policy: toolEffects.policyFor(call.name, call.args),
  effect: toolEffects.effectForTool(call.name, call.args, { lang: 'zh' }),
}));
vector('tool-effects', effectCalls, [
  { name: 'UnknownWrite', args: { secret: 'not-recorded' }, policy: toolEffects.policyFor('UnknownWrite', {}),
    effect: toolEffects.effectForTool('UnknownWrite', { secret: 'not-recorded' }) },
  { name: 'UpdateMemory', args: { action: 'forget', scope: 'user', fact: '共享事实' },
    policy: toolEffects.policyFor('UpdateMemory', { action: 'forget', scope: 'user', fact: '共享事实' }),
    effect: toolEffects.effectForTool('UpdateMemory', { action: 'forget', scope: 'user', fact: '共享事实' }) },
]);

const approvalCalls = [
  { tool: 'bash', args: { command: 'rm -rf build' } },
  { tool: 'bash', args: { command: 'git reset --hard HEAD' } },
  { tool: 'bash', args: { command: 'curl -X POST https://example.test/api' } },
  { tool: 'bash', args: { command: 'find . -name "*.tmp" -delete' } },
  { tool: 'bash', args: { command: 'echo ready' } },
].map((call) => ({ ...call, matches: approvalPatterns.analyzeToolCalls({ ...call, workspace: '/tmp/phonedsh-bot-work', lang: 'en' }) }));
vector('approval-patterns', approvalCalls, [
  { tool: 'bash', args: { command: 'python3 -c "import urllib.request; urllib.request.urlopen(\'https://example.test\')"' },
    matches: approvalPatterns.analyzeToolCalls({ tool: 'bash', args: { command: 'python3 -c "import urllib.request; urllib.request.urlopen(\'https://example.test\')"' }, workspace: '/tmp/phonedsh-bot-work', lang: 'en' }) },
]);

const director = await import(pathToFileURL(path.join(checkout, 'src/renderer/lib/fish/director.js')).href);
let fishState = director.createDirectorState({ lifecycle: 'idle', now: 0 });
const fishSteps = [];
function fishStep(action, event) {
  const result = action === 'reduce' ? director.reduce(fishState, event)
    : action === 'expire' ? director.expireOneShot(fishState, event.time)
      : director.setLifecycle(fishState, event.lifecycle, event.time);
  fishState = result.directorState;
  fishSteps.push({ action, event, expected: { directorState: fishState, command: result.command } });
}
fishStep('reduce', { type: 'turn.started', time: 100, data: { turn: 1, sessionId: 'gb-main' } });
fishStep('reduce', { type: 'conversation.user_message', time: 200, data: { text: '继续' } });
fishStep('reduce', { type: 'model.delta', time: 300, data: { channel: 'reasoning' } });
fishStep('reduce', { type: 'conversation.tool_call', time: 400, data: { name: 'read' } });
fishStep('reduce', { type: 'approval.requested', time: 500, data: { requestId: 'approval-1' } });
fishStep('reduce', { type: 'model.delta', time: 600, data: { channel: 'text' } });
fishStep('reduce', { type: 'approval.decided', time: 700, data: { resolution: 'once' } });
fishStep('reduce', { type: 'task.settled', time: 800, data: { status: 'completed' } });
fishStep('reduce', { type: 'memory.written', time: 900, data: { scope: 'agent' } });
fishStep('reduce', { type: 'task.settled', time: 1000, data: { status: 'failed' } });
fishStep('reduce', { type: 'task.settled', time: 1100, data: { status: 'completed' } });
fishStep('reduce', { type: 'turn.ended', time: 3600, data: { status: 'completed' } });
fishStep('reduce', { type: 'watchdog.flagged', time: 3700, data: { check: 'heartbeat' } });
fishStep('reduce', { type: 'approval.decided', time: 3800, data: { resolution: 'deny' } });
fishStep('expire', { time: 8000 });
fishStep('lifecycle', { time: 8100, lifecycle: 'working' });
fishStep('lifecycle', { time: 8200, lifecycle: 'idle' });
vector('fish-director', { initial: { lifecycle: 'idle', now: 0 }, steps: fishSteps }, [
  { event: { type: 'unknown.event', time: 1, data: {} }, expected: 'ignored_without_state_change' },
]);

// Bot profile: desktop record schema, colour/hairstyle order, normalizer and
// the FNV-1a seed. The Swift `BotProfile` implementation reads this same file;
// do not hand-edit the exported JSON.
for (const name of ['normalizeFishColor', 'normalizeFishHairstyle']) {
  if (typeof agentModel[name] !== 'function') {
    throw new Error(`dsh-bot agents/model.cjs must export ${name}`);
  }
}
if (!Array.isArray(fishModel.COLORS) || fishModel.COLORS.length !== 15) {
  throw new Error('dsh-bot fish/model.js must export the 15 COLORS');
}
if (!Array.isArray(fishModel.HAIRSTYLES) || fishModel.HAIRSTYLES.length !== 4) {
  throw new Error('dsh-bot fish/model.js must export the 4 HAIRSTYLES');
}
if (typeof fishModel.appearanceFromSeed !== 'function') {
  throw new Error('dsh-bot fish/model.js must export appearanceFromSeed');
}
const declaredRecordSchemaVersion = agentModel.RECORD_SCHEMA_VERSION
  ?? agentModel.AGENT_SCHEMA_VERSION ?? agentModel.SCHEMA_VERSION ?? agentModel.recordSchemaVersion;
const recordSchemaVersion = 3;
if (declaredRecordSchemaVersion !== undefined && Number(declaredRecordSchemaVersion) !== recordSchemaVersion) {
  throw new Error(`unexpected dsh-bot record schema: ${declaredRecordSchemaVersion}`);
}
const botColors = fishModel.COLORS.map((color) => ({ id: color.id, hex: color.hex }));
const botHairstyles = fishModel.HAIRSTYLES.map((style) => style.id);
const colorByHex = new Map(botColors.map((color) => [color.hex.toUpperCase(), color.id]));
const botProfileSeedInputs = [
  'main', 'agent-123', 'agent-0123456789abcdef', 'Bot', 'fish',
  '大肥鱼', 'DS 大肥魚', '🐟bot', 'a', 'agent-ffffffffffffffff',
];
const botProfileSeeds = botProfileSeedInputs.map((seed) => {
  const appearance = fishModel.appearanceFromSeed(seed);
  const colorId = colorByHex.get(String(appearance.color).toUpperCase())
    ?? botColors.map((color) => color.id).find((id) => id === appearance.color);
  const color = botColors.find((entry) => entry.id === colorId);
  if (!color) throw new Error(`seed ${JSON.stringify(seed)} returned an unknown colour: ${appearance.color}`);
  return { seed, color: color.id, hex: color.hex, hairstyle: appearance.hairstyle };
});
const normalizeBotColor = (value) => {
  const result = agentModel.normalizeFishColor(value);
  return result === undefined || result === '' ? null : result;
};
const normalizeBotHairstyle = (value) => {
  const result = agentModel.normalizeFishHairstyle(value);
  return result === undefined || result === '' ? null : result;
};

// Roster rules exported from the real AgentRecords. The fixture root lives in
// the system temporary directory; only ids and rule outcomes reach the golden.
function rosterFixture(ids, mainAgentId) {
  const root = fs.mkdtempSync(path.join(temporaryRoot, 'roster-'));
  const agents = ids.map((id, index) => ({
    schema: 3,
    id,
    name: `Bot ${id}`,
    description: '',
    fish_color: 'blue',
    fish_hairstyle: 'long',
    name_explicit: true,
    pinned: false,
    hidden_by_user: false,
    unread_count: 0,
    last_message_at: null,
    created_at: 1760000000000 + index,
    updated_at: 1760000000000 + index,
  }));
  fs.writeFileSync(path.join(root, 'agents-index.json'),
    `${JSON.stringify({ schemaVersion: 3, agents })}\n`);
  fs.writeFileSync(path.join(root, 'runtime-settings.json'),
    `${JSON.stringify({ version: 1, mainAgentId, updatedAt: 1760000000000 })}\n`);
  return new AgentRecords({ root });
}
const rosterMainPointerInputs = [
  { name: 'empty_pointer_uses_first_bot', records: ['agent-a', 'agent-b'], mainAgentId: null },
  { name: 'dangling_pointer_uses_first_bot', records: ['agent-a', 'agent-b'], mainAgentId: 'agent-gone' },
  { name: 'valid_pointer_is_kept', records: ['agent-a', 'agent-b'], mainAgentId: 'agent-b' },
  { name: 'empty_roster_has_no_main', records: [], mainAgentId: null },
];
const mainPointerRepair = rosterMainPointerInputs.map((entry) => ({
  ...entry,
  expectedMainAgentId: rosterFixture(entry.records, entry.mainAgentId).mainAgentId(),
}));
const rosterDeleteInputs = [
  { name: 'deleting_main_moves_pointer_to_first_remaining', records: ['agent-a', 'agent-b', 'agent-c'], mainAgentId: 'agent-b', deleteId: 'agent-b' },
  { name: 'deleting_non_main_keeps_pointer', records: ['agent-a', 'agent-b', 'agent-c'], mainAgentId: 'agent-c', deleteId: 'agent-b' },
  { name: 'deleting_last_main_uses_first_remaining', records: ['agent-a', 'agent-b'], mainAgentId: 'agent-b', deleteId: 'agent-b' },
];
const deleteMainMigration = rosterDeleteInputs.map((entry) => {
  const store = rosterFixture(entry.records, entry.mainAgentId);
  store.deleteAgent(entry.deleteId);
  return {
    ...entry,
    expectedRemaining: store.listRecords().map((record) => record.id),
    expectedMainAgentId: store.mainAgentId(),
  };
});
const rosterPatchInputs = [
  {
    name: 'identity_and_pointer_are_dropped',
    input: {
      id: 'agent-injected', primary: true, mainAgentId: 'agent-injected',
      name: '  换名  ', description: '新的描述', fish_color: 'BLUE', hidden_by_user: true,
    },
  },
  {
    name: 'pointer_only_patch_is_empty',
    input: { id: 'agent-injected', primary: false, mainAgentId: 'agent-injected' },
  },
];
const normalizePatch = rosterPatchInputs.map((entry) => ({
  name: entry.name,
  input: entry.input,
  expected: agentModel.normalizePatch(entry.input),
  droppedKeys: ['id', 'primary', 'mainAgentId'],
}));

writeJSON('golden/bot-profile.json', {
  source: {
    repo: 'launsion-boop/dsh-bot',
    commit: actualSHA,
    files: [
      'src/main/agents/model.cjs',
      'src/renderer/lib/fish/model.js',
      'src/renderer/lib/characterEngine.js',
      'src/main/agents/store.cjs',
    ],
  },
  recordSchemaVersion,
  colors: botColors,
  colorOrderMain: botColors.map((color) => color.id),
  hairstyles: botHairstyles,
  normalizeFishColor: [
    'blue', 'BLUE', 'Blue', ' blue', 'auto', '', null, 'violet', 'grey', 'purple', 'teal', 'sky', 'unknown',
  ].map((input) => ({ input, output: normalizeBotColor(input) })),
  normalizeFishHairstyle: [
    'long', 'LONG', 'twin-tail', 'Twin-Tail', 'bob', 'side-braid', 'side_braid',
    'auto', '', null, 'curly',
  ].map((input) => ({ input, output: normalizeBotHairstyle(input) })),
  seed: botProfileSeeds,
  rosterRules: {
    mainPointerRepair,
    deleteMainMigration,
    normalizePatch,
  },
});

const rowInputs = [
  { kind: 'message', role: 'user', text: '你好' },
  ...cardInputs.map((entry) => ({ kind: 'card', ...(entry.card || cardPayloads.buildCard(entry.tool, entry.args).card) })),
  { kind: 'card', cardType: 'task', title: '后台任务', task: { status: 'running' } },
  { kind: 'approval', status: 'pending', action: '删除旧文件' },
  { kind: 'routine-run', title: '晨间简报' },
  { kind: 'tool-call', name: 'bash' },
  { kind: 'system-event', event: 'other', text: 'free text' },
  { kind: 'notice', tone: 'info', text: '信息' },
  { kind: 'notice', tone: 'error', text: '失败' },
];
vector('row-projection', rowInputs.map((entry) => ({
  input: entry,
  surface: display.surfaceFor(entry),
  renderable: display.isRenderable(entry),
  wire: wireRecordFor(entry),
})), [
  { input: { kind: 'card', cardType: 'unknown' }, surface: display.surfaceFor({ kind: 'card', cardType: 'unknown' }),
    renderable: display.isRenderable({ kind: 'card', cardType: 'unknown' }) },
]);

vector('row-protocol', {
  row: {
    id: 'e-main-1', botID: 'main', seq: 1, updatedSeq: 2, kind: 'message', role: 'assistant',
    body: { type: 'text', text: '已完成' },
    provenance: { eventIDs: ['evt-1'], trust: 'owner_direct', tainted: false },
    streaming: false, createdAt: 1760000000000,
  },
  widgetRow: {
    id: 'e-main-2', botID: 'main', seq: 2, updatedSeq: 3, kind: 'event',
    body: { type: 'widget', cardType: 'progress', cardKey: 'report-1', title: '生成报告', state: 'running' },
    provenance: { eventIDs: ['evt-2'], trust: 'model', tainted: false },
    streaming: false, createdAt: 1760000001000,
  },
  batch: { rows: [], deletes: ['e-main-1'], cursor: 2, reset: false },
  action: { nonce: 'nonce-1', botID: 'main', kind: 'chat', text: '继续' },
  result: { status: 'accepted', eventID: 'evt-2' },
}, [
  { nonce: 'nonce-1', botID: 'main', kind: 'chat', text: '重复 nonce', result: { status: 'duplicate', eventID: 'evt-2' },
    reason: 'nonce_already_consumed' },
  { nonce: 'nonce-2', botID: 'main', kind: 'approval', approvalID: 'approval-1', decision: 'allowOnce',
    result: { status: 'stale', reason: 'digest_mismatch' } },
]);

// Memory, wake markers and proactive delivery moved to the phoneDSH-owned
// `spec/bot/v2` tree; this pin now only covers the vectors still exported
// here. `requiredMergeCommits` is intentionally absent: the memory/routine
// merge requirements belonged to the moved batch.
writeJSON('dshbot-pin.json', {
  schemaVersion: 1,
  repository: 'https://github.com/launsion-boop/dsh-bot.git',
  source: actualSHA,
});
const goldenDirectory = path.join(output, 'golden');
const files = fs.readdirSync(goldenDirectory).filter((name) => name.endsWith('.json')).sort();
const phoneOverlays = files.filter((name) => name.endsWith('.phone.json'));
const upstream = [...exportedGolden].filter((name) => files.includes(name)).sort();
const manual = files.filter((name) => !upstream.includes(name) && !phoneOverlays.includes(name));
if (manual.length > 0) {
  throw new Error(`golden file(s) are neither exported nor *.phone.json overlays: ${manual.join(', ')}`);
}
const sha256 = Object.fromEntries(files.map((name) => [
  name, crypto.createHash('sha256').update(fs.readFileSync(path.join(goldenDirectory, name))).digest('hex'),
]));
writeJSON('export-manifest.json', {
  schemaVersion: 1,
  source,
  generator: 'spec/tools/bot/export-vectors.mjs',
  files,
  upstream,
  phoneOverlays,
  sha256,
});
console.log(`Exported Bot vectors from ${actualSHA} to ${output}`);
