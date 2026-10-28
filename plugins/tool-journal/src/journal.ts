// SPDX-License-Identifier: MIT
/**
 * The tool journal file: one NDJSON file per session. On the phone Worker each
 * record is also sent as a JOURNAL frame (0x30) over the ordered channel and
 * the append resolves only after the host's level-1 ack (0x31); level 2 is
 * requested at checkpoint boundaries through `VFS_BARRIER` (0x12) and only the
 * host's epoch close answers it. On desktop the file append is the whole
 * promise: no `fsync` anywhere (a phone kill loses page cache at worst, and
 * DSH flushes its session log separately).
 *
 * A torn final line is ignored on load. `jseq` is per session and consecutive
 * from 1; the header carries `jseq_base` so a local compaction never reuses a
 * sequence the host already deduplicated.
 * @module @phone-dsh/dsh-tool-journal/journal
 */

import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync } from 'node:fs'
import { appendFile, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { ChannelClient } from '@phone-dsh/dsh-channel/client'
import {
  resolveDurabilityAckTimeoutMs, withDurabilityAckTimeout,
} from '@phone-dsh/dsh-channel/ack-tracker'
import { FrameType } from '@phone-dsh/dsh-channel/frames'
import { encodeJournal } from '@phone-dsh/dsh-channel/vfs-mutation'

export const JOURNAL_VERSION = 1

/** Durable projection of one tool result (what a `tool/result` event carries). */
export interface JournaledResult {
  content: unknown[]
  isError: boolean
  /**
   * The DSH error info. A budget/cancel settle stores the canonical JSON of
   * the full `AgentCancelCause` chain in `reason` so a replay can reconstruct
   * why the call was cut off (G2-FIX-84).
   */
  error?: { name: string; code: string; reason?: string }
  meta?: unknown
}

export type JournalRecord =
  | { v: 1; t: 'header'; session_id: string; profile: string; at: number; jseq_base?: number }
  | {
    v: 1; t: 'start'; key: string; call_id: string; tool: string; class: string
    args_sha256: string; schema_sha256: string | null; profile: string; at: number
    step_id?: string; turn_id?: string
  }
  | { v: 1; t: 'executed' | 'done'; key: string; call_id: string; result: JournaledResult; at: number; step_id?: string; turn_id?: string }
  | { v: 1; t: 'resolved'; key: string; call_id: string; action: string; detail?: string; at: number; step_id?: string; turn_id?: string }

/** One local journal record together with the `jseq` it occupies. */
export interface JournaledRecord {
  readonly jseq: bigint
  readonly record: JournalRecord
}

/** Everything the journal knows about one call. */
export interface CallEntry {
  start?: Extract<JournalRecord, { t: 'start' }>
  executed?: JournaledResult
  done?: JournaledResult
  resolved?: string
}

/** Journal confirmation level: 0 = not sent, 1 = host write() returned, 2 = epoch fsync. */
export type AckLevel = 0 | 1 | 2

/** Confirmation state of one session's journal. */
export interface JournalConfirmation {
  readonly level: AckLevel
  readonly uptoJseq: bigint
}

/** `XL_IDEMPOTENCY_KEY` = "xl1-" + first 32 hex chars of sha256(session_id + "\n" + call_id). */
export function idempotencyKey(sessionId: string, callId: string): string {
  return `xl1-${createHash('sha256').update(`${sessionId}\n${callId}`).digest('hex').slice(0, 32)}`
}

/** Stable sha256 of a JSON value with sorted object keys. */
export function canonicalHash(value: unknown): string {
  const canonical = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(canonical)
    if (v !== null && typeof v === 'object') {
      return Object.fromEntries(Object.keys(v).sort().map(k => [k, canonical((v as Record<string, unknown>)[k])]))
    }
    return v
  }
  return createHash('sha256').update(JSON.stringify(canonical(value)) ?? 'undefined').digest('hex')
}

function fileName(sessionId: string): string {
  return /^[A-Za-z0-9._-]{1,128}$/.test(sessionId) && !sessionId.startsWith('.')
    ? `${sessionId}.journal.ndjson`
    : `${createHash('sha256').update(sessionId).digest('hex')}.journal.ndjson`
}

/** The wire projection of a local record (the host's dispatched/completed view). */
function wireRecord(record: JournalRecord): Record<string, unknown> {
  const type = record.t === 'start' ? 'dispatched' : record.t === 'done' ? 'completed' : record.t === 'executed' ? 'executed' : record.t
  return { ...record, type }
}

type ChannelSource = ChannelClient | (() => ChannelClient | undefined)

/** Construction inputs for {@link ChannelJournalSync}. */
export interface ChannelJournalSyncOptions {
  /**
   * Bound for one 0x31/0x12 wait. Defaults to the channel package's validated
   * env/constant window; on expiry the append rejects instead of parking the
   * per-session journal chain forever.
   */
  readonly ackTimeoutMs?: number
  /**
   * Observe the 0x30 → 0x31 hop of each append (G2-FIX-83). Diagnostic only:
   * the wait always resolves the moment the cumulative level-1 ack arrives.
   */
  readonly onSyncTiming?: (timing: JournalSyncTiming) => void
}

/**
 * Per-hop timing of one tool-journal append over the ordered channel
 * (G2-FIX-83).
 *
 * `waitMilliseconds` covers the `0x30` send through the `0x31` level-1 ack
 * arrival. It is the journal-half of the `tool_dispatched -> journaled` step
 * boundary; the host's `ChannelMetrics.ackTimings` carries the matching
 * log-to-frame hop, so the two artifacts can be reconciled without guessing.
 */
export interface JournalSyncTiming {
  readonly sessionId: string
  readonly jseq: bigint
  /** True when the ack was already known and no ack frame was awaited. */
  readonly alreadyAcked: boolean
  readonly startedAtMilliseconds: number
  readonly ackedAtMilliseconds: number
  readonly waitMilliseconds: number
  /**
   * Milliseconds between the last event-loop heartbeat and the ack
   * observation (G2-FIX-119). Near zero on an idle Worker; near the whole wait
   * when a CPU-bound in-Worker command starved the single-threaded loop while
   * the host's fast 0x31 sat queued.
   */
  readonly eventLoopBlockedMilliseconds: number
  /**
   * True when a slow wait was mostly this Worker's own event-loop starvation,
   * not host ack latency. The sample is retained for artifact reconciliation
   * but is not a host slow-ack defect, so it must not reach the console error
   * stream (that would pollute the scenario's `console_errors`).
   */
  readonly workerBusy: boolean
}

/**
 * A journal level-1 sync at or above this bound is a boundary-cadence defect
 * (G2-FIX-83); reported on the console stream for artifact reconciliation.
 */
export const SLOW_JOURNAL_SYNC_MILLISECONDS = 1_000

/**
 * Cadence of the diagnostic heartbeat that runs while one append awaits its
 * level-1 ack (G2-FIX-119). It is unref'd and always cleared by `append`.
 */
export const JOURNAL_SYNC_HEARTBEAT_MILLISECONDS = 25

/**
 * A slow sync counts as Worker-busy only when the event loop was starved for
 * at least this many milliseconds *and* for at least
 * {@link JOURNAL_SYNC_EVENT_LOOP_BLOCK_RATIO} of the measured wait: a short
 * hiccup inside a genuinely slow host ack is not starvation.
 */
export const JOURNAL_SYNC_EVENT_LOOP_BLOCK_MINIMUM_MILLISECONDS = 250
/** Minimum fraction of the wait that must be event-loop starvation. */
export const JOURNAL_SYNC_EVENT_LOOP_BLOCK_RATIO = 0.5

/** G2-FIX-119 split of one slow hop into host latency vs Worker starvation. */
function journalSyncWorkerBusy(alreadyAcked: boolean, waitMilliseconds: number,
                               eventLoopBlockedMilliseconds: number): boolean {
  return !alreadyAcked
    && waitMilliseconds >= SLOW_JOURNAL_SYNC_MILLISECONDS
    && eventLoopBlockedMilliseconds >= Math.max(
      JOURNAL_SYNC_EVENT_LOOP_BLOCK_MINIMUM_MILLISECONDS,
      waitMilliseconds * JOURNAL_SYNC_EVENT_LOOP_BLOCK_RATIO,
    )
}

/**
 * One session's journal projection over the ordered channel: 0x30 out, and the
 * 0x31 high-water marks owned by the channel package's single ack tracker.
 *
 * This class keeps no level maps and no waiter list of its own; both levels are
 * read from {@link ChannelClient.journalAcked} and waits go through
 * {@link ChannelClient.waitJournalAck}. Level 2 is produced by the host at its
 * epoch close (the W2 WorkspaceLog adapter calls closeEpoch in the §D18 order);
 * a VFS_BARRIER(2) checkpoint only *requests* that close and never implies a
 * level-2 journal ack here.
 *
 * Every wait is bounded: a host that drops a 0x31 or 0x12 frame must fail the
 * append/checkpoint loud (the client emits an ERROR, recycles the connection
 * and replays the original jseq) instead of hanging the agent loop.
 */
export class ChannelJournalSync {
  private readonly source: ChannelSource
  private readonly ackTimeoutMs: number
  private readonly onSyncTiming: ((timing: JournalSyncTiming) => void) | undefined
  private disposed = false

  constructor(source: ChannelSource, options: ChannelJournalSyncOptions = {}) {
    this.source = source
    this.ackTimeoutMs = resolveDurabilityAckTimeoutMs(options.ackTimeoutMs)
    this.onSyncTiming = options.onSyncTiming
  }

  /** The channel, resolved at call time so a Worker boot may install it later. */
  private channel(): ChannelClient | undefined {
    return typeof this.source === 'function' ? this.source() : this.source
  }

  /** Send one record and resolve on the level-1 ack (or immediately when already covered). */
  async append(sessionId: string, jseq: bigint, record: Uint8Array, signal?: AbortSignal): Promise<void> {
    if (this.disposed) throw new Error('tool-journal: channel sync is closed')
    const channel = this.channel()
    if (channel === undefined) return
    const startedAtMilliseconds = Date.now()
    const alreadyAcked = channel.journalAcked(sessionId, 1) >= jseq
    // The channel buffers 0x30 across a reconnect and the host deduplicates by
    // (session_id, jseq), so a retry keeps the original sequence number.
    channel.send(FrameType.JOURNAL, encodeJournal({ jseq, sessionId, record }))
    if (channel.journalAcked(sessionId, 1) >= jseq) {
      this.noteTiming(sessionId, jseq, alreadyAcked, startedAtMilliseconds, startedAtMilliseconds, 0)
      return
    }
    // This Worker is single-threaded: a CPU-bound in-Worker command can leave
    // the host's already-sent 0x31 queued for over a second. A heartbeat shows
    // whether the wait was this loop being starved, so a fast host ack after a
    // long command is not reported as a slow host (G2-FIX-119).
    //
    // The blocked span is the *longest* gap between heartbeats, not the gap
    // since the last heartbeat: after a block, the overdue interval callback
    // can run before a queued 0x31 frame is delivered, which would otherwise
    // reset the clock and hide the starvation. `lastHeartbeatAt` starts at the
    // send time, so an append that never got a heartbeat still measures its
    // whole wait.
    let lastHeartbeatAt = startedAtMilliseconds
    let longestHeartbeatGap = 0
    let heartbeat: ReturnType<typeof setInterval> | undefined
    try {
      if (this.onSyncTiming !== undefined) {
        heartbeat = setInterval(() => {
          const now = Date.now()
          longestHeartbeatGap = Math.max(longestHeartbeatGap, now - lastHeartbeatAt)
          lastHeartbeatAt = now
        }, JOURNAL_SYNC_HEARTBEAT_MILLISECONDS)
        // JavaScriptCore's Web Worker returns a numeric id from setInterval,
        // not a Node Timeout; unref is a Node-only nicety, not a requirement.
        heartbeat.unref?.()
      }
      await withDurabilityAckTimeout(
        channel.waitJournalAck(1, sessionId, jseq, signal, { timeoutMs: this.ackTimeoutMs }),
        this.ackTimeoutMs,
        `tool-journal JOURNAL_ACK level 1 for ${JSON.stringify(sessionId)} jseq ${String(jseq)}`,
      )
      const ackedAtMilliseconds = Date.now()
      // The final heartbeat -> ack gap is part of the same measurement; on an
      // idle loop it is at most one heartbeat interval.
      longestHeartbeatGap = Math.max(longestHeartbeatGap, ackedAtMilliseconds - lastHeartbeatAt)
      this.noteTiming(sessionId, jseq, alreadyAcked, startedAtMilliseconds,
        ackedAtMilliseconds, longestHeartbeatGap)
    } finally {
      if (heartbeat !== undefined) clearInterval(heartbeat)
    }
  }

  /** Records one 0x30 → 0x31 hop for diagnostics (G2-FIX-83, G2-FIX-119). */
  private noteTiming(sessionId: string, jseq: bigint, alreadyAcked: boolean,
                     startedAtMilliseconds: number, ackedAtMilliseconds: number,
                     longestHeartbeatGap: number): void {
    if (this.onSyncTiming === undefined) return
    const waitMilliseconds = ackedAtMilliseconds - startedAtMilliseconds
    // When the ack was already known there was no wait to starve; keep the
    // field at zero instead of attributing send/check overhead to the loop.
    const eventLoopBlockedMilliseconds = alreadyAcked
      ? 0
      : Math.max(0, longestHeartbeatGap)
    this.onSyncTiming({
      sessionId,
      jseq,
      alreadyAcked,
      startedAtMilliseconds,
      ackedAtMilliseconds,
      waitMilliseconds,
      eventLoopBlockedMilliseconds,
      workerBusy: journalSyncWorkerBusy(alreadyAcked, waitMilliseconds, eventLoopBlockedMilliseconds),
    })
  }

  /** Whether an ordered channel is installed right now. */
  hasChannel(): boolean {
    return this.channel() !== undefined
  }

  /** Highest level-1 acknowledged jseq for a session. */
  acknowledged(sessionId: string): bigint {
    return this.channel()?.journalAcked(sessionId, 1) ?? 0n
  }

  /** Highest level-2 acknowledged jseq for a session. */
  durable(sessionId: string): bigint {
    return this.channel()?.journalAcked(sessionId, 2) ?? 0n
  }

  /** Current confirmation facts; level 2 only when the host actually sent it. */
  confirmation(sessionId: string): JournalConfirmation {
    const channel = this.channel()
    if (channel === undefined) return { level: 0, uptoJseq: 0n }
    const level2 = channel.journalAcked(sessionId, 2)
    if (level2 > 0n) return { level: 2, uptoJseq: level2 }
    const level1 = channel.journalAcked(sessionId, 1)
    return level1 > 0n ? { level: 1, uptoJseq: level1 } : { level: 0, uptoJseq: 0n }
  }

  /**
   * Request level 2 at a checkpoint boundary: a VFS barrier for the last
   * emitted mseq. The host closes an epoch and then may send 0x31 level 2; this
   * method does not synthesize that ack. Callers normally do not block a turn
   * on it, and `confirmation()` stays at level 1 until the real 0x31 arrives.
   */
  async checkpoint(_sessionId: string): Promise<void> {
    if (this.disposed) return
    const channel = this.channel()
    if (channel === undefined) return
    const upto = channel.nextMseq() > 0n ? channel.nextMseq() - 1n : 0n
    await withDurabilityAckTimeout(
      channel.barrier(2, upto, undefined, { timeoutMs: this.ackTimeoutMs }),
      this.ackTimeoutMs,
      `tool-journal VFS_BARRIER level 2 up to mseq ${String(upto)}`,
    )
  }

  /** Stop accepting appends. The channel remains owned by the entry. */
  close(): void {
    this.disposed = true
  }
}

/** The plaintext NDJSON journal, with an optional ordered-channel mirror. */
export class ToolJournalStore {
  readonly root: string
  readonly profile: string
  private readonly mirror: ChannelJournalSync | undefined
  private readonly chains = new Map<string, Promise<void>>()
  private readonly nextJseq = new Map<string, bigint>()

  constructor(root: string, profile: string, options: {
    channel?: ChannelSource | undefined
    ackTimeoutMs?: number | undefined
    onSyncTiming?: ((timing: JournalSyncTiming) => void) | undefined
  } = {}) {
    this.root = root
    this.profile = profile
    // Resolve globalThis.__PDSH_CHANNEL__ at call time by default: the entry may
    // install the ordered channel after the plugin mounted.
    this.mirror = new ChannelJournalSync(
      options.channel ?? (() => globalThis.__PDSH_CHANNEL__),
      {
        ...options.ackTimeoutMs === undefined ? {} : { ackTimeoutMs: options.ackTimeoutMs },
        ...options.onSyncTiming === undefined ? {} : { onSyncTiming: options.onSyncTiming },
      },
    )
    mkdirSync(root, { recursive: true, mode: 0o700 })
  }

  path(sessionId: string): string {
    return join(this.root, fileName(sessionId))
  }

  /**
   * Append one record: local NDJSON first (plaintext, no fsync), then the
   * JOURNAL frame and its level-1 ack when the ordered channel is present.
   */
  append(sessionId: string, record: JournalRecord, signal?: AbortSignal): Promise<void> {
    const result = this.enqueue(sessionId, async () => {
      signal?.throwIfAborted()
      const path = this.path(sessionId)
      const existing = await readTextOrUndefined(path)
      const base = existing === undefined ? 1n : nextJseqFrom(existing)
      const jseq = this.nextJseq.get(sessionId) ?? base
      const headerMissing = existing === undefined
      if (headerMissing) await writeFile(path, `${JSON.stringify(this.header(sessionId))}\n`, { mode: 0o600 })
      await appendFile(path, `${JSON.stringify(record)}\n`, { mode: 0o600 })
      this.nextJseq.set(sessionId, jseq + 1n)
      // Once the local record has consumed `jseq`, always send that same
      // sequence to the ordered channel before honoring cancellation. Throwing
      // here would leave a local-only jseq; the next append would send jseq+1
      // and the host would reject it as a gap. ChannelJournalSync sends first
      // and still uses this signal to cancel the level-1 ack wait.
      if (this.mirror !== undefined) {
        await this.mirror.append(sessionId, jseq, Buffer.from(JSON.stringify(wireRecord(record)), 'utf8'), signal)
      } else {
        signal?.throwIfAborted()
      }
    })
    return result
  }

  /** Worker sync path alias: append one record and await its confirmation. */
  sync(sessionId: string, record: JournalRecord, signal?: AbortSignal): Promise<void> {
    return this.append(sessionId, record, signal)
  }

  /** Wait for every append queued before this call for a session. */
  settled(sessionId: string): Promise<void> {
    return this.chains.get(sessionId) ?? Promise.resolve()
  }

  /** Load all intact records of a session; missing file = empty. */
  load(sessionId: string): JournalRecord[] {
    let text: string
    try {
      // Synchronous by design: reconcile reads the journal during session open.
      text = readFileSync(this.path(sessionId), 'utf8')
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
      throw error
    }
    return parseRecords(text)
  }

  /** Fold records into per-call entries plus the journal header. */
  entries(sessionId: string): { header?: Extract<JournalRecord, { t: 'header' }>; calls: Map<string, CallEntry> } {
    const calls = new Map<string, CallEntry>()
    let header: Extract<JournalRecord, { t: 'header' }> | undefined
    for (const record of this.load(sessionId)) {
      if (record.t === 'header') { header ??= record; continue }
      const entry = calls.get(record.call_id) ?? {}
      calls.set(record.call_id, entry)
      if (record.t === 'start') entry.start = record
      else if (record.t === 'executed') entry.executed = record.result
      else if (record.t === 'done') entry.done = record.result
      else if (record.t === 'resolved') entry.resolved = record.action
    }
    return { ...header === undefined ? {} : { header }, calls }
  }

  /**
   * Local records with the `jseq` each occupies (header excluded).
   *
   * Recovery uses this to tell an already-acknowledged `resolved` from one
   * whose local write completed just before a cancelled level-1 wait; only the
   * former proves the host saw the record.
   */
  journaled(sessionId: string): JournaledRecord[] {
    const records = this.load(sessionId)
    const header = records.find(record => record.t === 'header') as
      | Extract<JournalRecord, { t: 'header' }>
      | undefined
    let jseq = BigInt(header?.jseq_base ?? 1)
    const result: JournaledRecord[] = []
    for (const record of records) {
      if (record.t === 'header') continue
      result.push({ jseq, record })
      jseq += 1n
    }
    return result
  }

  /** Whether the ordered channel mirror currently has a live channel. */
  mirrored(): boolean {
    return this.mirror?.hasChannel() ?? false
  }

  /**
   * Drop every record (keep a fresh header carrying the next `jseq`). Called
   * only when every journaled call's `tool/result` is durable in the session log.
   */
  async compact(sessionId: string): Promise<void> {
    await this.settled(sessionId)
    const next = this.nextJseq.get(sessionId) ?? nextJseqOfFile(await readTextOrUndefined(this.path(sessionId)))
    const path = this.path(sessionId)
    const temp = `${path}.tmp-${process.pid}`
    await writeFile(temp, `${JSON.stringify({ ...this.header(sessionId), jseq_base: Number(next) })}\n`, { mode: 0o600 })
    await rename(temp, path)
    this.nextJseq.set(sessionId, next)
  }

  /** Confirmation level of a session (0 when there is no ordered channel). */
  confirmed(sessionId: string): JournalConfirmation {
    return this.mirror?.confirmation(sessionId) ?? { level: 0, uptoJseq: 0n }
  }

  /** Request level 2 at a checkpoint boundary through the channel barrier. */
  checkpoint(sessionId: string): Promise<void> {
    return this.mirror?.checkpoint(sessionId) ?? Promise.resolve()
  }

  /** Stop accepting appends and detach the channel listener. */
  close(): void {
    this.mirror?.close()
  }

  private enqueue(sessionId: string, task: () => Promise<void>): Promise<void> {
    const previous = this.chains.get(sessionId) ?? Promise.resolve()
    const result = previous.then(task, task)
    this.chains.set(sessionId, result)
    void result.catch(() => {}).finally(() => {
      if (this.chains.get(sessionId) === result) this.chains.delete(sessionId)
    })
    return result
  }

  private header(sessionId: string): JournalRecord {
    return { v: 1, t: 'header', session_id: sessionId, profile: this.profile, at: Date.now() }
  }
}

function parseRecords(text: string): JournalRecord[] {
  const records: JournalRecord[] = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    try {
      const record = JSON.parse(line) as JournalRecord
      if (record.v === JOURNAL_VERSION) records.push(record)
    } catch {
      // A torn final line from a crash mid-append.
    }
  }
  return records
}

function nextJseqFrom(text: string): bigint {
  const records = parseRecords(text)
  const header = records.find(record => record.t === 'header') as Extract<JournalRecord, { t: 'header' }> | undefined
  const base = header?.jseq_base ?? 1
  const body = records.filter(record => record.t !== 'header').length
  return BigInt(base + body)
}

function nextJseqOfFile(text: string | undefined): bigint {
  return text === undefined ? 1n : nextJseqFrom(text)
}

async function readTextOrUndefined(path: string): Promise<string | undefined> {
  try {
    return await readFile(path, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw error
  }
}
