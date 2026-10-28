// SPDX-License-Identifier: MIT
/**
 * Test-only harness: runs the python tool worker entry in a Node worker thread
 * by injecting `parentPort` as the worker scope before importing the entry.
 * Production code never imports `node:worker_threads`; only tests and this file
 * do.
 * @module @phone-dsh/dsh-wasi-toolbox/python/node-worker-python-harness
 */
import { parentPort, workerData } from 'node:worker_threads'
import type { ToolWorkerScope } from '../src/worker-scope.ts'

interface FakeHttpWorkerConfig {
  /** Loopback origin the transport must target. */
  readonly origin: string
  /** Upstream URL the guest asked for. */
  readonly target: string
  /** Channel bearer the transport must inject. */
  readonly token: string
  /** Response body the fake host route returns. */
  readonly body?: string
}

const fakeHttp = (workerData as { readonly pdshFakeHttp?: FakeHttpWorkerConfig } | null)?.pdshFakeHttp
if (fakeHttp !== undefined) {
  // Test-only stand-in for the production synchronous XMLHttpRequest. It
  // enforces the same `/v1/http` contract the real transport builds so the
  // real-WASI branch proves the whole chain, not just the Python shim.
  class FakeLoopbackXhr {
    status = 0
    statusText = ''
    response: unknown = null
    responseType = ''
    private readonly headers = new Map<string, string>()
    private endpoint = ''

    open(method: string, url: string, async: boolean): void {
      if (method !== 'POST' || async !== false) {
        throw new Error(`fake /v1/http expected a synchronous POST, got ${method} async=${String(async)}`)
      }
      this.endpoint = url
    }

    setRequestHeader(name: string, value: string): void {
      this.headers.set(name.toLowerCase(), value)
    }

    send(body?: Uint8Array | ArrayBuffer | string | null): void {
      const endpoint = new URL('/v1/http', fakeHttp!.origin).href
      if (this.endpoint !== endpoint) {
        throw new Error(`fake /v1/http received ${this.endpoint}, expected ${endpoint}`)
      }
      if (this.headers.get('x-pdsh-target-url') !== fakeHttp!.target) {
        throw new Error(`fake /v1/http target is ${String(this.headers.get('x-pdsh-target-url'))}`)
      }
      if (this.headers.get('x-pdsh-target-method') !== 'GET') {
        throw new Error(`fake /v1/http method is ${String(this.headers.get('x-pdsh-target-method'))}`)
      }
      if (this.headers.get('authorization') !== `Bearer ${fakeHttp!.token}`) {
        throw new Error('fake /v1/http did not receive the injected channel bearer')
      }
      if (body !== null && body !== undefined) {
        throw new Error('fake /v1/http expected the GET request to have no body')
      }
      const responseBody = new TextEncoder().encode(fakeHttp!.body ?? 'real-wasi-through-fake-loopback')
      this.status = 200
      this.statusText = 'OK'
      this.response = responseBody.buffer
    }

    get responseText(): string {
      if (this.status === 0) {
        const error = new Error('the response is not available when status is 0')
        error.name = 'InvalidStateError'
        throw error
      }
      return new TextDecoder().decode(this.response as ArrayBuffer)
    }

    get responseURL(): string {
      return this.endpoint
    }

    getAllResponseHeaders(): string {
      return 'Content-Type: text/plain\r\nX-Fake-Loopback: yes\r\n'
    }
  }

  ;(globalThis as { XMLHttpRequest?: new () => unknown }).XMLHttpRequest = FakeLoopbackXhr
}

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

await import('./tool-worker-python.ts')
