// SPDX-License-Identifier: MIT
/**
 * VFS proxy server, hosted by the DSH worker. It validates that every host path
 * stays inside a preopened root, applies the request through a `VfsBackend`
 * (the DSH worker's `node:fs` face in production), and answers over either the
 * async `postMessage` channel or the SharedArrayBuffer channel.
 *
 * The SAB channel is what makes a synchronous WASI `fd_read`/`path_open`
 * possible in the tool worker: the guest thread writes one request envelope
 * into the shared request buffer, `Atomics.wait`s, and the DSH worker serves it
 * on its own event loop and `Atomics.notify`s the response (see
 * `vfs-client.ts` for the guest half).
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-server
 */
import { VfsCapabilityError, VfsProxyError, toVfsProxyError } from './errors.ts'
import { checkFileSize } from './vfs-backends.ts'
import { DEFAULT_PREOPENS, DEFAULT_VFS_FRAME_BYTES } from './limits.ts'
import type { MessageEndpoint } from './message-endpoint.ts'
import { decodeRequests, encodeResponses } from './vfs-protocol.ts'
import type { RequestRecord, ResponseRecord } from './vfs-protocol.ts'
import { checkPathLength, isWithinRoot, normalizeAbsolutePath } from './vfs-paths.ts'
import { WORKER_VFS_NAMESPACE, VfsNamespace } from './vfs-namespace.ts'
import type { GuestPreopen, VfsBackend, VfsRequest, VfsResponse, VfsStat, VfsValue } from './types.ts'

/** Shared buffers of one synchronous proxy channel. */
export interface SyncVfsEndpoint {
  /** Int32Array of [state, requestLength, responseLength, reserved]; 16 bytes. */
  readonly control: SharedArrayBuffer
  readonly request: SharedArrayBuffer
  readonly response: SharedArrayBuffer
}

/** Allocate the three buffers of a synchronous proxy channel. */
export function createSyncVfsEndpoint(capacity = DEFAULT_VFS_FRAME_BYTES): SyncVfsEndpoint {
  if (typeof SharedArrayBuffer !== 'function') {
    throw new VfsProxyError('ENOTCAPABLE', 'SharedArrayBuffer is unavailable; crossOriginIsolated is required')
  }
  return {
    control: new SharedArrayBuffer(16),
    request: new SharedArrayBuffer(capacity),
    response: new SharedArrayBuffer(capacity),
  }
}

/** Construction inputs of {@link VfsProxyServer}. */
export interface VfsProxyServerOptions {
  readonly backend: VfsBackend
  readonly preopens?: readonly GuestPreopen[]
  readonly maxFrameBytes?: number
  /**
   * Path authority of the Worker. The server canonicalises every guest path
   * through it and applies its exec read policy, so a WASI program cannot read
   * DSH session state (G2-D01).
   */
  readonly namespace?: VfsNamespace
  /**
   * Byte budget of the read cache (see {@link VfsProxyServer.resetReadCache}).
   * `0` disables it; the default is {@link DEFAULT_READ_CACHE_BYTES}.
   */
  readonly readCacheBytes?: number
  /**
   * Byte budget of the positional-write buffer (see
   * {@link VfsProxyServer.flushWrites}). `0` disables it; the default is
   * {@link DEFAULT_WRITE_BUFFER_BYTES}.
   */
  readonly writeBufferBytes?: number
}

/**
 * Default byte budget of the positional-write buffer: 64 MiB.
 *
 * The backend can replace or append a file but not patch it, so a write that
 * is not at EOF used to rewrite the whole file. A program that back-patches
 * its output (a linker) paid output size times write count. For a file under
 * a volatile root the server now applies such writes to an in-memory copy and
 * stores the file once, when it is flushed.
 */
export const DEFAULT_WRITE_BUFFER_BYTES = 64 * 1024 * 1024

/** A volatile file whose latest bytes exist only in this server. */
interface WriteBuffer {
  /** Backing store; `length` bytes of it are the file. */
  data: Uint8Array
  length: number
}

/**
 * Default byte budget of the proxy's read cache: 128 MiB.
 *
 * The backend has no ranged read, so without the cache every `read` request
 * loads the whole file to return one slice. A program that reads a large file
 * in small pieces (a linker walking archives) then costs file size times read
 * count. The cache keeps the bytes of recently read files for the duration of
 * one dispatch; files larger than the budget are never cached. The budget has
 * to hold the whole set a program re-reads: at 32 MiB a firmware link over
 * about 53 MB of archives evicted and reloaded them (40 s), at 128 MiB each
 * file is loaded once (6.4 s) and a larger budget changes nothing. It is an
 * upper bound on what one dispatch may keep, not memory reserved up front.
 */
export const DEFAULT_READ_CACHE_BYTES = 128 * 1024 * 1024

/** One cached file: the bytes and the stat they were read under. */
interface ReadCacheEntry {
  readonly data: Uint8Array
  readonly size: number
  readonly mtimeMs: number
  readonly ino: number
}

/** Server half of the VFS proxy, one instance per tool worker. */
export class VfsProxyServer {
  readonly backend: VfsBackend
  readonly preopens: readonly GuestPreopen[]
  readonly maxFrameBytes: number
  readonly namespace: VfsNamespace
  /**
   * Observer for every path a guest mutates through this proxy.
   *
   * The toolbox uses it to attribute writes to the active dispatch, so a hard
   * termination can mark (or clean) the files a blocked interpreter left half
   * written (G2-FIX-104). It is a notification only: it must not throw and
   * must not change the request's result.
   */
  onWrite?: ((path: string) => void) | undefined
  private syncEndpoint: SyncVfsEndpoint | undefined
  private disposed = false
  /**
   * Tail of the async request chain. The tool worker can post several request
   * frames without waiting (the snapshot fallback's create-then-write is the
   * concrete case); applying them concurrently would let the write run before
   * the create it depends on. The synchronous SAB path is serialized by the
   * waiting guest, so this chain only orders the async control channel.
   */
  private requestTail: Promise<unknown> = Promise.resolve()
  /** Budget of {@link readCache} in bytes; `0` disables the cache. */
  readonly readCacheBytes: number
  /** Recently read files in least-recently-used order (Map insertion order). */
  private readonly readCache = new Map<string, ReadCacheEntry>()
  private readCacheUsed = 0
  /** Budget of {@link writeBuffers} in bytes; `0` disables buffering. */
  readonly writeBufferBytes: number
  private readonly writeBuffers = new Map<string, WriteBuffer>()

  constructor(options: VfsProxyServerOptions) {
    this.backend = options.backend
    this.preopens = options.preopens ?? DEFAULT_PREOPENS
    this.maxFrameBytes = options.maxFrameBytes ?? DEFAULT_VFS_FRAME_BYTES
    this.namespace = options.namespace ?? WORKER_VFS_NAMESPACE
    const budget = options.readCacheBytes ?? DEFAULT_READ_CACHE_BYTES
    this.readCacheBytes = Number.isFinite(budget) && budget > 0 ? Math.floor(budget) : 0
    const writeBudget = options.writeBufferBytes ?? DEFAULT_WRITE_BUFFER_BYTES
    this.writeBufferBytes = Number.isFinite(writeBudget) && writeBudget > 0 ? Math.floor(writeBudget) : 0
  }

  /** Number of files whose latest bytes are still only in this server. */
  get pendingWrites(): number {
    return this.writeBuffers.size
  }

  /**
   * Store every buffered file on the backend.
   *
   * Buffering applies only to files under a volatile root (`/tmp`,
   * `/dsh/tmp`): they have no sink, no WAL frame and no per-write host
   * outcome, so deferring the store changes no durability answer. What does
   * change is when a backend refusal of the *store* (the `tmp` quota) is
   * reported: at the flush, not at the positional write. The single-file
   * limit is still checked on every write. Flush points are a guest `fsync`,
   * a `truncate`, `rename` or directory removal through the proxy, and the
   * command boundary, where the owner calls this before it reports the exit.
   * Until then a reader outside the proxy sees the file as it was before the
   * first positional write.
   * @throws the first backend failure, after every file was attempted.
   */
  async flushWrites(): Promise<void> {
    let first: unknown
    for (const path of [...this.writeBuffers.keys()]) {
      try {
        await this.flushWrite(path)
      } catch (error) {
        first ??= error
      }
    }
    if (first !== undefined) throw first
  }

  /**
   * Drop every buffered file without storing it. The owner calls this when a
   * dispatch is hard-stopped: the backend keeps the pre-buffer bytes and the
   * partial-write marker records that the file is incomplete.
   */
  discardWrites(): void {
    this.writeBuffers.clear()
  }

  private async flushWrite(path: string): Promise<void> {
    const buffer = this.writeBuffers.get(path)
    if (buffer === undefined) return
    // Remove first: a failed store must not be retried on every later call.
    this.writeBuffers.delete(path)
    this.dropCached(path)
    await this.backend.writeFile(path, buffer.data.slice(0, buffer.length), { create: true })
  }

  private writeBuffersUsed(): number {
    let used = 0
    for (const buffer of this.writeBuffers.values()) used += buffer.data.byteLength
    return used
  }

  /** True when positional writes to this canonical path may be buffered. */
  private bufferable(path: string): boolean {
    return this.writeBufferBytes > 0 && this.namespace.classify(path).root?.kind === 'volatile'
  }

  /**
   * Apply one write to a buffered file. Returns false when the file would no
   * longer fit the budget; the caller then flushes it and writes directly.
   */
  private writeBuffered(path: string, buffer: WriteBuffer, offset: number, data: Uint8Array): boolean {
    const end = Math.max(buffer.length, offset + data.byteLength)
    checkFileSize(path, end)
    if (end > buffer.data.byteLength) {
      const capacity = Math.max(end, Math.min(buffer.data.byteLength * 2, end + 16 * 1024 * 1024))
      if (this.writeBuffersUsed() - buffer.data.byteLength + capacity > this.writeBufferBytes) return false
      const grown = new Uint8Array(capacity)
      grown.set(buffer.data.subarray(0, buffer.length), 0)
      buffer.data = grown
    }
    // Bytes between the old length and a later offset are a hole: zero.
    if (offset > buffer.length) buffer.data.fill(0, buffer.length, offset)
    buffer.data.set(data, offset)
    buffer.length = end
    return true
  }

  /** The backend stat with a buffered file's current size. */
  private overlaySize(path: string, stat: VfsStat): VfsStat {
    const buffer = this.writeBuffers.get(path)
    return buffer === undefined || stat.kind !== 'file' ? stat : { ...stat, size: buffer.length }
  }

  /**
   * Drop every cached file.
   *
   * The owner calls this at each dispatch boundary. Inside one dispatch an
   * entry is revalidated by `stat` (size, mtime, inode) on every read and
   * dropped by every mutation that goes through this proxy. A writer outside
   * the proxy that keeps all three stat fields unchanged cannot be seen by
   * that check, so cached bytes must not outlive the command that read them.
   */
  resetReadCache(): void {
    this.readCache.clear()
    this.readCacheUsed = 0
  }

  private dropCached(path: string): void {
    const entry = this.readCache.get(path)
    if (entry === undefined) return
    this.readCache.delete(path)
    this.readCacheUsed -= entry.data.byteLength
  }

  private storeCached(path: string, stat: VfsStat, data: Uint8Array): void {
    this.dropCached(path)
    if (stat.kind !== 'file' || stat.size !== data.byteLength) return
    if (data.byteLength > this.readCacheBytes) return
    while (this.readCacheUsed + data.byteLength > this.readCacheBytes) {
      const oldest = this.readCache.keys().next()
      if (oldest.done === true) break
      this.dropCached(oldest.value)
    }
    this.readCache.set(path, { data, size: stat.size, mtimeMs: stat.mtimeMs, ino: stat.ino })
    this.readCacheUsed += data.byteLength
  }

  /**
   * Whole-file bytes for a ranged `read`, served from the cache when the
   * backend's current stat still matches the one the bytes were read under.
   * Returns undefined when the cache is disabled or the stat fails, so the
   * caller takes the uncached path and reports the backend's own error.
   */
  private async cachedFile(path: string): Promise<Uint8Array | undefined> {
    if (this.readCacheBytes === 0) return undefined
    let stat: VfsStat
    try {
      stat = await this.backend.stat(path)
    } catch {
      this.dropCached(path)
      return undefined
    }
    if (stat.kind !== 'file') {
      this.dropCached(path)
      return undefined
    }
    const entry = this.readCache.get(path)
    if (entry !== undefined && entry.size === stat.size && entry.mtimeMs === stat.mtimeMs && entry.ino === stat.ino) {
      this.readCache.delete(path)
      this.readCache.set(path, entry)
      return entry.data
    }
    this.dropCached(path)
    if (stat.size > this.readCacheBytes) return undefined
    const data = await this.backend.readFile(path)
    this.storeCached(path, stat, data)
    return data
  }

  /** The synchronous endpoint, when one was created for this server. */
  get sync(): SyncVfsEndpoint | undefined {
    return this.syncEndpoint
  }

  /** Allocate the SAB channel and pass the buffers to the tool worker's init. */
  createSyncEndpoint(capacity = DEFAULT_VFS_FRAME_BYTES): SyncVfsEndpoint {
    if (this.syncEndpoint !== undefined) throw new VfsProxyError('EINVAL', 'sync endpoint already created')
    this.syncEndpoint = createSyncVfsEndpoint(capacity)
    return this.syncEndpoint
  }

  /** Serve one async request frame; returns the response frame. */
  async handleFrame(frame: Uint8Array): Promise<Uint8Array> {
    if (frame.byteLength > this.maxFrameBytes) {
      throw new VfsProxyError('EFBIG', 'VFS frame exceeds the proxy limit')
    }
    const records = decodeRequests(frame)
    const responses: ResponseRecord[] = []
    for (const record of records) {
      responses.push({ id: record.id, response: await this.execute(record.request) })
    }
    const encoded = encodeResponses(responses)
    if (encoded.byteLength > this.maxFrameBytes) {
      throw new VfsProxyError('EFBIG', 'VFS response exceeds the proxy limit')
    }
    return encoded
  }

  /** Apply one request to the backend, converting failures into responses. */
  async execute(request: VfsRequest): Promise<VfsResponse> {
    try {
      return { ok: true, value: await this.apply(request) }
    } catch (error) {
      const failure = toVfsProxyError(error)
      return { ok: false, code: failure.code, message: failure.message }
    }
  }

  /** Attach the server to a message endpoint; the disposer detaches it. */
  attach(port: MessageEndpoint): () => void {
    const dispose = port.onMessage(message => {
      void this.handleMessage(message, port).catch((error: unknown) => {
        // Protocol-level failures cannot be reported as an errno response; the
        // guest will time out or fail its own call. Keep the server alive.
        if (!this.disposed) console.error('wasi-toolbox: VFS proxy message failed', error)
      })
    })
    return () => {
      this.disposed = true
      dispose()
    }
  }

  /** Serve the pending SAB request, if the guest signalled one. */
  async serveSync(): Promise<void> {
    const endpoint = this.syncEndpoint
    if (endpoint === undefined) throw new VfsProxyError('EINVAL', 'sync endpoint is not configured')
    const control = new Int32Array(endpoint.control)
    if (Atomics.load(control, 0) !== 1) return
    const length = Atomics.load(control, 1)
    if (length <= 0 || length > endpoint.request.byteLength) {
      this.publishSync(endpoint, new Uint8Array(0))
      return
    }
    const frame = new Uint8Array(endpoint.request, 0, length)
    let response: Uint8Array
    try {
      response = await this.handleFrame(frame)
    } catch {
      response = new Uint8Array(0)
    }
    if (response.byteLength > endpoint.response.byteLength) response = new Uint8Array(0)
    this.publishSync(endpoint, response)
  }

  private publishSync(endpoint: SyncVfsEndpoint, response: Uint8Array): void {
    const control = new Int32Array(endpoint.control)
    if (response.byteLength > 0) new Uint8Array(endpoint.response, 0, response.byteLength).set(response)
    Atomics.store(control, 2, response.byteLength)
    Atomics.store(control, 0, 2)
    Atomics.notify(control, 0)
  }

  private async handleMessage(message: unknown, port: MessageEndpoint): Promise<void> {
    if (typeof message !== 'object' || message === null) return
    const type = (message as { type?: unknown }).type
    if (type === 'vfs-request') {
      const frame = (message as { frame?: unknown }).frame
      if (!(frame instanceof Uint8Array)) return
      const run = this.requestTail.then(async () => {
        const response = await this.handleFrame(frame)
        port.postMessage({ type: 'vfs-response', frame: response })
      })
      this.requestTail = run.then(() => undefined, () => undefined)
      await run
      return
    }
    if (type === 'vfs-sync') await this.serveSync()
  }

  private async apply(request: VfsRequest): Promise<VfsValue> {
    switch (request.op) {
      case 'stat': {
        const path = this.guardPath(request.path, 'read')
        return { kind: 'stat', stat: this.overlaySize(path, await this.backend.stat(path)) }
      }
      case 'readdir': {
        const path = this.guardPath(request.path, 'read')
        return { kind: 'entries', entries: await this.backend.readdir(path) }
      }
      case 'open': {
        const writes = request.create || request.truncate || request.exclusive
        const path = this.guardPath(request.path, writes ? 'write' : 'read')
        if (request.directory) {
          const stat = await this.backend.stat(path)
          if (stat.kind !== 'directory') throw new VfsProxyError('ENOTDIR', 'not a directory', path)
          return { kind: 'stat', stat }
        }
        let stat: VfsStat | undefined
        try {
          stat = await this.backend.stat(path)
        } catch (error) {
          if (toVfsProxyError(error, 'ENOENT', path).code !== 'ENOENT') throw error
        }
        // Opening for creation/truncation mutates the file even before the
        // first write; a dispatch cut off after this open must know.
        if (request.create || request.truncate) {
          this.noteWrite(path)
          this.dropCached(path)
        }
        // A truncating open empties the file: the buffered bytes are gone too.
        if (request.truncate) this.writeBuffers.delete(path)
        if (stat === undefined) {
          if (!request.create) throw new VfsProxyError('ENOENT', 'no such file or directory', path)
          await this.backend.writeFile(path, new Uint8Array(0), {
            create: true,
            ...(request.mode === undefined ? {} : { mode: request.mode }),
          })
          stat = await this.backend.stat(path)
        } else {
          if (stat.kind === 'directory') throw new VfsProxyError('EISDIR', 'is a directory', path)
          if (request.exclusive) throw new VfsProxyError('EEXIST', 'file exists', path)
          if (request.truncate) await this.backend.writeFile(path, new Uint8Array(0), { create: false })
          stat = await this.backend.stat(path)
        }
        return { kind: 'stat', stat: this.overlaySize(path, stat) }
      }
      case 'read': {
        const path = this.guardPath(request.path, 'read')
        const pending = this.writeBuffers.get(path)
        if (pending !== undefined) {
          const start = Math.min(pending.length, Math.max(0, request.offset))
          const stop = Math.min(pending.length, start + Math.max(0, request.length))
          return { kind: 'data', data: pending.data.slice(start, stop) }
        }
        let data: Uint8Array
        try {
          data = await this.cachedFile(path) ?? await this.backend.readFile(path)
        } catch (error) {
          const failure = toVfsProxyError(error, 'EIO', path)
          let stat: VfsStat | undefined
          try {
            stat = await this.backend.stat(path)
          } catch {
            stat = undefined
          }
          if (stat?.kind === 'directory') throw new VfsProxyError('EISDIR', 'is a directory', path)
          throw failure
        }
        const offset = Math.max(0, request.offset)
        return { kind: 'data', data: data.slice(offset, offset + Math.max(0, request.length)) }
      }
      case 'write': {
        const path = this.guardPath(request.path)
        const data = request.data
        const pending = this.writeBuffers.get(path)
        if (pending !== undefined) {
          // Once a file is buffered every write goes to the buffer, appends
          // included, so the stored file is the writes in the order made.
          const at = request.append ? pending.length : Math.max(0, request.offset)
          if (this.writeBuffered(path, pending, at, data)) {
            this.noteWrite(path)
            return { kind: 'written', written: data.byteLength }
          }
          await this.flushWrite(path)
        }
        if (request.append) {
          this.dropCached(path)
          await this.backend.writeFile(path, data, {
            append: true,
            create: request.create,
            ...(request.mode === undefined ? {} : { mode: request.mode }),
          })
          this.noteWrite(path)
          return { kind: 'written', written: data.byteLength }
        }
        // A sequential writer always lands exactly at EOF, and that case needs
        // only the file's size, not its bytes: ask `stat` first. Anything the
        // stat cannot settle (a missing file, a directory, a real positional
        // write) takes the whole-file path below and keeps its error codes.
        let sizeAtStart: number | undefined
        try {
          const current = await this.backend.stat(path)
          if (current.kind === 'file') sizeAtStart = current.size
        } catch {
          sizeAtStart = undefined
        }
        if (sizeAtStart !== undefined && Math.max(0, request.offset) === sizeAtStart) {
          this.dropCached(path)
          await this.backend.writeFile(path, data, {
            append: true,
            create: request.create,
            ...(request.mode === undefined ? {} : { mode: request.mode }),
          })
          this.noteWrite(path)
          return { kind: 'written', written: data.byteLength }
        }
        let existing: Uint8Array = new Uint8Array(0)
        try {
          existing = await this.cachedFile(path) ?? await this.backend.readFile(path)
        } catch (error) {
          if (toVfsProxyError(error, 'ENOENT', path).code !== 'ENOENT' || !request.create) throw error
        }
        const offset = Math.max(0, request.offset)
        this.dropCached(path)
        if (offset === existing.byteLength) {
          // A write that starts exactly at EOF is an append. Marking it as
          // such lets the production backend publish only the new suffix to
          // the WAL sink: a chunked write of an N-byte file costs N bytes,
          // not the 1+2+...+N whole-file rewrites (the G2-A09 shard-write
          // shape that exhausted the 256 MiB WAL budget before the timeout).
          await this.backend.writeFile(path, data, {
            append: true,
            create: request.create,
            ...(request.mode === undefined ? {} : { mode: request.mode }),
          })
          this.noteWrite(path)
          return { kind: 'written', written: data.byteLength }
        }
        const end = offset + data.byteLength
        const next = new Uint8Array(Math.max(existing.byteLength, end))
        next.set(existing, 0)
        next.set(data, offset)
        if (this.bufferable(path) && this.writeBuffersUsed() + next.byteLength <= this.writeBufferBytes) {
          // A real positional write to a volatile file: keep the patched
          // copy here instead of storing the whole file for every patch.
          checkFileSize(path, next.byteLength)
          this.writeBuffers.set(path, { data: next, length: next.byteLength })
          this.noteWrite(path)
          return { kind: 'written', written: data.byteLength }
        }
        await this.backend.writeFile(path, next, {
          create: request.create,
          ...(request.mode === undefined ? {} : { mode: request.mode }),
        })
        // The backend now holds exactly `next`; keeping it saves the whole-file
        // read the following positional write or read would otherwise repeat.
        if (this.readCacheBytes > 0) {
          try {
            this.storeCached(path, await this.backend.stat(path), next)
          } catch {
            // The write succeeded; a failed stat only costs the cache entry.
          }
        }
        this.noteWrite(path)
        return { kind: 'written', written: data.byteLength }
      }
      case 'truncate': {
        const path = this.guardPath(request.path)
        await this.flushWrite(path)
        this.dropCached(path)
        await this.backend.truncate(path, Math.max(0, request.length))
        this.noteWrite(path)
        return { kind: 'void' }
      }
      case 'mkdir': {
        const path = this.guardPath(request.path)
        await this.backend.mkdir(path, request.mode)
        return { kind: 'void' }
      }
      case 'unlink': {
        const path = this.guardPath(request.path)
        // A removed directory can sit above cached files; drop everything.
        this.resetReadCache()
        // A removed file takes its buffered bytes with it; a removed directory
        // must see the files below it as the guest left them.
        if (request.directory) await this.flushWrites()
        else this.writeBuffers.delete(path)
        await this.backend.unlink(path, { directory: request.directory, recursive: false })
        return { kind: 'void' }
      }
      case 'rename': {
        // A move out of the session store exposes the same bytes as a read.
        const from = this.guardPath(request.from, 'read')
        const to = this.guardPath(request.to)
        // Either side may be a directory above cached files; drop everything.
        this.resetReadCache()
        await this.flushWrites()
        await this.backend.rename(from, to)
        return { kind: 'void' }
      }
      case 'sync': {
        await this.flushWrites()
        await this.backend.sync?.()
        return { kind: 'void' }
      }
    }
  }

  /** Tell the owner that a dispatch mutated this host path. */
  private noteWrite(path: string): void {
    try {
      this.onWrite?.(path)
    } catch {
      // An observer cannot change the guest's result.
    }
  }

  /**
   * Canonicalise one guest-supplied host path and enforce the namespace.
   *
   * Resolution happens before the preopen check: `/tmp/x` becomes
   * `/dsh/tmp/x`, which every volatile preopen covers, and the backend then
   * sees the one storage path. A read of a DSH-internal subtree fails
   * `EACCES` here, before any bytes reach the guest.
   * @param path - host path supplied by the guest.
   * @param access - `read` applies the exec read policy; `write` does not.
   * @returns the canonical host path the backend should use.
   */
  private guardPath(path: string, access: 'read' | 'write' = 'write'): string {
    checkPathLength(path)
    let normalized: string
    try {
      normalized = this.namespace.storagePath(normalizeAbsolutePath(path))
    } catch (error) {
      throw toVfsProxyError(error, 'EINVAL', path)
    }
    const allowed = this.preopens.some(preopen => isWithinRoot(normalizeAbsolutePath(preopen.hostPath), normalized))
    if (!allowed) throw new VfsCapabilityError('path is outside the preopened host roots', normalized)
    if (access === 'read') this.namespace.assertExecReadable(normalized)
    return normalized
  }
}

/** Re-export for callers that build frames by hand (tests, diagnostics). */
export type { RequestRecord, ResponseRecord }
