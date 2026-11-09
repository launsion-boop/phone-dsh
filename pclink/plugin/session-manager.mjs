/**
 * PC-side E2E sessions: handshake responder, AEAD dispatch, DSH forwarding,
 * streams/chunking/cancel, notices, idle close and unpair handling (§5-§7).
 */
import { randomUUID } from 'node:crypto'
import {
  b64urlDecode,
  fingerprintOf,
  formatRfc3339,
  sha256,
} from '../core/encoding.mjs'
import { pclinkError, SESSION_REJECT_CODES } from '../core/errors.mjs'
import { FrameCrypto } from '../core/aead.mjs'
import { ChunkReassembler, encodeStreamValue, encodeUnaryResult } from '../core/chunking.mjs'
import {
  buildSessionReject,
  HandshakeResponder,
  initTranscript,
  SUITE,
  validateSessionConfirm,
  validateSessionInit,
  validateSessionReject,
} from '../core/handshake.mjs'
import {
  decodeInnerMessage,
  encodeInnerMessage,
  isDshVersionTested,
  isForbiddenAdminEndpoint,
  isReservedErrorType,
  isReservedType,
  jsonByteLength,
  missingRequiredCaps,
  normalizeFailure,
  reservedErrorReply,
  validateInnerMessage,
  validateSessionClose,
} from '../core/inner.mjs'
import { parseStrictJsonObject } from '../core/json.mjs'
import { buildPairingNotice } from '../core/pairing.mjs'
import { validateE2eFrame, validateE2eHandshakeOuter } from '../core/relay.mjs'
import { runAsPclinkRemote } from './remote-context.mjs'

/** E2E idle timeout: 15 minutes (§5.5). */
export const E2E_IDLE_MS = 900_000
/** Handshake step budget: 10 s (§5.2). */
export const HANDSHAKE_STEP_MS = 10_000
/** At most 10 handshake attempts per peer per minute (§5.1). */
export const HANDSHAKE_ATTEMPTS_PER_MINUTE = 10
/** At most 64 pending handshakes process-wide (§5.1). */
export const MAX_PENDING_HANDSHAKES = 64
/** Sid cache entries (§5.1). */
export const SID_CACHE_LIMIT = 4096
/** Sid cache lifetime (§5.1). */
export const SID_CACHE_TTL_MS = 300_000
/** Unknown-peer signed rejects per from per minute. */
export const UNKNOWN_REJECTS_PER_FROM = 5
/** Unknown-peer signed rejects process-wide per minute. */
export const UNKNOWN_REJECTS_GLOBAL = 120
/** Cancel must settle within 30 s (§6.2). */
export const CANCEL_SETTLE_MS = 30_000

function defaultTimers() {
  return {
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: handle => clearTimeout(handle),
    now: () => Date.now(),
  }
}

/** A fixed-window rate counter. */
export class RateWindow {
  /**
   * @param {{limit: number, windowMs: number, now: () => number}} options Limit definition.
   */
  constructor(options) {
    this.limit = options.limit
    this.windowMs = options.windowMs
    this.now = options.now
    this.count = 0
    this.startedAt = -Infinity
  }

  roll() {
    const now = this.now()
    if (now - this.startedAt >= this.windowMs) {
      this.startedAt = now
      this.count = 0
    }
  }

  /**
   * Consume one slot when available.
   * @returns {boolean} true when this attempt is allowed.
   */
  allow() {
    this.roll()
    if (this.count >= this.limit) return false
    this.count += 1
    return true
  }

  clear() {
    this.count = 0
    this.startedAt = -Infinity
  }
}

/** LRU sid cache with a five-minute lifetime (§5.1). */
export class SidCache {
  /**
   * @param {{limit?: number, ttlMs?: number, now?: () => number}} [options] Limits.
   */
  constructor(options = {}) {
    this.limit = options.limit ?? SID_CACHE_LIMIT
    this.ttlMs = options.ttlMs ?? SID_CACHE_TTL_MS
    this.now = options.now ?? Date.now
    this.entries = new Map()
  }

  purge() {
    const now = this.now()
    for (const [sid, entry] of this.entries) {
      if (now - entry.at > this.ttlMs) this.entries.delete(sid)
    }
  }

  /**
   * @param {string} sid Sid.
   * @returns {{state: string, at: number, th1?: string} | undefined} cached entry.
   */
  get(sid) {
    this.purge()
    const entry = this.entries.get(sid)
    if (entry === undefined) return undefined
    // Refresh LRU recency without extending the five-minute lifetime.
    this.entries.delete(sid)
    this.entries.set(sid, entry)
    return entry
  }

  /**
   * @param {string} sid Sid.
   * @param {{state: string, th1?: string}} value Entry state.
   */
  set(sid, value) {
    this.purge()
    this.entries.delete(sid)
    this.entries.set(sid, { ...value, at: this.now() })
    while (this.entries.size > this.limit) {
      const oldest = this.entries.keys().next().value
      this.entries.delete(oldest)
    }
  }

  /** @param {string} sid Sid. @returns {boolean} presence after purge. */
  has(sid) {
    return this.get(sid) !== undefined
  }

  /** Empty the cache. */
  clear() {
    this.entries.clear()
  }
}

function emptyUplink() {
  return {
    [Symbol.asyncIterator]() {
      return {
        async next() { return { done: true, value: undefined } },
        async return() { return { done: true, value: undefined } },
      }
    },
  }
}

function timeoutAfter(timers, ms) {
  let handle
  const promise = new Promise(resolve => {
    handle = timers.setTimeout(() => resolve(false), ms)
    handle?.unref?.()
  })
  return { promise, cancel: () => timers.clearTimeout(handle) }
}

/** E2E session manager for one PC plugin process. */
export class SessionManager {
  /**
   * @param {{
   *   connection: {createPeer: Function, createSharedFetchHandler: Function},
   *   gateway: {wireStream: {open: Function, failure?: Function}},
   *   store: import('./state.mjs').PclinkStore,
   *   link: {send: (frame: object) => boolean, waitForDrain?: () => Promise<void>},
   *   pcName: string,
   *   appVersion: string,
   *   dsh: {version: string, commit?: string},
   *   timers?: {setTimeout: Function, clearTimeout: Function, now: () => number},
   *   log?: (...args: unknown[]) => void,
   *   onOnlineChange?: () => void,
   *   onPeerUnpaired?: (peerMachineId: string) => void,
   *   idleMs?: number,
   *   cancelSettleMs?: number,
   * }} options Dependencies.
   */
  constructor(options) {
    this.connection = options.connection
    this.gateway = options.gateway
    this.store = options.store
    this.link = options.link
    this.pcName = options.pcName
    this.appVersion = options.appVersion
    this.dsh = {
      version: /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(options.dsh?.version ?? '') ? options.dsh.version : '0.0.0',
      ...(typeof options.dsh?.commit === 'string' && /^[0-9a-f]{7,64}$/.test(options.dsh.commit) ? { commit: options.dsh.commit } : {}),
    }
    this.timers = options.timers ?? defaultTimers()
    this.log = options.log ?? (() => {})
    this.onOnlineChange = options.onOnlineChange ?? (() => {})
    this.onPeerUnpaired = options.onPeerUnpaired ?? (() => {})
    this.idleMs = options.idleMs ?? E2E_IDLE_MS
    this.cancelSettleMs = options.cancelSettleMs ?? CANCEL_SETTLE_MS
    this.sessions = new Map()
    this.pending = new Map()
    this.sidCache = new SidCache({ now: this.timers.now })
    this.attemptsByPeer = new Map()
    this.unknownByFrom = new Map()
    this.unknownGlobal = new RateWindow({ limit: UNKNOWN_REJECTS_GLOBAL, windowMs: 60_000, now: this.timers.now })
    this.versionWarnings = []
    this.reassemblers = new Map()
    this.stopped = false
  }

  get machineId() {
    return this.store.identity.machineId
  }

  /** @returns {Set<string>} peer machineIds with an established, not-idle session. */
  onlinePeers() {
    const peers = new Set()
    for (const session of this.sessions.values()) {
      if (!session.closed && session.established) peers.add(session.peerMachineId)
    }
    return peers
  }

  /** Notify status observers. */
  changed() {
    try { this.onOnlineChange() } catch { /* status observers must not break sessions */ }
  }

  /** Build the PC's first AEAD message (also used by tests). */
  peerHello() {
    return {
      v: 1,
      type: 'peer.hello',
      role: 'pc',
      caps: ['workspace/1', SUITE],
      dsh: { ...this.dsh },
      app: { name: 'dsh-pclink', version: this.appVersion },
      name: this.pcName,
    }
  }

  /** @returns {boolean} whether this sid has an active session. */
  hasSession(sid) {
    return this.sessions.has(sid)
  }

  /** @returns {Record<string, unknown> | undefined} active session by sid (test helper). */
  session(sid) {
    return this.sessions.get(sid)
  }

  /** @returns {Record<string, unknown> | undefined} pending handshake by sid (test helper). */
  pendingHandshake(sid) {
    return this.pending.get(sid)
  }

  /**
   * Handle one `e2e.handshake` outer frame.
   * @param {Record<string, unknown>} frame Parsed outer frame.
   */
  handleHandshake(frame) {
    if (this.stopped) return
    let outer
    try {
      outer = validateE2eHandshakeOuter(frame)
    } catch (error) {
      this.log(`dropping malformed e2e.handshake: ${error.message}`)
      return
    }
    if (outer.to !== this.machineId || outer.from === this.machineId) return
    const body = outer.body
    if (body?.type === 'session.init') return this.handleInit(outer, body)
    if (body?.type === 'session.confirm') return this.handleConfirm(outer, body)
    if (body?.type === 'session.reject') return this.handlePhoneReject(outer, body)
    this.log(`wrong-direction handshake body ${String(body?.type)} from ${outer.from}`)
    // A phone must never send session.resp; answer with an unsigned bad_frame
    // reject (only a PC reject of a valid init carries a signature).
    this.link.send({
      v: 1,
      type: 'e2e.handshake',
      sid: outer.sid,
      from: this.machineId,
      to: outer.from,
      body: { v: 1, type: 'session.reject', sid: outer.sid, code: 'bad_frame', message: 'wrong-direction handshake body' },
    })
  }

  handleInit(outer, body) {
    let init
    try {
      init = validateSessionInit(body)
    } catch (error) {
      this.log(`dropping syntactically invalid session.init: ${error.message}`)
      return
    }
    let th1
    try {
      th1 = sha256(initTranscript({
        phoneMachineId: outer.from,
        pcMachineId: outer.to,
        sid: init.sid,
        suite: typeof init.suite === 'string' ? init.suite : '',
        ephPhone: b64urlDecode(init.eph, { length: 32 }),
        noncePhone: b64urlDecode(init.nonce, { length: 32 }),
      }))
    } catch (error) {
      this.log(`dropping session.init with invalid fields: ${error.message}`)
      return
    }
    if (outer.sid !== init.sid) {
      this.sendRejectTo(outer.from, init.sid, 'bad_frame', th1, 'outer/body sid mismatch')
      return
    }
    const record = this.store.usableRecord(outer.from)
    if (record === undefined) {
      const fromWindow = this.unknownByFrom.get(outer.from) ?? new RateWindow({
        limit: UNKNOWN_REJECTS_PER_FROM, windowMs: 60_000, now: this.timers.now,
      })
      this.unknownByFrom.set(outer.from, fromWindow)
      if (!fromWindow.allow() || !this.unknownGlobal.allow()) return
      this.sendRejectTo(outer.from, init.sid, 'unpaired', th1, 'no pairing record')
      return
    }
    const attempts = this.attemptsByPeer.get(outer.from) ?? new RateWindow({
      limit: HANDSHAKE_ATTEMPTS_PER_MINUTE, windowMs: 60_000, now: this.timers.now,
    })
    this.attemptsByPeer.set(outer.from, attempts)
    if (!attempts.allow()) {
      this.sendRejectTo(outer.from, init.sid, 'rate_limited', th1, 'handshake rate limited')
      return
    }
    if ([...this.pending.values()].some(pending => pending.peerMachineId === outer.from)) {
      this.sendRejectTo(outer.from, init.sid, 'rate_limited', th1, 'handshake already in progress')
      return
    }
    if (this.pending.size >= MAX_PENDING_HANDSHAKES) {
      this.sendRejectTo(outer.from, init.sid, 'rate_limited', th1, 'too many pending handshakes')
      return
    }
    if (this.sidCache.has(init.sid) || this.sessions.has(init.sid) || this.pending.has(init.sid)) {
      this.sendRejectTo(outer.from, init.sid, 'replay', th1, 'sid was already used')
      return
    }
    this.sidCache.set(init.sid, { state: 'pending', th1: th1.toString('base64url') })
    if (init.suite !== SUITE) {
      this.sidCache.set(init.sid, { state: 'rejected', th1: th1.toString('base64url') })
      this.sendRejectTo(outer.from, init.sid, 'version_unsupported', th1, 'unsupported suite')
      return
    }
    const responder = new HandshakeResponder({
      identity: this.store.identity,
      phoneMachineId: outer.from,
      phonePublicKey: b64urlDecode(record.peerPublicKey, { length: 32 }),
    })
    let response
    try {
      response = responder.respond(init, { from: outer.from, to: outer.to, sid: outer.sid })
    } catch (error) {
      responder.drop()
      this.sidCache.set(init.sid, { state: 'rejected', th1: th1.toString('base64url') })
      this.sendRejectTo(outer.from, init.sid, error.code === 'version_unsupported' ? error.code : 'auth_failed', th1, error.message)
      return
    }
    const pending = {
      sid: init.sid,
      peerMachineId: outer.from,
      phonePublicKey: record.peerPublicKey,
      responder,
      th1,
      createdAt: this.timers.now(),
      timer: undefined,
    }
    pending.timer = this.timers.setTimeout(() => {
      if (this.pending.get(init.sid) !== pending) return
      this.pending.delete(init.sid)
      responder.drop()
      this.sidCache.set(init.sid, { state: 'rejected', th1: th1.toString('base64url') })
      this.log(`handshake timed out sid=${init.sid}`)
    }, HANDSHAKE_STEP_MS)
    pending.timer?.unref?.()
    this.pending.set(init.sid, pending)
    this.link.send({ v: 1, type: 'e2e.handshake', sid: outer.sid, from: this.machineId, to: outer.from, body: response.resp })
    this.log(`handshake responding sid=${init.sid} peer=${outer.from}`)
  }

  handleConfirm(outer, body) {
    let confirm
    try {
      confirm = validateSessionConfirm(body)
    } catch (error) {
      this.log(`dropping malformed session.confirm: ${error.message}`)
      return
    }
    if (outer.sid !== confirm.sid) {
      const pending = this.pending.get(outer.sid) ?? this.pending.get(confirm.sid)
      const cached = pending?.th1 ?? this.sidCache.get(confirm.sid)?.th1 ?? this.sidCache.get(outer.sid)?.th1
      if (cached !== undefined) {
        const th1 = Buffer.isBuffer(cached) ? cached : b64urlDecode(cached, { length: 32 })
        this.sendRejectTo(outer.from, outer.sid, 'replay', th1, 'confirm sid does not match the handshake')
      }
      if (pending !== undefined) this.dropPending(pending, 'rejected')
      return
    }
    const pending = this.pending.get(confirm.sid)
    if (pending === undefined) {
      const cached = this.sidCache.get(confirm.sid)
      if (cached !== undefined && this.store.usableRecord(outer.from) !== undefined) {
        const th1 = cached.th1 === undefined ? undefined : b64urlDecode(cached.th1, { length: 32 })
        if (th1 !== undefined) this.sendRejectTo(outer.from, confirm.sid, 'replay', th1, 'sid was already used')
      }
      return
    }
    if (pending.peerMachineId !== outer.from) {
      this.sendRejectTo(outer.from, confirm.sid, 'auth_failed', pending.th1, 'confirm from the wrong peer')
      this.dropPending(pending, 'rejected')
      return
    }
    let established
    try {
      established = pending.responder.acceptConfirm(confirm)
    } catch (error) {
      this.sendRejectTo(outer.from, confirm.sid, 'auth_failed', pending.th1, error.message)
      this.dropPending(pending, 'rejected')
      return
    }
    // §5.3: re-read the pairing table at session.confirm. A record removed by
    // unpair during the handshake aborts it and installs no keys.
    const record = this.store.usableRecord(pending.peerMachineId)
    if (record === undefined || record.peerPublicKey !== pending.phonePublicKey) {
      this.sendRejectTo(outer.from, confirm.sid, 'unpaired', pending.th1, 'pairing record was removed')
      this.dropPending(pending, 'rejected')
      return
    }
    this.dropPending(pending, 'established')
    this.establishSession({
      sid: confirm.sid,
      peerMachineId: pending.peerMachineId,
      peerName: record.peerName,
      keys: established.keys,
    })
  }

  handlePhoneReject(outer, body) {
    try {
      validateSessionReject(body)
    } catch {
      return
    }
    const pending = this.pending.get(body.sid)
    if (pending === undefined || pending.peerMachineId !== outer.from) return
    this.dropPending(pending, 'rejected')
    this.log(`phone rejected handshake sid=${body.sid} code=${body.code}`)
  }

  dropPending(pending, state) {
    if (this.pending.get(pending.sid) === pending) this.pending.delete(pending.sid)
    if (pending.timer !== undefined) this.timers.clearTimeout(pending.timer)
    pending.responder.drop()
    this.sidCache.set(pending.sid, { state, th1: pending.th1.toString('base64url') })
  }

  sendRejectTo(peer, sid, code, th1, message) {
    if (!SESSION_REJECT_CODES.includes(code)) code = 'auth_failed'
    const body = buildSessionReject({ identity: this.store.identity }, { sid, code, th1, message })
    return this.link.send({ v: 1, type: 'e2e.handshake', sid, from: this.machineId, to: peer, body })
  }

  establishSession({ sid, peerMachineId, peerName, keys }) {
    const ownerPeer = this.connection.createPeer({ principal: { kind: 'owner' }, interactions: 'answer' })
    const handler = this.connection.createSharedFetchHandler('/api')
    const frameCrypto = new FrameCrypto({
      sendKey: keys.pcToPhone,
      recvKey: keys.phoneToPc,
      sid,
      from: this.machineId,
      to: peerMachineId,
    })
    const session = {
      sid,
      peerMachineId,
      peerName,
      ownerPeer,
      handler,
      frameCrypto,
      established: true,
      helloReceived: false,
      closed: false,
      createdAt: this.timers.now(),
      lastActivity: this.timers.now(),
      idleTimer: undefined,
      streams: new Map(),
      usedStreamIds: new Set(),
      inflightCalls: new Set(),
      reassembler: new ChunkReassembler({ now: this.timers.now }),
      previousSessions: [],
    }
    session.previousSessions = [...this.sessions.values()].filter(candidate => candidate.peerMachineId === peerMachineId && !candidate.closed)
    this.sessions.set(sid, session)
    this.sidCache.set(sid, { state: 'established' })
    this.resetIdle(session)
    this.changed()
    if (!this.sendInner(session, this.peerHello())) {
      this.closeSession(session, 'unavailable', 'failed to send peer.hello')
      return
    }
    this.log(`session established sid=${sid} peer=${peerMachineId}`)
  }

  resetIdle(session) {
    if (session.idleTimer !== undefined) this.timers.clearTimeout(session.idleTimer)
    session.idleTimer = this.timers.setTimeout(() => {
      session.idleTimer = undefined
      if (session.closed) return
      this.closeSession(session, 'session_expired', 'idle timeout', { sendClose: true })
    }, this.idleMs)
    session.idleTimer?.unref?.()
  }

  /**
   * Send one inner message over an established session.
   * @param {Record<string, unknown>} session Session record.
   * @param {Record<string, unknown>} message Inner message.
   * @returns {boolean} true when written.
   */
  sendInner(session, message) {
    if (session.closed) return false
    let frame
    try {
      frame = session.frameCrypto.seal(encodeInnerMessage(message))
    } catch (error) {
      this.log(`session seal failed sid=${session.sid}: ${error.message}`)
      this.closeSession(session, error.code === 'session_expired' ? 'session_expired' : 'frame_too_large', error.message, { sendClose: false })
      return false
    }
    const sent = this.link.send(frame)
    if (sent) {
      session.lastActivity = this.timers.now()
      this.resetIdle(session)
    }
    return sent
  }

  /**
   * Send a chunked or unary result, waiting for the send buffer between frames.
   * @param {Record<string, unknown>} session Session.
   * @param {Record<string, unknown>} resultFrame Complete rpc.result object.
   * @returns {Promise<void>} resolves after the last frame write.
   */
  async sendCallResult(session, resultFrame) {
    if (session.closed) return
    let encoded
    try {
      encoded = encodeUnaryResult(resultFrame)
    } catch (error) {
      encoded = { kind: 'result', frame: { type: 'rpc.result', id: resultFrame.id, ok: false, error: { code: 'frame_too_large', message: 'result exceeds 8 MiB' } } }
    }
    if (encoded.kind === 'result') {
      this.sendInner(session, encoded.frame)
      return
    }
    for (const frame of encoded.frames) {
      if (session.closed) return
      await this.link.waitForDrain?.()
      this.sendInner(session, frame)
    }
  }

  /**
   * Handle one sealed `e2e` outer frame.
   * @param {Record<string, unknown>} value Parsed frame.
   */
  handleE2e(value) {
    if (this.stopped) return
    let frame
    try {
      frame = validateE2eFrame(value)
    } catch (error) {
      this.log(`dropping malformed e2e frame: ${error.message}`)
      return
    }
    const session = this.sessions.get(frame.sid)
    if (session === undefined || session.closed) return
    let opened
    try {
      opened = session.frameCrypto.open(frame)
    } catch (error) {
      const code = ['replay', 'bad_frame', 'auth_failed', 'session_expired'].includes(error.code) ? error.code : 'auth_failed'
      this.log(`session ${code} sid=${session.sid}: ${error.message}`)
      this.closeSession(session, code, error.message, { sendClose: true })
      return
    }
    session.lastActivity = this.timers.now()
    this.resetIdle(session)
    let message
    try {
      message = decodeInnerMessage(opened.plaintext, { direction: 'phone_to_pc' })
    } catch (error) {
      this.closeSession(session, 'bad_frame', `invalid inner message: ${error.message}`, { sendClose: true })
      return
    }
    if (!session.helloReceived) {
      if (message.type === 'session.close') {
        validateSessionClose(message)
        this.handleRemoteClose(session, message)
        return
      }
      if (message.type !== 'peer.hello') {
        this.closeSession(session, 'bad_frame', 'first inner frame is not peer.hello', { sendClose: true })
        return
      }
      const missing = missingRequiredCaps(message.caps)
      if (missing.length > 0) {
        this.closeSession(session, 'version_unsupported', `missing capabilities ${missing.join(',')}`, { sendClose: true })
        return
      }
      if (!isDshVersionTested(message.dsh.version)) {
        const warning = `DSH ${message.dsh.version} is outside the tested range ${'>=0.2.2-rc.1 <0.3.0'} (peer=${session.peerMachineId})`
        this.versionWarnings.push(warning)
        this.log(`warning: ${warning}`)
      }
      session.helloReceived = true
      session.peerHello = message
      this.log(`peer hello sid=${session.sid} peer=${session.peerMachineId} dsh=${message.dsh.version}`)
      for (const older of session.previousSessions ?? []) {
        if (!older.closed) this.closeSession(older, 'rekey', 'rekey completed', { sendClose: true })
      }
      session.previousSessions = []
      this.changed()
      return
    }
    if (message.type === 'peer.hello') {
      this.closeSession(session, 'bad_frame', 'duplicate peer.hello', { sendClose: true })
      return
    }
    if (message.type === 'session.close') {
      this.handleRemoteClose(session, message)
      return
    }
    if (message.type === 'rpc.call') {
      void this.handleCall(session, message)
      return
    }
    if (message.type === 'rpc.stream.open') {
      this.handleStreamOpen(session, message)
      return
    }
    if (message.type === 'rpc.stream.cancel') {
      this.handleStreamCancel(session, message)
      return
    }
    if (isReservedType(message.type)) {
      if (!isReservedErrorType(message.type)) {
        this.sendInner(session, reservedErrorReply(message))
      }
      return
    }
    this.closeSession(session, 'bad_frame', `unexpected inner type ${String(message.type)}`, { sendClose: true })
  }

  handleRemoteClose(session, message) {
    try {
      validateSessionClose(message)
    } catch (error) {
      this.closeSession(session, 'bad_frame', error.message, { sendClose: true })
      return
    }
    if (message.code === 'unpaired') {
      // Phone-initiated unpair is authoritative on the PC through the same
      // tombstone path (§4.6/§5.5).
      try {
        this.onPeerUnpaired(session.peerMachineId)
      } catch (error) {
        this.log(`phone-initiated unpair failed: ${error.message}`)
      }
    }
    this.closeSession(session, message.code, message.message, { sendClose: false })
  }

  /**
   * Close one session: abort streams, drop keys, dispose the owner Peer.
   * @param {Record<string, unknown>} session Session.
   * @param {string} code Close code.
   * @param {string} [message] Human message.
   * @param {{sendClose?: boolean}} [options] Whether to emit session.close first.
   */
  closeSession(session, code, message, options = {}) {
    if (session.closed) return
    if (options.sendClose === true) {
      const close = { type: 'session.close', code, ...(message === undefined ? {} : { message: message.slice(0, 512) }) }
      try {
        const frame = session.frameCrypto.seal(encodeInnerMessage(close))
        this.link.send(frame)
      } catch {
        // The hard cap / closed keys make the best-effort close impossible.
      }
    }
    session.closed = true
    session.established = false
    session.frameCrypto.close()
    if (session.idleTimer !== undefined) this.timers.clearTimeout(session.idleTimer)
    session.idleTimer = undefined
    for (const record of session.streams.values()) {
      record.cancelled = true
      record.terminal = true
      try { record.controller.abort(new Error(`session closed ${code}`)) } catch { /* aborted */ }
    }
    session.streams.clear()
    this.sessions.delete(session.sid)
    const peer = session.ownerPeer
    Promise.resolve(peer?.dispose?.()).catch(error => this.log(`peer dispose failed: ${error.message}`))
    this.changed()
    this.log(`session closed sid=${session.sid} code=${code}`)
  }

  handleRelayOffline(frame) {
    if (frame.to !== this.machineId) return
    if (typeof frame.sid === 'string') {
      const session = this.sessions.get(frame.sid)
      if (session !== undefined) this.closeSession(session, 'session_expired', 'relay reported peer offline', { sendClose: false })
    }
  }

  async handleCall(session, message) {
    if (session.inflightCalls.has(message.id)) {
      this.sendInner(session, {
        type: 'rpc.result', id: message.id, ok: false,
        error: { code: 'bad_frame', message: 'duplicate id' },
      })
      return
    }
    if (isForbiddenAdminEndpoint(message.endpoint)) {
      this.sendInner(session, {
        type: 'rpc.result', id: message.id, ok: false,
        error: { code: 'forbidden', message: 'remote pclink.admin calls are forbidden' },
      })
      return
    }
    if (jsonByteLength(message.args) > 8 * 1024 * 1024) {
      this.sendInner(session, {
        type: 'rpc.result', id: message.id, ok: false,
        error: { code: 'frame_too_large', message: 'args exceed 8 MiB' },
      })
      return
    }
    session.inflightCalls.add(message.id)
    try {
      const rpcId = `pclink-${randomUUID()}`
      const request = new Request(`http://pclink.internal/api/${message.endpoint}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ type: 'client-request', rpcId, method: message.endpoint, payload: { args: message.args } }),
      })
      const response = await runAsPclinkRemote(() => session.handler.fetch(request, session.ownerPeer))
      let resultFrame
      if (response.status !== 200) {
        const code = response.status === 401 || response.status === 403 ? 'unavailable' : 'unavailable'
        const text = response.status === 401 || response.status === 403
          ? 'in-process authentication failure'
          : `in-process HTTP ${String(response.status)}`
        resultFrame = { type: 'rpc.result', id: message.id, ok: false, error: { code, message: text } }
      } else {
        let body
        try {
          body = parseStrictJsonObject(await response.text())
        } catch {
          body = undefined
        }
        if (body === undefined || body.type !== 'server-response' || body.result === undefined || typeof body.result !== 'object') {
          resultFrame = { type: 'rpc.result', id: message.id, ok: false, error: { code: 'unavailable', message: 'malformed in-process response' } }
        } else if (body.result.ok === true) {
          resultFrame = { type: 'rpc.result', id: message.id, ok: true, result: body.result.value }
        } else {
          resultFrame = { type: 'rpc.result', id: message.id, ok: false, error: normalizeFailure(body.result.error) }
        }
      }
      if (session.closed) return
      await this.sendCallResult(session, resultFrame)
    } catch (error) {
      if (!session.closed) {
        this.sendInner(session, {
          type: 'rpc.result', id: message.id, ok: false,
          error: normalizeFailure({ code: 'unavailable', message: error.message }),
        })
      }
    } finally {
      session.inflightCalls.delete(message.id)
    }
  }

  handleStreamOpen(session, message) {
    if (isForbiddenAdminEndpoint(message.endpoint)) {
      this.sendInner(session, {
        type: 'rpc.stream.error', streamId: message.streamId,
        error: { code: 'forbidden', message: 'remote pclink.admin calls are forbidden' },
      })
      return
    }
    if (session.usedStreamIds.has(message.streamId) || session.streams.has(message.streamId)) {
      this.sendInner(session, {
        type: 'rpc.stream.error', streamId: message.streamId,
        error: { code: 'bad_frame', message: 'streamId was already used' },
      })
      return
    }
    if (jsonByteLength(message.payload) > 8 * 1024 * 1024) {
      this.sendInner(session, {
        type: 'rpc.stream.error', streamId: message.streamId,
        error: { code: 'frame_too_large', message: 'payload exceeds 8 MiB' },
      })
      return
    }
    session.usedStreamIds.add(message.streamId)
    const controller = new AbortController()
    const record = {
      streamId: message.streamId,
      endpoint: message.endpoint,
      controller,
      cancelled: false,
      terminal: false,
      paused: false,
      done: Promise.resolve(),
    }
    session.streams.set(message.streamId, record)
    this.log(`stream open id=${record.streamId} endpoint=${record.endpoint}`)
    record.done = this.runStream(session, record, message)
    record.done.catch(error => this.log(`stream ${record.streamId} failed: ${error.message}`))
  }

  async runStream(session, record, message) {
    let iterable
    try {
      iterable = await this.gateway.wireStream.open(
        message.endpoint, message.payload, emptyUplink(), session.ownerPeer, record.controller.signal,
      )
    } catch (error) {
      if (record.cancelled) {
        this.log(`stream open cancelled id=${record.streamId}`)
        this.finishStream(session, record, { end: true })
      } else {
        this.log(`stream open failed id=${record.streamId} endpoint=${record.endpoint}: ${error.message}`)
        this.finishStream(session, record, { error: normalizeFailure(this.failureOf(error)) })
      }
      return
    }
    const iterator = iterable[Symbol.asyncIterator]()
    this.log(`stream carrier open id=${record.streamId} endpoint=${record.endpoint}`)
    let itemCount = 0
    try {
      while (!record.cancelled && !record.terminal && !session.closed) {
        if (session.frameCrypto.needsRekey) {
          record.paused = true
          this.log(`stream ${record.streamId} paused at the rekey threshold`)
          break
        }
        const step = await iterator.next()
        if (step.done === true) break
        if (record.cancelled || record.terminal || session.closed) break
        let encoded
        try {
          encoded = encodeStreamValue(record.streamId, step.value)
        } catch (error) {
          record.terminal = true
          this.sendInner(session, {
            type: 'rpc.stream.error', streamId: record.streamId,
            error: normalizeFailure({ code: error.code ?? 'frame_too_large', message: error.message }),
          })
          try { record.controller.abort(error) } catch { /* aborted */ }
          break
        }
        itemCount += 1
        if (itemCount === 1) this.log(`stream first item id=${record.streamId} endpoint=${record.endpoint}`)
        if (encoded.kind === 'item') {
          this.sendInner(session, encoded.frame)
        } else {
          for (const frame of encoded.frames) {
            if (record.cancelled || session.closed) break
            await this.link.waitForDrain?.()
            this.sendInner(session, frame)
          }
        }
        await this.link.waitForDrain?.()
      }
    } catch (error) {
      if (!record.cancelled && !record.terminal && !session.closed) {
        record.terminal = true
        this.sendInner(session, {
          type: 'rpc.stream.error', streamId: record.streamId,
          error: normalizeFailure(this.failureOf(error)),
        })
      }
    } finally {
      const returned = Promise.resolve()
        .then(() => iterator.return?.())
        .then(() => true)
        .catch(() => true)
      if (record.cancelled) {
        const timer = timeoutAfter(this.timers, this.cancelSettleMs)
        const settled = await Promise.race([returned, timer.promise])
        timer.cancel()
        if (!settled) {
          this.finishStream(session, record, {
            error: { code: 'unavailable', message: 'cancel did not settle' },
          })
          this.closeSession(session, 'session_expired', 'stream cancel did not settle', { sendClose: true })
          return
        }
      } else {
        await returned
      }
      if (!record.terminal && !record.paused && !session.closed) {
        this.log(`stream end id=${record.streamId} items=${String(itemCount ?? 0)}`)
        this.finishStream(session, record, { end: true })
      } else if (!session.closed) {
        session.streams.delete(record.streamId)
      }
    }
  }

  failureOf(error) {
    try {
      const mapped = this.gateway.wireStream?.failure?.(error)
      if (mapped !== null && typeof mapped === 'object') return mapped
    } catch { /* fall through */ }
    return { code: error?.code ?? 'unavailable', message: error?.message ?? String(error), details: error?.details }
  }

  finishStream(session, record, terminal) {
    if (record.terminal) return
    record.terminal = true
    session.streams.delete(record.streamId)
    if (session.closed) return
    if (terminal.end === true) {
      this.sendInner(session, { type: 'rpc.stream.end', streamId: record.streamId })
    } else if (terminal.error !== undefined) {
      this.sendInner(session, { type: 'rpc.stream.error', streamId: record.streamId, error: normalizeFailure(terminal.error) })
    }
  }

  handleStreamCancel(session, message) {
    const record = session.streams.get(message.streamId)
    if (record === undefined || record.terminal) return
    record.cancelled = true
    try {
      record.controller.abort(new Error('pclink rpc.stream.cancel'))
    } catch {
      // Already aborted.
    }
  }

  /**
   * Abort every handshake/session for one peer (authoritative unpair path).
   * @param {string} peerMachineId Peer to abort.
   * @param {{sendClose?: boolean}} [options] Close options.
   */
  abortPeer(peerMachineId, options = {}) {
    for (const pending of [...this.pending.values()]) {
      if (pending.peerMachineId === peerMachineId) this.dropPending(pending, 'rejected')
    }
    for (const session of [...this.sessions.values()]) {
      if (session.peerMachineId === peerMachineId) {
        this.closeSession(session, 'unpaired', 'pairing revoked', { sendClose: options.sendClose ?? true })
      }
    }
  }

  /**
   * Relay connection lost: every E2E session and handshake is dead (§10).
   * Old keys are discarded; the next session needs a fresh handshake.
   */
  handleRelayDown() {
    for (const session of [...this.sessions.values()]) {
      this.closeSession(session, 'session_expired', 'relay connection lost', { sendClose: false })
    }
    for (const pending of [...this.pending.values()]) this.dropPending(pending, 'rejected')
  }

  /** Abort every pending handshake (rotate-identity/unpair-all). */
  abortAllHandshakes() {
    for (const pending of [...this.pending.values()]) this.dropPending(pending, 'rejected')
  }

  /** Send a paired notice to every other established phone (§4.6). */
  notifyPaired(record) {
    const notice = buildPairingNotice(record)
    for (const session of this.sessions.values()) {
      if (session.closed || !session.helloReceived) continue
      if (session.peerMachineId === record.peerMachineId) continue
      this.sendInner(session, notice)
    }
  }

  /** Close every session and pending handshake (plugin shutdown). */
  closeAll() {
    this.stopped = true
    this.abortAllHandshakes()
    for (const session of [...this.sessions.values()]) {
      this.closeSession(session, 'unavailable', 'plugin stopping', { sendClose: true })
    }
  }
}
