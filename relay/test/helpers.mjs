// SPDX-License-Identifier: MIT
// Shared test helpers for the PCLink relay suite.
//
// These are tests, not relay code: reading the frozen fixtures is expected.
// The relay implementation itself never imports node:fs.

import { createHash, createPrivateKey, createPublicKey, randomBytes, sign } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocket } from 'ws'
import { createRelayServer } from '../src/server.mjs'
import { machineIdFromPublicKey, relayAuthTranscript } from '../src/identity.mjs'

const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex')
const SUITE = 'pclink-x25519-ed25519-chacha20poly1305-1'
const SPEC_ROOT = fileURLToPath(new URL('../../spec/pclink/v1/', import.meta.url))

export function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

export async function waitFor(predicate, timeoutMs = 2000, intervalMs = 10) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await delay(intervalMs)
  }
  throw new Error('waitFor timed out')
}

export function readGolden(name) {
  return JSON.parse(readFileSync(join(SPEC_ROOT, 'golden', name), 'utf8'))
}

export function createIdentity(label) {
  let seed
  if (label === undefined) {
    seed = randomBytes(32)
  } else {
    seed = createHash('sha256').update(Buffer.from(label, 'utf8')).digest()
  }
  const privateKey = createPrivateKey({
    key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  })
  const publicKey = createPublicKey(privateKey)
  const spki = publicKey.export({ format: 'der', type: 'spki' })
  const rawPublicKey = Buffer.from(spki.subarray(spki.length - 32))
  return {
    label,
    privateKey,
    publicKey,
    rawPublicKey,
    publicKeyB64: rawPublicKey.toString('base64url'),
    machineId: machineIdFromPublicKey(rawPublicKey),
  }
}

export function authFrame(identity, role, relayOrigin, nonce) {
  const nonceRaw = Buffer.from(nonce, 'base64url')
  const signature = sign(null, relayAuthTranscript(relayOrigin, nonceRaw), identity.privateKey)
  return {
    v: 1,
    type: 'peer.auth',
    machineId: identity.machineId,
    publicKey: identity.publicKeyB64,
    role,
    sig: signature.toString('base64url'),
  }
}

export function randomSid() {
  return randomBytes(16).toString('base64url')
}

export function e2eFrame({ from, to, sid = randomSid(), seq = 0, body = 'A'.repeat(22) }) {
  return { v: 1, type: 'e2e', sid, seq, from, to, body }
}

export function handshakeFrame({
  from,
  to,
  sid = randomSid(),
  type = 'session.init',
  code = 'unpaired',
  suite = SUITE,
}) {
  let body
  if (type === 'session.init') {
    body = {
      v: 1,
      type,
      sid,
      suite,
      eph: 'A'.repeat(43),
      nonce: 'A'.repeat(43),
    }
  } else if (type === 'session.resp') {
    body = {
      v: 1,
      type,
      sid,
      eph: 'A'.repeat(43),
      nonce: 'A'.repeat(43),
      sig: 'A'.repeat(86),
      confirm: 'A'.repeat(43),
    }
  } else if (type === 'session.confirm') {
    body = { v: 1, type, sid, sig: 'A'.repeat(86), confirm: 'A'.repeat(43) }
  } else if (type === 'session.reject') {
    body = { v: 1, type, sid, code, sig: 'A'.repeat(86), message: 'test reject' }
  } else {
    throw new Error(`unsupported handshake test type ${type}`)
  }
  return { v: 1, type: 'e2e.handshake', sid, from, to, body }
}

export class RelayClient {
  constructor(ws) {
    this.ws = ws
    this.queue = []
    this.waiters = []
    this.closeInfo = null
    this.closeWaiters = []
    this.autoPong = true
    this.error = null
    ws.on('message', (data, isBinary) => {
      if (isBinary) return
      let message
      try {
        message = JSON.parse(String(data))
      } catch (error) {
        this.error = error
        return
      }
      if (message.type === 'relay.ping' && this.autoPong) {
        try {
          this.send({ v: 1, type: 'relay.pong', nonce: message.nonce })
        } catch {
          // the socket is closing
        }
      }
      this.dispatch(message)
    })
    ws.on('close', (code, reason) => {
      this.closeInfo = { code, reason: String(reason) }
      for (const waiter of this.closeWaiters.splice(0)) {
        clearTimeout(waiter.timer)
        waiter.resolve(this.closeInfo)
      }
      for (const waiter of this.waiters.splice(0)) {
        clearTimeout(waiter.timer)
        waiter.reject(new Error(`connection closed before ${waiter.type} (code ${code})`))
      }
    })
    ws.on('error', error => {
      this.error = error
    })
  }

  dispatch(message) {
    for (let index = 0; index < this.waiters.length; index += 1) {
      const waiter = this.waiters[index]
      if (waiter.type === message.type) {
        this.waiters.splice(index, 1)
        clearTimeout(waiter.timer)
        waiter.resolve(message)
        return
      }
    }
    this.queue.push(message)
  }

  next(type, timeoutMs = 3000) {
    const index = this.queue.findIndex(message => message.type === type)
    if (index !== -1) return Promise.resolve(this.queue.splice(index, 1)[0])
    return new Promise((resolve, reject) => {
      const waiter = {
        type,
        resolve,
        reject,
        timer: setTimeout(() => {
          const at = this.waiters.indexOf(waiter)
          if (at !== -1) this.waiters.splice(at, 1)
          reject(new Error(`timed out waiting for ${type}`))
        }, timeoutMs),
      }
      this.waiters.push(waiter)
    })
  }

  async expectNoMessage(type, waitMs = 100) {
    await delay(waitMs)
    return this.queue.findIndex(message => message.type === type) === -1
  }

  send(message) {
    this.ws.send(JSON.stringify(message))
  }

  sendText(text) {
    this.ws.send(text)
  }

  sendBinary(bytes) {
    this.ws.send(bytes, { binary: true })
  }

  waitClose(timeoutMs = 3000) {
    if (this.closeInfo !== null) return Promise.resolve(this.closeInfo)
    return new Promise((resolve, reject) => {
      const waiter = {
        resolve,
        reject,
        timer: setTimeout(() => {
          const at = this.closeWaiters.indexOf(waiter)
          if (at !== -1) this.closeWaiters.splice(at, 1)
          reject(new Error('timed out waiting for close'))
        }, timeoutMs),
      }
      this.closeWaiters.push(waiter)
    })
  }

  close(code = 1000, reason = 'test done') {
    try {
      if (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING) {
        this.ws.close(code, reason)
      }
    } catch {
      // ignore
    }
  }

  terminate() {
    try {
      this.ws.terminate()
    } catch {
      // ignore
    }
  }

  get readyState() {
    return this.ws.readyState
  }
}

export async function startRelay(overrides = {}) {
  const relay = createRelayServer({
    host: '127.0.0.1',
    port: 0,
    publicOrigin: 'http://127.0.0.1:0',
    quiet: true,
    heartbeatMinMs: 10_000,
    heartbeatMaxMs: 10_000,
    phoneIdleMs: 600_000,
    ...overrides,
  })
  await relay.listen()
  return relay
}

export async function connectClient({
  relay,
  identity,
  role,
  autoAuth = true,
  autoPong = true,
  headers,
  authOverride,
}) {
  const ws = new WebSocket(`ws://127.0.0.1:${relay.port}/`, headers === undefined ? undefined : { headers })
  const client = new RelayClient(ws)
  client.autoPong = autoPong
  const challenge = await client.next('relay.challenge')
  if (!autoAuth) return { client, challenge }
  if (identity === undefined) throw new Error('connectClient requires an identity when autoAuth is true')
  const frame = authOverride ?? authFrame(identity, role, challenge.relay, challenge.nonce)
  client.send(frame)
  const ready = await client.next('relay.ready')
  return { client, challenge, ready }
}


export function openClient({ relay, headers }) {
  const ws = new WebSocket(`ws://127.0.0.1:${relay.port}/`, headers === undefined ? undefined : { headers })
  return new RelayClient(ws)
}

export async function connectRaw({ relay, headers, autoPong = true }) {
  const ws = new WebSocket(`ws://127.0.0.1:${relay.port}/`, headers === undefined ? undefined : { headers })
  const client = new RelayClient(ws)
  client.autoPong = autoPong
  const challenge = await client.next('relay.challenge')
  return { client, challenge }
}

export function captureLogger() {
  const lines = []
  return {
    lines,
    logger: {
      info(event, fields = {}) {
        lines.push({ event, ...fields })
      },
    },
    text() {
      return lines.map(line => JSON.stringify(line)).join('\n')
    },
  }
}
