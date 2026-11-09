// SPDX-License-Identifier: MIT
// PCLink v1 relay server (§3 relay plane, §4.3 rendezvous).
//
// The relay is deliberately self-contained: Node built-ins plus the pinned
// `ws` package.  It never imports pclink/core and never inspects, decrypts or
// logs `e2e.body` / `relay.pair.message.payload`.  All state is in memory and
// nothing is written to disk.

import { randomBytes, randomInt } from 'node:crypto'
import { createServer } from 'node:http'
import { performance } from 'node:perf_hooks'
import { WebSocket, WebSocketServer } from 'ws'
import { makeRelayConfig } from './config.mjs'
import { parseRelayFrame } from './frames.mjs'
import { parseStrictJsonObject } from './json.mjs'
import { hashPrefix, machineIdFromPublicKey, verifyRelayAuthSignature } from './identity.mjs'
import { hashIpForLog } from './logger.mjs'
import { DailyBytes, TokenBucket, perMinuteBucket, sweepBuckets } from './rate-limit.mjs'
import { ipKey, resolveClientIp } from './net-util.mjs'
import { replaceOriginPort } from './origin.mjs'

const CLOSE = Object.freeze({
  GOING_AWAY: 1001,
  PROTOCOL_ERROR: 1008,
  UNSUPPORTED_DATA: 1003,
  TOO_LARGE: 1009,
  REPLACED: 4001,
  AUTH_FAILED: 4002,
  RATE_LIMITED: 4003,
  SESSION_EXPIRED: 4004,
})

const TEXT_DECODER = new TextDecoder('utf-8', { fatal: true })
// A dropped slow-receiver frame is advisory-retried after one second; the
// sender can also use its own backpressure state.
const SLOW_RECEIVER_RETRY_AFTER_MS = 1000

function closeReasonText(reason) {
  if (typeof reason !== 'string') return undefined
  return Buffer.from(reason, 'utf8').subarray(0, 123).toString('utf8')
}

function safeSend(ws, message) {
  if (ws === undefined || ws.readyState !== WebSocket.OPEN) return false
  try {
    ws.send(JSON.stringify(message))
    return true
  } catch {
    return false
  }
}

function closeWs(ws, code, reason) {
  if (ws === undefined) return
  if (ws.readyState !== WebSocket.OPEN && ws.readyState !== WebSocket.CONNECTING) return
  try {
    ws.close(code, closeReasonText(reason))
  } catch {
    // The socket is already gone; there is nothing else to do.
  }
}

function errorFrame(code, message, extra = {}) {
  const frame = { v: 1, type: 'relay.error', code }
  if (message !== undefined) frame.message = String(message).slice(0, 2048)
  for (const key of ['id', 'streamId', 'sid']) {
    if (typeof extra[key] === 'string') frame[key] = extra[key]
  }
  if (extra.retryAfterMs !== undefined) {
    frame.retryAfterMs = Math.max(0, Math.min(86_400_000, Math.trunc(extra.retryAfterMs)))
  }
  return frame
}

export function createRelayServer(overrides = {}) {
  const config = makeRelayConfig(overrides)
  const logger = config.logger
  const peers = new Map()
  const connections = new Set()
  const slots = new Map()
  const ipCounts = new Map()
  const pairBuckets = new Map()
  const handshakeSourceBuckets = new Map()
  const handshakeTargetBuckets = new Map()
  const joinBuckets = new Map()
  const dailyBytes = new DailyBytes(config.dailyBytesPerMachine, config.dailyBytesMaxMachines)

  let connectionSequence = 0
  let listening = false
  let closed = false
  let sweepTimer = null

  const httpServer = createServer((request, response) => {
    const pathname = String(request.url ?? '').split('?')[0]
    if (request.method === 'GET' && pathname === '/healthz') {
      response.writeHead(200, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
      })
      response.end('{"ok":true}\n')
      return
    }
    response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' })
    response.end('not found\n')
  })

  httpServer.on('error', error => {
    logger.info('server.error', { code: typeof error?.code === 'string' ? error.code : 'http_error' })
  })

  const wss = new WebSocketServer({
    noServer: true,
    clientTracking: false,
    perMessageDeflate: false,
    maxPayload: config.maxFrameBytes + 64 * 1024,
  })

  httpServer.on('upgrade', (request, socket, head) => {
    socket.on('error', () => {})
    const pathname = String(request.url ?? '').split('?')[0]
    if (pathname !== '/') {
      try {
        socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
      } catch {
        // ignore
      }
      socket.destroy()
      return
    }
    wss.handleUpgrade(request, socket, head, ws => wss.emit('connection', ws, request))
  })

  wss.on('connection', (ws, request) => onConnection(ws, request))
  wss.on('error', error => {
    logger.info('server.error', { code: typeof error?.code === 'string' ? error.code : 'ws_error' })
  })

  function sendTo(connect, message) {
    if (connect.closed) return false
    return safeSend(connect.ws, message)
  }

  function sendError(connect, code, message, extra = {}) {
    return sendTo(connect, errorFrame(code, message, extra))
  }

  // Never add a forwarded frame that would push the target socket's outbound
  // queue over the configured cap.  The incoming frame byte length is an upper
  // bound for the forwarded encoding (the only change is overwriting `from`
  // with an equal-length authenticated machineId), so the check is conservative.
  function targetBufferWouldExceed(target, bytes) {
    return target.ws.bufferedAmount + bytes > config.maxBufferedBytesPerConnection
  }

  function closeWithError(connect, code, message, closeCode) {
    if (connect.closed) return
    logger.info('frame.rejected', {
      connectionId: connect.id,
      machineId: connect.machineId === null ? undefined : hashPrefix(connect.machineId),
      code,
    })
    sendError(connect, code, message)
    terminateConnection(connect, closeCode, code)
  }

  function badFrame(connect, message = 'bad frame') {
    closeWithError(connect, 'bad_frame', message, CLOSE.PROTOCOL_ERROR)
  }

  function authFailed(connect, message) {
    closeWithError(connect, 'auth_failed', message, CLOSE.AUTH_FAILED)
  }

  function rateLimited(connect, retryAfterMs, message) {
    sendError(connect, 'rate_limited', message, { retryAfterMs })
    logger.info('frame.dropped', {
      connectionId: connect.id,
      machineId: connect.machineId === null ? undefined : hashPrefix(connect.machineId),
      code: 'rate_limited',
    })
  }

  function touchBusiness(connect) {
    if (connect.role === 'phone') resetIdle(connect)
  }

  function resetIdle(connect) {
    if (connect.role !== 'phone' || connect.closed) return
    if (connect.idleTimer !== null) clearTimeout(connect.idleTimer)
    connect.idleTimer = setTimeout(() => {
      connect.idleTimer = null
      if (connect.closed) return
      logger.info('phone.idle_timeout', {
        connectionId: connect.id,
        machineId: hashPrefix(connect.machineId),
      })
      sendError(connect, 'session_expired', 'phone idle timeout')
      terminateConnection(connect, CLOSE.SESSION_EXPIRED, 'session_expired')
    }, config.phoneIdleMs)
    connect.idleTimer.unref()
  }

  function startHeartbeat(connect) {
    const schedule = () => {
      if (connect.closed) return
      const interval = config.heartbeatMaxMs === config.heartbeatMinMs
        ? config.heartbeatMinMs
        : randomInt(config.heartbeatMinMs, config.heartbeatMaxMs + 1)
      connect.heartbeatTimer = setTimeout(() => {
        connect.heartbeatTimer = null
        if (connect.closed) return
        if (connect.awaitingPong !== null) {
          connect.missedPings += 1
          if (connect.missedPings >= 2) {
            logger.info('heartbeat.timeout', {
              connectionId: connect.id,
              machineId: hashPrefix(connect.machineId),
            })
            sendError(connect, 'unavailable', 'heartbeat timeout')
            terminateConnection(connect, CLOSE.GOING_AWAY, 'unavailable')
            return
          }
        } else {
          connect.missedPings = 0
        }
        const nonce = randomBytes(16).toString('base64url')
        connect.awaitingPong = nonce
        sendTo(connect, { v: 1, type: 'relay.ping', nonce })
        schedule()
      }, interval)
      connect.heartbeatTimer.unref()
    }
    schedule()
  }

  function clearTimers(connect) {
    if (connect.authTimer !== null) clearTimeout(connect.authTimer)
    if (connect.idleTimer !== null) clearTimeout(connect.idleTimer)
    if (connect.heartbeatTimer !== null) clearTimeout(connect.heartbeatTimer)
    connect.authTimer = null
    connect.idleTimer = null
    connect.heartbeatTimer = null
  }

  function releaseConnectionCount(connect) {
    if (!connect.counted) return
    connect.counted = false
    const current = ipCounts.get(connect.sourceKey) ?? 0
    if (current <= 1) ipCounts.delete(connect.sourceKey)
    else ipCounts.set(connect.sourceKey, current - 1)
  }

  function terminateConnection(connect, code, reason) {
    if (connect.closed) return
    connect.closed = true
    clearTimers(connect)
    // The per-IP slot is released only when the socket's `close` event fires:
    // closeWs() starts a closing handshake that can take up to 30 s, and the
    // peer still occupies a source-IP slot until then (contract §3.5).
    connections.delete(connect)
    if (connect.machineId !== null && peers.get(connect.machineId) === connect) {
      peers.delete(connect.machineId)
    }
    for (const slot of [...slots.values()]) {
      if (slot.pc === connect || slot.phone === connect) {
        closeSlot(slot, 'peer_offline', connect)
      }
    }
    logger.info('connection.close', {
      connectionId: connect.id,
      machineId: connect.machineId === null ? undefined : hashPrefix(connect.machineId),
      code,
    })
    closeWs(connect.ws, code, reason)
  }

  function closeSlot(slot, reason, except) {
    if (slots.get(slot.rendezvous) !== slot) return
    slots.delete(slot.rendezvous)
    if (slot.timer !== null) clearTimeout(slot.timer)
    slot.pc.slots.delete(slot.rendezvous)
    if (slot.phone !== null) slot.phone.slots.delete(slot.rendezvous)
    for (const participant of [slot.pc, slot.phone]) {
      if (participant === null || participant === except || participant.closed) continue
      safeSend(participant.ws, {
        v: 1,
        type: 'relay.pair.close',
        rendezvous: slot.rendezvous,
        reason,
      })
    }
    logger.info('pair.close', {
      reason,
      pc: hashPrefix(slot.pc.machineId),
      phone: slot.phone === null ? undefined : hashPrefix(slot.phone.machineId),
    })
  }

  function expireSlot(slot) {
    if (slots.get(slot.rendezvous) !== slot) return
    logger.info('pair.expired', {
      pc: hashPrefix(slot.pc.machineId),
      phone: slot.phone === null ? undefined : hashPrefix(slot.phone.machineId),
    })
    closeSlot(slot, 'rendezvous_expired', null)
  }

  function sendJoined(slot) {
    if (slot.phone === null) return
    safeSend(slot.pc.ws, {
      v: 1,
      type: 'relay.pair.joined',
      rendezvous: slot.rendezvous,
      role: 'pc',
      peerMachineId: slot.phone.machineId,
    })
    safeSend(slot.phone.ws, {
      v: 1,
      type: 'relay.pair.joined',
      rendezvous: slot.rendezvous,
      role: 'phone',
      peerMachineId: slot.pc.machineId,
    })
  }

  function handlePairOpen(connect, frame) {
    if (connect.role !== 'pc') {
      badFrame(connect, 'only a PC connection may open a pairing slot')
      return
    }
    const rendezvous = frame.rendezvous
    let slot = slots.get(rendezvous)
    if (slot !== undefined && slot.expiresAt <= Date.now()) {
      expireSlot(slot)
      slot = undefined
    }
    if (slot !== undefined) {
      if (slot.pc === connect) {
        logger.info('pair.open.idempotent', { machineId: hashPrefix(connect.machineId) })
        return
      }
      sendError(connect, 'rendezvous_exhausted', 'rendezvous is already open')
      return
    }
    if (connect.slots.size >= config.maxPairSlotsPerConnection) {
      sendError(connect, 'rendezvous_exhausted', 'pairing slot limit reached')
      return
    }
    const now = Date.now()
    slot = {
      rendezvous,
      pc: connect,
      phone: null,
      createdAt: now,
      expiresAt: now + config.pairRendezvousTtlMs,
      joinAttempts: 0,
      timer: null,
    }
    slots.set(rendezvous, slot)
    connect.slots.add(rendezvous)
    slot.timer = setTimeout(() => {
      slot.timer = null
      expireSlot(slot)
    }, config.pairRendezvousTtlMs)
    slot.timer.unref()
    logger.info('pair.open', {
      machineId: hashPrefix(connect.machineId),
      slots: connect.slots.size,
    })
  }

  function handlePairJoin(connect, frame) {
    if (connect.role !== 'phone') {
      badFrame(connect, 'only a phone connection may join a pairing slot')
      return
    }
    let bucket = joinBuckets.get(connect.sourceKey)
    if (bucket === undefined) {
      bucket = perMinuteBucket(config.pairJoinsPerIpPerMinute)
      joinBuckets.set(connect.sourceKey, bucket)
    }
    const limited = bucket.take(1)
    if (!limited.ok) {
      rateLimited(connect, limited.retryAfterMs, 'pairing join rate limit')
      return
    }
    const rendezvous = frame.rendezvous
    let slot = slots.get(rendezvous)
    if (slot !== undefined && slot.expiresAt <= Date.now()) {
      expireSlot(slot)
      slot = undefined
    }
    if (slot === undefined) {
      sendError(connect, 'rendezvous_expired', 'rendezvous not found')
      return
    }
    if (slot.phone !== null) {
      if (slot.joinAttempts >= config.pairAttemptsPerRendezvous) {
        sendError(connect, 'rendezvous_exhausted', 'too many pairing join attempts')
        return
      }
      slot.joinAttempts += 1
      if (slot.phone === connect) {
        sendJoined(slot)
        return
      }
      sendError(connect, 'rendezvous_exhausted', 'rendezvous already matched')
      return
    }
    if (slot.joinAttempts >= config.pairAttemptsPerRendezvous) {
      sendError(connect, 'rendezvous_exhausted', 'too many pairing join attempts')
      closeSlot(slot, 'rendezvous_exhausted', connect)
      return
    }
    slot.joinAttempts += 1
    slot.phone = connect
    connect.slots.add(rendezvous)
    sendJoined(slot)
    logger.info('pair.joined', {
      pc: hashPrefix(slot.pc.machineId),
      phone: hashPrefix(connect.machineId),
    })
  }

  function handlePairMessage(connect, frame, bytes) {
    const slot = slots.get(frame.rendezvous)
    if (slot === undefined) {
      sendError(connect, 'rendezvous_expired', 'rendezvous not found')
      return
    }
    if (slot.pc !== connect && slot.phone !== connect) {
      badFrame(connect, 'connection is not a participant of this rendezvous')
      return
    }
    if (slot.phone === null) {
      badFrame(connect, 'pairing peer has not joined yet')
      return
    }
    const target = slot.pc === connect ? slot.phone : slot.pc
    if (target.closed) {
      sendError(connect, 'rendezvous_expired', 'pairing peer is offline')
      return
    }
    // The pair bandwidth/daily quota applies to every forwarded frame between
    // the two machineIds, including opaque pairing payloads.
    if (targetBufferWouldExceed(target, bytes)) {
      rateLimited(connect, SLOW_RECEIVER_RETRY_AFTER_MS, 'receiver is not draining frames')
      return
    }
    if (!consumeForwardLimits(connect, target.machineId, bytes)) return
    if (safeSend(target.ws, {
      v: 1,
      type: 'relay.pair.message',
      rendezvous: frame.rendezvous,
      payload: frame.payload,
    })) {
      touchBusiness(target)
    }
    logger.info('pair.message', {
      from: hashPrefix(connect.machineId),
      to: hashPrefix(target.machineId),
      bytes,
    })
  }

  function handlePairClose(connect, frame) {
    const slot = slots.get(frame.rendezvous)
    if (slot === undefined) {
      sendError(connect, 'rendezvous_expired', 'rendezvous not found')
      return
    }
    if (slot.pc !== connect && slot.phone !== connect) {
      badFrame(connect, 'connection is not a participant of this rendezvous')
      return
    }
    closeSlot(slot, frame.reason, connect)
  }

  function pairBucketFor(left, right) {
    const key = left < right ? `${left}\u0000${right}` : `${right}\u0000${left}`
    let bucket = pairBuckets.get(key)
    if (bucket === undefined) {
      bucket = new TokenBucket({
        ratePerSecond: config.pairRateBytesPerSec,
        burst: config.pairBurstBytes,
        // A single frame may exceed the burst when the bucket is full; the
        // balance then refills from negative (contract §3.5, pclink-v1.4).
        overdraftSingleFrame: true,
      })
      pairBuckets.set(key, bucket)
    }
    return bucket
  }

  function handshakeSourceBucket(machineId) {
    let bucket = handshakeSourceBuckets.get(machineId)
    if (bucket === undefined) {
      bucket = new TokenBucket({
        ratePerSecond: config.handshakeFramesPerSourcePerMinute / 60,
        burst: config.handshakeSourceBurst,
      })
      handshakeSourceBuckets.set(machineId, bucket)
    }
    return bucket
  }

  function handshakeTargetBucket(machineId) {
    let bucket = handshakeTargetBuckets.get(machineId)
    if (bucket === undefined) {
      bucket = new TokenBucket({
        ratePerSecond: config.handshakeFramesPerTargetPerMinute / 60,
        burst: config.handshakeTargetBurst,
      })
      handshakeTargetBuckets.set(machineId, bucket)
    }
    return bucket
  }

  function consumeForwardLimits(connect, to, bytes) {
    const bucket = pairBucketFor(connect.machineId, to)
    const pairCheck = bucket.check(bytes)
    if (!pairCheck.ok) {
      rateLimited(connect, pairCheck.retryAfterMs, 'pair bandwidth limit')
      return false
    }
    const dailyCheck = dailyBytes.check(connect.machineId, bytes, Date.now())
    if (!dailyCheck.ok) {
      rateLimited(connect, dailyCheck.retryAfterMs, 'daily byte limit')
      return false
    }
    bucket.consume(bytes)
    dailyBytes.consume(connect.machineId, bytes, Date.now())
    return true
  }

  function sendOffline(connect, frame) {
    const offline = { v: 1, type: 'relay.offline', to: frame.to }
    for (const key of ['id', 'streamId', 'sid']) {
      if (typeof frame[key] === 'string') offline[key] = frame[key]
    }
    safeSend(connect.ws, offline)
    logger.info('frame.offline', {
      from: hashPrefix(connect.machineId),
      to: hashPrefix(frame.to),
      type: frame.type,
    })
  }

  function routeFrame(connect, frame, bytes, handshake) {
    if (frame.to === connect.machineId) {
      badFrame(connect, 'to must differ from the authenticated sender')
      return
    }
    if (handshake) {
      const sourceCheck = handshakeSourceBucket(connect.machineId).take(1)
      if (!sourceCheck.ok) {
        rateLimited(connect, sourceCheck.retryAfterMs, 'handshake source limit')
        return
      }
      const targetCheck = handshakeTargetBucket(frame.to).take(1)
      if (!targetCheck.ok) {
        rateLimited(connect, targetCheck.retryAfterMs, 'handshake target limit')
        return
      }
    }
    const target = peers.get(frame.to)
    if (target === undefined) {
      sendOffline(connect, frame)
      return
    }
    // relay.allow belongs to the target PC and lists the senders it accepts.
    // It filters e2e application frames only; e2e.handshake bypasses it for
    // the four handshake body types.  A phone has no allowlist.
    if (!handshake && target.role === 'pc' && !target.allow.has(connect.machineId)) {
      logger.info('frame.dropped', {
        from: hashPrefix(connect.machineId),
        to: hashPrefix(frame.to),
        type: frame.type,
        reason: 'sender_not_allowed',
      })
      return
    }
    if (targetBufferWouldExceed(target, bytes)) {
      rateLimited(connect, SLOW_RECEIVER_RETRY_AFTER_MS, 'receiver is not draining frames')
      return
    }
    if (!consumeForwardLimits(connect, frame.to, bytes)) return
    const forwarded = { ...frame, from: connect.machineId }
    if (!safeSend(target.ws, forwarded)) {
      sendOffline(connect, frame)
      return
    }
    // A frame forwarded in either direction is business traffic for the phone
    // and resets its relay idle timer (contract §3.4).
    touchBusiness(target)
    logger.info('frame.forwarded', {
      from: hashPrefix(connect.machineId),
      to: hashPrefix(frame.to),
      type: frame.type,
      bytes,
    })
  }

  function handlePeerAuth(connect, frame) {
    const parsed = parseRelayFrame(frame)
    if (!parsed.ok) {
      if (parsed.code === 'version_unsupported') {
        closeWithError(connect, 'version_unsupported', parsed.message ?? 'unsupported protocol version', CLOSE.PROTOCOL_ERROR)
        return
      }
      authFailed(connect, parsed.message ?? 'invalid peer.auth')
      return
    }
    if (parsed.type !== 'peer.auth') {
      badFrame(connect, 'first client frame must be peer.auth')
      return
    }
    const derived = machineIdFromPublicKey(parsed.publicKey)
    if (derived !== frame.machineId) {
      authFailed(connect, 'machineId does not match publicKey')
      return
    }
    if (!verifyRelayAuthSignature(parsed.publicKey, config.publicOrigin, connect.challengeNonce, parsed.signature)) {
      authFailed(connect, 'relay authentication signature failed')
      return
    }
    const existing = peers.get(frame.machineId)
    if (existing !== undefined && existing !== connect) {
      if (existing.role !== frame.role) {
        authFailed(connect, 'machineId is already connected with a different role')
        return
      }
      peers.delete(frame.machineId)
      sendError(existing, 'replaced', 'replaced by a newer connection')
      logger.info('connection.replaced', {
        oldConnectionId: existing.id,
        connectionId: connect.id,
        machineId: hashPrefix(frame.machineId),
      })
      terminateConnection(existing, CLOSE.REPLACED, 'replaced')
    }
    platformReady(connect, frame)
  }

  function platformReady(connect, frame) {
    connect.authenticated = true
    connect.machineId = frame.machineId
    connect.role = frame.role
    connect.allow = new Set()
    if (connect.authTimer !== null) {
      clearTimeout(connect.authTimer)
      connect.authTimer = null
    }
    peers.set(connect.machineId, connect)
    const ready = {
      v: 1,
      type: 'relay.ready',
      machineId: connect.machineId,
      role: connect.role,
    }
    if (!safeSend(connect.ws, ready)) {
      terminateConnection(connect, CLOSE.GOING_AWAY, 'send_failed')
      return
    }
    logger.info('peer.ready', {
      connectionId: connect.id,
      machineId: hashPrefix(connect.machineId),
      role: connect.role,
    })
    startHeartbeat(connect)
    if (connect.role === 'phone') resetIdle(connect)
  }

  function handleIncoming(connect, data, isBinary) {
    if (connect.closed) return
    if (isBinary) {
      closeWithError(connect, 'bad_frame', 'binary frames are not supported', CLOSE.UNSUPPORTED_DATA)
      return
    }
    const byteLength = typeof data === 'string'
      ? Buffer.byteLength(data, 'utf8')
      : (data?.byteLength ?? data?.length ?? 0)
    // Before relay.ready only peer.auth is legal; cap the frame before UTF-8
    // decoding and JSON parsing so an unauthenticated peer cannot make the
    // relay parse a multi-MiB frame (contract §3.5, pclink-v1.4).
    const frameLimit = connect.authenticated
      ? config.maxFrameBytes
      : config.unauthenticatedMaxFrameBytes
    if (byteLength > frameLimit) {
      closeWithError(connect, 'frame_too_large', 'frame exceeds the configured limit', CLOSE.TOO_LARGE)
      return
    }
    let text
    try {
      if (Buffer.isBuffer(data) && data.length >= 3 && data[0] === 0xef && data[1] === 0xbb && data[2] === 0xbf) {
        throw new Error('BOM')
      }
      text = typeof data === 'string' ? data : TEXT_DECODER.decode(data)
    } catch {
      badFrame(connect, 'invalid UTF-8')
      return
    }
    if (text.charCodeAt(0) === 0xfeff) {
      badFrame(connect, 'BOM is not allowed')
      return
    }
    let frame
    try {
      frame = parseStrictJsonObject(text)
    } catch {
      badFrame(connect, 'malformed JSON frame')
      return
    }
    if (!connect.authenticated) {
      if (frame.type !== 'peer.auth') {
        badFrame(connect, 'first client frame must be peer.auth')
        return
      }
      handlePeerAuth(connect, frame)
      return
    }

    const parsed = parseRelayFrame(frame)
    if (!parsed.ok) {
      closeWithError(connect, parsed.code ?? 'bad_frame', parsed.message ?? 'bad frame', CLOSE.PROTOCOL_ERROR)
      return
    }
    if (parsed.type !== 'relay.ping' && parsed.type !== 'relay.pong') touchBusiness(connect)

    switch (parsed.type) {
      case 'peer.auth':
        badFrame(connect, 'peer.auth is only valid as the first frame')
        return
      case 'relay.allow':
        if (connect.role !== 'pc') {
          badFrame(connect, 'only a PC connection may send relay.allow')
          return
        }
        connect.allow = new Set(parsed.frame.peers)
        logger.info('relay.allow', {
          machineId: hashPrefix(connect.machineId),
          peers: connect.allow.size,
        })
        return
      case 'relay.ping':
        sendTo(connect, { v: 1, type: 'relay.pong', nonce: parsed.frame.nonce })
        return
      case 'relay.pong':
        if (connect.awaitingPong === parsed.frame.nonce) {
          connect.awaitingPong = null
          connect.missedPings = 0
        }
        return
      case 'e2e':
        routeFrame(connect, parsed.frame, byteLength, false)
        return
      case 'e2e.handshake':
        routeFrame(connect, parsed.frame, byteLength, true)
        return
      case 'relay.pair.open':
        handlePairOpen(connect, parsed.frame)
        return
      case 'relay.pair.join':
        handlePairJoin(connect, parsed.frame)
        return
      case 'relay.pair.message':
        handlePairMessage(connect, parsed.frame, byteLength)
        return
      case 'relay.pair.close':
        handlePairClose(connect, parsed.frame)
        return
      case 'relay.challenge':
      case 'relay.ready':
      case 'relay.offline':
      case 'relay.error':
      case 'relay.redirect':
      case 'relay.pair.joined':
        badFrame(connect, `frame type ${parsed.type} is not accepted from a client`)
        return
      default:
        badFrame(connect, 'unknown frame type')
    }
  }

  function onConnection(ws, request) {
    const remote = request?.socket?.remoteAddress ?? ''
    const clientIp = resolveClientIp(remote, request?.headers?.['x-forwarded-for'], config.trustedProxies)
    const sourceKey = ipKey(clientIp)
    const current = ipCounts.get(sourceKey) ?? 0
    const connectionId = ++connectionSequence
    if (current >= config.maxConnectionsPerIp) {
      ws.on('error', () => {})
      logger.info('connection.rate_limited', {
        connectionId,
        ip: hashIpForLog(clientIp),
        limit: config.maxConnectionsPerIp,
      })
      safeSend(ws, errorFrame('rate_limited', 'too many connections from this source', { retryAfterMs: 1000 }))
      closeWs(ws, CLOSE.RATE_LIMITED, 'rate_limited')
      return
    }
    ipCounts.set(sourceKey, current + 1)
    const connect = {
      id: connectionId,
      ws,
      sourceKey,
      clientIpHash: hashIpForLog(clientIp),
      challengeNonce: randomBytes(32),
      authenticated: false,
      machineId: null,
      role: null,
      allow: new Set(),
      slots: new Set(),
      counted: true,
      closed: false,
      authTimer: null,
      idleTimer: null,
      heartbeatTimer: null,
      awaitingPong: null,
      missedPings: 0,
    }
    connections.add(connect)
    ws.on('message', (data, isBinary) => handleIncoming(connect, data, isBinary))
    ws.on('close', code => {
      if (!connect.closed) {
        terminateConnection(connect, typeof code === 'number' ? code : 1000, undefined)
      }
      // Release the source-IP slot only now, when the socket is really closed.
      releaseConnectionCount(connect)
    })
    ws.on('error', error => {
      logger.info('connection.error', {
        connectionId: connect.id,
        code: typeof error?.code === 'string' ? error.code : 'socket_error',
      })
    })
    logger.info('connection.open', { connectionId, ip: connect.clientIpHash })
    safeSend(ws, {
      v: 1,
      type: 'relay.challenge',
      nonce: connect.challengeNonce.toString('base64url'),
      relay: config.publicOrigin,
    })
    connect.authTimer = setTimeout(() => {
      connect.authTimer = null
      if (connect.closed || connect.authenticated) return
      logger.info('auth.timeout', { connectionId: connect.id, ip: connect.clientIpHash })
      authFailed(connect, 'authentication timeout')
    }, config.authTimeoutMs)
    connect.authTimer.unref()
  }

  function sweep() {
    const now = performance.now()
    const idleLimit = 10 * 60 * 1000
    sweepBuckets(pairBuckets, now, idleLimit)
    sweepBuckets(handshakeSourceBuckets, now, idleLimit)
    sweepBuckets(handshakeTargetBuckets, now, idleLimit)
    sweepBuckets(joinBuckets, now, idleLimit)
    dailyBytes.sweep(Date.now())
  }

  async function listen() {
    if (listening) return handleObject
    if (closed) throw new Error('relay is closed')
    await new Promise((resolve, reject) => {
      const onError = error => {
        httpServer.off('listening', onListening)
        reject(error)
      }
      const onListening = () => {
        httpServer.off('error', onError)
        resolve()
      }
      httpServer.once('error', onError)
      httpServer.once('listening', onListening)
      httpServer.listen(config.port, config.host)
    })
    const address = httpServer.address()
    if (address !== null && typeof address === 'object' && config.publicOrigin.endsWith(':0')) {
      config.publicOrigin = replaceOriginPort(config.publicOrigin, address.port)
    }
    listening = true
    sweepTimer = setInterval(sweep, config.sweepIntervalMs)
    sweepTimer.unref()
    logger.info('server.listening', {
      origin: config.publicOrigin,
      host: config.host,
      port: handleObject.port,
    })
    return handleObject
  }

  async function close() {
    if (closed) return
    closed = true
    listening = false
    if (sweepTimer !== null) clearInterval(sweepTimer)
    sweepTimer = null
    for (const connect of [...connections]) {
      terminateConnection(connect, CLOSE.GOING_AWAY, 'server_shutdown')
      try {
        connect.ws.terminate()
      } catch {
        // already gone
      }
    }
    try {
      wss.close()
    } catch {
      // not running
    }
    await new Promise(resolve => {
      try {
        httpServer.close(() => resolve())
      } catch {
        resolve()
      }
    })
  }

  const handleObject = {
    config,
    httpServer,
    wss,
    listen,
    close,
    get port() {
      const address = httpServer.address()
      if (address !== null && typeof address === 'object') return address.port
      return config.port
    },
    get origin() {
      return config.publicOrigin
    },
    get closed() {
      return closed
    },
    get peerCount() {
      return peers.size
    },
    get slotCount() {
      return slots.size
    },
    get connections() {
      return connections
    },
    get slots() {
      return slots
    },
    get peers() {
      return peers
    },
  }

  return handleObject
}
