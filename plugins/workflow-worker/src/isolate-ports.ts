// SPDX-License-Identifier: MIT
/**
 * Message-port bootstrap for the dedicated workflow isolate.
 *
 * The browser path must capture `postMessage`/`addEventListener` **before**
 * `hideHostGlobals()` removes the ambient globals: an unbound closure that
 * looks them up lazily would silently drop every message once the global is
 * undefined. The Node image-boot harness uses `worker_threads.parentPort`,
 * whose methods do not depend on the hidden globals.
 * @module @phone-dsh/dsh-workflow-worker/isolate-ports
 */

/** A minimal message port over either a Web Worker or `node:worker_threads`. */
export interface IsolatePort {
  send(message: unknown): void
  onMessage(listener: (message: unknown) => void): void
}

/** Structural subset of a Worker global used by {@link openPort}. */
export interface IsolateScope {
  postMessage?: (message: unknown) => void
  addEventListener?: (type: string, listener: (event: { readonly data: unknown }) => void) => void
}

/** Structural `worker_threads` face reached without a static node import. */
interface WorkerThreadsFace {
  readonly parentPort?: {
    postMessage(message: unknown): void
    on(type: 'message', listener: (message: unknown) => void): void
  }
}

/**
 * Capture the ambient message port once, before host globals are hidden.
 * @param scope - Worker global (tests pass a fake object).
 * @returns the live message port.
 */
export function openPort(scope: IsolateScope = globalThis as unknown as IsolateScope): IsolatePort {
  const add = scope.addEventListener
  const post = scope.postMessage
  if (typeof add === 'function' && typeof post === 'function') {
    // Bind now: hideHostGlobals() overwrites the global properties later.
    const send = post.bind(scope)
    const listen = add.bind(scope)
    return {
      send: (message) => { send(message) },
      onMessage: (listener) => { listen('message', event => listener(event.data)) },
    }
  }
  const host = process as unknown as { getBuiltinModule?: (name: string) => unknown }
  const threads = host.getBuiltinModule?.('node:worker_threads') as WorkerThreadsFace | undefined
  if (threads?.parentPort === undefined) throw new Error('workflow isolate: no Worker message port')
  const parent = threads.parentPort
  return {
    send: (message) => { parent.postMessage(message) },
    onMessage: (listener) => { parent.on('message', listener) },
  }
}

/**
 * Remove ambient host capabilities from the isolate's global.
 *
 * The workflow script itself never runs here — it runs in the QuickJS realm —
 * so this is defence in depth for the trusted host half, not the script
 * sandbox. We still hide the capability globals so a bug in the bridge cannot
 * accidentally read a parent credential or open a network request from the
 * isolate's own realm.
 * @param scope - Worker global (tests pass a fake object).
 */
export function hideHostGlobals(scope: Record<string, unknown> = globalThis as unknown as Record<string, unknown>): void {
  const denied = [
    'fetch', 'process', 'self', 'postMessage', 'onmessage', 'Worker', 'SharedWorker',
    'WebSocket', 'XMLHttpRequest', 'EventSource', 'WebTransport', 'importScripts', 'close',
    'require', 'module', 'exports', 'console', 'location', 'navigator', 'crypto', 'caches',
    'indexedDB', 'BroadcastChannel', 'MessageChannel', 'MessagePort',
  ]
  for (const name of denied) {
    try {
      Object.defineProperty(scope, name, { value: undefined, writable: false, configurable: true })
    } catch {
      // A non-configurable platform global remains, but carries no parent data.
    }
  }
}
