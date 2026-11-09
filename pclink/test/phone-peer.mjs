/**
 * Test-only PCLink phone client: real relay auth, pairing MACs, E2E handshake,
 * AEAD calls/streams, chunk reassembly and signed-reject verification.
 */
import { b64urlDecode, b64urlEncode, randomBytes } from '../core/encoding.mjs'
import { parseStrictJsonObject } from '../core/json.mjs'
import { ed25519Sign } from '../core/identity.mjs'
import {
  buildPairAuth,
  buildPairFinal,
  buildPhoneRecord,
  crockfordDecode,
  normalizeManualCode,
  pairKeyFor,
  pairTranscriptHash,
  parseQrUri,
  rendezvousFor,
  verifyPairConfirm,
  verifyPairHello,
} from '../core/pairing.mjs'
import {
  HandshakeInitiator,
  SUITE,
  verifySessionReject,
} from '../core/handshake.mjs'
import { FrameCrypto } from '../core/aead.mjs'
import { ChunkReassembler } from '../core/chunking.mjs'
import { pclinkError } from '../core/errors.mjs'

const DEFAULT_TIMEOUT = 20_000

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/** Queue with timeout-aware waiting. */
class Queue {
  constructor() {
    this.items = []
    this.waiters = []
  }

  push(item) {
    const waiter = this.waiters.shift()
    if (waiter !== undefined) {
      clearTimeout(waiter.timer)
      waiter.resolve(item)
      return
    }
    this.items.push(item)
  }

  async next(timeoutMs = DEFAULT_TIMEOUT, label = 'item') {
    if (this.items.length > 0) return this.items.shift()
    let timer
    const timeout = new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), timeoutMs)
    })
    const item = new Promise(resolve => this.waiters.push({ resolve, timer }))
    try {
      return await Promise.race([item, timeout])
    } finally {
      clearTimeout(timer)
    }
  }

  async until(predicate, timeoutMs = DEFAULT_TIMEOUT, label = 'matching item') {
    const deadline = Date.now() + timeoutMs
    for (;;) {
      const remaining = Math.max(1, deadline - Date.now())
      const item = await this.next(remaining, label)
      if (predicate(item)) return item
    }
  }

  get length() {
    return this.items.length
  }
}

/** One phone identity + relay/E2E client used by the integration test. */
export class PhonePeer {
  /**
   * @param {{origin: string, identity: object, relayUrl?: string}} options Phone identity and relay.
   */
  constructor(options) {
    this.origin = options.origin
    this.relayUrl = options.relayUrl ?? `${options.origin.startsWith('https://') ? 'wss' : 'ws'}://${options.origin.slice(options.origin.indexOf('://') + 3)}/`
    this.identity = options.identity
    this.socket = undefined
    this.frames = new Queue()
    this.inner = new Queue()
    this.calls = new Map()
    this.streams = new Map()
    this.resultReassembler = new ChunkReassembler()
    this.phoneCrypto = undefined
    this.pcMachineId = undefined
    this.pcPublicKey = undefined
    this.pcName = undefined
    this.record = undefined
    this.closed = false
    this.sessionClosed = undefined
    this.notices = []
    this.log = options.log ?? (() => {})
  }

  async connect() {
    const socket = new WebSocket(this.relayUrl)
    this.socket = socket
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('relay connect timeout')), 10_000)
      socket.addEventListener('open', () => { clearTimeout(timer); resolve() }, { once: true })
      socket.addEventListener('error', event => { clearTimeout(timer); reject(new Error(`relay error ${String(event.error?.message ?? '')}`)) }, { once: true })
    })
    socket.addEventListener('message', event => this.onFrame(parseStrictJsonObject(String(event.data))))
    socket.addEventListener('close', event => {
      this.closed = true
      this.log(`phone relay closed code=${String(event.code)}`)
      for (const call of this.calls.values()) call.reject(pclinkError('session_expired', 'relay closed'))
      this.calls.clear()
    })
    const challenge = await this.frames.until(frame => frame.type === 'relay.challenge', 10_000, 'relay.challenge')
    if (challenge.relay !== this.origin) throw pclinkError('auth_failed', 'relay origin mismatch')
    const nonce = b64urlDecode(challenge.nonce, { length: 32 })
    const transcript = Buffer.concat([
      Buffer.from('pclink-v1/relay-auth', 'utf8'), Buffer.from([0]),
      Buffer.from(challenge.relay, 'utf8'), Buffer.from([0]), nonce,
    ])
    const signature = signEd25519(this.identity, transcript)
    this.send({
      v: 1, type: 'peer.auth',
      machineId: this.identity.machineId,
      publicKey: b64urlEncode(this.identity.publicKey),
      role: 'phone',
      sig: b64urlEncode(signature),
    })
    const ready = await this.frames.until(frame => frame.type === 'relay.ready', 10_000, 'relay.ready')
    if (ready.machineId !== this.identity.machineId || ready.role !== 'phone') throw pclinkError('auth_failed', 'relay.ready mismatch')
    return this
  }

  send(frame) {
    if (this.socket === undefined || this.socket.readyState !== 1) throw pclinkError('unavailable', 'relay socket is not open')
    this.socket.send(JSON.stringify(frame))
  }

  onFrame(frame) {
    if (frame.type === 'e2e') {
      if (this.phoneCrypto === undefined) {
        this.log('e2e before handshake; dropping')
        return
      }
      let opened
      try {
        opened = this.phoneCrypto.open(frame)
      } catch (error) {
        this.log(`phone AEAD failure sid=${frame.sid} seq=${String(frame.seq)}: ${error.message}`)
        return
      }
      this.onInner(parseStrictJsonObject(opened.plaintext))
      return
    }
    this.frames.push(frame)
  }

  onInner(message) {
    if (message.type === 'rpc.result') return this.finishCall(message)
    if (message.type === 'rpc.result.chunk') {
      const step = this.resultReassembler.push(message)
      if (step.complete) this.finishCall(step.value)
      return
    }
    if (message.type === 'rpc.stream.item' || message.type === 'rpc.stream.chunk' || message.type === 'rpc.stream.end' || message.type === 'rpc.stream.error') {
      return this.onStreamFrame(message)
    }
    if (message.type === 'session.close') {
      this.closed = true
      this.sessionClosed = message
      const stream = this.streams
      for (const record of stream.values()) {
        record.queue.push({ type: 'session.close', code: message.code })
      }
      for (const [id, call] of this.calls) {
        call.reject(Object.assign(pclinkError(message.code ?? 'session_expired', message.message ?? 'session closed'), { id }))
      }
      this.calls.clear()
      this.inner.push(message)
      return
    }
    if (message.type === 'pclink.notice') {
      this.notices.push(message)
      this.inner.push(message)
      return
    }
    this.inner.push(message)
  }

  finishCall(message) {
    const call = this.calls.get(message.id)
    if (call === undefined) return
    this.calls.delete(message.id)
    clearTimeout(call.timer)
    if (message.ok === true) call.resolve(message.result)
    else call.reject(Object.assign(pclinkError(message.error?.code ?? 'unavailable', message.error?.message ?? 'rpc error'), { dshError: message.error }))
  }

  onStreamFrame(message) {
    const record = this.streams.get(message.streamId)
    if (record === undefined) { this.log(`stream frame for unknown id=${String(message.streamId)} type=${message.type}`); return }
    if (message.type === 'rpc.stream.item') {
      record.queue.push({ type: 'item', value: message.value })
      return
    }
    if (message.type === 'rpc.stream.chunk') {
      const step = record.reassembler.push(message)
      if (step.complete) record.queue.push({ type: 'item', value: step.value })
      return
    }
    if (message.type === 'rpc.stream.end') {
      record.queue.push({ type: 'end' })
      this.streams.delete(message.streamId)
      return
    }
    record.queue.push({ type: 'error', error: message.error })
    this.streams.delete(message.streamId)
  }

  async pairWithQr(uri, options = {}) {
    const parsed = parseQrUri(uri)
    if (parsed.origin !== this.origin) throw pclinkError('auth_failed', 'QR origin mismatch')
    this.pcMachineId = parsed.machineId
    this.pcPublicKey = b64urlDecode(parsed.publicKey, { length: 32 })
    this.pcName = parsed.name
    const secret = b64urlDecode(parsed.secret, { length: 16 })
    return this.pairWithSecret(secret, options)
  }

  pairWithManual(code, options = {}) {
    return this.pairWithSecret(crockfordDecode(normalizeManualCode(code)), options)
  }

  async pairWithSecret(secret, options = {}) {
    const relayOrigin = this.origin
    const rendezvous = rendezvousFor(secret, relayOrigin)
    const pairKey = pairKeyFor(secret)
    this.send({ v: 1, type: 'relay.pair.join', rendezvous })
    await this.frames.until(frame => frame.type === 'relay.pair.joined' && frame.rendezvous === rendezvous, 15_000, 'relay.pair.joined')
    const message = await this.frames.until(frame => frame.type === 'relay.pair.message' && frame.rendezvous === rendezvous && frame.payload?.type === 'pair.hello', 15_000, 'pair.hello')
    const verified = verifyPairHello(message.payload, {
      pairKey,
      relay: relayOrigin,
      ...(this.pcPublicKey === undefined ? {} : { pinnedPublicKey: this.pcPublicKey }),
      ...(this.pcMachineId === undefined ? {} : { pinnedMachineId: this.pcMachineId }),
    })
    this.pcMachineId = verified.machineId
    this.pcPublicKey = verified.publicKey
    this.pcName = verified.hello.name
    this.record = buildPhoneRecord({ hello: verified.hello, relayOrigin, pairedAt: options.pairedAt })
    const auth = buildPairAuth({
      identity: this.identity,
      name: options.name ?? 'Test iPhone',
      relay: relayOrigin,
      nonce: randomBytes(32),
      peerNonce: b64urlDecode(verified.hello.nonce, { length: 32 }),
      pairKey,
    })
    this.send({ v: 1, type: 'relay.pair.message', rendezvous, payload: auth })
    const next = await this.frames.until(frame => frame.rendezvous === rendezvous
      && ((frame.type === 'relay.pair.message' && frame.payload?.type === 'pair.confirm') || frame.type === 'relay.pair.close'), 15_000, 'pair.confirm or close')
    if (next.type === 'relay.pair.close') {
      throw pclinkError(next.reason === 'auth_failed' ? 'auth_failed' : 'unavailable', `pairing closed: ${next.reason}`)
    }
    const confirmMessage = next
    const transcript = pairTranscriptHash(verified.hello, auth)
    verifyPairConfirm(confirmMessage.payload, {
      pairKey,
      expectedNonce: b64urlDecode(verified.hello.nonce, { length: 32 }),
      expectedPeerNonce: b64urlDecode(auth.nonce, { length: 32 }),
      transcriptHash: transcript.transcriptHash,
    })
    const final = buildPairFinal({
      pairKey,
      nonce: b64urlDecode(auth.nonce, { length: 32 }),
      peerNonce: b64urlDecode(verified.hello.nonce, { length: 32 }),
      transcriptHash: transcript.transcriptHash,
    })
    this.send({ v: 1, type: 'relay.pair.message', rendezvous, payload: final })
    const close = await this.frames.until(frame => frame.type === 'relay.pair.close' && frame.rendezvous === rendezvous, 15_000, 'pair.close')
    if (close.reason !== 'paired') throw pclinkError(close.reason === 'auth_failed' ? 'auth_failed' : 'unavailable', `pairing closed: ${close.reason}`)
    return { record: this.record, hello: verified.hello }
  }

  async handshake(options = {}) {
    if (this.pcMachineId === undefined || this.pcPublicKey === undefined) throw pclinkError('unpaired', 'no pinned PC identity')
    const initiator = new HandshakeInitiator({
      identity: this.identity,
      pcMachineId: this.pcMachineId,
      pcPublicKey: this.pcPublicKey,
      ...(options.sid === undefined ? {} : { sid: options.sid }),
    })
    this.initiator = initiator
    this.send({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: this.identity.machineId, to: this.pcMachineId, body: initiator.buildInit() })
    const resp = await this.frames.until(frame => frame.type === 'e2e.handshake' && frame.sid === initiator.sid && frame.body?.type === 'session.resp', 15_000, 'session.resp')
    const confirm = initiator.acceptResp(resp.body)
    this.phoneCrypto = new FrameCrypto({
      sendKey: initiator.keys.phoneToPc,
      recvKey: initiator.keys.pcToPhone,
      sid: initiator.sid,
      from: this.identity.machineId,
      to: this.pcMachineId,
    })
    this.closed = false
    this.send({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: this.identity.machineId, to: this.pcMachineId, body: confirm })
    const hello = await this.inner.until(message => message.type === 'peer.hello', 15_000, 'PC peer.hello')
    this.sendInner({
      v: 1,
      type: 'peer.hello',
      role: 'phone',
      caps: ['workspace/1', SUITE],
      dsh: { version: '0.2.2-rc.1', commit: '66491b05' },
      app: { name: 'phoneDSH', version: '0.1.0' },
      name: 'Test iPhone',
    })
    return { hello, sid: initiator.sid }
  }

  sendInner(message) {
    if (this.phoneCrypto === undefined) throw pclinkError('unavailable', 'no E2E session')
    this.send(this.phoneCrypto.seal(JSON.stringify(message)))
  }

  call(endpoint, args, timeoutMs = 60_000) {
    const id = `call-${randomBytes(6).toString('hex')}`
    const promise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.calls.delete(id)
        reject(pclinkError('unavailable', `call ${endpoint} timed out`))
      }, timeoutMs)
      this.calls.set(id, { resolve, reject, timer, endpoint })
    })
    this.sendInner({ type: 'rpc.call', id, endpoint, args })
    return promise
  }

  openStream(endpoint, payload, label = endpoint) {
    const streamId = `stream-${randomBytes(6).toString('hex')}`
    const record = {
      streamId,
      label,
      queue: new Queue(),
      reassembler: new ChunkReassembler(),
    }
    this.streams.set(streamId, record)
    this.sendInner({ type: 'rpc.stream.open', streamId, endpoint, payload })
    record.next = (timeoutMs, text) => record.queue.next(timeoutMs, text ?? label)
    record.until = async (predicate, timeoutMs, text) => {
      for (;;) {
        const item = await record.queue.next(timeoutMs, text ?? label)
        if (item.type === 'error') throw Object.assign(pclinkError(item.error?.code ?? 'unavailable', item.error?.message ?? 'stream error'), { streamError: item.error })
        if (item.type === 'end' && !predicate(item)) throw Object.assign(pclinkError('unavailable', 'stream ended'), { streamEnded: true })
        if (item.type === 'session.close') throw pclinkError(item.code ?? 'session_expired', 'session closed')
        if (predicate(item)) return item
      }
    }
    record.cancel = () => this.sendInner({ type: 'rpc.stream.cancel', streamId })
    record.close = () => this.streams.delete(streamId)
    return record
  }

  async reconnectHandshakeExpectingReject() {
    if (this.pcMachineId === undefined || this.pcPublicKey === undefined) throw new Error('no pinned PC key')
    const initiator = new HandshakeInitiator({
      identity: this.identity,
      pcMachineId: this.pcMachineId,
      pcPublicKey: this.pcPublicKey,
    })
    this.send({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: this.identity.machineId, to: this.pcMachineId, body: initiator.buildInit() })
    const reject = await this.frames.until(frame => frame.type === 'e2e.handshake' && frame.sid === initiator.sid && frame.body?.type === 'session.reject', 15_000, 'session.reject')
    const verified = verifySessionReject(this.pcPublicKey, reject.body, { sid: initiator.sid, th1: initiator.th1 })
    return { reject: reject.body, verified, initiator }
  }

  async close() {
    try {
      if (this.phoneCrypto !== undefined && !this.closed) {
        this.sendInner({ type: 'session.close', code: 'unavailable', message: 'test ended' })
      }
    } catch {
      // Socket may already be gone.
    }
    this.closed = true
    try { this.socket?.close(1000, 'test done') } catch { /* closed */ }
    await delay(20)
  }
}

function signEd25519(identity, bytes) {
  return ed25519Sign(identity.privateKey, bytes)
}
