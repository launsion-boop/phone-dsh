// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import {
  argsDigest, BOT_RUNTIME_UNAVAILABLE_REASON, botRuntimeAvailable, botSessionOwned,
  dispatchArguments, NATIVE_PHONE_TOOL_PREFIX, PHONE_TOOL_PREFIX,
} from './identity-bridge.ts'

export interface ApprovalEffect {
  tool: string
  operation: string
  resource: string
  target: string
  mutability: 'read' | 'write' | 'external-send' | 'destructive'
  policy: 'auto' | 'ask'
  label: string
  detail: string
  ui: boolean
  execution: string | null
  known: boolean
  isMcp: boolean
}

export interface ApprovalOutcome {
  readonly ok: boolean
  readonly allowed?: boolean
  readonly message?: string
  readonly error?: string
  /** The host parked a durable (non-interactive) approval as a todo. */
  readonly pending?: boolean
  readonly approvalId?: string
  readonly expiresAt?: number
}

type CancelableAgent = Agent & {
  cancel?: (cause: { kind: 'hook'; reason: string }, options?: { keepInbox?: boolean }) => void
}

export interface ApprovalGateConfig {
  readonly approvalUrl?: string
  readonly bridgeToken?: string
  readonly request?: (payload: Record<string, unknown>, signal?: AbortSignal) => Promise<ApprovalOutcome>
}

const UI_TOOLS = new Set([
  'ask_user', 'show_next_steps', 'show_attachment', 'show_document', 'show_progress',
  'show_checklist', 'show_link', 'RequestApproval',
])
const AUTO_TOOLS = new Set([
  // Both memory readers are read-only and frozen as `read + auto` in
  // spec/bot/v1/golden/tool-effects{,.phone}.json. ReadMemory was added after
  // this table and was missing here, so the Worker proposed an `unknown`
  // effect (alwaysScope=session) while the host classified it as a known read
  // (alwaysScope=until) and rejected the call with `stale:always_scope`.
  'ReadMemory', 'RecallMemory',
  'Task', 'AwaitTask', 'StopSubagent', 'UpdateRoutine', 'ListRoutines', 'SendToUser',
  // Team tools are auto-policy but audited by the App: SendToAgent is an
  // external send and CreateTeammate creates a local Bot. Neither asks the
  // user for another approval card. FishAction is cosmetic only; playing a
  // gesture must never block a turn behind an approval card.
  'SendToAgent', 'CreateTeammate', 'FishAction',
])
// PR59's native-MCP "BLE tools" (`spec/v1/native-mcp.md`), forwarded by the
// Bot server as `mcp__phone__ble_*`. PR59's per-connection grant is the real
// authorization gate; this Bot ask is only an additional layer.
const BLE_TOOLS = new Set([
  'ble_devices', 'ble_read', 'ble_alert', 'ble_link_tools', 'ble_link_call', 'ble_link_result',
])
const BLE_EXTERNAL_TOOLS = new Set(['ble_alert', 'ble_link_call'])

const SENSITIVE_RE = /(?:^|[\s'"(=,:])((?:~\/|\/)[^\s'"`)\]}>,;]*(?:\.ssh|\.aws|\.gnupg|\.netrc|\.npmrc|\.pypirc|\.git-credentials|\.credentials\.yaml)(?:\/[^\s'"`)\]}>,;]*)?)/i

export function approvalUrl(env: NodeJS.ProcessEnv = process.env): string {
  const raw = String(env.PDSH_PHONE_MCP_URL ?? '').trim()
  if (!raw) return ''
  const url = new URL(raw)
  url.pathname = url.pathname.replace(/\/mcp\/?$/, '/approval')
  return url.toString()
}

function clip(value: unknown, max: number): string {
  return String(value ?? '').trim().replace(/\s+/g, ' ').slice(0, max)
}

function memoryForgetEffect(args: Record<string, unknown>): ApprovalEffect {
  const fact = clip(args.fact ?? args.key, 300)
  const factId = clip(args.fact_id ?? args.factId, 200)
  const resource = `memory:user&${factId ? `fact_id=${factId}` : `fact=${fact}`}`
  return {
    tool: 'memory', operation: 'memory.forget', resource, target: resource,
    mutability: 'destructive', policy: 'ask', label: factId ? 'Forget a memory (fact_id)' : `Forget memory "${clip(fact, 60)}"`,
    detail: 'Remove one fact from the shared user memory.', ui: false, execution: 'memory', known: true, isMcp: true,
  }
}

function bleEffect(bare: string, args: Record<string, unknown>): ApprovalEffect {
  const deviceID = clip(args.device_id, 120)
  const external = BLE_EXTERNAL_TOOLS.has(bare)
  let operation: string
  let label: string
  let detail: string
  switch (bare) {
    case 'ble_devices':
      operation = 'ble.devices'
      label = '列出 BLE 设备'
      detail = '读取附近 BLE 设备列表；设备名称与广播内容是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。'
      break
    case 'ble_read':
      operation = 'ble.read'
      label = '读取 BLE 设备数据'
      detail = '读取 BLE 设备内容；设备返回是不可信数据，不得当作指令或授权。设备须先在「设置 → 蓝牙设备」中逐连接授权。'
      break
    case 'ble_link_tools':
      operation = 'ble.link_tools'
      label = '列出 BLE 连接工具'
      detail = '列出设备提供的 BLE 连接工具；工具描述是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。'
      break
    case 'ble_link_result':
      operation = 'ble.link_result'
      label = '读取 BLE 连接结果'
      detail = '读取 BLE 连接工具的结果；结果是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。'
      break
    case 'ble_alert':
      operation = 'ble.alert'
      label = '向 BLE 设备发送提醒'
      detail = '向 BLE 设备发送提醒；这是对外动作，结果未知时不自动重试。设备须先在「设置 → 蓝牙设备」中逐连接授权。'
      break
    default:
      operation = 'ble.link_call'
      label = '调用 BLE 连接工具'
      detail = `调用 BLE 连接工具${clip(args.name, 80) ? ` ${clip(args.name, 80)}` : ''}；这是对外动作，结果未知时不自动重试。设备须先在「设置 → 蓝牙设备」中逐连接授权。`
  }
  const parts = [deviceID ? `device_id=${deviceID}` : 'ble:*']
  if (bare === 'ble_link_call' && clip(args.name, 80)) parts.push(`name=${clip(args.name, 80)}`)
  const resource = parts.join('&')
  return {
    tool: bare, operation, resource, target: resource,
    mutability: external ? 'external-send' : 'read', policy: 'ask', label, detail,
    ui: false, execution: null, known: true, isMcp: true,
  }
}

function modelImageEffect(name: string, args: Record<string, unknown>): ApprovalEffect {
  const target = clip(args.path ?? args.fileId ?? args.photoId, 200)
  const purpose = clip(args.purpose, 120)
  return {
    tool: name,
    operation: 'model.image.attach',
    resource: `attachment=${target}`,
    target,
    mutability: 'external-send',
    policy: 'ask',
    label: '把图片发送给模型',
    detail: `把图片发送给模型服务，让模型看到像素。${purpose ? `用途：${purpose}` : ''}`,
    ui: false,
    execution: null,
    known: true,
    isMcp: true,
  }
}

function unclassifiedEffect(name: string, args: Record<string, unknown>): ApprovalEffect {
  const resource = `unclassified=${name}&args=${argsDigest(args).slice(0, 16)}`
  return {
    tool: name, operation: 'tool.unclassified', resource, target: resource,
    mutability: 'write', policy: 'ask', label: `Run unclassified tool ${name}`,
    detail: 'This tool is not registered in the effect table and needs approval.',
    ui: false, execution: null, known: false, isMcp: true,
  }
}

function shellEffect(operation: string, resource: string, label: string, detail: string, mutability: ApprovalEffect['mutability'] = 'destructive'): ApprovalEffect {
  return {
    tool: 'bash', operation, resource, target: resource, mutability, policy: 'ask',
    label, detail, ui: false, execution: null, known: true, isMcp: false,
  }
}

function rmResource(command: string): string {
  const tokens = command.split(/\s+/).filter(Boolean)
  const index = tokens.indexOf('rm')
  const operand = index < 0 ? undefined : tokens.slice(index + 1).find(token => !token.startsWith('-'))
  return operand ?? command
}

function bashEffectsForApproval(args: Record<string, unknown>): ApprovalEffect[] {
  const command = String(args.command ?? '')
  if (!command) return []
  if (/(?:^|[;&|]\s*)rm\s+(?:[^\s;&|]+\s+)*-/i.test(command) || command.startsWith('rm ')) {
    const resource = rmResource(command)
    return [shellEffect('rm-destructive', resource, 'Delete files or directories (rm)', `This command deletes files or directories: ${command}`)]
  }
  if (/(?:^|[;&|]\s*)git\s+reset\s+[^\n]*--hard/i.test(command)) {
    return [shellEffect('git-destructive', command, 'Discard Git working-tree changes', `This command discards uncommitted changes: ${command}`)]
  }
  if (/(?:^|[;&|]\s*)find\s+[^\n]*(?:\s|^)-delete(?:\s|$)/i.test(command)) {
    return [shellEffect('find-delete', command, 'Delete files with find -delete', `find -delete removes matching files: ${command}`)]
  }
  // Network writes are intentionally absent: command text is
  // model-controlled (script files, variable concatenation, interpreters), so
  // it is not a security boundary. The host `/v1/http` exit owns the
  // host+method approval (spec/bot/v1/README.md §2.4). The destructive
  // patterns above remain as advisory card hints only.
  return []
}

/** POSIX-normalize one virtual path without touching the host filesystem. */
function normalizeVirtualPath(path: string): string {
  const absolute = path.startsWith('/')
  const stack: string[] = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      if (stack.length > 0) stack.pop()
      continue
    }
    stack.push(part)
  }
  const joined = stack.join('/')
  return absolute ? `/${joined}` : joined === '' ? '.' : joined
}

function resolveVirtualPath(raw: string, workspaceRoot: string): string {
  const joined = raw.startsWith('/') ? raw : `${workspaceRoot.replace(/\/$/, '')}/${raw}`
  return normalizeVirtualPath(joined)
}

function virtualDirectory(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash <= 0 ? '/' : path.slice(0, slash)
}

function insideWorkspace(path: string, workspaceRoot: string): boolean {
  const root = normalizeVirtualPath(workspaceRoot)
  if (root === '/') return true
  const target = normalizeVirtualPath(path)
  return target === root || target.startsWith(`${root}/`)
}

/**
 * `write`/`edit` effects at the Bot workspace boundary. A target inside the
 * Bot root is the DSH file sandbox's business and gets no structural card; a
 * target outside it is authorized per parent directory, never per argument
 * digest, so one "always" decision covers the next write in that directory.
 */
function fileEffect(name: 'write' | 'edit', args: Record<string, unknown>,
                    workspaceRoot: string): ApprovalEffect[] {
  const raw = typeof args.file_path === 'string' ? args.file_path.trim() : ''
  if (raw === '') return [unclassifiedEffect(name, args)]
  const target = resolveVirtualPath(raw, workspaceRoot)
  if (insideWorkspace(target, workspaceRoot)) return []
  const directory = virtualDirectory(target)
  return [{
    tool: name,
    operation: name === 'write' ? 'file.write' : 'file.edit',
    resource: `dir=${directory}`,
    target,
    mutability: 'write',
    policy: 'ask',
    label: name === 'write' ? 'Write a file outside the Bot workspace' : 'Edit a file outside the Bot workspace',
    detail: `The target ${target} is outside this Bot's workspace ${normalizeVirtualPath(workspaceRoot)}; the approval is remembered per directory ${directory}.`,
    ui: false,
    execution: null,
    known: true,
    isMcp: false,
  }]
}

export function phoneEffectsForApproval(
  name: string,
  args: Record<string, unknown>,
  context: { workspaceRoot?: string } = {},
): ApprovalEffect[] {
  const bare = name.startsWith(PHONE_TOOL_PREFIX) ? name.slice(PHONE_TOOL_PREFIX.length) : name
  if (bare === 'bash') return bashEffectsForApproval(args)
  if (bare === 'write' || bare === 'edit') {
    return fileEffect(bare, args, context.workspaceRoot ?? '/dsh/workspace')
  }
  if (bare === 'BotVolatileContext' || UI_TOOLS.has(bare) || AUTO_TOOLS.has(bare)) return []
  if (BLE_TOOLS.has(bare)) return [bleEffect(bare, args)]
  if (bare === 'attach_to_model') return [modelImageEffect(name, args)]
  if (bare === 'UpdateMemory') {
    const action = String(args.action ?? 'write')
    const scope = String(args.scope ?? 'agent')
    if (action === 'forget' && scope === 'user') return [memoryForgetEffect(args)]
    return []
  }
  return [unclassifiedEffect(name, args)]
}

/**
 * The structural gate only owns the Worker shell/file tools and Bot's own
 * phone tools. Native Android tools keep the App's native MCP authorization;
 * unrelated built-ins (read/grep/glob/web) must not be turned into approval
 * requests, which used to end as unattributed and blocked them.
 */
export function needsStructuralApproval(name: string): boolean {
  if (name.startsWith(NATIVE_PHONE_TOOL_PREFIX)) return false
  if (name === 'bash' || name === 'write' || name === 'edit') return true
  return name.startsWith(PHONE_TOOL_PREFIX)
}

function sensitiveRead(exec: { name: string; arguments?: unknown }): boolean {
  const args = dispatchArguments(exec.arguments)
  const bare = exec.name.startsWith(PHONE_TOOL_PREFIX) ? exec.name.slice(PHONE_TOOL_PREFIX.length) : exec.name
  if (bare === 'bash') return SENSITIVE_RE.test(String(args.command ?? ''))
  for (const key of ['file_path', 'path', 'pattern']) {
    if (SENSITIVE_RE.test(String(args[key] ?? ''))) return true
  }
  return false
}

/**
 * Parses the SSE answer form of `/approval` (spec/bot/v1/mcp-endpoint.md §2
 * "Long approvals"). The stream must carry exactly one `message` event with
 * exactly one `data:` line holding a JSON object. Every other shape is a
 * transport failure (`undefined`), so `postApproval` fails closed.
 */
export function parseApprovalEventStream(text: string): ApprovalOutcome | undefined {
  const events: { event: string; data: string[] }[] = []
  let event = ''
  let data: string[] = []
  const dispatch = (): void => {
    // An event without a `data:` field is not dispatched (SSE rules), and a
    // comment-only block is skipped.
    if (data.length > 0) events.push({ event: event === '' ? 'message' : event, data })
    event = ''
    data = []
  }
  // SSE lines end in CRLF, LF or CR. A line starting with `:` is a comment.
  for (const line of text.replace(/\r\n?/g, '\n').split('\n')) {
    if (line === '') {
      dispatch()
      continue
    }
    if (line.startsWith(':')) continue
    const colon = line.indexOf(':')
    const field = colon < 0 ? line : line.slice(0, colon)
    let value = colon < 0 ? '' : line.slice(colon + 1)
    if (value.startsWith(' ')) value = value.slice(1)
    if (field === 'event') event = value
    else if (field === 'data') data.push(value)
  }
  if (events.length !== 1) return undefined
  const message = events[0]!
  if (message.event !== 'message' || message.data.length !== 1) return undefined
  let parsed: unknown
  try {
    parsed = JSON.parse(message.data[0]!)
  } catch {
    return undefined
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined
  return parsed as ApprovalOutcome
}

export async function postApproval(url: string, token: string, payload: Record<string, unknown>, signal?: AbortSignal): Promise<ApprovalOutcome> {
  if (!url || !token) return { ok: false, message: 'approval gate is not configured' }
  // One host-issued egress credential per host run. Absent/empty omits the
  // header, so the host rejects the request and no approval is granted.
  const egressToken = String(process.env.PDSH_MCP_EGRESS_TOKEN ?? '')
  const egress: Record<string, string> = egressToken === '' ? {} : { 'X-PDSH-MCP-Egress': egressToken }
  const controller = new AbortController()
  // This deadline only covers the interactive card (the host answers it
  // within 300 s). Durable approvals answer immediately with
  // `{ok:true,allowed:false,pending:true}`; they never keep the tool call
  // blocked across this timer (spec/bot/v1 §2.7).
  const timer = setTimeout(() => controller.abort(new Error('approval timed out')), 330_000)
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
        // The listener answers a wait longer than 5 s in the SSE form; a fast
        // outcome, or an older listener, is still JSON (mcp-endpoint.md §2).
        accept: 'application/json, text/event-stream',
        ...egress,
      },
      body: JSON.stringify(payload),
      signal: signal === undefined ? controller.signal : AbortSignal.any([controller.signal, signal]),
    })
    if (!response.ok) return { ok: false, message: `approval transport failed (HTTP ${response.status})` }
    const mediaType = (response.headers.get('content-type') ?? '').split(';')[0]!.trim().toLowerCase()
    if (mediaType === 'text/event-stream') {
      const outcome = parseApprovalEventStream(await response.text())
      if (outcome === undefined) {
        return { ok: false, message: 'approval transport failed (malformed event stream)' }
      }
      return outcome
    }
    return await response.json() as ApprovalOutcome
  } catch (error) {
    return { ok: false, message: error instanceof Error ? error.message : String(error) }
  } finally {
    clearTimeout(timer)
  }
}

/**
 * A durable approval ends the turn instead of holding `tools/pre-execute`
 * open. The host parks the task/routine and wakes it after the user decision;
 * the Worker must not keep the tool call (or its identity registration)
 * waiting for up to 24 hours. `hook` is the stable non-user cause.
 */
function stopTurnForDurableApproval(agent: Agent | undefined): void {
  const cancelable = agent as CancelableAgent | undefined
  try {
    cancelable?.cancel?.({ kind: 'hook', reason: 'approval-pending' }, { keepInbox: true })
  } catch {
    // The host still parks on the turn result; a failed cancel is not a
    // permission to execute the tool.
  }
}

export default function dshbotApprovalGate(ctx: Context, config: ApprovalGateConfig = {}): void {
  const url = config.approvalUrl ?? approvalUrl()
  const token = config.bridgeToken ?? String(process.env.PDSH_PHONE_MCP_TOKEN ?? '')
  const send = config.request ?? ((payload: Record<string, unknown>, signal?: AbortSignal) => postApproval(url, token, payload, signal))

  ctx.on('tools/pre-execute', async (exec: { name: string; arguments?: unknown; agent?: Agent; callId?: string; signal?: AbortSignal }, next: () => Promise<any>) => {
    // Workbench sessions keep the ordinary DSH permission chain. Ownership is
    // claimed by the Bot runtime, never inferred from the globally registered
    // MCP catalog.
    if (!botSessionOwned(ctx, exec)) return next()
    if (sensitiveRead(exec)) {
      return { kind: 'deny', reason: '[sensitive read] The operation targets protected credentials and was NOT executed.' }
    }
    if (!needsStructuralApproval(exec.name)) return next()
    if (!botRuntimeAvailable(ctx, exec)) {
      return { kind: 'deny', reason: BOT_RUNTIME_UNAVAILABLE_REASON }
    }
    const args = dispatchArguments(exec.arguments)
    const workspaceRoot = String(
      (exec.agent as { session?: { header?: { cwd?: unknown } } } | undefined)
        ?.session?.header?.cwd ?? '')
    const effects = phoneEffectsForApproval(exec.name, args,
      workspaceRoot === '' ? {} : { workspaceRoot })
    // Empty effects are auto-policy: destructive/network patterns are hints,
    // and a write inside the Bot workspace root is the sandbox's business.
    // Non-shell tools skip the roundtrip entirely; bash/write/edit keep it so
    // the host still sees (and auto-allows) the call it registered.
    if (effects.length === 0 && exec.name !== 'bash' && exec.name !== 'write' && exec.name !== 'edit') {
      return next()
    }
    const first = effects[0]
    const sessionId = String(exec.agent?.id ?? exec.agent?.session?.id ?? '')
    const payload: Record<string, unknown> = {
      source: 'structural', sessionId, tool: exec.name,
      action: first?.label ?? exec.name,
      detail: first?.detail ?? 'Evaluate structural tool effects.',
      command: exec.name === 'bash' ? String(args.command ?? '') : '',
      target: first?.target ?? exec.name,
      askAction: exec.name.startsWith('mcp__') ? 'tool-call' : 'run-command',
      callId: exec.callId ?? '',
      argsDigest: argsDigest(args),
      alwaysScope: effects.length > 0 && effects.every(effect => !effect.known) ? 'session' : 'until',
      pattern: first?.operation ?? 'structural',
      effects,
      grantSets: effects.map(effect => [effect.resource]),
      deferConsumption: effects.length > 0 && effects.every(effect => effect.execution !== null),
    }
    const decision = await send(payload, exec.signal)
    if (decision.ok && decision.allowed) return next()
    if (decision.pending === true) {
      stopTurnForDurableApproval(exec.agent)
      return {
        kind: 'deny',
        reason: `[approval pending] ${decision.message ?? 'The user is away; this approval is a durable todo.'} The tool call was NOT executed. The task is parked; the host will resume it after the user decides. Do not retry or work around it in this turn.`,
      }
    }
    const technical = decision.message ?? decision.error ?? 'approval was denied'
    // `unattributed` means the App could not match a live session identity
    // registration to this call. Bare `unattributed` told the model nothing,
    // so answer with what happened and what the person can do about it.
    const reason = technical === 'unattributed'
      ? '这个对话与 App 的身份登记已失效或未完成，App 无法确认这次工具调用属于当前对话；请稍后重试或重新打开对话。'
      : technical
    return {
      kind: 'deny',
      reason: `[structural approval gate] ${reason} The tool call was NOT executed. Do not retry or work around it.`,
    }
  })
}

dshbotApprovalGate.inject = ['tools']
