// SPDX-License-Identifier: MIT
/**
 * `VfsNamespace` — the single owner of "which virtual path, which backend and
 * which policy" for everything that runs inside the DSH phone Worker.
 *
 * Before this module the answer was assembled per execution surface: the shell
 * adapter carried its own `/tmp` alias, the CPython preopen table carried its
 * own roots, and the write tool and glob tool used the runtime's literal paths.
 * The same POSIX name could therefore mean three different files (G2-D05: a
 * write tool write to `/tmp` was invisible to `bash` and `python3`), and the
 * exec surfaces could read DSH's own session state because no layer owned a
 * read policy at all (G2-D01: `bash` grep'ed `/dsh/home/sessions/**`).
 *
 * The table is fixed by `spec/v1/channel.md` §6 and
 * `spec/v1/budgets.md` §4:
 *
 * | root | kind | sink | budget bucket |
 * | --- | --- | --- | --- |
 * | `/dsh/workspace` | durable | yes | `workspace` |
 * | `/dsh/home` | durable | yes | `sessions` |
 * | `/tmp` | volatile | no | `tmp` |
 * | `/dsh/tmp` | volatile | no | `tmp` |
 * | `/dev/null` | device | no | `none` |
 *
 * `/tmp` and `/dsh/tmp` are two spellings of one volatile storage: every
 * consumer resolves a virtual path through {@link VfsNamespace.storagePath},
 * which canonicalises `/tmp/**` onto `/dsh/tmp/**` before the in-memory VFS
 * sees it. That keeps the two names consistent for every surface — including
 * the surfaces this repository does not own — while the sink (D4) never sees
 * either prefix. Upstream's own Landlock dialect
 * (`webworker-runtime/src/shell/process/landlock.ts`) applies the same
 * `/tmp` → `DSH_TMP` mapping, so this is the runtime's meaning, not a second
 * one.
 *
 * The exec read policy is the other half: `/dsh/home/sessions`,
 * `/dsh/home/storages` and `/dsh/home/tool-journal` are DSH-internal state.
 * They stay readable by the runtime's own services but not by an execution
 * surface (`bash`, `python3`, `git`); {@link VfsNamespace.assertExecReadable}
 * answers `EACCES` with one remediation line, and the whole worker sees the
 * same answer because every surface asks this module.
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-namespace
 */
import { VfsProxyError } from './errors.ts'
import type { GuestPreopen } from './types.ts'

/** How long a root's contents live. */
export type RootKind = 'durable' | 'volatile' | 'device'

/** Budget bucket a byte written under a root counts against (budgets.md §4). */
export type BudgetBucket = 'workspace' | 'sessions' | 'tmp' | 'none'

/** One fixed root of the Worker namespace. */
export interface RootSpec {
  /** Absolute virtual path of the root (contract namespace). */
  readonly path: string
  readonly kind: RootKind
  /** Whether mutations below the root are sent to the host (D4). */
  readonly sink: boolean
  readonly budgetBucket: BudgetBucket
}

/** Everything one virtual path means to the Worker. */
export interface PathFacts {
  /** Canonical virtual path the facts were computed for. */
  readonly path: string
  /** Root the path belongs to, or undefined outside every root. */
  readonly root: RootSpec | undefined
  /** Whether a change at this path is sink-eligible (D4). */
  readonly sink: boolean
  /** Whether an execution surface may create or change the path. */
  readonly writable: boolean
  /** Whether an execution surface may read the path. */
  readonly execReadable: boolean
  readonly budgetBucket: BudgetBucket
}

/**
 * DSH-internal state under the durable home root. The runtime's own services
 * read these paths; execution surfaces do not.
 */
export const EXEC_INTERNAL_ROOTS: readonly string[] = Object.freeze([
  '/dsh/home/sessions',
  '/dsh/home/storages',
  '/dsh/home/tool-journal',
])

/**
 * Legacy runtime-native spellings and the contract root each one names.
 *
 * `/tmp` is deliberately absent: it is a root of the table, not an alias. The
 * old `/tmp` → `/dsh/tmp` translation survives only as the storage
 * canonicalisation in {@link VfsNamespace.storagePath}, which every surface
 * applies at the same boundary.
 */
export const LEGACY_ROOT_ALIASES: readonly { readonly from: string; readonly to: string }[] = Object.freeze([
  { from: '/workspace', to: '/dsh/workspace' },
  { from: '/home', to: '/dsh/home' },
])

/** The one fixed Worker root table. */
export const WORKER_ROOTS: readonly RootSpec[] = Object.freeze([
  Object.freeze({ path: '/dsh/workspace', kind: 'durable', sink: true, budgetBucket: 'workspace' }),
  Object.freeze({ path: '/dsh/home', kind: 'durable', sink: true, budgetBucket: 'sessions' }),
  Object.freeze({ path: '/tmp', kind: 'volatile', sink: false, budgetBucket: 'tmp' }),
  Object.freeze({ path: '/dsh/tmp', kind: 'volatile', sink: false, budgetBucket: 'tmp' }),
  Object.freeze({ path: '/dev/null', kind: 'device', sink: false, budgetBucket: 'none' }),
] as const)

/** One line an execution surface gets when it reaches for session state. */
export function execReadDeniedMessage(path: string, root: string): string {
  return `session-internal state under ${root} is not readable from an execution surface; `
    + `read it through the session API or copy what you need into /dsh/workspace first (${path})`
}

/** True when `path` is `root` itself or lies below it (both canonical). */
export function isWithin(root: string, path: string): boolean {
  return root === '/' ? path.startsWith('/') : path === root || path.startsWith(`${root}/`)
}

/**
 * Fold `.`/`..` and duplicate separators of an absolute virtual path.
 * @param path - absolute virtual path.
 * @returns the canonical path (`/` for the root).
 * @throws {VfsProxyError} `EINVAL` for a relative path or a NUL byte.
 */
export function normalizeVirtualPath(path: string): string {
  if (typeof path !== 'string' || path === '') {
    throw new VfsProxyError('EINVAL', 'expected a non-empty absolute path', String(path))
  }
  if (path.includes('\0')) throw new VfsProxyError('EINVAL', 'path contains a NUL byte', path)
  if (!path.startsWith('/')) {
    throw new VfsProxyError('EINVAL', `expected an absolute path, received ${JSON.stringify(path)}`, path)
  }
  const parts: string[] = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      parts.pop()
      continue
    }
    parts.push(part)
  }
  return parts.length === 0 ? '/' : `/${parts.join('/')}`
}

/** D4: `^/dsh/(home|workspace)(/[^/]+)+$` with no `.`/`..`/empty component. */
function isD4Target(path: string): boolean {
  const prefix = path.startsWith('/dsh/home/')
    ? '/dsh/home/'
    : path.startsWith('/dsh/workspace/') ? '/dsh/workspace/' : undefined
  if (prefix === undefined) return false
  const components = path.slice(prefix.length).split('/')
  return components.length > 0 && components.every(component => component !== '' && component !== '.' && component !== '..')
}

/**
 * The single path authority of the Worker.
 *
 * Instances are immutable after construction. Production uses
 * {@link WORKER_VFS_NAMESPACE}; a test may build another instance with the
 * same or a different root table to pin the policy in isolation.
 */
export class VfsNamespace {
  /** Fixed root table, in table order. */
  readonly roots: readonly RootSpec[]

  /**
   * @param roots - root table; defaults to {@link WORKER_ROOTS}.
   */
  constructor(roots: readonly RootSpec[] = WORKER_ROOTS) {
    if (roots.length === 0) throw new TypeError('VfsNamespace: the root table cannot be empty')
    for (const root of roots) {
      const canonical = normalizeVirtualPath(root.path)
      if (canonical !== root.path) {
        throw new TypeError(`VfsNamespace: root ${JSON.stringify(root.path)} must be canonical (${canonical})`)
      }
      if (root.path === '/') throw new TypeError('VfsNamespace: / cannot be a root')
    }
    this.roots = Object.freeze(roots.map(root => Object.freeze({ ...root })))
  }

  /**
   * Canonical virtual path: normalise, then translate the legacy
   * `/workspace` and `/home` spellings. `/tmp` stays `/tmp` — it is a root.
   * @param path - absolute virtual path in any surface's spelling.
   * @returns the canonical virtual path.
   * @throws {VfsProxyError} `EINVAL` on a relative path or NUL byte.
   */
  resolve(path: string): string {
    const normalized = normalizeVirtualPath(path)
    for (const alias of LEGACY_ROOT_ALIASES) {
      if (normalized === alias.from) return alias.to
      if (normalized.startsWith(`${alias.from}/`)) return `${alias.to}${normalized.slice(alias.from.length)}`
    }
    return normalized
  }

  /**
   * Canonical *storage* path: {@link resolve} plus the one volatile-root
   * canonicalisation `/tmp/**` → `/dsh/tmp/**`.
   *
   * Every consumer that reaches the in-memory VFS calls this, so the write
   * tool's `/tmp/x`, `bash`'s `/tmp/x` and `python3`'s `/tmp/x` are one file at
   * `/dsh/tmp/x` no matter which adapter named it (G2-D05).
   * @param path - absolute virtual path.
   * @returns the canonical storage path.
   */
  storagePath(path: string): string {
    const resolved = this.resolve(path)
    if (resolved === '/tmp') return '/dsh/tmp'
    if (resolved.startsWith('/tmp/')) return `/dsh/tmp${resolved.slice('/tmp'.length)}`
    return resolved
  }

  /**
   * Root the path belongs to (longest matching root wins).
   * @param path - absolute virtual path.
   * @returns the root, or undefined outside every root (the read-only image).
   */
  rootFor(path: string): RootSpec | undefined {
    const resolved = this.resolve(path)
    let best: RootSpec | undefined
    for (const root of this.roots) {
      if (!isWithin(root.path, resolved)) continue
      if (best === undefined || root.path.length > best.path.length) best = root
    }
    return best
  }

  /**
   * Complete policy answer for one path.
   * @param path - absolute virtual path.
   * @returns sink/writable/read/budget facts.
   */
  classify(path: string): PathFacts {
    const resolved = this.resolve(path)
    const root = this.rootFor(resolved)
    return {
      path: resolved,
      root,
      sink: root !== undefined && root.sink && isD4Target(resolved),
      writable: root !== undefined,
      execReadable: this.execReadable(resolved),
      budgetBucket: root?.budgetBucket ?? 'none',
    }
  }

  /**
   * True exactly when a change at this path belongs in the D4 stream.
   * @param path - absolute virtual path.
   * @returns sink eligibility.
   */
  sinkEligible(path: string): boolean {
    return this.classify(path).sink
  }

  /**
   * Whether an execution surface may read this path.
   * @param path - absolute virtual path.
   * @returns false for the DSH-internal subtrees.
   */
  execReadable(path: string): boolean {
    let resolved: string
    try {
      resolved = this.resolve(path)
    } catch {
      return false
    }
    return !EXEC_INTERNAL_ROOTS.some(root => isWithin(root, resolved))
  }

  /**
   * Whether an execution surface may create or change this path.
   * @param path - absolute virtual path.
   * @returns true for every root in the table.
   */
  writable(path: string): boolean {
    return this.rootFor(path) !== undefined
  }

  /**
   * Refuse a read of DSH-internal state with `EACCES` and one remediation
   * line. Surfaces call this before their first backend read so every one of
   * them answers with the same code and message.
   * @param path - absolute virtual path the surface is about to read.
   * @throws {VfsProxyError} `EACCES` when the path is inside an internal root.
   */
  assertExecReadable(path: string): void {
    const resolved = this.resolve(path)
    if (this.execReadable(resolved)) return
    const root = EXEC_INTERNAL_ROOTS.find(candidate => isWithin(candidate, resolved)) ?? resolved
    throw new VfsProxyError('EACCES', execReadDeniedMessage(resolved, root), resolved)
  }

  /**
   * Join a base directory and a search pattern into one canonical virtual
   * path. A relative pattern keeps the base; an absolute pattern replaces it;
   * a leading `!` (glob negation) is preserved.
   * @param base - absolute base directory.
   * @param pattern - relative or absolute pattern.
   * @returns the canonical joined pattern.
   */
  join(base: string, pattern: string): string {
    if (typeof pattern !== 'string' || pattern === '') {
      throw new VfsProxyError('EINVAL', 'expected a non-empty pattern', String(pattern))
    }
    const negated = pattern.startsWith('!')
    const body = negated ? pattern.slice(1) : pattern
    if (body === '') throw new VfsProxyError('EINVAL', 'pattern has no path after !', pattern)
    const joined = body.startsWith('/') ? this.resolve(body) : this.resolve(`${this.resolve(base)}/${body}`)
    return negated ? `!${joined}` : joined
  }

  /**
   * Identity preopen table generated from the root table (device roots are not
   * mountable directories). Guest path == host path, so a WASI program reads
   * the same names the shell does; a second alias mount never exists.
   * @returns one preopen per non-device root, in table order.
   */
  preopens(): readonly GuestPreopen[] {
    return Object.freeze(this.roots
      .filter(root => root.kind !== 'device')
      .map(root => Object.freeze({ guestPath: root.path, hostPath: root.path })))
  }

  /**
   * Writable roots in table order (what a preopen table and the shell's
   * writable-root check derive from).
   * @returns the writable root paths.
   */
  writableRoots(): readonly string[] {
    return Object.freeze(this.roots.filter(root => root.kind !== 'device').map(root => root.path))
  }
}

/** The one production namespace. */
export const WORKER_VFS_NAMESPACE: VfsNamespace = new VfsNamespace()

/**
 * Generate an identity preopen table for a namespace.
 * @param namespace - namespace whose roots are mounted.
 * @returns the preopen table.
 */
export function namespacePreopens(namespace: VfsNamespace = WORKER_VFS_NAMESPACE): readonly GuestPreopen[] {
  return namespace.preopens()
}

// -------------------------------------------------------------- VFS wrappers

/** One virtual-path-taking member of a `node:fs`-shaped promise face. */
const PROMISE_ONE_PATH: readonly string[] = Object.freeze([
  'readFile', 'writeFile', 'appendFile', 'mkdir', 'readdir', 'stat', 'lstat', 'realpath', 'unlink',
  'rm', 'rmdir', 'truncate', 'chmod', 'access', 'open', 'opendir', 'mkdtemp', 'utimes', 'readlink',
])

/** One two-path member of a `node:fs`-shaped promise face. */
const PROMISE_TWO_PATHS: readonly string[] = Object.freeze(['rename', 'cp', 'link'])

/** Members that expose data (not just metadata) of a path. */
const READ_MEMBERS: readonly string[] = Object.freeze(['readFile', 'readdir', 'stat', 'lstat', 'realpath', 'access', 'opendir'])

/** Any function-shaped member. */
type Fn = (...args: unknown[]) => unknown

/** `node:fs`-shaped face keyed by member name. */
export type FsFace = Record<string, unknown>

/** Resolve a virtual path the way every surface must (see {@link VfsNamespace.storagePath}). */
function storageOf(namespace: VfsNamespace, path: unknown): unknown {
  return typeof path === 'string' && path.startsWith('/') ? namespace.storagePath(path) : path
}

/** Decide whether one `open` call reads (and therefore needs the read policy). */
function openReads(args: readonly unknown[]): boolean {
  const flags = typeof args[1] === 'string' ? args[1] : 'r'
  return !/[wa+]/.test(flags)
}

/**
 * Wrap one `node:fs/promises`-shaped face so every virtual path goes through
 * the namespace and every execution read honours {@link VfsNamespace.assertExecReadable}.
 *
 * This is the face the execution adapters use — the shell's
 * `VfsFileSystem`, `NodeGitFs`, and (patched in place by
 * {@link installExecFsPolicy}) the Worker's own `node:fs.promises` object. The
 * runtime's `node:fs/promises` named bindings are *not* affected: they are
 * destructured once from the promises object, which is exactly the split the
 * exec policy needs (DSH services keep reading their own state).
 * @param face - promises face over the virtual tree.
 * @param namespace - namespace supplying resolution and the read policy.
 * @returns a new face; the input is not modified.
 */
export function wrapFsPromises<T extends object>(
  face: T,
  namespace: VfsNamespace = WORKER_VFS_NAMESPACE,
  options: { readonly policy?: boolean } = {},
): T {
  const policy = options.policy ?? true
  const source = face as unknown as FsFace
  const wrapped: FsFace = { ...source }
  const wrapOne = (name: string): void => {
    const original = source[name]
    if (typeof original !== 'function') return
    wrapped[name] = (...args: unknown[]): unknown => {
      const path = args[0]
      // The face is a promise face: a refused read is a rejected call, not a
      // synchronous throw (Node's `node:fs/promises` contract).
      try {
        if (policy && READ_MEMBERS.includes(name)) namespace.assertExecReadable(String(path))
        if (policy && name === 'open' && openReads(args)) namespace.assertExecReadable(String(path))
      } catch (error) {
        return Promise.reject(error)
      }
      const next = [...args]
      next[0] = storageOf(namespace, path)
      return (original as Fn).apply(source, next)
    }
  }
  const wrapTwo = (name: string): void => {
    const original = source[name]
    if (typeof original !== 'function') return
    wrapped[name] = (...args: unknown[]): unknown => {
      // Moving or linking DSH session state out of its subtree exposes the
      // same bytes a direct read would, so the source is policy-checked too.
      try {
        if (policy && (name === 'cp' || name === 'rename' || name === 'link')) {
          namespace.assertExecReadable(String(args[0]))
        }
      } catch (error) {
        return Promise.reject(error)
      }
      const next = [...args]
      next[0] = storageOf(namespace, args[0])
      next[1] = storageOf(namespace, args[1])
      return (original as Fn).apply(source, next)
    }
  }
  for (const name of PROMISE_ONE_PATH) wrapOne(name)
  for (const name of PROMISE_TWO_PATHS) wrapTwo(name)
  return wrapped as T
}

/**
 * Patch one shared promises object in place with the execution policy.
 *
 * Used by the Worker entry on the runtime's `node:fs.promises` object: the
 * adapters that do `import { promises as fsp } from 'node:fs'` (`VfsFileSystem`
 * in the shell, `NodeGitFs`) then see the policy, while DSH's own services —
 * which import named members from `node:fs/promises` — keep their bound
 * functions and never lose access to the session state they own.
 * @param face - shared promises object over the virtual tree.
 * @param namespace - namespace supplying resolution and the read policy.
 * @returns a disposer that restores every replaced member.
 */
export function installExecFsPolicy<T extends object>(face: T, namespace: VfsNamespace = WORKER_VFS_NAMESPACE): () => void {
  const target = face as unknown as FsFace
  const wrapped = wrapFsPromises(face, namespace) as unknown as FsFace
  const replaced = new Map<string, unknown>()
  for (const name of [...PROMISE_ONE_PATH, ...PROMISE_TWO_PATHS, 'readlink']) {
    const original = target[name]
    if (typeof original !== 'function' || typeof wrapped[name] !== 'function') continue
    replaced.set(name, original)
    target[name] = wrapped[name]
  }
  return () => {
    for (const [name, original] of replaced) target[name] = original
  }
}

/**
 * Wrap a `Vfs`-shaped object so every path it receives is canonical storage.
 * This is the object installed as the Worker's active VFS: every `node:fs`
 * call — DSH tool, shell adapter, WASI backend — then reads and writes the
 * same file for the same virtual name (G2-D05).
 * @param source - the mounted VFS.
 * @param namespace - namespace supplying resolution.
 * @returns a proxy that delegates to `source` with canonical paths.
 */
export function createNamespaceVfs<T extends object>(source: T, namespace: VfsNamespace = WORKER_VFS_NAMESPACE): T {
  const syncOne = new Set([
    'readFileSync', 'existsSync', 'statSync', 'readdirSync', 'realpathSync', 'mkdirSync', 'writeFileSync',
    'appendFileSync', 'truncateSync', 'chmodSync', 'unlinkSync', 'rmSync', 'openFileSync', 'mkdtempSync',
  ])
  const syncTwo = new Set(['renameSync', 'linkSync'])
  const map = (value: unknown): unknown => (typeof value === 'string' && value.startsWith('/') ? namespace.storagePath(value) : value)
  const promises = (source as { readonly promises?: FsFace }).promises
  const wrappedPromises = promises === undefined
    ? undefined
    : wrapFsPromises(promises, namespace, { policy: false })
  // Keep one bound function per member so identity checks (`vfs.flush ===
  // wrapper`, disposers) keep working through the proxy.
  const bound = new Map<PropertyKey, { readonly fn: Fn; readonly bound: Fn }>()
  return new Proxy(source, {
    get(target, property): unknown {
      if (property === 'promises') return wrappedPromises
      if (property === 'whenReadable') {
        const whenReadable = Reflect.get(target, property, target)
        if (typeof whenReadable !== 'function') return whenReadable
        return (path: string): unknown => (whenReadable as Fn).call(target, map(path))
      }
      const value = Reflect.get(target, property, target)
      if (typeof value !== 'function') return value
      if (syncOne.has(property as string)) {
        return (...args: unknown[]): unknown => {
          const next = [...args]
          next[0] = map(next[0])
          return (value as Fn).apply(target, next)
        }
      }
      if (syncTwo.has(property as string)) {
        return (...args: unknown[]): unknown => {
          const next = [...args]
          next[0] = map(next[0])
          next[1] = map(next[1])
          return (value as Fn).apply(target, next)
        }
      }
      const cached = bound.get(property)
      if (cached !== undefined && cached.fn === value) return cached.bound
      const entry = { fn: value as Fn, bound: (value as Fn).bind(target) }
      bound.set(property, entry)
      return entry.bound
    },
    set(target, property, value): boolean {
      bound.delete(property)
      return Reflect.set(target, property, value)
    },
  }) as T
}
