/**
 * Relay connection supervision for the PC plugin (§3, §10).
 *
 * Owns `relay.challenge`/`peer.auth`/`relay.ready`, `relay.allow`, heartbeats,
 * replacement/backoff reconnects and the tombstone fail-closed gate. All parsed
 * frames other than the relay-auth handshake are delivered to `onFrame`.
 */
import { b64urlDecode, b64urlEncode, randomBytes } from '../core/encoding.mjs'
import { pclinkError } from '../core/errors.mjs'
import {
  buildRelayAuth,
  parseRelayFrame,
  requireSameOrigin,
  validateRelayChallenge,
  validateRelayReady,
} from '../core/relay.mjs'
import { retryDelay, RETRY_STABLE_MS } from '../core/retry.mjs'

/** Heartbeat interval base with ±5 s jitter (§3.4). */
export const HEARTBEAT_BASE_MS = 25_000
/** Consecutive unanswered pings before close. */
export const MAX_UNANSWERED_PINGS = 2

/**
 * Compute one heartbeat delay in [20 s, 30 s].
 * @param {() => number} random Uniform [0,1) source.
 * @returns {number} delay ms.
 */
export function heartbeatDelay(random = Math.random) {
  return Math.round(HEARTBEAT_BASE_MS + (random() * 2 - 1) * 5_000)
}

/** A relay connection supervisor with injectable socket/timers. */
export class RelayLink {
  /**
   * @param {{
   *   origin: string,
   *   identity: {machineId: string, publicKey: Uint8Array, privateKey: import('node:crypto').KeyObject},
   *   allowlist: () => string[],
   *   onFrame: (frame: Record<string, unknown>) => void,
   *   onState?: (state: {state: string, connectedAt?: number, lastError?: string}) => void,
   *   WebSocketCtor?: typeof WebSocket,
   *   timers?: {setTimeout: Function, clearTimeout: Function, now: () => number},
   *   random?: () => number,
   *   log?: (...args: unknown[]) => void,
   *   canConnect?: () => boolean,
   *   heartbeatBaseMs?: number,
   *   retryStableMs?: number,
   *   maxUnansweredPings?: number,
   *   connectTimeoutMs?: number,
   *   errorGraceMs?: number,
   * }} options Dependencies and limits.
   */
  constructor(options) {
    this.origin = options.origin
    this.identity = options.identity
    this.allowlist = options.allowlist
    this.onFrame = options.onFrame
    this.onState = options.onState ?? (() => {})
    this.WebSocketCtor = options.WebSocketCtor ?? globalThis.WebSocket
    this.timers = options.timers ?? { setTimeout, clearTimeout, now: () => Date.now() }
    this.random = options.random ?? Math.random
    this.log = options.log ?? (() => {})
    this.canConnect = options.canConnect ?? (() => true)
    this.heartbeatBaseMs = options.heartbeatBaseMs
    this.retryStableMs = options.retryStableMs ?? RETRY_STABLE_MS
    this.maxUnansweredPings = options.maxUnansweredPings ?? MAX_UNANSWERED_PINGS
    // A TCP/TLS/upgrade attempt that never reaches `relay.ready` still has to
    // enter the reconnect schedule (CCR-3).
    this.connectTimeoutMs = options.connectTimeoutMs ?? 15_000
    // Runtimes normally emit `close` after `error`, but an upgrade failure can
    // surface only the `error` event; wait this long for the normal close.
    this.errorGraceMs = options.errorGraceMs ?? 250
    this.state = 'offline'
    this.socket = undefined
    this.phase = 'idle'
    this.stopping = false
    this.attempt = 0
    this.reconnectTimer = undefined
    this.heartbeatTimer = undefined
    this.stableTimer = undefined
    this.connectTimer = undefined
    this.errorGraceTimer = undefined
    this.outstandingPings = []
    this.connectedAt = undefined
    this.lastError = undefined
    this.replaced = false
    this.allowlistDeferred = false
  }

  /** Begin connecting (or return when stopped/forbidden). */
  start() {
    this.stopping = false
    this.connect()
  }

  /** Stop the supervisor and close the socket. */
  stop() {
    this.stopping = true
    this.clearConnectionTimers()
    if (this.reconnectTimer !== undefined) {
      this.timers.clearTimeout(this.reconnectTimer)
      this.reconnectTimer = undefined
    }
    const socket = this.socket
    this.socket = undefined
    this.phase = 'idle'
    if (socket !== undefined) {
      try { socket.close(1000, 'pclink stopping') } catch { /* already closed */ }
    }
    this.setState('offline')
  }

  /** Explicit restart after identity rotation. */
  restart() {
    this.stop()
    this.attempt = 0
    this.replaced = false
    this.start()
  }

  /** @returns {boolean} whether the socket is authenticated and ready. */
  get ready() {
    return this.phase === 'ready' && this.state === 'connected'
  }

  setState(state, error) {
    this.state = state
    if (error !== undefined) this.lastError = error
    this.onState({ state, connectedAt: this.connectedAt, lastError: this.lastError })
  }

  connect() {
    if (this.stopping) return
    if (!this.canConnect()) {
      this.log('relay connection suppressed by the fail-closed gate')
      this.setState('offline', 'fail-closed')
      this.scheduleReconnect(true)
      return
    }
    this.clearConnectionTimers()
    this.setState('connecting')
    let socket
    try {
      socket = new this.WebSocketCtor(this.wsUrl)
    } catch (error) {
      this.setState('offline', `WebSocket constructor: ${error.message}`)
      this.scheduleReconnect()
      return
    }
    this.socket = socket
    this.phase = 'awaitingChallenge'
    this.challenge = undefined
    this.outstandingPings = []
    // Every attempt, including a hung TCP/TLS/upgrade, is bounded. The timer is
    // cleared on `relay.ready` or on any disconnect; the failure path below
    // always schedules the next backoff attempt (CCR-3).
    this.connectTimer = this.timers.setTimeout(() => {
      this.connectTimer = undefined
      if (this.socket !== socket || this.phase === 'ready' || this.stopping) return
      this.log(`relay connect timed out after ${String(this.connectTimeoutMs)}ms`)
      this.disconnectSocket(socket, { detail: 'relay connect timeout', closeSocket: true })
    }, this.connectTimeoutMs)
    this.connectTimer?.unref?.()
    socket.addEventListener('open', () => {
      if (this.socket !== socket) return
      this.log('relay socket open; waiting for challenge')
    })
    socket.addEventListener('message', (event) => {
      if (this.socket !== socket) return
      this.handleText(typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString('utf8'))
    })
    socket.addEventListener('close', (event) => {
      this.disconnectSocket(socket, {
        detail: `relay closed code=${String(event.code)}`,
        replaced: event.code === 4001,
        logReason: String(event.reason ?? ''),
      })
    })
    socket.addEventListener('error', (event) => {
      if (this.socket !== socket) return
      const detail = `relay socket error: ${String(event.error?.message ?? event.type)}`
      this.log(detail)
      this.lastError = detail
      // Normally `close` follows immediately and clears this grace timer. If the
      // runtime only reports `error` (e.g. a non-101 upgrade during a relay
      // restart), take the connection down and reconnect instead of stopping.
      if (this.errorGraceTimer !== undefined) return
      this.errorGraceTimer = this.timers.setTimeout(() => {
        this.errorGraceTimer = undefined
        if (this.socket !== socket || this.stopping) return
        this.log('relay socket error without close; reconnecting')
        this.disconnectSocket(socket, { detail, closeSocket: true })
      }, this.errorGraceMs)
      this.errorGraceTimer?.unref?.()
    })
  }

  /**
   * Detach one socket and enter the reconnect schedule. Idempotent: the first
   * caller (close, error grace, connect timeout, heartbeat, protocol failure)
   * wins; later events for the same socket are ignored.
   * @param {WebSocket} socket Socket that failed.
   * @param {{detail: string, replaced?: boolean, closeSocket?: boolean, closeCode?: number, closeReason?: string, logReason?: string}} options Failure facts.
   * @returns {boolean} true when this call detached the socket.
   */
  disconnectSocket(socket, options) {
    if (this.socket !== socket) return false
    this.socket = undefined
    this.phase = 'idle'
    this.clearConnectionTimers()
    if (this.stopping) {
      this.setState('offline', options.detail)
      return true
    }
    const replaced = options.replaced === true || this.replaced === true
    this.replaced = replaced
    this.setState('offline', options.detail)
    this.log(options.logReason === undefined ? options.detail : `${options.detail} reason=${options.logReason}`)
    if (options.closeSocket === true) {
      try { socket.close(options.closeCode ?? 1000, options.closeReason ?? 'pclink reconnecting') } catch { /* already closed */ }
    }
    this.scheduleReconnect(replaced)
    return true
  }

  get wsUrl() {
    return `${this.origin.startsWith('https://') ? 'wss' : 'ws'}://${this.origin.slice(this.origin.indexOf('://') + 3)}/`
  }

  scheduleReconnect(replaced = false) {
    if (this.stopping) return
    if (this.reconnectTimer !== undefined) return
    const stable = this.connectedAt !== undefined && this.timers.now() - this.connectedAt >= this.retryStableMs
    if (stable) this.attempt = 0
    this.connectedAt = undefined
    this.replaced = replaced
    const delay = retryDelay(this.attempt, { random: this.random, replaced })
    if (!replaced) this.attempt += 1
    this.log(`relay reconnect in ${String(delay)}ms (attempt ${String(this.attempt)})`)
    this.reconnectTimer = this.timers.setTimeout(() => {
      this.reconnectTimer = undefined
      this.replaced = false
      this.connect()
    }, delay)
    this.reconnectTimer?.unref?.()
  }

  clearConnectionTimers() {
    if (this.heartbeatTimer !== undefined) {
      this.timers.clearTimeout(this.heartbeatTimer)
      this.heartbeatTimer = undefined
    }
    if (this.stableTimer !== undefined) {
      this.timers.clearTimeout(this.stableTimer)
      this.stableTimer = undefined
    }
    if (this.connectTimer !== undefined) {
      this.timers.clearTimeout(this.connectTimer)
      this.connectTimer = undefined
    }
    if (this.errorGraceTimer !== undefined) {
      this.timers.clearTimeout(this.errorGraceTimer)
      this.errorGraceTimer = undefined
    }
  }

  /**
   * Handle one relay text frame (also the unit-test entry point).
   * @param {string} text Relay frame text.
   */
  handleText(text) {
    let parsed
    try {
      parsed = parseRelayFrame(text)
    } catch (error) {
      this.failConnection(error)
      return
    }
    const frame = parsed.frame
    try {
      if (this.phase === 'awaitingChallenge') {
        if (frame.type === 'relay.error') return this.handleRelayError(frame)
        const challenge = validateRelayChallenge(frame)
        requireSameOrigin(challenge.relay, this.origin)
        this.challenge = { origin: challenge.relay, nonce: challenge.nonce }
        const auth = buildRelayAuth(this.identity, { origin: challenge.relay, nonce: challenge.nonce }, 'pc')
        this.sendRaw(auth)
        this.phase = 'awaitingReady'
        return
      }
      if (this.phase === 'awaitingReady') {
        if (frame.type === 'relay.error') return this.handleRelayError(frame)
        const ready = validateRelayReady(frame)
        if (ready.machineId !== this.identity.machineId || ready.role !== 'pc') {
          throw pclinkError('auth_failed', 'relay.ready machineId/role mismatch')
        }
        this.clearConnectionTimers()
        this.phase = 'ready'
        this.connectedAt = this.timers.now()
        this.attempt = 0
        this.setState('connected')
        this.sendAllowlist()
        this.scheduleHeartbeat()
        this.stableTimer = this.timers.setTimeout(() => {
          this.attempt = 0
          this.stableTimer = undefined
        }, this.retryStableMs)
        this.stableTimer?.unref?.()
        return
      }
      if (this.phase !== 'ready') return
      switch (frame.type) {
        case 'relay.ping': {
          const pong = { v: 1, type: 'relay.pong', nonce: frame.nonce }
          this.sendRaw(pong)
          return
        }
        case 'relay.pong': {
          const index = this.outstandingPings.indexOf(frame.nonce)
          if (index >= 0) this.outstandingPings.splice(index, 1)
          return
        }
        case 'relay.error': return this.handleRelayError(frame)
        case 'relay.redirect': this.log(`ignoring reserved relay.redirect url=${String(frame.url)}`); return
        case 'relay.challenge':
        case 'relay.ready':
          throw pclinkError('bad_frame', `unexpected ${frame.type} after ready`)
        default:
          this.onFrame(frame)
      }
    } catch (error) {
      this.failConnection(error)
    }
  }

  handleRelayError(frame) {
    this.lastError = `${String(frame.code)}: ${String(frame.message ?? '')}`
    this.log(`relay.error ${this.lastError}`)
    if (frame.code === 'replaced') this.replaced = true
    if (frame.code === 'auth_failed' || frame.code === 'replaced') {
      // The relay follows with a close; do not treat the error as fatal locally.
      this.onFrame(frame)
    } else {
      this.onFrame(frame)
    }
  }

  failConnection(error) {
    const detail = String(error?.message ?? 'protocol failure')
    this.log(`relay protocol failure: ${detail}`)
    const socket = this.socket
    if (socket === undefined) {
      if (!this.stopping) this.scheduleReconnect()
      return
    }
    this.disconnectSocket(socket, { detail, closeSocket: true, closeCode: 1008, closeReason: 'pclink bad frame' })
  }

  scheduleHeartbeat() {
    if (this.stopping || this.phase !== 'ready') return
    const delay = this.heartbeatBaseMs ?? heartbeatDelay(this.random)
    this.heartbeatTimer = this.timers.setTimeout(() => {
      this.heartbeatTimer = undefined
      if (this.phase !== 'ready' || this.stopping) return
      // §3.4: two consecutive pings without a matching pong close the
      // connection. Check before sending the next ping so the second ping gets
      // its full interval to be answered.
      if (this.outstandingPings.length >= this.maxUnansweredPings) {
        this.log('relay heartbeat timed out')
        const socket = this.socket
        if (socket === undefined) return
        this.disconnectSocket(socket, { detail: 'heartbeat timeout', closeSocket: true, closeCode: 1001, closeReason: 'heartbeat timeout' })
        return
      }
      const nonce = b64urlEncode(randomBytes(16))
      this.outstandingPings.push(nonce)
      this.sendRaw({ v: 1, type: 'relay.ping', nonce })
      this.scheduleHeartbeat()
    }, delay)
    this.heartbeatTimer?.unref?.()
  }

  sendAllowlist() {
    // §3.1: no client frame other than peer.auth is accepted before
    // relay.ready. A pairing change can call this while the supervisor is
    // reconnecting; remember it and let the ready handler send the list.
    if (!this.ready) {
      this.allowlistDeferred = true
      return false
    }
    if (this.allowlistDeferred) this.log('sending the deferred relay.allow after relay.ready')
    this.allowlistDeferred = false
    const peers = this.allowlist()
    return this.sendRaw({ v: 1, type: 'relay.allow', peers })
  }

  /**
   * Send one relay-plane frame if the socket is ready.
   * @param {Record<string, unknown>} frame Frame object.
   * @returns {boolean} true when written.
   */
  send(frame) {
    if (!this.ready) return false
    return this.sendRaw(frame)
  }

  sendRaw(frame) {
    const socket = this.socket
    if (socket === undefined || socket.readyState !== 1) return false
    try {
      socket.send(JSON.stringify(frame))
      return true
    } catch (error) {
      this.log(`relay send failed: ${String(error?.message ?? error)}`)
      return false
    }
  }

  /**
   * Wait until the socket's bufferedAmount is below the §6.2 threshold.
   * @param {number} [threshold] Buffered bytes threshold.
   * @returns {Promise<void>} resolves when drained or the socket closed.
   */
  async waitForDrain(threshold = 64 * 1024) {
    const socket = this.socket
    if (socket === undefined || typeof socket.bufferedAmount !== 'number') return
    while (this.socket === socket && socket.bufferedAmount >= threshold && socket.readyState === 1) {
      await new Promise(resolve => this.timers.setTimeout(resolve, 5))
    }
  }

  /**
   * Decode one challenge nonce for tests.
   * @param {string} nonce b64url nonce.
   * @returns {Buffer} raw nonce.
   */
  static challengeNonce(nonce) {
    return b64urlDecode(nonce, { length: 32 })
  }
}
