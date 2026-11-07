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
  'RecallMemory', 'Task', 'AwaitTask', 'StopSubagent', 'UpdateRoutine', 'ListRoutines', 'SendToUser',
])
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
  if (/(?:^|[;&|]\s*)curl\s+/i.test(command)
    && /(?:\s|^)-X\s+POST(?:\s|$)|(?:\s|^)--request\s+POST(?:\s|$)|(?:\s|^)(?:-d|--data(?:-raw|-binary)?|-F|--form)(?:\s|=|$)/i.test(command)) {
    return [shellEffect('curl-post', command, 'Send a network POST request', `This command sends a network write request: ${command}`)]
  }
  if (/(?:^|[;&|]\s*)(?:wget|nc|socat|telnet|ssh|sftp|ftp)(?:\s|$)/i.test(command)
    || (/(?:^|[;&|]\s*)(?:scp|rsync)\s+/i.test(command) && command.includes(':'))
    || (/(?:python3?|node|ruby|perl)(?:\s|$)/i.test(command)
      && /urllib|requests\.|http\.client|http\/server|require\(['"](?:http|https|net|dns)['"]\)|Net::HTTP|TCPSocket|socket\.|fetch\(|https?:\/\//i.test(command))
    || /(?:dig|nslookup)[^\n]*(?:\$\{|\$\()/i.test(command)) {
    return [shellEffect('network-egress', command, 'Sends data off this machine', `This command sends data outside this machine: ${command}`, 'external-send')]
  }
  return []
}

export function phoneEffectsForApproval(name: string, args: Record<string, unknown>): ApprovalEffect[] {
  const bare = name.startsWith(PHONE_TOOL_PREFIX) ? name.slice(PHONE_TOOL_PREFIX.length) : name
  if (bare === 'bash') return bashEffectsForApproval(args)
  if (bare === 'BotVolatileContext' || UI_TOOLS.has(bare) || AUTO_TOOLS.has(bare)) return []
  if (bare === 'ReplyToDevice') {
    // Host extension registered in golden/tool-effects.json hostExtensions:
    // the App replaces resource/target with the resolved staged source before
    // authorization. Marking it known/execution keeps `alwaysScope=until` and
    // `deferConsumption=true`, matching BotMCPRuntime.approve.
    return [{
      tool: 'ReplyToDevice', operation: 'device.reply', resource: 'device:*', target: '*',
      mutability: 'external-send', policy: 'ask', label: '回覆來源設備',
      detail: 'host resolves the staged source (deviceID, transport, mapped transport session) and replaces resource/target with the concrete values before execution; the model cannot name a destination',
      ui: false, execution: 'device-reply', known: true, isMcp: true,
    }]
  }
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

export async function postApproval(url: string, token: string, payload: Record<string, unknown>, signal?: AbortSignal): Promise<ApprovalOutcome> {
  if (!url || !token) return { ok: false, message: 'approval gate is not configured' }
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(new Error('approval timed out')), 330_000)
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(payload),
      signal: signal === undefined ? controller.signal : AbortSignal.any([controller.signal, signal]),
    })
    if (!response.ok) return { ok: false, message: `approval transport failed (HTTP ${response.status})` }
    return await response.json() as ApprovalOutcome
  } catch (error) {
    return { ok: false, message: error instanceof Error ? error.message : String(error) }
  } finally {
    clearTimeout(timer)
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
    const effects = phoneEffectsForApproval(exec.name, args)
    if (effects.length === 0 && exec.name !== 'bash' && exec.name !== 'write' && exec.name !== 'edit') return next()
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
    const reason = decision.message ?? decision.error ?? 'approval was denied'
    return {
      kind: 'deny',
      reason: `[structural approval gate] ${reason} The tool call was NOT executed. Do not retry or work around it.`,
    }
  })
}

dshbotApprovalGate.inject = ['tools']
