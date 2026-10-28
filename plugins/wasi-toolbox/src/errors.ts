// SPDX-License-Identifier: MIT
/**
 * Errors crossing the WASI toolbox surfaces. VFS failures carry the errno-style
 * code strings of `node:fs` so the WASI host can translate them; the memory
 * ceiling and traps are distinct classes because the hot-instance runner maps
 * them to fixed exit codes instead of an errno.
 * @module @phone-dsh/dsh-wasi-toolbox/errors
 */

/** Error codes the proxy and the WASI host agree on. */
export type VfsErrorCode =
  | 'EACCES'
  | 'EBADF'
  | 'EEXIST'
  | 'EFBIG'
  | 'EINVAL'
  | 'EIO'
  | 'EISDIR'
  | 'EMFILE'
  | 'ENAMETOOLONG'
  | 'ENOENT'
  | 'ENOMEM'
  | 'ENOSPC'
  | 'ENOSYS'
  | 'ENOTCAPABLE'
  | 'ENOTDIR'
  | 'ENOTEMPTY'
  | 'EPERM'
  | 'EROFS'
  | 'ETIMEDOUT'

/** Base class so callers can catch every toolbox failure at one point. */
export class WasiToolboxError extends Error {
  override readonly name: string = 'WasiToolboxError'
}

/** A VFS operation failed; `code` is returned to the guest as a WASI errno. */
export class VfsProxyError extends WasiToolboxError {
  override name: string = 'VfsProxyError'
  readonly code: string
  readonly path: string | undefined

  constructor(code: string, message: string, path?: string) {
    super(path === undefined ? `${code}: ${message}` : `${code}: ${message} (${path})`)
    this.code = code
    this.path = path
  }
}

/** The guest asked for a path outside its preopened directories. */
export class VfsCapabilityError extends VfsProxyError {
  override readonly name = 'VfsCapabilityError'

  constructor(message: string, path?: string) {
    super('ENOTCAPABLE', message, path)
  }
}

/** An instance tried to exceed the per-hot-instance memory ceiling. */
export class WasiMemoryCeilingError extends WasiToolboxError {
  override readonly name = 'WasiMemoryCeilingError'
  readonly limitBytes: number
  readonly observedBytes: number

  constructor(limitBytes: number, observedBytes: number) {
    super(`WASI instance memory ${observedBytes} exceeds the ${limitBytes} byte ceiling`)
    this.limitBytes = limitBytes
    this.observedBytes = observedBytes
  }
}

/** `proc_exit` unwinds through the wasm frames as this throwable. */
export class WasiProcExit extends Error {
  override readonly name = 'WasiProcExit'
  readonly code: number

  constructor(code: number) {
    super(`proc_exit(${code})`)
    this.code = code
  }
}

/** The module cannot run on this host (missing `_start`, missing memory, ...). */
export class WasiTrapError extends WasiToolboxError {
  override readonly name = 'WasiTrapError'
}

/** Filesystem syscalls need the SAB channel, which is absent without COI. */
export class WasiVfsUnavailableError extends VfsProxyError {
  override readonly name = 'WasiVfsUnavailableError'

  constructor(reason = 'WASI filesystem access requires a synchronous VFS channel') {
    super('ENOTCAPABLE', reason)
  }
}

/**
 * Map a `node:fs` error code onto the errno-style spelling the proxy protocol
 * carries. The Worker's in-memory VFS answers a non-recursive `rm` of a
 * directory with `ERR_FS_EISDIR`; without this translation that refusal would
 * reach the guest as EIO instead of EISDIR (G2-FIX-47).
 * @param code - code taken from a foreign error.
 * @returns the errno spelling, or the input code when it is already one.
 */
export function normalizeErrorCode(code: string): string {
  return code === 'ERR_FS_EISDIR' ? 'EISDIR' : code
}

/** Normalise an unknown thrown value into a `VfsProxyError`. */
export function toVfsProxyError(error: unknown, fallback: VfsErrorCode = 'EIO', path?: string): VfsProxyError {
  if (error instanceof VfsProxyError) return error
  if (error instanceof Error) {
    const raw = (error as Error & { code?: unknown }).code
    if (typeof raw === 'string') {
      const code = normalizeErrorCode(raw)
      if (/^E[A-Z]+$/.test(code)) return new VfsProxyError(code, error.message, path)
    }
    return new VfsProxyError(fallback, error.message, path)
  }
  return new VfsProxyError(fallback, String(error), path)
}

/** Read the errno-style code of a possibly foreign error object. */
export function errorCodeOf(error: unknown): string | undefined {
  if (error instanceof VfsProxyError) return error.code
  if (error instanceof Error) {
    const raw = (error as Error & { code?: unknown }).code
    if (typeof raw === 'string') return normalizeErrorCode(raw)
    if (error instanceof WasiMemoryCeilingError) return 'ENOMEM'
  }
  return undefined
}
