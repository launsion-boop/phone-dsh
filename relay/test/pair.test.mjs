// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import {
  connectClient,
  createIdentity,
  delay,
  randomSid,
  startRelay,
  waitFor,
} from './helpers.mjs'

async function pairClients(t, relay, overrides = {}) {
  const pcIdentity = createIdentity()
  const phoneIdentity = createIdentity()
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })
  const { client: phone } = await connectClient({ relay, identity: phoneIdentity, role: 'phone' })
  t.after(() => {
    pc.close()
    phone.close()
  })
  if (overrides.allow !== false) {
    pc.send({ v: 1, type: 'relay.allow', peers: [phoneIdentity.machineId] })
  }
  return { pc, phone, pcIdentity, phoneIdentity }
}

test('pair open/join/joined/message/close uses opaque rendezvous and forwards payloads', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { pc, phone, pcIdentity, phoneIdentity } = await pairClients(t, relay)
  const rendezvous = 'B'.repeat(22) // deliberately not a canonical 16-byte b64url

  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  assert.equal(await pc.expectNoMessage('relay.pair.joined', 50), true)
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  const joinedPc = await pc.next('relay.pair.joined')
  const joinedPhone = await phone.next('relay.pair.joined')
  assert.deepEqual(joinedPc, {
    v: 1,
    type: 'relay.pair.joined',
    rendezvous,
    role: 'pc',
    peerMachineId: phoneIdentity.machineId,
  })
  assert.deepEqual(joinedPhone, {
    v: 1,
    type: 'relay.pair.joined',
    rendezvous,
    role: 'phone',
    peerMachineId: pcIdentity.machineId,
  })

  const hello = {
    v: 1,
    type: 'pair.hello',
    role: 'pc',
    nested: { keep: ['exactly', 1, true, null] },
  }
  phone.send({ v: 1, type: 'relay.pair.message', rendezvous, payload: hello })
  const receivedHello = await pc.next('relay.pair.message')
  assert.deepEqual(receivedHello.payload, hello)
  assert.equal(receivedHello.rendezvous, rendezvous)

  const auth = { v: 1, type: 'pair.auth', role: 'phone', opaque: 'ok' }
  pc.send({ v: 1, type: 'relay.pair.message', rendezvous, payload: auth })
  assert.deepEqual((await phone.next('relay.pair.message')).payload, auth)

  pc.send({ v: 1, type: 'relay.pair.close', rendezvous, reason: 'paired' })
  const closed = await phone.next('relay.pair.close')
  assert.equal(closed.rendezvous, rendezvous)
  assert.equal(closed.reason, 'paired')
  assert.equal(relay.slotCount, 0)
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  assert.equal((await phone.next('relay.error')).code, 'rendezvous_expired')
})

test('pairing payload forwarding also consumes the unordered-pair bandwidth bucket', async t => {
  const relay = await startRelay({ pairRateBytesPerSec: 10, pairBurstBytes: 500 })
  t.after(() => relay.close())
  const { pc, phone } = await pairClients(t, relay)
  const rendezvous = 'R'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  await pc.next('relay.pair.joined')
  await phone.next('relay.pair.joined')

  const payload = { data: 'x'.repeat(300) }
  phone.send({ v: 1, type: 'relay.pair.message', rendezvous, payload })
  assert.deepEqual((await pc.next('relay.pair.message')).payload, payload)
  phone.send({ v: 1, type: 'relay.pair.message', rendezvous, payload })
  assert.equal((await phone.next('relay.error')).code, 'rate_limited')
})

test('a pairing slot expires after the configured lifetime', async t => {
  const relay = await startRelay({ pairRendezvousTtlMs: 120 })
  t.after(() => relay.close())
  const { pc, phone } = await pairClients(t, relay)
  const rendezvous = 'C'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  const expiredPc = await pc.next('relay.pair.close')
  assert.equal(expiredPc.reason, 'rendezvous_expired')
  assert.equal(relay.slotCount, 0)

  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  assert.equal((await phone.next('relay.error')).code, 'rendezvous_expired')

  const rendezvous2 = 'D'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous: rendezvous2 })
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous: rendezvous2 })
  await pc.next('relay.pair.joined')
  await phone.next('relay.pair.joined')
  // The expiry is absolute from open, not extended by the join.
  assert.equal((await pc.next('relay.pair.close')).reason, 'rendezvous_expired')
  assert.equal((await phone.next('relay.pair.close')).reason, 'rendezvous_expired')
  assert.equal(relay.slotCount, 0)
})

test('a pairing slot is single-use: a second phone cannot join after the match', async t => {
  const relay = await startRelay({ maxConnectionsPerIp: 100, pairAttemptsPerRendezvous: 2 })
  t.after(() => relay.close())
  const { pc, phone } = await pairClients(t, relay)
  const rendezvous = 'E'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  await pc.next('relay.pair.joined')
  await phone.next('relay.pair.joined')

  const intruderIdentity = createIdentity()
  const { client: intruder } = await connectClient({ relay, identity: intruderIdentity, role: 'phone' })
  t.after(() => intruder.close())
  intruder.send({ v: 1, type: 'relay.pair.join', rendezvous })
  assert.equal((await intruder.next('relay.error')).code, 'rendezvous_exhausted')

  const secondIntruderIdentity = createIdentity()
  const { client: secondIntruder } = await connectClient({ relay, identity: secondIntruderIdentity, role: 'phone' })
  t.after(() => secondIntruder.close())
  secondIntruder.send({ v: 1, type: 'relay.pair.join', rendezvous })
  assert.equal((await secondIntruder.next('relay.error')).code, 'rendezvous_exhausted')
  assert.equal(relay.slots.get(rendezvous).joinAttempts, 2)

  // The first pair is still able to exchange its opaque payload.
  phone.send({ v: 1, type: 'relay.pair.message', rendezvous, payload: { ok: true } })
  assert.deepEqual((await pc.next('relay.pair.message')).payload, { ok: true })
  assert.equal(relay.slotCount, 1)
})

test('a rendezvous accepts at most ten join attempts', async t => {
  const relay = await startRelay({ maxConnectionsPerIp: 100, pairJoinsPerIpPerMinute: 100 })
  t.after(() => relay.close())
  const { pc, phone } = await pairClients(t, relay)
  const rendezvous = 'Q'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  await pc.next('relay.pair.joined')
  await phone.next('relay.pair.joined')
  assert.equal(relay.slots.get(rendezvous).joinAttempts, 1)

  const intruderIdentity = createIdentity()
  const { client: intruder } = await connectClient({ relay, identity: intruderIdentity, role: 'phone' })
  t.after(() => intruder.close())
  for (let attempt = 2; attempt <= 10; attempt += 1) {
    intruder.send({ v: 1, type: 'relay.pair.join', rendezvous })
    assert.equal((await intruder.next('relay.error')).code, 'rendezvous_exhausted')
  }
  assert.equal(relay.slots.get(rendezvous).joinAttempts, 10)
  intruder.send({ v: 1, type: 'relay.pair.join', rendezvous })
  assert.equal((await intruder.next('relay.error')).code, 'rendezvous_exhausted')
  assert.equal(relay.slots.get(rendezvous).joinAttempts, 10)

  // The first successful pairing still owns the slot even after the attempt cap.
  phone.send({ v: 1, type: 'relay.pair.message', rendezvous, payload: { still: true } })
  assert.deepEqual((await pc.next('relay.pair.message')).payload, { still: true })
})

test('two open slots per connection are enforced; a duplicate open is idempotent', async t => {
  const relay = await startRelay({ maxPairSlotsPerConnection: 2 })
  t.after(() => relay.close())
  const { pc } = await pairClients(t, relay, { allow: false })
  const first = 'F'.repeat(22)
  const second = 'G'.repeat(22)
  const third = 'H'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous: first })
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous: second })
  await waitFor(() => relay.slotCount === 2)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous: first })
  assert.equal(await pc.expectNoMessage('relay.error', 80), true)
  assert.equal(relay.slotCount, 2)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous: third })
  assert.equal((await pc.next('relay.error')).code, 'rendezvous_exhausted')
  assert.equal(relay.slotCount, 2)

  pc.send({ v: 1, type: 'relay.pair.close', rendezvous: first, reason: 'cancelled' })
  await waitFor(() => relay.slotCount === 1)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous: third })
  await waitFor(() => relay.slotCount === 2)
})

test('phone cannot open, and a non-participant cannot message or close a slot', async t => {
  const relay = await startRelay({ maxConnectionsPerIp: 100 })
  t.after(() => relay.close())
  const { pc, phone } = await pairClients(t, relay, { allow: false })
  const rendezvous = 'J'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })

  const outsiderIdentity = createIdentity()
  const { client: outsider } = await connectClient({ relay, identity: outsiderIdentity, role: 'phone' })
  t.after(() => outsider.close())
  outsider.send({ v: 1, type: 'relay.pair.message', rendezvous, payload: { x: 1 } })
  assert.equal((await outsider.next('relay.error')).code, 'bad_frame')
  assert.equal((await outsider.waitClose()).code, 1008)

  phone.send({ v: 1, type: 'relay.pair.open', rendezvous: 'K'.repeat(22) })
  assert.equal((await phone.next('relay.error')).code, 'bad_frame')
  assert.equal((await phone.waitClose()).code, 1008)

  const unknown = 'L'.repeat(22)
  const other = await connectClient({ relay, identity: createIdentity(), role: 'phone' })
  t.after(() => other.client.close())
  other.client.send({ v: 1, type: 'relay.pair.join', rendezvous: unknown })
  assert.equal((await other.client.next('relay.error')).code, 'rendezvous_expired')
  other.client.send({ v: 1, type: 'relay.pair.message', rendezvous: unknown, payload: {} })
  assert.equal((await other.client.next('relay.error')).code, 'rendezvous_expired')
})

test('a participant disconnect closes the slot with peer_offline for the other side', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { pc, phone } = await pairClients(t, relay)
  const rendezvous = 'M'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  await pc.next('relay.pair.joined')
  await phone.next('relay.pair.joined')

  phone.close()
  await phone.waitClose()
  const closed = await pc.next('relay.pair.close')
  assert.equal(closed.reason, 'peer_offline')
  assert.equal(relay.slotCount, 0)
})

test('a PC disconnect notifies a joined phone with peer_offline', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { pc, phone } = await pairClients(t, relay)
  const rendezvous = 'N'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
  await pc.next('relay.pair.joined')
  await phone.next('relay.pair.joined')

  pc.close()
  await pc.waitClose()
  assert.equal((await phone.next('relay.pair.close')).reason, 'peer_offline')
  assert.equal(relay.slotCount, 0)
})

test('pair.message before the phone joins is bad_frame', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { pc } = await pairClients(t, relay, { allow: false })
  const rendezvous = 'O'.repeat(22)
  pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
  pc.send({ v: 1, type: 'relay.pair.message', rendezvous, payload: { early: true } })
  assert.equal((await pc.next('relay.error')).code, 'bad_frame')
  assert.equal((await pc.waitClose()).code, 1008)

  // The slot is cleaned up when its owner goes away.
  await delay(50)
  assert.equal(relay.slotCount, 0)
})
