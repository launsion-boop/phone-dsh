// SPDX-License-Identifier: MIT
/**
 * Command-boundary durability fence for programs that run in the Worker shell.
 *
 * `bash -c` and every writing command stay in the Worker (PLAN D12), so their
 * file mutations reach the host WAL through the VFS sink: `MemoryVfs` publishes
 * one mutation per write, `worker-entry` encodes it as 0x10 and waits for the
 * host's level-1 ack on `flush()`. That ack is asynchronous. A command that
 * returns as soon as the shell engine settles can therefore report success
 * while its last writes are still in flight; a WebContent kill in that window
 * removes them from the Worker VFS and they never reach the WAL or the
 * materialized copy (the G2-F07 batch defect, G2-FIX-61).
 *
 * `worker-entry` publishes the sink-wrapped `flush()` as
 * {@link WORKER_VFS_FLUSH_GLOBAL} after it installs the sink. This module is
 * the consumer side: the shell process awaits it after the engine settles and
 * before it reports the exit, so success implies the writes are acknowledged.
 * On the desktop reference transport (real `node:child_process`, no Worker VFS)
 * the hook is absent and this is a no-op.
 * @module @phone-dsh/dsh-subprocess-xl/durability
 */

/**
 * Name of the Worker global carrying the VFS sink flush.
 *
 * Kept literally in sync with `worker-entry`'s export of the same name; the two
 * packages have no dependency edge, and the ordered channel already uses the
 * same cross-package global convention (`__PDSH_CHANNEL__`).
 */
export const WORKER_VFS_FLUSH_GLOBAL = '__PDSH_VFS_FLUSH__'

/** Structural shape of the global `worker-entry` installs. */
interface WorkerVfsFlushGlobal {
  readonly [WORKER_VFS_FLUSH_GLOBAL]?: () => Promise<void> | void
}

/**
 * Flush the Worker VFS sink and wait for its level-1 acknowledgement.
 *
 * A missing hook means this process does not run a Worker VFS (desktop
 * transport, unit test without the entry): there is nothing to fence. A hook
 * that rejects means the sink refused a mutation or the channel is gone; the
 * caller must surface that as the command's failure rather than reporting
 * success for writes the host does not have.
 * @returns a promise that resolves once the last emitted mutation is acked.
 */
export async function flushWorkerVfs(): Promise<void> {
  const flush = (globalThis as unknown as WorkerVfsFlushGlobal)[WORKER_VFS_FLUSH_GLOBAL]
  if (typeof flush !== 'function') return
  await flush()
}
