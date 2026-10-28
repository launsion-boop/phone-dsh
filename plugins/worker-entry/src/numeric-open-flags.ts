// SPDX-License-Identifier: MIT
/**
 * Numeric `open(2)` flags at the Worker runtime's `node:fs` bridge.
 *
 * Node accepts both open-flag spellings: the string form (`'r'`, `'wx'`, `'a+'`)
 * and the numeric bit mask built from `fs.constants` (`O_CREAT | O_EXCL |
 * O_WRONLY`). The pinned webworker runtime implements only the string form
 * (`MemoryVfs.openFileSync` parses `flags[0]` and `flags.slice(1)`), and its
 * virtual `fs.constants` table omits `O_EXCL`. DSH's attachment-local store
 * uses exactly the numeric form to stage an immutable object:
 *
 * ```ts
 * await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600)
 * ```
 *
 * With the pinned runtime that expression becomes `NaN` (missing `O_EXCL`) and
 * the promise face hands the number to `openHandleSync`, whose string parser
 * throws a `TypeError`. The store folds the refusal into
 * `ATTACHMENT_WRITE_FAILED`, so a valid image can never be persisted even
 * though the same bytes decode and normalize correctly.
 *
 * This is the phone layer's adapter, not a DSH patch: it adds the missing
 * `O_EXCL` capability to the runtime's own virtual constants table and wraps
 * the mounted VFS's two open entry points so a numeric mask is interpreted
 * against **that same virtual table** (never the Mac/WK host's `fs.constants`,
 * whose values differ). The promise face (`fs/promises.open`), the sync face
 * (`fs.openSync`) and the callback face all reach the wrapped
 * `openFileSync`/`open`, so they share one semantic implementation.
 *
 * Supported masks are `O_RDONLY`/`O_WRONLY`/`O_RDWR` plus `O_CREAT`, `O_EXCL`,
 * `O_TRUNC` and `O_APPEND`, the set the runtime's string parser can express.
 * Anything else (or a contradictory combination such as `O_EXCL` without
 * `O_CREAT`) is refused with `ERR_INVALID_ARG_VALUE` rather than silently
 * dropping a bit. The adapter delegates to the runtime's own VFS methods for
 * the actual bytes and durability: `write`/`append`/`truncate`/`sync` keep
 * their real `VfsMutation` and `flush()` path, so no fsync success is faked.
 *
 * Two numeric shapes cannot be expressed by one runtime string and are
 * completed with the VFS's own primitives:
 *
 * - `O_CREAT` without `O_TRUNC`/`O_APPEND` (create-if-absent, keep existing):
 *   create an empty entry with the requested mode first, then open `'r'`/`'r+'`;
 * - `O_TRUNC | O_APPEND` (truncate then append): truncate first, then open `'a'`.
 *
 * The target `O_CREAT | O_EXCL | O_WRONLY` is one atomic runtime `'wx'` open,
 * so a second name is the runtime's own `EEXIST`; no pre-create race is added.
 * @module @phone-dsh/dsh-worker-entry/numeric-open-flags
 */

/** Numeric open bits as the Worker runtime's virtual `node:fs` defines them. */
export interface OpenFlagConstants {
  readonly O_RDONLY?: number
  readonly O_WRONLY?: number
  readonly O_RDWR?: number
  readonly O_CREAT?: number
  readonly O_EXCL?: number
  readonly O_TRUNC?: number
  readonly O_APPEND?: number
}

/**
 * The virtual values already present in the pinned runtime's `fs.constants`.
 * `O_EXCL` is the one missing capability this adapter supplies; it uses the
 * runtime's virtual (Node/POSIX) numbering, not the host's.
 */
export const VIRTUAL_OPEN_FLAGS: Required<OpenFlagConstants> = Object.freeze({
  O_RDONLY: 0,
  O_WRONLY: 1,
  O_RDWR: 2,
  O_CREAT: 64,
  O_EXCL: 128,
  O_TRUNC: 512,
  O_APPEND: 1024,
})

/** Constants the VFS wrapper maps numeric flags against. */
let activeConstants: OpenFlagConstants = VIRTUAL_OPEN_FLAGS

/** Return one virtual constant, falling back to the runtime-known value. */
function constantOf(constants: OpenFlagConstants, name: keyof OpenFlagConstants): number {
  const value = constants[name]
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
    ? value
    : VIRTUAL_OPEN_FLAGS[name]
}

/** A complete virtual constants table for one numeric-open decision. */
function resolveConstants(constants?: OpenFlagConstants): Required<OpenFlagConstants> {
  const source = constants ?? activeConstants
  return {
    O_RDONLY: constantOf(source, 'O_RDONLY'),
    O_WRONLY: constantOf(source, 'O_WRONLY'),
    O_RDWR: constantOf(source, 'O_RDWR'),
    O_CREAT: constantOf(source, 'O_CREAT'),
    O_EXCL: constantOf(source, 'O_EXCL'),
    O_TRUNC: constantOf(source, 'O_TRUNC'),
    O_APPEND: constantOf(source, 'O_APPEND'),
  }
}

/** Invalid or unsupported numeric flag mask, in Node's own error shape. */
function invalidFlags(flags: unknown, detail: string): TypeError & { code: string } {
  const error = new TypeError(
    `The argument 'flags' is invalid. Received ${typeof flags === 'number' ? String(flags) : JSON.stringify(flags)}: ${detail}`,
  ) as TypeError & { code: string }
  error.code = 'ERR_INVALID_ARG_VALUE'
  return error
}

/** Node-shaped VFS error (`code`/`syscall`/`path`). */
function fsError(
  code: string,
  syscall: string,
  path: string,
  message = `${code}: ${syscall} '${path}'`,
): Error & { code: string; syscall: string; path: string } {
  const error = new Error(message) as Error & { code: string; syscall: string; path: string }
  error.code = code
  error.syscall = syscall
  error.path = path
  return error
}

/** One open request resolved from a numeric mask. */
export interface NumericOpenPlan {
  /** String flags handed to the runtime's own parser. */
  readonly stringFlags: string
  readonly readable: boolean
  readonly writable: boolean
  readonly append: boolean
  readonly create: boolean
  readonly exclusive: boolean
  readonly truncate: boolean
  /** Create an absent entry before opening `'r'`/`'r+'`. */
  readonly preCreate: boolean
  /** Truncate before opening `'a'`/`'a+'`. */
  readonly preTruncate: boolean
  /** A no-create open whose base string would otherwise create. */
  readonly requireExisting: boolean
}

/**
 * Resolve one numeric mask against a virtual constants table.
 * @param flags - numeric open mask.
 * @param constants - virtual table; defaults to the installed runtime table.
 * @returns the runtime string flags plus the semantics the string loses.
 * @throws {TypeError} `ERR_INVALID_ARG_VALUE` for an unknown bit or combination.
 */
export function resolveNumericOpenFlags(
  flags: number,
  constants?: OpenFlagConstants,
): NumericOpenPlan {
  const table = resolveConstants(constants)
  if (!Number.isSafeInteger(flags) || flags < 0) throw invalidFlags(flags, 'expected a non-negative safe integer')
  const accessMask = table.O_WRONLY | table.O_RDWR
  const knownMask = accessMask | table.O_CREAT | table.O_EXCL | table.O_TRUNC | table.O_APPEND
  if ((flags & ~knownMask) !== 0) throw invalidFlags(flags, 'unsupported numeric open bit')
  const access = flags & accessMask
  if (access !== table.O_RDONLY && access !== table.O_WRONLY && access !== table.O_RDWR) {
    throw invalidFlags(flags, 'unsupported access mode')
  }
  const readable = access !== table.O_WRONLY
  const writable = access !== table.O_RDONLY
  const create = (flags & table.O_CREAT) !== 0
  const exclusive = (flags & table.O_EXCL) !== 0
  const truncate = (flags & table.O_TRUNC) !== 0
  const append = (flags & table.O_APPEND) !== 0
  if (exclusive && !create) throw invalidFlags(flags, 'O_EXCL requires O_CREAT')
  if (exclusive && access === table.O_RDONLY) {
    throw invalidFlags(flags, 'O_EXCL with O_RDONLY has no atomic runtime representation')
  }
  if (truncate && !writable) throw invalidFlags(flags, 'O_TRUNC requires a writable access mode')
  if (append && !writable) throw invalidFlags(flags, 'O_APPEND requires a writable access mode')

  let base: 'r' | 'w' | 'a'
  if (append) base = 'a'
  else if (truncate) base = 'w'
  else if (exclusive) base = 'w'
  else base = 'r'
  // O_CREAT without truncation/append cannot be the runtime's 'w' (it would
  // truncate an existing file); create-if-absent first and then use 'r'/'r+'.
  const preCreate = create && !exclusive && !append && !truncate
  // The runtime's 'a' never truncates, so a requested O_TRUNC is applied first.
  const preTruncate = truncate && append && !exclusive
  // The runtime's 'r' is read-only; a write-only create-if-absent open needs
  // 'r+' and the returned handle masks the extra read capability.
  const plus = access === table.O_RDWR || (base === 'r' && writable) ? '+' : ''
  const x = exclusive ? 'x' : ''
  return {
    stringFlags: `${base}${x}${plus}`,
    readable,
    writable,
    append,
    create,
    exclusive,
    truncate,
    preCreate,
    preTruncate,
    requireExisting: !create && (append || truncate),
  }
}

/** The synchronous VFS surface the adapter's preconditions need. */
interface NumericVfsSource {
  existsSync?(path: string): boolean
  writeFileSync?(path: string, data: string | Uint8Array, options?: { readonly mode?: number }): void
  truncateSync?(path: string, length?: number): void
}

/** Structural open-file handle returned by the runtime VFS. */
interface OpenFileLike {
  readonly readable: boolean
  readonly writable: boolean
  readonly append: boolean
  read(position: number, length: number): Uint8Array
  write(position: number, data: Uint8Array): number
  truncate(length: number): void
  chmod(mode: number): void
  stat(): unknown
  statBigInt(): unknown
}

/** Structural promise file handle returned by the runtime VFS. */
interface FileHandleLike {
  readonly fd: number
  readFile(options?: unknown): Promise<unknown>
  writeFile(data: string | Uint8Array, encoding?: string): Promise<void>
  write(data: string | Uint8Array): Promise<{ bytesWritten: number }>
  read(buffer: Uint8Array, offset?: number, length?: number, position?: number | null): Promise<{
    bytesRead: number
    buffer: Uint8Array
  }>
  chmod(mode: number | string): Promise<void>
  stat(options?: unknown): Promise<unknown>
  truncate(length?: number): Promise<void>
  sync(): Promise<void>
  datasync(): Promise<void>
  close(): Promise<void>
}

/** Function shape shared by the two VFS open methods. */
type OpenFunction = (this: NumericVfsSource, path: string, flags?: string | number, mode?: number) => unknown

/** Apply the preconditions the runtime string flags cannot express. */
function prepareNumericOpen(
  source: NumericVfsSource,
  plan: NumericOpenPlan,
  path: string,
  mode: number | undefined,
): void {
  const exists = typeof source.existsSync === 'function' ? source.existsSync(path) : undefined
  if (plan.requireExisting && exists !== true) {
    if (exists === false) throw fsError('ENOENT', 'open', path)
    throw fsError('ERR_FEATURE_UNAVAILABLE_ON_PLATFORM', 'open', path, 'numeric no-create open needs the VFS existsSync face')
  }
  if (plan.preCreate && exists === undefined) {
    throw fsError('ERR_FEATURE_UNAVAILABLE_ON_PLATFORM', 'open', path, 'numeric O_CREAT without O_TRUNC needs the VFS existsSync face')
  }
  if (plan.preCreate && exists !== true) {
    if (typeof source.writeFileSync !== 'function') {
      throw fsError('ERR_FEATURE_UNAVAILABLE_ON_PLATFORM', 'open', path, 'numeric O_CREAT without O_TRUNC needs the VFS writeFileSync face')
    }
    source.writeFileSync(path, new Uint8Array(0), mode === undefined ? {} : { mode })
  }
  if (plan.preTruncate) {
    if (exists === false) return
    if (typeof source.truncateSync !== 'function') {
      throw fsError('ERR_FEATURE_UNAVAILABLE_ON_PLATFORM', 'open', path, 'numeric O_TRUNC|O_APPEND needs the VFS truncateSync face')
    }
    source.truncateSync(path, 0)
  }
}

/**
 * Enforce the access mode when the runtime string is wider than the mask.
 *
 * The only wider case in {@link resolveNumericOpenFlags} is a write-only
 * create-if-absent open, which the runtime can express only as `'r+'`. Block
 * the extra read capability without replacing the VFS write/truncate path.
 */
function maskOpenFile(handle: OpenFileLike, plan: NumericOpenPlan, path: string): OpenFileLike {
  if (handle.readable === plan.readable) return handle
  return {
    ...handle,
    readable: plan.readable,
    read: (position, length) => {
      if (!plan.readable) throw fsError('EBADF', 'read', path)
      return handle.read(position, length)
    },
  }
}

/** Enforce the read capability on the promise file handle when `'r+'` is wider. */
function maskFileHandle(handle: FileHandleLike, plan: NumericOpenPlan, path: string): FileHandleLike {
  if (plan.readable) return handle
  return {
    ...handle,
    readFile: async (options?: unknown) => {
      if (!plan.readable) throw fsError('EBADF', 'read', path)
      return handle.readFile(options)
    },
    read: async (buffer, offset, length, position) => {
      if (!plan.readable) throw fsError('EBADF', 'read', path)
      return handle.read(buffer, offset, length, position)
    },
  }
}

/**
 * Wrap one mounted VFS so its sync and promise open faces accept numeric flags.
 *
 * The wrapper mutates only the live VFS object supplied by the runtime host; it
 * never touches the host process's `node:fs`, and every byte still travels
 * through the runtime's own `write`/`truncate`/`sync` methods (and therefore
 * its mutation sink and `flush()`).
 * @param source - runtime VFS mounted by the host.
 * @param constants - virtual constants table; defaults to the installed table.
 * @returns a disposer restoring the original methods.
 */
export function installNumericOpenHandlers<T extends object>(
  source: T,
  constants?: OpenFlagConstants,
): () => void {
  const target = source as unknown as NumericVfsSource & {
    openFileSync?: OpenFunction
    open?: OpenFunction
  }
  const originalOpenFileSync = target.openFileSync
  const originalOpen = target.open
  const table = constants ?? activeConstants

  let wrappedOpenFileSync: OpenFunction | undefined
  if (typeof originalOpenFileSync === 'function') {
    wrappedOpenFileSync = function numericOpenFileSync(
      this: NumericVfsSource,
      path: string,
      flags: string | number = 'r',
      mode?: number,
    ): unknown {
      if (typeof flags !== 'number') return originalOpenFileSync.call(this, path, flags, mode)
      const plan = resolveNumericOpenFlags(flags, table)
      prepareNumericOpen(this, plan, path, mode)
      const handle = originalOpenFileSync.call(this, path, plan.stringFlags, mode) as OpenFileLike
      return maskOpenFile(handle, plan, path)
    }
    target.openFileSync = wrappedOpenFileSync
  }

  let wrappedOpen: OpenFunction | undefined
  if (typeof originalOpen === 'function') {
    wrappedOpen = function numericOpen(
      this: NumericVfsSource,
      path: string,
      flags: string | number = 'r',
      mode?: number,
    ): unknown {
      if (typeof flags !== 'number') return originalOpen.call(this, path, flags, mode)
      const plan = resolveNumericOpenFlags(flags, table)
      prepareNumericOpen(this, plan, path, mode)
      const opened = originalOpen.call(this, path, plan.stringFlags, mode)
      if (typeof (opened as Promise<unknown>)?.then !== 'function') {
        return maskOpenFile(opened as OpenFileLike, plan, path)
      }
      return (opened as Promise<FileHandleLike>).then(handle => maskFileHandle(handle, plan, path))
    }
    target.open = wrappedOpen
  }

  return () => {
    if (wrappedOpenFileSync !== undefined && target.openFileSync === wrappedOpenFileSync) {
      target.openFileSync = originalOpenFileSync
    }
    if (wrappedOpen !== undefined && target.open === wrappedOpen) target.open = originalOpen
  }
}

/**
 * Install the virtual constants the numeric adapter maps against.
 *
 * Adds the pinned runtime's missing `O_EXCL` to its own `fs.constants` object so
 * DSH's `constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY` evaluates
 * to a real mask instead of `NaN`. The existing virtual values are never
 * replaced with host values.
 * @param fsModule - the runtime's `node:fs` module face (its `constants` object).
 * @returns a disposer removing only the property this call added.
 */
export function installNumericOpenFlags(fsModule: { readonly constants?: Record<string, unknown> }): () => void {
  const constants = fsModule.constants
  if (constants === undefined || constants === null) {
    throw new TypeError('worker entry: numeric open flags need the runtime fs.constants table')
  }
  const hadExclusive = Object.prototype.hasOwnProperty.call(constants, 'O_EXCL')
  const previous = constants['O_EXCL']
  if (typeof previous !== 'number') constants['O_EXCL'] = VIRTUAL_OPEN_FLAGS.O_EXCL
  activeConstants = constants as OpenFlagConstants
  return () => {
    if (hadExclusive) constants['O_EXCL'] = previous
    else delete constants['O_EXCL']
    if (activeConstants === constants) activeConstants = VIRTUAL_OPEN_FLAGS
  }
}
