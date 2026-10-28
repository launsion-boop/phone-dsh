// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Worker, MessageChannel } from 'node:worker_threads'
import type { MessagePort } from 'node:worker_threads'
import type { MessageEndpoint } from './message-endpoint.ts'
import { MemoryVfsBackend } from './vfs-backends.ts'
import { VfsProxyServer } from './vfs-server.ts'

function portEndpoint(port: MessagePort): MessageEndpoint {
  return {
    postMessage: message => { port.postMessage(message) },
    onMessage(handler) {
      const listener = (message: unknown): void => { handler(message) }
      port.on('message', listener)
      return () => { port.off('message', listener) }
    },
  }
}

test('vfs SAB path: a blocking client in another thread reads and writes through the proxy', async () => {
  const backend = new MemoryVfsBackend({ clock: () => 1_700_000_000_000 })
  backend.seedFile('/dsh/workspace/in.txt', 'hello world')
  const server = new VfsProxyServer({
    backend,
    preopens: [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }],
  })
  const endpoint = server.createSyncEndpoint(1024 * 1024)
  const { port1, port2 } = new MessageChannel()
  const detach = server.attach(portEndpoint(port1))
  const worker = new Worker(new URL('./sab-client-worker.ts', import.meta.url), {
    workerData: {
      port: port2,
      control: endpoint.control,
      request: endpoint.request,
      response: endpoint.response,
      input: '/dsh/workspace/in.txt',
      output: '/dsh/workspace/out.txt',
    },
    transferList: [port2],
  })
  try {
    const result = await new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => { reject(new Error('SAB client timed out')) }, 10_000)
      worker.once('message', message => {
        clearTimeout(timer)
        resolve(message as Record<string, unknown>)
      })
      worker.once('error', error => {
        clearTimeout(timer)
        reject(error)
      })
    })
    assert.equal(result.ok, true, String(result.message))
    assert.equal(result.kind, 'stat')
    assert.equal(result.size, 11)
    assert.equal(result.text, 'hello')
    assert.equal(result.written, 8)
    assert.equal(new TextDecoder().decode(backend.peek('/dsh/workspace/out.txt')), 'from-sab')
  } finally {
    await worker.terminate()
    detach()
    port1.close()
  }
})
