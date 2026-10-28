// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { decodeUtf8, encodeUtf8 } from './bytes.ts'
import {
  HostHelloTimeoutError, acceleratorsFromCaps, hostAccelerators, makeHostHello,
  parseHostHello, waitForHostHello,
} from './host-hello.ts'
import type { ChannelClient, HelloHostPayload } from './index.ts'

const here = dirname(fileURLToPath(import.meta.url))
const goldenRoot = join(here, '../../../spec/v1/golden')

test('parses the golden host HELLO and exposes the advertised accelerators', () => {
  const golden = JSON.parse(readFileSync(join(goldenRoot, 'frames/hello-host-1.json'), 'utf8')) as {
    payload_hex: string
    fields: Record<string, unknown>
  }
  const hello = parseHostHello(Buffer.from(golden.payload_hex, 'hex'))
  assert.equal(hello.proto, 1)
  assert.equal(hello.role, 'host')
  assert.equal(hello.boot_id, '00112233445566778899aabbccddeeff')
  assert.equal(hello.session_epoch, 7n)
  assert.deepEqual(hello.fence, { owner: 'phone', generation: 3n, wal_seq: 41n })
  assert.equal(hello.next_mseq, 42n)
  assert.equal(hello.acked_mseq, 41n)
  assert.equal(hello.durable_mseq, 40n)
  assert.deepEqual(hostAccelerators(hello), ['rg', 'jaq'])
})

test('advertised caps are only accelerator: entries, de-duplicated and in order', () => {
  assert.deepEqual(acceleratorsFromCaps(undefined), [])
  assert.deepEqual(acceleratorsFromCaps(['channel/1', 'wal/1', 'exec/1']), [])
  assert.deepEqual(acceleratorsFromCaps([
    'channel/1', 'accelerator:rg', 'wal/1', 'accelerator:jaq', 'accelerator:rg', 'accelerator:',
  ]), ['rg', 'jaq'])
})

test('a host HELLO without a required capability is a protocol mismatch', () => {
  const body = {
    proto: 1,
    role: 'host',
    boot_id: '00112233445566778899aabbccddeeff',
    session_epoch: 7,
    fence: { owner: 'phone', generation: 3, wal_seq: 41 },
    caps: ['channel/1', 'wal/1'],
    next_mseq: 42,
    acked_mseq: 41,
    durable_mseq: 40,
  }
  assert.throws(
    () => parseHostHello(encodeUtf8(JSON.stringify(body))),
    /lacks required capability exec\/1/,
  )
})

test('waitForHostHello waits for the first HELLO and returns later refreshes immediately', async () => {
  let current: HelloHostPayload | undefined
  const listeners = new Set<(hello: HelloHostPayload) => void>()
  const channel = {
    get hostHello() { return current },
    onHostHello(handler: (hello: HelloHostPayload) => void) {
      listeners.add(handler)
      return () => { listeners.delete(handler) }
    },
  } as Pick<ChannelClient, 'hostHello' | 'onHostHello'>
  const waiting = waitForHostHello(channel, 1_000)
  current = makeHostHello({ caps: ['accelerator:rg'] })
  for (const listener of [...listeners]) listener(current)
  const hello = await waiting
  assert.deepEqual(hostAccelerators(hello), ['rg'])
  // A second call sees the cached HELLO and never subscribes.
  assert.equal(await waitForHostHello(channel, 1), hello)
})

test('waitForHostHello times out instead of guessing an accelerator set', async () => {
  const channel = {
    hostHello: undefined,
    onHostHello: () => () => {},
  } as unknown as Pick<ChannelClient, 'hostHello' | 'onHostHello'>
  await assert.rejects(waitForHostHello(channel, 5), HostHelloTimeoutError)
})

test('waitForHostHello honors an abort signal', async () => {
  const channel = {
    hostHello: undefined,
    onHostHello: () => () => {},
  } as unknown as Pick<ChannelClient, 'hostHello' | 'onHostHello'>
  const controller = new AbortController()
  const waiting = waitForHostHello(channel, 10_000, controller.signal)
  controller.abort(new Error('cancelled'))
  await assert.rejects(waiting, /cancelled/)
})
