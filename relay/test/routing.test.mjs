// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import {
  connectClient,
  createIdentity,
  e2eFrame,
  handshakeFrame,
  randomSid,
  startRelay,
} from './helpers.mjs'

async function makeUsers(t, relay) {
  const pc1Identity = createIdentity()
  const phone1Identity = createIdentity()
  const pc2Identity = createIdentity()
  const phone2Identity = createIdentity()
  const connected = []
  for (const [identity, role] of [
    [pc1Identity, 'pc'],
    [phone1Identity, 'phone'],
    [pc2Identity, 'pc'],
    [phone2Identity, 'phone'],
  ]) {
    const { client } = await connectClient({ relay, identity, role })
    connected.push(client)
  }
  t.after(() => {
    for (const client of connected) client.close()
  })
  return {
    pc1: connected[0],
    phone1: connected[1],
    pc2: connected[2],
    phone2: connected[3],
    pc1Identity,
    phone1Identity,
    pc2Identity,
    phone2Identity,
  }
}

test('two users are isolated and the PC allowlist drops non-listed e2e frames', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { pc1, phone1, pc2, phone2, pc1Identity, phone1Identity, pc2Identity, phone2Identity } =
    await makeUsers(t, relay)

  pc1.send({ v: 1, type: 'relay.allow', peers: [phone1Identity.machineId] })
  pc2.send({ v: 1, type: 'relay.allow', peers: [phone2Identity.machineId] })

  const sid1 = randomSid()
  phone1.send(e2eFrame({
    from: 'b'.repeat(26),
    to: pc1Identity.machineId,
    sid: sid1,
    seq: 0,
    body: 'A'.repeat(22),
  }))
  const forwarded = await pc1.next('e2e')
  assert.equal(forwarded.from, phone1Identity.machineId)
  assert.equal(forwarded.to, pc1Identity.machineId)
  assert.equal(forwarded.sid, sid1)
  assert.equal(forwarded.body, 'A'.repeat(22))

  // pc2's allowlist does not contain phone1.
  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: pc2Identity.machineId, sid: randomSid() }))
  assert.equal(await pc2.expectNoMessage('e2e'), true)

  // pc1's allowlist does not contain phone2.
  phone2.send(e2eFrame({ from: phone2Identity.machineId, to: pc1Identity.machineId, sid: randomSid() }))
  assert.equal(await pc1.expectNoMessage('e2e'), true)

  // PC -> phone has no relay allowlist (the phone drops unknown senders
  // locally, §3.3); the relay forwards these.
  pc1.send(e2eFrame({ from: pc1Identity.machineId, to: phone1Identity.machineId, sid: randomSid() }))
  assert.equal((await phone1.next('e2e')).to, phone1Identity.machineId)
  pc1.send(e2eFrame({ from: pc1Identity.machineId, to: phone2Identity.machineId, sid: randomSid() }))
  assert.equal((await phone2.next('e2e')).to, phone2Identity.machineId)

  // The second pair still works end to end.
  phone2.send(e2eFrame({ from: phone2Identity.machineId, to: pc2Identity.machineId, sid: randomSid() }))
  assert.equal((await pc2.next('e2e')).from, phone2Identity.machineId)

  // A phone cannot send relay.allow.
  phone1.send({ v: 1, type: 'relay.allow', peers: [] })
  const error = await phone1.next('relay.error')
  assert.equal(error.code, 'bad_frame')
  assert.equal((await phone1.waitClose()).code, 1008)
})

test('relay.allow replaces the previous list and an empty list drops e2e', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { pc1, phone1, phone2, pc1Identity, phone1Identity, phone2Identity } = await makeUsers(t, relay)

  pc1.send({ v: 1, type: 'relay.allow', peers: [phone1Identity.machineId] })
  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: pc1Identity.machineId, sid: randomSid() }))
  assert.equal((await pc1.next('e2e')).from, phone1Identity.machineId)

  pc1.send({ v: 1, type: 'relay.allow', peers: [phone2Identity.machineId] })
  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: pc1Identity.machineId, sid: randomSid() }))
  assert.equal(await pc1.expectNoMessage('e2e'), true)
  phone2.send(e2eFrame({ from: phone2Identity.machineId, to: pc1Identity.machineId, sid: randomSid() }))
  assert.equal((await pc1.next('e2e')).from, phone2Identity.machineId)

  pc1.send({ v: 1, type: 'relay.allow', peers: [] })
  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: pc1Identity.machineId, sid: randomSid() }))
  assert.equal(await pc1.expectNoMessage('e2e'), true)
  phone1.send({ v: 1, type: 'relay.ping', nonce: 'A'.repeat(22) })
  assert.equal((await phone1.next('relay.pong')).nonce, 'A'.repeat(22))
})

test('relay.offline reports an absent target without queueing', async t => {
  const relay = await startRelay({ maxConnectionsPerIp: 100 })
  t.after(() => relay.close())
  const { phone1, phone1Identity } = await makeUsers(t, relay)
  const missing = 'b'.repeat(26)
  const sid = randomSid()
  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: missing, sid }))
  const offline = await phone1.next('relay.offline')
  assert.equal(offline.to, missing)
  assert.equal(offline.sid, sid)
  assert.equal(offline.id, undefined)
  assert.equal(offline.streamId, undefined)

  phone1.send(handshakeFrame({ from: phone1Identity.machineId, to: missing, sid: randomSid() }))
  const offlineHandshake = await phone1.next('relay.offline')
  assert.equal(offlineHandshake.to, missing)
  assert.equal(typeof offlineHandshake.sid, 'string')

  // Connect a real target after the offline responses: nothing may be queued.
  const lateIdentity = createIdentity()
  const lateSid = randomSid()
  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: lateIdentity.machineId, sid: lateSid }))
  assert.equal((await phone1.next('relay.offline')).to, lateIdentity.machineId)
  const { client: late } = await connectClient({ relay, identity: lateIdentity, role: 'phone' })
  t.after(() => late.close())
  assert.equal(await late.expectNoMessage('e2e', 100), true)
  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: lateIdentity.machineId, sid: randomSid() }))
  assert.equal((await late.next('e2e')).from, phone1Identity.machineId)
})

test('e2e.handshake bypasses the allowlist only for the four handshake body types', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { pc1, phone1, pc1Identity, phone1Identity } = await makeUsers(t, relay)
  pc1.send({ v: 1, type: 'relay.allow', peers: [] })

  const initSid = randomSid()
  phone1.send(handshakeFrame({
    from: phone1Identity.machineId,
    to: pc1Identity.machineId,
    sid: initSid,
    type: 'session.init',
  }))
  const init = await pc1.next('e2e.handshake')
  assert.equal(init.sid, initSid)
  assert.equal(init.body.type, 'session.init')
  assert.equal(init.from, phone1Identity.machineId)

  for (const type of ['session.resp', 'session.confirm', 'session.reject']) {
    phone1.send(handshakeFrame({
      from: phone1Identity.machineId,
      to: pc1Identity.machineId,
      sid: randomSid(),
      type,
    }))
    const forwarded = await pc1.next('e2e.handshake')
    assert.equal(forwarded.body.type, type)
  }

  // Application e2e is still dropped while the allowlist is empty.
  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: pc1Identity.machineId, sid: randomSid() }))
  assert.equal(await pc1.expectNoMessage('e2e'), true)

  // A non-session body is not covered by the bypass.
  phone1.send({
    v: 1,
    type: 'e2e.handshake',
    sid: randomSid(),
    from: phone1Identity.machineId,
    to: pc1Identity.machineId,
    body: { type: 'rpc.call' },
  })
  const error = await phone1.next('relay.error')
  assert.equal(error.code, 'bad_frame')
  assert.equal((await phone1.waitClose()).code, 1008)
})

test('e2e/e2e.handshake reject to=self, malformed shapes and unknown members', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { phone1, phone1Identity } = await makeUsers(t, relay)

  phone1.send(e2eFrame({ from: phone1Identity.machineId, to: phone1Identity.machineId, sid: randomSid() }))
  assert.equal((await phone1.next('relay.error')).code, 'bad_frame')
  assert.equal((await phone1.waitClose()).code, 1008)

  const second = await connectClient({ relay, identity: phone1Identity, role: 'phone' })
  t.after(() => second.client.close())
  second.client.send({
    ...e2eFrame({ from: phone1Identity.machineId, to: 'b'.repeat(26), sid: randomSid() }),
    extra: true,
  })
  assert.equal((await second.client.next('relay.error')).code, 'bad_frame')
  assert.equal((await second.client.waitClose()).code, 1008)

  const third = await connectClient({ relay, identity: phone1Identity, role: 'phone' })
  t.after(() => third.client.close())
  third.client.send(e2eFrame({
    from: phone1Identity.machineId,
    to: 'b'.repeat(26),
    sid: randomSid(),
    seq: 1_048_576,
  }))
  assert.equal((await third.client.next('relay.error')).code, 'bad_frame')
  assert.equal((await third.client.waitClose()).code, 1008)
})
