// SPDX-License-Identifier: MIT
/**
 * Budget constants of the WASI toolbox. The memory values are the "WASI hot
 * instance" row of `spec/v1/budgets.md` (PLAN §2.5) for each device
 * tier; 260 MB is the default 8 GiB tier.
 * @module @phone-dsh/dsh-wasi-toolbox/limits
 */
import type { GuestPreopen } from './types.ts'
import { WORKER_VFS_NAMESPACE } from './vfs-namespace.ts'

/** One mebibyte, the unit of the budget table. */
export const MEBIBYTE = 1024 * 1024

/**
 * Render a byte budget as its exact byte count plus, when the bound is a whole
 * number of MiB, the MiB spelling: `67108864 bytes (64 MiB)`.
 *
 * This is the single owner of every human-readable resource-limit label in the
 * Worker (`EFBIG`, `ENOSPC`, quota, read caps). Callers pass the same value
 * their check enforces, so a diagnostic can never name a budget that is not
 * the one applied — the G2-FIX-100 split where the bytes came from the
 * configurable budget and the label from a hard-coded literal.
 * @param limit - the bound in bytes.
 * @returns the human-readable limit.
 */
export function formatByteLimit(limit: number): string {
  return limit > 0 && limit % MEBIBYTE === 0
    ? `${String(limit)} bytes (${String(limit / MEBIBYTE)} MiB)`
    : `${String(limit)} bytes`
}

/**
 * The MiB spelling alone (`64 MiB`) when the bound is a whole number of MiB,
 * undefined otherwise. For one-line hints that must stay short; a caller that
 * needs the exact byte count uses {@link formatByteLimit}.
 * @param limit - the bound in bytes.
 * @returns the MiB label, or undefined when the bound is not a whole MiB.
 */
export function formatByteLimitMib(limit: number): string | undefined {
  return limit > 0 && limit % MEBIBYTE === 0 ? `${String(limit / MEBIBYTE)} MiB` : undefined
}

/** Environment name the host uses to publish its `single_file_limit` (D4). */
export const SINGLE_FILE_LIMIT_ENV = 'PDSH_SINGLE_FILE_LIMIT_BYTES'

/** Default single-file budget, 8 GiB tier (budgets.md §4): 64 MiB. */
export const DEFAULT_SINGLE_FILE_LIMIT = 64 * MEBIBYTE
/** Contract floor for a host-configured single-file limit: 16 MiB. */
export const MIN_SINGLE_FILE_LIMIT = 16 * MEBIBYTE
/** Absolute host maximum for a configured single-file limit: 128 MiB. */
export const MAX_SINGLE_FILE_LIMIT = 128 * MEBIBYTE

/**
 * Active single-file budget: 64 MiB by default, the 8 GiB tier row.
 *
 * This is the file cap, not the per-mutation frame cap. One file larger than
 * one VFS_MUT is published as one complete write plus appended suffixes
 * (channel.md §3.1), so the cap can exceed the 15 MiB mutation bound. The
 * Worker write surfaces (`shell-ext`, the WASI VFS backends) refuse a write
 * whose post-write file would exceed this with `EFBIG` before the runtime VFS
 * publishes the mutation; the sink's payload guard stays as the last-resort
 * backstop. Every refusal renders its bound through {@link formatByteLimit},
 * so the byte count and the MiB label come from this one value. The host
 * publishes its tier value through
 * {@link SINGLE_FILE_LIMIT_ENV}; {@link configureSingleFileLimit} applies it
 * once before the VFS boots.
 */
export let MAX_FILE_SIZE = DEFAULT_SINGLE_FILE_LIMIT

/**
 * Apply one validated single-file limit to the process-wide WASI budget.
 *
 * The entry calls this before the host starts, from the host's
 * `single_file_limit`. Tests may set a small value for a deterministic
 * over-limit case. The value is not re-clamped here: the host already applied
 * `budgets.md` §4 clamping and an explicit test override must stay exact.
 * @param bytes - post-write file cap in bytes.
 * @returns the applied value.
 * @throws {RangeError} when the value is not a non-negative safe integer.
 */
export function configureSingleFileLimit(bytes: number): number {
  if (!Number.isSafeInteger(bytes) || bytes < 0) {
    throw new RangeError(`single-file limit must be a non-negative safe integer, got ${String(bytes)}`)
  }
  MAX_FILE_SIZE = bytes
  return bytes
}

/**
 * Read the host's single-file budget from the Worker environment.
 *
 * A missing, non-decimal or non-positive value yields undefined so the
 * built-in tier default applies. A parsed value is clamped into the contract
 * range 16 MiB...128 MiB (budgets.md §4 says an out-of-range configuration is
 * clamped, never a start failure).
 * @param env - environment map; defaults to `process.env` when available.
 * @returns the clamped byte limit, or undefined when unset.
 */
export function singleFileLimitFromEnvironment(
  env?: Readonly<Record<string, string | undefined>>,
): number | undefined {
  const source = env ?? (typeof process === 'undefined' ? undefined : process.env)
  const raw = source?.[SINGLE_FILE_LIMIT_ENV]
  if (raw === undefined || raw === '' || !/^[0-9]+$/u.test(raw)) return undefined
  const parsed = Number(raw)
  if (!Number.isSafeInteger(parsed) || parsed <= 0) return undefined
  return Math.min(MAX_SINGLE_FILE_LIMIT, Math.max(MIN_SINGLE_FILE_LIMIT, parsed))
}

/** Default ceiling for one live WASI instance (260 MB, 8 GiB tier). */
export const DEFAULT_HOT_INSTANCE_MEMORY_BYTES = 260 * MEBIBYTE

/** Ceiling per device tier, from budgets.md §4. */
export const HOT_INSTANCE_MEMORY_BYTES_BY_TIER = {
  '8GiB': 260 * MEBIBYTE,
  '6GiB': 200 * MEBIBYTE,
  '4GiB': 144 * MEBIBYTE,
  '3GiB': 96 * MEBIBYTE,
} as const

/** One proxy frame (request or response) fits in this many bytes by default. */
export const DEFAULT_VFS_FRAME_BYTES = MEBIBYTE

/** How long a blocking VFS call waits for the DSH worker before failing. */
export const DEFAULT_VFS_SYNC_TIMEOUT_MS = 30_000

/** How long a fresh tool worker has to answer `init` before it is terminated. */
export const DEFAULT_WORKER_READY_TIMEOUT_MS = 10_000

/** Absolute path length limit in bytes (WASI `PATH_MAX`). */
export const DEFAULT_PATH_MAX_BYTES = 4096

/**
 * VFS roots the Worker shell serves and may write (PLAN D4/D15).
 *
 * Generated from the single path authority ({@link WORKER_VFS_NAMESPACE}), so
 * the preopen table, the shell's writable-root check and the sink predicate
 * cannot drift. The table includes both volatile spellings (`/tmp` and
 * `/dsh/tmp`); the namespace canonicalises them to one storage path before the
 * in-memory VFS sees either.
 */
export const WORKER_VFS_ROOTS: readonly string[] = WORKER_VFS_NAMESPACE.writableRoots()

/**
 * Guest preopens of the Worker VFS: identity mounts of {@link WORKER_VFS_ROOTS}.
 *
 * A guest path is therefore already a contract path (`/dsh/workspace/...`), and
 * a relative path resolved by wasi-libc stays inside the same root the shell
 * uses. There is no `/workspace` or `/home` second mount: those POSIX
 * spellings are translated to this namespace before dispatch (see
 * `workerNamespacePath`/`resolveGuestCwd` in `vfs-paths.ts`). `/tmp` is not a
 * translation: it is an identity preopen of its own root, and the namespace
 * maps it onto the same volatile storage as `/dsh/tmp`.
 */
export const WORKER_VFS_PREOPENS: readonly GuestPreopen[] = WORKER_VFS_NAMESPACE.preopens()

/** Directory a command runs in when neither the caller nor `PWD` names one. */
export const WORKER_DEFAULT_CWD = WORKER_VFS_ROOTS[0] as string

/** Guest directories preopened by default; host paths follow PLAN §2.5. */
export const DEFAULT_PREOPENS: readonly GuestPreopen[] = WORKER_VFS_PREOPENS
