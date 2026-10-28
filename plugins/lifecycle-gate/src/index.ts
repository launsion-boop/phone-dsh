// SPDX-License-Identifier: MIT
/**
 * `lifecycle-gate`: stops DSH from starting new work while the host app is out
 * of background execution budget, and lets it continue cleanly afterwards.
 *
 * Gate points (both run AFTER the session checkpoint, so everything the loop
 * logged so far is durable before the harness parks):
 * - `llm/stream`: before a model request is sent.
 * - `tools/execute`: before a top-level tool body runs.
 * `agent/pre-step` is deliberately not used: a pre-step rejection closes the
 * turn without a step, and a parked pre-step listener holds the turn open in a
 * state the inbox cannot advance.
 *
 * Sources, in preference order: the Worker's `__PDSH_LIFECYCLE__` update push
 * (with `__PDSH_FENCE__` admission), the bridge's `GET /v1/lifecycle` long-poll
 * (fallback when the push is not installed), a control file whose body is
 * `run` / `pause` / `stop` (or JSON), `PDSH_LIFECYCLE_STATE` at boot, and
 * `ctx.xlLifecycle.set()` for an in-process host channel. The most restrictive
 * source wins. A fatal channel error closes admission (stops new work).
 *
 * States (channel.md §4.5): `run` admits; `pause` parks the caller until
 * `run` (work already in flight is not interrupted); `stop` refuses: the model
 * request fails with a non-retryable error and the tool call returns an error
 * result without running, so the turn ends and the host can continue it later
 * with a new message.
 *
 * The loop watchdog refuses the N-th identical consecutive tool call (same
 * name and arguments, i.e. the same idem_key inputs); the default N is 3.
 * @module @phone-dsh/dsh-lifecycle-gate
 */

import { readFileSync, watchFile, unwatchFile } from 'node:fs'
import { Context, Service } from '@deepseek-ai/cordis'
import schema from '@deepseek-ai/schemastery'
import { LlmError } from '@deepseek-ai/dsh-llm'
import type { StreamChunk } from '@deepseek-ai/dsh-llm'
import type { ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import type {} from '@deepseek-ai/dsh-session'
import type {} from '@phone-dsh/dsh-exec-bridge'
import {
  DEFAULT_THRESHOLDS, Gate, LifecycleRefusedError, LoopWatchdog, applyThresholds, installGlobalPush, parseSignal,
} from './gate.ts'
import type { BudgetThreshold, GateSnapshot, GateState, WatchdogDecision } from './gate.ts'

export {
  DEFAULT_THRESHOLDS, Gate, LifecycleRefusedError, LoopWatchdog, applyThresholds, installGlobalPush, parseSignal,
} from './gate.ts'
export type { BudgetThreshold, GateSnapshot, GateState, WatchdogDecision } from './gate.ts'

export interface LifecyclePushPayload {
  readonly state?: string
  readonly budget?: number | bigint
  readonly admission?: 'open' | 'closed'
  readonly reason?: string
}

export interface FencePushPayload {
  readonly fence?: unknown
  readonly admission?: 'open' | 'closed'
}

export interface Config {
  /** Long-poll the exec bridge's lifecycle endpoint when the push channel is absent. */
  bridge: boolean
  /** Control file polled for `run` / `pause` / `stop`. */
  file?: string
  /** Poll interval for the control file. */
  filePollMs: number
  /** Treat a reported positive `budget_ms` below this as `pause` (0 disables). */
  minBudgetMs: number
  /** Budget threshold table; merged with `minBudgetMs` when that is positive. */
  thresholds: BudgetThreshold[]
  /** Refuse repeated identical tool calls. */
  watchdog: boolean
  /** Consecutive identical calls allowed + 1: the N-th call is refused. */
  watchdogLimit: number
}

declare module '@deepseek-ai/cordis' {
  interface Context { xlLifecycle: XlLifecycle }
}

const RANK: Record<GateState, number> = { run: 0, pause: 1, stop: 2 }

export class XlLifecycle extends Service {
  static inject = ['sessions']
  static Config: schema<Config> = schema.object({
    bridge: schema.boolean().default(true),
    file: schema.string(),
    filePollMs: schema.number().default(250),
    minBudgetMs: schema.number().default(0),
    thresholds: schema.array(schema.object({
      atOrBelowMs: schema.number().required(),
      state: schema.union(['run', 'pause', 'stop'] as const).required(),
      reason: schema.string().required(),
    })).default([...DEFAULT_THRESHOLDS]),
    watchdog: schema.boolean().default(true),
    watchdogLimit: schema.number().default(3),
  }) as schema<Config>

  readonly gate = new Gate()
  readonly watchdog: LoopWatchdog
  private readonly sources = new Map<string, GateSnapshot>()
  private readonly config: Config
  private lifecycleAdmission: 'open' | 'closed' = 'open'
  private fenceAdmission: 'open' | 'closed' | undefined
  private channelDetach: (() => void) | undefined
  private readonly disposers: Array<() => void> = []

  constructor(ctx: Context, config: Config) {
    super(ctx, 'xlLifecycle')
    this.config = config
    this.watchdog = new LoopWatchdog(config.watchdogLimit ?? 3)
    const logger = ctx.logger('lifecycle-gate')
    this.gate.onChange(snapshot => { logger.info('state %s%s', snapshot.state, snapshot.reason === undefined ? '' : ` (${snapshot.reason})`) })

    // Boot-time state from the environment (a host that starts Node already out of budget).
    const initial = parseSignal(process.env.PDSH_LIFECYCLE_STATE ?? '')
    if (initial !== undefined) this.update('env', initial)

    // Push channels: LIFECYCLE and FENCE are assignments to worker globals.
    this.disposers.push(installGlobalPush<LifecyclePushPayload>('__PDSH_LIFECYCLE__', value => { this.acceptLifecycle(value) }))
    this.disposers.push(installGlobalPush<FencePushPayload>('__PDSH_FENCE__', value => { this.acceptFence(value) }))
    // The channel itself may be installed after this plugin; observe the
    // assignment so a fatal ERROR still closes admission.
    this.disposers.push(installGlobalPush<unknown>('__PDSH_CHANNEL__', value => { this.observeChannel(value) }))

    if (config.file !== undefined && config.file !== '') this.watchFile(config.file)
    if (config.bridge && !this.pushAvailable()) this.pollBridge()

    ctx.effect(() => () => {
      this.channelDetach?.()
      this.channelDetach = undefined
      for (const dispose of this.disposers.splice(0)) dispose()
    }, 'lifecycle-gate sources')

    ctx.on('llm/stream', (options, next): AsyncIterable<StreamChunk> => {
      const session = options.sessionId === undefined ? undefined : ctx.sessions.get(options.sessionId)
      const gate = this.gate
      return (async function* (): AsyncIterable<StreamChunk> {
        if (session !== undefined) await ctx.sessions.flush(session)
        try {
          await gate.admit(options.signal)
        } catch (error) {
          // A non-retryable structured code: llm-retry must not spin on a refusal.
          if (error instanceof LifecycleRefusedError) throw new LlmError(error.message, error.code, { cause: error })
          throw error
        }
        yield* next()
      })()
    })

    ctx.on('tools/execute', async (exec, next): Promise<ToolExecutionResult> => {
      if (exec.agent === undefined || exec.parent !== undefined) return next()
      await ctx.sessions.flush(exec.agent.session)
      try {
        await this.gate.admit(exec.signal)
      } catch (error) {
        if (!(error instanceof LifecycleRefusedError)) throw error
        return {
          isError: true,
          content: [{ type: 'text', text: `Error: ${error.message}` }],
          error: { message: error.message, info: { name: error.name, code: error.code } },
        }
      }
      if (config.watchdog !== false) {
        const decision = this.watchdog.observe(exec.name, exec.arguments)
        if (!decision.allowed) {
          const message = loopMessage(exec.name, decision)
          ctx.logger('lifecycle-gate').warn('%s', message)
          return {
            isError: true,
            content: [{ type: 'text', text: `Error: ${message}` }],
            error: { message, info: { name: 'LoopWatchdogError', code: 'PDSH_LOOP_WATCHDOG' } },
          }
        }
      }
      return next()
    })
  }

  /** In-process host control (e.g. a nodejs-mobile channel message). */
  set(state: GateState, reason?: string): void {
    this.update('host', { state, ...reason === undefined ? {} : { reason } })
  }

  get state(): GateSnapshot { return this.gate.current }

  /** Admission composed from the last LIFECYCLE and FENCE pushes. */
  get admission(): 'open' | 'closed' {
    return this.lifecycleAdmission === 'closed' || this.fenceAdmission === 'closed' ? 'closed' : 'open'
  }

  /** A fatal sink error closes admission: no new work is started. */
  sinkFailed(code: string, reason = 'the ordered-channel sink failed'): void {
    this.update('sink', { state: 'stop', reason: `${code}: ${reason}` })
  }

  /** Feed one LIFECYCLE payload (also used by tests without the global push). */
  acceptLifecycle(value: LifecyclePushPayload | undefined): void {
    if (value === undefined || typeof value !== 'object') return
    const state = value.state === 'pause' || value.state === 'stop' ? value.state : 'run'
    const budget = typeof value.budget === 'bigint' ? Number(value.budget) : value.budget
    if (value.admission === 'open' || value.admission === 'closed') this.lifecycleAdmission = value.admission
    this.update('push', {
      state,
      ...value.reason === undefined ? {} : { reason: value.reason },
      ...typeof budget === 'number' && Number.isFinite(budget) ? { budgetMs: budget } : {},
    })
  }

  /** Feed one FENCE payload's admission switch. */
  acceptFence(value: FencePushPayload | undefined): void {
    if (value === undefined || typeof value !== 'object') return
    if (value.admission === 'open' || value.admission === 'closed') this.fenceAdmission = value.admission
    this.update('fence', { state: 'run' })
  }

  private update(source: string, snapshot: GateSnapshot): void {
    this.sources.set(source, this.applyBudget(snapshot))
    this.gate.set(this.effective())
  }

  private applyBudget(snapshot: GateSnapshot): GateSnapshot {
    const thresholds = this.thresholds()
    const withMinimum = snapshot.state === 'run' && snapshot.budgetMs !== undefined && snapshot.budgetMs > 0 && this.config.minBudgetMs > 0 && snapshot.budgetMs < this.config.minBudgetMs
      ? { ...snapshot, state: 'pause' as const, reason: snapshot.reason ?? 'background budget below minimum' }
      : snapshot
    return applyThresholds(withMinimum, thresholds)
  }

  private thresholds(): readonly BudgetThreshold[] {
    const configured = this.config.thresholds ?? []
    if (this.config.minBudgetMs <= 0) return configured.length > 0 ? configured : DEFAULT_THRESHOLDS
    return [{ atOrBelowMs: this.config.minBudgetMs, state: 'pause', reason: 'background budget below minimum' }, ...configured]
  }

  private effective(): GateSnapshot {
    let winner: GateSnapshot = { state: 'run' }
    for (const candidate of this.sources.values()) if (RANK[candidate.state] > RANK[winner.state]) winner = candidate
    if (this.admission === 'closed' && winner.state === 'run') {
      return { state: 'pause', reason: 'admission_closed', ...winner.budgetMs === undefined ? {} : { budgetMs: winner.budgetMs } }
    }
    return winner
  }

  private pushAvailable(): boolean {
    return typeof globalThis.__PDSH_CHANNEL__ !== 'undefined'
  }

  private watchFile(path: string): void {
    const read = (): void => {
      let text: string
      try { text = readFileSync(path, 'utf8') } catch { this.update('file', { state: 'run' }); return }
      const parsed = parseSignal(text)
      if (parsed !== undefined) this.update('file', parsed)
    }
    read()
    watchFile(path, { interval: this.config.filePollMs, persistent: false }, read)
    this.disposers.push(() => { unwatchFile(path, read) })
  }

  /** Fatal channel ERROR closes admission (channel.md §10). */
  private observeChannel(channel: unknown): void {
    this.channelDetach?.()
    this.channelDetach = undefined
    const candidate = channel as
      | { onFrame?: (handler: (frame: { type: number; payload: Uint8Array }) => void) => () => void }
      | undefined
    if (candidate?.onFrame === undefined) return
    this.channelDetach = candidate.onFrame((frame) => {
      if (frame.type !== 0x7f) return
      let code = 'channel_error'
      try {
        const payload = JSON.parse(new TextDecoder().decode(frame.payload)) as { code?: unknown }
        if (typeof payload.code === 'string') code = payload.code
      } catch {
        // Keep the generic code; the host's protocol layer reports the detail.
      }
      this.sinkFailed(code)
    })
  }

  /** Long-poll the bridge's lifecycle endpoint whenever `ctx.xlExecBridge` is mounted (fallback source). */
  private pollBridge(): void {
    this.ctx.inject(['xlExecBridge'], (child) => {
      const stop = new AbortController()
      child.effect(() => () => { stop.abort() }, 'lifecycle-gate bridge poll')
      const bridge = child.xlExecBridge
      void (async () => {
        await bridge.ready
        if (bridge.hello.capabilities.lifecycle !== true) return
        let since: number | undefined
        while (!stop.signal.aborted) {
          try {
            const state = await bridge.client.lifecycle(since, 25_000, stop.signal)
            since = state.rev
            this.update('bridge', {
              state: state.state,
              ...state.reason === undefined ? {} : { reason: state.reason },
              ...state.budget_ms === undefined ? {} : { budgetMs: state.budget_ms },
            })
          } catch {
            if (stop.signal.aborted) return
            await new Promise(resolve => setTimeout(resolve, 1000))
          }
        }
      })()
    })
  }
}

function loopMessage(tool: string, decision: WatchdogDecision): string {
  const ordinal = decision.count === 3 ? '3rd' : `${decision.count}th`
  return `Loop watchdog: the ${ordinal} consecutive ${tool} call has identical arguments to the previous `
    + `${decision.count - 1} call(s); the harness refused it. Change the command/file or stop the loop. `
    + `Limit: ${decision.limit} identical calls (same idem_key inputs).`
}

export default XlLifecycle
