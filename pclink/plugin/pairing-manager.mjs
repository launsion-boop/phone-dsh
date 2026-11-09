/**
 * One-at-a-time PC pairing slot (§4.3/§4.4): QR or manual, relay rendezvous,
 * compare-the-phone approval, transcript-verified final and durable write.
 */
import {
  b64urlDecode,
  b64urlEncode,
  fingerprintOf,
  fingerprintMatches,
  formatRfc3339,
  normalizeFingerprintInput,
  randomBytes,
  validateName,
} from '../core/encoding.mjs'
import { pclinkError, PAIRING_FAILURE_CODES } from '../core/errors.mjs'
import {
  buildPairConfirm,
  buildPairHello,
  buildPairingRecord,
  buildQrUri,
  generatePairingSecret,
  pairKeyFor,
  pairTranscriptHash,
  rendezvousFor,
  verifyPairAuth,
  verifyPairFinal,
} from '../core/pairing.mjs'

/** Pairing slot lifetime: 300 s absolute (§3.5/§4.3). */
export const PAIR_SLOT_TTL_MS = 300_000
/** Approval prompt budget: 120 s (§4.4). */
export const APPROVAL_TTL_MS = 120_000

function defaultTimers() {
  return {
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: handle => clearTimeout(handle),
    now: () => Date.now(),
  }
}

/** The PC pairing state machine. */
export class PairingManager {
  /**
   * @param {{
   *   store: import('./state.mjs').PclinkStore,
   *   send: (frame: Record<string, unknown>) => boolean,
   *   relayOrigin: string,
   *   pcName: string,
   *   now?: () => string,
   *   timers?: {setTimeout: Function, clearTimeout: Function, now: () => number},
   *   onCompleted?: (record: Record<string, unknown>) => void,
   *   onFailure?: (code: string, message: string) => void,
   *   log?: (...args: unknown[]) => void,
   * }} options Dependencies.
   */
  constructor(options) {
    this.store = options.store
    this.send = options.send
    this.relayOrigin = options.relayOrigin
    this.pcName = validateName(options.pcName, 'PC name')
    this.now = options.now ?? (() => formatRfc3339())
    this.timers = options.timers ?? defaultTimers()
    this.onCompleted = options.onCompleted ?? (() => {})
    this.onFailure = options.onFailure ?? (() => {})
    this.log = options.log ?? (() => {})
    this.pairing = undefined
    this.slotTimer = undefined
    this.approvalTimer = undefined
  }

  /** @returns {boolean} whether a pairing is in progress (not terminal). */
  get active() {
    return this.pairing !== undefined && !['failed', 'completed'].includes(this.pairing.state)
  }

  /** Clear internal timers. */
  clearTimers() {
    if (this.slotTimer !== undefined) this.timers.clearTimeout(this.slotTimer)
    if (this.approvalTimer !== undefined) this.timers.clearTimeout(this.approvalTimer)
    this.slotTimer = undefined
    this.approvalTimer = undefined
  }

  /** Stop any pairing and timers (plugin shutdown / relay loss). */
  dispose() {
    this.clearTimers()
    if (this.active) this.fail('unavailable', 'pairing stopped')
    this.pairing = undefined
  }

  /**
   * Start exactly one slot.
   * @param {{mode?: 'qr'|'manual', relay?: string, name?: string}} [request] Pair request.
   * @returns {Record<string, unknown>} `/v1/pair` success body.
   */
  start(request = {}) {
    if (this.active) throw pclinkError('unavailable', 'pairing already in progress')
    const mode = request.mode ?? 'qr'
    if (mode !== 'qr' && mode !== 'manual') throw pclinkError('bad_frame', 'pairing mode must be qr or manual')
    if (request.relay !== undefined && request.relay !== this.relayOrigin) {
      throw pclinkError('unavailable', 'requested relay does not match the configured relay')
    }
    const material = generatePairingSecret(mode)
    const id = `pair-${b64urlEncode(randomBytes(12)).slice(0, 16)}`
    const createdAtMs = this.timers.now()
    const expiresAt = formatRfc3339(new Date(createdAtMs + PAIR_SLOT_TTL_MS))
    const rendezvous = rendezvousFor(material.secret, this.relayOrigin)
    const pairing = {
      id,
      mode,
      state: 'waiting',
      createdAt: createdAtMs,
      expiresAt,
      relayOrigin: this.relayOrigin,
      secret: material.secret,
      pairKey: pairKeyFor(material.secret),
      rendezvous,
      qrURI: mode === 'qr'
        ? buildQrUri({
          origin: this.relayOrigin,
          machineId: this.store.identity.machineId,
          publicKey: this.store.identity.publicKey,
          secret: material.secret,
          name: this.pcName,
        })
        : undefined,
      manualCode: material.display,
      hello: undefined,
      helloNonce: undefined,
      auth: undefined,
      peerName: undefined,
      peerMachineId: undefined,
      peerPublicKey: undefined,
      approved: false,
      approvedAt: undefined,
      approvedVia: undefined,
      error: undefined,
      bannerParent: undefined,
    }
    this.pairing = pairing
    const opened = this.send({ v: 1, type: 'relay.pair.open', rendezvous })
    if (!opened) {
      this.fail('unavailable', 'relay is not connected')
      throw pclinkError('unavailable', 'relay is offline')
    }
    this.slotTimer = this.timers.setTimeout(() => {
      this.slotTimer = undefined
      if (this.pairing !== pairing || pairing.state === 'completed') return
      this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'timeout' })
      this.fail('rendezvous_expired', 'pairing slot expired')
    }, PAIR_SLOT_TTL_MS)
    this.slotTimer?.unref?.()
    this.log(`pairing opened mode=${mode} rendezvous=${rendezvous}`)
    return {
      v: 1,
      pairing: {
        id,
        mode,
        relayOrigin: this.relayOrigin,
        ...(mode === 'qr' ? { qrURI: pairing.qrURI } : { manualCode: pairing.manualCode }),
        expiresAt,
      },
    }
  }

  /**
   * Handle one relay pairing frame.
   * @param {Record<string, unknown>} frame Validated relay frame.
   */
  handleFrame(frame) {
    const pairing = this.pairing
    if (pairing === undefined || pairing.state === 'completed' || pairing.state === 'failed') {
      if (frame.type === 'relay.pair.close' && pairing !== undefined) this.clearTimers()
      return
    }
    if (frame.rendezvous !== pairing.rendezvous) return
    if (frame.type === 'relay.pair.joined') {
      if (pairing.hello !== undefined) return
      const helloNonce = randomBytes(32)
      const hello = buildPairHello({
        identity: this.store.identity,
        name: this.pcName,
        relay: this.relayOrigin,
        nonce: helloNonce,
        pairKey: pairing.pairKey,
      })
      pairing.hello = hello
      pairing.helloNonce = helloNonce
      this.send({ v: 1, type: 'relay.pair.message', rendezvous: pairing.rendezvous, payload: hello })
      return
    }
    if (frame.type === 'relay.pair.message') {
      this.handlePayload(frame.payload)
      return
    }
    if (frame.type === 'relay.pair.close') {
      this.handlePeerClose(frame.reason)
    }
  }

  handlePayload(payload) {
    const pairing = this.pairing
    if (pairing === undefined || pairing.hello === undefined) return
    if (payload?.type === 'pair.auth') {
      if (pairing.auth !== undefined) {
        this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'auth_failed' })
        this.fail('auth_failed', 'duplicate pair.auth')
        return
      }
      let verified
      try {
        verified = verifyPairAuth(payload, {
          pairKey: pairing.pairKey,
          relay: this.relayOrigin,
          peerNonce: pairing.helloNonce,
        })
      } catch (error) {
        this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'auth_failed' })
        this.fail('auth_failed', `pair.auth verification failed: ${error.message}`)
        return
      }
      pairing.auth = verified.auth
      pairing.peerName = verified.auth.name
      pairing.peerMachineId = verified.machineId
      pairing.peerPublicKey = verified.auth.publicKey
      pairing.state = 'awaiting_approval'
      this.log(`pairing awaiting approval name=${verified.auth.name}`)
      this.approvalTimer = this.timers.setTimeout(() => {
        this.approvalTimer = undefined
        if (this.pairing !== pairing || pairing.state !== 'awaiting_approval' || pairing.approved) return
        this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'timeout' })
        this.fail('session_expired', 'approval timed out')
      }, APPROVAL_TTL_MS)
      this.approvalTimer?.unref?.()
      return
    }
    if (payload?.type === 'pair.final') {
      this.handleFinal(payload)
    }
  }

  handleFinal(payload) {
    const pairing = this.pairing
    if (pairing === undefined || pairing.auth === undefined) return
    if (!pairing.approved) {
      this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'auth_failed' })
      this.fail('auth_failed', 'pair.final before local approval')
      return
    }
    let verified
    try {
      const { transcriptHash } = pairTranscriptHash(pairing.hello, pairing.auth)
      verified = verifyPairFinal(payload, {
        pairKey: pairing.pairKey,
        expectedNonce: b64urlDecode(pairing.auth.nonce, { length: 32 }),
        expectedPeerNonce: pairing.helloNonce,
        transcriptHash,
      })
    } catch (error) {
      this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'auth_failed' })
      this.fail('auth_failed', `pair.final verification failed: ${error.message}`)
      return
    }
    const record = buildPairingRecord({
      peerMachineId: pairing.peerMachineId,
      peerPublicKey: pairing.peerPublicKey,
      peerName: pairing.peerName,
      pairedAt: this.now(),
      relayOrigin: this.relayOrigin,
      approvedAt: pairing.approvedAt,
      approvedVia: pairing.approvedVia,
    })
    try {
      this.store.addPair(record)
    } catch (error) {
      this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'storage' })
      this.fail('unavailable', `pairing storage failed: ${error.message}`)
      return
    }
    this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'paired' })
    this.clearTimers()
    pairing.state = 'completed'
    pairing.peerFingerprint = fingerprintOf(pairing.peerMachineId)
    pairing.completedAt = this.now()
    this.log(`pairing completed peer=${pairing.peerMachineId}`)
    try {
      this.onCompleted(record)
    } catch (error) {
      this.log(`pairing completion callback failed: ${error.message}`)
    }
    void verified
  }

  /**
   * Operator approval by comparing the phone's own 60-bit fingerprint.
   * @param {string} pairingId Pairing id.
   * @param {string} fingerprint Fingerprint typed from the phone screen.
   * @param {'cli'|'webui'} [via] Approval carrier.
   * @returns {Record<string, unknown>} `/v1/pair/approve` body.
   */
  approve(pairingId, fingerprint, via = 'cli') {
    const pairing = this.pairing
    if (pairing === undefined || pairing.id !== pairingId) throw pclinkError('unavailable', 'no such pairing')
    if (pairing.state !== 'awaiting_approval') throw pclinkError('unavailable', 'pairing is not awaiting approval')
    if (pairing.approved) throw pclinkError('unavailable', 'pairing is already approved')
    if (via !== 'cli' && via !== 'webui') throw pclinkError('bad_frame', 'invalid approval carrier')
    let normalized
    try {
      normalized = normalizeFingerprintInput(fingerprint)
    } catch {
      normalized = undefined
    }
    if (normalized === undefined || !fingerprintMatches(pairing.peerMachineId, normalized)) {
      this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: 'auth_failed' })
      this.fail('auth_failed', 'fingerprint does not match the phone that joined; pairing voided')
      return {
        v: 1,
        approved: false,
        error: { code: 'auth_failed', message: 'fingerprint does not match the phone that joined; pairing was voided' },
      }
    }
    pairing.approved = true
    pairing.approvedAt = this.now()
    pairing.approvedVia = via
    const { transcriptHash } = pairTranscriptHash(pairing.hello, pairing.auth)
    const confirm = buildPairConfirm({
      pairKey: pairing.pairKey,
      nonce: pairing.helloNonce,
      peerNonce: b64urlDecode(pairing.auth.nonce, { length: 32 }),
      transcriptHash,
    })
    this.send({ v: 1, type: 'relay.pair.message', rendezvous: pairing.rendezvous, payload: confirm })
    this.log(`pairing approved via=${via}`)
    return { v: 1, approved: true }
  }

  /**
   * Operator cancel/refusal.
   * @param {string} pairingId Pairing id.
   * @param {boolean} [rejected] Explicit refusal.
   * @returns {Record<string, unknown>} `/v1/pair/cancel` body.
   */
  cancel(pairingId, rejected = false) {
    const pairing = this.pairing
    if (pairing === undefined || pairing.id !== pairingId) throw pclinkError('unavailable', 'no such pairing')
    if (pairing.state === 'completed') return { v: 1, cancelled: true }
    if (this.active) {
      this.send({ v: 1, type: 'relay.pair.close', rendezvous: pairing.rendezvous, reason: rejected ? 'rejected' : 'cancelled' })
    }
    this.clearTimers()
    if (this.active) pairing.state = 'failed'
    this.pairing = undefined
    return { v: 1, cancelled: true }
  }

  /**
   * Relay/phone close for the active slot.
   * @param {string} reason Pair close reason.
   */
  handlePeerClose(reason) {
    const pairing = this.pairing
    if (pairing === undefined || pairing.state === 'completed' || pairing.state === 'failed') return
    this.clearTimers()
    if (reason === 'paired') {
      if (pairing.state === 'completed') return
      this.fail('auth_failed', 'peer closed as paired before the PC wrote a record')
      return
    }
    const mapped = {
      auth_failed: 'auth_failed',
      storage: 'unavailable',
      timeout: 'session_expired',
      rendezvous_expired: 'rendezvous_expired',
      rendezvous_exhausted: 'rendezvous_exhausted',
      peer_offline: 'unavailable',
      cancelled: 'unavailable',
      rejected: 'auth_failed',
    }[reason] ?? 'unavailable'
    this.fail(mapped, `pairing closed by peer: ${reason}`)
  }

  /**
   * Relay-level pairing error (expired/exhausted) ends the local slot.
   * @param {string} code Relay error code.
   */
  handleRelayError(code) {
    if (!this.active) return
    this.clearTimers()
    this.fail(code === 'rendezvous_exhausted' ? 'rendezvous_exhausted' : 'rendezvous_expired', `relay reported ${code}`)
  }

  /** Called when the relay connection drops; the slot is not durable. */
  handleRelayDown() {
    if (!this.active) return
    this.clearTimers()
    this.fail('unavailable', 'relay connection lost during pairing')
  }

  fail(code, message) {
    const pairing = this.pairing
    if (pairing === undefined) return
    this.clearTimers()
    pairing.state = 'failed'
    pairing.error = PAIRING_FAILURE_CODES.includes(code) ? code : 'unavailable'
    pairing.failureMessage = message
    this.log(`pairing failed code=${pairing.error}: ${message}`)
    try {
      this.onFailure(pairing.error, message)
    } catch {
      // Failure reporting must never mask the original failure.
    }
  }

  /**
   * Public status pairing object, with the §8.2 pending-peer redaction.
   * @returns {Record<string, unknown> | undefined} pairing status.
   */
  status() {
    const pairing = this.pairing
    if (pairing === undefined) return undefined
    if (pairing.state === 'failed') {
      return {
        id: pairing.id,
        state: 'failed',
        mode: pairing.mode,
        expiresAt: pairing.expiresAt,
        error: pairing.error ?? 'unavailable',
      }
    }
    if (pairing.state === 'completed') {
      return {
        id: pairing.id,
        state: 'completed',
        mode: pairing.mode,
        expiresAt: pairing.expiresAt,
        peerName: pairing.peerName,
        peerMachineId: pairing.peerMachineId,
        peerFingerprint: pairing.peerFingerprint,
      }
    }
    if (pairing.state === 'awaiting_approval') {
      return {
        id: pairing.id,
        state: 'awaiting_approval',
        mode: pairing.mode,
        expiresAt: pairing.expiresAt,
        peerName: pairing.peerName,
      }
    }
    return {
      id: pairing.id,
      state: 'waiting',
      mode: pairing.mode,
      expiresAt: pairing.expiresAt,
      ...(pairing.mode === 'qr' ? { qrURI: pairing.qrURI } : { manualCode: pairing.manualCode }),
    }
  }
}
