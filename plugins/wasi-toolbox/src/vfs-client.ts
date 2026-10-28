// SPDX-License-Identifier: MIT
/**
 * Guest-side VFS clients. The async client posts request frames and awaits
 * response frames; the sync client writes the same frame into a
 * SharedArrayBuffer and blocks on `Atomics.wait`, which is what lets a
 * synchronous WASI import call into a filesystem held by another thread.
 * `ProxyWasiVfs` presents the sync client as the `WasiVfs` face the host uses.
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-client
 */
import { VfsProxyError, WasiVfsUnavailableError } from './errors.ts'
import { DEFAULT_VFS_SYNC_TIMEOUT_MS } from './limits.ts'
import type { MessageEndpoint } from './message-endpoint.ts'
import { decodeResponses, encodeRequests } from './vfs-protocol.ts'
import type { RequestRecord } from './vfs-protocol.ts'
import type { VfsDirEntry, VfsRequest, VfsStat, VfsValue, WasiVfs } from './types.ts'

/** Async proxy client used for non-blocking (control-plane) VFS work. */
export class AsyncVfsClient {
  private readonly endpoint: MessageEndpoint
  private readonly timeoutMs: number
  private readonly pending = new Map<number, {
    resolve: (result: AsyncVfsResult) => void
    timer: ReturnType<typeof setTimeout>
  }>()
  private readonly dispose: () => void
  private nextId = 1
  private closed = false

  constructor(endpoint: MessageEndpoint, options: { readonly timeoutMs?: number } = {}) {
    this.endpoint = endpoint
    this.timeoutMs = options.timeoutMs ?? DEFAULT_VFS_SYNC_TIMEOUT_MS
    this.dispose = endpoint.onMessage(message => { this.receive(message) })
  }

  /** Send one request and await its value. */
  call(request: VfsRequest): Promise<VfsValue> {
    return this.batch([request]).then(values => {
      const value = values[0]
      if (value === undefined) throw new VfsProxyError('EIO', 'proxy returned no value')
      return value
    })
  }

  /** Send several requests in one frame; any failure rejects the batch. */
  async batch(requests: readonly VfsRequest[]): Promise<VfsValue[]> {
    const results = await this.send(requests)
    return results.map(result => {
      if (result.error !== undefined) throw result.error
      return result.value as VfsValue
    })
  }

  /**
   * Send several requests in one frame and return per-request outcomes. A
   * missing preopen is an expected answer, not a protocol failure, so the
   * preopen probe uses this form.
   */
  async batchSettled(requests: readonly VfsRequest[]): Promise<readonly AsyncVfsResult[]> {
    return this.send(requests)
  }

  /** Detach the listener and fail every in-flight request. */
  close(): void {
    this.closed = true
    this.dispose()
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer)
      entry.resolve({ error: new VfsProxyError('EIO', 'proxy client closed') })
    }
    this.pending.clear()
  }

  private send(requests: readonly VfsRequest[]): Promise<AsyncVfsResult[]> {
    if (this.closed) return Promise.resolve(requests.map(() => ({ error: new VfsProxyError('EIO', 'proxy client is closed') })))
    if (requests.length === 0) return Promise.resolve([])
    const records: RequestRecord[] = requests.map(request => ({ id: this.nextId++, request }))
    const frame = encodeRequests(records)
    const promises = records.map(record => new Promise<AsyncVfsResult>(resolve => {
      const timer = setTimeout(() => {
        this.pending.delete(record.id)
        resolve({ error: new VfsProxyError('ETIMEDOUT', 'VFS proxy call timed out') })
      }, this.timeoutMs)
      this.pending.set(record.id, { resolve, timer })
    }))
    this.endpoint.postMessage({ type: 'vfs-request', frame })
    return Promise.all(promises)
  }

  private receive(message: unknown): void {
    if (typeof message !== 'object' || message === null) return
    if ((message as { type?: unknown }).type !== 'vfs-response') return
    const frame = (message as { frame?: unknown }).frame
    if (!(frame instanceof Uint8Array)) return
    let records
    try {
      records = decodeResponses(frame)
    } catch (error) {
      this.rejectAll(error instanceof Error ? error : new Error(String(error)))
      return
    }
    for (const record of records) {
      const entry = this.pending.get(record.id)
      if (entry === undefined) continue
      this.pending.delete(record.id)
      clearTimeout(entry.timer)
      if (record.response.ok) entry.resolve({ value: record.response.value })
      else entry.resolve({ error: new VfsProxyError(record.response.code, record.response.message) })
    }
  }

  private rejectAll(error: Error): void {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer)
      entry.resolve({ error: error instanceof VfsProxyError ? error : new VfsProxyError('EIO', error.message) })
    }
    this.pending.clear()
  }
}

/** Outcome of one async proxy request. */
export interface AsyncVfsResult {
  readonly value?: VfsValue
  readonly error?: VfsProxyError
}

/** Construction inputs of {@link SyncVfsClient}. */
export interface SyncVfsClientOptions {
  readonly control: SharedArrayBuffer
  readonly request: SharedArrayBuffer
  readonly response: SharedArrayBuffer
  readonly endpoint: MessageEndpoint
  readonly timeoutMs?: number
}

/**
 * Blocking proxy client. Only usable from a worker thread (a browser main
 * thread forbids `Atomics.wait`), which is exactly where WASI runs.
 */
export class SyncVfsClient {
  private readonly control: Int32Array
  private readonly request: Uint8Array
  private readonly response: Uint8Array
  private readonly endpoint: MessageEndpoint
  private readonly timeoutMs: number
  private nextId = 1

  constructor(options: SyncVfsClientOptions) {
    this.control = new Int32Array(options.control)
    this.request = new Uint8Array(options.request)
    this.response = new Uint8Array(options.response)
    this.endpoint = options.endpoint
    this.timeoutMs = options.timeoutMs ?? DEFAULT_VFS_SYNC_TIMEOUT_MS
  }

  /** Largest payload one request or response can carry, with JSON headroom. */
  get maxPayloadBytes(): number {
    return Math.max(4096, Math.min(this.request.byteLength, this.response.byteLength) - 65_536)
  }

  /** One blocking round trip. Throws `VfsProxyError` when the server fails. */
  call(request: VfsRequest): VfsValue {
    if (Atomics.load(this.control, 0) === 2) Atomics.store(this.control, 0, 0)
    if (Atomics.load(this.control, 0) !== 0) {
      throw new VfsProxyError('EBUSY', 'another synchronous VFS call is in flight')
    }
    const record: RequestRecord = { id: this.nextId++, request }
    const frame = encodeRequests([record])
    if (frame.byteLength > this.request.byteLength) {
      throw new VfsProxyError('EFBIG', 'VFS request exceeds the shared buffer')
    }
    this.request.set(frame, 0)
    Atomics.store(this.control, 1, frame.byteLength)
    Atomics.store(this.control, 0, 1)
    this.endpoint.postMessage({ type: 'vfs-sync' })
    const deadline = Date.now() + this.timeoutMs
    try {
      for (;;) {
        const remaining = deadline - Date.now()
        if (remaining <= 0) throw new VfsProxyError('ETIMEDOUT', 'VFS proxy call timed out')
        const state = Atomics.load(this.control, 0)
        if (state !== 1) break
        Atomics.wait(this.control, 0, 1, remaining)
      }
      const length = Atomics.load(this.control, 2)
      if (length <= 0) throw new VfsProxyError('EIO', 'proxy returned an empty response')
      if (length > this.response.byteLength) {
        throw new VfsProxyError('EFBIG', 'VFS response exceeds the shared buffer')
      }
      const records = decodeResponses(this.response.slice(0, length))
      const response = records[0]
      if (response === undefined) throw new VfsProxyError('EIO', 'proxy returned no response')
      if (!response.response.ok) {
        throw new VfsProxyError(response.response.code, response.response.message)
      }
      return response.response.value
    } finally {
      Atomics.store(this.control, 0, 0)
    }
  }
}

/** Implement `WasiVfs` over the blocking proxy client. */
export class ProxyWasiVfs implements WasiVfs {
  private readonly client: SyncVfsClient

  constructor(client: SyncVfsClient) {
    this.client = client
  }

  stat(path: string): VfsStat {
    return statValue(this.client.call({ op: 'stat', path }), path)
  }

  readdir(path: string): readonly VfsDirEntry[] {
    const value = this.client.call({ op: 'readdir', path })
    if (value.kind !== 'entries') throw new VfsProxyError('EIO', 'proxy returned a non-directory value', path)
    return value.entries
  }

  open(path: string, options: { create: boolean; truncate: boolean; exclusive: boolean; directory: boolean; mode?: number }): VfsStat {
    return statValue(this.client.call({
      op: 'open',
      path,
      create: options.create,
      truncate: options.truncate,
      exclusive: options.exclusive,
      directory: options.directory,
      ...(options.mode === undefined ? {} : { mode: options.mode }),
    }), path)
  }

  read(path: string, offset: number, length: number): Uint8Array {
    const bounded = Math.min(Math.max(0, length), this.client.maxPayloadBytes)
    const value = this.client.call({ op: 'read', path, offset, length: bounded })
    if (value.kind !== 'data') throw new VfsProxyError('EIO', 'proxy returned a non-data value', path)
    return value.data
  }

  write(
    path: string,
    offset: number,
    data: Uint8Array,
    options: { append: boolean; create: boolean; mode?: number },
  ): number {
    const chunkBytes = this.client.maxPayloadBytes
    let written = 0
    while (written < data.byteLength) {
      const chunk = data.subarray(written, written + chunkBytes)
      const value = this.client.call({
        op: 'write',
        path,
        offset: options.append ? 0 : offset + written,
        append: options.append,
        create: options.create || written > 0,
        ...(options.mode === undefined ? {} : { mode: options.mode }),
        data: chunk,
      })
      if (value.kind !== 'written') throw new VfsProxyError('EIO', 'proxy returned a non-write value', path)
      if (value.written <= 0) break
      written += value.written
    }
    return written
  }

  truncate(path: string, length: number): void {
    this.client.call({ op: 'truncate', path, length })
  }

  mkdir(path: string, mode?: number): void {
    this.client.call({ op: 'mkdir', path, ...(mode === undefined ? {} : { mode }) })
  }

  unlink(path: string, options: { directory: boolean }): void {
    this.client.call({ op: 'unlink', path, directory: options.directory })
  }

  /** `path_remove_directory`: the proxy request carries `directory: true`. */
  rmdir(path: string): void {
    this.client.call({ op: 'unlink', path, directory: true })
  }

  rename(from: string, to: string): void {
    this.client.call({ op: 'rename', from, to })
  }

  sync(): void {
    this.client.call({ op: 'sync' })
  }
}

/** File operations without a synchronous channel fail with `ENOTCAPABLE`. */
export class UnavailableWasiVfs implements WasiVfs {
  stat(path: string): VfsStat {
    throw new WasiVfsUnavailableError(`cannot stat ${path} without a synchronous VFS channel`)
  }

  readdir(path: string): readonly VfsDirEntry[] {
    throw new WasiVfsUnavailableError(`cannot read ${path} without a synchronous VFS channel`)
  }

  open(path: string): VfsStat {
    throw new WasiVfsUnavailableError(`cannot open ${path} without a synchronous VFS channel`)
  }

  read(path: string): Uint8Array {
    throw new WasiVfsUnavailableError(`cannot read ${path} without a synchronous VFS channel`)
  }

  write(path: string): number {
    throw new WasiVfsUnavailableError(`cannot write ${path} without a synchronous VFS channel`)
  }

  truncate(path: string): void {
    throw new WasiVfsUnavailableError(`cannot truncate ${path} without a synchronous VFS channel`)
  }

  mkdir(path: string): void {
    throw new WasiVfsUnavailableError(`cannot create ${path} without a synchronous VFS channel`)
  }

  unlink(path: string): void {
    throw new WasiVfsUnavailableError(`cannot remove ${path} without a synchronous VFS channel`)
  }

  rmdir(path: string): void {
    throw new WasiVfsUnavailableError(`cannot remove ${path} without a synchronous VFS channel`)
  }

  rename(): void {
    throw new WasiVfsUnavailableError('cannot rename without a synchronous VFS channel')
  }

  sync(): void {
    throw new VfsProxyError('ENOTCAPABLE', 'cannot fsync without a synchronous VFS channel')
  }
}

function statValue(value: VfsValue, path: string): VfsStat {
  if (value.kind !== 'stat') throw new VfsProxyError('EIO', 'proxy returned a non-stat value', path)
  return value.stat
}
