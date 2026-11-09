// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import { decodeB64url } from '../src/base64url.mjs'
import {
  authFrame,
  connectClient,
  connectRaw,
  createIdentity,
  e2eFrame,
  startRelay,
} from './helpers.mjs'

async function errorCode(client, expected) {
  const error = await client.next('relay.error')
  assert.equal(error.code, expected)
  return error
}

test('challenge / peer.auth / relay.ready authenticates with the configured origin', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()
  const { client, challenge, ready } = await connectClient({ relay, identity, role: 'phone' })

  assert.equal(challenge.v, 1)
  assert.equal(challenge.type, 'relay.challenge')
  assert.equal(challenge.relay, relay.origin)
  assert.notEqual(decodeB64url(challenge.nonce, 32), null)
  assert.equal(ready.v, 1)
  assert.equal(ready.type, 'relay.ready')
  assert.equal(ready.machineId, identity.machineId)
  assert.equal(ready.role, 'phone')

  client.close()
  await client.waitClose()
})

test('peer.auth rejects a machineId that is not derived from the presented key', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()
  const { client, challenge } = await connectClient({
    relay,
    identity,
    role: 'phone',
    autoAuth: false,
  })
  const frame = authFrame(identity, 'phone', challenge.relay, challenge.nonce)
  frame.machineId = 'a'.repeat(26)
  client.send(frame)
  await errorCode(client, 'auth_failed')
  const close = await client.waitClose()
  assert.equal(close.code, 4002)
})

test('peer.auth rejects a bad Ed25519 signature', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()
  const { client, challenge } = await connectClient({
    relay,
    identity,
    role: 'phone',
    autoAuth: false,
  })
  const frame = authFrame(identity, 'phone', challenge.relay, challenge.nonce)
  frame.sig = 'A'.repeat(86)
  client.send(frame)
  await errorCode(client, 'auth_failed')
  assert.equal((await client.waitClose()).code, 4002)
})

test('a replayed peer.auth fails on the fresh challenge nonce', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()
  const first = await connectClient({ relay, identity, role: 'phone', autoAuth: false })
  const second = await connectClient({ relay, identity, role: 'phone', autoAuth: false })
  const replay = authFrame(identity, 'phone', first.challenge.relay, first.challenge.nonce)
  second.client.send(replay)
  await errorCode(second.client, 'auth_failed')
  assert.equal((await second.client.waitClose()).code, 4002)
  first.client.close()
  await first.client.waitClose()
})

test('same machineId with a different role is rejected without replacing the live peer', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const pcIdentity = createIdentity()
  const phoneIdentity = createIdentity()
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })

  const conflicting = await connectClient({
    relay,
    identity: pcIdentity,
    role: 'phone',
    autoAuth: false,
  })
  conflicting.client.send(authFrame(pcIdentity, 'phone', conflicting.challenge.relay, conflicting.challenge.nonce))
  await errorCode(conflicting.client, 'auth_failed')
  assert.equal((await conflicting.client.waitClose()).code, 4002)
  assert.equal(relay.peerCount, 1)

  pc.send({ v: 1, type: 'relay.allow', peers: [phoneIdentity.machineId] })
  const { client: phone } = await connectClient({ relay, identity: phoneIdentity, role: 'phone' })
  const sid = 'ODU-xxharZz-k1yXN2XWRA'
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid }))
  const forwarded = await pc.next('e2e')
  assert.equal(forwarded.sid, sid)
  phone.close()
  pc.close()
})

test('a newer same-role connection replaces the old one with replaced/4001', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()
  const first = await connectClient({ relay, identity, role: 'pc' })
  const second = await connectClient({ relay, identity, role: 'pc' })

  const replaced = await first.client.next('relay.error')
  assert.equal(replaced.code, 'replaced')
  const close = await first.client.waitClose()
  assert.equal(close.code, 4001)
  assert.equal(second.ready.machineId, identity.machineId)
  assert.equal(relay.peerCount, 1)
  second.client.close()
  await second.client.waitClose()
})

test('any non-peer.auth frame before relay.ready is bad_frame', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const { client } = await connectRaw({ relay })
  client.send({ v: 1, type: 'relay.ping', nonce: 'A'.repeat(22) })
  await errorCode(client, 'bad_frame')
  assert.equal((await client.waitClose()).code, 1008)
})

test('a second peer.auth after relay.ready is bad_frame', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()
  const { client, challenge } = await connectClient({ relay, identity, role: 'phone' })
  client.send(authFrame(identity, 'phone', challenge.relay, challenge.nonce))
  await errorCode(client, 'bad_frame')
  assert.equal((await client.waitClose()).code, 1008)
})

test('unauthenticated connections are closed with auth_failed after the timeout', async t => {
  const relay = await startRelay({ authTimeoutMs: 80 })
  t.after(() => relay.close())
  const { client } = await connectRaw({ relay })
  await errorCode(client, 'auth_failed')
  assert.equal((await client.waitClose()).code, 4002)
})

test('binary frames and malformed JSON are rejected as bad_frame', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()

  const binary = await connectClient({ relay, identity, role: 'phone', autoAuth: false })
  binary.client.sendBinary(Buffer.from([0x01, 0x02, 0x03]))
  await errorCode(binary.client, 'bad_frame')
  assert.equal((await binary.client.waitClose()).code, 1003)

  const malformed = await connectRaw({ relay })
  malformed.client.sendText('{"v":1,')
  await errorCode(malformed.client, 'bad_frame')
  assert.equal((await malformed.client.waitClose()).code, 1008)

  const duplicate = await connectRaw({ relay })
  duplicate.client.sendText('{"v":1,"v":1,"type":"peer.auth"}')
  await errorCode(duplicate.client, 'bad_frame')
  assert.equal((await duplicate.client.waitClose()).code, 1008)

  const nestedDuplicate = await connectRaw({ relay })
  nestedDuplicate.client.sendText('{"v":1,"type":"peer.auth","nested":{"a":1,"a":2}}')
  await errorCode(nestedDuplicate.client, 'bad_frame')
  assert.equal((await nestedDuplicate.client.waitClose()).code, 1008)

  const nonObject = await connectRaw({ relay })
  nonObject.client.sendText('[]')
  await errorCode(nonObject.client, 'bad_frame')
  assert.equal((await nonObject.client.waitClose()).code, 1008)

  const escapedNul = await connectRaw({ relay })
  escapedNul.client.sendText('{"v":1,"type":"peer.auth","x":"a\\u0000b"}')
  await errorCode(escapedNul.client, 'bad_frame')
  assert.equal((await escapedNul.client.waitClose()).code, 1008)

  const loneSurrogate = await connectRaw({ relay })
  loneSurrogate.client.sendText('{"v":1,"type":"peer.auth","x":"\\ud800"}')
  await errorCode(loneSurrogate.client, 'bad_frame')
  assert.equal((await loneSurrogate.client.waitClose()).code, 1008)

  const bom = await connectRaw({ relay })
  bom.client.sendText('\ufeff{"v":1}')
  await errorCode(bom.client, 'bad_frame')
  assert.equal((await bom.client.waitClose()).code, 1008)
})

test('a frame over the configured cap is frame_too_large and close 1009', async t => {
  const relay = await startRelay({ maxFrameBytes: 1024 })
  t.after(() => relay.close())
  const identity = createIdentity()
  const { client } = await connectClient({ relay, identity, role: 'phone' })
  client.sendText(JSON.stringify({ v: 1, type: 'relay.ping', nonce: 'A'.repeat(22), padding: 'x'.repeat(2000) }))
  await errorCode(client, 'frame_too_large')
  assert.equal((await client.waitClose()).code, 1009)
})

test('an unsupported outer protocol version is version_unsupported', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()
  const { client } = await connectClient({ relay, identity, role: 'phone' })
  client.send({ v: 2, type: 'relay.ping', nonce: 'A'.repeat(22) })
  assert.equal((await client.next('relay.error')).code, 'version_unsupported')
  assert.equal((await client.waitClose()).code, 1008)

  const preAuth = await connectClient({ relay, identity, role: 'phone', autoAuth: false })
  t.after(() => preAuth.client.close())
  preAuth.client.send({
    v: 2,
    type: 'peer.auth',
    machineId: identity.machineId,
    publicKey: identity.publicKeyB64,
    role: 'phone',
    sig: 'A'.repeat(86),
  })
  assert.equal((await preAuth.client.next('relay.error')).code, 'version_unsupported')
  assert.equal((await preAuth.client.waitClose()).code, 1008)
})

test('outbound-only relay frames and the reserved redirect are rejected from clients', async t => {
  const relay = await startRelay()
  t.after(() => relay.close())
  const identity = createIdentity()

  for (const frame of [
    { v: 1, type: 'relay.challenge', nonce: 'A'.repeat(43), relay: relay.origin },
    { v: 1, type: 'relay.ready', machineId: identity.machineId, role: 'phone' },
    { v: 1, type: 'relay.offline', to: identity.machineId },
    { v: 1, type: 'relay.error', code: 'bad_frame' },
    { v: 1, type: 'relay.redirect', url: 'https://relay2.example' },
    { v: 1, type: 'relay.pair.joined', rendezvous: 'A'.repeat(22), role: 'phone', peerMachineId: identity.machineId },
    { v: 1, type: 'relay.unregistered' },
  ]) {
    const { client } = await connectClient({ relay, identity, role: 'phone' })
    client.send(frame)
    await errorCode(client, 'bad_frame')
    assert.equal((await client.waitClose()).code, 1008)
  }
})
