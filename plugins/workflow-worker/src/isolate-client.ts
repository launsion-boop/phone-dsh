// SPDX-License-Identifier: MIT
/**
 * Parent-side transport to the dedicated workflow isolate.
 *
 * Production runs inside the DSH Web Worker, so it creates a nested classic
 * Worker from `workflow-isolate.js` served beside `worker-entry.js`. The Node
 * image-boot harness cannot construct a Web Worker, so it points
 * `PDSH_WORKFLOW_ISOLATE_PATH` at the same built isolate and this module uses
 * `node:worker_threads` there. The isolate always receives only structured
 * messages; no parent global is shared.
 * @module @phone-dsh/dsh-workflow-worker/isolate-client
 */

/** Why an isolate transport ended before the run settled. */
export interface IsolateExit {
  readonly code?: number
  readonly reason?: string
}

/** The narrow message port the engine needs from an isolate transport. */
export interface IsolatePort {
  postMessage(message: unknown): void
  onMessage(listener: (message: unknown) => void): void
  /** A Worker load/init/runtime error that must not escape as an uncaught throw. */
  onError(listener: (error: Error) => void): void
  /** A Worker exit before the parent observed `done`/`fatal`. */
  onExit(listener: (exit: IsolateExit) => void): void
  terminate(): Promise<void>
}

/** Browser Worker face this module uses without importing DOM lib types. */
interface BrowserWorker {
  postMessage(message: unknown): void
  addEventListener(type: 'message', listener: (event: { readonly data: unknown }) => void): void
  onerror: ((event: BrowserWorkerErrorEvent) => void) | null
  terminate(): void
}

/** The subset of a browser Worker error event the parent needs. */
interface BrowserWorkerErrorEvent {
  readonly message?: unknown
  readonly filename?: unknown
  readonly lineno?: unknown
  readonly colno?: unknown
  readonly error?: unknown
  preventDefault?(): void
}

/** Node worker_threads face, reached only outside a Worker global. */
interface NodeWorker {
  postMessage(message: unknown): void
  on(type: 'message', listener: (message: unknown) => void): void
  on(type: 'error', listener: (error: unknown) => void): void
  on(type: 'exit', listener: (code: number) => void): void
  terminate(): Promise<number>
}

/** Structural process face for the Node harness fallback. */
interface ProcessFace {
  readonly env?: Readonly<Record<string, string | undefined>>
  getBuiltinModule?: (name: string) => unknown
}

/**
 * Build the parent transport for one workflow run.
 *
 * A fresh isolate is created per run so a terminated synchronous loop can never
 * poison the next workflow. Children remain in the parent and are disposed
 * separately.
 * @returns a message port to the isolate.
 */
export function createDefaultIsolatePort(): IsolatePort {
  const scope = globalThis as unknown as {
    Worker?: new (url: URL | string, options?: { type?: 'module' }) => BrowserWorker
    location?: { href?: string }
  }
  if (typeof scope.Worker === 'function') {
    const href = scope.location?.href
    if (typeof href !== 'string' || href === '') {
      throw new Error('workflow-worker: no Worker location to resolve workflow-isolate.js')
    }
    const worker = new scope.Worker(new URL('workflow-isolate.js', href), { type: 'module' })
    return {
      postMessage: (message) => { worker.postMessage(message) },
      onMessage: (listener) => { worker.addEventListener('message', event => listener(event.data)) },
      onError: (listener) => {
        worker.onerror = (event) => {
          // The parent owns the failure result; do not also report it as an
          // uncaught browser Worker error.
          event.preventDefault?.()
          const detail = typeof event.message === 'string' && event.message !== ''
            ? event.message
            : event.error instanceof Error ? event.error.message : 'workflow isolate failed'
          const where = typeof event.filename === 'string' && event.filename !== ''
            ? ` (${event.filename}${typeof event.lineno === 'number' ? `:${String(event.lineno)}` : ''})`
            : ''
          listener(event.error instanceof Error ? event.error : new Error(`${detail}${where}`))
        }
      },
      // A browser Worker has no exit event; the parent watchdog covers a Worker
      // that vanishes without a message.
      onExit: () => {},
      terminate: async () => { worker.terminate() },
    }
  }
  const host = process as unknown as ProcessFace
  const path = host.env?.PDSH_WORKFLOW_ISOLATE_PATH
  if (typeof path !== 'string' || path === '') {
    throw new Error(
      'workflow-worker: no Worker global and PDSH_WORKFLOW_ISOLATE_PATH is unset; '
      + 'build workflow-isolate.js beside worker-entry.js or point the Node harness at it',
    )
  }
  const threads = host.getBuiltinModule?.('node:worker_threads') as {
    Worker?: new (filename: string) => NodeWorker
  } | undefined
  if (threads?.Worker === undefined) throw new Error('workflow-worker: node:worker_threads is unavailable')
  const worker = new threads.Worker(path)
  return {
    postMessage: (message) => { worker.postMessage(message) },
    onMessage: (listener) => { worker.on('message', listener) },
    onError: (listener) => {
      worker.on('error', (error: unknown) => {
        listener(error instanceof Error ? error : new Error(String(error)))
      })
    },
    onExit: (listener) => {
      worker.on('exit', (code: number) => { listener({ code }) })
    },
    terminate: async () => { await worker.terminate() },
  }
}
