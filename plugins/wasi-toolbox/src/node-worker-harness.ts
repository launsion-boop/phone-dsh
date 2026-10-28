// SPDX-License-Identifier: MIT
/**
 * Test-only harness: runs the tool worker entry in a Node worker thread by
 * injecting the `parentPort` as the worker scope before importing the entry.
 * Production code never imports `node:worker_threads`; only this file does.
 * @module @phone-dsh/dsh-wasi-toolbox/node-worker-harness
 */
import { parentPort } from 'node:worker_threads'
import type { ToolWorkerScope } from './worker-scope.ts'

const port = parentPort
if (port !== null) {
  const scope: ToolWorkerScope = {
    postMessage: message => { port.postMessage(message) },
    onMessage(handler) {
      const listener = (message: unknown): void => { handler(message) }
      port.on('message', listener)
      return () => { port.off('message', listener) }
    },
    close: () => { port.close() },
  }
  globalThis.__PDSH_TOOL_WORKER_SCOPE__ = scope
}

await import('./tool-worker.ts')
