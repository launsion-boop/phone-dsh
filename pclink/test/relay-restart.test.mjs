/**
 * Real-relay restart regression for the PC plugin relay supervisor (CCR-3).
 *
 * This uses `relay/` itself (the real relay server module, not the test stub):
 * start it on an ephemeral port, let the real `RelayLink` authenticate and
 * send `relay.allow`, close the relay (all in-memory state and connections are
 * lost), wait through failed reconnect attempts, start a fresh relay on the
 * same origin/port, and assert the plugin re-authenticates and re-sends its
 * allowlist within the §10 backoff ceiling.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { generateIdentity } from '../core/identity.mjs'
import { RelayLink } from '../plugin/relay-link.mjs'

let createRelayServer
let relaySkip
try {
  ({ createRelayServer } = await import('../../relay/src/server.mjs'))
} catch (error) {
  relaySkip = `real relay is unavailable (install relay/node_modules): ${error.message}`
}

const quietLogger = { info() {}, warn() {}, error() {} }

function relayOptions(port, publicOrigin) {
  return {
    publicOrigin,
    host: '127.0.0.1',
    port,
    logger: quietLogger,
    heartbeatMinMs: 20_000,
    heartbeatMaxMs: 30_000,
  }
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

async function waitFor(predicate, label, timeoutMs = 40_000, intervalMs = 100) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value !== undefined && value !== false) return value
    await delay(intervalMs)
  }
  throw new Error(`timed out waiting for ${label}`)
}

/** Real WebSocket that records the frames the supervisor put on the wire. */
function recordingWebSocket(sent) {
  return class RecordingWebSocket extends WebSocket {
    send(data) {
      if (typeof data === 'string') {
        try { sent.push(JSON.parse(data)) } catch { /* not one of our frames */ }
      }
      return super.send(data)
    }
  }
}

test('PC relay supervisor re-authenticates and re-sends relay.allow after a real relay restart', {
  timeout: 120_000,
  skip: relaySkip,
}, async () => {
  let relay = createRelayServer(relayOptions(0, 'http://127.0.0.1:0'))
  await relay.listen()
  const origin = relay.origin
  const port = relay.port
  const identity = generateIdentity()
  const phone = generateIdentity()
  const allow = [phone.machineId]
  const sent = []
  const frames = []
  const states = []
  const WebSocketCtor = recordingWebSocket(sent)
  const link = new RelayLink({
    origin,
    identity,
    allowlist: () => allow,
    onFrame: frame => frames.push(frame),
    onState: state => states.push(state),
    WebSocketCtor,
    random: () => 0.5,
    heartbeatBaseMs: 1_000_000,
    connectTimeoutMs: 10_000,
    errorGraceMs: 250,
    log: () => {},
  })

  try {
    link.start()
    await waitFor(() => link.ready, 'initial relay authentication', 15_000)
    await waitFor(() => sent.some(frame => frame.type === 'relay.allow'), 'initial relay.allow', 5_000)
    const initialAllows = sent.filter(frame => frame.type === 'relay.allow').length
    assert.equal(relay.peerCount, 1)

    // Kill the relay: the listener and every connection/allowlist disappear.
    await relay.close()
    await waitFor(() => !link.ready, 'link offline after relay close', 10_000)
    // Let at least one reconnect attempt fail against the closed port.
    await delay(1_500)

    // Restart the same real relay on the same origin/port.
    relay = createRelayServer(relayOptions(port, origin))
    await relay.listen()
    const restartedAt = Date.now()
    await waitFor(() => link.ready, 'reconnect after relay restart', 40_000)
    const reconnectMs = Date.now() - restartedAt
    assert.ok(reconnectMs <= 40_000, `reconnect ${reconnectMs}ms must stay inside the backoff ceiling`)
    assert.equal(relay.peerCount, 1, 'the relay accepted a fresh peer.auth')

    const after = await waitFor(
      () => sent.filter(frame => frame.type === 'relay.allow').slice(initialAllows),
      'relay.allow after reconnect',
      5_000,
    )
    const allowFrame = after[0]
    assert.deepEqual(allowFrame.peers, allow)
    assert.ok(states.some(state => state.state === 'connected'))
    assert.deepEqual(frames, [], 'no application frame was expected in this supervisor test')
  } finally {
    link.stop()
    await relay.close()
  }
})
