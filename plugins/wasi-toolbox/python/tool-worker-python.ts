// SPDX-License-Identifier: MIT
/**
 * Entry point of the dedicated CPython tool worker. The DSH worker spawns this
 * module as a Worker; it installs the python runtime on its own global scope.
 * @module @phone-dsh/dsh-wasi-toolbox/python/tool-worker-python
 */
import { resolveWorkerScope } from '../src/worker-scope.ts'
import { installPythonToolWorker } from './python-worker-runtime.ts'

installPythonToolWorker(resolveWorkerScope())
