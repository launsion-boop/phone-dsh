// SPDX-License-Identifier: MIT
/**
 * Phone-only Worker command acceptance receipt (G2-FIX-35).
 *
 * `workspace_command` is a Mac-host assertion: it runs `/bin/bash` against a
 * materialized copy of the workspace and never sees the Worker's in-memory
 * VFS. This route is the independent Worker-side assertion the runner calls
 * over the same authenticated connection the harness uses. It:
 *
 *   - captures an immutable, point-in-time fork of the Worker VFS roots
 *     (`/dsh/workspace`, `/dsh/home`, `/dsh/tmp`) into a local memory backend;
 *   - runs the requested Worker shell (or the Worker's `python3` toolbox) over
 *     that fork, never over the live VFS;
 *   - returns a receipt that binds the observation to scenario/session/turn
 *     and to the VFS watermark, with raw stdout/stderr, exit status, budget and
 *     cancellation facts, and the list of writes the fork absorbed.
 *
 * The route is served by the existing phone `/api` connection carrier (the
 * same launch-token/channel authentication as the recovery route), not by a
 * new network surface. It makes no model request and never opens the session
 * journal.
 * @module @phone-dsh/dsh-surface-phone/worker-command-controller
 */

import { createHash, randomUUID } from 'node:crypto'
import { promises as fsp } from 'node:fs'
import { posix } from 'node:path'
import {
  EXEC_INTERNAL_ROOTS,
  MemoryVfsBackend,
  WORKER_DEFAULT_CWD,
  WORKER_VFS_PREOPENS,
  isWithin,
} from '@phone-dsh/dsh-wasi-toolbox'
import {
  VfsFileSystem,
  WORKER_PATH_ALIASES,
  WorkerShell,
  createWorkerCommands,
} from '@phone-dsh/dsh-shell-ext'

/** Exact shared-API path the host posts to for one Worker command receipt. */
export const WORKER_COMMAND_PATH = '/api/pdsh-worker-command/execute'
/** Wire protocol recorded in every receipt. */
export const WORKER_COMMAND_PROTOCOL = 'pdsh-worker-command/1'
/** Largest accepted JSON body; a command, one binding and small options. */
export const WORKER_COMMAND_MAX_BODY_BYTES = 64 * 1024
/** Default execution budget; the assertion may lower (never exceed) this. */
export const WORKER_COMMAND_DEFAULT_BUDGET_MS = 30_000
/** Hard upper bound for one assertion command. */
export const WORKER_COMMAND_MAX_BUDGET_MS = 120_000
/** Largest stdout/stderr text returned verbatim; the byte counts stay exact. */
export const WORKER_COMMAND_MAX_OUTPUT_BYTES = 256 * 1024
/** Most VFS entries (files plus directories) one fork may capture. */
export const WORKER_COMMAND_MAX_SNAPSHOT_ENTRIES = 20_000
/** Most file bytes one fork may capture; the snapshot fails closed above it. */
export const WORKER_COMMAND_MAX_SNAPSHOT_BYTES = 64 * 1024 * 1024
/** Wall-clock share of the overall deadline reserved for capture/verify. */
export const WORKER_COMMAND_SNAPSHOT_TIMEOUT_MS = 5_000
/** Environment sentinel the Worker-side execution sets; a host shell does not. */
export const WORKER_COMMAND_LOCATION_ENV = 'PDSH_WORKER_COMMAND_LOCATION'
/** Environment sentinel recording that the command ran on the VFS fork. */
export const WORKER_COMMAND_FORK_ENV = 'PDSH_WORKER_VFS_FORK'
/** Default VFS roots the fork captures. */
export const WORKER_COMMAND_ROOTS = Object.freeze(['/dsh/workspace', '/dsh/home', '/dsh/tmp'])
/**
 * Legacy boolean capability marker for a trusted directory opener.
 *
 * The presence of `opendir` alone is not proof: the pinned DSH
 * `node:fs.promises.opendir` is built from `opendirSync` -> `readdirSync(...,
 * { withFileTypes: true })`, so it materialises the whole directory inside the
 * call, before capture can see one entry and before its deadline can fire.
 * Only an opener that explicitly opts in is trusted; an unmarked opener fails
 * the capture closed without being called. New production bridges expose the
 * separate bounded opener function below, because a boolean on the shared
 * opener cannot distinguish the capture's bounded call from an ordinary
 * `node:fs` read.
 */
export const WORKER_COMMAND_BOUNDED_OPENDIR = Symbol.for('@phone-dsh/dsh-surface-phone/bounded-opendir')

/**
 * Capability marker carrying a separate bounded directory opener function.
 *
 * The function receives the path the capture is about to read, plus the
 * capture's deadline/abort check as its last argument, and returns the same
 * directory handle as `opendir`. The bridge that supplies it must prove a
 * whole-VFS entry upper bound synchronously before calling the pinned
 * materialising opener and must run that check again after its synchronous
 * scans, so the shared `opendir` itself can stay unbounded for ordinary
 * DSH/session/storage reads.
 */
export const WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER = Symbol.for('@phone-dsh/dsh-surface-phone/bounded-directory-opener')

/**
 * Mark a directory opener as a verified incremental enumerator.
 *
 * This is a legacy contract, not a wrapper: the opener must return a `Dir`
 * whose `read()` yields one entry at a time and does not build the whole
 * listing first. Tests and a future runtime facade can opt in. The production
 * Worker bridge instead attaches {@link WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER}
 * so only the capture's calls are bounded.
 * @param {Function} opendir - directory opener to mark.
 * @returns {Function} the same opener, for convenient wiring.
 */
export function markBoundedDirectoryOpener(opendir) {
  if (typeof opendir !== 'function') {
    throw new TypeError('worker-command: a bounded directory opener must be a function')
  }
  Object.defineProperty(opendir, WORKER_COMMAND_BOUNDED_OPENDIR, {
    value: true, configurable: true,
  })
  return opendir
}

const SUPPORTED_PROGRAMS = new Set(['bash', 'sh', 'python3', 'python'])

/** Structured route failure with a stable code and HTTP status. */
export class WorkerCommandError extends Error {
  /**
   * @param {string} code - stable wire code (`worker-command/...`).
   * @param {string} message - human-readable detail.
   * @param {number} status - HTTP status the route answers.
   */
  constructor(code, message, status = 400) {
    super(message)
    this.name = 'WorkerCommandError'
    this.code = code
    this.status = status
  }
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  })
}

function failure(status, code, message) {
  return json({ ok: false, error: { code, message } }, status)
}

/** True for a non-empty string. */
function nonEmpty(value) {
  return typeof value === 'string' && value !== ''
}

/**
 * Canonical Worker VFS spelling for one absolute path.
 *
 * The shell's `VfsFileSystem` normalises with `posix.normalize` and applies
 * `WORKER_PATH_ALIASES` before every read (`/tmp` -> `/dsh/tmp`). The capture's
 * required-path check, the shell cwd and the receipt must use that same
 * spelling, or `cwd=/tmp/` would be searched for as a literal live `/tmp`
 * directory that the VFS never had.
 * @param {string} path - absolute virtual path already checked by the caller.
 * @returns {string} normalised, alias-mapped path.
 */
export function normalizeWorkerVfsPath(path) {
  const normalised = posix.normalize(path)
  // `posix.normalize` keeps a trailing slash (`/dsh/workspace/`). A cwd must
  // name the directory entry itself, not a second spelling of it.
  const canonical = normalised === '/' ? normalised : normalised.replace(/\/+$/, '')
  for (const alias of WORKER_PATH_ALIASES) {
    if (canonical === alias.from) return alias.to
    if (canonical.startsWith(`${alias.from}/`)) return `${alias.to}${canonical.slice(alias.from.length)}`
  }
  return canonical
}

/** Clamp one positive integer budget. */
function budgetOf(value) {
  if (value === undefined) return WORKER_COMMAND_DEFAULT_BUDGET_MS
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
    throw new WorkerCommandError('worker-command/bad-budget',
      'timeout_ms must be a positive number of milliseconds')
  }
  return Math.min(WORKER_COMMAND_MAX_BUDGET_MS, Math.max(1, Math.trunc(value)))
}

/** Message of an arbitrary thrown value. */
function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}

/** Reason carried by an aborted signal, with a stable fallback. */
function abortReason(signal, fallback = 'worker-command: aborted') {
  return signal?.reason instanceof Error ? signal.reason : new Error(fallback)
}

/**
 * Race one I/O promise against an abort signal without leaving the losing
 * promise unobserved. Filesystem facades are not required to understand
 * `AbortSignal`; a late result is simply discarded by the capture, which never
 * mutates the live VFS.
 * @template T
 * @param {Promise<T>} promise - the I/O operation.
 * @param {AbortSignal|undefined} signal - cancellation/deadline signal.
 * @returns {Promise<T>} the operation result or an abort rejection.
 */
function raceSignal(promise, signal) {
  if (signal === undefined) return promise
  if (signal.aborted) return Promise.reject(abortReason(signal))
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(abortReason(signal))
    signal.addEventListener('abort', onAbort, { once: true })
    promise.then(
      value => {
        signal.removeEventListener('abort', onAbort)
        resolve(value)
      },
      error => {
        signal.removeEventListener('abort', onAbort)
        reject(error)
      })
  })
}

/** Best-effort cleanup grace; a hanging close must not outlive the capture. */
const WORKER_COMMAND_CLOSE_GRACE_MS = 250

/**
 * Close one iterator/file handle without letting cleanup I/O defeat the
 * capture deadline. The close is always initiated, but it is awaited only for
 * a short grace or until the phase signal aborts. A close promise that never
 * settles is observed (so it cannot become an unhandled rejection) and then
 * abandoned; the fork only reads the live VFS, so a late close has no write
 * side effects.
 * @param {() => unknown} close - starts the close operation.
 * @param {AbortSignal|undefined} signal - phase/caller cancellation.
 * @param {number} graceMs - maximum time to wait for a cooperative close.
 * @returns {Promise<void>} always resolves.
 */
async function closeWithinBound(close, signal, graceMs = WORKER_COMMAND_CLOSE_GRACE_MS) {
  let pending
  try {
    pending = close()
  } catch {
    return
  }
  const settled = Promise.resolve(pending).then(() => {}, () => {})
  if (signal?.aborted === true) return
  let timer
  let onAbort
  const bound = new Promise(resolve => {
    timer = setTimeout(resolve, graceMs)
    if (signal !== undefined) {
      onAbort = () => resolve()
      signal.addEventListener('abort', onAbort, { once: true })
    }
  })
  try {
    await Promise.race([settled, bound])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
    if (onAbort !== undefined) signal?.removeEventListener('abort', onAbort)
  }
}

/**
 * One phase of the unified capture/execute/verify deadline.
 *
 * The timer aborts the phase signal at the absolute deadline; a parent (the
 * overall command) abort is forwarded too. `timedOut` distinguishes a phase
 * deadline from a caller cancellation.
 * @param {AbortSignal|undefined} parent - overall command signal.
 * @param {number} deadline - absolute epoch milliseconds.
 * @param {string} message - error message recorded on the timeout.
 * @returns {{signal: AbortSignal, timedOut: () => boolean, dispose: () => void}}.
 */
function phaseDeadline(parent, deadline, message) {
  const controller = new AbortController()
  let timedOut = false
  const remaining = deadline - Date.now()
  let timer
  if (remaining <= 0) {
    timedOut = true
    controller.abort(new WorkerCommandError('worker-command/snapshot-timeout', message, 504))
  } else {
    timer = setTimeout(() => {
      timedOut = true
      controller.abort(new WorkerCommandError('worker-command/snapshot-timeout', message, 504))
    }, remaining)
  }
  const onParent = () => controller.abort(parent?.reason)
  if (parent?.aborted === true) onParent()
  else parent?.addEventListener('abort', onParent, { once: true })
  return {
    signal: controller.signal,
    timedOut: () => timedOut || Date.now() >= deadline,
    dispose: () => {
      if (timer !== undefined) clearTimeout(timer)
      parent?.removeEventListener('abort', onParent)
    },
  }
}

/**
 * Fixed-size collector for one program stream.
 *
 * It stores at most `limit` bytes but counts every byte the program produced,
 * so `bytes`/`truncated` stay exact when a command writes far more than the
 * receipt should carry. A cancelled or timed-out program therefore cannot grow
 * this collector without bound.
 */
class BoundedStreamCapture {
  /** @param {number} limit - maximum retained bytes. */
  constructor(limit) {
    this.limit = limit
    /** @type {Buffer[]} */
    this.chunks = []
    this.retainedBytes = 0
    this.bytes = 0
    this.truncated = false
  }

  /** @param {Uint8Array|Buffer|string} chunk - one callback chunk. */
  push(chunk) {
    const bytes = typeof chunk === 'string' ? Buffer.from(chunk) : Buffer.from(chunk)
    this.bytes += bytes.byteLength
    const room = this.limit - this.retainedBytes
    if (room <= 0) {
      if (bytes.byteLength > 0) this.truncated = true
      return
    }
    const kept = bytes.byteLength <= room ? bytes : bytes.subarray(0, room)
    if (kept.byteLength > 0) {
      this.chunks.push(Buffer.from(kept))
      this.retainedBytes += kept.byteLength
    }
    if (kept.byteLength < bytes.byteLength) this.truncated = true
  }

  /** The bounded text plus the exact produced byte count. */
  finish() {
    return {
      text: Buffer.concat(this.chunks).toString('utf8'),
      bytes: this.bytes,
      retainedBytes: this.retainedBytes,
      truncated: this.truncated,
    }
  }
}

/**
 * Validate one request body and return the command/binding the route executes.
 * A missing scenario/session/turn binding is a caller bug, not a pass.
 * @param {unknown} body - parsed JSON body.
 * @returns {object} normalized request.
 */
export function validateWorkerCommandRequest(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw new WorkerCommandError('worker-command/bad-request', 'the request body must be a JSON object')
  }
  const value = /** @type {Record<string, unknown>} */ (body)
  const command = value.command
  if (!nonEmpty(command)) {
    throw new WorkerCommandError('worker-command/missing-command', 'the request needs a non-empty command')
  }
  const program = value.program ?? 'bash'
  if (typeof program !== 'string' || !SUPPORTED_PROGRAMS.has(program)) {
    throw new WorkerCommandError('worker-command/bad-program',
      `program must be one of ${[...SUPPORTED_PROGRAMS].join(', ')}`)
  }
  const scenarioId = value.scenario_id
  const sessionId = value.session_id
  const turn = value.turn
  if (!nonEmpty(scenarioId)) {
    throw new WorkerCommandError('worker-command/missing-binding', 'scenario_id is required')
  }
  if (!nonEmpty(sessionId)) {
    throw new WorkerCommandError('worker-command/missing-binding', 'session_id is required')
  }
  if (typeof turn !== 'number' || !Number.isSafeInteger(turn) || turn < 0) {
    throw new WorkerCommandError('worker-command/missing-binding',
      'turn must be a non-negative integer')
  }
  const assertionIndex = value.assertion_index
  if (typeof assertionIndex !== 'number' || !Number.isSafeInteger(assertionIndex) || assertionIndex < 0) {
    throw new WorkerCommandError('worker-command/missing-binding',
      'assertion_index must be a non-negative integer')
  }
  const watermark = value.completion_watermark
  if (watermark !== undefined
      && (typeof watermark !== 'number' || !Number.isSafeInteger(watermark) || watermark < 0)) {
    throw new WorkerCommandError('worker-command/missing-binding',
      'completion_watermark must be a non-negative integer')
  }
  const cwd = value.cwd ?? WORKER_DEFAULT_CWD
  if (typeof cwd !== 'string' || !cwd.startsWith('/')) {
    throw new WorkerCommandError('worker-command/bad-cwd', 'cwd must be an absolute Worker VFS path')
  }
  return {
    command,
    program,
    cwd: normalizeWorkerVfsPath(cwd),
    budgetMs: budgetOf(value.timeout_ms),
    scenarioId,
    sessionId,
    turn,
    assertionIndex,
    completionWatermark: watermark,
  }
}

/**
 * Environment of one fork execution. It is deliberately built from constants:
 * nothing from the host process (credentials included) enters the child.
 * @param {string} cwd - command working directory.
 * @returns {Record<string,string>} a scrubbed environment.
 */
export function workerCommandEnvironment(cwd) {
  return {
    PATH: '/usr/bin:/bin',
    HOME: '/dsh/home',
    PWD: cwd,
    TMPDIR: '/dsh/tmp',
    LANG: 'C',
    LC_ALL: 'C',
    [WORKER_COMMAND_LOCATION_ENV]: 'worker',
    [WORKER_COMMAND_FORK_ENV]: '1',
  }
}

/** Current Worker VFS mseq, or undefined outside the ordered-channel Worker. */
function currentWorkerMseq() {
  const channel = /** @type {{ nextMseq?: () => bigint } | undefined} */ (
    /** @type {Record<string, unknown>} */ (globalThis).__PDSH_CHANNEL__)
  if (channel === undefined || typeof channel.nextMseq !== 'function') return undefined
  const next = channel.nextMseq()
  return next > 0n ? Number(next - 1n) : 0
}

/** Resolve one Worker VFS path to the reader's real path. */
function realPath(root, path) {
  if (root === '' || root === '/') return path
  return `${root.replace(/\/+$/, '')}${path}`
}

/**
 * Deterministic hash over the complete captured state of a backend.
 *
 * A file name and its bytes are not the whole snapshot: an empty directory, a
 * file/directory mode change or a touch all change what a command can observe.
 * The digest therefore covers the sorted path, kind, mode and mtime of every
 * entry under `roots`, plus each file's bytes. Both the fork and the live
 * verification recapture run this same function over the same root list, so
 * `source.digest` is directly comparable with the verification digest.
 * @param {{list: () => readonly string[], stat: (path: string) => {kind: string,
 *   mode: number, mtimeMs: number}, readFile: (path: string) => Uint8Array}} backend - fork backend.
 * @param {readonly string[]} roots - captured roots the digest covers.
 * @returns {string} `sha256:<hex>` over the scoped backend state.
 */
function digestBackend(backend, roots) {
  const hash = createHash('sha256')
  const scoped = [...backend.list()]
    .filter(path => roots.some(root => isWithin(root, path)))
    .sort((left, right) => (left < right ? -1 : left > right ? 1 : 0))
  for (const path of scoped) {
    const stat = backend.stat(path)
    const mtimeMs = Number.isFinite(stat.mtimeMs) ? stat.mtimeMs : null
    hash.update(JSON.stringify([path, stat.kind, stat.mode, mtimeMs]))
    hash.update('\0')
    if (stat.kind === 'file') {
      const bytes = backend.readFile(path)
      hash.update(`file:${String(bytes.byteLength)}\0`)
      hash.update(bytes)
    } else {
      hash.update(`${stat.kind}\0`)
    }
    hash.update('\0')
  }
  return `sha256:${hash.digest('hex')}`
}

/** A missing root/child makes the snapshot incomplete, never an immutable fork. */
function missingPathFailure(virtual, cause, missingRoots = [virtual]) {
  const detail = cause instanceof Error && cause.message !== ''
    ? `: ${cause.message}`
    : ''
  const failure = new WorkerCommandError('worker-command/snapshot-missing-root',
    `worker-command: the required VFS path ${virtual} is missing${detail}`, 409)
  failure.missingRoots = [...missingRoots]
  return failure
}

/**
 * Capture an immutable fork of the Worker VFS into a memory backend.
 *
 * Reads are one bounded pass over the live mounted VFS; the returned backend is
 * never connected to the live sink, so a command's writes stay in the fork.
 * A symlink (or any other special file) fails the capture explicitly: the
 * in-memory backend cannot represent a link without risking an escape from the
 * allowed preopens, and silently dropping it would make a partial view look
 * like a complete immutable fork.
 * @param {{roots?: readonly string[], requiredPaths?: readonly string[], fs?: object,
 *   root?: string, mseqStart?: number, mseqEnd?: number, maxEntries?: number,
 *   maxBytes?: number, deadline?: number, signal?: AbortSignal}} options - reader/roots and bounds.
 * @returns {Promise<{backend: MemoryVfsBackend, entries: Map<string, Uint8Array>,
 *   digest: string, bytes: number, roots: string[], missing: string[],
 *   mseqStart: number|undefined, mseqEnd: number|undefined, sourceFrozen: boolean}>}
 */
export async function captureWorkerVfsFork(options = {}) {
  const roots = options.roots ?? WORKER_COMMAND_ROOTS
  const requiredPaths = options.requiredPaths ?? []
  const fs = options.fs ?? fsp
  const root = options.root ?? ''
  const maxEntries = options.maxEntries ?? WORKER_COMMAND_MAX_SNAPSHOT_ENTRIES
  const maxBytes = options.maxBytes ?? WORKER_COMMAND_MAX_SNAPSHOT_BYTES
  const deadline = options.deadline ?? Number.POSITIVE_INFINITY
  const parentSignal = options.signal
  let signal = parentSignal
  let deadlineTimer
  let removeParentAbort
  if (Number.isFinite(deadline)) {
    const local = new AbortController()
    const remaining = deadline - Date.now()
    if (remaining <= 0) {
      local.abort(new WorkerCommandError('worker-command/snapshot-timeout',
        'worker-command: the VFS snapshot exceeded its deadline', 504))
    } else {
      deadlineTimer = setTimeout(() => {
        local.abort(new WorkerCommandError('worker-command/snapshot-timeout',
          'worker-command: the VFS snapshot exceeded its deadline', 504))
      }, remaining)
    }
    const onParentAbort = () => local.abort(parentSignal?.reason)
    if (parentSignal?.aborted === true) onParentAbort()
    else parentSignal?.addEventListener('abort', onParentAbort, { once: true })
    removeParentAbort = () => parentSignal?.removeEventListener('abort', onParentAbort)
    signal = local.signal
  }
  const entries = new Map()
  const fileMetadata = new Map()
  const directories = new Map([['/', { mode: 0o755, mtimeMs: undefined }]])
  const missing = []
  const mseqStart = options.mseqStart ?? currentWorkerMseq()
  let entriesCount = 0
  let bytes = 0

  function checkLive() {
    if (signal?.aborted === true) throw abortReason(signal)
    if (Date.now() >= deadline) {
      throw new WorkerCommandError('worker-command/snapshot-timeout',
        'worker-command: the VFS snapshot exceeded its deadline', 504)
    }
  }

  async function io(run) {
    checkLive()
    return await raceSignal(Promise.resolve().then(run), signal)
  }

  function snapshotBudgetError() {
    return new WorkerCommandError('worker-command/snapshot-budget',
      `worker-command: the VFS snapshot exceeds its ${String(maxEntries)} entries / `
        + `${String(maxBytes)} bytes budget`, 507)
  }

  function unsupportedOperation(error) {
    const code = error?.code
    return code === 'ENOSYS' || code === 'ENOTSUP' || code === 'EOPNOTSUPP'
      || code === 'ERR_METHOD_NOT_IMPLEMENTED' || code === 'ERR_NOT_IMPLEMENTED'
      || /not implemented|unsupported/iu.test(messageOf(error))
  }

  /**
   * A reader without the streaming member cannot be used safely: the only
   * fallback (`readdir`/`readFile`) materialises the whole directory/file
   * before any budget check, so a huge live object could exhaust the Worker
   * heap before the capture rejects it. Fail closed instead of pretending the
   * snapshot is bounded.
   * @param {string} operation - missing streaming operation.
   * @param {string} path - virtual path being read.
   * @returns {WorkerCommandError} the typed unsupported-reader failure.
   */
  function streamingRequired(operation, path, detail) {
    return new WorkerCommandError('worker-command/snapshot-unsupported',
      `worker-command: the VFS reader has no bounded ${operation} for ${path}; `
        + (detail ?? 'refusing to materialise an unbounded live object'), 422)
  }

  /**
   * Read one directory without materialising an unbounded children array.
   *
   * `opendir`/`Dir.read()` is accepted only when the shared opener carries a
   * separate {@link WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER} function or the
   * legacy {@link WORKER_COMMAND_BOUNDED_OPENDIR} boolean marker. An unmarked
   * `opendir` may be a materialising facade: the pinned DSH runtime implements
   * it with `opendirSync` -> `readdirSync(..., { withFileTypes: true })`, which
   * allocates the whole listing synchronously before `read()` is ever called
   * and cannot be interrupted by the deadline. Refuse before that call rather
   * than pretending the entry budget is enforced. The function form keeps the
   * bound on capture calls only; ordinary `node:fs` reads stay unbounded. The
   * bounded call also receives {@link checkLive}, so the bridge can re-check
   * the phase deadline/abort after its synchronous scans and before it enters
   * the materialising original opener.
   * @param {string} path - real reader path of the directory.
   * @param {string} virtual - Worker VFS path used for failure reporting.
   */
  async function readDirectory(path, virtual) {
    if (typeof fs.opendir !== 'function') throw streamingRequired('opendir', path)
    const opener = fs.opendir
    const boundedOpener = opener[WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER]
    const legacyMarked = opener[WORKER_COMMAND_BOUNDED_OPENDIR] === true
    if (typeof boundedOpener !== 'function' && !legacyMarked) {
      throw streamingRequired('opendir', path,
        'the reader\'s opendir is neither a separate bounded opener nor a legacy verified '
          + 'incremental enumerator (the pinned DSH facade materialises the whole listing inside '
          + 'opendir); refusing before the call')
    }
    let directory
    try {
      directory = await io(() => typeof boundedOpener === 'function'
        ? boundedOpener.call(fs, path, checkLive)
        : opener.call(fs, path))
    } catch (error) {
      if (error?.code === 'ENOENT') throw missingPathFailure(virtual, error, [virtual])
      if (unsupportedOperation(error)) throw streamingRequired('opendir', path)
      throw error
    }
    if (directory === null || directory === undefined
        || typeof directory.read !== 'function') {
      await closeWithinBound(() => directory?.close?.(), signal)
      throw streamingRequired('opendir', path)
    }
    const children = []
    try {
      while (true) {
        let child
        try {
          child = await io(() => directory.read())
        } catch (error) {
          // The directory disappeared after its lstat but before/during the
          // listing. That is a missing child, not an opaque snapshot failure.
          if (error?.code === 'ENOENT') throw missingPathFailure(virtual, error, [virtual])
          throw error
        }
        if (child === null || child === undefined) break
        if (entriesCount + children.length + 1 > maxEntries) throw snapshotBudgetError()
        children.push(child)
      }
    } finally {
      await closeWithinBound(() => directory.close?.(), signal)
    }
    return children
  }

  /**
   * Read one file under the remaining byte budget. The production face has
   * `open`; that path never allocates more than the remaining budget plus one
   * probe byte. A reader without a streaming `open`/`read` fails closed rather
   * than calling `readFile`, which would materialise the whole live file before
   * the byte budget can reject it.
   */
  async function readFileBounded(path, virtual, remaining) {
    if (remaining < 0) throw snapshotBudgetError()
    if (typeof fs.open !== 'function') throw streamingRequired('open', virtual)
    let handle
    try {
      handle = await io(() => fs.open(path, 'r'))
    } catch (error) {
      if (error?.code === 'ENOENT') throw missingPathFailure(virtual, error)
      if (unsupportedOperation(error)) throw streamingRequired('open', virtual)
      throw error
    }
    if (handle === null || handle === undefined || typeof handle.read !== 'function') {
      await closeWithinBound(() => handle?.close?.(), signal)
      throw streamingRequired('open', virtual)
    }
    const chunks = []
    let total = 0
    try {
      while (true) {
        const room = remaining - total
        if (room < 0) throw snapshotBudgetError()
        const length = Math.min(64 * 1024, room + 1)
        const buffer = Buffer.alloc(length)
        const read = await io(() => handle.read(buffer, 0, length, null))
        const count = typeof read === 'number' ? read : read?.bytesRead ?? 0
        if (count === 0) break
        total += count
        if (total > remaining) throw snapshotBudgetError()
        chunks.push(buffer.subarray(0, count))
      }
    } finally {
      await closeWithinBound(() => handle.close(), signal)
    }
    return Buffer.concat(chunks, total)
  }

  async function walk(virtual) {
    // The Worker patches its execution-facing `node:fs.promises` with the
    // namespace read policy, so `/dsh/home/sessions`, `/dsh/home/storages` and
    // `/dsh/home/tool-journal` answer EACCES. The fork must have the same
    // visibility an execution surface has: skip them, do not disable the
    // policy and do not report them as missing roots.
    if (EXEC_INTERNAL_ROOTS.some(internal => isWithin(internal, virtual))) return
    const path = realPath(root, virtual)
    let stats
    try {
      stats = await io(() => fs.lstat(path))
    } catch (error) {
      // A missing root or child means the snapshot is not the live view. Do
      // not continue and later call the partial capture an immutable fork.
      if (error?.code === 'ENOENT') {
        missing.push(virtual)
        throw missingPathFailure(virtual, error)
      }
      throw error
    }
    entriesCount += 1
    if (entriesCount > maxEntries) throw snapshotBudgetError()
    if (stats.isSymbolicLink?.() === true) {
      throw new WorkerCommandError('worker-command/symlink-unsupported',
        `worker-command: ${virtual} is a symbolic link; the immutable memory fork cannot preserve it safely`, 422)
    }
    if (stats.isDirectory()) {
      directories.set(virtual, { mode: stats.mode, mtimeMs: stats.mtimeMs })
      const children = await readDirectory(path, virtual)
      for (const child of children) {
        await walk(posix.join(virtual, child.name))
      }
      return
    }
    if (stats.isFile()) {
      const declaredBytes = typeof stats.size === 'number' ? stats.size : 0
      if (bytes + declaredBytes > maxBytes) throw snapshotBudgetError()
      const data = await readFileBounded(path, virtual, maxBytes - bytes)
      bytes += data.byteLength
      entries.set(virtual, data)
      fileMetadata.set(virtual, { mode: stats.mode, mtimeMs: stats.mtimeMs })
      return
    }
    throw new WorkerCommandError('worker-command/special-file-unsupported',
      `worker-command: ${virtual} is not a regular file or directory; the immutable memory fork cannot preserve it`, 422)
  }

  try {
    for (const virtual of roots) await walk(virtual)
    for (const required of requiredPaths) {
      checkLive()
      // A cwd is a working directory. A file with the same name is not an
      // acceptable substitute: the shell could not chdir into it, so the
      // snapshot would look complete while the command is doomed.
      if (!directories.has(required)) {
        const detail = entries.has(required) ? new Error('not a directory') : undefined
        throw missingPathFailure(required, detail, [required])
      }
    }
    checkLive()
    const backend = new MemoryVfsBackend()
    for (const [directory, metadata] of [...directories]
      .sort(([left], [right]) => left.length - right.length)) {
      if (directory === '/') continue
      checkLive()
      try {
        backend.seedDirectory(directory, metadata.mode, metadata.mtimeMs)
      } catch {
        // A parent that the backend already created is enough.
      }
    }
    for (const [virtual, data] of entries) {
      checkLive()
      const metadata = fileMetadata.get(virtual)
      backend.seedFile(virtual, data, metadata?.mode ?? 0o644, metadata?.mtimeMs)
    }
    return finishFork(backend, entries, roots, missing, mseqStart, options.mseqEnd)
  } finally {
    if (deadlineTimer !== undefined) clearTimeout(deadlineTimer)
    removeParentAbort?.()
  }
}

function finishFork(backend, entries, roots, missing, mseqStart, explicitEnd) {
  const bytes = [...entries.values()].reduce((total, data) => total + data.byteLength, 0)
  const mseqEnd = explicitEnd ?? currentWorkerMseq()
  return {
    backend,
    entries,
    digest: digestBackend(backend, roots),
    bytes,
    roots: [...roots],
    missing,
    mseqStart,
    mseqEnd,
    sourceFrozen: missing.length === 0 && mseqStart !== undefined && mseqStart === mseqEnd,
  }
}

/**
 * Adapt the memory backend to the Promise filesystem face `VfsFileSystem`
 * expects. All writes therefore land in the fork, never the live VFS.
 * @param {MemoryVfsBackend} backend - fork backend.
 * @returns {object} `VfsFileSystemIo`-shaped object plus a synchronous reader.
 */
export function createForkFileSystemFace(backend) {
  const statsOf = (stat) => {
    // The fork stores the one timestamp the live VFS exposes (`mtimeMs`).
    // just-bash reads Date-valued `mtime` directly (`ls`), and the Worker stat
    // shim formats `stat -c %y`/`%T@` from it, so an mtimeMs-only object made
    // those commands show 1970 or throw. Keep every timestamp explicit and
    // equal to the stored mtime: the source cannot distinguish atime/ctime.
    const time = new Date(stat.mtimeMs)
    return {
      size: stat.size,
      mode: stat.mode,
      mtimeMs: time.getTime(),
      atimeMs: time.getTime(),
      ctimeMs: time.getTime(),
      birthtimeMs: time.getTime(),
      mtime: time,
      atime: time,
      ctime: time,
      birthtime: time,
      ino: stat.ino,
      dev: 0,
      uid: 0,
      gid: 0,
      isFile: () => stat.kind === 'file',
      isDirectory: () => stat.kind === 'directory',
      isSymbolicLink: () => stat.kind === 'symlink',
    }
  }
  const dirent = (entry) => ({
    name: entry.name,
    isFile: () => entry.kind === 'file',
    isDirectory: () => entry.kind === 'directory',
    isSymbolicLink: () => entry.kind === 'symlink',
  })
  const toBytes = (data, options) => {
    if (typeof data !== 'string') return new Uint8Array(data)
    return new Uint8Array(Buffer.from(data, options?.encoding ?? 'utf8'))
  }
  const face = {
    async readFile(path) {
      return Buffer.from(backend.readFile(path))
    },
    async readFileRange(path, start, length) {
      return Buffer.from(backend.readFile(path).slice(start, start + length))
    },
    async writeFile(path, data, options) {
      if (options?.flag === 'wx') {
        try {
          backend.stat(path)
          throw Object.assign(new Error('EEXIST: file already exists'), { code: 'EEXIST' })
        } catch (error) {
          if (error?.code !== 'ENOENT') throw error
        }
      }
      backend.writeFile(path, toBytes(data, options), {
        create: true,
        truncate: true,
        ...(options?.mode === undefined ? {} : { mode: options.mode }),
      })
    },
    async appendFile(path, data, options) {
      backend.writeFile(path, toBytes(data, options), { create: true, append: true })
    },
    async stat(path) { return statsOf(backend.stat(path)) },
    async lstat(path) { return statsOf(backend.stat(path)) },
    async access(path) { backend.stat(path) },
    async mkdir(path, options) {
      if (options?.recursive === true) {
        const parts = path.split('/').filter(Boolean)
        let current = ''
        for (const part of parts) {
          current += `/${part}`
          try { backend.mkdir(current, options.mode) } catch (error) {
            if (error?.code !== 'EEXIST') throw error
          }
        }
        return
      }
      backend.mkdir(path, options?.mode)
    },
    async readdir(path, options) {
      const entries = backend.readdir(path)
      return options?.withFileTypes === true ? entries.map(dirent) : entries.map(entry => entry.name)
    },
    async rm(path, options) {
      const stat = backend.stat(path)
      if (stat.kind === 'directory') backend.unlink(path, { directory: true, recursive: options?.recursive === true })
      else backend.unlink(path)
    },
    async cp(from, to, options) {
      const stat = backend.stat(from)
      if (stat.kind === 'directory') {
        if (options?.recursive !== true) throw Object.assign(new Error('EISDIR'), { code: 'EISDIR' })
        backend.seedDirectory(to, stat.mode, stat.mtimeMs)
        for (const entry of backend.readdir(from)) {
          await face.cp(`${from}/${entry.name}`, `${to}/${entry.name}`, options)
        }
        return
      }
      backend.writeFile(to, backend.readFile(from), {
        create: true,
        truncate: true,
        mode: stat.mode,
      })
    },
    async rename(from, to) { backend.rename(from, to) },
    async chmod(path, mode) {
      // Keep the real VFS metadata: a copied capture must answer `test -x`,
      // `stat`/`ls -l` and `cp -a` from the mode the Worker actually has, and
      // a directory needs its own mode as well as a file's.
      backend.chmod(path, mode)
    },
    async link(existing, next) { backend.writeFile(next, backend.readFile(existing), { create: true }) },
  }
  // VfsFileSystem.getAllPaths() calls this synchronously for glob matching;
  // it must never return the Promise face.
  const syncReaddir = (path, _options) => backend.readdir(path).map(dirent)
  return { face, syncReaddir }
}

/**
 * Build a fresh Python runtime over the fork. It reads the immutable image
 * artifacts through the read-only live VFS reader; the interpreter's writes go
 * through the fork backend only.
 */
async function defaultPythonRuntime({ fork, cwd, fs, root }) {
  const reader = fs ?? fsp
  const read = async path => new Uint8Array(await reader.readFile(realPath(root ?? '', path)))
  let wasm
  let stdlib
  try {
    wasm = await read('/dsh/bin/python/python.wasm')
    stdlib = await read('/dsh/bin/python/python313.zip')
  } catch {
    return undefined
  }
  const { PythonRuntime } = await import('@phone-dsh/dsh-wasi-toolbox/python')
  const workerUrl = globalThis[Symbol.for('@phone-dsh/worker-entry/python-worker-url')]
  return new PythonRuntime({
    ...typeof workerUrl === 'string' ? { workerUrl } : {},
    backend: fork.backend,
    wasm,
    stdlib,
    preopens: WORKER_VFS_PREOPENS,
    cwd,
  })
}

/** True only when this image really carries both CPython WASI artifacts. */
async function defaultPythonArtifactsAvailable({ fs, root, signal }) {
  const reader = fs ?? fsp
  const lstat = typeof reader.lstat === 'function'
    ? reader.lstat
    : typeof reader.stat === 'function' ? reader.stat : undefined
  if (lstat === undefined) return false
  for (const path of ['/dsh/bin/python/python.wasm', '/dsh/bin/python/python313.zip']) {
    try {
      const stats = await raceSignal(
        Promise.resolve().then(() => lstat.call(reader, realPath(root ?? '', path))), signal)
      if (stats === null || stats === undefined) return false
      if (typeof stats.isFile === 'function' && !stats.isFile()) return false
      if (typeof stats.size === 'number' && stats.size <= 0) return false
    } catch (error) {
      if (signal?.aborted === true) throw abortReason(signal)
      return false
    }
  }
  return true
}

/**
 * Build the local toolbox facade over one fork.
 *
 * This deliberately never consults `globalThis.__PDSH_WASI_TOOLBOX__`: that is
 * the live Worker's toolbox, with live preopens, and a fork command must not
 * fall back to it. The facade registers `python3` only when the image actually
 * carries both Python artifacts, so `command -v python3` cannot claim a
 * program the image does not have. A missing artifact becomes a real exit 127
 * from the local facade; the caller does not silently disappear the program.
 * @param {object} fork - captured fork.
 * @param {object} options - executor seams (`python`, `createPythonRuntime`).
 * @param {AbortSignal|undefined} signal - overall command signal.
 * @returns {Promise<object|undefined>} the local toolbox, or undefined when
 *   disabled/absent.
 */
async function forkToolbox(fork, options, signal) {
  if (options.python === false) return undefined
  if (options.python !== undefined) return options.python
  if (!await defaultPythonArtifactsAvailable({ fs: options.fs, root: options.root, signal })) {
    return undefined
  }
  return {
    preopenTable: WORKER_VFS_PREOPENS,
    list: () => [{ program: 'python3', aliases: ['python'] }],
    has: program => program === 'python3' || program === 'python',
    async run(request) {
      const create = options.createPythonRuntime ?? defaultPythonRuntime
      const runtime = await create({ fork, cwd: request.cwd ?? WORKER_DEFAULT_CWD, fs: options.fs, root: options.root })
      if (runtime === undefined) {
        return {
          program: 'python3', exitCode: 127, cancelled: false, memoryExceeded: false,
          memoryPeakBytes: 0, stdoutBytes: 0, stderrBytes: 0,
        }
      }
      try {
        return await runtime.run(request)
      } finally {
        await runtime.dispose?.()
      }
    },
  }
}

/** Programs whose live implementation must never appear in the fork PATH. */
const FORK_EXCLUDED_COMMANDS = Object.freeze(['jq'])

/**
 * The command table a fork may run.
 *
 * `git` and `curl` need live runtime state and stay out. `jq` currently reads
 * the published live toolbox by itself (`createJqCommand()` takes no toolbox),
 * so the fork's shell disables it entirely (built-in, shadow and PATH names).
 * The explicit failing entry below is a defence for any caller that assembles
 * this table without `disabledCommands`. There is no `allowJq` opt-in: a future
 * fork-bound jq must be an explicit local implementation, never the live
 * global runtime.
 * @param {object|undefined} toolbox - local fork toolbox.
 * @returns {readonly object[]} the fork command table.
 */
function forkCommands(toolbox) {
  const commands = createWorkerCommands({
    git: false,
    curl: false,
    toolbox: toolbox ?? false,
  })
  return commands.map(command => command.name !== 'jq' ? command : {
    name: 'jq',
    execute: async () => ({
      stdout: '',
      stderr: 'worker-command: jq is not supported on the immutable VFS fork; '
        + 'the assertion fails instead of reading the live jq runtime\n',
      exitCode: 127,
    }),
  })
}

/** Capture one command result from the just-bash shell. */
async function runBash(fork, request, options) {
  const { face, syncReaddir } = createForkFileSystemFace(fork.backend)
  const fs = new VfsFileSystem({ root: '', nodeFs: face, readdirSync: syncReaddir, workerPaths: true })
  const toolbox = await forkToolbox(fork, options, request.signal)
  const commands = forkCommands(toolbox)
  const maxOutputBytes = Number.isFinite(options.maxOutputBytes) && options.maxOutputBytes > 0
    ? Math.floor(options.maxOutputBytes)
    : WORKER_COMMAND_MAX_OUTPUT_BYTES
  // `disabledCommands` removes jq from the built-in registry, every shadow and
  // the PATH/capability names. A failing table entry alone is not enough:
  // just-bash's `command -v`/`type` would still report the registered name.
  const shell = new WorkerShell({
    fs,
    commands,
    maxOutputBytes,
    disabledCommands: FORK_EXCLUDED_COMMANDS,
  })
  const argv = request.program === 'bash'
    ? ['bash', '-c', request.command]
    : ['sh', '-c', request.command]
  const result = await shell.run(argv, {
    cwd: request.cwd,
    env: workerCommandEnvironment(request.cwd),
    timeoutMs: request.budgetMs,
    maxOutputBytes,
    signal: request.signal,
    stdin: '',
  })
  return {
    exitCode: result.exitCode,
    timedOut: result.timedOut === true,
    cancelled: result.aborted === true,
    stdout: result.stdout,
    stderr: result.stderr,
    stdoutBytes: result.stdoutOriginalBytes ?? Buffer.byteLength(result.stdout, 'utf8'),
    stderrBytes: result.stderrOriginalBytes ?? Buffer.byteLength(result.stderr, 'utf8'),
    stdoutTruncated: result.stdoutTruncated === true,
    stderrTruncated: result.stderrTruncated === true,
  }
}

/** Run one program through the fork toolbox (python). */
async function runToolbox(fork, request, options) {
  const toolbox = await forkToolbox(fork, options, request.signal)
  if (toolbox === undefined) {
    const message = 'worker-command: python3 is not installed in this Worker image\n'
    return {
      exitCode: 127,
      timedOut: false,
      cancelled: false,
      stdout: '',
      stderr: message,
      stdoutBytes: 0,
      stderrBytes: Buffer.byteLength(message, 'utf8'),
      stdoutTruncated: false,
      stderrTruncated: false,
    }
  }
  const stdout = new BoundedStreamCapture(WORKER_COMMAND_MAX_OUTPUT_BYTES)
  const stderr = new BoundedStreamCapture(WORKER_COMMAND_MAX_OUTPUT_BYTES)
  const controller = new AbortController()
  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    controller.abort(new Error(`worker-command: python3 exceeded its ${String(request.budgetMs)} ms budget`))
  }, request.budgetMs)
  const onExternalAbort = () => {
    if (!controller.signal.aborted) controller.abort(abortReason(request.signal))
  }
  if (request.signal?.aborted === true) onExternalAbort()
  else request.signal?.addEventListener('abort', onExternalAbort, { once: true })
  const signal = controller.signal
  let result
  try {
    // A runtime that ignores its AbortSignal must not make the receipt wait
    // forever: the race settles at the budget/cancel bound. Its late run stays
    // confined to the in-memory fork and cannot touch the live VFS.
    result = await raceSignal(toolbox.run({
      program: 'python3',
      argv: ['-c', request.command],
      cwd: request.cwd,
      env: workerCommandEnvironment(request.cwd),
      signal,
      onStdout: chunk => stdout.push(chunk),
      onStderr: chunk => stderr.push(chunk),
    }), signal)
  } catch (error) {
    if (!signal.aborted) throw error
    result = {
      exitCode: timedOut ? 124 : 130,
      cancelled: !timedOut,
      memoryExceeded: false,
      memoryPeakBytes: 0,
      stdoutBytes: 0,
      stderrBytes: 0,
    }
  } finally {
    clearTimeout(timer)
    request.signal?.removeEventListener('abort', onExternalAbort)
  }
  const out = stdout.finish()
  const err = stderr.finish()
  return {
    exitCode: timedOut ? 124 : signal.aborted ? 130 : result.exitCode,
    timedOut,
    cancelled: timedOut ? false : signal.aborted || result.cancelled === true,
    stdout: out.text,
    stderr: err.text,
    stdoutBytes: out.bytes,
    stderrBytes: err.bytes,
    stdoutTruncated: out.truncated,
    stderrTruncated: err.truncated,
  }
}

/** Turn a capture/verify failure into the receipt's stable failure facts. */
function snapshotFailure(error, externalSignal, phase) {
  const cancelled = externalSignal?.aborted === true && !phase.timedOut()
  const timedOut = !cancelled
    && (phase.timedOut() || error?.code === 'worker-command/snapshot-timeout')
  const code = cancelled
    ? 'worker-command/snapshot-cancelled'
    : error instanceof WorkerCommandError
      ? error.code
      : timedOut ? 'worker-command/snapshot-timeout' : 'worker-command/snapshot-failed'
  return {
    code,
    detail: messageOf(error),
    timedOut,
    cancelled,
    exitCode: timedOut ? 124 : cancelled ? 130 : 1,
    missingRoots: Array.isArray(error?.missingRoots) ? [...error.missingRoots] : [],
  }
}

/** Stable execution-failure facts while keeping the captured fork evidence. */
function executionFailure(error, externalSignal, phase) {
  const cancelled = externalSignal?.aborted === true && !phase.timedOut()
  const timedOut = !cancelled && phase.timedOut()
  const code = cancelled
    ? 'worker-command/execution-cancelled'
    : timedOut ? 'worker-command/execution-timeout' : 'worker-command/execution-failed'
  return {
    code,
    detail: messageOf(error),
    timedOut,
    cancelled,
    exitCode: timedOut ? 124 : cancelled ? 130 : 1,
  }
}

/**
 * A failed capture still returns a protocol receipt, but it never claims an
 * immutable fork: `location.fork` is `none`, `source.fork` is false and
 * `source.source_frozen` is false. The command did not run, and the assertion
 * must fail on the receipt rather than on a fabricated host fallback.
 */
function captureFailureReceipt(request, startedAt, mseqStart, failure) {
  const carrier = currentWorkerMseq() === undefined ? 'surface-process' : 'ordered-channel'
  const stdout = ''
  const stderr = `${failure.detail}\n`
  return {
    protocol: WORKER_COMMAND_PROTOCOL,
    receipt_id: `wc-${randomUUID()}`,
    location: {
      kind: 'worker',
      carrier,
      worker_vfs: false,
      host_process: false,
      fork: 'none',
    },
    binding: {
      scenario_id: request.scenarioId,
      session_id: request.sessionId,
      turn: request.turn,
      assertion_index: request.assertionIndex,
      ...(request.completionWatermark === undefined
        ? {} : { completion_watermark: request.completionWatermark }),
    },
    source: {
      kind: 'worker-vfs-fork',
      fork: false,
      roots: [...WORKER_COMMAND_ROOTS],
      missing_roots: [...failure.missingRoots ?? []],
      source_mseq_start: mseqStart,
      source_mseq_end: mseqStart,
      source_frozen: false,
      digest: '',
      entries: 0,
      bytes: 0,
      failure: failure.code,
      failure_detail: failure.detail,
      timed_out: failure.timedOut,
    },
    execution: {
      program: request.program,
      cwd: request.cwd,
      budget_ms: request.budgetMs,
      duration_ms: Date.now() - startedAt,
      exit_code: failure.exitCode,
      timed_out: failure.timedOut,
      cancelled: failure.cancelled,
      stdout,
      stderr,
      stdout_bytes: 0,
      stderr_bytes: Buffer.byteLength(stderr, 'utf8'),
      stdout_truncated: false,
      stderr_truncated: false,
    },
    model_requests: 0,
    live_workspace_unchanged: false,
    side_effects: {
      isolated: true,
      live_workspace: false,
      journal: false,
      changes: [],
      changed: 0,
    },
  }
}

/**
 * Prove the live workspace still matches the fork without an unbounded second
 * read. A frozen ordered-channel watermark is already that proof; otherwise a
 * bounded, deadline-bound re-capture of the same roots is compared by the same
 * full-state digest as `source.digest` (paths, kinds, modes, mtimes and file
 * bytes). A verify failure is reported as `live_workspace_unchanged: false`,
 * never as a pass.
 *
 * Both proofs require their own capture to be frozen. An equal digest alone is
 * not enough: a writer can change the live tree after verification read the old
 * bytes but before its capture ended, leaving the old digest intact while
 * `sourceFrozen` is already false. Likewise the mseq shortcut is only valid for
 * a fork that was itself frozen at one watermark.
 */
async function verifyLiveWorkspace(fork, options, deadline, signal) {
  const mseqNow = currentWorkerMseq()
  if (fork.sourceFrozen === true
      && fork.mseqEnd !== undefined
      && mseqNow === fork.mseqEnd) {
    return { unchanged: true, method: 'mseq', digest: fork.digest }
  }
  const live = await captureWorkerVfsFork({
    fs: options.fs,
    root: options.root,
    // Re-capture exactly the roots the source digest covers. The same bounded
    // capture, budgets and deadline apply; comparing that digest with
    // `fork.digest` is a state proof, not just a file-content comparison.
    roots: fork.roots,
    mseqStart: mseqNow,
    maxEntries: options.maxEntries,
    maxBytes: options.maxBytes,
    deadline,
    signal,
  })
  if (live.sourceFrozen !== true) {
    return {
      unchanged: false,
      method: 'digest',
      digest: live.digest,
      failure: 'worker-command/live-workspace-changed',
      failure_detail: 'worker-command: the live workspace moved during verification; '
        + 'its digest is not a frozen snapshot',
    }
  }
  if (live.digest !== fork.digest) {
    return {
      unchanged: false,
      method: 'digest',
      digest: live.digest,
      failure: 'worker-command/live-workspace-changed',
      failure_detail: 'worker-command: the live workspace digest changed after the fork was captured',
    }
  }
  return { unchanged: true, method: 'digest', digest: live.digest }
}

/**
 * Execute one validated request on an immutable Worker VFS fork and return the
 * receipt body. This is the production executor; tests may inject it.
 *
 * Capture, execution and the live-workspace proof share one overall deadline.
 * Capture gets the first snapshot share, execution the assertion's own budget,
 * and verification the remaining snapshot share. Every filesystem I/O races
 * that signal, so a reader that does not support cancellation still returns a
 * bounded receipt; late reads have no write side effects.
 * @param {object} request - normalized request from {@link validateWorkerCommandRequest}.
 * @param {object} options - reader/root/executor seams.
 * @returns {Promise<object>} the `value` object of the route response.
 */
export async function executeWorkerCommandInFork(request, options = {}) {
  // Direct callers may bypass the route validator. Apply the same VFS spelling
  // here so capture requiredPaths, the fork shell cwd and the receipt all agree.
  const normalizedCwd = normalizeWorkerVfsPath(request.cwd)
  if (normalizedCwd !== request.cwd) request = { ...request, cwd: normalizedCwd }
  const startedAt = Date.now()
  const snapshotTimeoutMs = options.snapshotTimeoutMs ?? WORKER_COMMAND_SNAPSHOT_TIMEOUT_MS
  const overallDeadline = startedAt + snapshotTimeoutMs * 2 + request.budgetMs
  const overall = phaseDeadline(options.signal, overallDeadline,
    'worker-command: the Worker VFS fork operation exceeded its overall deadline')
  const mseqStart = currentWorkerMseq()
  const captureDeadline = startedAt + snapshotTimeoutMs
  let fork
  try {
    try {
      const capturePhase = phaseDeadline(overall.signal, captureDeadline,
        'worker-command: the VFS snapshot exceeded its deadline')
      try {
        fork = await captureWorkerVfsFork({
          fs: options.fs,
          root: options.root,
          mseqStart,
          requiredPaths: [request.cwd],
          maxEntries: options.maxEntries,
          maxBytes: options.maxBytes,
          deadline: captureDeadline,
          signal: capturePhase.signal,
        })
      } catch (error) {
        return captureFailureReceipt(request, startedAt, mseqStart,
          snapshotFailure(error, options.signal, capturePhase))
      } finally {
        capturePhase.dispose()
      }
    } catch (error) {
      return captureFailureReceipt(request, startedAt, mseqStart,
        snapshotFailure(error, options.signal, overall))
    }
    let execution
    try {
      const remaining = Math.max(1, overallDeadline - Date.now())
      const executionRequest = {
        ...request,
        budgetMs: Math.max(1, Math.min(request.budgetMs, remaining)),
        signal: overall.signal,
      }
      execution = request.program === 'python3' || request.program === 'python'
        ? await runToolbox(fork, executionRequest, options)
        : await runBash(fork, executionRequest, options)
    } catch (error) {
      // Capture already succeeded. Keep its fork/digest/entries as evidence;
      // a runtime or shell bootstrap failure is an execution failure, not a
      // VFS snapshot failure, and must not be re-labelled as `fork: none`.
      const failure = executionFailure(error, options.signal, overall)
      execution = {
        exitCode: failure.exitCode,
        timedOut: failure.timedOut,
        cancelled: failure.cancelled,
        stdout: '',
        stderr: `${failure.detail}\n`,
        stdoutBytes: 0,
        stderrBytes: Buffer.byteLength(`${failure.detail}\n`, 'utf8'),
        stdoutTruncated: false,
        stderrTruncated: false,
        failure: failure.code,
        failureDetail: failure.detail,
      }
    }
    const finishedAt = Date.now()
    const before = fork.entries
    const after = new Map()
    for (const path of fork.backend.list()) {
      try {
        const stat = fork.backend.stat(path)
        if (stat.kind === 'file') after.set(path, fork.backend.readFile(path))
      } catch {
        // A path removed by the command is simply absent from `after`.
      }
    }
    const changes = []
    for (const [path, bytes] of after) {
      const old = before.get(path)
      if (old === undefined) changes.push({ path, change: 'created', bytes: bytes.byteLength })
      else if (!Buffer.from(old).equals(Buffer.from(bytes))) {
        changes.push({ path, change: 'modified', bytes: bytes.byteLength })
      }
    }
    for (const path of before.keys()) {
      if (!after.has(path)) changes.push({ path, change: 'removed', bytes: 0 })
    }
    let verification
    try {
      const verifyPhase = phaseDeadline(overall.signal, overallDeadline,
        'worker-command: the live Workspace verification exceeded its deadline')
      try {
        verification = await verifyLiveWorkspace(fork, options, overallDeadline, verifyPhase.signal)
      } finally {
        verifyPhase.dispose()
      }
    } catch (error) {
      const code = overall.timedOut()
        ? 'worker-command/snapshot-timeout'
        : error instanceof WorkerCommandError ? error.code : 'worker-command/verify-failed'
      verification = {
        unchanged: false,
        method: 'error',
        failure: code,
        failure_detail: messageOf(error),
      }
    }
    const liveWorkspaceUnchanged = verification.unchanged === true
    const receipt = {
    protocol: WORKER_COMMAND_PROTOCOL,
    receipt_id: `wc-${randomUUID()}`,
    location: {
      kind: 'worker',
      carrier: currentWorkerMseq() === undefined ? 'surface-process' : 'ordered-channel',
      worker_vfs: true,
      host_process: false,
      fork: 'memory-vfs',
    },
    binding: {
      scenario_id: request.scenarioId,
      session_id: request.sessionId,
      turn: request.turn,
      assertion_index: request.assertionIndex,
      ...(request.completionWatermark === undefined
        ? {} : { completion_watermark: request.completionWatermark }),
    },
    source: {
      kind: 'worker-vfs-fork',
      fork: true,
      roots: fork.roots,
      missing_roots: fork.missing,
      source_mseq_start: fork.mseqStart,
      source_mseq_end: fork.mseqEnd,
      source_frozen: fork.sourceFrozen,
      digest: fork.digest,
      entries: fork.entries.size,
      bytes: fork.bytes,
    },
    execution: {
      program: request.program,
      cwd: request.cwd,
      budget_ms: request.budgetMs,
      duration_ms: finishedAt - startedAt,
      exit_code: execution.exitCode,
      timed_out: execution.timedOut,
      cancelled: execution.cancelled,
      stdout: execution.stdout,
      stderr: execution.stderr,
      stdout_bytes: execution.stdoutBytes,
      stderr_bytes: execution.stderrBytes,
      stdout_truncated: execution.stdoutTruncated,
      stderr_truncated: execution.stderrTruncated,
      ...(execution.failure === undefined ? {} : {
        failure: execution.failure,
        failure_detail: execution.failureDetail,
      }),
    },
    model_requests: 0,
    live_workspace_unchanged: liveWorkspaceUnchanged,
    verification,
    side_effects: {
      isolated: true,
      live_workspace: false,
      journal: false,
      changes,
      changed: changes.length,
    },
  }
    return receipt
  } finally {
    overall.dispose()
  }
}

/**
 * Register the Worker command acceptance route on the phone connection
 * carrier, exactly like the recovery route.
 * @param {object} ctx - owning surface context with `effect`.
 * @param {object} connection - `HostConnectionService` the surface created.
 * @param {object} options - execution seams (tests inject a reader/executor).
 * @returns {Function} disposer owned by the surface fiber.
 */
export function registerWorkerCommandRoute(ctx, connection, options = {}) {
  const executor = options.executor ?? executeWorkerCommandInFork
  return ctx.effect(() => connection.fetch.register({
    path: WORKER_COMMAND_PATH,
    methods: ['POST'],
    requestBody: 'buffered',
    fetch: async request => {
      const mediaType = request.headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase()
      if (mediaType !== 'application/json') {
        return failure(415, 'worker-command/content-type', 'content type must be application/json')
      }
      let body
      try {
        const text = await request.text()
        if (Buffer.byteLength(text, 'utf8') > WORKER_COMMAND_MAX_BODY_BYTES) {
          return failure(413, 'worker-command/body-too-large', 'the Worker command request body is too large')
        }
        body = JSON.parse(text)
      } catch {
        return failure(400, 'worker-command/bad-json', 'the Worker command request body is not JSON')
      }
      let validated
      try {
        validated = validateWorkerCommandRequest(body)
      } catch (error) {
        if (error instanceof WorkerCommandError) return failure(error.status, error.code, error.message)
        return failure(400, 'worker-command/bad-request', error instanceof Error ? error.message : String(error))
      }
      try {
        const value = await executor(validated, { ...options, signal: request.signal })
        if (value === null || typeof value !== 'object' || value.protocol !== WORKER_COMMAND_PROTOCOL) {
          return failure(500, 'worker-command/missing-receipt',
            'the executor returned no pdsh-worker-command/1 receipt')
        }
        return json({ ok: true, value })
      } catch (error) {
        if (error instanceof WorkerCommandError) return failure(error.status, error.code, error.message)
        return failure(500, 'worker-command/failed', error instanceof Error ? error.message : String(error))
      }
    },
  }), 'phone-surface: Worker command acceptance receipt')
}
