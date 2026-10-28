// SPDX-License-Identifier: MIT
/**
 * POSIX path handling for the guest namespace. The toolbox is browser code, so
 * it cannot rely on `node:path`; the rules are the subset the WASI proxy needs:
 * absolute paths, `/` separators, `.`/`..` folding, and a preopen prefix check
 * that leaves the guest namespace entirely before a path reaches the host.
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-paths
 */
import { VfsCapabilityError, VfsProxyError } from './errors.ts'
import { DEFAULT_PATH_MAX_BYTES, WORKER_VFS_ROOTS } from './limits.ts'
import type { GuestPreopen } from './types.ts'

/** Fold `.`/`..` and duplicate separators, keeping the result absolute. */
export function normalizePosixPath(path: string): string {
  if (path.includes('\0')) throw new VfsProxyError('EINVAL', 'path contains a NUL byte')
  const absolute = path.startsWith('/')
  const parts: string[] = []
  for (const part of path.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      if (parts.length > 0) parts.pop()
      else if (!absolute) parts.push('..')
      continue
    }
    parts.push(part)
  }
  return `${absolute ? '/' : ''}${parts.join('/')}` || '.'
}

/** Normalise a path that must be absolute. */
export function normalizeAbsolutePath(path: string): string {
  const normalized = normalizePosixPath(path)
  if (!normalized.startsWith('/')) {
    throw new VfsProxyError('EINVAL', `expected an absolute path, received ${JSON.stringify(path)}`, path)
  }
  return normalized === '/' ? '/' : normalized.replace(/\/+$/, '')
}

/** Join a relative or absolute guest path to a directory path. */
export function joinPosixPath(directory: string, path: string): string {
  if (path.startsWith('/')) return normalizeAbsolutePath(path)
  return normalizeAbsolutePath(`${directory === '/' ? '' : directory}/${path}`)
}

/** True when `path` is `root` or lies below it (both normalised). */
export function isWithinRoot(root: string, path: string): boolean {
  if (root === '/') return path.startsWith('/')
  return path === root || path.startsWith(`${root}/`)
}

/** Reject paths that are empty or longer than the WASI `PATH_MAX`. */
export function checkPathLength(path: string, maximum = DEFAULT_PATH_MAX_BYTES): void {
  if (path.length === 0) throw new VfsProxyError('EINVAL', 'empty path')
  if (path.length > maximum) throw new VfsProxyError('ENAMETOOLONG', `path longer than ${maximum} bytes`, path)
}

/** Mapping result of one guest path resolution. */
export interface ResolvedGuestPath {
  readonly guestPath: string
  readonly hostPath: string
}

/**
 * Resolve a guest path against a directory fd and the preopen table. Relative
 * paths join the directory; absolute paths must already start with a preopen.
 * A path that is not under any preopen is refused before it can reach the host.
 */
export function resolveGuestPath(
  preopens: readonly GuestPreopen[],
  directoryGuestPath: string | undefined,
  path: string,
): ResolvedGuestPath {
  checkPathLength(path)
  const guestPath = path.startsWith('/')
    ? normalizeAbsolutePath(path)
    : joinPosixPath(directoryGuestPath ?? '/', path)
  let best: GuestPreopen | undefined
  for (const preopen of preopens) {
    const root = normalizeAbsolutePath(preopen.guestPath)
    if (!isWithinRoot(root, guestPath)) continue
    if (best === undefined || root.length > normalizeAbsolutePath(best.guestPath).length) best = preopen
  }
  if (best === undefined) {
    throw new VfsCapabilityError(`path is outside the preopened directories: ${guestPath}`, guestPath)
  }
  const root = normalizeAbsolutePath(best.guestPath)
  const suffix = guestPath === root ? '' : guestPath.slice(root.length)
  const hostRoot = normalizeAbsolutePath(best.hostPath)
  return {
    guestPath,
    hostPath: normalizeAbsolutePath(`${hostRoot === '/' ? '' : hostRoot}${suffix}`),
  }
}

/** Find the guest path a host path belongs to, for diagnostics. */
export function toGuestPath(preopens: readonly GuestPreopen[], hostPath: string): string | undefined {
  const normalized = normalizeAbsolutePath(hostPath)
  for (const preopen of preopens) {
    const root = normalizeAbsolutePath(preopen.hostPath)
    if (!isWithinRoot(root, normalized)) continue
    const guestRoot = normalizeAbsolutePath(preopen.guestPath)
    const suffix = normalized === root ? '' : normalized.slice(root.length)
    return `${guestRoot === '/' ? '' : guestRoot}${suffix}` || '/'
  }
  return undefined
}

/**
 * Legacy POSIX spellings a runtime or a `cd` may still hand us and the
 * contract `/dsh` root each one means.
 *
 * `/tmp` is deliberately absent: it is a root of the namespace table
 * (`VfsNamespace.roots`), not a translation, and both volatile spellings are
 * preopened. The namespace's storage canonicalisation, not this table, is what
 * makes `/tmp/x` and `/dsh/tmp/x` one file. The remaining aliases are never
 * extra preopen roots, so a guest cannot reach the same file under two names.
 */
export const WORKER_PATH_ALIASES: readonly { readonly from: string; readonly to: string }[] = Object.freeze([
  { from: '/workspace', to: '/dsh/workspace' },
  { from: '/home', to: '/dsh/home' },
])

/**
 * Canonicalise a Worker path into the contract `/dsh` namespace.
 *
 * A path that already names a Worker VFS root is returned unchanged — this
 * includes `/tmp`, which is a root of its own; the legacy spellings in
 * {@link WORKER_PATH_ALIASES} are translated. Anything else (the image tree
 * under `/dsh/bin`, a Windows-looking path, a relative path) has no Worker VFS
 * root and returns undefined instead of inventing one.
 * @param path - absolute path in the shell or runtime spelling.
 * @returns the `/dsh` path, or undefined when it names no Worker VFS root.
 */
export function workerNamespacePath(path: string): string | undefined {
  let normalized: string
  try {
    normalized = normalizeAbsolutePath(path)
  } catch {
    return undefined
  }
  for (const root of WORKER_VFS_ROOTS) {
    if (isWithinRoot(root, normalized)) return normalized
  }
  for (const alias of WORKER_PATH_ALIASES) {
    if (!isWithinRoot(alias.from, normalized)) continue
    const suffix = normalized === alias.from ? '' : normalized.slice(alias.from.length)
    return `${alias.to}${suffix}`
  }
  return undefined
}

/**
 * Translate the `PWD`-style environment values a shell exports onto the
 * contract namespace. Values that already name a Worker root are canonicalised;
 * values outside every root are left untouched so a program can still report
 * them.
 * @param env - mutable environment to rewrite in place.
 */
export function translateWorkerEnvironment(env: Record<string, string | undefined>): void {
  for (const name of ['PWD', 'OLDPWD'] as const) {
    const value = env[name]
    if (value === undefined) continue
    env[name] = workerNamespacePath(value) ?? value
  }
}

/**
 * Resolve a cwd a shell or caller supplied into the guest path of the preopen
 * table, translating the legacy spellings. This is the same mapping the shell
 * applies to its own cwd, so a WASI program starts in the directory `ls` runs
 * in.
 * @param preopens - preopen table of the program.
 * @param path - absolute shell/runtime path (host `/dsh` or legacy spelling).
 * @returns the guest cwd, or undefined when no preopen covers it.
 */
export function resolveGuestCwd(preopens: readonly GuestPreopen[], path: string): string | undefined {
  let normalized: string
  try {
    normalized = normalizeAbsolutePath(path)
  } catch {
    return undefined
  }
  const direct = guestOfPreopen(preopens, normalized)
  if (direct !== undefined) return direct
  const translated = workerNamespacePath(normalized)
  if (translated === undefined) return undefined
  return guestOfPreopen(preopens, translated)
}

/** Map a path onto a preopen's guest spelling (guest root first, then host root). */
function guestOfPreopen(preopens: readonly GuestPreopen[], path: string): string | undefined {
  for (const preopen of preopens) {
    if (isWithinRoot(normalizeAbsolutePath(preopen.guestPath), path)) return path
  }
  let bestGuestRoot = ''
  let bestSuffix = ''
  let bestLength = -1
  for (const preopen of preopens) {
    const hostRoot = normalizeAbsolutePath(preopen.hostPath)
    if (!isWithinRoot(hostRoot, path) || hostRoot.length <= bestLength) continue
    bestGuestRoot = normalizeAbsolutePath(preopen.guestPath)
    bestSuffix = path === hostRoot ? '' : path.slice(hostRoot.length)
    bestLength = hostRoot.length
  }
  if (bestLength < 0) return undefined
  return `${bestGuestRoot === '/' ? '' : bestGuestRoot}${bestSuffix}` || '/'
}
