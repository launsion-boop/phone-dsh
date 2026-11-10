/**
 * Real-relay pacing regression (contract §3.8, pclink-v1.5).
 *
 * Start the real `relay/` server with its default pair limits (1 MiB/s, 4 MiB
 * burst), run the real PC SessionManager/RelayLink over a real WebSocket, and
 * ask a stub DSH endpoint for a result close to the 8 MiB plaintext cap. The
 * result is chunked over several ~1.4 MB `e2e` frames; without sender pacing
 * the relay drops the third frame. The test asserts that the relay logged no
 * dropped frame, that the phone reassembled the complete result, and that the
 * elapsed time is consistent with the 0.9 MiB/s local bucket (rather than an
 * instantaneous burst).
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { RelayLink } from '../plugin/relay-link.mjs'
import { SessionManager } from '../plugin/session-manager.mjs'
import { FakeConnection, FakeGateway, makeStore } from './helpers.mjs'
import { PhonePeer } from './phone-peer.mjs'

let createRelayServer
let relaySkip
try {
  ({ createRelayServer } = await import('../../relay/src/server.mjs'))
} catch (error) {
  relaySkip = `real relay is unavailable (install relay/node_modules): ${error.message}`
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

async function waitFor(predicate, label, timeoutMs = 30_000, intervalMs = 50) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value !== undefined && value !== false) return value
    await delay(intervalMs)
  }
  throw new Error(`timed out waiting for ${label}`)
}

test('real relay default limits: a ~7 MiB DSH result is paced, not dropped', {
  timeout: 120_000,
  skip: relaySkip,
}, async () => {
  const events = []
  const dropped = []
  const logger = {
    info: (event, fields) => {
      events.push({ event, fields })
      if (event === 'frame.dropped') dropped.push(fields)
    },
    warn: () => {},
    error: () => {},
  }
  const relay = createRelayServer({
    publicOrigin: 'http://127.0.0.1:0',
    host: '127.0.0.1',
    port: 0,
    logger,
  })
  await relay.listen()
  const origin = relay.origin
  const { store, phone } = makeStore()
  const rateLimits = []
  const link = new RelayLink({
    origin,
    identity: store.identity,
    allowlist: () => [phone.machineId],
    onFrame: () => {},
    onState: () => {},
    onRateLimited: frame => {
      rateLimits.push(frame)
    },
    log: () => {},
    connectTimeoutMs: 10_000,
  })
  let phonePeer
  try {
    const payloadBytes = 7 * 1024 * 1024
    const payload = 'x'.repeat(payloadBytes)
    const connection = new FakeConnection(async () => Response.json({
      type: 'server-response',
      rpcId: 'stub',
      result: { ok: true, value: { blob: payload } },
    }))
    const manager = new SessionManager({
      connection,
      gateway: new FakeGateway(),
      store,
      link,
      pcName: 'Pacing PC',
      appVersion: '0.1.0',
      dsh: { version: '0.2.2-rc.1' },
      log: () => {},
      idleMs: 900_000,
    })
    link.onFrame = frame => {
      if (frame.type === 'e2e.handshake') manager.handleHandshake(frame)
      else if (frame.type === 'e2e') manager.handleE2e(frame)
      else if (frame.type === 'relay.offline') manager.handleRelayOffline(frame)
      else if (frame.type === 'relay.error') rateLimits.push(frame)
    }
    link.start()
    await waitFor(() => link.ready, 'relay authentication', 15_000)

    phonePeer = new PhonePeer({ origin, identity: phone })
    phonePeer.pcMachineId = store.identity.machineId
    phonePeer.pcPublicKey = store.identity.publicKey
    phonePeer.pcName = 'Pacing PC'
    await phonePeer.connect()
    await phonePeer.handshake()

    const startedAt = Date.now()
    const result = await phonePeer.call('session/list', { _request: {} }, 90_000)
    const elapsedMs = Date.now() - startedAt

    assert.equal(result.blob.length, payloadBytes, 'the whole value reached the phone')
    assert.ok(phonePeer.resultChunkFrames >= 3,
      `expected several result chunks, saw ${String(phonePeer.resultChunkFrames)}`)
    assert.deepEqual(dropped, [], 'the relay must not drop a paced frame')
    assert.deepEqual(rateLimits, [], 'the relay must not rate-limit a paced sender')
    assert.equal(manager.lastRateLimited, undefined)

    // ~1.4 MB per chunk: most of the wire bytes are beyond the 3.5 MiB burst,
    // so the send must take roughly (chunkChars - burst) / 0.9 MiB/s. Use a
    // conservative floor so a loaded CI machine cannot make this flaky.
    const overflowBytes = Math.max(0, phonePeer.resultChunkChars - 3.5 * 1024 * 1024)
    const expectedMs = overflowBytes / (0.9 * 1024 * 1024) * 1000
    assert.ok(elapsedMs >= expectedMs * 0.6,
      `paced send took ${String(elapsedMs)}ms, expected at least ${String(Math.round(expectedMs * 0.6))}ms`)
    assert.ok(elapsedMs < 90_000, `paced send must finish well inside the test timeout (${String(elapsedMs)}ms)`)

    const forwarded = events.filter(event => event.event === 'frame.forwarded')
    assert.ok(forwarded.length >= phonePeer.resultChunkFrames, 'the relay forwarded every chunk')
    assert.equal(phonePeer.closed, false)
    assert.equal(manager.sessions.size, 1)
  } finally {
    await phonePeer?.close().catch(() => {})
    link.stop()
    await relay.close()
  }
})
