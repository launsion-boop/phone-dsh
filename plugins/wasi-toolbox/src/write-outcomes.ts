// SPDX-License-Identifier: MIT
/**
 * Awaitable outcomes of proxied VFS writes.
 *
 * A WASI guest's `fd_write` reaches the DSH worker as one VFS proxy request and
 * becomes an ordinary runtime VFS mutation. The mutation sink publishes it to
 * the ordered channel as one or more `VFS_MUT` frames; the host answers with a
 * level-1 `VFS_ACK` when the bytes are in its WAL, or with an `ERROR
 * VFS_REFUSED` when its own resource budget refuses the mutation. By default
 * the proxy responds as soon as the Worker memory VFS accepted the bytes, so
 * the guest never observes the host outcome: an over-limit write reports
 * success and a channel that stops acknowledging frames leaves the command
 * blocked in `flush()` with nothing bounded on the write path (G2-A09, attempt
 * 7: the interpreter sat in `fd_write` while the host stream stood still).
 *
 * This module makes one proxied write awaitable-with-outcome:
 *
 *  - {@link VfsWriteOutcomes.begin} opens a ticket around the backend call that
 *    publishes the mutation, so the sink can attach the `mseq` it emitted;
 *  - {@link VfsWriteOutcomes.noteAck} settles the ticket once a level-1 ack
 *    covers every attached `mseq`;
 *  - {@link VfsWriteOutcomes.noteRefusal} rejects it with the structured
 *    `EFBIG`/`ENOSPC`/`EDQUOT` error the refusal names (the refusal consumes no
 *    `mseq` and the channel stays open, channel.md §4.8);
 *  - {@link VfsWriteOutcomes.awaitOutcome} bounds the wait by D3's 30 s
 *    fail-loud window and rejects with a typed {@link VfsFlowControlError}
 *    without touching the channel.
 *
 * The error classes are `VfsProxyError`s, so the proxy server returns them to
 * the tool worker as an errno response and the WASI host reports the matching
 * errno (plus the actionable line on stderr) instead of blocking the
 * interpreter inside the write syscall.
 * @module @phone-dsh/dsh-wasi-toolbox/write-outcomes
 */
import { VfsProxyError } from './errors.ts'
import { formatByteLimit } from './limits.ts'

/**
 * Default bound for one proxied write's level-1 outcome wait.
 *
 * D3 (channel.md §4.8) bounds the 32 MiB unacknowledged-VFS condition with a
 * 30 s fail-loud window. The channel client starts its own ring timer on the
 * same condition; this bound is the write-path owner's backstop, so a sink or
 * an injected channel that never acknowledges cannot park a guest write
 * forever.
 */
export const DEFAULT_VFS_FLOW_CONTROL_TIMEOUT_MS = 30_000
/** Upper bound accepted for a configured flow-control wait. */
export const MAX_VFS_FLOW_CONTROL_TIMEOUT_MS = 600_000
/** Environment override for {@link DEFAULT_VFS_FLOW_CONTROL_TIMEOUT_MS}, in ms. */
export const VFS_FLOW_CONTROL_TIMEOUT_ENV = 'PDSH_VFS_FLOW_CONTROL_TIMEOUT_MS'
/** D3's worker-side unacknowledged-VFS buffer, for the failure message. */
export const DEFAULT_UNACKED_VFS_WINDOW_BYTES = 32 * 1024 * 1024

/**
 * Resolve the bounded outcome wait. An explicit value wins; otherwise the
 * process environment may set {@link VFS_FLOW_CONTROL_TIMEOUT_ENV}. Both are
 * validated `1..MAX_VFS_FLOW_CONTROL_TIMEOUT_MS` integers so a typo fails at
 * boot instead of silently restoring the unbounded wait this module removes.
 * @param explicit - configured bound in milliseconds, if any.
 * @returns the validated bound.
 * @throws {RangeError} when the value (or the environment override) is invalid.
 */
export function resolveVfsFlowControlTimeoutMs(explicit?: number): number {
  if (explicit !== undefined) {
    return validateFlowControlTimeoutMs(explicit, 'VFS flow-control timeout')
  }
  const processEnv = (globalThis as {
    process?: { env?: Record<string, string | undefined> }
  }).process?.env
  const raw = processEnv?.[VFS_FLOW_CONTROL_TIMEOUT_ENV]
  if (raw === undefined || raw === '') return DEFAULT_VFS_FLOW_CONTROL_TIMEOUT_MS
  if (!/^[0-9]+$/u.test(raw)) {
    throw new RangeError(`${VFS_FLOW_CONTROL_TIMEOUT_ENV} must be a positive integer in milliseconds`)
  }
  return validateFlowControlTimeoutMs(Number(raw), VFS_FLOW_CONTROL_TIMEOUT_ENV)
}

function validateFlowControlTimeoutMs(value: number, what: string): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > MAX_VFS_FLOW_CONTROL_TIMEOUT_MS) {
    throw new RangeError(`${what} must be an integer in 1..${String(MAX_VFS_FLOW_CONTROL_TIMEOUT_MS)} ms`)
  }
  return value
}

/** Keep a pending timeout from holding a short-lived Node test process open. */
function unrefTimer(timer: unknown): void {
  ;(timer as { unref?: () => void } | undefined)?.unref?.()
}

/** One raw system error character, so a diagnostic stays a single line. */
function oneLine(text: string): string {
  return text.replace(/[\r\n]+/gu, ' ').trim()
}

/**
 * One host resource refusal as the sink received it (channel.md §4.8).
 *
 * `code` is the node errno spelling (`EFBIG`, `ENOSPC`, `EDQUOT`), `limit` the
 * host policy bound in bytes, and `hint` the optional one-line remediation the
 * host supplied. The refusal never consumed an `mseq` and never closes the
 * ordered channel.
 */
export interface VfsWriteRefusal {
  readonly code: string
  readonly path: string
  readonly limit: number
  readonly hint?: string
}

/**
 * The model-visible text of a refused proxied write.
 *
 * It always carries the limit in exact bytes (and the MiB spelling when the
 * bound is a whole MiB) plus a split/chunk remediation, so the interpreter's
 * stderr and the tool result teach the model how to repair the write instead of
 * only naming an errno.
 * @param refusal - the host refusal.
 * @returns one line naming the code, path, limit and remediation.
 */
export function vfsWriteRefusalMessage(refusal: VfsWriteRefusal): string {
  const limit = formatByteLimit(refusal.limit)
  const hint = refusal.hint === undefined || refusal.hint.trim() === ''
    ? `the write would exceed the host file budget; split it into chunks under ${limit} and retry, or delete the file`
    : oneLine(refusal.hint)
  return `${refusal.code}: VFS refused ${refusal.path} (limit ${limit}): ${hint}`
}

/**
 * A proxied write waited past the D3 fail-loud window for its level-1 ack.
 *
 * The channel is deliberately not touched: the host may simply be slow to
 * drain, and a resource condition is not a protocol error. The write fails
 * loud as `ETIMEDOUT` (the guest sees `WASI_ERRNO.TIMEDOUT`) and the enclosing
 * command settles with a tool result; a later ack that covers the pending
 * `mseq` range clears {@link VfsWriteOutcomes.failure}, so the next step can
 * proceed on the same connection.
 */
export class VfsFlowControlError extends VfsProxyError {
  override readonly name: string = 'VfsFlowControlError'
  /** Configured bound that expired. */
  readonly timeoutMs: number
  /** D3's unacknowledged-VFS window in bytes. */
  readonly windowBytes: number
  /** Bytes the write had already published without an ack. */
  readonly pendingBytes: number

  constructor(options: {
    readonly path: string
    readonly timeoutMs: number
    readonly pendingBytes: number
    readonly windowBytes?: number
  }) {
    const windowBytes = options.windowBytes ?? DEFAULT_UNACKED_VFS_WINDOW_BYTES
    super(
      'ETIMEDOUT',
      `VFS flow control: ${options.path} published ${String(options.pendingBytes)} bytes with no level-1 VFS_ACK`
      + ` within ${String(options.timeoutMs)} ms (unacknowledged window ${formatByteLimit(windowBytes)});`
      + ' the host is not draining the ordered channel; split the write into smaller chunks and retry the step',
      options.path,
    )
    this.timeoutMs = options.timeoutMs
    this.windowBytes = windowBytes
    this.pendingBytes = options.pendingBytes
  }
}

/** Handle of one write being tracked; opaque outside this module. */
export interface VfsWriteTicket {
  readonly id: number
  readonly path: string
}

/** Construction inputs of {@link VfsWriteOutcomes}. */
export interface VfsWriteOutcomesOptions {
  /** Level-1 outcome bound in milliseconds; defaults to the D3 30 s window. */
  readonly timeoutMs?: number
  /** D3 window in bytes, for diagnostics only. */
  readonly windowBytes?: number
}

/** One refusal already applied to a mutation slot, for duplicate suppression. */
interface RefusedSlot {
  readonly mseq: bigint
  readonly path: string
}

interface TicketState {
  readonly id: number
  readonly path: string
  /** True while the backend call that publishes the mutation is running. */
  open: boolean
  /** True once a caller awaits the outcome. */
  awaiting: boolean
  readonly mseqs: bigint[]
  bytes: number
  settled: 'resolved' | 'rejected' | undefined
  error: Error | undefined
  readonly outcome: Promise<void>
  resolve: () => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout> | undefined
}

/**
 * One per Worker boot. The sink drives it with every mutation it publishes and
 * every ack/refusal it receives; the WASI VFS backend opens a ticket around a
 * write and awaits its outcome.
 */
export class VfsWriteOutcomes {
  /** Validated level-1 outcome bound. */
  readonly timeoutMs: number
  /** D3 window in bytes, for diagnostics. */
  readonly windowBytes: number
  private readonly states = new Map<number, TicketState>()
  /** Open tickets in publication order; the innermost matching path owns a mutation. */
  private readonly stack: TicketState[] = []
  private nextId = 1
  /**
   * Highest cumulative level-1/level-2 ack seen, so an ack that arrives while
   * a multi-frame write is still being published can be applied once the
   * publication window closes instead of settling the ticket early.
   */
  private ackedUpto = 0n
  /**
   * Refusals already applied, keyed by `(mseq, path)` in the current numbering.
   *
   * A host diagnostic reaches this tracker twice on the WASI path — the sink's
   * frame listener sees the `ERROR` and the parked command-boundary `flush()`
   * catches the same diagnostic from its rejected `waitAck` — so the second
   * delivery must not renumber the surviving in-flight writes again or reject
   * the write that moved into the freed slot.
   *
   * The path is part of the key so a *new* host refusal of a different write
   * that the channel renumbered into the freed slot and re-sent is applied
   * instead of being suppressed (G2-FIX-103 repair). A same-path mutation that
   * owns the slot and has not settled yet re-arms the entry the same way.
   * {@link notePublished} re-arms the key when a new mutation with that path is
   * published into the slot and {@link noteAck} drops every slot the host has
   * already covered.
   */
  private readonly refusedSlots = new Map<string, RefusedSlot>()
  private flowFailure: VfsFlowControlError | undefined
  private flowFailureMseqs: bigint[] = []
  private closed = false

  constructor(options: VfsWriteOutcomesOptions = {}) {
    this.timeoutMs = resolveVfsFlowControlTimeoutMs(options.timeoutMs)
    this.windowBytes = options.windowBytes ?? DEFAULT_UNACKED_VFS_WINDOW_BYTES
    if (!Number.isSafeInteger(this.windowBytes) || this.windowBytes <= 0) {
      throw new RangeError('VFS flow-control window must be a positive safe integer')
    }
  }

  /** Tickets that have not settled yet (diagnostics and tests). */
  get pending(): number {
    let count = 0
    for (const state of this.states.values()) if (state.settled === undefined) count += 1
    return count
  }

  /**
   * A flow-control failure that already failed one write loud.
   *
   * The sink's command-boundary flush checks this so a write that exceeded the
   * D3 window settles the tool call immediately instead of waiting a second
   * ack window. It clears as soon as an ack covers the pending mseq range.
   */
  get failure(): VfsFlowControlError | undefined {
    return this.flowFailure
  }

  /**
   * Open a ticket around the backend call that publishes one mutation.
   * @param path - canonical host VFS path of the write.
   * @returns the ticket to pass to {@link endPublishing} and {@link awaitOutcome}.
   */
  begin(path: string): VfsWriteTicket {
    if (this.closed) {
      throw new VfsProxyError('EIO', 'the VFS write outcome tracker is closed', path)
    }
    let resolve!: () => void
    let reject!: (error: Error) => void
    const outcome = new Promise<void>((res, rej) => {
      resolve = res
      reject = rej
    })
    // A settled ticket may never be awaited (a write to a volatile root, or a
    // backend error after the mutation landed); keep that from surfacing as an
    // unhandled rejection. The awaiting caller still observes the rejection.
    outcome.catch(() => {})
    const id = this.nextId++
    const state: TicketState = {
      id,
      path,
      open: true,
      awaiting: false,
      mseqs: [],
      bytes: 0,
      settled: undefined,
      error: undefined,
      outcome,
      resolve,
      reject,
      timer: undefined,
    }
    this.states.set(id, state)
    this.stack.push(state)
    return { id, path }
  }

  /**
   * Mark the publication window closed: mutations observed from now on do not
   * belong to this ticket. A ticket with no host-eligible mutation is complete
   * as soon as its backend call returns.
   * @param ticket - handle returned by {@link begin}.
   */
  endPublishing(ticket: VfsWriteTicket): void {
    const state = this.states.get(ticket.id)
    if (state === undefined) return
    state.open = false
    const index = this.stack.indexOf(state)
    if (index >= 0) this.stack.splice(index, 1)
    // An ack may have covered every frame attached so far *while* the backend
    // was still publishing later frames (a synchronous or in-memory channel).
    // The ticket is only complete now that the window is closed: check the
    // final frame list against the cumulative ack watermark.
    if (
      state.settled === undefined
      && state.mseqs.length > 0
      && everyAtOrBelow(state.mseqs, this.ackedUpto)
    ) {
      this.settle(state, undefined)
    }
    // A resolved ticket has nothing left to deliver; a rejected one must stay
    // until its write consumes the error. A ticket whose mutation never
    // reached the sink (volatile root or a local refusal) is complete too.
    if (state.awaiting) return
    if (state.settled === 'resolved') this.states.delete(state.id)
    else if (state.settled === undefined && state.mseqs.length === 0) this.states.delete(state.id)
  }

  /**
   * Attach one published mutation to the innermost open ticket for its path.
   * Called by the sink before it hands the frame to the channel, so an
   * immediate (same-thread) ack or refusal can settle the ticket.
   * @param path - canonical path of the published mutation.
   * @param mseq - mseq the sink assigned to the frame.
   * @param bytes - mutation payload bytes, for the flow-control diagnostic.
   */
  notePublished(path: string, mseq: bigint, bytes = 0): void {
    // A new mutation with this path owns its slot again: a refusal recorded for
    // the previous occupant of the same path must not suppress a later genuine
    // refusal of this one. A different path in the same slot keeps its own key,
    // so the old refusal is still recognized as a duplicate of itself.
    this.refusedSlots.delete(refusedSlotKey(mseq, path))
    for (let index = this.stack.length - 1; index >= 0; index -= 1) {
      const state = this.stack[index] as TicketState
      if (!state.open || state.settled !== undefined || state.path !== path) continue
      if (!state.mseqs.includes(mseq)) state.mseqs.push(mseq)
      state.bytes += Math.max(0, bytes)
      return
    }
  }

  /**
   * Record a cumulative host acknowledgement.
   * @param level - ack level; level 2 implies level 1.
   * @param uptoMseq - every mseq at or below this is acknowledged.
   */
  noteAck(level: 1 | 2, uptoMseq: bigint): void {
    if (level !== 1 && level !== 2) return
    if (uptoMseq > this.ackedUpto) this.ackedUpto = uptoMseq
    for (const [key, slot] of [...this.refusedSlots]) {
      if (slot.mseq <= uptoMseq) this.refusedSlots.delete(key)
    }
    if (this.flowFailure !== undefined && everyAtOrBelow(this.flowFailureMseqs, uptoMseq)) {
      this.flowFailure = undefined
      this.flowFailureMseqs = []
    }
    for (const state of this.states.values()) {
      if (state.settled !== undefined) continue
      // While the backend is still publishing this mutation's frames, an ack
      // can cover only a prefix of them; `endPublishing` re-checks the final
      // list against the watermark. Settling here would let a multi-frame
      // write complete before its later frames are even published.
      if (state.open) continue
      if (state.mseqs.length === 0) continue
      if (!everyAtOrBelow(state.mseqs, uptoMseq)) continue
      this.settle(state, undefined)
    }
  }

  /**
   * Record a host resource refusal (channel.md §4.8).
   *
   * The refusal names the refused mutation; every unsettled ticket that
   * published that mseq rejects with the structured errno error. Every
   * unsettled ticket for the same path is rejected too: a refusal is a file
   * budget condition, so a write that already published a frame for that file
   * cannot be confirmed even when the diagnostic named a sibling mutation
   * (conservative by design).
   *
   * A refusal consumes no mseq, so every later unacked mutation is renumbered
   * one slot down, exactly like the channel client's local buffer. Delivery is
   * idempotent per `(mseq, path)`: the sink's frame listener and a parked
   * command-boundary flush both observe the same host diagnostic, and the
   * second delivery must not renumber the surviving in-flight writes twice or
   * reject the write that moved into the freed slot. The key is the pair, not
   * the slot alone, because the channel renumbers a surviving write into the
   * freed slot and re-sends it: a later genuine refusal of that new occupant
   * carries its own path and must settle it rather than be dropped as a
   * duplicate of the previous occupant's refusal (G2-FIX-103 repair). A
   * same-path occupant that has not settled yet re-arms the entry the same way,
   * and {@link notePublished} re-arms it when the path is published again.
   * @param refusal - structured refusal from the host or the sink.
   * @param refusedMseq - the refused mutation's mseq, when the host named it.
   */
  noteRefusal(refusal: VfsWriteRefusal, refusedMseq?: bigint): void {
    if (refusedMseq !== undefined) {
      // A mutation the host already acknowledged cannot be refused; such a
      // frame is a duplicate/stale diagnostic, and applying it would fail a
      // newer write to the same path.
      if (refusedMseq <= this.ackedUpto) return
      // The second delivery of one host diagnostic names the same slot *and*
      // path, and the mutation it named is already settled. A different path at
      // that slot is the surviving write the channel renumbered into it, and a
      // same-path mutation that still owns the slot is a new occupant: both are
      // genuine refusals, not duplicates.
      if (
        this.refusedSlots.has(refusedSlotKey(refusedMseq, refusal.path))
        && !this.hasUnsettledSlotOwner(refusedMseq, refusal.path)
      ) {
        return
      }
    }
    const error = new VfsProxyError(refusal.code, vfsWriteRefusalMessage(refusal), refusal.path)
    for (const state of this.states.values()) {
      if (state.settled !== undefined) continue
      const ownsRefusedSlot = refusedMseq !== undefined && state.mseqs.includes(refusedMseq)
      if (ownsRefusedSlot || state.path === refusal.path) {
        this.settle(state, error)
        continue
      }
      if (refusedMseq !== undefined) {
        for (let index = 0; index < state.mseqs.length; index += 1) {
          const mseq = state.mseqs[index] as bigint
          if (mseq > refusedMseq) state.mseqs[index] = mseq - 1n
        }
      }
    }
    if (refusedMseq !== undefined) {
      this.recordRefusedSlot(refusedMseq, refusal.path)
    }
  }

  /** Whether an unsettled ticket with this exact path now owns the slot again. */
  private hasUnsettledSlotOwner(mseq: bigint, path: string): boolean {
    for (const state of this.states.values()) {
      if (state.settled !== undefined) continue
      if (state.path !== path) continue
      if (state.mseqs.includes(mseq)) return true
    }
    return false
  }

  /**
   * Remember one applied refusal in the slot's current numbering and shift the
   * records of later refusals down with the channel's renumbering.
   * @param refusedMseq - the refused mutation's mseq in the current numbering.
   * @param path - the refused mutation's path.
   */
  private recordRefusedSlot(refusedMseq: bigint, path: string): void {
    const shifted = new Map<string, RefusedSlot>()
    for (const slot of this.refusedSlots.values()) {
      const mseq = slot.mseq > refusedMseq ? slot.mseq - 1n : slot.mseq
      shifted.set(refusedSlotKey(mseq, slot.path), { mseq, path: slot.path })
    }
    shifted.set(refusedSlotKey(refusedMseq, path), { mseq: refusedMseq, path })
    this.refusedSlots.clear()
    for (const [key, slot] of shifted) this.refusedSlots.set(key, slot)
  }

  /**
   * Fail every pending ticket loud (structural sink failure, channel loss,
   * disposal). Nothing may stay parked on a write after this.
   * @param error - failure every waiting write observes.
   */
  noteFailure(error: Error): void {
    for (const state of this.states.values()) {
      if (state.settled === undefined) this.settle(state, error)
    }
  }

  /**
   * Wait for the ticket's outcome, bounded by the configured D3 window.
   * @param ticket - handle returned by {@link begin}.
   * @throws {VfsProxyError} when the host refused the write (EFBIG/ENOSPC/EDQUOT).
   * @throws {VfsFlowControlError} when no level-1 ack arrived within the bound.
   */
  async awaitOutcome(ticket: VfsWriteTicket): Promise<void> {
    const state = this.states.get(ticket.id)
    if (state === undefined) return
    state.awaiting = true
    if (state.settled !== undefined) {
      this.states.delete(state.id)
      if (state.error !== undefined) throw state.error
      return
    }
    if (state.mseqs.length === 0) {
      // Nothing reached the sink (volatile root, or the runtime refused the
      // mutation locally); there is no host outcome to wait for.
      if (!state.open) this.states.delete(state.id)
      return
    }
    if (state.timer === undefined) {
      const timer = setTimeout(() => {
        state.timer = undefined
        if (state.settled !== undefined) return
        const error = new VfsFlowControlError({
          path: state.path,
          timeoutMs: this.timeoutMs,
          pendingBytes: state.bytes,
          windowBytes: this.windowBytes,
        })
        this.flowFailure = error
        this.flowFailureMseqs = [...state.mseqs]
        this.settle(state, error)
      }, this.timeoutMs)
      unrefTimer(timer)
      state.timer = timer
    }
    try {
      await state.outcome
    } finally {
      this.states.delete(state.id)
    }
  }

  /**
   * Reject every pending ticket and stop accepting new work. Idempotent.
   * @param reason - optional failure the pending writes observe.
   */
  close(reason?: Error): void {
    if (this.closed) return
    this.closed = true
    const error = reason ?? new VfsProxyError('EIO', 'the VFS write outcome tracker was closed')
    for (const state of this.states.values()) {
      if (state.settled === undefined) this.settle(state, error)
    }
    this.stack.length = 0
  }

  private settle(state: TicketState, error: Error | undefined): void {
    if (state.settled !== undefined) return
    if (state.timer !== undefined) {
      clearTimeout(state.timer)
      state.timer = undefined
    }
    state.settled = error === undefined ? 'resolved' : 'rejected'
    state.error = error
    if (state.open) {
      const index = this.stack.indexOf(state)
      if (index >= 0) this.stack.splice(index, 1)
    }
    if (error === undefined) state.resolve()
    else state.reject(error)
    if (!state.awaiting) {
      // Keep a rejected ticket until its caller consumes the error; a resolved
      // one has no information left to deliver.
      if (error === undefined) this.states.delete(state.id)
    }
  }
}

/** Dedupe key of one refused mutation: its slot in the current numbering plus path. */
function refusedSlotKey(mseq: bigint, path: string): string {
  return `${String(mseq)}\u0000${path}`
}

function everyAtOrBelow(mseqs: readonly bigint[], uptoMseq: bigint): boolean {
  if (mseqs.length === 0) return false
  for (const mseq of mseqs) if (mseq > uptoMseq) return false
  return true
}
