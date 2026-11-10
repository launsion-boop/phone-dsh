/** Test helpers shared by the PCLink unit tests. */
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { generateIdentity } from '../core/identity.mjs'
import { buildPairingRecord } from '../core/pairing.mjs'
import { PclinkStore } from '../plugin/state.mjs'

/**
 * Deterministic manual timer queue.
 */
export class FakeTimers {
  constructor() {
    this.nowMs = 0
    this.nextId = 1
    this.tasks = []
  }

  now() {
    return this.nowMs
  }

  setTimeout(fn, ms) {
    const id = this.nextId++
    this.tasks.push({ id, at: this.nowMs + Math.max(0, ms), fn })
    return { id, unref() {} }
  }

  clearTimeout(handle) {
    const id = typeof handle === 'object' ? handle?.id : handle
    this.tasks = this.tasks.filter(task => task.id !== id)
  }

  advance(ms) {
    const target = this.nowMs + ms
    for (;;) {
      this.tasks.sort((left, right) => left.at - right.at || left.id - right.id)
      const task = this.tasks[0]
      if (task === undefined || task.at > target) break
      this.tasks.shift()
      this.nowMs = task.at
      task.fn()
    }
    this.nowMs = target
  }

  get pending() {
    return this.tasks.length
  }
}

/** Fresh state directory under the OS temp area. */
export function tempStateDir() {
  return mkdtempSync(join(tmpdir(), 'pclink-test-'))
}

/**
 * Create a real PclinkStore with a real Ed25519 identity.
 * @param {{records?: boolean}} [options] Whether to add a paired phone.
 * @returns {{store: PclinkStore, dir: string, phone: ReturnType<typeof generateIdentity>, record?: object}}
 */
export function makeStore(options = {}) {
  const dir = tempStateDir()
  const store = new PclinkStore({ dir }).load()
  let record
  const phone = generateIdentity()
  if (options.records !== false) {
    record = buildPairingRecord({
      peerMachineId: phone.machineId,
      peerPublicKey: Buffer.from(phone.publicKey).toString('base64url'),
      peerName: 'iPhone',
      pairedAt: '2026-11-09T00:00:00Z',
      relayOrigin: 'https://relay.example',
      approvedAt: '2026-11-09T00:00:05Z',
      approvedVia: 'cli',
    })
    store.addPair(record, { at: '2026-11-09T00:00:05Z' })
  }
  return { store, dir, phone, record }
}

/** In-memory relay link capturing writes. */
export class FakeLink {
  constructor() {
    this.sent = []
    this.allowlists = []
    this.drainCalls = 0
  }

  send(frame) {
    this.sent.push(frame)
    return true
  }

  async waitForDrain() {
    this.drainCalls += 1
  }

  sendAllowlist() {
    this.allowlists.push([])
  }

  restart() {
    this.restarts = (this.restarts ?? 0) + 1
  }

  /** Frames of one type, oldest first. */
  frames(type) {
    return this.sent.filter(frame => frame.type === type)
  }

  clear() {
    this.sent.length = 0
  }
}

/** Minimal Cordis connection double with owner Peers and a shared fetch handler. */
export class FakeConnection {
  constructor(fetchImpl = async () => new Response('not found', { status: 404 })) {
    this.peers = []
    this.disposed = 0
    this.fetchImpl = fetchImpl
    this.requests = []
  }

  createPeer(options) {
    const peer = {
      id: `peer-${this.peers.length + 1}`,
      principal: options.principal,
      interactions: options.interactions,
      disposed: false,
      async dispose() {
        this.disposed = true
        return undefined
      },
    }
    this.peers.push(peer)
    return peer
  }

  createSharedFetchHandler() {
    return {
      fetch: async (request, peer) => {
        this.requests.push({ url: request.url, peer })
        return this.fetchImpl(request, peer)
      },
    }
  }

  async disposeAll() {
    for (const peer of this.peers) {
      if (!peer.disposed) {
        peer.disposed = true
        this.disposed += 1
      }
    }
  }
}

/** Minimal `ctx.typertGateway` double. */
export class FakeGateway {
  constructor(openImpl) {
    this.openImpl = openImpl ?? (async () => {
      throw Object.assign(new Error('no stream'), { code: 'gateway/method-unavailable' })
    })
    this.opened = []
  }

  wireStream = {
    open: async (endpoint, payload, uplink, peer, signal) => {
      this.opened.push({ endpoint, payload, peer, signal })
      return this.openImpl(endpoint, payload, signal)
    },
    failure: error => ({ code: error?.code ?? 'unavailable', message: error?.message ?? String(error), details: error?.details ?? {} }),
  }
}

/**
 * Async iterable yielding values, recording return().
 * @param {unknown[]} values Values.
 * @param {{neverReturn?: boolean}} [options] Simulate a stuck iterator.
 */
export function fakeIterable(values, options = {}) {
  const state = { returned: false, nextCalls: 0 }
  const iterable = {
    [Symbol.asyncIterator]() {
      let index = 0
      return {
        async next() {
          state.nextCalls += 1
          if (index >= values.length) return { done: true, value: undefined }
          const value = values[index]
          index += 1
          return { done: false, value }
        },
        async return() {
          state.returned = true
          if (options.neverReturn === true) return new Promise(() => {})
          return { done: true, value: undefined }
        },
      }
    },
  }
  return { iterable, state }
}

/**
 * Complete a real E2E handshake against a SessionManager.
 * @param {{manager: import('../plugin/session-manager.mjs').SessionManager, link: FakeLink, phoneIdentity: object, pcIdentity: object, pcName?: string}} input
 * @returns {Promise<{initiator: object, session: object, phoneCrypto: import('../core/aead.mjs').FrameCrypto}>}
 */
export async function completeHandshake({ manager, link, phoneIdentity, pcIdentity }) {
  const { HandshakeInitiator } = await import('../core/handshake.mjs')
  const { FrameCrypto } = await import('../core/aead.mjs')
  const initiator = new HandshakeInitiator({
    identity: phoneIdentity,
    pcMachineId: pcIdentity.machineId,
    pcPublicKey: pcIdentity.publicKey,
  })
  manager.handleHandshake({
    v: 1,
    type: 'e2e.handshake',
    sid: initiator.sid,
    from: phoneIdentity.machineId,
    to: pcIdentity.machineId,
    body: initiator.buildInit(),
  })
  const respFrame = link.frames('e2e.handshake').find(frame => frame.body?.type === 'session.resp' && frame.sid === initiator.sid)
  if (respFrame === undefined) throw new Error('no session.resp')
  const confirm = initiator.acceptResp(respFrame.body)
  manager.handleHandshake({
    v: 1,
    type: 'e2e.handshake',
    sid: initiator.sid,
    from: phoneIdentity.machineId,
    to: pcIdentity.machineId,
    body: confirm,
  })
  const session = manager.session(initiator.sid)
  if (session === undefined) throw new Error('session was not established')
  const phoneCrypto = new FrameCrypto({
    sendKey: initiator.keys.phoneToPc,
    recvKey: initiator.keys.pcToPhone,
    sid: initiator.sid,
    from: phoneIdentity.machineId,
    to: pcIdentity.machineId,
  })
  return { initiator, session, phoneCrypto }
}

/**
 * Send one inner message from the phone side through the real AEAD codec.
 * @param {import('../core/aead.mjs').FrameCrypto} phoneCrypto Phone direction.
 * @param {import('../plugin/session-manager.mjs').SessionManager} manager Manager.
 * @param {object} message Inner message.
 */
export function phoneSend(phoneCrypto, manager, message) {
  const frame = phoneCrypto.seal(JSON.stringify(message))
  manager.handleE2e(frame)
  return frame
}

/**
 * Complete handshake and exchange peer.hello in both directions.
 * @param {{manager: import('../plugin/session-manager.mjs').SessionManager, link: FakeLink, phoneIdentity: object, pcIdentity: object, managerPcName?: string}} input
 * @returns {Promise<{initiator: object, session: object, phoneCrypto: object}>}
 */
export async function completeSession(input) {
  const result = await completeHandshake(input)
  phoneSend(result.phoneCrypto, input.manager, {
    v: 1,
    type: 'peer.hello',
    role: 'phone',
    caps: ['workspace/1', 'pclink-x25519-ed25519-chacha20poly1305-1'],
    dsh: { version: '0.2.2-rc.1' },
    app: { name: 'phoneDSH', version: '0.1.0' },
    name: 'iPhone',
  })
  if (!result.session.helloReceived) throw new Error('phone hello was not accepted')
  return result
}
