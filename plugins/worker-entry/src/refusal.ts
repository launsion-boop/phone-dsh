// SPDX-License-Identifier: MIT
/**
 * Resource refusals raised by the VFS sink, kept separate from protocol
 * violations (G2-ENG-03).
 *
 * A structural failure (`BAD_PATH`, `BAD_MSEQ`, `BAD_PAYLOAD`) is a protocol
 * error: the sink fails loud and closes the ordered channel. A resource
 * refusal (`EFBIG`, `ENOSPC`, quota) is a normal consequence of a bounded
 * phone filesystem: the refused mutation never consumed an `mseq`, the channel
 * stays open, and `flush()` rejects with this node-errno-shaped error until a
 * later mutation repairs the path. The message ends in the shared `pdsh-shell:`
 * trailer so the model sees a self-healing instruction in the tool result
 * without an upstream `isError` change.
 * @module @phone-dsh/dsh-worker-entry/refusal
 */
import { DEFAULT_SINGLE_FILE_LIMIT } from '../../channel/src/vfs-mutation.ts'
import { formatByteLimit } from '../../wasi-toolbox/src/limits.ts'
import {
  vfsResourceErrorCode,
  type VfsRefusalReason, type VfsRefusedDiagnostic, type VfsRefusedError, type VfsRefusedPayload,
} from '../../channel/src/payloads.ts'

/** Re-exported so existing callers keep the name; the owner is `limits.ts`. */
export { formatByteLimit }

/** Node errno codes the sink classifies as a resource refusal. */
export type VfsResourceErrorCode = 'EFBIG' | 'ENOSPC' | 'EDQUOT'

/** Every resource code, in one place for classification tests and docs. */
export const VFS_RESOURCE_ERROR_CODES: readonly VfsResourceErrorCode[] = Object.freeze([
  'EFBIG',
  'ENOSPC',
  'EDQUOT',
])

/**
 * The persistent refusal record a poisoned `flush()` replays.
 *
 * Shape is the node-errno surface the shell and the write tool already expose:
 * `code` is the errno, `path` the refused VFS path, `limit` the policy bound in
 * bytes, and `hint` the one-line remediation echoed in the trailer.
 */
export interface VfsRefusalRecord {
  readonly code: VfsResourceErrorCode
  readonly path: string
  readonly limit: number
  readonly hint: string
  /**
   * Accepted prefix when the host refused an appended mutation (channel.md
   * §4.8): `append_from` bounded by `limit`; 0 for a complete write. Absent on
   * a Worker-sink refusal, which never accepted any part of the mutation.
   */
  readonly acceptedBytes?: number
}

/** True when a value is one of the resource errno codes. */
export function isVfsResourceErrorCode(value: unknown): value is VfsResourceErrorCode {
  return typeof value === 'string' && (VFS_RESOURCE_ERROR_CODES as readonly string[]).includes(value)
}

/** Stable machine-readable class carried in ERROR `VFS_REFUSED` (channel.md §4.8). */
export function vfsRefusalReason(code: VfsResourceErrorCode): VfsRefusalReason {
  switch (code) {
    case 'EFBIG':
      return 'file-too-large'
    case 'ENOSPC':
      return 'no-space'
    case 'EDQUOT':
      return 'quota-exceeded'
  }
}

/** The default one-line remediation for a resource code. */
export function vfsRefusalHint(code: VfsResourceErrorCode, limit: number, path?: string): string {
  const target = path === undefined ? 'the file' : path
  const bytes = formatByteLimit(limit)
  switch (code) {
    case 'EFBIG':
      return `${target} would be over the single-file limit; a file is limited to ${bytes}; delete it or rewrite it in chunks`
    case 'ENOSPC':
      return `${target} does not fit the remaining space (limit ${bytes}); delete files or write less`
    case 'EDQUOT':
      return `${target} would exceed the workspace quota (limit ${bytes}); delete files or write less`
  }
}

/** The node-errno-shaped error a poisoned `flush()` rejects with. */
export class VfsRefusalError extends Error {
  readonly code: VfsResourceErrorCode
  readonly path: string
  readonly limit: number
  readonly hint: string
  readonly reason: VfsRefusalReason
  /** Accepted prefix reported by a host budget refusal; 0 for a local guard. */
  readonly acceptedBytes: number

  constructor(record: VfsRefusalRecord) {
    super(vfsRefusalMessage(record))
    this.name = 'VfsRefusalError'
    this.code = record.code
    this.path = record.path
    this.limit = record.limit
    this.hint = record.hint
    this.reason = vfsRefusalReason(record.code)
    this.acceptedBytes = record.acceptedBytes ?? 0
  }

  /** The record replayed by every later flush while the condition persists. */
  get record(): VfsRefusalRecord {
    return {
      code: this.code,
      path: this.path,
      limit: this.limit,
      hint: this.hint,
      acceptedBytes: this.acceptedBytes,
    }
  }
}

/** True for the sink's own refusal error. */
export function isVfsRefusalError(error: unknown): error is VfsRefusalError {
  return error instanceof VfsRefusalError
}

/**
 * Classify an arbitrary thrown value as a resource refusal.
 * @param error - value thrown by a sink guard or a write surface.
 * @param fallbackLimit - limit to use when the error carries none.
 * @returns the normalized record, or undefined for a protocol failure.
 */
export function vfsRefusalRecordFromError(
  error: unknown,
  fallbackLimit: number = DEFAULT_SINGLE_FILE_LIMIT,
): VfsRefusalRecord | undefined {
  if (isVfsRefusalError(error)) return error.record
  const code = (error as { code?: unknown } | null)?.code
  if (!isVfsResourceErrorCode(code)) return undefined
  const record = error as {
    path?: unknown
    limit?: unknown
    hint?: unknown
    acceptedBytes?: unknown
  }
  const path = typeof record.path === 'string' ? record.path : '(unknown path)'
  const limit = typeof record.limit === 'number' && Number.isSafeInteger(record.limit) && record.limit >= 0
    ? record.limit
    : fallbackLimit
  const hint = typeof record.hint === 'string' && record.hint.trim() !== ''
    ? record.hint
    : vfsRefusalHint(code, limit, path)
  const acceptedBytes = typeof record.acceptedBytes === 'number'
    && Number.isSafeInteger(record.acceptedBytes) && record.acceptedBytes >= 0
    ? record.acceptedBytes
    : undefined
  return { code, path, limit, hint, ...(acceptedBytes === undefined ? {} : { acceptedBytes }) }
}

/**
 * Normalize a host `ERROR VFS_REFUSED` reply into the sink's refusal record.
 *
 * The host's stable wire reason (`file-too-large`, `no-space`,
 * `quota-exceeded`) maps to the same node errno code a Worker-side pre-check
 * raises, and the accepted prefix is carried for an appended mutation
 * (channel.md §4.8). A local sink guard never accepts a prefix.
 * @param diagnostic - parsed host refusal.
 * @returns the refused write's node-errno-shaped record.
 */
export function vfsRefusalRecordFromDiagnostic(diagnostic: VfsRefusedDiagnostic): VfsRefusalRecord {
  const code = vfsResourceErrorCode(diagnostic.reason)
  const acceptedBytes = diagnostic.acceptedBytes ?? 0
  return {
    code,
    path: diagnostic.path,
    limit: diagnostic.limit,
    hint: vfsRefusalHint(code, diagnostic.limit, diagnostic.path),
    acceptedBytes,
  }
}

/** Normalize the channel's structured refusal error the same way. */
export function vfsRefusalRecordFromChannelError(error: VfsRefusedError): VfsRefusalRecord {
  return {
    code: error.code,
    path: error.path,
    limit: error.limit,
    hint: vfsRefusalHint(error.code, error.limit, error.path),
    acceptedBytes: error.acceptedBytes,
  }
}

/** One line, so a hint cannot break the trailer grammar. */
function oneLine(text: string): string {
  return text.replace(/[\r\n]+/gu, ' ').trim()
}

/**
 * The shared contract trailer for a refusal.
 *
 * `pdsh-shell: exit=<n> program=<p> reason=<token> hint=<text>` is the existing
 * corpus grammar; `vfs` names the sink as the failing program and
 * `limit-refused` is the taxonomy member for a resource bound (shell-ext
 * `contract.ts`, `tools/shell-corpus/contract.mjs`).
 */
export function vfsRefusalTrailer(record: VfsRefusalRecord): string {
  return `pdsh-shell: exit=1 program=vfs reason=limit-refused hint=${oneLine(record.hint)}\n`
}

/** The model-facing error text, with the trailer as the final line. */
export function vfsRefusalMessage(record: VfsRefusalRecord): string {
  return `${record.code}: VFS refused ${record.path}: ${oneLine(record.hint)}\n${vfsRefusalTrailer(record)}`
}

/** The ERROR `VFS_REFUSED` payload for one refusal record. */
export function vfsRefusedPayload(record: VfsRefusalRecord): VfsRefusedPayload {
  return {
    code: 'VFS_REFUSED',
    message: `${record.code}: VFS refused ${record.path}: ${oneLine(record.hint)}`,
    path: record.path,
    limit: record.limit,
    reason: vfsRefusalReason(record.code),
  }
}

/** The CONSOLE audit line the sink sends alongside the ERROR frame. */
export function vfsRefusalConsoleText(record: VfsRefusalRecord): string {
  return `pdsh-vfs: ${record.code} refused ${record.path} (limit ${formatByteLimit(record.limit)}): ${oneLine(record.hint)}`
}
