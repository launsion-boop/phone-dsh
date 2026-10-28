// SPDX-License-Identifier: MIT
/**
 * Bundle surface for the bounded-directory integration test.
 *
 * The test bundles this file with the pinned runtime source, redirecting
 * `node:fs` to the runtime's VFS bridge. Exporting the real `MemoryVfs`, the
 * real promise face, the namespace policy, the bounded opener and the Worker
 * command capture proves the production composition instead of a test double.
 * @module @phone-dsh/dsh-tests/fixtures/bounded-opendir-runtime
 */
// The ambient runtime declaration only names the members the Worker entry
// calls, and `MemoryVfs` is not one of them. The esbuild alias resolves this
// source path; cast the namespace so the fixture exports the real class.
import * as runtimeMemory from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/memory.ts'

export const MemoryVfs = (runtimeMemory as unknown as { MemoryVfs: new () => unknown }).MemoryVfs
export { setActiveVfs } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/active.ts'
export { promises as runtimeFsPromises } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/fs.ts'
export {
  EXEC_INTERNAL_ROOTS,
  WORKER_VFS_NAMESPACE,
  installExecFsPolicy,
} from '../../wasi-toolbox/src/vfs-namespace.ts'
export {
  WORKER_BOUNDED_DIRECTORY_MATERIALIZATION,
  WORKER_BOUNDED_OPENDIR_MANIFEST_PATH,
  WORKER_BOUNDED_OPENDIR_MAX_ENTRIES,
  WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER,
  WORKER_COMMAND_BOUNDED_OPENDIR,
  installBoundedDirectoryOpener,
} from '../../worker-entry/src/bounded-opendir.ts'
export {
  WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER as SURFACE_BOUNDED_DIRECTORY_OPENER,
  WORKER_COMMAND_BOUNDED_OPENDIR as SURFACE_BOUNDED_OPENDIR,
  WORKER_COMMAND_MAX_SNAPSHOT_ENTRIES,
  captureWorkerVfsFork,
  executeWorkerCommandInFork,
  validateWorkerCommandRequest,
} from '../../surface-phone/src/worker-command-controller.js'
