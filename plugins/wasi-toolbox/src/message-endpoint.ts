// SPDX-License-Identifier: MIT
/**
 * Message plumbing shared by the DSH worker (server) and the tool worker
 * (client). A `MessageEndpoint` hides whether the transport is a browser
 * `Worker`, a Node worker thread, or a test `MessagePort`; the VFS proxy and
 * the toolbox control channel both speak through it.
 * @module @phone-dsh/dsh-wasi-toolbox/message-endpoint
 */

/** Minimal bidirectional message port used across the toolbox. */
export interface MessageEndpoint {
  postMessage(message: unknown): void
  /** Register a handler and return its disposer. */
  onMessage(handler: (message: unknown) => void): () => void
}

/** Structural face of a browser `Worker` or a Node `worker_threads.Worker`. */
export interface WorkerLike {
  postMessage(message: unknown): void
  addEventListener?(type: 'message' | 'error', listener: (event: unknown) => void): void
  removeEventListener?(type: 'message' | 'error', listener: (event: unknown) => void): void
  on?(type: 'message' | 'error', listener: (data: unknown) => void): void
  off?(type: 'message' | 'error', listener: (data: unknown) => void): void
  terminate?(): unknown
}

function unwrapMessage(value: unknown): unknown {
  if (typeof value === 'object' && value !== null && 'data' in value) {
    const event = value as { data?: unknown; type?: unknown; target?: unknown }
    // Browser MessageEvent carries the payload in `data`; Node's EventEmitter
    // passes the payload itself.
    if (event.type === 'message' || (typeof MessageEvent !== 'undefined' && value instanceof MessageEvent)) {
      return event.data
    }
  }
  return value
}

/** Wrap a Worker-like transport as a `MessageEndpoint`. */
export function workerEndpoint(worker: WorkerLike): MessageEndpoint {
  return {
    postMessage: message => { worker.postMessage(message) },
    onMessage(handler) {
      if (typeof worker.addEventListener === 'function') {
        const listener = (event: unknown): void => { handler(unwrapMessage(event)) }
        worker.addEventListener('message', listener)
        return () => { worker.removeEventListener?.('message', listener) }
      }
      if (typeof worker.on === 'function') {
        const listener = (data: unknown): void => { handler(unwrapMessage(data)) }
        worker.on('message', listener)
        return () => { worker.off?.('message', listener) }
      }
      throw new TypeError('worker has neither addEventListener nor on')
    },
  }
}

/** A Worker-like plus the hooks the toolbox needs for cancel and crash. */
export interface ToolWorkerTransport extends MessageEndpoint {
  terminate(): void | Promise<void>
  onError?(handler: (error: Error) => void): () => void
}

/** Wrap a Worker-like as a terminable toolbox transport. */
export function workerTransport(worker: WorkerLike): ToolWorkerTransport {
  const endpoint = workerEndpoint(worker)
  return {
    ...endpoint,
    async terminate(): Promise<void> {
      if (typeof worker.terminate === 'function') await worker.terminate()
    },
    onError(handler: (error: Error) => void): () => void {
      if (typeof worker.addEventListener === 'function') {
        const listener = (event: unknown): void => {
          const value = (event as { error?: unknown; message?: unknown }).error
            ?? (event as { message?: unknown }).message
          handler(value instanceof Error ? value : new Error(String(value ?? 'worker error')))
        }
        worker.addEventListener('error', listener)
        return () => { worker.removeEventListener?.('error', listener) }
      }
      if (typeof worker.on === 'function') {
        const listener = (error: unknown): void => {
          handler(error instanceof Error ? error : new Error(String(error)))
        }
        worker.on('error', listener)
        return () => { worker.off?.('error', listener) }
      }
      return () => {}
    },
  }
}
