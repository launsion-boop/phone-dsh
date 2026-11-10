/** Pairing manager, admin carriers, runtime unpair/fail-closed and CLI-adjacent plugin tests. */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { chmodSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { request as httpRequest } from 'node:http'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { buildPairingRecord } from '../core/pairing.mjs'
import { generateIdentity } from '../core/identity.mjs'
import { PclinkStore } from '../plugin/state.mjs'
import { probeAuditAppend } from '../core/store.mjs'
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
import { PairingManager, PAIR_SLOT_TTL_MS } from '../plugin/pairing-manager.mjs'
import { PclinkRuntime } from '../plugin/pclink.mjs'
import { runAsPclinkRemote } from '../plugin/remote-context.mjs'
import { FakeLink, FakeTimers, makeStore } from './helpers.mjs'

const ORIGIN = 'https://relay.example'

/** Minimal WebSocket double: only construction matters for the gate tests. */
function makeSocketRecorder() {
  const instances = []
  class RecordingWebSocket {
    constructor(url) {
      this.url = url
      this.readyState = 0
      this.sent = []
      instances.push(this)
    }

    addEventListener() {}

    send(text) {
      this.sent.push(text)
    }

    close() {
      this.readyState = 3
    }
  }
  return { instances, RecordingWebSocket }
}

/** Deterministic valid machineId for an arbitrary integer (RFC 4648 base32). */
function machineIdFor(index) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567'
  let value = BigInt(index + 1)
  let text = ''
  for (let position = 0; position < 26; position += 1) {
    text = alphabet[Number(value % 32n)] + text
    value /= 32n
  }
  return text
}

/** Fresh DSH home whose `pclink/` state dir has an empty audit log. */
function makeRuntimeHome() {
  const home = mkdtempSync(join(tmpdir(), 'pclink-runtime-'))
  const dir = join(home, 'pclink')
  new PclinkStore({ dir }).load()
  const logPath = join(dir, 'pairs.log')
  writeFileSync(logPath, '')
  return { home, dir, logPath }
}

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

test('pairing auto-approves the verified auth, sends confirm, writes only after final and audits qr', () => {
  const records = []
  const { store, phone, pairing, link } = makePairing({ onCompleted: record => records.push(record) })
  const start = pairing.start({ mode: 'qr' })
  const { secret } = secretOfStart(start)
  const joined = joinAndAuth({ pairing, link, store, phone, secret })
  const status = pairing.status()
  assert.equal(status.state, 'joined')
  assert.equal(status.peerName, 'iPhone')
  for (const forbidden of ['peerMachineId', 'peerFingerprint', 'peerPublicKey']) {
    assert.equal(status[forbidden], undefined, forbidden)
  }
  // §4.4 v1.6: the verified pair.auth is the approval; confirm is already sent.
  assert.equal(link.frames('relay.pair.message').some(frame => frame.payload.type === 'pair.confirm'), true)
  assert.equal(store.records.length, 0, 'the record still waits for pair.final')
  finishPairing({ pairing, link, rendezvous: joined.rendezvous, hello: joined.hello, auth: joined.auth, pairKey: joined.pairKey })
  const completed = pairing.status()
  assert.equal(completed.state, 'completed')
  assert.equal(completed.peerMachineId, phone.machineId)
  assert.equal(completed.peerFingerprint, fingerprintOf(phone.machineId))
  const record = store.records.find(entry => entry.peerMachineId === phone.machineId)
  assert.ok(record)
  assert.equal(record.approvedVia, 'qr')
  const audit = store.audit.filter(event => event.event === 'pair')
  assert.equal(audit.length, 1)
  assert.equal(audit[0].approvedVia, 'qr')
  assert.equal(records.length, 1)
  assert.equal(link.frames('relay.pair.close').at(-1).reason, 'paired')
})

test('the deprecated approve route is a no-op on a v1.6 slot and never voids it', () => {
  const { store, phone, pairing, link } = makePairing()
  const start = pairing.start({ mode: 'manual' })
  const { secret } = secretOfStart(start)
  const joined = joinAndAuth({ pairing, link, store, phone, secret })
  assert.throws(
    () => pairing.approve(start.pairing.id, '2222-2222-2222', 'cli'),
    error => error.code === 'unavailable' && /not awaiting approval/.test(error.message),
  )
  assert.equal(pairing.status().state, 'joined')
  assert.equal(link.frames('relay.pair.close').length, 0)
  finishPairing({ pairing, link, rendezvous: joined.rendezvous, hello: joined.hello, auth: joined.auth, pairKey: joined.pairKey })
  assert.equal(pairing.status().state, 'completed')
  assert.equal(store.records[0].approvedVia, 'manual')
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

test('a joined pairing has no 120 s approval timer; slot expiry still closes it', () => {
  const first = makePairing()
  const start = first.pairing.start({ mode: 'qr' })
  const { secret } = secretOfStart(start)
  joinAndAuth({ pairing: first.pairing, link: first.link, store: first.store, phone: first.phone, secret })
  first.timers.advance(120_001)
  assert.equal(first.pairing.status().state, 'joined', 'auto-approval must not arm the legacy approval timeout')
  first.timers.advance(PAIR_SLOT_TTL_MS)
  assert.equal(first.pairing.status().state, 'failed')
  assert.equal(first.pairing.status().error, 'rendezvous_expired')

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

test('admin status is schema-valid while joined and hides the pending peer', async () => {
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
    plugin: { version: '0.2.0', packageSha256: 'a'.repeat(64) },
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

test('startup audit probe keeps the plugin fail-closed and re-probes after a restart', async () => {
  const { home, logPath } = makeRuntimeHome()
  chmodSync(logPath, 0o444)
  const firstSockets = makeSocketRecorder()
  const firstTimers = new FakeTimers()
  const first = new PclinkRuntime({
    connection: {}, gateway: {}, dshHome: home,
    relayOrigin: ORIGIN, pcName: 'My PC',
    log: () => {}, timers: firstTimers, WebSocketCtor: firstSockets.RecordingWebSocket,
  })
  try {
    try {
      await first.start()
      assert.equal(first.failClosed, true)
      assert.equal(firstSockets.instances.length, 0, 'a failed audit append probe must not dial the relay')
      const status = first.adminPlane.status()
      assert.equal(status.relay.state, 'offline')
      assert.match(status.warnings.join('\n'), /fail-closed|pairs\.log/)
    } finally {
      await first.stop()
    }

    // Restarting does not clear fail-closed while the storage failure persists.
    const secondSockets = makeSocketRecorder()
    const secondTimers = new FakeTimers()
    const second = new PclinkRuntime({
      connection: {}, gateway: {}, dshHome: home,
      relayOrigin: ORIGIN, pcName: 'My PC',
      log: () => {}, timers: secondTimers, WebSocketCtor: secondSockets.RecordingWebSocket,
    })
    try {
      await second.start()
      assert.equal(second.failClosed, true)
      assert.equal(secondSockets.instances.length, 0)
      // Once the log is writable again the retry probes, clears the gate, and connects.
      chmodSync(logPath, 0o600)
      secondTimers.advance(5_001)
      assert.equal(second.failClosed, false)
      assert.equal(secondSockets.instances.length, 1)
      assert.doesNotMatch(second.adminPlane.status().warnings.join('\n'), /fail-closed/)
    } finally {
      await second.stop()
    }
  } finally {
    chmodSync(logPath, 0o600)
  }
})

test('a full-disk audit probe fails closed and reports the storage error in status', async () => {
  const { home } = makeRuntimeHome()
  const sockets = makeSocketRecorder()
  const runtime = new PclinkRuntime({
    connection: {}, gateway: {}, dshHome: home,
    relayOrigin: ORIGIN, pcName: 'My PC',
    log: () => {}, timers: new FakeTimers(), WebSocketCtor: sockets.RecordingWebSocket,
    probeAudit: () => { throw Object.assign(new Error('ENOSPC: no space left on device'), { code: 'ENOSPC' }) },
  })
  try {
    await runtime.start()
    assert.equal(runtime.failClosed, true)
    assert.equal(sockets.instances.length, 0)
    const status = runtime.adminPlane.status()
    assert.equal(status.relay.state, 'offline')
    assert.match(status.warnings.join('\n'), /ENOSPC/)
  } finally {
    await runtime.stop()
  }
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

test('addPair checks the 1024-record cap before appending the audit line', () => {
  const { store } = makeStore()
  const base = store.records[0]
  store.records = Array.from({ length: 1024 }, (_, index) => ({ ...base, peerMachineId: machineIdFor(index) }))
  const phone = generateIdentity()
  const nextRecord = buildPairingRecord({
    peerMachineId: phone.machineId,
    peerPublicKey: b64urlEncode(phone.publicKey),
    peerName: 'Overflow Phone',
    pairedAt: '2026-11-10T00:00:00Z',
    relayOrigin: ORIGIN,
    approvedAt: '2026-11-10T00:00:05Z',
    approvedVia: 'cli',
  })
  const before = readFileSync(`${store.dir}/pairs.log`, 'utf8')
  assert.throws(() => store.addPair(nextRecord, { at: '2026-11-10T00:00:05Z' }), /limit/)
  assert.equal(readFileSync(`${store.dir}/pairs.log`, 'utf8'), before)
  assert.equal(store.audit.length, 1)
})

test('a failed re-pair write keeps the previous record usable', () => {
  const { store, phone, record } = makeStore()
  // Force the durable replace of pairs.json to fail at its validation/write
  // step. The still-durable old record must stay usable: the old code appended
  // the new pair audit line first, so the old record became "unapproved" even
  // though the new file never landed.
  store.records = [...store.records, { peerMachineId: 'not-a-machine-id' }]
  const replacement = { ...record, approvedAt: '2026-11-10T00:00:05Z' }
  const before = readFileSync(`${store.dir}/pairs.log`, 'utf8')
  assert.throws(() => store.addPair(replacement, { at: '2026-11-10T00:00:05Z' }))
  assert.equal(readFileSync(`${store.dir}/pairs.log`, 'utf8'), before)
  assert.notEqual(store.usableRecord(phone.machineId), undefined)
  const reloaded = new PclinkStore({ dir: store.dir }).load()
  assert.notEqual(reloaded.usableRecord(phone.machineId), undefined)
})

test('a corrupt pairs.json is preserved before a later pairing writes a new file', () => {
  const { store } = makeStore()
  const corrupt = '{ "v":1, "pcMachineId": "broken"'
  writeFileSync(`${store.dir}/pairs.json`, corrupt)
  const reloaded = new PclinkStore({ dir: store.dir }).load()
  assert.match(reloaded.warnings.join('\n'), /pairs\.json/)
  const backups = readdirSync(store.dir).filter(name => name.startsWith('pairs.json.corrupt'))
  assert.equal(backups.length, 1)
  assert.equal(readFileSync(`${store.dir}/${backups[0]}`, 'utf8'), corrupt)

  const phone = generateIdentity()
  const record = buildPairingRecord({
    peerMachineId: phone.machineId,
    peerPublicKey: b64urlEncode(phone.publicKey),
    peerName: 'After Corruption',
    pairedAt: '2026-11-10T00:00:00Z',
    relayOrigin: ORIGIN,
    approvedAt: '2026-11-10T00:00:05Z',
    approvedVia: 'cli',
  })
  reloaded.addPair(record, { at: '2026-11-10T00:00:05Z' })
  assert.equal(JSON.parse(readFileSync(`${store.dir}/pairs.json`, 'utf8')).pairs.length, 1)
  // The corrupt bytes remain inspectable in the backup.
  assert.equal(readFileSync(`${store.dir}/${backups[0]}`, 'utf8'), corrupt)
})

test('the audit append probe leaves pairs.log byte-identical', () => {
  const { store } = makeStore()
  const before = readFileSync(`${store.dir}/pairs.log`)
  probeAuditAppend(store.dir)
  assert.deepEqual(readFileSync(`${store.dir}/pairs.log`), before)
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
  assert.equal(config.relayOrigin, 'https://pclink.tonoai.cn')
  const context = { get: () => undefined }
  await apply(context, {})
})
