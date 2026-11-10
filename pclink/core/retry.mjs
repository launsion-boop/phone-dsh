/** Reconnect backoff (§10) and endpoint retry classification (§7). */

/** The reconnect delays in order; the last value repeats. */
export const RETRY_DELAYS_MS = Object.freeze([500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000])
/** A connection that stays up this long resets the schedule. */
export const RETRY_STABLE_MS = 60_000
/** A replaced connection waits at least this long (§3.2). */
export const REPLACED_MIN_DELAY_MS = 30_000

/**
 * Compute one reconnect delay with ±20 % jitter.
 * @param {number} attempt Zero-based attempt number after the last healthy start.
 * @param {{random?: () => number, replaced?: boolean}} [options] Jitter source and replacement rule.
 * @returns {number} delay milliseconds.
 */
export function retryDelay(attempt, options = {}) {
  const random = options.random ?? Math.random
  if (options.replaced === true) return Math.round(30_000 + random() * 6_000)
  const base = RETRY_DELAYS_MS[Math.min(Math.max(attempt, 0), RETRY_DELAYS_MS.length - 1)]
  return Math.round(base * (0.8 + random() * 0.4))
}

/**
 * Classify one endpoint for retry purposes using the normative inventory.
 * @param {string} endpoint `<ns>/<method>`.
 * @param {object} inventory Parsed `endpoints.json`.
 * @returns {'read'|'idempotent'|'unsafe'} retry class.
 */
export function retryClassOf(endpoint, inventory) {
  const entry = inventory?.endpoints?.find(candidate => candidate.name === endpoint)
  return entry?.retry ?? inventory?.defaultRetry ?? 'unsafe'
}

/**
 * Whether an endpoint exists only on the phone.
 * @param {string} endpoint `<ns>/<method>`.
 * @param {object} inventory Parsed `endpoints.json`.
 * @returns {boolean} true for phone-only inventory entries.
 */
export function isPhoneOnlyEndpoint(endpoint, inventory) {
  const entry = inventory?.endpoints?.find(candidate => candidate.name === endpoint)
  return entry?.phoneOnly === true
}
