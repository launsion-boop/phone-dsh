// SPDX-License-Identifier: MIT
import { AsyncLocalStorage } from 'node:async_hooks'
import { createHash } from 'node:crypto'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { botOwnedSessions } from './bot-sessions.ts'
import { canonicalStringify } from './canonical-json.ts'
import { BOT_VOLATILE_CONTEXT_TOOL } from './volatile-mcp.ts'
import { callerCatalogUrl, installCallerCatalog } from './caller-catalog.ts'
import type { CallerCatalogConfig } from './caller-catalog.ts'

export const PHONE_TOOL_PREFIX = 'mcp__phone__'
export const NATIVE_PHONE_TOOL_PREFIX = 'mcp__phone__android_'
// PR59's native-MCP BLE tools have their own per-connection grant and are
// forwarded by the Bot server; they are not Bot-owned phone tools.
export const NATIVE_BLE_TOOL_PREFIX = 'mcp__phone__ble_'
export const DEFAULT_IDENTITY_TIMEOUT_MS = 5_000
/** One registration must outlive the 300 s approval wait plus transport slack. */
export const DEFAULT_IDENTITY_LIFETIME_MS = 330_000
export const BOT_RUNTIME_UNAVAILABLE_REASON =
  '[bot runtime] The App Bot MCP endpoint is unavailable; the tool call was NOT executed. Do not retry or work around it.'

export interface ToolExecution {
  readonly name: string
  readonly arguments?: unknown
  readonly callId?: string
  readonly agent?: Agent
  readonly signal?: AbortSignal
}

export interface IdentityRegistration {
  readonly ok: boolean
  readonly id?: string
  readonly error?: string
}

export interface IdentityBridgeConfig {
  readonly runtimeId?: string
  readonly bridgeUrl?: string
  readonly bridgeToken?: string
  readonly timeoutMs?: number
  readonly lifetimeMs?: number
  readonly request?: (payload: Record<string, unknown>, options: { timeoutMs: number; signal?: AbortSignal }) => Promise<IdentityRegistration>
  readonly cancel?: (id: string, options: { timeoutMs: number; signal?: AbortSignal }) => Promise<void>
  /**
   * Per-caller `tools/list` catalog. The App's MCP client sees one global tool
   * list per Worker, so the Worker fetches the identified session's catalog
   * itself and applies it to that Bot's scoped tool surface.
   */
  readonly catalog?: CallerCatalogConfig
}

export function argsDigest(value: unknown): string {
  return createHash('sha256').update(canonicalStringify(value ?? {})).digest('hex')
}

export function dispatchArguments(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {}
}

export function identityRegisterUrl(env: NodeJS.ProcessEnv = process.env): string {
  const raw = String(env.PDSH_PHONE_MCP_URL ?? '').trim()
  if (!raw) return ''
  const url = new URL(raw)
  url.pathname = url.pathname.replace(/\/mcp\/?$/, '/identity/register')
  return url.toString()
}

/**
 * Tools whose identity the App's Bot runtime needs before execution. Native
 * Android tools are served by the App's native MCP handler (which keeps its
 * own authorization and receipts) and non-phone built-ins are not Bot
 * tools, so neither is registered here.
 */
export function needsIdentityRegistration(name: string): boolean {
  if (name.startsWith(NATIVE_PHONE_TOOL_PREFIX)) return false
  if (name.startsWith(NATIVE_BLE_TOOL_PREFIX)) return false
  if (name === 'bash' || name === 'write' || name === 'edit') return true
  return name.startsWith(PHONE_TOOL_PREFIX)
}

export function createKeyedMutex() {
  const states = new Map<string, { busy: boolean; waiters: { resolve: (release: () => void) => void; reject: (error: Error) => void; signal?: AbortSignal }[] }>()

  function acquire(key: string, signal?: AbortSignal): Promise<() => void> {
    if (signal?.aborted) return Promise.reject(new Error('identity registration wait was aborted'))
    let state = states.get(key)
    if (!state) {
      state = { busy: false, waiters: [] }
      states.set(key, state)
    }
    const makeRelease = (): (() => void) => {
      let released = false
      return () => {
        if (released) return
        released = true
        state!.busy = false
        const waiter = state!.waiters.shift()
        if (waiter) {
          state!.busy = true
          waiter.resolve(makeRelease())
        } else if (!state!.busy && state!.waiters.length === 0) {
          states.delete(key)
        }
      }
    }
    if (!state.busy) {
      state.busy = true
      return Promise.resolve(makeRelease())
    }
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, signal }
      state!.waiters.push(waiter)
      signal?.addEventListener('abort', () => {
        const index = state!.waiters.indexOf(waiter)
        if (index >= 0) state!.waiters.splice(index, 1)
        reject(new Error('identity registration wait was aborted'))
      }, { once: true })
    })
  }

  return { acquire, size: () => states.size }
}

async function postJson(url: string, token: string, payload: Record<string, unknown>, timeoutMs: number, signal?: AbortSignal): Promise<IdentityRegistration> {
  if (!url) throw new Error('[identity-bridge] App MCP URL is not configured')
  if (!token) throw new Error('[identity-bridge] App MCP token is not configured')
  // The host-issued per-run MCP egress credential. Absent or empty means the
  // header is omitted and the host rejects the request (fail closed); it is
  // never replaced by a placeholder or another token.
  const egressToken = String(process.env.PDSH_MCP_EGRESS_TOKEN ?? '')
  const egress: Record<string, string> = egressToken === '' ? {} : { 'X-PDSH-MCP-Egress': egressToken }
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(new Error('identity registration timed out')), timeoutMs)
  const abort = (): void => controller.abort(signal?.reason)
  signal?.addEventListener('abort', abort, { once: true })
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...egress },
      body: JSON.stringify(payload),
      signal: signal === undefined ? controller.signal : AbortSignal.any([controller.signal, signal]),
    })
    if (!response.ok) throw new Error(`[identity-bridge] App MCP rejected registration (HTTP ${response.status})`)
    const value = await response.json() as IdentityRegistration
    if (!value || typeof value !== 'object') {
      throw new Error('[identity-bridge] App MCP returned an invalid registration reply')
    }
    return value
  } finally {
    clearTimeout(timer)
    signal?.removeEventListener('abort', abort)
  }
}

export interface BotIdentityCall {
  readonly sessionId: string
  readonly name: string
  readonly arguments: Record<string, unknown>
  readonly argsDigest: string
}

interface PendingIdentity {
  readonly registrationId: string
  readonly release: () => void
  readonly sessionId: string
  readonly callId: string
}

export function sessionIdFor(agent: Agent | undefined): string {
  return String(agent?.id ?? agent?.session?.id ?? '')
}

function callKey(sessionId: string, callId: string): string {
  return `${sessionId}\0${callId}`
}

/**
 * Registers the phone call with the App *before* the structural approval gate
 * runs, so the App can attribute the approval card. Registration happens in
 * `tools/pre-execute`, but it must stay live through the `tools/execute`
 * phase: the actual MCP `tools/call` arrives there and claims the
 * registration, and sandbox escalation is answered during execution. The
 * execute hook therefore only cleans up; registering a second time there
 * would publish two attributions for one call.
 *
 * Only sessions owned by the Bot runtime are gated. Ownership is deterministic
 * (`gb-` namespace plus `phone/botClaimSession`) and does not depend on the
 * current Bot MCP `tools/list`: when the Bot runtime is unavailable the gate
 * denies instead of falling back to the ordinary DSH permission chain.
 *
 * Mounting order matters: this plugin must precede `approval-gate` on
 * `tools/pre-execute` (the shipped profile already lists it first).
 */
export default function dshbotIdentityBridge(ctx: Context, config: IdentityBridgeConfig = {}): void {
  const runtimeId = config.runtimeId ?? 'phone-worker'
  const bridgeUrl = config.bridgeUrl ?? identityRegisterUrl()
  const bridgeToken = config.bridgeToken ?? String(process.env.PDSH_PHONE_MCP_TOKEN ?? '')
  const timeoutMs = config.timeoutMs ?? DEFAULT_IDENTITY_TIMEOUT_MS
  const lifetimeMs = config.lifetimeMs ?? DEFAULT_IDENTITY_LIFETIME_MS
  const send = config.request ?? ((payload: Record<string, unknown>, options: { timeoutMs: number; signal?: AbortSignal }) => postJson(bridgeUrl, bridgeToken, payload, options.timeoutMs, options.signal))
  const cancelUrl = bridgeUrl.replace(/\/identity\/register$/, '/identity/cancel')
  const cancel = config.cancel ?? (async (id: string, options: { timeoutMs: number; signal?: AbortSignal }) => {
    await postJson(cancelUrl, bridgeToken, { id }, options.timeoutMs, options.signal)
  })
  const mutex = createKeyedMutex()
  const dispatchChain = new AsyncLocalStorage<string>()
  const calls = new Map<string, BotIdentityCall>()
  const pending = new Map<string, PendingIdentity>()
  const ownedSessions = botOwnedSessions(ctx)

  ctx.provide('dshbotIdentityCalls', {
    get(callId: string, sessionId?: string): BotIdentityCall | undefined {
      if (sessionId !== undefined) return calls.get(callKey(sessionId, callId))
      const matches = [...calls.values()].filter(call => call.name !== '' && call.argsDigest !== ''
        && calls.get(callKey(call.sessionId, callId)) === call)
      return matches.length === 1 ? matches[0] : undefined
    },
  })

  const cleanup = async (key: string, expectedRegistrationId?: string): Promise<void> => {
    const entry = pending.get(key)
    if (entry === undefined) return
    if (expectedRegistrationId !== undefined && entry.registrationId !== expectedRegistrationId) return
    pending.delete(key)
    calls.delete(key)
    try {
      await cancel(entry.registrationId, { timeoutMs })
    } catch {}
    entry.release()
  }

  ctx.on('tools/pre-execute', async (exec: ToolExecution, next: () => Promise<any>) => {
    const sessionId = sessionIdFor(exec.agent)
    if (!ownedSessions.has(sessionId)) return next()
    if (!needsIdentityRegistration(exec.name)) return next()
    if (!botRuntimeAvailable(ctx, exec)) {
      return { kind: 'deny', reason: BOT_RUNTIME_UNAVAILABLE_REASON }
    }
    if (dispatchChain.getStore() === sessionId) {
      throw new Error('[identity-bridge] re-entrant phone tool call is not allowed')
    }
    const args = dispatchArguments(exec.arguments)
    const digest = argsDigest(args)
    const callId = String(exec.callId ?? '')
    const key = callKey(sessionId, callId)
    const release = await mutex.acquire(`${runtimeId}\0${sessionId}\0${callId}\0${digest}`, exec.signal)
    let registrationId: string | undefined
    let retained = false
    try {
      if (!sessionId) throw new Error('[identity-bridge] tool execution has no session identity')
      if (!callId) throw new Error('[identity-bridge] tool execution has no callId')
      // The host-issued session token is the only identity evidence for this
      // registration. Before the App claims the session (or after a Worker
      // restart until the next claim) there is no token: omit the field, do
      // not fabricate one, and let the host reject the registration closed.
      const sessionToken = ownedSessions.tokenFor(sessionId)
      const registration = await send({
        runtimeId, sessionId, callId, name: exec.name, arguments: args, argsDigest: digest,
        ...(sessionToken === undefined ? {} : { sessionToken }),
      }, { timeoutMs, signal: exec.signal })
      if (registration.ok !== true || typeof registration.id !== 'string' || registration.id === '') {
        // Fail closed. Every tool that reaches this point needs App identity
        // registration; `unknown_tool` means the App does not know the tool, so
        // executing it unregistered would be a policy bypass. The Worker never
        // gets to run the tool body in that case.
        if (registration.error === 'unknown_tool') {
          throw new Error('[identity-bridge] App MCP does not recognize the tool; the call was NOT executed')
        }
        throw new Error(`[identity-bridge] App MCP did not accept the call registration: ${registration.error ?? 'unknown error'}`)
      }
      registrationId = registration.id
      calls.set(key, { sessionId, name: exec.name, arguments: args, argsDigest: digest })
      const decision = await next()
      if (decision?.kind !== 'allow') return decision
      retained = true
      const entry: PendingIdentity = { registrationId, release, sessionId, callId }
      pending.set(key, entry)
      const timer = setTimeout(() => { void cleanup(key, registrationId) }, lifetimeMs)
      timer.unref?.()
      const onAbort = (): void => { void cleanup(key, registrationId) }
      if (exec.signal?.aborted) {
        await cleanup(key, registrationId)
        return { kind: 'deny', reason: '[identity-bridge] the tool call was aborted before dispatch' }
      }
      exec.signal?.addEventListener('abort', onAbort, { once: true })
      return decision
    } finally {
      // Denied, aborted, refused or queued-without-execute: the registration
      // and the digest mutex are released together, never left behind.
      if (!retained) {
        calls.delete(key)
        if (registrationId !== undefined) {
          try { await cancel(registrationId, { timeoutMs }) } catch {}
        }
        release()
      }
    }
  })

  ctx.on('tools/execute', async (exec: ToolExecution, next: () => Promise<any>) => {
    const key = callKey(sessionIdFor(exec.agent), String(exec.callId ?? ''))
    if (!pending.has(key)) return next()
    try {
      return await dispatchChain.run(sessionIdFor(exec.agent), () => next())
    } finally {
      await cleanup(key)
    }
  })

  installCallerCatalog(ctx, {
    ...config.catalog,
    ownedSessions,
    url: config.catalog?.url ?? callerCatalogUrl(bridgeUrl),
    token: config.catalog?.token ?? bridgeToken,
  })
}

/**
 * Whether the App's Bot MCP catalog is currently visible. This is an
 * availability probe for already-owned Bot sessions, not an ownership test:
 * MCP tools are registered globally, so their visibility cannot distinguish a
 * Bot session from a workbench session in the same Worker.
 */
export function botRuntimeAvailable(ctx: Context, exec: Pick<ToolExecution, 'agent'>): boolean {
  return ctx.tools.get(BOT_VOLATILE_CONTEXT_TOOL, exec.agent) !== undefined
}

export function botSessionOwned(ctx: Context, exec: Pick<ToolExecution, 'agent'>): boolean {
  return botOwnedSessions(ctx).has(sessionIdFor(exec.agent))
}

dshbotIdentityBridge.inject = ['tools']
