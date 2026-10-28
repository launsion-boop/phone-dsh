// SPDX-License-Identifier: MIT
/**
 * Concurrency and admission for Worker executions (budgets.md §3/§4).
 *
 * The phone allows at most two sub-agents, and one when the host says the
 * thermal state is `fair` (or worse). At the same time a fatal ordered-channel
 * event or a closed LIFECYCLE/FENCE admission must stop new commands at the
 * subprocess seam instead of letting them queue forever.
 *
 * Thermal pressure is a host OS signal (`budgets.md` §3), not part of the
 * `LIFECYCLE` (`0x50`) payload, whose only fields are `state`, `budget`,
 * `admission` and `reason` (`channel.md` §4.5). It therefore arrives through
 * `PDSH_THERMAL_STATE` at construction or through {@link
 * ExecutionGovernor.setThermal} after a host signal; the governor deliberately
 * does not read non-contract fields from `__PDSH_LIFECYCLE__`.
 *
 * The governor is deliberately independent of Cordis: it takes an optional
 * admission callback for tests and otherwise reads the two globals the Worker
 * entry installs (`__PDSH_LIFECYCLE__`, `__PDSH_FENCE__`) plus the ordered channel's
 * ERROR frame (`0x7F`).
 * @module @phone-dsh/dsh-subprocess-xl/governor
 */

/** Thermal states the host can report (`nominal` is the default). */
export type ThermalState = 'nominal' | 'fair' | 'serious' | 'critical'

/** Admission is closed: no new execution may start. */
export class AdmissionClosedError extends Error {
  readonly code = 'PDSH_ADMISSION_CLOSED'

  constructor(reason: string) {
    super(`subprocess-xl: admission is closed (${reason})`)
    this.name = 'AdmissionClosedError'
  }
}

/** Constructor inputs. */
export interface ExecutionGovernorOptions {
  /** Maximum concurrent executions; clamped to 1..2 (budgets.md §4). */
  readonly maxConcurrent?: number | undefined
  /** Initial thermal state; `PDSH_THERMAL_STATE` is read when omitted. */
  readonly thermal?: ThermalState | undefined
  /** Extra admission source (the lifecycle gate in production, a fake in tests). */
  readonly admission?: (() => boolean) | undefined
}

/** One queued acquirer. */
interface Waiter {
  readonly resolve: (release: () => void) => void
  readonly reject: (error: unknown) => void
  readonly signal?: AbortSignal | undefined
  onAbort?: (() => void) | undefined
}

/** Parse a thermal state from the environment. */
export function parseThermal(value: string | undefined): ThermalState {
  if (value === 'fair' || value === 'serious' || value === 'critical') return value
  return 'nominal'
}

/** The governor shared by every Worker execution. */
export class ExecutionGovernor {
  private readonly maximum: number
  private readonly admissionSource: (() => boolean) | undefined
  private thermal: ThermalState
  private active = 0
  private readonly waiters: Waiter[] = []
  private readonly cancelListeners = new Set<(reason: string) => void>()
  private closedReason: string | undefined
  private detachChannel: (() => void) | undefined

  constructor(options: ExecutionGovernorOptions = {}) {
    const configured = options.maxConcurrent ?? Number(process.env.PDSH_SUBAGENT_LIMIT ?? 2)
    this.maximum = Number.isFinite(configured)
      ? Math.max(1, Math.min(2, Math.floor(configured)))
      : 2
    this.thermal = options.thermal ?? parseThermal(process.env.PDSH_THERMAL_STATE)
    this.admissionSource = options.admission
  }

  /** Current concurrency limit (1 on fair or worse, else the configured cap). */
  get limit(): number {
    return this.thermal === 'nominal' ? this.maximum : 1
  }

  /** Current thermal state. */
  get thermalState(): ThermalState {
    return this.thermal
  }

  /** Number of executions currently holding a slot. */
  get activeCount(): number { return this.active }

  /** Number of executions waiting for a slot. */
  get waitingCount(): number { return this.waiters.length }

  /** True when a new execution may start. */
  get admissionOpen(): boolean {
    if (this.closedReason !== undefined) return false
    const globals = globalThis as {
      __PDSH_LIFECYCLE__?: { admission?: unknown }
      __PDSH_FENCE__?: { admission?: unknown }
    }
    if (globals.__PDSH_LIFECYCLE__?.admission === 'closed') return false
    if (globals.__PDSH_FENCE__?.admission === 'closed') return false
    if (this.admissionSource !== undefined) {
      try {
        return this.admissionSource()
      } catch {
        return false
      }
    }
    return true
  }

  /** Why admission closed, if it did. */
  get closed(): string | undefined { return this.closedReason }

  /** Update the thermal state from a host signal (`budgets.md` §3). */
  setThermal(state: ThermalState): void {
    this.thermal = state
    this.drain()
  }

  /** Close admission permanently for this provider lifetime. */
  close(reason: string): void {
    if (this.closedReason !== undefined) return
    this.closedReason = reason
    this.detachChannel?.()
    this.detachChannel = undefined
    const error = new AdmissionClosedError(reason)
    for (const waiter of this.waiters.splice(0)) {
      if (waiter.signal !== undefined && waiter.onAbort !== undefined) waiter.signal.removeEventListener('abort', waiter.onAbort)
      waiter.reject(error)
    }
    this.cancelExecutions(reason)
  }

  /**
   * Observe a host cancellation of in-flight work (drain / abort).
   *
   * Closing admission rejects queued waiters but says nothing about commands
   * already running: the host is waiting for them before it parks or hands
   * off. A Worker command that ignores its abort would otherwise keep the lane
   * and the drain open indefinitely.
   * @param listener - called with the cause; the runtime terminates live jobs.
   * @returns a disposer.
   */
  onCancel(listener: (reason: string) => void): () => void {
    this.cancelListeners.add(listener)
    return () => { this.cancelListeners.delete(listener) }
  }

  /** Tell every subscriber to settle its in-flight executions. */
  private cancelExecutions(reason: string): void {
    for (const listener of [...this.cancelListeners]) {
      try { listener(reason) } catch { /* a cancel subscriber cannot stop the drain */ }
    }
  }

  /**
   * Observe a fatal ERROR frame on the ordered channel. A channel that has no
   * `onFrame` face is ignored (this is also the desktop transport case).
   * @param channel - the client the Worker entry installed.
   */
  watchChannel(channel: unknown): void {
    this.detachChannel?.()
    this.detachChannel = undefined
    const candidate = channel as {
      onFrame?: (handler: (frame: { type: number; payload: Uint8Array }) => void) => () => void
    } | undefined
    if (typeof candidate?.onFrame !== 'function') return
    this.detachChannel = candidate.onFrame((frame) => {
      if (frame.type === 0x7f) {
        let code = 'channel_error'
        try {
          const payload = JSON.parse(new TextDecoder().decode(frame.payload)) as { code?: unknown }
          if (typeof payload.code === 'string' && payload.code !== '') code = payload.code
        } catch {
          // Keep the generic code; the channel layer reports the detail.
        }
        this.close(code)
        return
      }
      // 0x50 LIFECYCLE and 0x70 FENCE carry the host's admission switch. A
      // closed admission is the drain/abort signal: no new command starts and
      // the ones running are settled instead of being waited for.
      if (frame.type !== 0x50 && frame.type !== 0x70) return
      let admission: unknown
      try {
        admission = (JSON.parse(new TextDecoder().decode(frame.payload)) as { admission?: unknown }).admission
      } catch {
        return
      }
      if (admission === 'closed') {
        this.cancelExecutions(frame.type === 0x50 ? 'LIFECYCLE admission closed' : 'FENCE admission closed')
      }
    })
  }

  /**
   * Acquire one execution slot.
   * @param signal - cancels a queued waiter.
   * @returns an idempotent release function.
   * @throws {AdmissionClosedError} when admission is closed.
   */
  async acquire(signal?: AbortSignal): Promise<() => void> {
    if (!this.admissionOpen) throw new AdmissionClosedError(this.closedReason ?? 'lifecycle admission')
    if (signal?.aborted === true) throw signal.reason instanceof Error ? signal.reason : new Error('subprocess-xl: execution aborted')
    if (this.active < this.limit) {
      this.active += 1
      return this.releaser()
    }
    return await new Promise<() => void>((resolve, reject) => {
      const waiter: Waiter = {
        resolve: (release) => {
          if (waiter.signal !== undefined && waiter.onAbort !== undefined) waiter.signal.removeEventListener('abort', waiter.onAbort)
          resolve(release)
        },
        reject,
        signal,
      }
      if (signal !== undefined) {
        waiter.onAbort = (): void => {
          const index = this.waiters.indexOf(waiter)
          if (index >= 0) this.waiters.splice(index, 1)
          reject(signal.reason instanceof Error ? signal.reason : new Error('subprocess-xl: execution aborted'))
        }
        signal.addEventListener('abort', waiter.onAbort, { once: true })
      }
      this.waiters.push(waiter)
    })
  }

  /** Build the idempotent release function for one granted slot. */
  private releaser(): () => void {
    let released = false
    return () => {
      if (released) return
      released = true
      this.active = Math.max(0, this.active - 1)
      this.drain()
    }
  }

  /** Grant queued slots while capacity and admission remain. */
  private drain(): void {
    while (this.waiters.length > 0 && this.active < this.limit) {
      if (!this.admissionOpen) {
        const error = new AdmissionClosedError(this.closedReason ?? 'lifecycle admission')
        for (const waiter of this.waiters.splice(0)) {
          if (waiter.signal !== undefined && waiter.onAbort !== undefined) waiter.signal.removeEventListener('abort', waiter.onAbort)
          waiter.reject(error)
        }
        return
      }
      const waiter = this.waiters.shift()
      if (waiter === undefined) return
      this.active += 1
      waiter.resolve(this.releaser())
    }
  }
}

export default ExecutionGovernor
