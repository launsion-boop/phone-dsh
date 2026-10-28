// SPDX-License-Identifier: MIT
/**
 * Worker-native workflow engine for the phone DSH path.
 *
 * The standard preset names `@deepseek-ai/dsh-workflow-ptc`; its official
 * provider needs a PTC runtime backed by a child Node process, which the phone
 * Worker intentionally does not have. This package is installed for that exact
 * specifier and keeps the official workflow contract:
 *
 *  - `validateMeta` is the official implementation from the pinned checkout;
 *  - the official `WorkflowExecution` compiles and drives the script, inside a
 *    dedicated workflow Worker (never the DSH Worker's global), and
 *  - every `agent()` call crosses a structured, schema-checked child bridge
 *    into the real `ctx.subagents`, so the child keeps the parent Session,
 *    working directory, tool permissions, and model identity.
 *
 * The parent Worker performs only a syntax parse. The workflow isolate owns
 * script execution and is terminated on cancellation or its synchronous
 * deadline; child agents stay in the parent and are disposed there.
 * @module @phone-dsh/dsh-workflow-worker
 */

import { randomUUID } from 'node:crypto'
import { availableParallelism } from 'node:os'
import * as vm from 'node:vm'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { ContentBlock } from '@deepseek-ai/dsh-llm'
import type { SessionId } from '@deepseek-ai/dsh-session'
import type { ObjectJsonSchema } from '@deepseek-ai/dsh-tools'
import WorkflowEngine, { WorkflowError, WorkflowRunId } from '@deepseek-ai/dsh-workflow'
import type {
  WorkflowAgentEndInfo, WorkflowAgentInfo, WorkflowMeta, WorkflowResult, WorkflowResultInfo,
  WorkflowRun, WorkflowRunInfo, WorkflowStartRequest,
} from '@deepseek-ai/dsh-workflow'
import type { ChildResult, ChildStartRequest, WorkerLimits } from '@deepseek-ai/dsh-workflow-ptc'
import { validateMeta } from '@deepseek-ai/dsh-workflow-ptc/src/meta.ts'
import type {} from '@deepseek-ai/dsh-subagent'
import type {} from '@deepseek-ai/dsh-working-directory'
import z from '@deepseek-ai/schemastery'
import { createDefaultIsolatePort, type IsolatePort } from './isolate-client.ts'
import { budgetDiagnostic } from './budget-error.ts'
import { renderError, type IsolateToParent, type ParentToIsolate } from './protocol.ts'

export { validateMeta } from '@deepseek-ai/dsh-workflow-ptc/src/meta.ts'

/** Plugin configuration, mirroring the official engine's deployment knobs. */
export interface Config {
  /** The `ctx.subagents` provider children run on (default `spawn`). */
  provider?: string
  /** Concurrent `agent()` ceiling; `0` (the default) resolves from CPU count. */
  maxConcurrentAgents?: number
  /** Total `agent()` calls one run may start — the runaway-loop backstop (default 1000). */
  maxTotalAgents?: number
  /** Items accepted by a single `parallel()`/`pipeline()` call (default 4096). */
  maxItemsPerCall?: number
  /** Synchronous-slice deadline; the parent Worker terminates the isolate at expiry (default 5000 ms). */
  syncTimeoutMs?: number
}

type ResolvedConfig = Required<Config>

/** A body that still carries the Claude Code-style meta header is rejected. */
const META_STATEMENT = /^\s*export\s+const\s+meta\b/

/**
 * Reject invalid JavaScript before publishing a workflow run. Compilation only:
 * the script object is discarded and nothing executes in the DSH Worker.
 * @param body - workflow script text.
 * @param name - validated workflow name for diagnostics.
 */
function assertBodyParses(body: string, name: string): void {
  if (META_STATEMENT.test(body)) {
    throw new WorkflowError(
      'workflow meta rides the `meta` request field, not the script: remove the `export const meta = {...}` statement from the body',
      'SCRIPT_PARSE',
    )
  }
  try {
    void new vm.Script(`(async () => {\n${body}\n})()`, { filename: `workflow:${name}`, lineOffset: -1 })
  } catch (error: unknown) {
    throw new WorkflowError(`workflow script does not parse: ${String(error)}`, 'SCRIPT_PARSE', { cause: error })
  }
}

/** Resolve one run's child provider before publishing work. */
function resolveSubagentProvider(ctx: Context, configured: string, override: string | undefined): string {
  const provider = override ?? configured
  if (provider.length === 0 || provider !== provider.trim()) {
    throw new WorkflowError('workflow subagentProvider must be a non-empty normalized string', 'INVALID_ARGUMENT')
  }
  if (ctx.subagents.getProvider(provider) === undefined) {
    throw new WorkflowError(`no subagent provider registered for "${provider}"`, 'AGENT_START')
  }
  return provider
}

/** Resolve one run's total-child cap against the engine ceiling. */
function resolveMaxTotalAgents(requested: number | undefined, ceiling: number): number {
  if (requested === undefined) return ceiling
  if (!Number.isSafeInteger(requested) || requested < 1) {
    throw new WorkflowError('workflow maxTotalAgents must be a positive safe integer', 'INVALID_ARGUMENT')
  }
  if (requested > ceiling) {
    throw new WorkflowError(
      `workflow maxTotalAgents ${requested} exceeds the engine ceiling ${ceiling}`,
      'INVALID_ARGUMENT',
    )
  }
  return requested
}

/** A JSON child result is the official runtime's `ChildResult` without host classes. */
function mapChildResult(result: { readonly output: readonly ContentBlock[]; readonly structured?: unknown; readonly stopReason: string }): ChildResult {
  return {
    output: [...result.output],
    stopReason: result.stopReason,
    ...result.structured === undefined ? {} : { structured: result.structured },
  }
}

/** Deferred without `Promise.withResolvers` (absent on iOS 17.0-17.3). */
interface Deferred<T> {
  readonly promise: Promise<T>
  readonly resolve: (value: T) => void
  readonly reject: (reason: unknown) => void
}

/** Create one deferred. */
function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((accept, refuse) => { resolve = accept; reject = refuse })
  return { promise, resolve, reject }
}

/** The parent-side record of one child agent. */
interface ChildRecord {
  readonly callId: number
  readonly run: { readonly childId: SessionId; readonly result: Promise<{ readonly output: readonly ContentBlock[]; readonly structured?: unknown; readonly stopReason: string }>; dispose(): Promise<void> }
  readonly result: Promise<ChildResult>
  disposal?: Promise<void>
}

/** The official observer surface, mirrored inside the parent. */
interface RunObserver {
  phase(title: string): void
  log(message: string): void
  agentStart(info: WorkflowAgentInfo): void
  agentEnd(info: WorkflowAgentEndInfo): void
}

/**
 * One holder-owned workflow run. The script lives in the isolate; children,
 * cancellation and cleanup live here so they keep the real Session and tool
 * authority.
 */
class WorkerWorkflowRun implements WorkflowRun {
  readonly result: Promise<WorkflowResult>
  readonly id: ReturnType<typeof WorkflowRunId>
  readonly meta: WorkflowMeta
  private readonly ctx: Context
  private readonly subagents: Context['subagents']
  private readonly parent: Agent
  private readonly init: { readonly meta: WorkflowMeta; readonly body: string; readonly args?: unknown; readonly limits: WorkerLimits }
  private readonly provider: string
  private readonly observer: RunObserver
  private readonly controller = new AbortController()
  private readonly children = new Map<number, ChildRecord>()
  private readonly liveAgents = new Map<number, WorkflowAgentInfo>()
  private readonly pendingStarts = new Set<Promise<void>>()
  private readonly done = deferred<void>()
  private readonly settled = deferred<WorkflowResult>()
  private readonly cwd: Promise<string>
  private readonly externalSignal: AbortSignal | undefined
  private readonly externalAbort: () => void
  private port: IsolatePort | undefined
  private watchdog: ReturnType<typeof setTimeout> | undefined
  private bootWatchdog: ReturnType<typeof setTimeout> | undefined
  private outcome: WorkflowResult | undefined
  private cancelReason: string | undefined
  private started = 0
  private finished = false

  constructor(
    ctx: Context,
    subagents: Context['subagents'],
    id: ReturnType<typeof WorkflowRunId>,
    meta: WorkflowMeta,
    parent: Agent,
    init: { readonly meta: WorkflowMeta; readonly body: string; readonly args?: unknown; readonly limits: WorkerLimits },
    provider: string,
    observer: RunObserver,
    signal?: AbortSignal,
  ) {
    this.ctx = ctx
    this.subagents = subagents
    this.id = id
    this.meta = meta
    this.parent = parent
    this.init = init
    this.provider = provider
    this.observer = observer
    this.externalSignal = signal
    this.externalAbort = () => { this.cancel('workflow signal aborted') }
    if (signal?.aborted) this.externalAbort()
    else signal?.addEventListener('abort', this.externalAbort, { once: true })
    this.cwd = ctx.workingDirectory.ensure(parent, this.controller.signal)
    this.cwd.catch(() => { /* consumed by startChild's guarded await */ })
    this.result = this.settled.promise
    void this.run()
  }

  /**
   * Stop the isolate immediately and dispose every published or starting child.
   * @param reason - human-readable cancellation cause; first request wins.
   */
  cancel(reason = 'workflow cancelled'): void {
    if (this.finished || this.cancelReason !== undefined) return
    this.cancelReason = reason
    this.controller.abort(reason)
    this.finish({ value: null, stopReason: 'cancelled', error: `workflow run cancelled: ${reason}`, agentsStarted: this.started })
  }

  /**
   * Cancel unfinished work and await the isolate plus child cleanup.
   * @returns one shared completion promise for repeated disposal calls.
   */
  dispose(): Promise<void> {
    this.cancel('workflow disposed')
    return this.result.then(() => {})
  }

  /** Set up the isolate and wait for its terminal message or a stop request. */
  private async run(): Promise<void> {
    try {
      if (this.finished) return
      const port = createDefaultIsolatePort()
      this.port = port
      port.onMessage((message) => { this.onMessage(message) })
      port.onError((error) => {
        this.finish({
          value: null,
          stopReason: 'error',
          error: `workflow isolate failed: ${renderError(error)}`,
          agentsStarted: this.started,
        })
      })
      port.onExit((exit) => {
        this.finish({
          value: null,
          stopReason: 'error',
          error: `workflow isolate exited before completing${exit.code === undefined ? '' : ` (code ${String(exit.code)})`}`,
          agentsStarted: this.started,
        })
      })
      if (this.finished || this.controller.signal.aborted) {
        await port.terminate()
        return
      }
      port.postMessage({
        type: 'run',
        meta: this.meta,
        body: this.init.body,
        ...this.init.args === undefined ? {} : { args: this.init.args },
        limits: this.init.limits,
      })
      this.armBootWatchdog()
      await this.done.promise
    } catch (error: unknown) {
      this.finish({
        value: null,
        stopReason: 'error',
        error: `workflow isolate failed: ${renderError(error)}`,
        agentsStarted: this.started,
      })
    }
  }

  /** Bound isolate/WASM boot separately from the script's execution budget. */
  private armBootWatchdog(): void {
    if (this.finished) return
    this.clearBootWatchdog()
    this.bootWatchdog = setTimeout(() => {
      this.finish({
        value: null,
        stopReason: 'error',
        error: 'workflow isolate did not become ready within 30s',
        agentsStarted: this.started,
      })
    }, 30_000)
  }

  /** Stop the boot timer once the isolate has loaded its realm. */
  private clearBootWatchdog(): void {
    if (this.bootWatchdog !== undefined) {
      clearTimeout(this.bootWatchdog)
      this.bootWatchdog = undefined
    }
  }

  /**
   * Arm the no-host-activity deadline. The isolate is allowed to wait on a
   * child for as long as the child takes; this timer covers a segment that is
   * supposed to make progress locally, including a loop after an `await`.
   */
  private armWatchdog(): void {
    if (this.finished || this.init.limits.syncTimeoutMs <= 0) return
    this.clearWatchdog()
    // The isolated QuickJS realm enforces the guest deadline itself; this
    // parent timer is a backstop for a wedged host half. The small grace lets
    // the realm report its precise diagnostic first while still hard-killing
    // anything that never yields.
    this.watchdog = setTimeout(() => {
      this.failSyncDeadline()
    }, this.init.limits.syncTimeoutMs + 250)
  }

  /** The synchronous/activity deadline expired: kill the isolate, never just log. */
  private failSyncDeadline(): void {
    if (this.finished) return
    this.finish({
      value: null,
      stopReason: 'error',
      error: budgetDiagnostic(this.init.limits.syncTimeoutMs),
      agentsStarted: this.started,
    })
  }

  /** Dispatch one isolate message. */
  private onMessage(message: unknown): void {
    if (this.finished) return
    if (typeof message !== 'object' || message === null || typeof (message as { type?: unknown }).type !== 'string') return
    const tagged = message as IsolateToParent
    switch (tagged.type) {
      case 'ready':
        this.clearBootWatchdog()
        this.armWatchdog()
        break
      case 'sync-yield':
        this.armWatchdog()
        break
      case 'phase':
        this.observer.phase(tagged.title)
        this.armWatchdog()
        break
      case 'log':
        this.observer.log(tagged.message)
        this.armWatchdog()
        break
      case 'agent-start':
        // The official execution emits this immediately before awaiting the
        // child's result: it starts a host wait, not local computation.
        this.liveAgents.set(tagged.info.seq, tagged.info)
        this.observer.agentStart(tagged.info)
        this.clearWatchdog()
        break
      case 'agent-end':
        // The official execution emits this after the child settled and before
        // the script continues locally; local computation is covered again.
        // Only a live start may pair, so a duplicate/late end cannot be emitted.
        if (!this.liveAgents.delete(tagged.info.seq)) break
        this.observer.agentEnd(tagged.info)
        this.armWatchdog()
        break
      case 'child-start':
        // The script is now waiting on the parent-controlled child, whose
        // duration is not the script's computation budget.
        this.clearWatchdog()
        this.trackStart(tagged.callId, tagged.request)
        break
      case 'child-result':
        this.clearWatchdog()
        this.track(this.replyChildResult(tagged.callId))
        break
      case 'child-dispose':
        this.clearWatchdog()
        this.track(this.replyChildDisposed(tagged.callId))
        break
      case 'done':
        this.finish(tagged.result)
        break
      case 'fatal':
        this.finish({
          value: null,
          stopReason: 'error',
          error: tagged.error,
          agentsStarted: this.started,
        })
        break
    }
  }

  /** Track one async response without changing its rejection into an unhandled one. */
  private track(task: Promise<void>): void {
    void task.catch((error: unknown) => {
      this.ctx.logger.warn(`workflow-worker: ${renderError(error)}`)
    })
  }

  /** Track one in-flight child start so cleanup can await it. */
  private trackStart(callId: number, request: ChildStartRequest): void {
    // The official runtime counts an `agent()` attempt when it starts, even if
    // the provider then refuses it; child-start carries that 1-based attempt.
    this.started = Math.max(this.started, callId)
    const task = this.startChild(callId, request)
    this.pendingStarts.add(task)
    void task.then(
      () => { this.pendingStarts.delete(task) },
      () => { this.pendingStarts.delete(task) },
    )
    this.track(task)
  }

  /** Start one child through the real `ctx.subagents` seam. */
  private async startChild(callId: number, request: ChildStartRequest): Promise<void> {
    try {
      this.controller.signal.throwIfAborted()
      const cwd = await this.cwd
      this.controller.signal.throwIfAborted()
      // `request.provider` is the script's LLM provider override, not the
      // subagent backend. The backend always stays the engine-configured
      // provider validated at start.
      const provider = this.provider
      if (this.subagents.getProvider(provider) === undefined) {
        throw new Error(`no subagent provider registered for "${provider}"`)
      }
      const activation = await this.subagents.startActivation({
        provider,
        label: `${this.meta.name} child ${String(callId)}`,
        delivery: 'caller',
        signal: this.controller.signal,
        request: {
          cwd,
          prompt: [{ type: 'text', text: request.prompt }],
          parent: this.parent,
          ...request.schema === undefined ? {} : { outputSchema: request.schema },
          ...request.provider === undefined && request.model === undefined ? {} : {
            agentOptions: {
              ...request.provider === undefined ? {} : { provider: request.provider },
              ...request.model === undefined ? {} : { model: request.model },
            },
          },
        },
      })
      if (this.controller.signal.aborted || this.finished) {
        await activation.dispose()
        this.send({ type: 'child-start-failed', callId, error: 'workflow cancelled during child startup' })
        return
      }
      const result = activation.result.then(mapChildResult)
      result.catch(() => { /* consumed through the explicit child-result request */ })
      const record: ChildRecord = {
        callId,
        run: activation,
        result,
      }
      this.children.set(callId, record)
      this.send({ type: 'child-started', callId, childId: activation.childId })
    } catch (error: unknown) {
      this.send({ type: 'child-start-failed', callId, error: renderError(error) })
      this.armWatchdog()
    }
  }

  /** Reply to one child-result request. */
  private async replyChildResult(callId: number): Promise<void> {
    const record = this.children.get(callId)
    if (record === undefined) {
      this.send({ type: 'child-result-failed', callId, error: `workflow child ${String(callId)} is not active` })
      return
    }
    try {
      const result = await record.result
      this.send({ type: 'child-result-ok', callId, result })
    } catch (error: unknown) {
      this.send({ type: 'child-result-failed', callId, error: renderError(error) })
    } finally {
      this.armWatchdog()
    }
  }

  /** Dispose one child and acknowledge the isolate. */
  private async replyChildDisposed(callId: number): Promise<void> {
    const record = this.children.get(callId)
    if (record !== undefined) await this.disposeChild(record)
    this.send({ type: 'child-disposed', callId })
    this.armWatchdog()
  }

  /** Idempotent child disposal. */
  private disposeChild(record: ChildRecord): Promise<void> {
    record.disposal ??= Promise.resolve().then(() => record.run.dispose()).catch((error: unknown) => {
      this.ctx.logger.warn(`workflow-worker: child dispose failed: ${renderError(error)}`)
    }).finally(() => {
      this.children.delete(record.callId)
    })
    return record.disposal
  }

  /** Post one message to the isolate, ignoring a torn-down port. */
  private send(message: ParentToIsolate): void {
    try {
      this.port?.postMessage(message)
    } catch (error: unknown) {
      // A terminated Worker cannot receive replies; cleanup still owns the
      // child, so this is a teardown race rather than a workflow failure.
      this.ctx.logger.warn(`workflow-worker: isolate message dropped: ${renderError(error)}`)
    }
  }

  /** Stop once; cleanup precedes result settlement and `workflow/end`. */
  private finish(outcome: WorkflowResult): void {
    if (this.finished) return
    this.finished = true
    this.outcome = outcome
    this.clearBootWatchdog()
    this.clearWatchdog()
    // Every terminal path (completed, error, cancelled, watchdog) must stop the
    // internal signal so a late child start cannot outlive the run.
    this.controller.abort(outcome.error ?? outcome.stopReason)
    if (this.externalSignal !== undefined) {
      this.externalSignal.removeEventListener('abort', this.externalAbort)
    }
    this.done.resolve()
    void this.cleanup().then(() => { this.settled.resolve(this.outcome ?? outcome) })
  }

  /** Terminate the isolate, await every child and close the lifecycle pair. */
  private async cleanup(): Promise<void> {
    const port = this.port
    if (port !== undefined) {
      try {
        await port.terminate()
      } catch (error: unknown) {
        this.ctx.logger.warn(`workflow-worker: isolate terminate failed: ${renderError(error)}`)
      }
    }
    // A child-start may arrive (or be issued) while cleanup awaits an earlier
    // start; keep draining until the set is empty and stable. No new start can
    // be accepted after `finished`, so this terminates.
    while (this.pendingStarts.size > 0) {
      await Promise.allSettled([...this.pendingStarts])
    }
    await Promise.allSettled([...this.children.values()].map(record => this.disposeChild(record)))
    for (const info of this.liveAgents.values()) {
      this.observer.agentEnd({ ...info, outcome: 'cancelled' })
    }
    this.liveAgents.clear()
  }

  /** Clear the synchronous-slice watchdog. */
  private clearWatchdog(): void {
    if (this.watchdog !== undefined) {
      clearTimeout(this.watchdog)
      this.watchdog = undefined
    }
  }
}

/**
 * The Worker-native workflow engine. `start()` validates and publishes a run;
 * all failures before publication throw synchronously and all failures after
 * it resolve through `result` (which never rejects).
 */
class WorkerWorkflowEngine extends WorkflowEngine {
  static inject = ['subagents', 'workingDirectory']

  static Config: z<Config> = z.object({
    provider: z.string().default('spawn'),
    maxConcurrentAgents: z.natural().default(0),
    maxTotalAgents: z.natural().min(1).default(1000),
    maxItemsPerCall: z.natural().min(1).default(4096),
    syncTimeoutMs: z.natural().min(1).default(5000),
  })

  private readonly config: ResolvedConfig

  constructor(ctx: Context, config: Config) {
    super(ctx)
    this.config = config as ResolvedConfig
  }

  /**
   * Validate and publish one workflow run.
   * @param request - script, meta, args, parent Agent and optional cancellation.
   * @returns the live run whose result never rejects.
   */
  start(request: WorkflowStartRequest): WorkflowRun {
    const meta = validateMeta(request.meta)
    assertBodyParses(request.script, meta.name)
    const provider = resolveSubagentProvider(this.ctx, this.config.provider, request.subagentProvider)
    const maxTotalAgents = resolveMaxTotalAgents(request.maxTotalAgents, this.config.maxTotalAgents)
    const id = WorkflowRunId(randomUUID())
    const info: WorkflowRunInfo = { id, meta }
    const limits: WorkerLimits = {
      maxConcurrentAgents: this.config.maxConcurrentAgents === 0
        ? Math.min(16, Math.max(1, availableParallelism() - 2))
        : this.config.maxConcurrentAgents,
      maxTotalAgents,
      maxItemsPerCall: this.config.maxItemsPerCall,
      syncTimeoutMs: this.config.syncTimeoutMs,
    }
    const observer: RunObserver = {
      phase: (title) => { this.emitWorkflowEvent('workflow/phase', info, title) },
      log: (message) => { this.emitWorkflowEvent('workflow/log', info, message) },
      agentStart: (agent) => { this.emitWorkflowEvent('workflow/agent-start', info, agent) },
      agentEnd: (agent) => { this.emitWorkflowEvent('workflow/agent-end', info, agent) },
    }
    const run = new WorkerWorkflowRun(
      this.ctx,
      this.ctx.subagents,
      id,
      meta,
      request.parent,
      {
        meta,
        body: request.script,
        ...request.args === undefined ? {} : { args: request.args },
        limits,
      },
      provider,
      observer,
      request.signal,
    )
    this.emitWorkflowEvent('workflow/start', info)
    void run.result.then((settled) => {
      const resultInfo: WorkflowResultInfo = {
        stopReason: settled.stopReason,
        ...settled.error === undefined ? {} : { error: settled.error },
        agentsStarted: settled.agentsStarted,
      }
      this.emitWorkflowEvent('workflow/end', info, resultInfo)
    })
    return run
  }
}

export default WorkerWorkflowEngine
