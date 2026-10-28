// SPDX-License-Identifier: MIT
/**
 * Bounded directory opening for the Worker command capture.
 *
 * The pinned DSH runtime implements `node:fs.promises.opendir` as
 * `opendirSync` -> `readdirSync(..., { withFileTypes: true })`. Its
 * `MemoryVfs.readdirSync` walks the VFS maps and allocates the complete child
 * list before the first `Dir.read()`, so an acceptance capture cannot apply its
 * entry budget or enforce its deadline during that call.
 *
 * The bridge therefore does two separate things:
 *
 *  1. the shared virtual `node:fs.promises.opendir` becomes a transparent
 *     wrapper. Ordinary DSH/session/storage reads keep the pinned semantics;
 *     the bridge does not add a global VFS entry limit to the runtime;
 *  2. the wrapper exposes a separate bounded opener function under
 *     {@link WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER}. Only the Worker command
 *     capture calls that function. It verifies the whole-VFS entry upper bound
 *     synchronously and then calls the original opener in the same JavaScript
 *     stack, with no `await` a writer could interleave.
 *
 * The upper bound is not just `MemoryVfs.usage()`: the pinned public `usage()`
 * counts `files` and `directories` but not the `deferred` map populated by
 * `deferArchive()`, and `readdirSync` enumerates that map too. Lazy archive
 * registrations are therefore counted separately:
 *
 *  - the pinned image manifest (`config/vfs-manifest.json`) lists the files
 *    registered by the host's initial `deferArchive()` calls, so their total is
 *    read through the mounted VFS's public synchronous face;
 *  - later public `deferArchive()` calls on the mounted VFS are observed and
 *    their file counts added;
 *  - a missing/malformed manifest, an uncountable archive, or a missing
 *    `deferArchive()` fails closed instead of treating the absent count as 0;
 *  - counts are never reduced after hydration, so an entry that moves from the
 *    deferred map to the file map may be counted twice. That is conservative;
 *    it must never undercount.
 *
 * This is "bounded materialisation", not a streaming enumerator: a directory
 * containing at most the ceiling entries may still be materialised, and the
 * synchronous usage/manifest scans themselves are not preemptible. A caller
 * that owns a deadline must check before invoking the bounded opener (the
 * Worker command capture does) and passes its own check as the last argument
 * of the bounded call, so this wrapper checks again immediately before and
 * after its own scans. An install-level
 * {@link BoundedDirectoryOpenerOptions.check} can add a second boundary; the
 * per-call check is the one the capture's deadline/signal uses.
 *
 * The wrapper is installed on the runtime's virtual `node:fs.promises` object
 * after `installExecFsPolicy`, so it composes with that layer: `/tmp` is still
 * canonicalised to `/dsh/tmp` and `/dsh/home/{sessions,storages,tool-journal}`
 * still rejects with `EACCES` before the original opener. The host's real Node
 * `fs.promises` is never patched.
 * @module @phone-dsh/dsh-worker-entry/bounded-opendir
 */

/**
 * Legacy boolean capability marker the Worker command capture still accepts.
 * The bridge no longer puts this on the shared opener: a boolean cannot say
 * which calls are bounded, and the shared opener is deliberately not capped.
 */
export const WORKER_COMMAND_BOUNDED_OPENDIR = Symbol.for('@phone-dsh/dsh-surface-phone/bounded-opendir')

/**
 * Capability marker carrying the separate bounded opener function.
 *
 * The shared `opendir` wrapper exposes this function so the capture can opt in
 * per call without imposing its budget on every other `node:fs` caller. The
 * key is the contract owned by `@phone-dsh/dsh-surface-phone`;
 * `worker-entry` uses the same `Symbol.for` key so the packages agree without a
 * build-time dependency.
 */
export const WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER = Symbol.for('@phone-dsh/dsh-surface-phone/bounded-directory-opener')

/**
 * Marker describing what this bounded opener actually proves.
 *
 * The legacy marker is a boolean compatibility contract. This second symbol
 * records the real mechanism so a reader does not mistake the wrapper for an
 * incremental enumerator.
 */
export const WORKER_BOUNDED_DIRECTORY_MATERIALIZATION = Symbol.for('@phone-dsh/dsh-worker-entry/bounded-directory-materialization')

/**
 * Conservative whole-VFS entry ceiling for one bounded opener.
 *
 * `files + directories + deferred registrations` is the upper bound on any
 * single directory's listing (`MemoryVfs.readdirSync` scans all three maps).
 * The value equals the Worker command capture's default
 * `WORKER_COMMAND_MAX_SNAPSHOT_ENTRIES`; the integration test pins that
 * equality. The ceiling is not a per-directory allowance: a VFS larger than
 * this fails before its first bounded `opendir`, which is the safe direction
 * for a whole-VFS bound.
 */
export const WORKER_BOUNDED_OPENDIR_MAX_ENTRIES = 20_000

/** Pinned runtime default manifest path; the runtime binding passes the real one. */
export const WORKER_BOUNDED_OPENDIR_MANIFEST_PATH = '/dsh/config/vfs-manifest.json'

/** Public `MemoryVfs.usage()` shape this layer reads. */
export interface WorkerVfsEntryUsage {
  readonly files: number
  readonly directories: number
  readonly bytes?: number
}

/** One lazy file registration as the public image manifest records it. */
export interface WorkerVfsDeferredFile {
  readonly path: string
  readonly size: number
}

/** Public `deferArchive()` input shape this layer observes. */
export interface WorkerVfsDeferredArchive {
  readonly files: readonly WorkerVfsDeferredFile[]
}

/** The mounted VFS state the preflight needs. */
export interface BoundedDirectoryVfs {
  usage(): WorkerVfsEntryUsage
  /** Public lazy-archive registration; observed so later calls cannot be missed. */
  deferArchive?(archive: WorkerVfsDeferredArchive): unknown
  /** Public synchronous manifest read; used only for the initial registration count. */
  readFileSync?(path: string, options?: string | { readonly encoding?: string }): string | Uint8Array
  /** Public existence probe for the manifest. */
  existsSync?(path: string): boolean
}

/** The one `node:fs.promises` member this installer replaces. */
export interface BoundedDirectoryPromiseFace {
  opendir?: (...args: unknown[]) => unknown
}

/** Facts attached to the bounded opener, for diagnostics and tests. */
export interface BoundedDirectoryMaterializationFacts {
  readonly mode: 'bounded-materialization'
  readonly upperBound: 'vfs-usage-and-deferred-registrations'
  readonly maxEntries: number
}

/** Inputs for {@link installBoundedDirectoryOpener}. */
export interface BoundedDirectoryOpenerOptions {
  /** Mounted VFS whose public face supplies the whole-VFS upper bound. */
  readonly vfs: BoundedDirectoryVfs
  /** Virtual `node:fs.promises` object to wrap (the runtime's shared face). */
  readonly fs: BoundedDirectoryPromiseFace
  /** Whole-VFS ceiling; defaults to {@link WORKER_BOUNDED_OPENDIR_MAX_ENTRIES}. */
  readonly maxEntries?: number
  /** Pinned image manifest path; defaults to {@link WORKER_BOUNDED_OPENDIR_MANIFEST_PATH}. */
  readonly manifestPath?: string
  /**
   * Optional install-level deadline/abort check. It runs once before the
   * synchronous usage/manifest scans and once after them, before the original
   * opener. It cannot interrupt a synchronous scan or the original
   * materialisation; no JavaScript callback can. The caller that owns the
   * deadline (the Worker command capture) instead supplies its check per call,
   * which runs at the same two points and is never forwarded to the original
   * opener.
   */
  readonly check?: () => void
}

/** Error raised when a caller-supplied per-call check is not a function. */
function checkError(): TypeError {
  return new TypeError('worker-entry: a per-call bounded opendir check must be a function')
}

/** Error raised when the VFS cannot prove a finite entry bound. */
function usageError(detail: string, cause?: unknown): Error {
  const error = new Error(
    `worker-entry: bounded opendir cannot verify the mounted VFS: ${detail}; refusing before the original opener`,
    cause === undefined ? undefined : { cause },
  ) as Error & { code: string }
  error.name = 'BoundedDirectoryOpenerError'
  error.code = 'ERR_PDSH_BOUNDED_OPENDIR_USAGE'
  return error
}

/** Error raised when the whole VFS is above the configured ceiling. */
function budgetError(maxEntries: number, deferred: number): Error {
  const error = new Error(
    `worker-entry: bounded opendir refused: the mounted VFS exceeds the ${String(maxEntries)}-entry `
      + `whole-VFS ceiling (including ${String(deferred)} observed lazy registrations); `
      + 'refusing before the original opener materialises a directory listing',
  ) as Error & { code: string }
  error.name = 'BoundedDirectoryOpenerError'
  error.code = 'ERR_PDSH_BOUNDED_OPENDIR_BUDGET'
  return error
}

/** Decode a manifest read the same way whether text or bytes came back. */
function decode(value: string | Uint8Array): string {
  return typeof value === 'string' ? value : new TextDecoder().decode(value)
}

/**
 * Count the lazy files the pinned image manifest says were registered before
 * this bridge was installed. The manifest is the public record the runtime host
 * itself consumes; its initial `deferArchive()` calls register exactly those
 * files. A missing or malformed record is not silently zero.
 * @param vfs - mounted VFS.
 * @param manifestPath - image manifest path.
 * @returns the conservative initial deferred-file count.
 * @throws {Error} `ERR_PDSH_BOUNDED_OPENDIR_USAGE` when the count cannot be proven.
 */
function readInitialDeferredCount(vfs: BoundedDirectoryVfs, manifestPath: string): number {
  if (typeof vfs.existsSync !== 'function' || typeof vfs.readFileSync !== 'function') {
    throw usageError('the mounted VFS exposes no public synchronous image manifest reader for lazy registrations')
  }
  let exists: boolean
  try {
    exists = vfs.existsSync(manifestPath)
  } catch (cause) {
    throw usageError(`the mounted VFS could not probe the image manifest ${manifestPath}`, cause)
  }
  if (!exists) {
    throw usageError(`the image manifest ${manifestPath} is missing, so initial lazy registrations cannot be counted`)
  }
  let text: string
  try {
    text = decode(vfs.readFileSync(manifestPath, 'utf8'))
  } catch (cause) {
    throw usageError(`the mounted VFS could not read the image manifest ${manifestPath}`, cause)
  }
  let manifest: unknown
  try {
    manifest = JSON.parse(text)
  } catch (cause) {
    throw usageError(`the image manifest ${manifestPath} is not valid JSON`, cause)
  }
  if (manifest === null || typeof manifest !== 'object' || Array.isArray(manifest)) {
    throw usageError(`the image manifest ${manifestPath} does not hold an object`)
  }
  const lazy = (manifest as { readonly lazy?: unknown }).lazy
  if (!Array.isArray(lazy)) {
    throw usageError(`the image manifest ${manifestPath} has no lazy archive list`)
  }
  let total = 0
  for (const [index, archive] of lazy.entries()) {
    if (archive === null || typeof archive !== 'object' || Array.isArray(archive)) {
      throw usageError(`the image manifest ${manifestPath} lists a non-object lazy archive at index ${String(index)}`)
    }
    const files = (archive as { readonly files?: unknown }).files
    if (!Array.isArray(files)) {
      throw usageError(`the image manifest ${manifestPath} lists no files for lazy archive ${String(index)}`)
    }
    if (total > Number.MAX_SAFE_INTEGER - files.length) {
      throw usageError(`the image manifest ${manifestPath} has an unrepresentable lazy file count`)
    }
    total += files.length
  }
  return total
}

/**
 * Read and validate the public usage counts. Every count must be a finite,
 * non-negative safe integer.
 * @param vfs - mounted VFS.
 * @returns the validated counts.
 * @throws {Error} `ERR_PDSH_BOUNDED_OPENDIR_USAGE` for missing/non-finite data.
 */
function readUsage(vfs: BoundedDirectoryVfs): { readonly files: number, readonly directories: number } {
  if (vfs === null || typeof vfs !== 'object' || typeof vfs.usage !== 'function') {
    throw usageError('the mounted VFS exposes no public usage() entry count')
  }
  let usage: WorkerVfsEntryUsage
  try {
    usage = vfs.usage()
  } catch (cause) {
    throw usageError('the mounted VFS usage() call failed', cause)
  }
  if (usage === null || typeof usage !== 'object') {
    throw usageError('usage() did not return an object')
  }
  const files = usage.files
  const directories = usage.directories
  if (typeof files !== 'number' || !Number.isSafeInteger(files) || files < 0) {
    throw usageError(`usage().files is not a non-negative safe integer (${String(files)})`)
  }
  if (typeof directories !== 'number' || !Number.isSafeInteger(directories) || directories < 0) {
    throw usageError(`usage().directories is not a non-negative safe integer (${String(directories)})`)
  }
  return { files, directories }
}

/**
 * Compare the conservative whole-VFS entry upper bound with the ceiling.
 * @param usage - validated public file/directory counts.
 * @param deferred - observed lazy registrations (never reduced after hydration).
 * @param maxEntries - whole-VFS ceiling.
 * @throws {Error} `ERR_PDSH_BOUNDED_OPENDIR_USAGE` for an invalid deferred count,
 *   `ERR_PDSH_BOUNDED_OPENDIR_BUDGET` when the entry sum exceeds the ceiling.
 */
function checkBudget(
  usage: { readonly files: number, readonly directories: number },
  deferred: number,
  maxEntries: number,
): void {
  if (!Number.isSafeInteger(deferred) || deferred < 0) {
    throw usageError(`the observed lazy registration count is not a non-negative safe integer (${String(deferred)})`)
  }
  // Compare without forming possibly overflowing sums. Each subtraction is
  // guarded so it cannot go negative in a way that hides an over-budget VFS.
  if (deferred > maxEntries) throw budgetError(maxEntries, deferred)
  const afterDeferred = maxEntries - deferred
  if (usage.files > afterDeferred || usage.directories > afterDeferred - usage.files) {
    throw budgetError(maxEntries, deferred)
  }
}

/**
 * Replace the shared virtual `node:fs.promises.opendir` with a transparent
 * wrapper exposing a separate bounded opener function.
 *
 * Ordinary calls delegate unchanged. The bounded function carries
 * {@link WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER}, the legacy boolean marker is
 * deliberately absent, and {@link WORKER_BOUNDED_DIRECTORY_MATERIALIZATION}
 * records the bounded-materialisation contract. The bounded call may pass a
 * deadline/abort check as its last argument; that argument is consumed by the
 * bridge and never forwarded to the original opener. The disposer restores the
 * exact previous functions only when its wrappers are still installed, so a
 * later boot can install its own bridge without an earlier disposer clobbering
 * it.
 * @param options - mounted VFS, promise face, ceiling, manifest and optional check.
 * @returns a disposer restoring the previous opener and deferArchive.
 * @throws {TypeError} When the face has no opener or the ceiling is invalid.
 */
export function installBoundedDirectoryOpener(options: BoundedDirectoryOpenerOptions): () => void {
  const { vfs, fs, check } = options
  const maxEntries = options.maxEntries ?? WORKER_BOUNDED_OPENDIR_MAX_ENTRIES
  const manifestPath = options.manifestPath ?? WORKER_BOUNDED_OPENDIR_MANIFEST_PATH
  if (!Number.isSafeInteger(maxEntries) || maxEntries <= 0) {
    throw new TypeError('worker-entry: a bounded opendir ceiling must be a positive safe integer')
  }
  if (fs === null || typeof fs !== 'object' || typeof fs.opendir !== 'function') {
    throw new TypeError('worker-entry: the virtual node:fs.promises face has no opendir to bound')
  }
  const original = fs.opendir
  const facts: BoundedDirectoryMaterializationFacts = Object.freeze({
    mode: 'bounded-materialization',
    upperBound: 'vfs-usage-and-deferred-registrations',
    maxEntries,
  })

  let initialDeferred: number | undefined
  let initialError: Error | undefined
  let deferredSinceInstall = 0
  let deferredTrackingError: Error | undefined
  let disposed = false

  // Freeze the packer's initial registration count while installing at boot,
  // before any model/tool can edit this public file. Reading it for the first
  // time during capture would let a later edit hide already-deferred entries.
  // Keep a failure for the bounded capture to reject; ordinary opendir remains
  // unchanged even when this capability cannot establish a trustworthy bound.
  try {
    initialDeferred = readInitialDeferredCount(vfs, manifestPath)
  } catch (error) {
    initialError = error instanceof Error ? error : usageError('the initial lazy registration count failed', error)
  }

  /** Initial manifest count plus every later public registration; never reduced. */
  const deferredRegistrations = (): number => {
    if (initialError !== undefined) throw initialError
    if (deferredTrackingError !== undefined) throw deferredTrackingError
    const total = (initialDeferred ?? 0) + deferredSinceInstall
    if (!Number.isSafeInteger(total)) throw usageError('the observed lazy registration count overflowed')
    return total
  }

  let originalDeferArchive: BoundedDirectoryVfs['deferArchive']
  let wrappedDeferArchive: BoundedDirectoryVfs['deferArchive']
  if (typeof vfs.deferArchive !== 'function') {
    deferredTrackingError = usageError('the mounted VFS exposes no public deferArchive() to observe lazy registrations')
  } else {
    originalDeferArchive = vfs.deferArchive
    const delegate = function deferredArchive(this: unknown, archive: WorkerVfsDeferredArchive): unknown {
      if (disposed) return originalDeferArchive?.call(this, archive)
      const files = archive !== null && typeof archive === 'object' ? archive.files : undefined
      if (!Array.isArray(files)) {
        deferredTrackingError ??= usageError('deferArchive() received an archive whose file registrations cannot be counted')
        return originalDeferArchive?.call(this, archive)
      }
      if (!Number.isSafeInteger(files.length) || files.length < 0) {
        deferredTrackingError ??= usageError('deferArchive() received an unrepresentable file registration count')
        return originalDeferArchive?.call(this, archive)
      }
      // Count before calling the original: if an implementation registered
      // some files and then threw, the conservative count still includes them.
      const next = deferredSinceInstall + files.length
      if (!Number.isSafeInteger(next)) {
        deferredTrackingError ??= usageError('the observed lazy registration count overflowed')
      } else {
        deferredSinceInstall = next
      }
      return originalDeferArchive?.call(this, archive)
    }
    try {
      vfs.deferArchive = delegate
      wrappedDeferArchive = delegate
    } catch (cause) {
      deferredTrackingError = usageError('the mounted VFS deferArchive() could not be observed', cause)
    }
  }

  const bounded = function boundedDirectoryOpener(this: unknown, ...callArgs: unknown[]): unknown {
    // Capture may retain this capability across a microtask while teardown
    // removes it from the facade. A retained reference must never turn into
    // the unbounded original opener after its owner has been disposed.
    if (disposed) return Promise.reject(usageError('the bounded directory opener has been disposed'))
    // The capture passes its deadline/abort check as the last argument (either
    // `(path, check)` or `(path, options, check)`). Remove it before delegating
    // so the original `opendir` only ever sees Node-shaped arguments. Holding
    // it in this call's closure is what makes the post-scan check happen before
    // the original materialisation, with no asynchronous gap in between.
    const args = callArgs.slice()
    let perCallCheck: (() => void) | undefined
    if (typeof args[1] === 'function') {
      perCallCheck = args.splice(1, 1)[0] as () => void
    } else if (typeof args[2] === 'function') {
      perCallCheck = args.splice(2, 1)[0] as () => void
    } else if (args.length > 2 && args[2] !== undefined) {
      return Promise.reject(checkError())
    }
    const checks = perCallCheck === undefined ? [] : [perCallCheck]
    if (check !== undefined) checks.push(check)
    const runChecks = (): void => {
      for (const current of checks) current()
    }
    if (!disposed) {
      try {
        runChecks()
        const usage = readUsage(vfs)
        checkBudget(usage, deferredRegistrations(), maxEntries)
        runChecks()
      } catch (error) {
        // This is a `node:fs.promises`-shaped call: a refused preflight is a
        // rejected call, not a synchronous throw. The original opener has still
        // not run.
        return Promise.reject(error)
      }
    }
    try {
      return original.apply(this, args)
    } catch (error) {
      return Promise.reject(error)
    }
  }
  Object.defineProperty(bounded, WORKER_BOUNDED_DIRECTORY_MATERIALIZATION, {
    value: facts, configurable: true,
  })

  const facade = function boundedDirectoryFacade(this: unknown, ...args: unknown[]): unknown {
    return original.apply(this, args)
  }
  Object.defineProperty(facade, WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER, {
    value: bounded, configurable: true,
  })
  fs.opendir = facade as BoundedDirectoryPromiseFace['opendir']

  return () => {
    if (disposed) return
    disposed = true
    if (fs.opendir === facade) {
      fs.opendir = original
    }
    // Whether this facade is current or only a lower delegate, remove its
    // capabilities now: a retained reference to a disposed wrapper must never
    // look like a bounded opener still bound to this dead VFS.
    Reflect.deleteProperty(facade, WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER)
    Reflect.deleteProperty(facade, WORKER_COMMAND_BOUNDED_OPENDIR)
    Reflect.deleteProperty(bounded, WORKER_BOUNDED_DIRECTORY_MATERIALIZATION)
    if (wrappedDeferArchive !== undefined && vfs.deferArchive === wrappedDeferArchive) {
      vfs.deferArchive = originalDeferArchive
    }
  }
}
