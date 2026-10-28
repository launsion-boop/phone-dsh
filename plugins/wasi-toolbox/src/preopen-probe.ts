// SPDX-License-Identifier: MIT
/**
 * The guest-side preopen verification shared by both tool workers.
 *
 * The async control-plane probe can answer while the blocking channel a WASI
 * syscall actually uses is dead (G2-FIX-54), so after `init` each worker walks
 * the same roots through the synchronous client — the exact path `stat` takes
 * — and reports `sync-preopens` to the host, which treats it as authoritative
 * for the file view. The two workers (generic WASI and the CPython bundle) had
 * separate copies of this loop; one implementation keeps their answer shape
 * and timeout behaviour identical.
 * @module @phone-dsh/dsh-wasi-toolbox/preopen-probe
 */
import type { GuestPreopen } from './types.ts'
import type { SyncVfsClient } from './vfs-client.ts'

/**
 * Probe every preopen root through the synchronous VFS and post the result.
 *
 * A worker without a synchronous channel (the snapshot fallback) skips this:
 * its file view is verified by the host from the captured snapshot instead.
 * @param client - Blocking VFS client, or undefined when the host has none.
 * @param program - Program name echoed in the message.
 * @param preopens - Roots to verify.
 * @param post - Worker scope's postMessage.
 */
export function probeSynchronousPreopens(
  client: SyncVfsClient | undefined,
  program: string,
  preopens: readonly GuestPreopen[],
  post: (message: unknown) => void,
): void {
  if (client === undefined) return
  const present: string[] = []
  const missing: string[] = []
  const errors: string[] = []
  for (const preopen of preopens) {
    try {
      const value = client.call({ op: 'stat', path: preopen.hostPath })
      if (value.kind === 'stat') present.push(preopen.guestPath)
      else missing.push(preopen.guestPath)
    } catch (error) {
      missing.push(preopen.guestPath)
      errors.push(error instanceof Error ? error.message : String(error))
    }
  }
  post({
    type: 'sync-preopens',
    program,
    present,
    missing,
    ...(errors.length === 0 ? {} : { error: errors.join('; ') }),
  })
}
