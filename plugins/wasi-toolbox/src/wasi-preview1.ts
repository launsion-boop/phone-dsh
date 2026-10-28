// SPDX-License-Identifier: MIT
/**
 * Minimal WASI preview1 host for `wasi_snapshot_preview1` modules. It is an own
 * implementation (no third-party shim): the imports are built from the host's
 * own table, file descriptors live in the guest, and every path is resolved
 * through the preopen table before it reaches the `WasiVfs` face.
 *
 * Synchrony: the preview1 ABI is synchronous, so the `WasiVfs` given here must
 * answer without awaiting. In the tool worker that is the SharedArrayBuffer
 * proxy client; in unit tests it is the in-memory filesystem. A module that
 * only writes to stdout works without a filesystem at all.
 *
 * The memory ceiling is enforced on every host call, because a wasm module that
 * defines its own memory cannot be given a maximum at instantiation. Modules
 * that import their memory get a real `maximum` as well (`hot-instance.ts`).
 *
 * The optional spawn bridge is one extra descriptor kind: the guest opens a
 * private path under the bridge root, writes one framed request and reads one
 * framed response. The bytes never reach the VFS; `spawn-bridge.ts` owns the
 * protocol and the nested interpreter run. That is how CPython's `subprocess`
 * shim reaches the toolbox without a preview1 process syscall.
 * @module @phone-dsh/dsh-wasi-toolbox/wasi-preview1
 */
import { VfsProxyError, WasiMemoryCeilingError, WasiProcExit, WasiTrapError, errorCodeOf } from './errors.ts'
import { DEFAULT_HOT_INSTANCE_MEMORY_BYTES, DEFAULT_PATH_MAX_BYTES } from './limits.ts'
import { MAX_HTTP_REQUEST_FRAME_BYTES, encodeHttpFailure } from './http-bridge.ts'
import type { HttpBridge } from './http-bridge.ts'
import { MAX_SPAWN_FRAME_BYTES, SPAWN_FRAME_PREFIX_BYTES } from './spawn-bridge.ts'
import type { SpawnBridge } from './spawn-bridge.ts'
import {
  ALL_RIGHTS, WASI_ERRNO, WASI_FDFLAGS, WASI_FILETYPE, WASI_OFLAGS, WASI_RIGHTS, errnoFromError,
} from './wasi-errno.ts'
import { WasiStdin } from './stdin-delivery.ts'
import { isWithinRoot, resolveGuestPath } from './vfs-paths.ts'
import type { GuestPreopen, VfsDirEntry, VfsStat, WasiVfs } from './types.ts'

const encoder = new TextEncoder()
const decoder = new TextDecoder()

/**
 * Errno codes whose actionable detail is mirrored on the command's stderr.
 *
 * A WASI errno is a number, so the guest (and therefore CPython) can only
 * report a generic OS error. These are the bounded-resource and
 * read-policy failures where the detail names a limit and a remediation the
 * model needs: the D4 single-file refusal, the exec read policy, a host
 * resource refusal and the D3 flow-control fail-loud window.
 */
const VFS_DIAGNOSTIC_CODES: ReadonlySet<string | undefined> = new Set([
  'EFBIG',
  'ENOSPC',
  'EDQUOT',
  'EACCES',
  'ETIMEDOUT',
])

type HostFunction = (...args: never[]) => number

interface FdEntry {
  kind: 'stdin' | 'stdout' | 'stderr' | 'file' | 'directory' | 'spawn' | 'http'
  /** Guest path used for `fd_prestat_dir_name` and relative resolution. */
  guestPath?: string
  hostPath?: string
  offset: number
  append: boolean
  readable: boolean
  writable: boolean
  preopen: boolean
}

/**
 * Per-descriptor state of one open spawn control file.
 *
 * A guest may write the request in several `fd_write` calls and read the
 * response in several `fd_read` calls; the state owns both directions and the
 * declared frame length. One descriptor carries one request at a time.
 */
interface ControlFdState {
  /** Which private control descriptor this open fd carries. */
  readonly kind: 'spawn' | 'http'
  readonly chunks: Uint8Array[]
  length: number
  /** Total frame length once the 8-byte prefix arrived. */
  expected?: number
  /**
   * Set when a declared frame is over this kind's limit. The host keeps
   * draining the guest's writes (without buffering them) so it can answer the
   * completed request with a structured error instead of a bare errno.
   */
  discard: boolean
  /** Complete response frame, or undefined while the request is incomplete. */
  response?: Uint8Array
  /** Read cursor into `response`. */
  offset: number
}

/** The control-file faces that share `/__xl__`. */
type ControlBridge = SpawnBridge | HttpBridge

/** Construction inputs of {@link WasiPreview1}. */
export interface WasiPreview1Options {
  readonly args: readonly string[]
  readonly env?: Readonly<Record<string, string>>
  readonly preopens: readonly GuestPreopen[]
  readonly vfs: WasiVfs
  /**
   * Complete stdin payload, or a pre-built {@link WasiStdin} feed. The feed
   * marks EOF explicitly; a bare array is a complete payload.
   */
  readonly stdin?: Uint8Array | WasiStdin
  /**
   * Called after every `fd_read` of fd 0 with the bytes returned (0 at EOF).
   * The toolbox dispatch watchdog uses the first call to prove the
   * interpreter actually consumed the script delivery.
   */
  readonly onStdinRead?: (bytes: number, total: number) => void
  readonly stdout?: (chunk: Uint8Array) => void
  readonly stderr?: (chunk: Uint8Array) => void
  readonly memoryLimitBytes?: number
  readonly clockNs?: () => bigint
  readonly randomBytes?: (target: Uint8Array) => void
  readonly sleep?: (milliseconds: number) => void
  readonly pathMaxBytes?: number
  /**
   * Subprocess control file. Present in the Python tool worker only; the
   * preopen table must contain the bridge root, and every request under it is
   * intercepted here instead of reaching the VFS.
   */
  readonly spawn?: SpawnBridge
  /**
   * HTTP egress control file (`/__xl__/http`). Present when the DSH Worker
   * injected a loopback `/v1/http` route; it shares the private preopen with
   * the spawn bridge.
   */
  readonly http?: HttpBridge
}

/** Own WASI preview1 host. */
export class WasiPreview1 {
  readonly args: readonly string[]
  readonly env: readonly string[]
  readonly preopens: readonly GuestPreopen[]
  readonly memoryLimitBytes: number
  readonly imports: WebAssembly.Imports
  private readonly vfs: WasiVfs
  private readonly stdin: WasiStdin
  private readonly stdoutSink: ((chunk: Uint8Array) => void) | undefined
  private readonly stderrSink: ((chunk: Uint8Array) => void) | undefined
  private readonly onStdinRead: ((bytes: number, total: number) => void) | undefined
  private readonly clockNs: () => bigint
  private readonly randomBytes: (target: Uint8Array) => void
  private readonly sleep: (milliseconds: number) => void
  private readonly pathMaxBytes: number
  private readonly spawn: SpawnBridge | undefined
  private readonly http: HttpBridge | undefined
  private readonly controlFds = new Map<number, ControlFdState>()
  private readonly fds: (FdEntry | undefined)[] = []
  private memory: WebAssembly.Memory | undefined
  private instance: WebAssembly.Instance | undefined
  private exited: number | undefined

  constructor(options: WasiPreview1Options) {
    this.args = options.args
    this.env = Object.entries(options.env ?? {})
      .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
      .map(([key, value]) => `${key}=${value}`)
    this.preopens = options.preopens
    this.vfs = options.vfs
    this.stdin = options.stdin instanceof WasiStdin
      ? options.stdin
      : new WasiStdin(options.stdin ?? new Uint8Array(0), true)
    this.onStdinRead = options.onStdinRead
    this.stdoutSink = options.stdout
    this.stderrSink = options.stderr
    this.memoryLimitBytes = options.memoryLimitBytes ?? DEFAULT_HOT_INSTANCE_MEMORY_BYTES
    this.clockNs = options.clockNs ?? (() => BigInt(Date.now()) * 1_000_000n)
    this.randomBytes = options.randomBytes ?? defaultRandomBytes
    this.sleep = options.sleep ?? defaultSleep
    this.pathMaxBytes = options.pathMaxBytes ?? DEFAULT_PATH_MAX_BYTES
    this.spawn = options.spawn
    this.http = options.http

    this.fds[0] = { kind: 'stdin', offset: 0, append: false, readable: true, writable: false, preopen: false }
    this.fds[1] = { kind: 'stdout', offset: 0, append: false, readable: false, writable: true, preopen: false }
    this.fds[2] = { kind: 'stderr', offset: 0, append: false, readable: false, writable: true, preopen: false }
    for (const preopen of this.preopens) {
      this.fds.push({
        kind: 'directory',
        guestPath: preopen.guestPath,
        hostPath: preopen.hostPath,
        offset: 0,
        append: false,
        readable: true,
        writable: true,
        preopen: true,
      })
    }

    const functions: Record<string, HostFunction> = {
      args_get: this.argsGet.bind(this),
      args_sizes_get: this.argsSizesGet.bind(this),
      environ_get: this.environGet.bind(this),
      environ_sizes_get: this.environSizesGet.bind(this),
      clock_res_get: this.clockResGet.bind(this),
      clock_time_get: this.clockTimeGet.bind(this),
      fd_advise: this.fdAdvise.bind(this),
      fd_allocate: this.fdAllocate.bind(this),
      fd_close: this.fdClose.bind(this),
      fd_datasync: this.fdDatasync.bind(this),
      fd_fdstat_get: this.fdFdstatGet.bind(this),
      fd_fdstat_set_flags: this.fdFdstatSetFlags.bind(this),
      fd_fdstat_set_rights: this.fdFdstatSetRights.bind(this),
      fd_filestat_get: this.fdFilestatGet.bind(this),
      fd_filestat_set_size: this.fdFilestatSetSize.bind(this),
      fd_filestat_set_times: this.fdFilestatSetTimes.bind(this),
      fd_pread: this.fdPread.bind(this),
      fd_prestat_dir_name: this.fdPrestatDirName.bind(this),
      fd_prestat_get: this.fdPrestatGet.bind(this),
      fd_pwrite: this.fdPwrite.bind(this),
      fd_read: this.fdRead.bind(this),
      fd_readdir: this.fdReaddir.bind(this),
      fd_renumber: this.fdRenumber.bind(this),
      fd_seek: this.fdSeek.bind(this),
      fd_sync: this.fdSync.bind(this),
      fd_tell: this.fdTell.bind(this),
      fd_write: this.fdWrite.bind(this),
      path_create_directory: this.pathCreateDirectory.bind(this),
      path_filestat_get: this.pathFilestatGet.bind(this),
      path_filestat_set_times: this.pathFilestatSetTimes.bind(this),
      path_link: this.unsupported.bind(this),
      path_open: this.pathOpen.bind(this),
      path_readlink: this.unsupported.bind(this),
      path_remove_directory: this.pathRemoveDirectory.bind(this),
      path_rename: this.pathRename.bind(this),
      path_symlink: this.unsupported.bind(this),
      path_unlink_file: this.pathUnlinkFile.bind(this),
      poll_oneoff: this.pollOneoff.bind(this),
      proc_exit: this.procExit.bind(this),
      proc_raise: this.unsupported.bind(this),
      random_get: this.randomGet.bind(this),
      sched_yield: this.schedYield.bind(this),
      sock_accept: this.unsupported.bind(this),
      sock_recv: this.unsupported.bind(this),
      sock_send: this.unsupported.bind(this),
      sock_shutdown: this.unsupported.bind(this),
    }
    this.imports = { wasi_snapshot_preview1: functions }
  }

  /** Bind the instance's exported (or already imported) memory. */
  attach(instance: WebAssembly.Instance): void {
    this.instance = instance
    const memory = instance.exports.memory
    if (memory instanceof WebAssembly.Memory) {
      this.setMemory(memory)
      return
    }
    if (this.memory !== undefined) return
    throw new WasiTrapError('WASI module does not export or import a linear memory')
  }

  /** Bind a memory explicitly (used when the module imports it). */
  setMemory(memory: WebAssembly.Memory): void {
    if (memory.buffer.byteLength > this.memoryLimitBytes) {
      throw new WasiMemoryCeilingError(this.memoryLimitBytes, memory.buffer.byteLength)
    }
    this.memory = memory
  }

  /** Current memory size in bytes (0 before attach). */
  get memoryBytes(): number {
    return this.memory?.buffer.byteLength ?? 0
  }

  /**
   * Run the module's `_start` export. Returns the `proc_exit` code, or 0 when
   * the entry point returns normally.
   */
  start(): number {
    const instance = this.instance
    if (instance === undefined) throw new WasiTrapError('WASI host is not attached to an instance')
    const entry = (instance.exports as Record<string, unknown>)._start
    if (typeof entry !== 'function') throw new WasiTrapError('WASI module has no exported _start')
    try {
      ;(entry as () => void)()
      return 0
    } catch (error) {
      if (error instanceof WasiProcExit) {
        this.exited = error.code
        return error.code
      }
      throw error
    }
  }

  /** Exit code set by `proc_exit`, when it ran. */
  get exitCode(): number | undefined {
    return this.exited
  }

  // ---------------------------------------------------------------- memory

  private touch(): { bytes: Uint8Array; view: DataView } {
    const memory = this.memory
    if (memory === undefined) throw new WasiTrapError('WASI memory is not attached')
    const buffer = memory.buffer
    if (buffer.byteLength > this.memoryLimitBytes) {
      throw new WasiMemoryCeilingError(this.memoryLimitBytes, buffer.byteLength)
    }
    return { bytes: new Uint8Array(buffer), view: new DataView(buffer) }
  }

  private ensure(offset: number, length: number): void {
    const size = this.memory?.buffer.byteLength ?? 0
    if (!Number.isInteger(offset) || !Number.isInteger(length) || offset < 0 || length < 0 || offset + length > size) {
      throw new VfsProxyError('EFAULT', 'guest pointer out of range')
    }
  }

  private readString(pointer: number, length: number): string {
    this.ensure(pointer, length)
    if (length > this.pathMaxBytes) throw new VfsProxyError('ENAMETOOLONG', 'path exceeds PATH_MAX')
    const bytes = new Uint8Array(this.memory!.buffer)
    return decoder.decode(bytes.subarray(pointer, pointer + length))
  }

  private fail(error: unknown): number {
    if (error instanceof WasiProcExit || error instanceof WasiMemoryCeilingError || error instanceof WasiTrapError) {
      throw error
    }
    // A WASI errno cannot carry text. For the D4 single-file refusal, the exec
    // read policy and the bounded flow-control wait, put the actionable
    // message on the command's stderr as well: a guest program such as python3
    // otherwise reports only "File too large" / "Permission denied" / a bare
    // timeout and the model cannot learn the limit or the remediation without
    // another probe (G2-A09, G2-D01, G2-FIX-103).
    const code = errorCodeOf(error)
    if (VFS_DIAGNOSTIC_CODES.has(code) && this.stderrSink !== undefined) {
      try {
        const detail = (error instanceof Error ? error.message : String(error))
          .replace(new RegExp(`^(?:${code}: )+`), '')
        // The proxy client re-prefixes the code onto a server message that
        // already names it; keep one code prefix in the visible line.
        this.stderrSink(encoder.encode(`${code}: ${detail}\n`))
      } catch (sinkError) {
        // Diagnostics are best effort; the errno still reaches the guest. A
        // trap raised by the sink itself (a nested child's output budget) is
        // terminal and must unwind the guest, not be swallowed here.
        if (sinkError instanceof WasiTrapError || sinkError instanceof WasiMemoryCeilingError) throw sinkError
      }
    }
    return errnoFromError(error)
  }

  private stringTableSize(values: readonly string[]): number {
    let size = 0
    for (const value of values) size += encoder.encode(value).byteLength + 1
    return size
  }

  private writeStringTable(values: readonly string[], pointers: number, buffer: number, view: DataView, bytes: Uint8Array): void {
    let cursor = buffer
    for (const [index, value] of values.entries()) {
      const encoded = encoder.encode(value)
      view.setUint32(pointers + index * 4, cursor, true)
      bytes.set(encoded, cursor)
      bytes[cursor + encoded.byteLength] = 0
      cursor += encoded.byteLength + 1
    }
  }

  // ---------------------------------------------------------------- args/env

  private argsSizesGet(argcPointer: number, sizePointer: number): number {
    try {
      const { view } = this.touch()
      view.setUint32(argcPointer, this.args.length, true)
      view.setUint32(sizePointer, this.stringTableSize(this.args), true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private argsGet(pointers: number, buffer: number): number {
    try {
      const { bytes, view } = this.touch()
      this.ensure(pointers, this.args.length * 4)
      this.ensure(buffer, this.stringTableSize(this.args))
      this.writeStringTable(this.args, pointers, buffer, view, bytes)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private environSizesGet(countPointer: number, sizePointer: number): number {
    try {
      const { view } = this.touch()
      view.setUint32(countPointer, this.env.length, true)
      view.setUint32(sizePointer, this.stringTableSize(this.env), true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private environGet(pointers: number, buffer: number): number {
    try {
      const { bytes, view } = this.touch()
      this.ensure(pointers, this.env.length * 4)
      this.ensure(buffer, this.stringTableSize(this.env))
      this.writeStringTable(this.env, pointers, buffer, view, bytes)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  // ---------------------------------------------------------------- clocks

  private clockResGet(clockId: number, pointer: number): number {
    try {
      const { view } = this.touch()
      view.setBigUint64(pointer, 1_000_000n, true)
      void clockId
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private clockTimeGet(clockId: number, precision: bigint, pointer: number): number {
    try {
      const { view } = this.touch()
      void precision
      const value = clockId === 0 ? BigInt(Date.now()) * 1_000_000n : this.clockNs()
      view.setBigUint64(pointer, BigInt.asUintN(64, value), true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private randomGet(pointer: number, length: number): number {
    try {
      const { bytes } = this.touch()
      this.ensure(pointer, length)
      const target = bytes.subarray(pointer, pointer + length)
      this.randomBytes(target)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private schedYield(): number {
    return WASI_ERRNO.SUCCESS
  }

  // ---------------------------------------------------------------- fd basics

  private entry(fd: number): FdEntry | undefined {
    return Number.isInteger(fd) ? this.fds[fd] : undefined
  }

  private allocate(entry: FdEntry): number {
    for (let index = 3; index < this.fds.length; index += 1) {
      if (this.fds[index] === undefined) {
        this.fds[index] = entry
        return index
      }
    }
    this.fds.push(entry)
    return this.fds.length - 1
  }

  private resolve(fd: number, path: string): { guestPath: string; hostPath: string; directory: FdEntry } {
    const directory = this.entry(fd)
    if (directory === undefined) throw new VfsProxyError('EBADF', `bad file descriptor ${fd}`)
    if (directory.kind !== 'directory') throw new VfsProxyError('ENOTDIR', 'not a directory descriptor')
    return { ...resolveGuestPath(this.preopens, directory.guestPath, path), directory }
  }

  private statOf(entry: FdEntry): VfsStat {
    if (this.isDevice(entry)) {
      return { kind: 'file', size: 0, mode: 0o666, mtimeMs: 0, ino: 0 }
    }
    if (this.controlRoot() !== undefined && entry.guestPath === this.controlRoot()) {
      return { kind: 'directory', size: 0, mode: 0o555, mtimeMs: 0, ino: 0 }
    }
    if (entry.hostPath === undefined) throw new VfsProxyError('EBADF', 'descriptor has no host path')
    return this.vfs.stat(entry.hostPath)
  }

  /** Guest root of the private control directory, when one bridge is present. */
  private controlRoot(): string | undefined {
    return this.spawn?.guestRoot ?? this.http?.guestRoot
  }

  /** The bridge that owns a guest path, if any. */
  private controlBridgeAt(guestPath: string): ControlBridge | undefined {
    if (this.spawn !== undefined && guestPath === this.spawn.guestPath) return this.spawn
    if (this.http !== undefined && guestPath === this.http.guestPath) return this.http
    return undefined
  }

  /** True when the guest path is the control root or below it. */
  private underControlRoot(guestPath: string): boolean {
    const root = this.controlRoot()
    return root !== undefined && isWithinRoot(root, guestPath)
  }

  /** True when the descriptor is a stdio/control device (fake stat, character type). */
  private isDevice(entry: FdEntry): boolean {
    return entry.kind === 'stdin' || entry.kind === 'stdout' || entry.kind === 'stderr'
      || entry.kind === 'spawn' || entry.kind === 'http'
  }

  private fileTypeOf(stat: VfsStat): number {
    if (stat.kind === 'directory') return WASI_FILETYPE.DIRECTORY
    if (stat.kind === 'symlink') return WASI_FILETYPE.SYMBOLIC_LINK
    return WASI_FILETYPE.REGULAR_FILE
  }

  private writeFilestat(view: DataView, pointer: number, stat: VfsStat, fileType: number): void {
    const mtime = BigInt(Math.trunc(stat.mtimeMs)) * 1_000_000n
    view.setBigUint64(pointer, 0n, true)
    view.setBigUint64(pointer + 8, BigInt(stat.ino), true)
    view.setUint8(pointer + 16, fileType)
    view.setBigUint64(pointer + 24, 1n, true)
    view.setBigUint64(pointer + 32, BigInt(stat.size), true)
    view.setBigUint64(pointer + 40, mtime, true)
    view.setBigUint64(pointer + 48, mtime, true)
    view.setBigUint64(pointer + 56, mtime, true)
  }

  private fdClose(fd: number): number {
    try {
      if (this.entry(fd) === undefined) return WASI_ERRNO.BADF
      this.fds[fd] = undefined
      this.controlFds.delete(fd)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdRenumber(from: number, to: number): number {
    try {
      const source = this.entry(from)
      if (source === undefined) return WASI_ERRNO.BADF
      if (from === to) return WASI_ERRNO.SUCCESS
      this.fds[to] = source
      this.fds[from] = undefined
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdFdstatGet(fd: number, pointer: number): number {
    try {
      const { view } = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      const stat = this.statOf(entry)
      const fileType = this.isDevice(entry) ? WASI_FILETYPE.CHARACTER_DEVICE : this.fileTypeOf(stat)
      view.setUint8(pointer, fileType)
      view.setUint16(pointer + 2, entry.append ? WASI_FDFLAGS.APPEND : 0, true)
      view.setBigUint64(pointer + 8, ALL_RIGHTS, true)
      view.setBigUint64(pointer + 16, ALL_RIGHTS, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdFdstatSetFlags(fd: number, flags: number): number {
    try {
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      entry.append = (flags & WASI_FDFLAGS.APPEND) !== 0
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdFdstatSetRights(fd: number, base: bigint, inheriting: bigint): number {
    void base
    void inheriting
    return this.entry(fd) === undefined ? WASI_ERRNO.BADF : WASI_ERRNO.SUCCESS
  }

  private fdFilestatGet(fd: number, pointer: number): number {
    try {
      const { view } = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      const stat = this.statOf(entry)
      const fileType = this.isDevice(entry) ? WASI_FILETYPE.CHARACTER_DEVICE : this.fileTypeOf(stat)
      this.writeFilestat(view, pointer, stat, fileType)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdFilestatSetSize(fd: number, size: bigint): number {
    try {
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      if (entry.hostPath === undefined) return WASI_ERRNO.SPIPE
      if (!Number.isSafeInteger(Number(size)) || size < 0n) return WASI_ERRNO.INVAL
      this.vfs.truncate(entry.hostPath, Number(size))
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdFilestatSetTimes(fd: number, atime: bigint, mtime: bigint, flags: number): number {
    void fd
    void atime
    void mtime
    void flags
    return WASI_ERRNO.NOSYS
  }

  private fdSeek(fd: number, offset: bigint, whence: number, newOffsetPointer: number): number {
    try {
      const { view } = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      if (entry.kind !== 'file') return WASI_ERRNO.SPIPE
      const size = BigInt(this.statOf(entry).size)
      let base: bigint
      if (whence === 0) base = 0n
      else if (whence === 1) base = BigInt(entry.offset)
      else if (whence === 2) base = size
      else return WASI_ERRNO.INVAL
      const next = base + offset
      if (next < 0n) return WASI_ERRNO.INVAL
      if (next > BigInt(Number.MAX_SAFE_INTEGER)) return WASI_ERRNO.INVAL
      entry.offset = Number(next)
      view.setBigUint64(newOffsetPointer, BigInt.asUintN(64, next), true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdTell(fd: number, pointer: number): number {
    try {
      const { view } = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      if (entry.kind !== 'file') return WASI_ERRNO.SPIPE
      view.setBigUint64(pointer, BigInt(entry.offset), true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdSync(fd: number): number {
    return this.fdDatasync(fd)
  }

  private fdDatasync(fd: number): number {
    try {
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      this.vfs.sync()
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdAdvise(fd: number, offset: bigint, length: bigint, advice: number): number {
    void offset
    void length
    void advice
    return this.entry(fd) === undefined ? WASI_ERRNO.BADF : WASI_ERRNO.SUCCESS
  }

  private fdAllocate(fd: number, offset: bigint, length: bigint): number {
    void offset
    void length
    return this.entry(fd) === undefined ? WASI_ERRNO.BADF : WASI_ERRNO.SUCCESS
  }

  // ---------------------------------------------------------------- read/write

  private gatherIoVec(args: { bytes: Uint8Array; view: DataView }, iovs: number, count: number): Uint8Array {
    const parts: Uint8Array[] = []
    let total = 0
    for (let index = 0; index < count; index += 1) {
      const base = iovs + index * 8
      const pointer = args.view.getUint32(base, true)
      const length = args.view.getUint32(base + 4, true)
      this.ensure(pointer, length)
      parts.push(args.bytes.slice(pointer, pointer + length))
      total += length
    }
    const joined = new Uint8Array(total)
    let offset = 0
    for (const part of parts) {
      joined.set(part, offset)
      offset += part.byteLength
    }
    return joined
  }

  private scatterIoVec(args: { bytes: Uint8Array; view: DataView }, iovs: number, count: number, data: Uint8Array): number {
    let cursor = 0
    for (let index = 0; index < count && cursor < data.byteLength; index += 1) {
      const base = iovs + index * 8
      const pointer = args.view.getUint32(base, true)
      const length = args.view.getUint32(base + 4, true)
      this.ensure(pointer, length)
      const chunk = data.subarray(cursor, cursor + Math.min(length, data.byteLength - cursor))
      args.bytes.set(chunk, pointer)
      cursor += chunk.byteLength
    }
    return cursor
  }

  private fdWrite(fd: number, iovs: number, iovsLength: number, writtenPointer: number): number {
    try {
      const args = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      const data = this.gatherIoVec(args, iovs, iovsLength)
      let written = 0
      if (entry.kind === 'stdout') {
        this.stdoutSink?.(data)
        written = data.byteLength
      } else if (entry.kind === 'stderr') {
        this.stderrSink?.(data)
        written = data.byteLength
      } else if (entry.kind === 'file') {
        if (!entry.writable || entry.hostPath === undefined) return WASI_ERRNO.BADF
        written = this.vfs.write(entry.hostPath, entry.offset, data, { append: entry.append, create: false })
        entry.offset = entry.append ? this.vfs.stat(entry.hostPath).size : entry.offset + written
      } else if (entry.kind === 'spawn' || entry.kind === 'http') {
        const consumed = this.writeControl(fd, data)
        if (consumed < 0) return -consumed
        written = consumed
      } else {
        return WASI_ERRNO.ISDIR
      }
      args.view.setUint32(writtenPointer, written, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdPwrite(fd: number, iovs: number, iovsLength: number, offset: bigint, writtenPointer: number): number {
    try {
      const args = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      if (entry.kind !== 'file' || !entry.writable || entry.hostPath === undefined) return WASI_ERRNO.BADF
      const data = this.gatherIoVec(args, iovs, iovsLength)
      const written = this.vfs.write(entry.hostPath, Number(offset), data, { append: entry.append, create: false })
      args.view.setUint32(writtenPointer, written, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdRead(fd: number, iovs: number, iovsLength: number, readPointer: number): number {
    try {
      const args = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      let requested = 0
      for (let index = 0; index < iovsLength; index += 1) {
        requested += args.view.getUint32(iovs + index * 8 + 4, true)
      }
      let data: Uint8Array
      if (entry.kind === 'stdin') {
        data = this.stdin.read(requested)
        this.onStdinRead?.(data.byteLength, this.stdin.totalBytes)
      } else if (entry.kind === 'file') {
        if (!entry.readable || entry.hostPath === undefined) return WASI_ERRNO.BADF
        data = this.vfs.read(entry.hostPath, entry.offset, requested)
        entry.offset += data.byteLength
      } else if (entry.kind === 'spawn' || entry.kind === 'http') {
        data = this.readControl(fd, requested)
      } else {
        return WASI_ERRNO.ISDIR
      }
      const read = this.scatterIoVec(args, iovs, iovsLength, data)
      args.view.setUint32(readPointer, read, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdPread(fd: number, iovs: number, iovsLength: number, offset: bigint, readPointer: number): number {
    try {
      const args = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      if (entry.kind !== 'file' || !entry.readable || entry.hostPath === undefined) return WASI_ERRNO.BADF
      let requested = 0
      for (let index = 0; index < iovsLength; index += 1) {
        requested += args.view.getUint32(iovs + index * 8 + 4, true)
      }
      const data = this.vfs.read(entry.hostPath, Number(offset), requested)
      const read = this.scatterIoVec(args, iovs, iovsLength, data)
      args.view.setUint32(readPointer, read, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  // ----------------------------------------------------------- control bridges

  /**
   * Accept one chunk of a framed request on a spawn/http descriptor.
   *
   * A guest may split the frame across several `fd_write` calls; the 8-byte
   * prefix declares the total so the host knows when the request is complete.
   * The dispatch runs synchronously on the guest's own thread, which is what
   * makes piped stdio possible without a preview1 process primitive.
   * @returns the consumed byte count, or a negated WASI errno.
   */
  private writeControl(fd: number, data: Uint8Array): number {
    const state = this.controlFds.get(fd)
    if (state === undefined) return -WASI_ERRNO.BADF
    const bridge = state.kind === 'spawn' ? this.spawn : this.http
    if (bridge === undefined) return -WASI_ERRNO.NOSYS
    if (state.discard) {
      // An over-limit frame is being drained. The structured limit response is
      // queued as soon as the 8-byte prefix is parsed, so a guest that wrote
      // the whole frame in one call can read it immediately. This branch only
      // consumes the remaining declared bytes without buffering them.
      state.length += data.byteLength
      if (state.expected !== undefined && state.length >= state.expected) {
        state.length = 0
        state.expected = undefined
        state.chunks.length = 0
        state.discard = false
      }
      return data.byteLength
    }
    if (state.response !== undefined && state.offset < state.response.byteLength) {
      return -WASI_ERRNO.INVAL
    }
    if (state.response !== undefined) {
      // The previous response was fully read: this descriptor carries the next
      // request, so its buffers start empty again.
      state.response = undefined
      state.offset = 0
      state.chunks.length = 0
      state.length = 0
      state.expected = undefined
    }
    state.chunks.push(data.slice())
    state.length += data.byteLength
    if (state.expected === undefined && state.length >= SPAWN_FRAME_PREFIX_BYTES) {
      const joined = concatChunks(state.chunks, SPAWN_FRAME_PREFIX_BYTES)
      const view = new DataView(joined.buffer, joined.byteOffset, joined.byteLength)
      const headerLength = view.getUint32(0, true)
      const payloadLength = view.getUint32(4, true)
      const expected = SPAWN_FRAME_PREFIX_BYTES + headerLength + payloadLength
      if (expected > (state.kind === 'http' ? MAX_HTTP_REQUEST_FRAME_BYTES : MAX_SPAWN_FRAME_BYTES)) {
        if (state.kind === 'spawn') return -WASI_ERRNO.NOMEM
        // Queue the structured failure as soon as the prefix is known instead
        // of waiting for a body that may never arrive (or may be gigabytes).
        // `state.length` already includes every buffered chunk, including the
        // one that completed the prefix; the discard branch counts from there.
        state.expected = expected
        state.response = encodeHttpFailure(
          'limit',
          `http request frame is ${expected} bytes; the limit is ${MAX_HTTP_REQUEST_FRAME_BYTES}`,
        )
        state.offset = 0
        state.chunks.length = 0
        if (state.length >= expected) {
          // The whole over-limit frame arrived in this one `fd_write`.
          state.length = 0
          state.expected = undefined
        } else {
          state.discard = true
        }
        return data.byteLength
      }
      state.expected = expected
    }
    if (state.expected !== undefined && state.length > state.expected) return -WASI_ERRNO.INVAL
    if (state.expected !== undefined && state.length === state.expected) {
      state.response = bridge.dispatch(concatChunks(state.chunks, state.length))
      state.offset = 0
      state.chunks.length = 0
      state.length = 0
      state.expected = undefined
    }
    return data.byteLength
  }

  /**
   * Serve one chunk of the response frame; a fully consumed response reads as
   * EOF, which is what the shim's exact-length reader expects.
   */
  private readControl(fd: number, requested: number): Uint8Array {
    const state = this.controlFds.get(fd)
    if (state === undefined) throw new VfsProxyError('EBADF', 'bad control descriptor')
    const response = state.response
    if (response === undefined) return new Uint8Array(0)
    const remaining = response.byteLength - state.offset
    if (remaining <= 0) return new Uint8Array(0)
    const length = Math.min(requested, remaining)
    const chunk = response.slice(state.offset, state.offset + length)
    state.offset += length
    return chunk
  }

  // ---------------------------------------------------------------- directories

  private fdPrestatGet(fd: number, pointer: number): number {
    try {
      const { view } = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined || !entry.preopen || entry.guestPath === undefined) return WASI_ERRNO.BADF
      view.setUint8(pointer, 0)
      view.setUint32(pointer + 4, encoder.encode(entry.guestPath).byteLength, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdPrestatDirName(fd: number, pathPointer: number, pathLength: number): number {
    try {
      const entry = this.entry(fd)
      if (entry === undefined || !entry.preopen || entry.guestPath === undefined) return WASI_ERRNO.BADF
      const encoded = encoder.encode(entry.guestPath)
      if (pathLength < encoded.byteLength) return WASI_ERRNO.NAMETOOLONG
      const { bytes } = this.touch()
      this.ensure(pathPointer, pathLength)
      bytes.set(encoded, pathPointer)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private fdReaddir(fd: number, buffer: number, bufferLength: number, cookie: bigint, usedPointer: number): number {
    try {
      const args = this.touch()
      const entry = this.entry(fd)
      if (entry === undefined) return WASI_ERRNO.BADF
      if (entry.kind !== 'directory' || entry.hostPath === undefined) return WASI_ERRNO.NOTDIR
      this.ensure(buffer, bufferLength)
      let entries: readonly VfsDirEntry[]
      const root = this.controlRoot()
      if (root !== undefined && entry.guestPath === root) {
        // The private control directory exists only in this host; it is never
        // read from the VFS, which has no such root. Both descriptors are
        // advertised when both bridges are installed.
        entries = [
          ...(this.spawn === undefined ? [] : [{ name: 'spawn', kind: 'file' as const, ino: 0 }]),
          ...(this.http === undefined ? [] : [{ name: 'http', kind: 'file' as const, ino: 0 }]),
        ]
      } else {
        try {
          entries = this.vfs.readdir(entry.hostPath)
        } catch (error) {
          if (errorCodeOf(error) === 'EISDIR') entries = []
          else throw error
        }
      }
      let used = 0
      let index = Number(cookie)
      while (index < entries.length) {
        const item = entries[index]!
        const name = encoder.encode(item.name)
        const remaining = bufferLength - used
        if (remaining < 24) break
        const base = buffer + used
        args.view.setBigUint64(base, BigInt(index + 1), true)
        args.view.setBigUint64(base + 8, BigInt(item.ino), true)
        args.view.setUint32(base + 16, name.byteLength, true)
        args.view.setUint8(base + 20, item.kind === 'directory'
          ? WASI_FILETYPE.DIRECTORY
          : item.kind === 'symlink' ? WASI_FILETYPE.SYMBOLIC_LINK : WASI_FILETYPE.REGULAR_FILE)
        const copy = Math.min(name.byteLength, remaining - 24)
        args.bytes.set(name.subarray(0, copy), base + 24)
        if (copy < name.byteLength) {
          used = bufferLength
          break
        }
        used += 24 + name.byteLength
        index += 1
      }
      args.view.setUint32(usedPointer, used, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  // ---------------------------------------------------------------- paths

  private pathOpen(
    fd: number,
    dirflags: number,
    pathPointer: number,
    pathLength: number,
    oflags: number,
    rightsBase: bigint,
    rightsInheriting: bigint,
    fdflags: number,
    openedFdPointer: number,
  ): number {
    try {
      void dirflags
      void rightsInheriting
      const { view } = this.touch()
      const path = this.readString(pathPointer, pathLength)
      const resolved = this.resolve(fd, path)
      const directory = (oflags & WASI_OFLAGS.DIRECTORY) !== 0
      const create = (oflags & WASI_OFLAGS.CREAT) !== 0
      const truncate = (oflags & WASI_OFLAGS.TRUNC) !== 0
      const exclusive = (oflags & WASI_OFLAGS.EXCL) !== 0
      const controlRoot = this.controlRoot()
      if (controlRoot !== undefined && resolved.guestPath === controlRoot) {
        // Opening the private directory itself (wasi-libc's opendir does) is a
        // normal directory descriptor; its entries are served by fd_readdir.
        if (!directory) return WASI_ERRNO.ISDIR
        const opened = this.allocate({
          kind: 'directory',
          guestPath: resolved.guestPath,
          hostPath: resolved.hostPath,
          offset: 0,
          append: false,
          readable: true,
          writable: false,
          preopen: false,
        })
        view.setUint32(openedFdPointer, opened, true)
        return WASI_ERRNO.SUCCESS
      }
      const bridge = this.controlBridgeAt(resolved.guestPath)
      if (bridge !== undefined) {
        if (directory || create || truncate || exclusive) return WASI_ERRNO.INVAL
        const kind = bridge === this.spawn ? 'spawn' : 'http'
        const opened = this.allocate({
          kind,
          guestPath: resolved.guestPath,
          offset: 0,
          append: false,
          readable: true,
          writable: true,
          preopen: false,
        })
        this.controlFds.set(opened, { kind, chunks: [], length: 0, discard: false, offset: 0 })
        view.setUint32(openedFdPointer, opened, true)
        return WASI_ERRNO.SUCCESS
      }
      if (this.underControlRoot(resolved.guestPath)) return WASI_ERRNO.NOENT
      if (directory) {
        const stat = this.vfs.open(resolved.hostPath, { create: false, truncate: false, exclusive: false, directory: true })
        const opened = this.allocate({
          kind: 'directory',
          guestPath: resolved.guestPath,
          hostPath: resolved.hostPath,
          offset: 0,
          append: false,
          readable: true,
          writable: false,
          preopen: false,
        })
        view.setUint32(openedFdPointer, opened, true)
        void stat
        return WASI_ERRNO.SUCCESS
      }
      const wantsRead = (rightsBase & WASI_RIGHTS.FD_READ) !== 0n
      const wantsWrite = (rightsBase & WASI_RIGHTS.FD_WRITE) !== 0n
      const readable = wantsRead || !wantsWrite
      const writable = wantsWrite || create || truncate
      this.vfs.open(resolved.hostPath, { create, truncate, exclusive, directory: false, mode: 0o644 })
      const opened = this.allocate({
        kind: 'file',
        guestPath: resolved.guestPath,
        hostPath: resolved.hostPath,
        offset: 0,
        append: (fdflags & WASI_FDFLAGS.APPEND) !== 0,
        readable,
        writable,
        preopen: false,
      })
      view.setUint32(openedFdPointer, opened, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private pathFilestatGet(fd: number, flags: number, pathPointer: number, pathLength: number, statPointer: number): number {
    try {
      void flags
      const { view } = this.touch()
      const path = this.readString(pathPointer, pathLength)
      const resolved = this.resolve(fd, path)
      if (this.controlBridgeAt(resolved.guestPath) !== undefined) {
        this.writeFilestat(
          view,
          statPointer,
          { kind: 'file', size: 0, mode: 0o666, mtimeMs: 0, ino: 0 },
          WASI_FILETYPE.CHARACTER_DEVICE,
        )
        return WASI_ERRNO.SUCCESS
      }
      const controlRoot = this.controlRoot()
      if (controlRoot !== undefined && resolved.guestPath === controlRoot) {
        this.writeFilestat(
          view,
          statPointer,
          { kind: 'directory', size: 0, mode: 0o555, mtimeMs: 0, ino: 0 },
          WASI_FILETYPE.DIRECTORY,
        )
        return WASI_ERRNO.SUCCESS
      }
      if (this.underControlRoot(resolved.guestPath)) return WASI_ERRNO.NOENT
      const stat = this.vfs.stat(resolved.hostPath)
      this.writeFilestat(view, statPointer, stat, this.fileTypeOf(stat))
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private pathFilestatSetTimes(
    fd: number,
    flags: number,
    pathPointer: number,
    pathLength: number,
    atime: bigint,
    mtime: bigint,
    fstflags: number,
  ): number {
    void fd
    void flags
    void pathPointer
    void pathLength
    void atime
    void mtime
    void fstflags
    return WASI_ERRNO.NOSYS
  }

  private pathCreateDirectory(fd: number, pathPointer: number, pathLength: number): number {
    try {
      const path = this.readString(pathPointer, pathLength)
      const resolved = this.resolve(fd, path)
      if (this.underControlRoot(resolved.guestPath)) return WASI_ERRNO.ROFS
      this.vfs.mkdir(resolved.hostPath, 0o755)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private pathRemoveDirectory(fd: number, pathPointer: number, pathLength: number): number {
    try {
      const path = this.readString(pathPointer, pathLength)
      const resolved = this.resolve(fd, path)
      if (this.underControlRoot(resolved.guestPath)) return WASI_ERRNO.ROFS
      // POSIX `rmdir` semantics belong to the VFS face: empty only, ENOTEMPTY
      // otherwise, ENOTDIR for a file. `rmdir` is the explicit seam; the
      // `unlink(..., {directory:true})` fallback keeps older hosts working
      // (G2-FIX-47: the production face's directory removal used to answer EIO).
      const rmdir = this.vfs.rmdir
      if (typeof rmdir === 'function') rmdir.call(this.vfs, resolved.hostPath)
      else this.vfs.unlink(resolved.hostPath, { directory: true })
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private pathUnlinkFile(fd: number, pathPointer: number, pathLength: number): number {
    try {
      const path = this.readString(pathPointer, pathLength)
      const resolved = this.resolve(fd, path)
      if (this.underControlRoot(resolved.guestPath)) return WASI_ERRNO.ROFS
      this.vfs.unlink(resolved.hostPath, { directory: false })
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private pathRename(
    oldFd: number,
    oldPathPointer: number,
    oldPathLength: number,
    newFd: number,
    newPathPointer: number,
    newPathLength: number,
  ): number {
    try {
      const oldPath = this.readString(oldPathPointer, oldPathLength)
      const newPath = this.readString(newPathPointer, newPathLength)
      const from = this.resolve(oldFd, oldPath)
      const to = this.resolve(newFd, newPath)
      if (this.underControlRoot(from.guestPath) || this.underControlRoot(to.guestPath)) return WASI_ERRNO.ROFS
      this.vfs.rename(from.hostPath, to.hostPath)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private unsupported(): number {
    return WASI_ERRNO.NOSYS
  }

  // ---------------------------------------------------------------- poll/exit

  private pollOneoff(inputPointer: number, outputPointer: number, subscriptions: number, eventsPointer: number): number {
    try {
      if (subscriptions === 0) return WASI_ERRNO.INVAL
      const { bytes, view } = this.touch()
      this.ensure(inputPointer, subscriptions * 48)
      this.ensure(outputPointer, subscriptions * 32)
      let events = 0
      for (let index = 0; index < subscriptions; index += 1) {
        const base = inputPointer + index * 48
        const userdata = view.getBigUint64(base, true)
        const tag = view.getUint8(base + 8)
        if (tag !== 0) return WASI_ERRNO.NOSYS
        const timeout = view.getBigUint64(base + 24, true)
        const flags = view.getUint16(base + 40, true)
        const now = this.clockNs()
        const deadline = (flags & 1) !== 0 ? timeout : now + timeout
        const wait = deadline > now ? Number(deadline - now) / 1_000_000 : 0
        if (wait > 0) this.sleep(Math.min(wait, 60_000))
        const event = outputPointer + events * 32
        bytes.fill(0, event, event + 32)
        view.setBigUint64(event, userdata, true)
        view.setUint16(event + 8, 0, true)
        view.setUint8(event + 10, 0)
        events += 1
      }
      view.setUint32(eventsPointer, events, true)
      return WASI_ERRNO.SUCCESS
    } catch (error) {
      return this.fail(error)
    }
  }

  private procExit(code: number): number {
    throw new WasiProcExit(code >>> 0)
  }
}

/** Join the buffered spawn-frame chunks, optionally reading only the prefix. */
function concatChunks(chunks: readonly Uint8Array[], limit?: number): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0)
  const length = limit === undefined ? total : Math.min(limit, total)
  const joined = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    if (offset >= length) break
    const part = chunk.subarray(0, Math.min(chunk.byteLength, length - offset))
    joined.set(part, offset)
    offset += part.byteLength
  }
  return joined
}

function defaultRandomBytes(target: Uint8Array): void {
  const crypto = (globalThis as { crypto?: { getRandomValues?: (array: Uint8Array) => Uint8Array } }).crypto
  if (crypto?.getRandomValues !== undefined) {
    crypto.getRandomValues(target)
    return
  }
  for (let index = 0; index < target.byteLength; index += 1) {
    target[index] = Math.floor(Math.random() * 256)
  }
}

function defaultSleep(milliseconds: number): void {
  if (milliseconds <= 0) return
  if (typeof SharedArrayBuffer === 'function' && typeof Atomics.wait === 'function') {
    try {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds)
      return
    } catch {
      // Atomics.wait is forbidden on a browser main thread; fall through.
    }
  }
  const end = Date.now() + milliseconds
  while (Date.now() < end) {
    // Busy wait is the only synchronous option without SAB.
  }
}
