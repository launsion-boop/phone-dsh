// SPDX-License-Identifier: MIT
/**
 * Snapshot of the preopened trees for hosts without a synchronous VFS channel.
 *
 * A WASI guest calls `fd_read`/`path_open` synchronously, so a tool worker needs
 * a synchronous view of the DSH Worker's live VFS. The intended channel is a
 * SharedArrayBuffer (`ProxyWasiVfs`), which exists only in a cross-origin
 * isolated Worker. A Worker rebuilt by a recovery path can come back without it
 * (see G2-FIX-54: after `park_resume` the rebuilt Worker's `python3` lost the
 * file view while `bash` kept it), and the Android WebView host never has it at
 * all: `:engine` disables cross-origin isolation because Chromium will not
 * isolate a WebView (COOP/COEP there is half-executed and breaks intercepted
 * worker scripts), so `crossOriginIsolated` is false and
 * `supportsSynchronousVfs()` answers false for every boot. On Android this
 * module is therefore the *only* file path a WASI guest has, not a rare
 * recovery mode — every `python3` toolbox instance and every `jq` dispatch
 * captures one.
 *
 * Publishing a `python3` that silently resolves every path against an empty `/`
 * is worse than not publishing it, so the toolbox captures the preopened trees
 * over the *asynchronous* control channel and mounts them in the tool worker as
 * a snapshot:
 *
 *  - reads (`stat`, `readdir`, `open`, `read`) are served synchronously from
 *    the snapshot, so cwd, absolute `/dsh/...` paths and relative paths all
 *    resolve exactly as they do in the shell;
 *  - mutations are applied to the snapshot immediately (a later read in the
 *    same program sees its own write) and forwarded to the live VFS over the
 *    asynchronous channel; the tool worker drains them before it reports the
 *    command's exit, so a following `bash` step sees the same bytes.
 *
 * The capture is bounded so a large workspace cannot inflate the tool worker
 * past the WASI hot-instance budget; a truncated capture is reported to the
 * caller, which fails loud instead of serving a partial view. A tree the
 * execution surface is not allowed to read (`EACCES` from the exec read policy,
 * `channel.md` §VFS) is not truncation — and it is not absence either: the
 * capture drops the subtree from `entries` (a listing must not name it) but
 * records the policy's own answer in `denied`. A guest that resolves a path
 * *explicitly* to a denied prefix is then answered `EACCES` with the same
 * remediation sentence the shell renders, instead of the guest inventing
 * `ENOENT` from a snapshot that simply has no such entry.
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-snapshot
 */
import { VfsProxyError, errorCodeOf } from './errors.ts'
import { MAX_FILE_SIZE, MEBIBYTE } from './limits.ts'
import { MemoryWasiVfs } from './memory-wasi-vfs.ts'
import { isWithinRoot, normalizeAbsolutePath } from './vfs-paths.ts'
import type { VfsBackend, VfsDirEntry, VfsOpenOptions, VfsRequest, VfsStat, VfsValue, WasiVfs } from './types.ts'
import { EXEC_INTERNAL_ROOTS } from './vfs-namespace.ts'

/** Default ceiling for one snapshot's file bytes (48 MiB, the workspace budget). */
export const DEFAULT_SNAPSHOT_BYTES = 48 * MEBIBYTE
/** Default ceiling for one snapshot's entries. */
export const DEFAULT_SNAPSHOT_ENTRIES = 8192

/** One captured entry. `path` is the DSH Worker VFS path (the guest path). */
export interface VfsSnapshotEntry {
  readonly path: string
  readonly kind: 'file' | 'directory'
  readonly mode: number
  readonly mtimeMs: number
  readonly ino: number
  /** File bytes; absent for directories. */
  readonly bytes?: Uint8Array
}

/**
 * One path the live VFS refused to let an execution surface read.
 *
 * A denial is not an absence. `channel.md` §VFS makes
 * `/dsh/home/{sessions,storages,tool-journal}/**` DSH-internal: an execution
 * surface gets `EACCES` plus one remediation sentence, whichever program asked.
 * The snapshot is a WASI guest's only file view on Android, so it has to carry
 * that answer across the thread boundary: without it the guest's runtime
 * resolves the path locally, finds no entry, and prints `No such file or
 * directory` — a claim that the path does not exist, which is false.
 */
export interface VfsSnapshotDenial {
  /** Absolute host VFS path of the denied subtree root. */
  readonly path: string
  /** The errno-style code the live VFS answered. */
  readonly code: 'EACCES'
  /**
   * The live VFS's message *without* its `EACCES: ` prefix.
   *
   * For a policy denial this is `VfsNamespace.execReadDeniedMessage`'s
   * sentence, so the WASI host's stderr diagnostic renders the same
   * `EACCES: <sentence>` line `cat`/`stat` print. It is stored verbatim
   * rather than rebuilt from a table: the sentence names the path and its
   * remediation, and a second wording is what the contract forbids.
   */
  readonly message: string
}

/** One captured view of the preopened trees. */
export interface VfsSnapshot {
  /** Preopen roots the snapshot was taken from (host paths). */
  readonly roots: readonly string[]
  /** Roots the live VFS did not have when the snapshot was captured. */
  readonly missing: readonly string[]
  /**
   * Paths the live VFS refused to read (`EACCES`).
   *
   * They are absent from {@link entries} — a denied subtree is not part of the
   * guest's *view* — but an explicit access to one answers the recorded
   * `EACCES` instead of falling through to the guest's own `ENOENT`. Required,
   * not optional: a snapshot that omitted the field would silently restore the
   * false "not found" this record exists to prevent.
   */
  readonly denied: readonly VfsSnapshotDenial[]
  readonly entries: readonly VfsSnapshotEntry[]
  /** Total file bytes captured. */
  readonly bytes: number
  /** True when a limit stopped the walk; the view is incomplete. */
  readonly truncated: boolean
  /**
   * Entries skipped by a limit or by the read policy (for the loud failure
   * message). A policy skip is also named in {@link denied}; the count alone
   * must never be rendered as "missing".
   */
  readonly omitted: number
}

/** Capture limits. */
export interface VfsSnapshotOptions {
  readonly maxBytes?: number
  readonly maxEntries?: number
  /** Per-file read cap; defaults to the configured single-file budget (64 MiB). */
  readonly maxFileBytes?: number
}

/**
 * The errno code a capture failure stands for, if it is one of the two answers
 * a walk may absorb.
 *
 * Two different things reach this walk and they must not be treated alike:
 *
 *  - **Truncation** (the byte or entry ceiling) means the guest would see a
 *    *partial* view of a tree it is entitled to. That is reported to the
 *    caller, which fails loud — a silently short listing is worse than no
 *    command at all. It is not an error code, so it never appears here.
 *  - **`ENOENT`** means the path is genuinely not part of the guest's view;
 *    the walk omits it and the guest's own `ENOENT` is the truth.
 *  - **`EACCES`** means the path *exists* and the execution surface may not
 *    read it. `channel.md` §VFS gives exactly one answer for that (the policy
 *    sentence), so the walk must not let the guest invent a different one: it
 *    records a {@link VfsSnapshotDenial} and drops the subtree from the view.
 *
 * Anything else (a torn read, an I/O failure) is a broken capture, not a
 * smaller one, and is rethrown.
 * @param error - the error one walk step raised.
 * @returns `'absent'`/`'denied'` for the two absorbable answers, else undefined.
 */
function omissionOf(error: unknown): 'absent' | 'denied' | undefined {
  const code = errorCodeOf(error)
  if (code === 'ENOENT') return 'absent'
  if (code === 'EACCES') return 'denied'
  return undefined
}

/**
 * The message a denial carries, without the errno prefix the backend added.
 *
 * `VfsProxyError` spells itself `${code}: ${detail}`, and the proxy client may
 * have re-prefixed an already-prefixed server message, so the prefix is
 * stripped repeatedly. The result is re-wrapped in a `VfsProxyError` on the
 * guest side, which restores exactly one prefix — the line the guest's stderr
 * shows is the line the shell would have shown.
 * @param error - the error the backend raised for the denied path.
 * @param path - the denied path, used only when the backend gave no sentence.
 * @returns the denial text.
 */
function denialMessageOf(error: unknown, path: string): string {
  const raw = error instanceof Error ? error.message : String(error)
  const prefix = 'EACCES: '
  let message = raw
  while (message.startsWith(prefix)) message = message.slice(prefix.length)
  message = message.trim()
  return message === '' ? `permission denied, ${path}` : message
}

function isSnapshotDenial(value: unknown): value is VfsSnapshotDenial {
  if (typeof value !== 'object' || value === null) return false
  const denial = value as Record<string, unknown>
  return typeof denial.path === 'string' && denial.path.startsWith('/')
    && denial.code === 'EACCES'
    && typeof denial.message === 'string' && denial.message !== ''
}

function isSnapshotEntry(value: unknown): value is VfsSnapshotEntry {
  if (typeof value !== 'object' || value === null) return false
  const entry = value as Record<string, unknown>
  if (typeof entry.path !== 'string' || entry.path === '') return false
  if (entry.kind !== 'file' && entry.kind !== 'directory') return false
  if (typeof entry.mode !== 'number' || typeof entry.mtimeMs !== 'number'
      || typeof entry.ino !== 'number') {
    return false
  }
  // A structured clone preserves a typed array; a plain object from an older
  // or foreign sender must not be seeded as file bytes.
  if (entry.kind === 'directory') return entry.bytes === undefined
  return entry.bytes instanceof Uint8Array
}

/**
 * Validate a `snapshot` message body received from another thread.
 *
 * The Worker control channel carries the whole preopened tree as one
 * structured-clone message. It is big and crosses a thread boundary, so the
 * receiver cannot rely on the sender's TypeScript type: a malformed body must
 * be rejected loud instead of being cast and half-seeded.
 * @param value - Untrusted message payload.
 * @returns Whether `value` has the exact {@link VfsSnapshot} shape.
 */
export function isVfsSnapshot(value: unknown): value is VfsSnapshot {
  if (typeof value !== 'object' || value === null) return false
  const snapshot = value as Record<string, unknown>
  if (!Array.isArray(snapshot.roots)
      || !snapshot.roots.every(root => typeof root === 'string')) {
    return false
  }
  if (!Array.isArray(snapshot.missing)
      || !snapshot.missing.every(root => typeof root === 'string')) {
    return false
  }
  // A missing denial list is a snapshot that cannot tell a refusal from an
  // absence, so it is malformed for this receiver — not "a snapshot with no
  // denials". The check is positive for the same reason the other fields are.
  if (!Array.isArray(snapshot.denied) || !snapshot.denied.every(isSnapshotDenial)) return false
  if (!Array.isArray(snapshot.entries)) return false
  if (!snapshot.entries.every(isSnapshotEntry)) return false
  return typeof snapshot.bytes === 'number'
    && typeof snapshot.truncated === 'boolean'
    && typeof snapshot.omitted === 'number'
}

/**
 * Walk the preopened trees over the asynchronous backend and return one
 * snapshot. The walk is deterministic (directory entries are visited in
 * name order) so two boots over the same tree capture the same bytes.
 * @param backend - The host-side VFS backend the proxy serves.
 * @param roots - Host paths to capture (the preopen table's `hostPath`s).
 * @param options - Byte/entry limits.
 * @returns The captured snapshot; `truncated` when a limit was hit.
 */
export async function captureVfsSnapshot(
  backend: VfsBackend,
  roots: readonly string[],
  options: VfsSnapshotOptions = {},
): Promise<VfsSnapshot> {
  const maxBytes = options.maxBytes ?? DEFAULT_SNAPSHOT_BYTES
  const maxEntries = options.maxEntries ?? DEFAULT_SNAPSHOT_ENTRIES
  const maxFileBytes = options.maxFileBytes ?? MAX_FILE_SIZE
  const entries: VfsSnapshotEntry[] = []
  const missing: string[] = []
  const denied: VfsSnapshotDenial[] = []
  let bytes = 0
  let omitted = 0
  let truncated = false

  /**
   * Absorb one policy refusal: drop the path from the view and remember the
   * answer, so an explicit access can still be told "refused", never "absent".
   */
  const recordDenial = (path: string, error: unknown): void => {
    denied.push({ path, code: 'EACCES', message: denialMessageOf(error, path) })
  }

  const visited = new Set<string>()
  const walk = async (root: string, path: string): Promise<void> => {
    if (truncated) return
    if (visited.has(path)) return
    visited.add(path)
    if (!isWithinRoot(root, path)) {
      omitted += 1
      return
    }
    let stat: VfsStat
    try {
      stat = await backend.stat(path)
    } catch (error) {
      const omission = omissionOf(error)
      if (omission === 'denied') {
        // The live VFS says the path exists and this surface may not read it.
        // Record that answer instead of folding it into absence: the guest's
        // own resolver would otherwise report ENOENT for a present path.
        recordDenial(path, error)
        omitted += 1
        return
      }
      if (omission === undefined) throw error
      // A root the VFS genuinely lacks is reported to the caller; a child that
      // vanished between the parent's listing and its own stat is just gone.
      if (path === root) missing.push(path)
      omitted += 1
      return
    }
    if (stat.kind === 'symlink') {
      // The snapshot backend has no link resolution; leaving symlinks out is
      // the same answer the guest gets from a preopen that does not follow it.
      omitted += 1
      return
    }
    if (entries.length >= maxEntries) {
      truncated = true
      return
    }
    if (stat.kind === 'directory') {
      entries.push({
        path,
        kind: 'directory',
        mode: stat.mode,
        mtimeMs: stat.mtimeMs,
        ino: stat.ino,
      })
      let children: readonly { readonly name: string }[]
      try {
        children = await backend.readdir(path)
      } catch (error) {
        const omission = omissionOf(error)
        if (omission === 'denied') {
          // `stat` succeeded, so the directory is real — but its listing is
          // refused. The name must not appear in the parent (that is the
          // "invisible" half of the contract), so the entry pushed above is
          // withdrawn; the denial record keeps an explicit access answering
          // EACCES instead of the guest's ENOENT.
          recordDenial(path, error)
          if (entries[entries.length - 1]?.path === path) entries.pop()
          omitted += 1
          return
        }
        if (omission === undefined) throw error
        // The directory disappeared after its stat: it stays as an empty entry
        // (the name was real when the parent listed it), as it always has.
        omitted += 1
        return
      }
      const names = children.map(entry => entry.name).sort()
      for (const name of names) {
        if (name === '' || name === '.' || name === '..' || name.includes('/')) {
          omitted += 1
          continue
        }
        await walk(root, normalizeAbsolutePath(path === '/' ? `/${name}` : `${path}/${name}`))
        if (truncated) return
      }
      return
    }
    if (stat.size > maxFileBytes) {
      truncated = true
      return
    }
    if (bytes + stat.size > maxBytes) {
      truncated = true
      return
    }
    let content: Uint8Array
    try {
      content = await backend.readFile(path)
    } catch (error) {
      // A file the policy refuses to read is the same shape as a denied
      // directory: present, unreadable, and never absent.
      if (omissionOf(error) !== 'denied') throw error
      recordDenial(path, error)
      omitted += 1
      return
    }
    if (content.byteLength > maxFileBytes || bytes + content.byteLength > maxBytes) {
      truncated = true
      return
    }
    bytes += content.byteLength
    entries.push({
      path,
      kind: 'file',
      mode: stat.mode,
      mtimeMs: stat.mtimeMs,
      ino: stat.ino,
      bytes: content.slice(),
    })
  }

  for (const root of roots) {
    await walk(normalizeAbsolutePath(root), normalizeAbsolutePath(root))
  }

  // Probe the internal roots directly.
  //
  // The listing filter hides these names from `readdir`, which means the walk
  // above cannot *discover* them — and an undiscovered denial would leave the
  // guest answering ENOENT for a path that exists. Visibility and refusal are
  // separate properties: the name stays out of listings, but an explicit access
  // must still be told "refused". Stat each one so the denial is on record even
  // though the name is never listed.
  for (const internal of EXEC_INTERNAL_ROOTS) {
    if (truncated) break
    if (denied.some(entry => entry.path === internal)) continue
    const owner = roots.find(root => isWithinRoot(normalizeAbsolutePath(root), internal))
    if (owner === undefined) continue
    try {
      await backend.stat(internal)
    } catch (error) {
      if (omissionOf(error) === 'denied') recordDenial(internal, error)
    }
  }

  return { roots, missing, denied, entries, bytes, truncated, omitted }
}

/** Write-behind face the snapshot forwards mutations to (the async client). */
export interface SnapshotWriteThrough {
  call(request: VfsRequest): Promise<VfsValue>
}

/**
 * Normalise a captured denial list into the prefixes the view answers with.
 *
 * The list crosses a thread boundary and may also be handed in by a test, so
 * every path is canonicalised here rather than trusted: a denial recorded as
 * `/dsh/home/sessions/` must still match `/dsh/home/sessions/x`.
 * @param snapshot - the capture to index.
 * @returns one entry per denied path, longest first (a nested denial wins).
 */
function denialIndex(snapshot: VfsSnapshot): readonly VfsSnapshotDenial[] {
  const seen = new Set<string>()
  const denials: VfsSnapshotDenial[] = []
  for (const denial of snapshot.denied) {
    let path: string
    try {
      path = normalizeAbsolutePath(denial.path)
    } catch {
      continue
    }
    if (seen.has(path)) continue
    seen.add(path)
    denials.push({ path, code: denial.code, message: denial.message })
  }
  return denials.sort((left, right) => right.path.length - left.path.length)
}

/**
 * `WasiVfs` over a captured snapshot with write-behind.
 *
 * Reads are synchronous and local (the whole point: they work with no
 * SharedArrayBuffer). Mutations update the local view first, then queue an
 * asynchronous request; {@link flushWrites} awaits the queue so the tool worker
 * can report the command's exit only after the live VFS (and therefore the WAL
 * sink) has the bytes.
 *
 * A path the capture recorded as denied is answered from {@link VfsSnapshot.denied}
 * before the local tree is consulted: the tree has no such entry, and a tree
 * miss would become the guest's own `ENOENT`.
 */
export class SnapshotWasiVfs extends MemoryWasiVfs {
  private readonly writer: SnapshotWriteThrough | undefined
  private readonly pending = new Set<Promise<VfsValue>>()
  private failure: Error | undefined
  /** Set while `write()` drives the inherited whole-file path. */
  private incrementalWrite = false
  private snapshot: VfsSnapshot
  /** Denied prefixes of the current capture, sorted for the guard's scan. */
  private denials: readonly VfsSnapshotDenial[] = []

  /**
   * @param snapshot - Captured entries to seed.
   * @param writer - Async request face; absent for a read-only view.
   */
  constructor(snapshot: VfsSnapshot, writer?: SnapshotWriteThrough) {
    super()
    this.snapshot = snapshot
    this.writer = writer
    this.denials = denialIndex(snapshot)
    this.seed(snapshot)
  }

  /**
   * Replace the local view with a fresh capture of the live preopened trees.
   *
   * The host captures again before each dispatch in fallback mode, so a file a
   * `bash` step wrote (or removed) since the previous python run is visible to
   * the next one. Files this view wrote are already in the live VFS because
   * `flushWrites()` ran before the previous exit.
   * @param snapshot - The new capture; its roots replace the whole local tree.
   */
  update(snapshot: VfsSnapshot): void {
    this.snapshot = snapshot
    this.denials = denialIndex(snapshot)
    this.resetTree()
    this.failure = undefined
    this.seed(snapshot)
  }

  /**
   * Answer a path inside a denied prefix with the captured `EACCES`.
   *
   * The guest resolves a path locally against this tree, so a path the capture
   * refused has no entry — and a tree miss is `ENOENT`. That would turn "you
   * may not read this" into "this does not exist", which is the one thing the
   * execution policy must never say. Every read and every mutation therefore
   * asks this guard first: the answer is the policy's own sentence for the
   * denied root, with exactly the errno prefix the shell would have printed.
   * @param path - host VFS path the guest resolved.
   * @throws {VfsProxyError} `EACCES` with the captured remediation sentence.
   */
  private denyIfRefused(path: string): void {
    if (this.denials.length === 0) return
    const target = normalizeAbsolutePath(path)
    for (const denial of this.denials) {
      if (!isWithinRoot(denial.path, target)) continue
      // No `(path)` suffix: the captured sentence already names the path, and
      // a second one would make the guest's line differ from the shell's.
      throw new VfsProxyError(denial.code, denial.message)
    }
  }

  override stat(path: string): VfsStat {
    this.denyIfRefused(path)
    return super.stat(path)
  }

  /**
   * List one directory, never naming a denied entry.
   *
   * The capture already leaves a denied subtree out of its entries, so this
   * filter is normally a no-op; it is the view's own invariant, not a second
   * copy of the capture's. A snapshot produced by an older capture (or handed
   * in by a test) may still carry an entry a denial covers, and a listing is
   * the one place that name would become visible again.
   */
  override readdir(path: string): readonly VfsDirEntry[] {
    this.denyIfRefused(path)
    const entries = super.readdir(path)
    if (this.denials.length === 0) return entries
    const directory = normalizeAbsolutePath(path)
    return entries.filter(entry => {
      const child = normalizeAbsolutePath(directory === '/' ? `/${entry.name}` : `${directory}/${entry.name}`)
      return !this.denials.some(denial => isWithinRoot(denial.path, child))
    })
  }

  override readFile(path: string): Uint8Array {
    this.denyIfRefused(path)
    return super.readFile(path)
  }

  override read(path: string, offset: number, length: number): Uint8Array {
    this.denyIfRefused(path)
    return super.read(path, offset, length)
  }

  private seed(snapshot: VfsSnapshot): void {
    // Parents first so seeding a file never has to invent a directory that
    // the snapshot itself reported with its own mode/mtime.
    const ordered = [...snapshot.entries].sort((left, right) => left.path.length - right.path.length)
    for (const entry of ordered) {
      try {
        if (entry.kind === 'directory') {
          this.seedDirectory(entry.path)
        } else if (entry.bytes !== undefined) {
          this.seedFile(entry.path, entry.bytes, entry.mode)
        }
      } catch {
        // A parent that the live VFS reported as a file cannot hold the child;
        // the snapshot is truncated for that subtree and the guest sees the
        // same ENOENT a missing directory produces.
        this.failure ??= new VfsProxyError('EIO', `snapshot entry ${entry.path} could not be seeded`)
      }
    }
  }

  /** The captured view this instance serves (diagnostics/tests). */
  get captured(): VfsSnapshot {
    return this.snapshot
  }

  override open(path: string, options: VfsOpenOptions): VfsStat {
    this.denyIfRefused(path)
    return super.open(path, options)
  }

  override writeFile(
    path: string,
    data: Uint8Array,
    options: { create?: boolean; append?: boolean; truncate?: boolean; mode?: number } = {},
  ): void {
    this.denyIfRefused(path)
    super.writeFile(path, data, options)
    if (this.incrementalWrite) return
    this.forward({
      op: 'write',
      path: normalizeAbsolutePath(path),
      offset: 0,
      append: options.append === true,
      create: options.create !== false,
      ...(options.mode === undefined ? {} : { mode: options.mode }),
      data: this.readFile(path).slice(),
    })
  }

  override write(
    path: string,
    offset: number,
    data: Uint8Array,
    options: { append: boolean; create: boolean; mode?: number },
  ): number {
    this.denyIfRefused(path)
    this.incrementalWrite = true
    let written: number
    try {
      written = super.write(path, offset, data, options)
    } finally {
      this.incrementalWrite = false
    }
    this.forward({
      op: 'write',
      path: normalizeAbsolutePath(path),
      offset: Math.max(0, offset),
      append: options.append,
      create: options.create,
      ...(options.mode === undefined ? {} : { mode: options.mode }),
      data: data.slice(),
    })
    return written
  }

  override truncate(path: string, length: number): void {
    this.denyIfRefused(path)
    super.truncate(path, length)
    this.forward({ op: 'truncate', path: normalizeAbsolutePath(path), length })
  }

  override mkdir(path: string, mode?: number): void {
    this.denyIfRefused(path)
    super.mkdir(path, mode)
    this.forward({ op: 'mkdir', path: normalizeAbsolutePath(path), ...(mode === undefined ? {} : { mode }) })
  }

  override unlink(path: string, options: { directory?: boolean; recursive?: boolean } = {}): void {
    this.denyIfRefused(path)
    super.unlink(path, options)
    this.forward({ op: 'unlink', path: normalizeAbsolutePath(path), directory: options.directory === true })
  }

  override rename(from: string, to: string): void {
    // Both sides: a move out of a denied subtree would expose the bytes, and a
    // move into one would rewrite state the policy never lets the guest touch.
    this.denyIfRefused(from)
    this.denyIfRefused(to)
    super.rename(from, to)
    this.forward({ op: 'rename', from: normalizeAbsolutePath(from), to: normalizeAbsolutePath(to) })
  }

  override sync(): void {
    this.forward({ op: 'sync' })
  }

  /** True when a mutation could not be represented locally. */
  get broken(): boolean {
    return this.failure !== undefined
  }

  /**
   * Await every queued mutation and surface the first failure.
   * @throws {Error} When the live VFS refused a forwarded mutation.
   */
  async flushWrites(): Promise<void> {
    if (this.failure !== undefined) throw this.failure
    if (this.pending.size === 0) return
    const pending = [...this.pending]
    this.pending.clear()
    const results = await Promise.allSettled(pending)
    for (const result of results) {
      if (result.status === 'rejected') {
        this.failure ??= result.reason instanceof Error ? result.reason : new Error(String(result.reason))
      }
    }
    if (this.failure !== undefined) throw this.failure
  }

  private forward(request: VfsRequest): void {
    if (this.writer === undefined) {
      // A read-only snapshot must not silently swallow a write: the guest
      // would see a successful write that no other step can observe.
      this.failure ??= new VfsProxyError('EROFS', `cannot write ${'path' in request ? request.path : 'the tree'}: the snapshot view is read-only`)
      return
    }
    try {
      const promise = this.writer.call(request)
      this.pending.add(promise)
      void promise.then(
        () => { this.pending.delete(promise) },
        (error: unknown) => {
          this.pending.delete(promise)
          this.failure ??= error instanceof Error ? error : new Error(String(error))
        },
      )
    } catch (error) {
      this.failure ??= error instanceof Error ? error : new Error(String(error))
    }
  }
}

/** Bind a snapshot view to the synchronous `WasiVfs` face. */
export function createSnapshotVfs(
  snapshot: VfsSnapshot,
  writer?: SnapshotWriteThrough,
): SnapshotWasiVfs & WasiVfs {
  return new SnapshotWasiVfs(snapshot, writer)
}
