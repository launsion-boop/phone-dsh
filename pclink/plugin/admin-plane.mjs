/** Shared admin operation surface for the loopback CLI carrier and the DSH owner routes (§8.2). */

import { pclinkError } from '../core/errors.mjs'
import { parseStrictJsonObject } from '../core/json.mjs'
import { isPclinkRemoteRequest } from './remote-context.mjs'

/** Largest request body the local admin API accepts. */
export const MAX_ADMIN_REQUEST_BYTES = 64 * 1024
/** Largest response body the local admin API emits. */
export const MAX_ADMIN_RESPONSE_BYTES = 256 * 1024

const OPERATIONS = new Map([
  ['status', 'status'],
  ['pair', 'pair'],
  ['pair/approve', 'pair/approve'],
  ['pair/cancel', 'pair/cancel'],
  ['unpair', 'unpair'],
  ['rotate-identity', 'rotate-identity'],
])

function jsonResponse(body, status = 200) {
  const text = JSON.stringify(body)
  return new Response(text, {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  })
}

/** Admin status builder and operation dispatcher. */
export class AdminPlane {
  /**
   * @param {{
   *   store: import('./state.mjs').PclinkStore,
   *   pairing: import('./pairing-manager.mjs').PairingManager,
   *   sessions: import('./session-manager.mjs').SessionManager,
   *   relay: {origin: string, state: string},
   *   unpair: (body: object) => Record<string, unknown>,
   *   rotateIdentity: (body: object) => Record<string, unknown>,
   *   extraWarnings?: () => string[],
   * }} options Dependencies.
   */
  constructor(options) {
    this.store = options.store
    this.pairing = options.pairing
    this.sessions = options.sessions
    this.relay = options.relay
    this.unpairOperation = options.unpair
    this.rotateOperation = options.rotateIdentity
    this.extraWarnings = options.extraWarnings ?? (() => [])
  }

  /** Build the §8.2 status body. */
  status() {
    const online = this.sessions.onlinePeers()
    const warnings = [
      ...this.store.statusWarnings(),
      ...this.sessions.versionWarnings,
      ...this.extraWarnings(),
    ].slice(0, 64)
    const pairing = this.pairing.status()
    return {
      v: 1,
      identity: {
        machineId: this.store.identity.machineId,
        publicKey: Buffer.from(this.store.identity.publicKey).toString('base64url'),
        name: this.pairing.pcName,
      },
      relay: { origin: this.relay.origin, state: this.relay.state },
      pairs: this.store.statusPairs(online),
      warnings: warnings.map(warning => (Buffer.byteLength(warning, 'utf8') > 2048 ? `${warning.slice(0, 2000)}…` : warning)),
      ...(pairing === undefined ? {} : { pairing }),
    }
  }

  /**
   * Dispatch one operation.
   * @param {string} operation One of the six §8.2 operations.
   * @param {object} [body] Parsed request body.
   * @param {{via?: 'cli'|'webui'}} [options] Carrier.
   * @returns {Record<string, unknown>} response body.
   */
  handle(operation, body = {}, options = {}) {
    const via = options.via ?? 'webui'
    switch (operation) {
      case 'status':
        return this.status()
      case 'pair':
        if (body === null || typeof body !== 'object' || Array.isArray(body)) throw pclinkError('bad_frame', 'pair body must be an object')
        return this.pairing.start({
          ...(body.mode === undefined ? {} : { mode: body.mode }),
          ...(body.relay === undefined ? {} : { relay: body.relay }),
          ...(body.name === undefined ? {} : { name: body.name }),
        })
      case 'pair/approve': {
        if (typeof body.pairingId !== 'string' || typeof body.fingerprint !== 'string') {
          throw pclinkError('bad_frame', 'pair/approve requires pairingId and fingerprint')
        }
        return this.pairing.approve(body.pairingId, body.fingerprint, via)
      }
      case 'pair/cancel':
        if (typeof body.pairingId !== 'string') throw pclinkError('bad_frame', 'pair/cancel requires pairingId')
        return this.pairing.cancel(body.pairingId, body.rejected === true)
      case 'unpair':
        return this.unpairOperation(body)
      case 'rotate-identity':
        return this.rotateOperation(body)
      default:
        throw pclinkError('bad_frame', `unknown PCLink admin operation ${operation}`)
    }
  }

  /**
   * Handle one owner `/api/pclink.admin/*` HTTP request.
   *
   * This is the authoritative §6.1/§8.2 source-Peer gate: the request is
   * refused when the current in-process dispatch came from a PCLink remote
   * Peer, regardless of the endpoint/path spelling.
   * @param {Request} request Fetch request.
   * @param {{operation: string, via?: 'cli'|'webui'}} route Route facts.
   * @returns {Promise<Response>} response.
   */
  async handleFetch(request, route) {
    if (isPclinkRemoteRequest()) {
      return jsonResponse({ v: 1, error: { code: 'forbidden', message: 'remote pclink.admin calls are forbidden' } }, 403)
    }
    let body
    try {
      const text = await request.text()
      if (Buffer.byteLength(text, 'utf8') > MAX_ADMIN_REQUEST_BYTES) {
        throw pclinkError('frame_too_large', 'admin request body exceeds 64 KiB')
      }
      body = text === '' ? {} : parseStrictJsonObject(text)
    } catch (error) {
      return jsonResponse({ v: 1, error: { code: 'bad_frame', message: `invalid admin request: ${error.message}` } }, 400)
    }
    if (body === null || typeof body !== 'object' || Array.isArray(body)) {
      return jsonResponse({ v: 1, error: { code: 'bad_frame', message: 'admin request body must be an object' } }, 400)
    }
    try {
      const response = this.handle(route.operation, body, { via: route.via ?? 'webui' })
      const text = JSON.stringify(response)
      if (Buffer.byteLength(text, 'utf8') > MAX_ADMIN_RESPONSE_BYTES) {
        return jsonResponse({ v: 1, error: { code: 'frame_too_large', message: 'admin response exceeds 256 KiB' } }, 500)
      }
      return new Response(text, {
        status: 200,
        headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
      })
    } catch (error) {
      const code = typeof error.code === 'string' ? error.code : 'unavailable'
      const status = code === 'bad_frame' ? 400 : code === 'frame_too_large' ? 413 : 409
      return jsonResponse({ v: 1, error: { code, message: error.message } }, status)
    }
  }
}

/**
 * Operation name for one admin path below `/api/`.
 * @param {string} pathname Request pathname.
 * @returns {'status'|'pair'|'pair/approve'|'pair/cancel'|'unpair'|'rotate-identity'|undefined} operation.
 */
export function adminOperationForPath(pathname) {
  const prefix = '/api/pclink.admin/'
  if (!pathname.startsWith(prefix)) return undefined
  return OPERATIONS.get(pathname.slice(prefix.length))
}

/**
 * The six DSH owner route paths (§8.2).
 * @returns {string[]} route paths.
 */
export function adminRoutePaths() {
  return [...OPERATIONS.values()].map(operation => `/api/pclink.admin/${operation}`)
}
