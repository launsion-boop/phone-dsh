/** PCLink v1 error vocabulary (§9.1) and one structured error type. */

/** PCLink error codes that may appear in `relay.error`, `session.close` or `session.reject`. */
export const PCLINK_WIRE_CODES = Object.freeze([
  'unavailable',
  'peer_offline',
  'unpaired',
  'auth_failed',
  'replaced',
  'session_expired',
  'replay',
  'bad_frame',
  'frame_too_large',
  'rate_limited',
  'version_unsupported',
  'rendezvous_expired',
  'rendezvous_exhausted',
  'rekey',
  'forbidden',
])

/** Codes the relay may put in `relay.error` (§3.4/§3.5/§9.1). */
export const RELAY_ERROR_CODES = Object.freeze([
  'unavailable',
  'unpaired',
  'auth_failed',
  'replaced',
  'session_expired',
  'replay',
  'bad_frame',
  'frame_too_large',
  'rate_limited',
  'version_unsupported',
  'rendezvous_expired',
  'rendezvous_exhausted',
])

/** Codes `session.close` may carry (inner-message schema). */
export const SESSION_CLOSE_CODES = Object.freeze([
  'unavailable',
  'unpaired',
  'auth_failed',
  'replaced',
  'session_expired',
  'replay',
  'bad_frame',
  'frame_too_large',
  'rate_limited',
  'version_unsupported',
  'rekey',
])

/** Codes `session.reject` may carry (e2e-handshake schema). */
export const SESSION_REJECT_CODES = Object.freeze([
  'unavailable',
  'unpaired',
  'auth_failed',
  'session_expired',
  'replay',
  'bad_frame',
  'frame_too_large',
  'rate_limited',
  'version_unsupported',
])

/** Closed reason set for `relay.pair.close` (§4.3). */
export const PAIR_CLOSE_REASONS = Object.freeze([
  'paired',
  'cancelled',
  'rejected',
  'peer_offline',
  'rendezvous_expired',
  'rendezvous_exhausted',
  'auth_failed',
  'storage',
  'timeout',
])

/** Error codes the admin `pairing.error` field may carry (admin-status schema). */
export const PAIRING_FAILURE_CODES = Object.freeze([
  'unavailable',
  'unpaired',
  'auth_failed',
  'session_expired',
  'bad_frame',
  'frame_too_large',
  'rate_limited',
  'version_unsupported',
  'rendezvous_expired',
  'rendezvous_exhausted',
])

/** One PCLink failure carrying a vocabulary code and a human message. */
export class PclinkError extends Error {
  /**
   * @param {string} code PCLink code from §9.1.
   * @param {string} message Human-readable message.
   * @param {object} [details] Optional structured details.
   */
  constructor(code, message, details) {
    super(message)
    this.name = 'PclinkError'
    this.code = code
    if (details !== undefined) this.details = details
  }

  /** Wire-shaped error object, message capped at 2048 UTF-8 bytes by the caller when needed. */
  toJSON() {
    return { code: this.code, message: this.message, ...(this.details === undefined ? {} : { details: this.details }) }
  }
}

/**
 * Build a structured PCLink failure.
 * @param {string} code PCLink code.
 * @param {string} message Human message.
 * @param {object} [details] Optional details.
 * @returns {PclinkError} structured failure.
 */
export function pclinkError(code, message, details) {
  return new PclinkError(code, message, details)
}

/**
 * Whether a value is one of the PCLink wire codes.
 * @param {unknown} code Candidate code.
 * @returns {boolean} true for a registered code.
 */
export function isPclinkCode(code) {
  return typeof code === 'string' && PCLINK_WIRE_CODES.includes(code)
}

/**
 * Whether a value is an allowed `session.close` code.
 * @param {unknown} code Candidate code.
 * @returns {boolean} true for a registered close code.
 */
export function isSessionCloseCode(code) {
  return typeof code === 'string' && SESSION_CLOSE_CODES.includes(code)
}

/**
 * Whether a value is an allowed `session.reject` code.
 * @param {unknown} code Candidate code.
 * @returns {boolean} true for a registered reject code.
 */
export function isSessionRejectCode(code) {
  return typeof code === 'string' && SESSION_REJECT_CODES.includes(code)
}

/**
 * Whether a value is an allowed pairing close reason.
 * @param {unknown} reason Candidate reason.
 * @returns {boolean} true for a registered reason.
 */
export function isPairCloseReason(reason) {
  return typeof reason === 'string' && PAIR_CLOSE_REASONS.includes(reason)
}
