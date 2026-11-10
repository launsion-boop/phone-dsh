// SPDX-License-Identifier: MIT
// Relay hardening regressions: pre-auth frame cap, slow-receiver backpressure,
// bounded daily counters, source-IP HMAC logging and the close-time IP count.
import test from 'node:test'
import assert from 'node:assert/strict'
import { performance } from 'node:perf_hooks'
import { hashPrefix } from '../src/identity.mjs'
import { hashIpForLog } from '../src/logger.mjs'
import { DailyBytes } from '../src/rate-limit.mjs'
import {
  captureLogger,
  connectClient,
  connectRaw,
  createIdentity,
  delay,
  e2eFrame,
  openClient,
  randomSid,
  startRelay,
  waitFor,
} from './helpers.mjs'

test('unauthenticated frames above 4 KiB are frame_too_large before JSON parsing', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { client } = await connectRaw({ relay })
  t.after(() => client.close())

  // Malformed JSON: if the relay parsed before checking the unauthenticated
  // cap it would answer bad_frame; the pre-auth size check must win.
  const started = performance.now()
  client.sendText(`{"v":1,"type":"peer.auth","pad":"${'x'.repeat(8192)}`)
  const error = await client.next('relay.error', 3000)
  const elapsed = performance.now() - started

  assert.equal(error.code, 'frame_too_large')
  assert.equal((await client.waitClose()).code, 1009)
  assert.ok(elapsed < 1000, `pre-auth rejection took ${Math.round(elapsed)} ms`)
})

test('a slow receiver is rate-limited instead of buffering without bound', async t => {
  const relay = await startRelay({
    maxFrameBytes: 8192,
    maxBufferedBytesPerConnection: 8192,
    pairRateBytesPerSec: 100_000_000,
    pairBurstBytes: 100_000_000,
    dailyBytesPerMachine: 1_000_000_000,
    maxConnectionsPerIp: 100,
  })
  const pcIdentity = createIdentity()
  const phoneIdentity = createIdentity()
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })
  const { client: phone } = await connectClient({ relay, identity: phoneIdentity, role: 'phone' })
  t.after(async () => {
    // Resume before close: a paused client would hold the server's closing
    // handshake open for its 30 s timeout and stall the suite.
    pc.ws._socket.resume()
    pc.close()
    phone.close()
    await relay.close()
  })
  pc.send({ v: 1, type: 'relay.allow', peers: [phoneIdentity.machineId] })

  // Do not read from the target socket: the relay's outbound queue cannot
  // drain, so without the buffered-byte cap it would grow without bound.
  pc.ws._socket.pause()
  let limited = false
  const limitedError = phone.next('relay.error', 10_000).then(error => {
    limited = true
    return error
  })
  const body = 'A'.repeat(8000)
  for (let index = 0; index < 2000 && !limited; index += 1) {
    phone.send(e2eFrame({
      from: phoneIdentity.machineId,
      to: pcIdentity.machineId,
      sid: randomSid(),
      seq: index,
      body,
    }))
    if (index % 25 === 0) await delay(0)
  }

  const error = await limitedError
  assert.equal(error.code, 'rate_limited')
  assert.equal(typeof error.retryAfterMs, 'number')
  assert.ok(error.retryAfterMs > 0)
  // The slow target is not closed: only the excess frame is dropped.
  assert.equal(pc.readyState, 1)
  pc.ws._socket.resume()
})

test('relay.pair.message obeys the slow-receiver cap as well', async t => {
  const relay = await startRelay({
    maxFrameBytes: 8192,
    maxBufferedBytesPerConnection: 8192,
    pairRateBytesPerSec: 100_000_000,
    pairBurstBytes: 100_000_000,
    dailyBytesPerMachine: 1_000_000_000,
    maxConnectionsPerIp: 100,
  })
  const pcIdentity = createIdentity()
  const phoneIdentity = createIdentity()
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })
  const { client: phone } = await connectClient({ relay, identity: phoneIdentity, role: 'phone' })
  t.after(async () => {
    pc.ws._socket.resume()
    pc.close()
    phone.close()
    await relay.close()
  })
  const rendezvous = 'C'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  await pc.next('relay.pair.joined')
  await phone.next('relay.pair.joined')

  pc.ws._socket.pause()
  let limited = false
  const limitedError = phone.next('relay.error', 10_000).then(error => {
    limited = true
    return error
  })
  const payload = { data: 'A'.repeat(7000) }
  for (let index = 0; index < 2000 && !limited; index += 1) {
    phone.send({ v: 1, type: 'relay.pair.message', rendezvous, payload })
    if (index % 25 === 0) await delay(0)
  }
  const error = await limitedError
  assert.equal(error.code, 'rate_limited')
  assert.equal(pc.readyState, 1)
  pc.ws._socket.resume()
})

test('one frame above the pair burst is forwarded by overdraft, then rate-limited', async t => {
  const relay = await startRelay({
    pairRateBytesPerSec: 4000,
    pairBurstBytes: 400,
    maxConnectionsPerIp: 100,
    dailyBytesPerMachine: 10_000_000,
  })
  t.after(() => relay.close())
  const pcIdentity = createIdentity()
  const phoneIdentity = createIdentity()
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })
  const { client: phone } = await connectClient({ relay, identity: phoneIdentity, role: 'phone' })
  t.after(() => {
    pc.close()
    phone.close()
  })
  pc.send({ v: 1, type: 'relay.allow', peers: [phoneIdentity.machineId] })

  // The frame is larger than the 400-byte burst; a full bucket may overdraw.
  const body = 'B'.repeat(700)
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: randomSid(), body }))
  assert.equal((await pc.next('e2e')).body, body)

  // The bucket is in debt, so an immediate repeat is limited.
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: randomSid(), body }))
  const limited = await phone.next('relay.error')
  assert.equal(limited.code, 'rate_limited')
  assert.ok(limited.retryAfterMs > 0)
  assert.equal(await pc.expectNoMessage('e2e'), true)

  // The debt refills at 4000 B/s: ~800 bytes of debt is paid back in ~200 ms.
  await delay(300)
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: randomSid(), body }))
  assert.equal((await pc.next('e2e')).body, body)
})

test('DailyBytes caps the machineId map and evicts the oldest counter', () => {
  const day = Date.UTC(2026, 10, 9, 12)
  const counters = new DailyBytes(1_000_000, 2)
  counters.consume('a', 10, day)
  counters.consume('b', 10, day)
  assert.equal(counters.entries.size, 2)

  counters.consume('c', 10, day)
  assert.equal(counters.entries.size, 2)
  assert.equal(counters.entries.has('a'), false)
  assert.equal(counters.entries.has('b'), true)
  assert.equal(counters.entries.has('c'), true)

  // Reusing an existing machineId must not evict another entry.
  counters.consume('b', 5, day)
  assert.equal(counters.entries.size, 2)
  assert.equal(counters.entries.get('b').bytes, 15)

  // A new entry at the cap evicts the oldest (b), not the just-touched c.
  counters.consume('d', 10, day)
  assert.equal(counters.entries.size, 2)
  assert.equal(counters.entries.has('b'), false)
  assert.equal(counters.entries.has('c'), true)
  assert.equal(counters.entries.has('d'), true)
})

test('source-IP log fields use a process-salted HMAC, not plain SHA-256', async t => {
  const capture = captureLogger()
  const relay = await startRelay({ logger: capture.logger, maxConnectionsPerIp: 1 })
  t.after(() => relay.close())
  const first = openClient({ relay })
  await first.next('relay.challenge')
  t.after(() => first.close())

  const second = openClient({ relay })
  const error = await second.next('relay.error')
  assert.equal(error.code, 'rate_limited')
  await second.waitClose()

  const text = capture.text()
  assert.equal(text.includes(hashIpForLog('127.0.0.1')), true)
  assert.equal(text.includes(hashPrefix('127.0.0.1')), false)
})

test('per-IP connection count is released only when the socket really closes', async t => {
  const relay = await startRelay({ maxConnectionsPerIp: 2, authTimeoutMs: 500 })
  t.after(() => relay.close())

  const held = openClient({ relay })
  await held.next('relay.challenge')
  // A paused client cannot read the server's close frame, so terminate() leaves
  // the socket in the closing handshake for up to 30 s.
  held.ws._socket.pause()
  await waitFor(() => relay.connections.size === 0, 2000)

  const second = openClient({ relay })
  await second.next('relay.challenge')
  t.after(() => second.close())

  const third = openClient({ relay })
  t.after(() => third.close())
  const error = await third.next('relay.error')
  assert.equal(error.code, 'rate_limited')
  await third.waitClose()

  // The real socket close releases the held slot; a new connection fits again.
  held.ws._socket.resume()
  held.terminate()
  await delay(200)
  const fourth = openClient({ relay })
  t.after(() => fourth.close())
  await fourth.next('relay.challenge')
})
