/** Relay supervisor: auth, allowlist, heartbeat, replacement/backoff and origin pinning. */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { b64urlDecode, b64urlEncode, randomBytes } from '../core/encoding.mjs'
import { verifyRelayAuth } from '../core/relay.mjs'
import { generateIdentity } from '../core/identity.mjs'
import { RelayLink } from '../plugin/relay-link.mjs'
import { FakeTimers } from './helpers.mjs'

class FakeWebSocket {
  static instances = []

  constructor(url) {
    this.url = url
    this.readyState = 0
    this.bufferedAmount = 0
    this.sent = []
    this.listeners = new Map()
    this.closed = undefined
    FakeWebSocket.instances.push(this)
  }

  addEventListener(type, listener) {
    const list = this.listeners.get(type) ?? []
    list.push(listener)
    this.listeners.set(type, list)
  }

  emit(type, event) {
    for (const listener of this.listeners.get(type) ?? []) listener(event)
  }

  open() {
    this.readyState = 1
    this.emit('open', {})
  }

  send(text) {
    this.sent.push(text)
  }

  close(code, reason) {
    if (this.readyState === 3) return
    this.readyState = 3
    this.closed = { code, reason }
    this.emit('close', { code, reason })
  }

  message(frame) {
    this.emit('message', { data: JSON.stringify(frame) })
  }

  get sentFrames() {
    return this.sent.map(text => JSON.parse(text))
  }
}

function makeLink(overrides = {}) {
  const identity = generateIdentity()
  const timers = new FakeTimers()
  const frames = []
  const states = []
  const link = new RelayLink({
    origin: 'https://relay.example',
    identity,
    allowlist: () => ['gewra3lzquaxpctdtkvzv2drdp'],
    onFrame: frame => frames.push(frame),
    onState: state => states.push(state),
    WebSocketCtor: FakeWebSocket,
    timers,
    random: () => 0.5,
    heartbeatBaseMs: 1_000_000,
    log: () => {},
    ...overrides,
  })
  return { link, identity, timers, frames, states }
}

function authenticate(link, socket, identity) {
  socket.open()
  const nonce = randomBytes(32)
  socket.message({ v: 1, type: 'relay.challenge', nonce: b64urlEncode(nonce), relay: 'https://relay.example' })
  const auth = socket.sentFrames.at(-1)
  const verified = verifyRelayAuth(auth, { origin: 'https://relay.example', nonce })
  assert.equal(verified.machineId, identity.machineId)
  assert.equal(verified.role, 'pc')
  socket.message({ v: 1, type: 'relay.ready', machineId: identity.machineId, role: 'pc' })
}

test('relay link authenticates, sends the allowlist and delivers application frames', () => {
  FakeWebSocket.instances = []
  const { link, identity, frames } = makeLink()
  link.start()
  const socket = FakeWebSocket.instances[0]
  authenticate(link, socket, identity)
  assert.equal(link.ready, true)
  const allow = socket.sentFrames.filter(frame => frame.type === 'relay.allow').at(-1)
  assert.deepEqual(allow.peers, ['gewra3lzquaxpctdtkvzv2drdp'])
  socket.message({ v: 1, type: 'e2e', sid: 'ODU-xxharZz-k1yXN2XWRA', seq: 0, from: 'gewra3lzquaxpctdtkvzv2drdp', to: identity.machineId, body: 'AA' })
  assert.equal(frames.length, 1)
  link.stop()
})

test('relay link pins the dialed origin and refuses a mismatched challenge', () => {
  FakeWebSocket.instances = []
  const { link, states } = makeLink()
  link.start()
  const socket = FakeWebSocket.instances[0]
  socket.open()
  socket.message({ v: 1, type: 'relay.challenge', nonce: b64urlEncode(randomBytes(32)), relay: 'https://other.example' })
  assert.equal(socket.sentFrames.length, 0)
  assert.equal(states.at(-1).state, 'offline')
  link.stop()
})

test('relay heartbeat answers pings, counts unanswered pings and closes', () => {
  FakeWebSocket.instances = []
  const { link, identity, timers } = makeLink({ heartbeatBaseMs: 100 })
  link.start()
  const socket = FakeWebSocket.instances[0]
  authenticate(link, socket, identity)
  socket.message({ v: 1, type: 'relay.ping', nonce: b64urlEncode(randomBytes(16)) })
  assert.equal(socket.sentFrames.at(-1).type, 'relay.pong')
  timers.advance(100)
  const firstPing = socket.sentFrames.filter(frame => frame.type === 'relay.ping').at(-1)
  assert.ok(firstPing)
  socket.message({ v: 1, type: 'relay.pong', nonce: firstPing.nonce })
  timers.advance(100)
  const secondPing = socket.sentFrames.filter(frame => frame.type === 'relay.ping').at(-1)
  assert.notEqual(secondPing.nonce, firstPing.nonce)
  timers.advance(100)
  assert.equal(socket.closed.code, 1001)
  link.stop()
})

test('a replaced relay connection waits at least 30 seconds before reconnecting', () => {
  FakeWebSocket.instances = []
  const { link, identity, timers } = makeLink()
  link.start()
  const socket = FakeWebSocket.instances[0]
  authenticate(link, socket, identity)
  socket.message({ v: 1, type: 'relay.error', code: 'replaced' })
  socket.close(4001, 'replaced')
  timers.advance(29_999)
  assert.equal(FakeWebSocket.instances.length, 1)
  timers.advance(4_001)
  assert.equal(FakeWebSocket.instances.length, 2)
  link.stop()
})
