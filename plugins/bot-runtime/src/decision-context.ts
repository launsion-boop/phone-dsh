// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { ToolCallId } from '@deepseek-ai/dsh-llm'
import { isRestrictedAgent } from '../../lifecycle-gate/src/restricted-session.ts'
import { agentSessionIdOf } from './volatile-context.ts'
import { isBotSessionId } from './bot-sessions.ts'
import { resolveTurnOrigin, rpcIdFromSource, turnOriginOfMessage } from './turn-origin.ts'
import type { TurnOriginKind } from './turn-origin.ts'

/**
 * Worker half of the frozen G-2 decision-material contract
 * (`spec/bot/v2/decision-context.md`, contract revision b4c6ef7d…).
 *
 * The official `agent/pre-step` waterfall selects a material block through the
 * host; the official `systemPrompt.context` provider renders that block into
 * the runtime-context snapshot that `step()`'s `refreshContext` puts into the
 * same model request. The block is never appended to the user message and
 * never becomes a system instruction, so it can not impersonate
 * `current-user-turn`.
 *
 * DSH pin: 66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db (0.2.2-rc.1).
 */

export const BOT_DECISION_CONTEXT_TOOL = 'mcp__phone__BotDecisionContext'
export const BOT_DECISION_CONTEXT_REQUEST_SCHEMA = 'bot-decision-context-request/v1'
export const BOT_DECISION_CONTEXT_RESULT_SCHEMA = 'bot-decision-context-result/v1'
export const DECISION_CONTEXT_SECTION = 'dshbot:decision-context'
export const DECISION_CONTEXT_ORDER = 350

export const DECISION_CONTEXT_LIMITS = Object.freeze({
  maxMaterials: 6,
  maxCharacters: 2_400,
  maxSnippetCharacters: 300,
  deadlineMilliseconds: 3_000,
})
export const DECISION_CONTEXT_DEFAULTS = Object.freeze({
  maxMaterials: 4,
  maxCharacters: 1_600,
  maxSnippetCharacters: 240,
  deadlineMilliseconds: 1_500,
})

export interface DecisionContextLimitsResolved {
  readonly maxMaterials: number
  readonly maxCharacters: number
  readonly maxSnippetCharacters: number
  readonly deadlineMilliseconds: number
}

export type DecisionMaterialState =
  | 'current' | 'changed' | 'unavailable' | 'revoked' | 'erased' | 'unknown'
export type DecisionMaterialReason =
  | 'record-unresolved' | 'record-erased' | 'grant-revoked' | 'source-changed'
  | 'newer-observation-unversioned' | 'revision-basis-mismatch' | 'no-baseline'
  | 'source-version-unknown' | 'cycle-detected' | 'scan-limit-exceeded'
  | 'feedback-disputed'
export type DecisionSelectionReason = 'match' | 'recipient' | 'goal' | 'recency'

export interface DecisionMaterial {
  readonly material_id: string
  readonly ref: string
  readonly path: string
  readonly scope: 'user' | 'agent'
  readonly version: number
  readonly updated_at_ms: number
  readonly snippet: string
  readonly evidence: readonly string[]
  readonly selection_reason: DecisionSelectionReason
  readonly state: DecisionMaterialState
  readonly reason?: DecisionMaterialReason
  readonly source_version?: Readonly<Record<string, unknown>>
}

export interface DecisionMaterialLimits {
  readonly max_materials: number
  readonly max_characters: number
  readonly max_snippet_characters: number
  readonly deadline_ms: number
}

/** Frozen `decision-material.schema.json` block. */
export interface DecisionMaterialBlock {
  readonly block_id: string
  readonly turn_id: string
  readonly session_id: string
  readonly bot_id: string
  readonly stage: 'pre_step' | 'pre_delivery'
  readonly authorization_revision: string
  readonly query_digest: string
  readonly goal_digest?: string
  readonly retrieved_at_ms: number
  readonly materials: readonly DecisionMaterial[]
  readonly limits: DecisionMaterialLimits
  readonly truncated: boolean
  readonly canceled: boolean
}

export interface DecisionContextSourceRequest {
  readonly sessionId: string
  readonly turn: number
  readonly step: number
  readonly query: string
  readonly origin: TurnOriginKind
  readonly agent?: Agent
  readonly signal: AbortSignal
}

export type DecisionContextSource = (
  request: DecisionContextSourceRequest,
) => Promise<DecisionMaterialBlock | undefined>

export interface DecisionContextObservation {
  readonly stage: 'retrieved' | 'injected' | 'adopted'
  readonly turnId: string
  readonly blockId: string
  readonly materialIds: readonly string[]
  readonly refs: readonly string[]
  readonly basis?: 'tool_argument'
}

/** Test/telemetry callback only. The durable trace carrier is C's
 * `BotMaterialTraceRecording`; this plugin must not create a second store. */
export type DecisionContextObserver = (event: DecisionContextObservation) => void

export interface DecisionContextConfig {
  /** Internal A/B switch (E's same-image comparison), not a user setting. */
  readonly enabled?: boolean
  /** Structured activation telemetry (no user text); eval-only diagnostic. */
  readonly debug?: boolean
  /// G-2 r6 A/B switch: false removes workspace candidates from the block.
  readonly workspaceMaterials?: boolean
  readonly source?: DecisionContextSource
  readonly observer?: DecisionContextObserver
  readonly lang?: () => 'en' | 'zh'
  readonly minQueryScalars?: number
  readonly allowOrigins?: readonly TurnOriginKind[]
  readonly limits?: {
    readonly maxMaterials?: number
    readonly maxCharacters?: number
    readonly maxSnippetCharacters?: number
    readonly deadlineMilliseconds?: number
  }
}

const ALL_ORIGINS: readonly TurnOriginKind[] = Object.freeze([
  'user', 'held', 'agent', 'routine', 'task', 'task-wake', 'unknown',
])
const STATES = new Set<DecisionMaterialState>([
  'current', 'changed', 'unavailable', 'revoked', 'erased', 'unknown',
])
const REASONS = new Set<DecisionMaterialReason>([
  'record-unresolved', 'record-erased', 'grant-revoked', 'source-changed',
  'newer-observation-unversioned', 'revision-basis-mismatch', 'no-baseline',
  'source-version-unknown', 'cycle-detected', 'scan-limit-exceeded',
  'feedback-disputed',
])
const SELECTION_REASONS = new Set<DecisionSelectionReason>(['match', 'recipient', 'goal', 'recency'])
const RECORD_REF = /^record:\/\/(session\/[A-Za-z0-9._-]{1,64}#(?:0|[1-9][0-9]*)|event\/[1-9][0-9]*)$/u
const MEMORY_REF = /^memory:(?:user|agent)\/[^\s]{1,190}@v[1-9][0-9]*$/u
const PREFERENCE_REF = /^feedback:preference:[A-Za-z0-9._:-]{1,128}$/u
const WORKSPACE_REF = /^workspace:((?:[A-Za-z0-9\-._~!$&'()*+,;=:]|%[0-9A-Fa-f]{2}|\/)+)@sha256:[0-9a-f]{64}$/u
const SHA256 = /^sha256:[0-9a-f]{64}$/u

function scalarLength(value: string): number {
  let length = 0
  for (const _character of value) length += 1
  return length
}

function bounded(value: string, limit: number): string {
  if (scalarLength(value) <= limit) return value
  let result = ''
  let length = 0
  for (const character of value) {
    if (length + 1 > limit) break
    result += character
    length += 1
  }
  return result
}

function validMemoryPath(path: string): boolean {
  if (path === '' || scalarLength(path) > 200) return false
  const segments = path.split('/')
  if (segments.length < 2) return false
  if (segments[0] !== 'user' && segments[0] !== 'agent') return false
  return segments.every(segment => segment !== '' && segment !== '.' && segment !== '..'
    && !segment.includes('\\'))
}

/** G-2 r6 workspace path: bot-root-relative, no leading slash, no escape. */
/**
 * Raw workspace path (G-2 r6): UTF-8, relative, no NUL/control, no escape.
 * Spaces, Chinese, `@` and `%` are legitimate file names; the ref carries the
 * canonical percent-encoded form while `path` stays raw.
 */
function validWorkspacePath(path: string): boolean {
  if (path === '' || scalarLength(path) > 200) return false
  if (path.startsWith('/') || path.endsWith('/') || path.includes('\\')) return false
  if (/[\u0000-\u001f\u007f]/u.test(path)) return false
  const segments = path.split('/')
  return segments.length > 0 && segments.every(segment => segment !== ''
    && segment !== '.' && segment !== '..')
}

/** RFC 3986 canonical workspace path: only unreserved + `/` stay literal. */
function encodeWorkspacePath(path: string): string {
  const encoder = new TextEncoder()
  const bytes = encoder.encode(path)
  const unreserved = /[A-Za-z0-9._~-]/
  let output = ''
  for (const byte of bytes) {
    const character = String.fromCharCode(byte)
    if (character === '/') {
      output += '/'
    } else if (unreserved.test(character)) {
      output += character
    } else {
      output += '%' + byte.toString(16).toUpperCase().padStart(2, '0')
    }
  }
  return output
}

/** Decode exactly one canonical workspace-ref path. */
function decodeWorkspaceRefPath(encoded: string): string | undefined {
  if (encoded === '') return undefined
  if (!/^(?:[A-Za-z0-9\-._~!$&'()*+,;=:]|%[0-9A-Fa-f]{2}|\/)+$/u.test(encoded)) return undefined
  let decoded: string
  try {
    decoded = decodeURIComponent(encoded)
  } catch {
    return undefined
  }
  if (!validWorkspacePath(decoded)) return undefined
  // Canonical form: reject lowercase/over-encoded `%xx` and `%2F` for `/`.
  return encodeWorkspacePath(decoded) === encoded ? decoded : undefined
}

function messageText(message: { content?: readonly { type?: string; text?: string }[] }): string {
  return (message.content ?? [])
    .map(block => block.type === 'text' ? String(block.text ?? '') : '')
    .join('')
}

/** The claimed turn text, excluding runtime-context snapshots. */
function isHeldSource(source: unknown): boolean {
  return rpcIdFromSource(source)?.startsWith('held:') === true
}

function isCurrentUserMessage(message: { source?: unknown }, requireUser = true): boolean {
  const kind = (message.source as { kind?: unknown } | undefined)?.kind
  if (requireUser && kind !== 'user') return false
  return !isHeldSource(message.source)
}

/** The message that opened the current turn: last non-held user message. */
export function currentTurnMessage(
  messages: readonly { content?: readonly { type?: string; text?: string }[]; source?: unknown }[],
): (typeof messages)[number] | undefined {
  const visible = messages.filter(message =>
    (message.source as { kind?: unknown } | undefined)?.kind !== 'runtime-context')
  const userMessages = visible.filter(message => isCurrentUserMessage(message))
  return userMessages.at(-1) ?? visible.at(-1)
}

export function queryFromMessages(
  messages: readonly { content?: readonly { type?: string; text?: string }[]; source?: unknown }[],
): string {
  const visible = messages.filter(message =>
    (message.source as { kind?: unknown } | undefined)?.kind !== 'runtime-context')
  const userMessages = visible.filter(message => isCurrentUserMessage(message))
  // The current turn is the last non-held user message. Put it first so a long
  // onboarding/held block can never consume the 600-scalar prefix; the prior
  // user turn is optional background, never a prefix.
  const selected = (userMessages.length > 0 ? userMessages : visible).slice(-2)
  const ordered = selected.length > 1 ? [selected[1], selected[0]] : selected
  return bounded(ordered
    .map(messageText)
    .join('\n')
    .replace(/\s+/gu, ' ')
    .trim(), 600)
}

function clampLimit(value: number | undefined, fallback: number, low: number, high: number): number {
  if (value === undefined || !Number.isFinite(value)) return fallback
  return Math.min(Math.max(Math.trunc(value), low), high)
}

function limitsOf(config: DecisionContextConfig): DecisionContextLimitsResolved {
  const limits = config.limits ?? {}
  return {
    maxMaterials: clampLimit(limits.maxMaterials, DECISION_CONTEXT_DEFAULTS.maxMaterials,
      1, DECISION_CONTEXT_LIMITS.maxMaterials),
    maxCharacters: clampLimit(limits.maxCharacters, DECISION_CONTEXT_DEFAULTS.maxCharacters,
      240, DECISION_CONTEXT_LIMITS.maxCharacters),
    maxSnippetCharacters: clampLimit(limits.maxSnippetCharacters,
      DECISION_CONTEXT_DEFAULTS.maxSnippetCharacters, 60, DECISION_CONTEXT_LIMITS.maxSnippetCharacters),
    deadlineMilliseconds: clampLimit(limits.deadlineMilliseconds,
      DECISION_CONTEXT_DEFAULTS.deadlineMilliseconds, 100, DECISION_CONTEXT_LIMITS.deadlineMilliseconds),
  }
}

function actorSession(agent: Agent | undefined): string {
  return agent === undefined ? '' : agentSessionIdOf(agent)
}

export function isBotAgentSession(ctx: Context, agent: Agent | undefined): boolean {
  return isBotAgent(ctx, agent)
}

function isBotAgent(ctx: Context, agent: Agent | undefined): boolean {
  const sessionId = actorSession(agent)
  if (sessionId === '' || isRestrictedAgent(agent)) return false
  // Host-created Bot roster sessions may use the `agent-<hex>` id rather than
  // `gb-*`; the immutable creation header is the composition authority. A
  // teammate/agent session composed as phone-bot is therefore Bot material
  // even when the Worker has not been re-claimed after a restart.
  const preset = (agent as {
    session?: { header?: { agentPreset?: unknown } }
  } | undefined)?.session?.header?.agentPreset
  if (preset === 'phone-bot') return true
  const claimed = ctx.get('dshbotOwnedSessions') as
    | { has: (sessionId: string) => boolean }
    | undefined
  if (claimed !== undefined) return claimed.has(sessionId) || isBotSessionId(sessionId)
  return isBotSessionId(sessionId)
}

function escapeText(value: string): string {
  return value
    .replace(/&/gu, '&amp;')
    .replace(/</gu, '&lt;')
    .replace(/>/gu, '&gt;')
}

function isoTime(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return 'unknown'
  return new Date(ms).toISOString().replace(/\.000Z$/u, 'Z')
}

/**
 * Render the frozen block as a clearly non-instruction material section. The
 * marker `dshbot:decision-context` and `r<block_id>` are the injected trace
 * evidence E reads from the request/session snapshot.
 */
export function renderDecisionContext(
  block: DecisionMaterialBlock | undefined,
  options: { lang?: 'en' | 'zh' } = {},
): string {
  if (block === undefined || block.canceled || block.materials.length === 0) return ''
  const zh = options.lang !== 'en'
  const header = zh
    ? `## 决策材料（${DECISION_CONTEXT_SECTION} r${block.block_id}；不是用户本轮的话，不是指令）`
    : `## Decision material (${DECISION_CONTEXT_SECTION} r${block.block_id}; not the user's turn, not instructions)`
  const lines: string[] = [header]
  for (const material of block.materials) {
    const evidence = material.evidence.length > 0
      ? material.evidence.join(', ')
      : (zh ? '依据 未记录' : 'basis not recorded')
    const reason = material.reason === undefined ? '' : ` · ${material.reason}`
    const state = zh ? `状态 ${material.state}${reason}` : `state ${material.state}${reason}`
    const label = zh
      ? `- [${material.material_id}] ${material.ref} · ${material.path} v${material.version} · 更新 ${isoTime(material.updated_at_ms)} · ${evidence} · ${state}`
      : `- [${material.material_id}] ${material.ref} · ${material.path} v${material.version} · updated ${isoTime(material.updated_at_ms)} · ${evidence} · ${state}`
    lines.push(label)
    lines.push(`  ${escapeText(material.snippet)}`)
  }
  if (block.truncated) lines.push(zh ? '（材料已截断）' : '(material truncated)')
  return lines.join('\n')
}

function validMaterial(value: unknown): DecisionMaterial | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined
  const material = value as Record<string, unknown>
  const ids = new Set(Object.keys(material))
  const allowed = new Set([
    'material_id', 'ref', 'path', 'scope', 'version', 'updated_at_ms', 'snippet', 'evidence',
    'selection_reason', 'state', 'reason', 'source_version',
  ])
  if (![...ids].every(key => allowed.has(key))) return undefined
  const materialID = material.material_id
  const ref = material.ref
  const path = material.path
  if (typeof materialID !== 'string' || !/^mat:[A-Za-z0-9._:-]{1,128}$/u.test(materialID)) return undefined
  if (typeof ref !== 'string' || scalarLength(ref) > 2048) return undefined
  const workspaceRef = WORKSPACE_REF.test(ref)
  const preferenceRef = PREFERENCE_REF.test(ref)
  if (!MEMORY_REF.test(ref) && !RECORD_REF.test(ref) && !workspaceRef && !preferenceRef) return undefined
  if (typeof path !== 'string') return undefined
  if (workspaceRef) {
    if (!validWorkspacePath(path)) return undefined
  } else if (preferenceRef) {
    if (!path.startsWith('feedback/preference/')) return undefined
  } else if (!validMemoryPath(path)) {
    return undefined
  }
  if (workspaceRef) {
    const marker = ref.lastIndexOf('@sha256:')
    if (marker <= 0) return undefined
    const encodedPath = ref.slice('workspace:'.length, marker)
    if (decodeWorkspaceRefPath(encodedPath) !== path) return undefined
    if (!Array.isArray(material.evidence) || material.evidence.length !== 0) return undefined
    if (material.scope !== 'agent') return undefined
    if (material.state !== 'current') return undefined
    if (material.reason !== undefined) return undefined
  }
  if (material.scope !== 'user' && material.scope !== 'agent') return undefined
  if (!Number.isInteger(material.version) || (material.version as number) < 1) return undefined
  if (!Number.isFinite(material.updated_at_ms) || (material.updated_at_ms as number) < 0) return undefined
  if (typeof material.snippet !== 'string' || material.snippet === ''
      || scalarLength(material.snippet) > DECISION_CONTEXT_LIMITS.maxSnippetCharacters) return undefined
  const evidence = material.evidence
  if (!Array.isArray(evidence) || evidence.length > 2) return undefined
  if (!evidence.every(entry => typeof entry === 'string' && RECORD_REF.test(entry))) return undefined
  if (typeof material.selection_reason !== 'string'
      || !SELECTION_REASONS.has(material.selection_reason as DecisionSelectionReason)) return undefined
  if (typeof material.state !== 'string'
      || !STATES.has(material.state as DecisionMaterialState)) return undefined
  const reason = material.reason
  if (reason !== undefined && (typeof reason !== 'string'
      || !REASONS.has(reason as DecisionMaterialReason))) return undefined
  if (material.state === 'unknown' && reason === undefined) return undefined
  if (reason === 'feedback-disputed' && material.state !== 'unknown') return undefined
  if (preferenceRef) {
    const id = ref.slice('feedback:preference:'.length)
    if (path !== `feedback/preference/${id}`) return undefined
    if (material.scope !== 'user' || material.version !== 1) return undefined
    if (evidence.length !== 0) return undefined
    if (material.state !== 'current' || reason !== undefined) return undefined
    if (material.selection_reason !== 'match') return undefined
  }
  const sourceVersion = material.source_version
  if (sourceVersion !== undefined && (sourceVersion === null
      || typeof sourceVersion !== 'object' || Array.isArray(sourceVersion))) return undefined
  return {
    material_id: materialID,
    ref,
    path,
    scope: material.scope,
    version: material.version as number,
    updated_at_ms: material.updated_at_ms as number,
    snippet: material.snippet,
    evidence: evidence as string[],
    selection_reason: material.selection_reason as DecisionSelectionReason,
    state: material.state as DecisionMaterialState,
    ...reason === undefined ? {} : { reason: reason as DecisionMaterialReason },
    ...sourceVersion === undefined
      ? {} : { source_version: sourceVersion as Record<string, unknown> },
  }
}

function validLimits(value: unknown): DecisionMaterialLimits | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined
  const limits = value as Record<string, unknown>
  const keys = new Set(Object.keys(limits))
  const expected = ['max_materials', 'max_characters', 'max_snippet_characters', 'deadline_ms']
  if (keys.size !== expected.length || !expected.every(key => keys.has(key))) return undefined
  const int = (key: string): number | undefined =>
    Number.isInteger(limits[key]) ? limits[key] as number : undefined
  const maxMaterials = int('max_materials')
  const maxCharacters = int('max_characters')
  const maxSnippetCharacters = int('max_snippet_characters')
  const deadlineMs = int('deadline_ms')
  if (maxMaterials === undefined || maxCharacters === undefined
      || maxSnippetCharacters === undefined || deadlineMs === undefined) return undefined
  if (maxMaterials < 1 || maxMaterials > DECISION_CONTEXT_LIMITS.maxMaterials) return undefined
  if (maxCharacters < 240 || maxCharacters > DECISION_CONTEXT_LIMITS.maxCharacters) return undefined
  if (maxSnippetCharacters < 60
      || maxSnippetCharacters > DECISION_CONTEXT_LIMITS.maxSnippetCharacters) return undefined
  if (deadlineMs < 100 || deadlineMs > DECISION_CONTEXT_LIMITS.deadlineMilliseconds) return undefined
  return {
    max_materials: maxMaterials,
    max_characters: maxCharacters,
    max_snippet_characters: maxSnippetCharacters,
    deadline_ms: deadlineMs,
  }
}

/** Strict consumer validation of the frozen block. Any malformed member
 * drops the whole block (there is no partial injection). */
export function validateDecisionContextResponse(
  value: unknown,
  expected: { sessionId: string; turn: number },
): DecisionMaterialBlock | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined
  const block = value as Record<string, unknown>
  const keys = new Set(Object.keys(block))
  const allowed = new Set([
    'block_id', 'turn_id', 'session_id', 'bot_id', 'stage', 'authorization_revision',
    'query_digest', 'goal_digest', 'retrieved_at_ms', 'materials', 'limits', 'truncated', 'canceled',
  ])
  if (![...keys].every(key => allowed.has(key))) return undefined
  const turnId = `${expected.sessionId}#${expected.turn}`
  if (typeof block.block_id !== 'string' || !/^dm:[A-Za-z0-9._:-]{1,128}$/u.test(block.block_id)) return undefined
  if (block.turn_id !== turnId) return undefined
  if (block.session_id !== expected.sessionId) return undefined
  if (typeof block.bot_id !== 'string' || scalarLength(block.bot_id) < 1
      || scalarLength(block.bot_id) > 128) return undefined
  if (block.stage !== 'pre_step' && block.stage !== 'pre_delivery') return undefined
  if (typeof block.authorization_revision !== 'string'
      || scalarLength(block.authorization_revision) < 1
      || scalarLength(block.authorization_revision) > 128) return undefined
  if (typeof block.query_digest !== 'string' || !SHA256.test(block.query_digest)) return undefined
  const goalDigest = block.goal_digest
  if (goalDigest !== undefined && (typeof goalDigest !== 'string' || !SHA256.test(goalDigest))) return undefined
  if (!Number.isFinite(block.retrieved_at_ms) || (block.retrieved_at_ms as number) < 0) return undefined
  const limits = validLimits(block.limits)
  if (limits === undefined) return undefined
  if (!Array.isArray(block.materials)
      || block.materials.length > DECISION_CONTEXT_LIMITS.maxMaterials) return undefined
  const materials: DecisionMaterial[] = []
  for (const raw of block.materials) {
    const material = validMaterial(raw)
    if (material === undefined) return undefined
    materials.push(material)
  }
  const total = materials.reduce((sum, material) => sum + scalarLength(material.snippet), 0)
  if (total > DECISION_CONTEXT_LIMITS.maxCharacters) return undefined
  if (typeof block.truncated !== 'boolean' || typeof block.canceled !== 'boolean') return undefined
  if (block.canceled) return undefined
  return {
    block_id: block.block_id,
    turn_id: turnId,
    session_id: expected.sessionId,
    bot_id: block.bot_id,
    stage: block.stage,
    authorization_revision: block.authorization_revision,
    query_digest: block.query_digest,
    ...goalDigest === undefined ? {} : { goal_digest: goalDigest },
    retrieved_at_ms: block.retrieved_at_ms as number,
    materials,
    limits,
    truncated: block.truncated,
    canceled: false,
  }
}

/**
 * Map the Worker turn-origin vocabulary onto the frozen G-2 r3 request enum
 * (`user|bot|routine|task|proactive`). `unknown` is omitted because `origin`
 * is optional; no new enum value is introduced.
 */
export function internalToolOrigin(origin: TurnOriginKind): 'user' | 'bot' | 'routine' | 'task' | 'proactive' | undefined {
  switch (origin) {
    case 'user': return 'user'
    case 'agent': return 'bot'
    case 'routine': return 'routine'
    case 'task': return 'task'
    case 'held':
    case 'task-wake': return 'proactive'
    default: return undefined
  }
}

/** Default provider: the single internal `BotDecisionContext` host call. */
export function createPhoneDecisionContextSource(
  ctx: Context,
  limits: DecisionContextLimitsResolved = DECISION_CONTEXT_DEFAULTS,
): DecisionContextSource {
  let nextCallId = 0
  return async ({ sessionId, turn, step, query, origin, agent, signal }) => {
    nextCallId += 1
    const mappedOrigin = internalToolOrigin(origin)
    const argumentsValue = {
      schema: BOT_DECISION_CONTEXT_REQUEST_SCHEMA,
      session_id: sessionId,
      turn_id: `${sessionId}#${turn}`,
      step,
      stage: 'pre_step',
      query: bounded(query, 600),
      ...mappedOrigin === undefined ? {} : { origin: mappedOrigin },
      scopes: ['user', 'agent'],
      limits: {
        max_materials: limits.maxMaterials,
        max_characters: limits.maxCharacters,
        max_snippet_characters: limits.maxSnippetCharacters,
        deadline_ms: limits.deadlineMilliseconds,
      },
    }
    try {
      const batch = await ctx.tools.execute({
        calls: [{
          type: 'tool-call',
          id: `dshbot-decision-${nextCallId}` as ToolCallId,
          name: BOT_DECISION_CONTEXT_TOOL,
          arguments: JSON.stringify(argumentsValue),
        }],
        signal,
        ...agent === undefined ? {} : { agent },
      })
      const result = batch.results[0]?.result
      if (result === undefined || result.isError || signal.aborted || !isRecord(result.value)) return undefined
      const value = result.value.structuredContent
      if (!isRecord(value) || value.schema !== BOT_DECISION_CONTEXT_RESULT_SCHEMA) return undefined
      if (value.ok !== true || !isRecord(value.block)) return undefined
      return validateDecisionContextResponse(value.block, { sessionId, turn })
    } catch {
      return undefined
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

interface TurnState {
  readonly turn: number
  readonly step: number
  readonly block: DecisionMaterialBlock
  injectedNoted: boolean
  adoptedNoted: boolean
}

export default function dshbotDecisionContext(
  ctx: Context,
  config: DecisionContextConfig = {},
): void {
  const enabled = config.enabled !== false
  const debug = config.debug === true
  const log = (message: string, fields: Record<string, unknown> = {}): void => {
    if (debug) console.info('[dshbot-decision-context]', message, fields)
  }
  const workspaceMaterials = config.workspaceMaterials !== false
  const limits = limitsOf(config)
  const source = config.source ?? createPhoneDecisionContextSource(ctx, limits)
  const lang = config.lang ?? (() => 'zh' as const)
  const minQuery = config.minQueryScalars ?? 1
  const allowOrigins = new Set(config.allowOrigins ?? ALL_ORIGINS)
  const states = new Map<string, TurnState>()
  const observer = config.observer ?? (() => {})

  const note = (
    stage: DecisionContextObservation['stage'],
    sessionId: string,
    state: TurnState,
    basis?: 'tool_argument',
  ): void => {
    observer({
      stage,
      turnId: state.block.turn_id,
      blockId: state.block.block_id,
      materialIds: state.block.materials.map(material => material.material_id),
      refs: state.block.materials.map(material => material.ref),
      ...basis === undefined ? {} : { basis },
    })
  }

  log('apply', { enabled })
  ctx.on('agent/pre-step', async (payload, next) => {
    if (!enabled) return next()
    const sessionId = actorSession(payload.agent)
    const bot = isBotAgent(ctx, payload.agent)
    log('pre-step', { sessionId, bot, messages: payload.messages.length })
    if (sessionId === '' || !bot) return next()
    const current = states.get(sessionId)
    // One retrieval per turn; a later step of the same turn reuses the block.
    // A new turn always replaces it. There is deliberately no time window.
    if (current !== undefined && current.turn === payload.turn) return next()
    states.delete(sessionId)
    const query = queryFromMessages(payload.messages)
    const originMessage = currentTurnMessage(payload.messages)
    const origin = originMessage !== undefined
      ? turnOriginOfMessage(originMessage)
      : resolveTurnOrigin(undefined)
    log('query', { origin: origin.kind, queryScalars: scalarLength(query) })
    if (!allowOrigins.has(origin.kind) || scalarLength(query) < minQuery) return next()

    const deadline = AbortSignal.timeout(limits.deadlineMilliseconds)
    const combined = AbortSignal.any([payload.signal, deadline])
    try {
      const block = await source({
        sessionId,
        turn: payload.turn,
        step: payload.step,
        query,
        origin: origin.kind,
        ...payload.agent === undefined ? {} : { agent: payload.agent },
        signal: combined,
      })
      log('host', { block: block !== undefined, materials: block?.materials.length ?? 0 })
      if (block === undefined || block.materials.length === 0 || payload.signal.aborted) return next()
      const visible = workspaceMaterials
        ? block
        : { ...block, materials: block.materials.filter(material => !material.ref.startsWith('workspace:')) }
      if (visible.materials.length === 0) return next()
      const state: TurnState = {
        turn: payload.turn,
        step: payload.step,
        block: visible,
        injectedNoted: false,
        adoptedNoted: false,
      }
      states.set(sessionId, state)
      log('injected', { sessionId, block: block.block_id, materials: visible.materials.length })
      note('retrieved', sessionId, state)
    } catch {
      // Timeout, abort and host failure all mean "no material this turn"; the
      // turn proceeds exactly as the baseline and no partial block survives.
    }
    return next()
  })

  // The first assistant-stream frame of the turn is emitted after the accepted
  // request (with the refreshed runtime-context snapshot) has started. It is
  // plugin-local telemetry; the authoritative `injected` evidence is the
  // request/session runtime-context row C observes with the same marker.
  ctx.on('agent/assistant-stream', ({ agent }) => {
    if (!enabled) return
    const sessionId = actorSession(agent)
    const state = states.get(sessionId)
    if (state === undefined || state.injectedNoted) return
    state.injectedNoted = true
    note('injected', sessionId, state)
  })

  // `adopted` is only the machine-checkable subset: a later tool call whose
  // arguments carry an exact material id, ref or quoted path, and only after
  // the block was actually injected. Prose use is E's judge, never this hook.
  ctx.on('tools/pre-execute', (exec, next) => {
    if (!enabled) return next()
    const sessionId = actorSession(exec.agent)
    const state = states.get(sessionId)
    if (state === undefined || state.adoptedNoted || !state.injectedNoted) return next()
    if (exec.name === BOT_DECISION_CONTEXT_TOOL) return next()
    let args: string
    try {
      args = JSON.stringify(exec.arguments ?? {})
    } catch {
      return next()
    }
    if (!state.block.materials.some(material =>
      args.includes(material.material_id) || args.includes(material.ref)
      || args.includes(JSON.stringify(material.path)))) {
      return next()
    }
    state.adoptedNoted = true
    note('adopted', sessionId, state, 'tool_argument')
    return next()
  })

  ctx.on('agent/disposed', ({ agent }) => {
    const sessionId = actorSession(agent)
    if (sessionId !== '') states.delete(sessionId)
  })

  ctx.systemPrompt.context({
    name: DECISION_CONTEXT_SECTION,
    order: DECISION_CONTEXT_ORDER,
    text: context => {
      if (!enabled || !isBotAgent(ctx, context.agent)) return ''
      const state = states.get(actorSession(context.agent))
      if (state === undefined) return ''
      return renderDecisionContext(state.block, { lang: lang() })
    },
  })
}

dshbotDecisionContext.inject = ['systemPrompt', 'tools']
