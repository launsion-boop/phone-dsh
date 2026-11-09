// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import {
  connectClient,
  createIdentity,
  delay,
  e2eFrame,
  randomSid,
  startRelay,
} from './helpers.mjs'

test('two unanswered relay pings close the connection with unavailable/1001', async t => {
  const relay = await startRelay({
    heartbeatMinMs: 50,
    heartbeatMaxMs: 50,
    phoneIdleMs: 600_000,
  })
  t.after(() => relay.close())
  const identity = createIdentity()
  const { client } = await connectClient({
    relay,
    identity,
    role: 'phone',
    autoPong: false,
  })
  t.after(() => client.close())

  const error = await client.next('relay.error', 3000)
  assert.equal(error.code, 'unavailable')
  assert.equal(error.message, 'heartbeat timeout')
  assert.equal((await client.waitClose()).code, 1001)
})

test('answered heartbeats keep the connection alive; client ping gets a matching pong', async t => {
  const relay = await startRelay({
    heartbeatMinMs: 50,
    heartbeatMaxMs: 50,
    phoneIdleMs: 600_000,
  })
  t.after(() => relay.close())
  const identity = createIdentity()
  const { client } = await connectClient({ relay, identity, role: 'phone' })
  t.after(() => client.close())

  await delay(250)
  assert.equal(client.readyState, 1)
  assert.equal(await client.expectNoMessage('relay.error', 0), true)

  const nonce = 'A'.repeat(22)
  client.send({ v: 1, type: 'relay.ping', nonce })
  assert.equal((await client.next('relay.pong')).nonce, nonce)

  // An unknown pong is ignored rather than closing the connection.
  client.send({ v: 1, type: 'relay.pong', nonce: 'A'.repeat(22) })
  await delay(100)
  assert.equal(client.readyState, 1)
  assert.equal(await client.expectNoMessage('relay.error', 0), true)
})

test('phone idle closes with session_expired/4004; business frames reset the timer', async t => {
  const relay = await startRelay({
    phoneIdleMs: 300,
    heartbeatMinMs: 10_000,
    heartbeatMaxMs: 10_000,
  })
  t.after(() => relay.close())
  const phoneIdentity = createIdentity()
  const pcIdentity = createIdentity()
  const { client: phone } = await connectClient({ relay, identity: phoneIdentity, role: 'phone' })
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })
  t.after(() => {
    phone.close()
    pc.close()
  })

  await delay(150)
  phone.send(e2eFrame({
    from: phoneIdentity.machineId,
    to: 'b'.repeat(26),
    sid: randomSid(),
  }))
  await phone.next('relay.offline')
  // The original 300 ms deadline has passed, but the business frame reset it.
  await delay(250)
  assert.equal(phone.readyState, 1)
  assert.equal(await phone.expectNoMessage('relay.error', 0), true)

  const error = await phone.next('relay.error', 2000)
  assert.equal(error.code, 'session_expired')
  assert.equal((await phone.waitClose()).code, 4004)

  // The PC has no relay idle-close rule.
  await delay(150)
  assert.equal(pc.readyState, 1)
  pc.send({ v: 1, type: 'relay.ping', nonce: 'A'.repeat(22) })
  assert.equal((await pc.next('relay.pong')).nonce, 'A'.repeat(22))
})

test('a business frame forwarded to the phone also resets its idle timer', async t => {
  const relay = await startRelay({
    phoneIdleMs: 400,
    heartbeatMinMs: 10_000,
    heartbeatMaxMs: 10_000,
  })
  t.after(() => relay.close())
  const phoneIdentity = createIdentity()
  const pcIdentity = createIdentity()
  const { client: phone } = await connectClient({ relay, identity: phoneIdentity, role: 'phone' })
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })
  t.after(() => {
    phone.close()
    pc.close()
  })

  // The phone is passive: only the PC sends.  Each forwarded e2e frame must
  // reset the phone's 400 ms idle timer, so the connection stays open well past
  // the original deadline.
  for (let index = 0; index < 4; index += 1) {
    pc.send(e2eFrame({
      from: pcIdentity.machineId,
      to: phoneIdentity.machineId,
      sid: randomSid(),
    }))
    assert.equal((await phone.next('e2e')).from, pcIdentity.machineId)
    await delay(150)
  }
  assert.equal(phone.readyState, 1)
  assert.equal(await phone.expectNoMessage('relay.error', 0), true)

  // Once the PC stops, the idle timer fires normally.
  const error = await phone.next('relay.error', 2000)
  assert.equal(error.code, 'session_expired')
  assert.equal((await phone.waitClose()).code, 4004)
})
