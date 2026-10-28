// SPDX-License-Identifier: MIT
/**
 * TypeScript shapes of every JSON payload of channel.md §4.
 *
 * Field names are the wire names so a payload object can be passed straight to
 * `canonicalStringify`. u64 fields are `bigint`; the encoder emits them as JSON
 * integer digits without losing precision.
 * @module @phone-dsh/dsh-channel/payloads
 */
import { FrameError } from './errors.ts'
import { FrameType } from './frames.ts'

/** Direction a frame type may travel (channel.md §2). */
export type FrameDirection = 'host->worker' | 'worker->host' | 'both'

/**
 * Direction table of channel.md §2.
 * @returns the legal direction, or undefined for a reserved type byte.
 */
export function frameDirection(type: FrameType): FrameDirection | undefined {
  switch (type) {
    case FrameType.HELLO:
    case FrameType.API_ABORT:
    case FrameType.ERROR:
      return 'both'
    case FrameType.VFS_ACK:
    case FrameType.VFS_RESYNC:
    case FrameType.EXEC_EVT:
    case FrameType.JOURNAL_ACK:
    case FrameType.API_REQ:
    case FrameType.LIFECYCLE:
    case FrameType.FENCE:
      return 'host->worker'
    case FrameType.VFS_MUT:
    case FrameType.VFS_BARRIER:
    case FrameType.EXEC_REQ:
    case FrameType.EXEC_CTL:
    case FrameType.JOURNAL:
    case FrameType.API_RES:
    case FrameType.API_END:
    case FrameType.CONSOLE:
      return 'worker->host'
    default:
      return undefined
  }
}

/** True when a Worker-role client may put `type` on the wire. */
export function workerMaySend(type: FrameType): boolean {
  const direction = frameDirection(type)
  return direction !== undefined && direction !== 'host->worker'
}

/** True when a host-role client may put `type` on the wire. */
export function hostMaySend(type: FrameType): boolean {
  const direction = frameDirection(type)
  return direction !== undefined && direction !== 'worker->host'
}

/** Head of an API_REQ: `{method, path, headers}` (channel.md §4.9). */
export interface ApiRequestHead {
  readonly method: string
  readonly path: string
  readonly headers: Readonly<Record<string, string>>
}

/** Head of the first API_RES chunk: `{status, headers}` (channel.md §4.9). */
export interface ApiResponseHead {
  readonly status: number
  readonly headers: Readonly<Record<string, string>>
}

/** Admission switch carried by LIFECYCLE and FENCE. */
export type Admission = 'open' | 'closed'

/** Execution authority of channel.md §4.1/§4.7. */
export interface Fence {
  readonly owner: string
  readonly generation: bigint
  readonly wal_seq: bigint
}

/** Fields common to both HELLO variants. */
export interface HelloBase {
  readonly proto: 1
  readonly boot_id: string
  readonly session_epoch: bigint
  readonly fence: Fence
  readonly caps: readonly string[]
}

/** Host HELLO: allocates the mseq space and reports the durable tail. */
export interface HelloHostPayload extends HelloBase {
  readonly role: 'host'
  readonly next_mseq: bigint
  readonly acked_mseq: bigint
  readonly durable_mseq: bigint
}

/** Worker HELLO: reports the highest mseq this worker process assigned. */
export interface HelloWorkerPayload extends HelloBase {
  readonly role: 'worker'
  readonly last_mseq: bigint
}

/** Either HELLO variant. */
export type HelloPayload = HelloHostPayload | HelloWorkerPayload

/** stdin modes of exec-bridge v1 §4.1. */
export type ExecStdin =
  | { readonly mode: 'ignore' }
  | { readonly mode: 'data'; readonly data: string }
  | { readonly mode: 'pipe' }

/** Sandbox values of exec-bridge v1 §4.1. */
export interface ExecConfine {
  readonly mode: 'read-only' | 'workspace-write'
  readonly workspace_root: string
}

/** EXEC_REQ: the exec-bridge v1 request plus `requires_mseq` and `idem_key`. */
export interface ExecReqPayload {
  readonly exec_id: string
  readonly argv: readonly string[]
  readonly cwd: string
  readonly env?: Readonly<Record<string, string | null>>
  readonly deadline?: bigint
  readonly grace_ms?: number
  readonly stdin?: ExecStdin
  readonly tier?: 'interactive' | 'session' | 'batch'
  readonly confine?: ExecConfine
  readonly requires_mseq: bigint
  readonly idem_key: string
}

/** EXEC_CTL cancels or feeds stdin to an execution. */
export type ExecCtlPayload =
  | { readonly exec_id: string; readonly op: 'cancel' }
  | { readonly exec_id: string; readonly op: 'stdin'; readonly data: string }

/** Event types of an EXEC_EVT stream (exec-bridge v1 §4.1). */
export type ExecEventType = 'start' | 'output' | 'exit' | 'quiescent' | 'error'

/** Fields every exec event carries. */
export interface ExecEventBase {
  readonly type: ExecEventType
  readonly exec_id: string
  /** Per-execution event sequence, from 0. */
  readonly seq: number
}

/** The execution started (or its recorded stream is being replayed). */
export interface ExecStartEvent extends ExecEventBase {
  readonly type: 'start'
  readonly pid?: number
  readonly replayed?: boolean
}

/** One stdout or stderr chunk; `data` is base64. */
export interface ExecOutputEvent extends ExecEventBase {
  readonly type: 'output'
  readonly stream: 'stdout' | 'stderr'
  readonly data: string
}

/** Terminal process event. */
export interface ExecExitEvent extends ExecEventBase {
  readonly type: 'exit'
  readonly code: number | null
  readonly signal: string | null
  readonly status: 'exited' | 'signaled' | 'cancelled' | 'timed_out' | 'rejected' | 'failed'
  readonly quiescent: boolean
  readonly stdout_bytes?: number
  readonly stderr_bytes?: number
  readonly stdout_truncated?: boolean
  readonly stderr_truncated?: boolean
  readonly error?: string
}

/** The process group emptied after a non-quiescent exit. */
export interface ExecQuiescentEvent extends ExecEventBase {
  readonly type: 'quiescent'
}

/** Terminal provider failure after the stream started. */
export interface ExecErrorEvent extends ExecEventBase {
  readonly type: 'error'
  readonly code: string
  readonly message: string
}

/** One EXEC_EVT payload; `exec_id` is a member, not a binary prefix. */
export type ExecEvent =
  | ExecStartEvent
  | ExecOutputEvent
  | ExecExitEvent
  | ExecQuiescentEvent
  | ExecErrorEvent

/** LIFECYCLE payload. */
export interface LifecyclePayload {
  readonly state: 'run' | 'pause' | 'stop'
  /** Remaining execution budget in milliseconds; 0 means none. */
  readonly budget: bigint
  readonly admission: Admission
  readonly reason: string
}

/** CONSOLE payload; the readiness marker `XL_DSH_READY` travels as `text`. */
export interface ConsolePayload {
  readonly level: 'debug' | 'info' | 'warn' | 'error'
  readonly text: string
}

/** FENCE payload. */
export interface FencePayload {
  readonly fence: Fence
  readonly admission: Admission
}

/** Error codes of channel.md §10. */
export type ChannelErrorCode =
  | 'BAD_MAGIC'
  | 'BAD_SEQ'
  | 'BAD_MSEQ'
  | 'BAD_PATH'
  | 'BAD_PAYLOAD'
  | 'FENCE_STALE'
  | 'VFS_CONFLICT'
  | 'VFS_REFUSED'
  | 'RING_TIMEOUT'
  | 'PROTO_MISMATCH'

/** Resource classes a `VFS_REFUSED` diagnostic can carry (channel.md §4.8). */
export type VfsRefusalReason = 'file-too-large' | 'no-space' | 'quota-exceeded'

/** ERROR payload. */
export interface ErrorPayload {
  readonly code: ChannelErrorCode
  readonly message: string
  readonly ref_seq?: bigint
}

/**
 * ERROR payload of a resource refusal (channel.md §4.8 and §10).
 *
 * `VFS_REFUSED` is the one ERROR code that does not close the connection: the
 * refused mutation never consumed an mseq and the Worker keeps serving. `path`
 * and `limit` name the refused target and the policy limit; `reason` is the
 * stable machine-readable class for the host's diagnostics.
 */
export interface VfsRefusedPayload extends ErrorPayload {
  readonly code: 'VFS_REFUSED'
  readonly path: string
  readonly limit: number
  readonly reason: VfsRefusalReason
}

/** True when a decoded ERROR payload is the non-closing `VFS_REFUSED` form. */
export function isVfsRefusedPayload(value: unknown): value is VfsRefusedPayload {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const record = value as Record<string, unknown>
  return record['code'] === 'VFS_REFUSED'
    && typeof record['message'] === 'string'
    && typeof record['path'] === 'string'
    && typeof record['limit'] === 'number'
    && Number.isSafeInteger(record['limit'])
    && record['limit'] >= 0
    && (record['reason'] === 'file-too-large'
      || record['reason'] === 'no-space'
      || record['reason'] === 'quota-exceeded')
}

/** Node errno code of the sink's structured resource refusal. */
export type VfsResourceErrorCode = 'EFBIG' | 'ENOSPC' | 'EDQUOT'

/**
 * Map the wire's stable refusal class to the node errno code both the Worker
 * write prechecks and the sink's local refusal use (channel.md §4.8, §10).
 */
export function vfsResourceErrorCode(reason: VfsRefusalReason): VfsResourceErrorCode {
  switch (reason) {
    case 'file-too-large':
      return 'EFBIG'
    case 'no-space':
      return 'ENOSPC'
    case 'quota-exceeded':
      return 'EDQUOT'
  }
}

/**
 * A host `ERROR VFS_REFUSED` reply (channel.md §4.8).
 *
 * A host reply names the refused mutation by `ref_seq` and carries structured
 * `mseq` and `accepted_bytes`; the Worker sink's own outbound diagnostic omits
 * both. The refused mutation consumed no mseq and the connection stays open.
 */
export interface VfsRefusedDiagnostic extends VfsRefusedPayload {
  /** Refused mutation's mseq; present exactly with {@link acceptedBytes} on a host reply. */
  readonly mseq?: bigint
  /** Accepted prefix of an appended mutation, bounded by `limit`; 0 for a complete write. */
  readonly acceptedBytes?: number
  /** Connection seq of the refused VFS_MUT. */
  readonly refSeq?: bigint
}

/**
 * Parse one decoded ERROR payload as the non-closing refusal diagnostic.
 * @param value - the decoded JSON object.
 * @returns the typed diagnostic, or undefined when the code is not `VFS_REFUSED`.
 * @throws FrameError `BAD_PAYLOAD` when the refusal lacks required members or
 *   carries an inconsistent structured `mseq`/`accepted_bytes` pair.
 */
export function parseVfsRefusedDiagnostic(value: unknown): VfsRefusedDiagnostic | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined
  const record = value as Record<string, unknown>
  if (record['code'] !== 'VFS_REFUSED') return undefined
  if (!isVfsRefusedPayload(record)) {
    throw new FrameError('BAD_PAYLOAD', 'ERROR VFS_REFUSED requires message, path, limit and reason')
  }
  const rawMseq = record['mseq']
  const rawAccepted = record['accepted_bytes']
  if ((rawMseq === undefined) !== (rawAccepted === undefined)) {
    throw new FrameError('BAD_PAYLOAD', 'ERROR VFS_REFUSED requires mseq and accepted_bytes together')
  }
  let mseq: bigint | undefined
  let acceptedBytes: number | undefined
  if (rawMseq !== undefined) {
    if (typeof rawMseq !== 'number' || !Number.isSafeInteger(rawMseq) || rawMseq < 1) {
      throw new FrameError('BAD_PAYLOAD', 'ERROR VFS_REFUSED mseq must be a positive integer')
    }
    if (typeof rawAccepted !== 'number' || !Number.isSafeInteger(rawAccepted)
      || rawAccepted < 0 || rawAccepted > record['limit']) {
      throw new FrameError('BAD_PAYLOAD', 'ERROR VFS_REFUSED accepted_bytes must be an integer in 0..limit')
    }
    mseq = BigInt(rawMseq)
    acceptedBytes = rawAccepted
  }
  let refSeq: bigint | undefined
  const rawRefSeq = record['ref_seq']
  if (rawRefSeq !== undefined) {
    if (typeof rawRefSeq !== 'number' || !Number.isSafeInteger(rawRefSeq) || rawRefSeq < 0) {
      throw new FrameError('BAD_PAYLOAD', 'ERROR VFS_REFUSED ref_seq must be a non-negative integer')
    }
    refSeq = BigInt(rawRefSeq)
  }
  const diagnostic: VfsRefusedDiagnostic = {
    code: 'VFS_REFUSED',
    message: record['message'],
    path: record['path'],
    limit: record['limit'],
    reason: record['reason'],
    ...(mseq === undefined ? {} : { mseq, acceptedBytes: acceptedBytes as number }),
    ...(refSeq === undefined ? {} : { refSeq }),
  }
  return diagnostic
}

/**
 * The structured, non-fatal resource refusal a Worker channel raises when the
 * host answers one VFS_MUT with `ERROR VFS_REFUSED` (channel.md §4.8, §8).
 *
 * Field names match the sink's local refusal record (`EFBIG`/`ENOSPC`/`EDQUOT`,
 * path, limit, accepted prefix) so the worker sink can route it to the write
 * that caused it exactly like its own pre-check.
 */
export class VfsRefusedError extends Error {
  /** Node errno code the command reports. */
  readonly code: VfsResourceErrorCode
  readonly path: string
  readonly limit: number
  /** Accepted prefix in bytes: 0 for a complete write, `append_from` for an append. */
  readonly acceptedBytes: number
  readonly reason: VfsRefusalReason
  /** The refused mutation's mseq when the host named it. */
  readonly refusedMseq: bigint | undefined

  constructor(diagnostic: VfsRefusedDiagnostic) {
    const code = vfsResourceErrorCode(diagnostic.reason)
    super(`${code}: VFS refused ${diagnostic.path} (limit ${String(diagnostic.limit)} bytes): ${diagnostic.message}`)
    this.name = 'VfsRefusedError'
    this.code = code
    this.path = diagnostic.path
    this.limit = diagnostic.limit
    this.acceptedBytes = diagnostic.acceptedBytes ?? 0
    this.reason = diagnostic.reason
    this.refusedMseq = diagnostic.mseq
  }
}

/** Capabilities a worker advertises in HELLO (channel.md §4.1). */
export const WORKER_CAPABILITIES: readonly string[] = Object.freeze([
  'channel/1', 'vfs-sink/1', 'journal/1', 'api/1',
])

/** Capabilities every host must advertise in HELLO. */
export const REQUIRED_HOST_CAPABILITIES: readonly string[] = Object.freeze([
  'channel/1', 'wal/1', 'exec/1',
])

/** Commands that may travel as EXEC_REQ (exec.md §3). */
export const ACCELERATOR_NAMES: readonly string[] = Object.freeze([
  'rg', 'jaq', 'ts-parse', 'ts-query', 'phone', 'ctx',
])
