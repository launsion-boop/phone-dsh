// SPDX-License-Identifier: MIT
import { AsyncLocalStorage } from 'node:async_hooks'
import { createHash } from 'node:crypto'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { botOwnedSessions } from './bot-sessions.ts'
import { canonicalStringify } from './canonical-json.ts'
import { restrictedPresetForSessionId } from '../../lifecycle-gate/src/restricted-session.ts'
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
/**
 * A background job can outlive the tool call that started it. The Worker keeps
 * that call's identity registration alive and refreshes it on this cadence,
 * which is comfortably inside the host's 330 s registration TTL.
 */
export const DEFAULT_BACKGROUND_JOB_HEARTBEAT_MS = 120_000
/**
 * Hard cap for a job registration that never produces a settlement event (for
 * example a lost Worker event loop or a job from an older registry). The cap
 * is deliberately finite: a leaked registration must not authorize writes for
 * the lifetime of the Bot session.
 */
export const DEFAULT_BACKGROUND_JOB_MAX_LIFETIME_MS = 24 * 60 * 60 * 1_000
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
  /** Refresh cadence for a registration that outlives its tool call. */
  readonly jobHeartbeatMs?: number
  /** Upper bound on such a registration when no job settlement arrives. */
  readonly jobMaxLifetimeMs?: number
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

export interface TailCancelQueue {
  /** Queue one registration id; never blocks the caller. */
  enqueue(id: string | undefined): void
  /** Resolve once every queued cancellation has been attempted. */
  flush(): Promise<void>
  readonly pending: number
}

/**
 * Cancellation is a tail request: the tool result must reach the model before
 * the host is told to drop the identity registration. The queue drains on the
 * next event-loop turn, collapses duplicate ids, and swallows transport
 * failures (the host TTL is the backstop). It never delays execution.
 */
export function createTailCancelQueue(
  cancel: (id: string, options: { timeoutMs: number }) => Promise<void>,
  timeoutMs: number,
  schedule: (run: () => void) => void = run => queueMicrotask(run),
): TailCancelQueue {
  const ids: string[] = []
  const seen = new Set<string>()
  let draining: Promise<void> | undefined
  const start = (): void => {
    if (draining !== undefined || ids.length === 0) return
    draining = (async () => {
      await new Promise<void>(resolve => schedule(resolve))
      while (ids.length > 0) {
        const id = ids.shift()!
        seen.delete(id)
        try { await cancel(id, { timeoutMs }) } catch {}
      }
    })().finally(() => {
      draining = undefined
      if (ids.length > 0) start()
    })
  }
  return {
    enqueue(id: string | undefined): void {
      const value = id?.trim() ?? ''
      if (value === '' || seen.has(value)) return
      seen.add(value)
      ids.push(value)
      start()
    },
    async flush(): Promise<void> {
      while (draining !== undefined || ids.length > 0) {
        if (draining !== undefined) await draining
        else start()
      }
    },
    get pending(): number { return ids.length },
  }
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
  /** Updated when a heartbeat refresh replaces an expired registration. */
  registrationId: string
  readonly release: () => void
  readonly sessionId: string
  readonly callId: string
  /** The 330 s cleanup timer, cleared once a background job takes ownership. */
  timer?: NodeJS.Timeout
}

/**
 * One `bash` call that the DSH job registry kept running after the tool call
 * returned (`run_in_background: true`, or a foreground call promoted on
 * timeout). The identity registration is held and refreshed until the job
 * settles; otherwise `/v1/http` writes from the still-running command would
 * arrive with no live Bot call and fall into the workbench path.
 */
interface BackgroundJobBinding {
  readonly key: string
  readonly jobId: string
  readonly sessionId: string
  readonly callId: string
  readonly name: string
  readonly arguments: Record<string, unknown>
  readonly argsDigest: string
  registrationId: string
  heartbeat?: NodeJS.Timeout
  maxLifetime?: NodeJS.Timeout
  unsubscribe?: () => void
  finished: boolean
}

interface BackgroundJobView {
  readonly id: string
  readonly status: string
  readonly owner?: string
}

interface BackgroundJobEvent {
  readonly type: string
  readonly job?: BackgroundJobView
}

interface BackgroundJobRegistry {
  readonly events: {
    subscribe(filter: { owner: string }, listener: (event: BackgroundJobEvent) => void): () => void
  }
  get(id: string, caller?: string): BackgroundJobView
}

/** The DSH job id carried by a `background`/`promoted` bash result, if any. */
function backgroundJobId(result: unknown): string | undefined {
  if (result === null || typeof result !== 'object') return undefined
  const value = (result as { value?: unknown }).value
  if (value === null || typeof value !== 'object') return undefined
  const record = value as { kind?: unknown; jobId?: unknown }
  if (record.kind !== 'background' && record.kind !== 'promoted') return undefined
  return typeof record.jobId === 'string' && record.jobId !== '' ? record.jobId : undefined
}

function jobRegistry(ctx: Context): BackgroundJobRegistry | undefined {
  const value = (ctx as unknown as { get(name: string): unknown }).get('jobs')
  if (value === null || typeof value !== 'object') return undefined
  const candidate = value as Partial<BackgroundJobRegistry>
  if (typeof candidate.get !== 'function'
    || candidate.events === null || typeof candidate.events !== 'object'
    || typeof candidate.events.subscribe !== 'function') return undefined
  return candidate as BackgroundJobRegistry
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
  const jobHeartbeatMs = Math.max(1, config.jobHeartbeatMs ?? DEFAULT_BACKGROUND_JOB_HEARTBEAT_MS)
  const jobMaxLifetimeMs = Math.max(jobHeartbeatMs,
    config.jobMaxLifetimeMs ?? DEFAULT_BACKGROUND_JOB_MAX_LIFETIME_MS)
  const send = config.request ?? ((payload: Record<string, unknown>, options: { timeoutMs: number; signal?: AbortSignal }) => postJson(bridgeUrl, bridgeToken, payload, options.timeoutMs, options.signal))
  const cancelUrl = bridgeUrl.replace(/\/identity\/register$/, '/identity/cancel')
  const cancel = config.cancel ?? (async (id: string, options: { timeoutMs: number; signal?: AbortSignal }) => {
    await postJson(cancelUrl, bridgeToken, { id }, options.timeoutMs, options.signal)
  })
  const cancelQueue = createTailCancelQueue(cancel, timeoutMs)
  const mutex = createKeyedMutex()
  const dispatchChain = new AsyncLocalStorage<string>()
  const calls = new Map<string, BotIdentityCall>()
  const pending = new Map<string, PendingIdentity>()
  const backgroundJobs = new Map<string, BackgroundJobBinding>()
  const ownedSessions = botOwnedSessions(ctx)

  ctx.provide('dshbotIdentityCalls', {
    get(callId: string, sessionId?: string): BotIdentityCall | undefined {
      if (sessionId !== undefined) return calls.get(callKey(sessionId, callId))
      const matches = [...calls.values()].filter(call => call.name !== '' && call.argsDigest !== ''
        && calls.get(callKey(call.sessionId, callId)) === call)
      return matches.length === 1 ? matches[0] : undefined
    },
  })

  /** Drop the timers/listeners owned by one background-job registration. */
  const clearBackgroundBinding = (key: string): BackgroundJobBinding | undefined => {
    const binding = backgroundJobs.get(key)
    if (binding === undefined) return undefined
    backgroundJobs.delete(key)
    if (binding.heartbeat !== undefined) clearInterval(binding.heartbeat)
    if (binding.maxLifetime !== undefined) clearTimeout(binding.maxLifetime)
    binding.unsubscribe?.()
    binding.unsubscribe = undefined
    return binding
  }

  const cleanup = async (key: string, expectedRegistrationId?: string): Promise<void> => {
    const entry = pending.get(key)
    if (entry === undefined) {
      clearBackgroundBinding(key)
      return
    }
    if (expectedRegistrationId !== undefined && entry.registrationId !== expectedRegistrationId) return
    const binding = clearBackgroundBinding(key)
    if (binding !== undefined) binding.finished = true
    pending.delete(key)
    calls.delete(key)
    if (entry.timer !== undefined) clearTimeout(entry.timer)
    // Tail request, never on the result path (W5: cancel does not block the
    // tool result). The queue collapses duplicates and the host TTL bounds a
    // lost cancellation.
    cancelQueue.enqueue(entry.registrationId)
    entry.release()
  }

  /**
   * Refresh a job-held registration so it stays ahead of the host's 330 s TTL.
   * Re-posting the same call is idempotent on the host and extends the same
   * attribution; if the host already pruned it, the response is a fresh id
   * that replaces the old one.
   */
  const refreshBackgroundRegistration = async (binding: BackgroundJobBinding): Promise<void> => {
    if (binding.finished || backgroundJobs.get(binding.key) !== binding) return
    const entry = pending.get(binding.key)
    if (entry === undefined) return
    try {
      const sessionToken = ownedSessions.tokenFor(binding.sessionId)
      const registration = await send({
        runtimeId, sessionId: binding.sessionId, callId: binding.callId,
        name: binding.name, arguments: binding.arguments, argsDigest: binding.argsDigest,
        ...(sessionToken === undefined ? {} : { sessionToken }),
      }, { timeoutMs })
      if (registration.ok === true
        && typeof registration.id === 'string' && registration.id !== '') {
        // A settlement can win the race while this request was in flight.
        // Cancel the just-issued id instead of letting it outlive the job.
        if (binding.finished || backgroundJobs.get(binding.key) !== binding) {
          cancelQueue.enqueue(registration.id)
          return
        }
        binding.registrationId = registration.id
        entry.registrationId = registration.id
      }
    } catch {
      // The next heartbeat retries; if the host TTL expires first, the
      // fail-closed egress fallback owns the write until re-registration.
    }
  }

  /**
   * Hand one completed bash tool call's registration to the DSH job that keeps
   * running. The registration is removed only when the job settles, its owner
   * goes away, the hard cap expires, or the plugin/Worker is disposed.
   *
   * @returns true when a job binding now owns cleanup.
   */
  const retainBackgroundJob = (key: string, jobId: string, sessionId: string): boolean => {
    const entry = pending.get(key)
    const call = calls.get(key)
    if (entry === undefined || call === undefined) return false
    // The pre-execute lifetime timer only covers a normal tool call. A job has
    // no such bound; replace it with the heartbeat and the explicit cap.
    if (entry.timer !== undefined) {
      clearTimeout(entry.timer)
      entry.timer = undefined
    }
    const binding: BackgroundJobBinding = {
      key, jobId, sessionId, callId: entry.callId,
      name: call.name, arguments: call.arguments, argsDigest: call.argsDigest,
      registrationId: entry.registrationId, finished: false,
    }
    backgroundJobs.set(key, binding)
    const finish = (): void => {
      if (backgroundJobs.get(key) !== binding) return
      binding.finished = true
      clearBackgroundBinding(key)
      void cleanup(key)
    }
    const registry = jobRegistry(ctx)
    if (registry !== undefined) {
      try {
        const view = registry.get(jobId, sessionId)
        if (view.status !== 'running' && view.status !== 'stopping') {
          finish()
          return true
        }
      } catch {
        // The registry may not know an id from an older generation; the
        // heartbeat keeps the registration honest until the cap.
      }
      try {
        binding.unsubscribe = registry.events.subscribe({ owner: sessionId }, event => {
          if (event.type !== 'settled' && event.type !== 'removed') return
          if (event.job?.id !== jobId) return
          finish()
        })
        // Close the race between the first status read and the subscription:
        // a job that settled in that window has already emitted its event.
        const settled = registry.get(jobId, sessionId)
        if (settled.status !== 'running' && settled.status !== 'stopping') {
          finish()
          return true
        }
      } catch {
        // A subscription refusal is not a reason to drop the registration
        // while the command can still write; the cap remains the backstop.
      }
    }
    const heartbeat = setInterval(() => { void refreshBackgroundRegistration(binding) }, jobHeartbeatMs)
    heartbeat.unref?.()
    binding.heartbeat = heartbeat
    const cap = setTimeout(finish, jobMaxLifetimeMs)
    cap.unref?.()
    binding.maxLifetime = cap
    return true
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
      entry.timer = timer
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
        cancelQueue.enqueue(registrationId)
        release()
      }
    }
  })

  ctx.on('tools/execute', async (exec: ToolExecution, next: () => Promise<any>) => {
    const sessionId = sessionIdFor(exec.agent)
    const key = callKey(sessionId, String(exec.callId ?? ''))
    if (!pending.has(key)) return next()
    let retainedByJob = false
    try {
      const result = await dispatchChain.run(sessionId, () => next())
      const bareName = exec.name.startsWith(PHONE_TOOL_PREFIX)
        ? exec.name.slice(PHONE_TOOL_PREFIX.length)
        : exec.name
      // A bash call that the DSH job registry kept alive after this tool
      // result is no longer a normal call: its registration must outlive the
      // call until the job settles.
      const jobId = bareName === 'bash' ? backgroundJobId(result) : undefined
      if (jobId !== undefined) retainedByJob = retainBackgroundJob(key, jobId, sessionId)
      return result
    } finally {
      if (!retainedByJob) await cleanup(key)
    }
  })

  // A Worker/plugin disposal must not leave a job registration authorizing
  // writes for a Worker that no longer exists. The host's generation rotation
  // is the other half of that barrier.
  ctx.effect(() => () => {
    for (const key of [...backgroundJobs.keys()]) {
      const entry = pending.get(key)
      clearBackgroundBinding(key)
      if (entry === undefined) continue
      pending.delete(key)
      calls.delete(key)
      if (entry.timer !== undefined) clearTimeout(entry.timer)
      cancelQueue.enqueue(entry.registrationId)
      entry.release()
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
  if (ctx.tools.get(BOT_VOLATILE_CONTEXT_TOOL, exec.agent) !== undefined) return true
  // The maintainer preset deliberately hides the volatile-context marker from
  // the model surface. Its host-issued session token is the liveness evidence
  // instead: a claimed maintainer session can still register phone calls, and
  // an unclaimed one stays fail-closed.
  const sessionId = sessionIdFor(exec.agent)
  // Every host-minted restricted session (verifier and maintainer) gets the
  // same liveness evidence: a claimed session token. The verifier's allow-list
  // deliberately hides BotVolatileContext, so requiring that tool would make
  // its only bash capability unusable and leave it unable to read the records
  // the verification contract requires.
  if (restrictedPresetForSessionId(sessionId) === undefined) return false
  return (botOwnedSessions(ctx).tokenFor(sessionId)?.length ?? 0) > 0
}

export function botSessionOwned(ctx: Context, exec: Pick<ToolExecution, 'agent'>): boolean {
  return botOwnedSessions(ctx).has(sessionIdFor(exec.agent))
}

dshbotIdentityBridge.inject = ['tools']
