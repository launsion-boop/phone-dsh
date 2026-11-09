/** Pairing manager, admin carriers, runtime unpair/fail-closed and CLI-adjacent plugin tests. */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { request as httpRequest } from 'node:http'
import { statSync } from 'node:fs'
import { buildPairingRecord } from '../core/pairing.mjs'
import { generateIdentity } from '../core/identity.mjs'
import { PclinkStore } from '../plugin/state.mjs'
import {
  b64urlDecode,
  b64urlEncode,
  fingerprintOf,
  randomBytes,
} from '../core/encoding.mjs'
import { PclinkError } from '../core/errors.mjs'
import {
  buildPairAuth,
  buildPairFinal,
  crockfordDecode,
  normalizeManualCode,
  pairKeyFor,
  pairTranscriptHash,
  parseQrUri,
  rendezvousFor,
  verifyPairConfirm,
  verifyPairHello,
} from '../core/pairing.mjs'
import { AdminPlane, adminOperationForPath, adminRoutePaths } from '../plugin/admin-plane.mjs'
import { AdminServer } from '../plugin/admin-server.mjs'
import { AdminClient } from '../core/admin.mjs'
import { PairingManager, PAIR_SLOT_TTL_MS, APPROVAL_TTL_MS } from '../plugin/pairing-manager.mjs'
import { PclinkRuntime } from '../plugin/pclink.mjs'
import { runAsPclinkRemote } from '../plugin/remote-context.mjs'
import { FakeLink, FakeTimers, makeStore } from './helpers.mjs'

const ORIGIN = 'https://relay.example'

function makePairing(options = {}) {
  const { store, phone } = makeStore({ records: false })
  if (options.withRecord === true) {
    // separate helper use; pairing tests normally start empty
  }
  const timers = new FakeTimers()
  const link = new FakeLink()
  const pairing = new PairingManager({
    store,
    send: frame => link.send(frame),
    relayOrigin: ORIGIN,
    pcName: 'My PC',
    timers,
    onCompleted: options.onCompleted,
    log: () => {},
  })
  return { store, phone, timers, link, pairing }
}

function secretOfStart(start) {
  if (start.pairing.qrURI !== undefined) {
    const parsed = parseQrUri(start.pairing.qrURI)
    return { secret: b64urlDecode(parsed.secret, { length: 16 }), parsed }
  }
  return { secret: crockfordDecode(normalizeManualCode(start.pairing.manualCode)), parsed: undefined }
}

function joinAndAuth({ pairing, link, store, phone, secret, mutateAuth, pin = true }) {
  const rendezvous = rendezvousFor(secret, ORIGIN)
  pairing.handleFrame({ v: 1, type: 'relay.pair.joined', rendezvous, role: 'pc', peerMachineId: phone.machineId })
  const helloFrame = link.frames('relay.pair.message').at(-1)
  assert.equal(helloFrame.payload.type, 'pair.hello')
  const pairKey = pairKeyFor(secret)
  const verified = verifyPairHello(helloFrame.payload, {
    pairKey,
    relay: ORIGIN,
    ...(pin ? { pinnedPublicKey: store.identity.publicKey, pinnedMachineId: store.identity.machineId } : {}),
  })
  const authNonce = randomBytes(32)
  let auth = buildPairAuth({
    identity: phone,
    name: 'iPhone',
    relay: ORIGIN,
    nonce: authNonce,
    peerNonce: b64urlDecode(helloFrame.payload.nonce, { length: 32 }),
    pairKey,
  })
  if (mutateAuth !== undefined) auth = mutateAuth(auth)
  pairing.handleFrame({ v: 1, type: 'relay.pair.message', rendezvous, payload: auth })
  return { rendezvous, hello: helloFrame.payload, pairKey, authNonce, auth, verified }
}

function finishPairing({ pairing, link, rendezvous, hello, auth, pairKey }) {
  const confirmFrame = link.frames('relay.pair.message').at(-1)
  assert.equal(confirmFrame.payload.type, 'pair.confirm')
  const transcript = pairTranscriptHash(hello, auth)
  verifyPairConfirm(confirmFrame.payload, {
    pairKey,
    expectedNonce: b64urlDecode(hello.nonce, { length: 32 }),
    expectedPeerNonce: b64urlDecode(auth.nonce, { length: 32 }),
    transcriptHash: transcript.transcriptHash,
  })
  const final = buildPairFinal({
    pairKey,
    nonce: b64urlDecode(auth.nonce, { length: 32 }),
    peerNonce: b64urlDecode(hello.nonce, { length: 32 }),
    transcriptHash: transcript.transcriptHash,
  })
  pairing.handleFrame({ v: 1, type: 'relay.pair.message', rendezvous, payload: final })
}

test('pairing QR start returns a pinned URI and redacted waiting status; second start refused', () => {
  const { store, pairing, link } = makePairing()
  const start = pairing.start({ mode: 'qr' })
  assert.equal(start.pairing.mode, 'qr')
  assert.ok(start.pairing.qrURI.startsWith('pclink://pair?'))
  const parsed = parseQrUri(start.pairing.qrURI)
  assert.equal(parsed.machineId, store.identity.machineId)
  const opened = link.frames('relay.pair.open')
  assert.equal(opened.length, 1)
  assert.equal(opened[0].rendezvous, rendezvousFor(b64urlDecode(parsed.secret, { length: 16 }), ORIGIN))
  const status = pairing.status()
  assert.equal(status.state, 'waiting')
  assert.equal(status.qrURI, start.pairing.qrURI)
  assert.equal(status.peerMachineId, undefined)
  assert.throws(() => pairing.start({ mode: 'manual' }), error => error.code === 'unavailable')
})

test('pairing manual mode only opens the C slot and displays the 16-character code', () => {
  const { pairing, link } = makePairing()
  const start = pairing.start({ mode: 'manual' })
  assert.equal(start.pairing.qrURI, undefined)
  assert.match(start.pairing.manualCode, /^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$/)
  assert.equal(link.frames('relay.pair.open').length, 1)
  assert.equal(pairing.status().manualCode, start.pairing.manualCode)
})

test('pairing approve requires the phone fingerprint, writes only after final, and sends a notice', () => {
  const records = []
  const { store, phone, pairing, link } = makePairing({ onCompleted: record => records.push(record) })
  const start = pairing.start({ mode: 'manual' })
  const { secret } = secretOfStart(start)
  const joined = joinAndAuth({ pairing, link, store, phone, secret })
  assert.equal(pairing.status().state, 'awaiting_approval')
  assert.equal(pairing.status().peerName, 'iPhone')
  for (const forbidden of ['peerMachineId', 'peerFingerprint', 'peerPublicKey']) {
    assert.equal(pairing.status()[forbidden], undefined, forbidden)
  }
  // No pair.confirm may exist before approval.
  assert.equal(link.frames('relay.pair.message').some(frame => frame.payload.type === 'pair.confirm'), false)
  const approved = pairing.approve(start.pairing.id, phone.machineId.slice(0, 12).replace(/(.{4})(.{4})(.{4})/, '$1-$2-$3'), 'cli')
  assert.deepEqual(approved, { v: 1, approved: true })
  assert.equal(pairing.status().state, 'awaiting_approval')
  finishPairing({ pairing, link, rendezvous: joined.rendezvous, hello: joined.hello, auth: joined.auth, pairKey: joined.pairKey })
  const completed = pairing.status()
  assert.equal(completed.state, 'completed')
  assert.equal(completed.peerMachineId, phone.machineId)
  assert.equal(completed.peerFingerprint, fingerprintOf(phone.machineId))
  const record = store.records.find(entry => entry.peerMachineId === phone.machineId)
  assert.ok(record)
  assert.equal(record.approvedVia, 'cli')
  assert.equal(store.audit.filter(event => event.event === 'pair').length, 1)
  assert.equal(records.length, 1)
  assert.equal(link.frames('relay.pair.close').at(-1).reason, 'paired')
})

test('pairing wrong fingerprint blocks, voids the single-use slot and writes nothing', () => {
  const { store, phone, pairing, link } = makePairing()
  const start = pairing.start({ mode: 'qr' })
  const { secret } = secretOfStart(start)
  joinAndAuth({ pairing, link, store, phone, secret })
  const result = pairing.approve(start.pairing.id, '2222-2222-2222', 'cli')
  assert.equal(result.approved, false)
  assert.equal(result.error.code, 'auth_failed')
  assert.equal(link.frames('relay.pair.close').at(-1).reason, 'auth_failed')
  assert.equal(pairing.status().state, 'failed')
  assert.equal(pairing.status().error, 'auth_failed')
  assert.equal(store.records.length, 0)
  assert.equal(store.audit.length, 0)
  assert.equal(link.frames('relay.pair.message').some(frame => frame.payload.type === 'pair.confirm'), false)
  assert.throws(() => pairing.approve(start.pairing.id, phone.machineId.slice(0, 12)), error => error.code === 'unavailable')
})

test('pairing MAC failure is auth_failed and never reaches approval', () => {
  const { store, phone, pairing, link } = makePairing()
  const start = pairing.start({ mode: 'manual' })
  const { secret } = secretOfStart(start)
  joinAndAuth({
    pairing, link, store, phone, secret,
    mutateAuth: auth => ({ ...auth, mac: b64urlEncode(Buffer.alloc(32)) }),
  })
  assert.equal(pairing.status().state, 'failed')
  assert.equal(pairing.status().error, 'auth_failed')
  assert.equal(link.frames('relay.pair.close').at(-1).reason, 'auth_failed')
  assert.equal(store.records.length, 0)
})

test('pairing approval timeout and slot expiry close the slot', () => {
  const first = makePairing()
  const start = first.pairing.start({ mode: 'qr' })
  const { secret } = secretOfStart(start)
  joinAndAuth({ pairing: first.pairing, link: first.link, store: first.store, phone: first.phone, secret })
  first.timers.advance(APPROVAL_TTL_MS + 1)
  assert.equal(first.pairing.status().state, 'failed')
  assert.equal(first.pairing.status().error, 'session_expired')
  assert.equal(first.link.frames('relay.pair.close').at(-1).reason, 'timeout')

  const second = makePairing()
  second.pairing.start({ mode: 'manual' })
  second.timers.advance(PAIR_SLOT_TTL_MS + 1)
  assert.equal(second.pairing.status().state, 'failed')
  assert.equal(second.pairing.status().error, 'rendezvous_expired')
})

test('pairing storage failure sends storage and leaves no usable record', () => {
  const { store, phone, pairing, link } = makePairing()
  const start = pairing.start({ mode: 'qr' })
  const { secret } = secretOfStart(start)
  const joined = joinAndAuth({ pairing, link, store, phone, secret })
  pairing.approve(start.pairing.id, phone.machineId.slice(0, 12), 'webui')
  store.addPair = () => { throw new Error('disk full') }
  finishPairing({ pairing, link, rendezvous: joined.rendezvous, hello: joined.hello, auth: joined.auth, pairKey: joined.pairKey })
  assert.equal(link.frames('relay.pair.close').at(-1).reason, 'storage')
  assert.equal(pairing.status().state, 'failed')
  assert.equal(store.records.length, 0)
})

test('pairing relay loss fails the slot instead of pretending success', () => {
  const { pairing } = makePairing()
  pairing.start({ mode: 'qr' })
  pairing.handleRelayDown()
  assert.equal(pairing.status().state, 'failed')
  assert.equal(pairing.status().error, 'unavailable')
})

test('admin status is schema-valid while awaiting approval and hides the pending peer', async () => {
  const { store, phone, pairing, link } = makePairing()
  const start = pairing.start({ mode: 'qr' })
  const { secret } = secretOfStart(start)
  joinAndAuth({ pairing, link, store, phone, secret })
  const sessions = { onlinePeers: () => new Set(), versionWarnings: [] }
  const plane = new AdminPlane({
    store,
    pairing,
    sessions,
    relay: { origin: ORIGIN, state: 'connected' },
    unpair: () => ({ v: 1, removed: [] }),
    rotateIdentity: () => ({ v: 1 }),
  })
  const status = plane.status()
  const { validateJsonSchema } = await import('../core/schema.mjs')
  const { parseStrictJsonObject } = await import('../core/json.mjs')
  const schema = parseStrictJsonObject(readFileSync(new URL('../../spec/pclink/v1/schema/admin-status.schema.json', import.meta.url)))
  validateJsonSchema(status, schema)
  for (const forbidden of ['peerMachineId', 'peerFingerprint', 'peerPublicKey']) {
    assert.equal(JSON.stringify(status).includes(forbidden), false, forbidden)
  }
})

test('admin /api source-Peer gate refuses a PCLink remote despite the endpoint spelling', async () => {
  const { store, pairing } = makePairing()
  const sessions = { onlinePeers: () => new Set(), versionWarnings: [] }
  let unpairs = 0
  const plane = new AdminPlane({
    store,
    pairing,
    sessions,
    relay: { origin: ORIGIN, state: 'connected' },
    unpair: () => { unpairs += 1; return { v: 1, removed: [] } },
    rotateIdentity: () => ({ v: 1 }),
  })
  const request = () => new Request('http://pclink.internal/api/pclink.admin/unpair', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ all: true }),
  })
  const owner = await plane.handleFetch(request(), { operation: 'unpair', via: 'webui' })
  assert.equal(owner.status, 200)
  assert.equal(unpairs, 1)
  const remote = await runAsPclinkRemote(() => plane.handleFetch(request(), { operation: 'unpair', via: 'webui' }))
  assert.equal(remote.status, 403)
  const remoteBody = await remote.json()
  assert.equal(remoteBody.error.code, 'forbidden')
  assert.equal(unpairs, 1)
})

test('the six owner admin routes are registered with the contract operation names', () => {
  assert.deepEqual(adminRoutePaths().sort(), [
    '/api/pclink.admin/pair',
    '/api/pclink.admin/pair/approve',
    '/api/pclink.admin/pair/cancel',
    '/api/pclink.admin/rotate-identity',
    '/api/pclink.admin/status',
    '/api/pclink.admin/unpair',
  ].sort())
  assert.equal(adminOperationForPath('/api/pclink.admin/pair/approve'), 'pair/approve')
  assert.equal(adminOperationForPath('/api/pclink.admin/unknown'), undefined)
  assert.equal(adminOperationForPath('/api/other'), undefined)
})

test('loopback admin server enforces Host/Origin/Content-Type/Bearer and the proof challenge', async () => {
  const { store, pairing } = makePairing()
  const sessions = { onlinePeers: () => new Set(), versionWarnings: [] }
  const plane = new AdminPlane({
    store,
    pairing,
    sessions,
    relay: { origin: ORIGIN, state: 'offline' },
    unpair: () => ({ v: 1, removed: [] }),
    rotateIdentity: () => ({ v: 1 }),
  })
  const server = new AdminServer({ dir: store.dir, plane, log: () => {} })
  await server.start()
  try {
    const client = new AdminClient({ dir: store.dir })
    const status = await client.status()
    assert.equal(status.relay.origin, ORIGIN)
    const port = server.port
    const originRejected = await fetch(`http://127.0.0.1:${String(port)}/v1/status`, {
      headers: { origin: 'http://evil.example', authorization: `Bearer ${server.tokenText}` },
    })
    assert.equal(originRejected.status, 403)
    const contentTypeRejected = await fetch(`http://127.0.0.1:${String(port)}/v1/pair`, {
      method: 'POST',
      headers: { authorization: `Bearer ${server.tokenText}`, 'content-type': 'text/plain' },
      body: '{}',
    })
    assert.equal(contentTypeRejected.status, 415)
    const badToken = await fetch(`http://127.0.0.1:${String(port)}/v1/status`, { headers: { authorization: 'Bearer nope' } })
    assert.equal(badToken.status, 401)
    const wrongHost = await new Promise((resolve, reject) => {
      const request = httpRequest({ hostname: '127.0.0.1', port, path: '/v1/status', method: 'GET', headers: { host: 'localhost', authorization: `Bearer ${server.tokenText}` } }, response => {
        response.resume()
        resolve(response.statusCode)
      })
      request.on('error', reject)
      request.end()
    })
    assert.equal(wrongHost, 400)
  } finally {
    await server.stop()
  }
  await assert.rejects(() => new AdminClient({ dir: store.dir }).status(), error => error.code === 'unavailable')
})

test('unpair appends tombstones, removes records and updates the allowlist', () => {
  const { store, phone } = makeStore()
  const runtime = new PclinkRuntime({
    connection: {}, gateway: {}, dshHome: store.dir,
    relayOrigin: ORIGIN, pcName: 'My PC',
    log: () => {}, timers: new FakeTimers(),
  })
  runtime.store = store
  const aborted = []
  runtime.sessions = { abortPeer: peer => aborted.push(peer) }
  runtime.link = new FakeLink()
  const result = runtime.unpair({ all: true })
  assert.deepEqual(result, { v: 1, removed: [phone.machineId] })
  assert.deepEqual(aborted, [phone.machineId])
  assert.equal(store.records.length, 0)
  assert.equal(store.audit.filter(event => event.event === 'unpair').length, 1)
  assert.equal(runtime.link.allowlists.length, 1)
})

test('a failing unpair tombstone enters fail-closed and retries before reconnecting', () => {
  const { store, phone } = makeStore()
  const timers = new FakeTimers()
  const runtime = new PclinkRuntime({
    connection: {}, gateway: {}, dshHome: store.dir,
    relayOrigin: ORIGIN, pcName: 'My PC',
    log: () => {}, timers,
  })
  runtime.store = store
  runtime.sessions = { abortPeer: () => {} }
  let stopped = 0
  let started = 0
  runtime.link = { stop: () => { stopped += 1 }, start: () => { started += 1 }, sendAllowlist: () => {} }
  const original = store.unpair.bind(store)
  let attempts = 0
  store.unpair = targets => {
    attempts += 1
    if (attempts === 1) throw new Error('ENOSPC')
    return original(targets)
  }
  assert.throws(() => runtime.unpair({ peerMachineId: phone.machineId }), error => error.code === 'unavailable')
  assert.equal(runtime.failClosed, true)
  assert.equal(stopped, 1)
  timers.advance(5_001)
  assert.equal(runtime.failClosed, false)
  assert.equal(started, 1)
  assert.equal(store.records.length, 0)
})

test('rotate-identity makes every record stale and restarts the relay identity', () => {
  const { store, phone } = makeStore()
  const timers = new FakeTimers()
  const runtime = new PclinkRuntime({
    connection: {}, gateway: {}, dshHome: store.dir,
    relayOrigin: ORIGIN, pcName: 'My PC',
    log: () => {}, timers,
  })
  runtime.store = store
  const closed = []
  runtime.sessions = {
    abortAllHandshakes: () => {},
    sessions: new Map([['sid', { fake: true }]]),
    closeSession: session => closed.push(session),
  }
  runtime.pairing = { dispose: () => {} }
  runtime.link = new FakeLink()
  runtime.link.identity = store.identity
  const oldMachineId = store.identity.machineId
  const result = runtime.rotateIdentity({ confirm: 'rotate-identity' })
  assert.equal(result.rotated, true)
  assert.equal(result.oldMachineId, oldMachineId)
  assert.notEqual(result.newMachineId, oldMachineId)
  assert.equal(runtime.link.identity.machineId, result.newMachineId)
  assert.equal(closed.length, 1)
  assert.equal(store.audit.filter(event => event.event === 'rotate').length, 1)
  assert.equal(store.stale, true)
  assert.equal(store.records.length, 1)
  assert.equal(store.records[0].peerMachineId, phone.machineId)
  assert.throws(() => runtime.rotateIdentity({ confirm: 'no' }), error => error.code === 'bad_frame')
})

test('rotating identity then pairing a new phone does not re-adopt stale records', () => {
  const { store } = makeStore()
  const oldPeer = store.records[0].peerMachineId
  store.rotateIdentity()
  assert.equal(store.stale, true)
  const phone = generateIdentity()
  const record = buildPairingRecord({
    peerMachineId: phone.machineId,
    peerPublicKey: b64urlEncode(phone.publicKey),
    peerName: 'New Phone',
    pairedAt: '2026-11-10T00:00:00Z',
    relayOrigin: ORIGIN,
    approvedAt: '2026-11-10T00:00:05Z',
    approvedVia: 'cli',
  })
  store.addPair(record, { at: '2026-11-10T00:00:05Z' })
  assert.equal(store.records.length, 1)
  assert.equal(store.records[0].peerMachineId, phone.machineId)
  const reloaded = new PclinkStore({ dir: store.dir }).load()
  assert.equal(reloaded.stale, false)
  assert.equal(reloaded.records.length, 1)
  assert.equal(reloaded.records[0].peerMachineId, phone.machineId)
  assert.equal(reloaded.usableRecord(oldPeer), undefined)
})

test('state files use the contract modes 0700/0600', async () => {
  const { store } = makeStore()
  const mode = path => statSync(path).mode & 0o777
  assert.equal(mode(store.dir), 0o700)
  assert.equal(mode(`${store.dir}/identity.key`), 0o600)
  assert.equal(mode(`${store.dir}/pairs.json`), 0o600)
  assert.equal(mode(`${store.dir}/pairs.log`), 0o600)
  const sessions = { onlinePeers: () => new Set(), versionWarnings: [] }
  const plane = new AdminPlane({ store, pairing: { status: () => undefined }, sessions, relay: { origin: ORIGIN, state: 'offline' }, unpair: () => ({ v: 1, removed: [] }), rotateIdentity: () => ({ v: 1 }) })
  const server = new AdminServer({ dir: store.dir, plane, log: () => {} })
  await server.start()
  try {
    assert.equal(mode(`${store.dir}/admin.json`), 0o600)
  } finally {
    await server.stop()
  }
})

test('runtime config normalization and unsupported-profile behavior', async () => {
  const { resolvePluginConfig, apply } = await import('../plugin/index.js')
  assert.equal(resolvePluginConfig({ relayUrl: 'wss://relay.example/' }).relayOrigin, 'https://relay.example')
  assert.equal(resolvePluginConfig({ relayUrl: 'http://127.0.0.1:3210' }).relayOrigin, 'http://127.0.0.1:3210')
  const config = resolvePluginConfig({})
  assert.equal(config.relayOrigin, 'https://relay.example.invalid')
  const context = { get: () => undefined }
  await apply(context, {})
})
