// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import { ipKey, isTrustedIp, parseTrustedProxies } from '../src/net-util.mjs'
import {
  connectClient,
  createIdentity,
  e2eFrame,
  handshakeFrame,
  openClient,
  randomSid,
  startRelay,
} from './helpers.mjs'

test('per-IP connection limit rejects before auth with rate_limited/4003', async t => {
  const relay = await startRelay({ maxConnectionsPerIp: 2 })
  t.after(() => relay.close())
  const first = openClient({ relay })
  const second = openClient({ relay })
  t.after(() => {
    first.close()
    second.close()
  })
  await first.next('relay.challenge')
  await second.next('relay.challenge')

  const third = openClient({ relay })
  const error = await third.next('relay.error')
  assert.equal(error.code, 'rate_limited')
  assert.equal(typeof error.retryAfterMs, 'number')
  assert.equal((await third.waitClose()).code, 4003)
})

test('IPv6 per-IP limits aggregate by /64 and XFF is trusted only when configured', async t => {
  assert.equal(ipKey('2001:db8:1:2::1'), ipKey('2001:db8:1:2::ffff'))
  assert.notEqual(ipKey('2001:db8:1:2::1'), ipKey('2001:db8:1:3::1'))

  const proxies = parseTrustedProxies('10.0.0.0/8,2001:db8::/32')
  assert.equal(isTrustedIp('10.1.2.3', proxies), true)
  assert.equal(isTrustedIp('11.0.0.1', proxies), false)
  assert.equal(isTrustedIp('2001:db8:ffff::1', proxies), true)
  assert.equal(isTrustedIp('2001:db9::1', proxies), false)

  const trusted = await startRelay({ maxConnectionsPerIp: 1, trustedProxies: ['127.0.0.1'] })
  t.after(() => trusted.close())
  const same64a = openClient({ relay: trusted, headers: { 'x-forwarded-for': '2001:db8:1:2::1' } })
  await same64a.next('relay.challenge')
  const same64b = openClient({ relay: trusted, headers: { 'x-forwarded-for': '2001:db8:1:2::2' } })
  const limited = await same64b.next('relay.error')
  assert.equal(limited.code, 'rate_limited')
  await same64b.waitClose()
  same64a.close()
  await same64a.waitClose()
  await new Promise(resolve => setTimeout(resolve, 50))

  const other64 = openClient({ relay: trusted, headers: { 'x-forwarded-for': '2001:db8:1:3::1' } })
  t.after(() => other64.close())
  await other64.next('relay.challenge')

  const untrusted = await startRelay({ maxConnectionsPerIp: 1 })
  t.after(() => untrusted.close())
  const spoofA = openClient({ relay: untrusted, headers: { 'x-forwarded-for': '2001:db8:2::1' } })
  await spoofA.next('relay.challenge')
  const spoofB = openClient({ relay: untrusted, headers: { 'x-forwarded-for': '2001:db8:2::2' } })
  assert.equal((await spoofB.next('relay.error')).code, 'rate_limited')
  await spoofB.waitClose()
  spoofA.close()
  await spoofA.waitClose()
})

test('per-machineId-pair bandwidth bucket drops excess frames but keeps the connection', async t => {
  const relay = await startRelay({
    pairRateBytesPerSec: 20,
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

  for (let index = 0; index < 2; index += 1) {
    phone.send(e2eFrame({
      from: phoneIdentity.machineId,
      to: pcIdentity.machineId,
      sid: randomSid(),
      seq: index,
    }))
    assert.equal((await pc.next('e2e')).seq, index)
  }
  phone.send(e2eFrame({
    from: phoneIdentity.machineId,
    to: pcIdentity.machineId,
    sid: randomSid(),
    seq: 2,
  }))
  const error = await phone.next('relay.error')
  assert.equal(error.code, 'rate_limited')
  assert.equal(typeof error.retryAfterMs, 'number')
  assert.ok(error.retryAfterMs > 0)

  phone.send({ v: 1, type: 'relay.ping', nonce: 'A'.repeat(22) })
  assert.equal((await phone.next('relay.pong')).nonce, 'A'.repeat(22))
})

test('per-machineId daily quota drops excess frames but keeps the connection', async t => {
  const relay = await startRelay({
    dailyBytesPerMachine: 300,
    pairRateBytesPerSec: 10_000_000,
    pairBurstBytes: 10_000_000,
    maxConnectionsPerIp: 100,
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

  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: randomSid() }))
  await pc.next('e2e')
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: randomSid() }))
  const error = await phone.next('relay.error')
  assert.equal(error.code, 'rate_limited')
  assert.ok(error.retryAfterMs > 0)
  phone.send({ v: 1, type: 'relay.ping', nonce: 'A'.repeat(22) })
  assert.equal((await phone.next('relay.pong')).nonce, 'A'.repeat(22))
})

test('e2e.handshake source bucket is separate and rate-limits only handshake frames', async t => {
  const relay = await startRelay({
    handshakeFramesPerSourcePerMinute: 3,
    maxConnectionsPerIp: 100,
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

  phone.send(handshakeFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId }))
  await pc.next('e2e.handshake')
  phone.send(handshakeFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId }))
  const error = await phone.next('relay.error')
  assert.equal(error.code, 'rate_limited')

  // Application e2e is not part of the handshake bucket.
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: randomSid() }))
  await pc.next('e2e')
})

test('e2e.handshake target bucket prevents one PC from being flooded through the bypass', async t => {
  const relay = await startRelay({
    handshakeFramesPerTargetPerMinute: 3,
    maxConnectionsPerIp: 100,
  })
  t.after(() => relay.close())
  const pcIdentity = createIdentity()
  const phone1 = createIdentity()
  const phone2 = createIdentity()
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })
  const { client: first } = await connectClient({ relay, identity: phone1, role: 'phone' })
  const { client: second } = await connectClient({ relay, identity: phone2, role: 'phone' })
  t.after(() => {
    pc.close()
    first.close()
    second.close()
  })
  pc.send({ v: 1, type: 'relay.allow', peers: [] })

  first.send(handshakeFrame({ from: phone1.machineId, to: pcIdentity.machineId }))
  await pc.next('e2e.handshake')
  second.send(handshakeFrame({ from: phone2.machineId, to: pcIdentity.machineId }))
  assert.equal((await second.next('relay.error')).code, 'rate_limited')
  assert.equal(await pc.expectNoMessage('e2e.handshake'), true)
})

test('pairing joins are rate-limited per source IP', async t => {
  const relay = await startRelay({
    pairJoinsPerIpPerMinute: 2,
    maxConnectionsPerIp: 100,
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
  const rendezvous = 'B'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  assert.equal((await pc.next('relay.pair.joined')).peerMachineId, phoneIdentity.machineId)
  assert.equal((await phone.next('relay.pair.joined')).peerMachineId, pcIdentity.machineId)

  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  await phone.next('relay.pair.joined')
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  assert.equal((await phone.next('relay.error')).code, 'rate_limited')
})
