// SPDX-License-Identifier: MIT
/**
 * Boot-time installation of the one path authority
 * ({@link VfsNamespace}) into the running Worker.
 *
 * The entry installs it after `host.start()` and before the first API_REQ, so
 * every later `node:fs` call — the DSH write/glob tools, the Worker shell,
 * the WASI backends and `git` — resolves through the same table:
 *
 *  1. the mounted VFS is wrapped with {@link createNamespaceVfs}, which
 *     canonicalises virtual paths (`/tmp/**` → `/dsh/tmp/**`) before the
 *     in-memory tree sees them, and that wrapper becomes the active VFS of the
 *     runtime's `node:fs` proxy (`runtime.activateVfs`);
 *  2. the two volatile roots are created and probed (see
 *     {@link seedNamespaceRoots}); a probe failure is loud, because the
 *     upstream sandbox promises both spellings are writable;
 *  3. the shared `node:fs.promises` object receives the exec read policy
 *     (`runtime.installExecFsPolicy`), so `bash` and `git` cannot read DSH's
 *     own session state.
 *
 * Steps 1 and 3 are hooks of the runtime binding: the pure entry logic (and
 * its Node tests) can run without the pinned DSH checkout.
 * @module @phone-dsh/dsh-worker-entry/namespace-boot
 */
import {
  WORKER_VFS_NAMESPACE,
  createNamespaceVfs,
  type VfsNamespace,
} from '../../wasi-toolbox/src/index.ts'
import type { WorkerEntryVfs } from './entry.ts'
import { installNumericOpenHandlers } from './numeric-open-flags.ts'

/** Runtime hooks the boot needs; the DSH binding supplies both in production. */
export interface NamespaceRuntimeHooks {
  /** Publish the wrapped VFS as the one the runtime's `node:fs` proxy reads. */
  activateVfs?(vfs: unknown): void
  /** Patch the shared `node:fs.promises` object with the exec read policy. */
  installExecFsPolicy?(namespace: VfsNamespace): (() => void) | void
  /** Add a bounded opener after the exec policy (real mounted VFS supplied). */
  installBoundedDirectoryOpener?(vfs: unknown): (() => void) | void
}

/** The synchronous write face of the runtime VFS the seeding uses. */
export interface NamespaceSeedVfs extends WorkerEntryVfs {
  mkdirSync?(path: string, options?: { readonly recursive?: boolean; readonly mode?: number }): unknown
  writeFileSync?(path: string, data: string | Uint8Array, options?: { readonly mode?: number }): void
  chmodSync?(path: string, mode: number): void
  rmSync?(path: string, options?: { readonly recursive?: boolean; readonly force?: boolean }): void
}

/** What {@link seedNamespaceRoots} did. */
export interface NamespaceSeedReport {
  /** False when the VFS exposed no synchronous write face (a test double). */
  readonly active: boolean
  /** Roots that were created, in table order. */
  readonly roots: readonly string[]
  /** Two-spelling probe performed, when the write face existed. */
  readonly probe?: readonly string[]
  /** Why seeding was skipped, when it was. */
  readonly reason?: string
}

/** Pairs of spellings that must name one storage. */
const VOLATILE_PAIRS: readonly (readonly [string, string])[] = Object.freeze([
  Object.freeze(['/tmp', '/dsh/tmp'] as const),
])

const PROBE_TEXT = 'pdsh-namespace-probe'
const PROBE_NAME = '.pdsh-namespace-probe'

/** Decode a `readFileSync` result the same way whether bytes or text came back. */
function decode(value: string | Uint8Array): string {
  return typeof value === 'string' ? value : new TextDecoder().decode(value)
}

/**
 * Create the namespace roots and prove the volatile spellings are one store.
 *
 * A VFS without the synchronous write face (a unit-test double) is skipped:
 * the seeding is a runtime-VFS responsibility, not a policy. A VFS that has
 * the face but cannot write both spellings is a hard boot failure — that is
 * exactly the upstream contract gap G2-D05 exposed, and continuing would
 * hand the model a `/tmp` that only some surfaces can see.
 * @param vfs - mounted VFS (normally the namespace-wrapped one).
 * @param namespace - path authority; defaults to the production namespace.
 * @returns what was created and probed.
 * @throws {Error} When a root cannot be created or the two spellings diverge.
 */
export function seedNamespaceRoots(
  vfs: WorkerEntryVfs,
  namespace: VfsNamespace = WORKER_VFS_NAMESPACE,
): NamespaceSeedReport {
  const target = vfs as NamespaceSeedVfs
  const mkdir = target.mkdirSync
  const write = target.writeFileSync
  const read = target.readFileSync
  if (typeof mkdir !== 'function' || typeof write !== 'function' || typeof read !== 'function') {
    return { active: false, roots: [], reason: 'the VFS exposes no synchronous write face' }
  }
  const roots = namespace.roots.filter(root => root.kind !== 'device')
  for (const root of roots) {
    const mode = root.kind === 'volatile' ? 0o1777 : 0o755
    mkdir.call(target, root.path, { recursive: true, mode })
    if (root.kind === 'volatile') target.chmodSync?.call(target, root.path, mode)
  }
  const probe: string[] = []
  for (const [left, right] of VOLATILE_PAIRS) {
    const leftPath = `${left}/${PROBE_NAME}`
    const rightPath = `${right}/${PROBE_NAME}`
    probe.push(`${left}->${right}`)
    try {
      write.call(target, leftPath, PROBE_TEXT, { mode: 0o600 })
      let seen: string
      try {
        seen = decode(read.call(target, rightPath))
      } catch (error) {
        throw probeFailure(`${left} is not visible through ${right}: ${messageOf(error)}`)
      }
      if (seen !== PROBE_TEXT) {
        throw probeFailure(`${left} and ${right} resolve to different files (read back ${JSON.stringify(seen)})`)
      }
      target.rmSync?.call(target, `${right}/${PROBE_NAME}`, { force: true })
      write.call(target, rightPath, PROBE_TEXT, { mode: 0o600 })
      try {
        seen = decode(read.call(target, leftPath))
      } catch (error) {
        throw probeFailure(`${right} is not visible through ${left}: ${messageOf(error)}`)
      }
      if (seen !== PROBE_TEXT) {
        throw probeFailure(`${right} and ${left} resolve to different files (read back ${JSON.stringify(seen)})`)
      }
    } finally {
      target.rmSync?.call(target, leftPath, { force: true })
      target.rmSync?.call(target, rightPath, { force: true })
    }
    for (const root of [left, right]) {
      // The base interface only promises `isFile`; the runtime VFS also
      // answers `isDirectory`, which is the proof the root is a directory.
      const stat = target.statSync
      if (typeof stat !== 'function') continue
      const stats = stat.call(target, root) as { isDirectory?: () => boolean }
      if (typeof stats.isDirectory === 'function' && !stats.isDirectory()) {
        throw probeFailure(`${root} is not a directory after seeding`)
      }
    }
  }
  return { active: true, roots: roots.map(root => root.path), probe }
}

/** Error text that names the upstream contract so a boot failure is actionable. */
function probeFailure(detail: string): Error {
  return new Error(
    `worker entry: the volatile tmp root is not usable through both spellings (/tmp, /dsh/tmp): ${detail}. `
    + 'The upstream sandbox declares writableRoots=[workspaceRoot, /tmp, os.tmpdir()] and os.tmpdir() '
    + 'is /dsh/tmp, so both must be writable before the first request (upstream contract gap).',
  )
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** One installed authority. */
export interface NamespaceAuthority {
  /** VFS the runtime's `node:fs` now reads. */
  readonly vfs: NamespaceSeedVfs
  readonly seed: NamespaceSeedReport
  /** Restore the previous `node:fs.promises` object (tests and shutdown). */
  readonly dispose: () => void
}

/**
 * Install the namespace into one running Worker.
 * @param options.vfs - mounted VFS returned by the runtime host.
 * @param options.runtime - runtime hooks; absent in pure unit tests.
 * @param options.namespace - path authority override.
 * @returns the wrapped VFS, the seed report and the policy disposer.
 */
export function installNamespaceAuthority(options: {
  readonly vfs: WorkerEntryVfs
  readonly runtime?: NamespaceRuntimeHooks | undefined
  readonly namespace?: VfsNamespace | undefined
}): NamespaceAuthority {
  const namespace = options.namespace ?? WORKER_VFS_NAMESPACE
  const vfs = createNamespaceVfs(options.vfs, namespace) as NamespaceSeedVfs
  // Seed before publishing: no `node:fs` caller can observe the volatile roots
  // missing, and a failed probe leaves the host's original VFS active while
  // the boot fails loud.
  const seed = seedNamespaceRoots(vfs, namespace)
  // Numeric `open(2)` masks are part of the mounted VFS contract: the sync
  // and promise faces both reach this one object. Install after the path
  // authority so the adapter's preconditions write through the same
  // `/tmp` -> `/dsh/tmp` mapping as every other node:fs caller.
  const disposeNumericOpen = installNumericOpenHandlers(options.vfs)
  options.runtime?.activateVfs?.(vfs)
  const disposePolicy = options.runtime?.installExecFsPolicy?.(namespace)
  // The bounded opener composes on top of the exec policy: the policy still
  // rewrites `/tmp` and refuses DSH-internal reads before the original opener.
  // It receives the real mounted VFS, not the alias proxy, so `usage()`, the
  // image manifest and `deferArchive()` observation all describe the same tree
  // the original `opendir` will materialise.
  const disposeBoundedOpener = options.runtime?.installBoundedDirectoryOpener?.(options.vfs)
  return {
    vfs,
    seed,
    dispose: () => {
      if (typeof disposeBoundedOpener === 'function') disposeBoundedOpener()
      if (typeof disposePolicy === 'function') disposePolicy()
      disposeNumericOpen()
    },
  }
}
