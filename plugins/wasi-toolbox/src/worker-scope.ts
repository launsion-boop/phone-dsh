// SPDX-License-Identifier: MIT
/**
 * The tool worker's global scope, abstracted so the same runtime source runs in
 * a browser Worker and in the Node worker-thread harness the tests use. The
 * Node harness injects `globalThis.__PDSH_TOOL_WORKER_SCOPE__` before importing
 * the entry; production code never imports `node:worker_threads`.
 * @module @phone-dsh/dsh-wasi-toolbox/worker-scope
 */
import { WasiToolboxError } from './errors.ts'

/** Minimal worker global scope the toolbox runtime needs. */
export interface ToolWorkerScope {
  postMessage(message: unknown): void
  onMessage(handler: (message: unknown) => void): () => void
  close?(): void
}

interface BrowserScopeLike {
  postMessage?: (message: unknown) => void
  addEventListener?: (type: 'message', listener: (event: { data: unknown }) => void) => void
  removeEventListener?: (type: 'message', listener: (event: { data: unknown }) => void) => void
  close?: () => void
}

declare global {
  // eslint-disable-next-line no-var
  var __PDSH_TOOL_WORKER_SCOPE__: ToolWorkerScope | undefined
}

/** The ambient browser Worker global scope. */
export function browserWorkerScope(): ToolWorkerScope {
  const scope = globalThis as BrowserScopeLike
  if (typeof scope.postMessage !== 'function' || typeof scope.addEventListener !== 'function') {
    throw new WasiToolboxError('no worker scope: run this entry in a Web Worker or inject __PDSH_TOOL_WORKER_SCOPE__')
  }
  return {
    postMessage: message => { scope.postMessage!(message) },
    onMessage(handler) {
      const listener = (event: { data: unknown }): void => { handler(event.data) }
      scope.addEventListener!('message', listener)
      return () => { scope.removeEventListener?.('message', listener) }
    },
    ...(typeof scope.close === 'function' ? { close: () => { scope.close!() } } : {}),
  }
}

/** The injected scope (Node tests) or the ambient browser worker scope. */
export function resolveWorkerScope(): ToolWorkerScope {
  const injected = globalThis.__PDSH_TOOL_WORKER_SCOPE__
  return injected ?? browserWorkerScope()
}
