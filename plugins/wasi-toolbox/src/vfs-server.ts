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

  constructor(options: VfsProxyServerOptions) {
    this.backend = options.backend
    this.preopens = options.preopens ?? DEFAULT_PREOPENS
    this.maxFrameBytes = options.maxFrameBytes ?? DEFAULT_VFS_FRAME_BYTES
    this.namespace = options.namespace ?? WORKER_VFS_NAMESPACE
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
        return { kind: 'stat', stat: await this.backend.stat(path) }
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
        if (request.create || request.truncate) this.noteWrite(path)
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
        return { kind: 'stat', stat }
      }
      case 'read': {
        const path = this.guardPath(request.path, 'read')
        let data: Uint8Array
        try {
          data = await this.backend.readFile(path)
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
        if (request.append) {
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
          existing = await this.backend.readFile(path)
        } catch (error) {
          if (toVfsProxyError(error, 'ENOENT', path).code !== 'ENOENT' || !request.create) throw error
        }
        const offset = Math.max(0, request.offset)
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
        await this.backend.writeFile(path, next, {
          create: request.create,
          ...(request.mode === undefined ? {} : { mode: request.mode }),
        })
        this.noteWrite(path)
        return { kind: 'written', written: data.byteLength }
      }
      case 'truncate': {
        const path = this.guardPath(request.path)
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
        await this.backend.unlink(path, { directory: request.directory, recursive: false })
        return { kind: 'void' }
      }
      case 'rename': {
        // A move out of the session store exposes the same bytes as a read.
        const from = this.guardPath(request.from, 'read')
        const to = this.guardPath(request.to)
        await this.backend.rename(from, to)
        return { kind: 'void' }
      }
      case 'sync': {
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
