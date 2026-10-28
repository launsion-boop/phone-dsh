// SPDX-License-Identifier: MIT
/**
 * Entry point of the dedicated WASI tool worker. The DSH worker spawns this
 * module as a Worker; it installs the toolbox runtime on its own global scope.
 * @module @phone-dsh/dsh-wasi-toolbox/tool-worker
 */
import { installToolWorker } from './tool-worker-runtime.ts'
import { resolveWorkerScope } from './worker-scope.ts'

installToolWorker(resolveWorkerScope())
