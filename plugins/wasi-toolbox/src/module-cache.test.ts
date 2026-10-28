// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { MessageChannel } from 'node:worker_threads'
import type { MessagePort } from 'node:worker_threads'
import type { MessageEndpoint } from './message-endpoint.ts'
import { ModuleCache } from './module-cache.ts'

const moduleBytes = readFileSync(new URL('./testdata/fd-echo.wasm', import.meta.url))
const emptyModule = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])

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

test('module cache: one load and one compile per URL, shared by every caller', async () => {
  let loads = 0
  let compiles = 0
  const cache = new ModuleCache({
    compile: async bytes => {
      compiles += 1
      return new WebAssembly.Module(new Uint8Array(bytes).buffer)
    },
  })
  const source = {
    url: 'image://fd-echo.wasm',
    load: async () => {
      loads += 1
      return moduleBytes
    },
  }
  const [first, second, third] = await Promise.all([
    cache.getModule(source),
    cache.getModule(source),
    cache.getModule(source),
  ])
  assert.equal(loads, 1)
  assert.equal(compiles, 1)
  assert.equal(first, second)
  assert.equal(second, third)
  assert.equal(await cache.getModule(source), first)
  assert.deepEqual(cache.stats(), { modules: 1, compiles: 1 })
})

test('module cache: a failed compile can be retried', async () => {
  let attempts = 0
  const cache = new ModuleCache({
    compile: async bytes => {
      attempts += 1
      if (attempts === 1) throw new Error('transient compile failure')
      return new WebAssembly.Module(new Uint8Array(bytes).buffer)
    },
  })
  const source = { url: 'image://retry.wasm', load: async () => moduleBytes }
  await assert.rejects(cache.getModule(source), /transient/)
  const module = await cache.getModule(source)
  assert.equal(attempts, 2)
  assert.ok(module instanceof WebAssembly.Module)
})

test('module cache: a compiled Module crosses a MessageChannel by structured clone', async () => {
  const cache = new ModuleCache()
  await cache.compile('image://empty.wasm', async () => emptyModule)
  const { port1, port2 } = new MessageChannel()
  const received = new Promise<{ type: string; url: string; module: WebAssembly.Module }>(resolve => {
    port2.once('message', message => { resolve(message as { type: string; url: string; module: WebAssembly.Module }) })
  })
  cache.share(portEndpoint(port1), 'image://empty.wasm')
  const message = await received
  port1.close()
  port2.close()
  assert.equal(message.type, 'wasm-module')
  assert.equal(message.url, 'image://empty.wasm')
  assert.ok(message.module instanceof WebAssembly.Module)
  // The clone is executable on the receiving side without recompiling bytes.
  assert.ok(new WebAssembly.Instance(message.module) instanceof WebAssembly.Instance)
})

test('module cache: sharing an uncached URL is an error', () => {
  const cache = new ModuleCache()
  const { port1, port2 } = new MessageChannel()
  assert.throws(() => cache.share(portEndpoint(port1), 'image://missing.wasm'), /not cached/)
  port1.close()
  port2.close()
})
