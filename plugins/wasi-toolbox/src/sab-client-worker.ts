// SPDX-License-Identifier: MIT
/**
 * Test worker for the SharedArrayBuffer path: it only speaks the blocking
 * `SyncVfsClient`, so the test proves that a worker thread can perform VFS
 * calls while the server lives on the test thread's event loop.
 */
import { parentPort, workerData } from 'node:worker_threads'
import type { MessagePort } from 'node:worker_threads'
import { SyncVfsClient } from './vfs-client.ts'
import type { MessageEndpoint } from './message-endpoint.ts'

interface SabWorkerData {
  readonly port: MessagePort
  readonly control: SharedArrayBuffer
  readonly request: SharedArrayBuffer
  readonly response: SharedArrayBuffer
  readonly input: string
  readonly output: string
}

const data = workerData as SabWorkerData
const endpoint: MessageEndpoint = {
  postMessage: message => { data.port.postMessage(message) },
  onMessage(handler) {
    const listener = (message: unknown): void => { handler(message) }
    data.port.on('message', listener)
    return () => { data.port.off('message', listener) }
  },
}

try {
  const client = new SyncVfsClient({
    control: data.control,
    request: data.request,
    response: data.response,
    endpoint,
    timeoutMs: 5000,
  })
  const stat = client.call({ op: 'stat', path: data.input })
  const read = client.call({ op: 'read', path: data.input, offset: 0, length: 5 })
  const written = client.call({
    op: 'write',
    path: data.output,
    offset: 0,
    append: false,
    create: true,
    data: new TextEncoder().encode('from-sab'),
  })
  parentPort?.postMessage({
    ok: true,
    kind: stat.kind,
    size: stat.kind === 'stat' ? stat.stat.size : -1,
    text: read.kind === 'data' ? new TextDecoder().decode(read.data) : '',
    written: written.kind === 'written' ? written.written : -1,
  })
} catch (error) {
  parentPort?.postMessage({ ok: false, message: error instanceof Error ? error.message : String(error) })
}
