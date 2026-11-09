/** Loopback admin client with the §8.2 server-proof challenge. */

import { adminProof } from './identity.mjs'
import { b64urlDecode, b64urlEncode, randomBytes } from './encoding.mjs'
import { pclinkError } from './errors.mjs'
import { parseStrictJsonObject } from './json.mjs'
import { loadAdminFile } from './store.mjs'

/**
 * Constant-time byte comparison for challenge proofs.
 * @param {Uint8Array} left Left bytes.
 * @param {Uint8Array} right Right bytes.
 * @returns {boolean} true when equal.
 */
export function proofMatches(left, right) {
  const a = Buffer.from(left)
  const b = Buffer.from(right)
  if (a.length !== b.length) return false
  let difference = 0
  for (let index = 0; index < a.length; index += 1) difference |= a[index] ^ b[index]
  return difference === 0
}

/**
 * The CLI-side loopback admin API client.
 */
export class AdminClient {
  /**
   * @param {{dir: string, fetchImpl?: typeof fetch, timeoutMs?: number}} options State directory and transport.
   */
  constructor(options) {
    this.dir = options.dir
    this.fetchImpl = options.fetchImpl ?? fetch
    this.timeoutMs = options.timeoutMs ?? 5_000
    this.adminFile = undefined
  }

  /** Load admin.json or report that the plugin is not running. */
  load() {
    if (this.adminFile !== undefined) return this.adminFile
    let file
    try {
      file = loadAdminFile(this.dir)
    } catch (error) {
      throw pclinkError('unavailable', `plugin not running: ${error.message}`)
    }
    if (file === undefined) throw pclinkError('unavailable', 'plugin not running: admin.json is absent')
    this.adminFile = file
    return file
  }

  /**
   * Run the HMAC server-proof challenge and return the Bearer token.
   * @returns {Promise<{port: number, token: string}>} verified admin endpoint.
   */
  async prove() {
    const file = this.load()
    const nonce = randomBytes(32)
    let response
    try {
      response = await this.fetchImpl(`http://127.0.0.1:${String(file.port)}/v1/challenge`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ nonce: b64urlEncode(nonce) }),
        signal: AbortSignal.timeout(this.timeoutMs),
      })
    } catch (error) {
      throw pclinkError('unavailable', `plugin not running: ${error.message}`)
    }
    if (response.status !== 200) throw pclinkError('unavailable', 'plugin not running: challenge rejected')
    let body
    try {
      body = parseStrictJsonObject(await response.text())
    } catch {
      throw pclinkError('unavailable', 'plugin not running: malformed challenge response')
    }
    if (body.v !== 1 || body.nonce !== b64urlEncode(nonce)) throw pclinkError('unavailable', 'plugin not running: challenge nonce mismatch')
    let proof
    try {
      proof = b64urlDecode(body.proof, { length: 32 })
    } catch {
      throw pclinkError('unavailable', 'plugin not running: malformed challenge proof')
    }
    const expected = adminProof(b64urlDecode(file.token, { length: 32 }), nonce)
    if (!proofMatches(expected, proof)) throw pclinkError('unavailable', 'plugin not running: server proof mismatch')
    return { port: file.port, token: file.token }
  }

  /**
   * Send one authenticated admin request.
   * @param {'GET'|'POST'} method HTTP method.
   * @param {string} path `/v1/...` path.
   * @param {object} [body] JSON body for POST.
   * @returns {Promise<any>} parsed response.
   */
  async request(method, path, body) {
    const verified = await this.prove()
    const headers = { authorization: `Bearer ${verified.token}`, accept: 'application/json' }
    if (method === 'POST') headers['content-type'] = 'application/json'
    let response
    try {
      response = await this.fetchImpl(`http://127.0.0.1:${String(verified.port)}${path}`, {
        method,
        headers,
        ...(method === 'POST' ? { body: JSON.stringify(body ?? {}) } : {}),
        signal: AbortSignal.timeout(this.timeoutMs),
      })
    } catch (error) {
      throw pclinkError('unavailable', `plugin not running: ${error.message}`)
    }
    const text = await response.text()
    let parsed
    try {
      parsed = text === '' ? {} : parseStrictJsonObject(text)
    } catch {
      throw pclinkError('unavailable', `admin response is not JSON (HTTP ${String(response.status)})`)
    }
    if (response.status !== 200) {
      const failure = parsed?.error
      throw pclinkError(
        typeof failure?.code === 'string' ? failure.code : 'unavailable',
        typeof failure?.message === 'string' ? failure.message : `admin request failed with HTTP ${String(response.status)}`,
      )
    }
    return parsed
  }

  /** @returns {Promise<object>} admin status. */
  status() {
    return this.request('GET', '/v1/status')
  }

  /** @param {{mode?: 'qr'|'manual', relay?: string, name?: string}} [options] Pairing options. */
  pair(options = {}) {
    return this.request('POST', '/v1/pair', options)
  }

  /** @param {string} pairingId Pairing id. @param {string} fingerprint Typed fingerprint. */
  approve(pairingId, fingerprint) {
    return this.request('POST', '/v1/pair/approve', { pairingId, fingerprint })
  }

  /** @param {string} pairingId Pairing id. @param {boolean} [rejected] Explicit operator refusal. */
  cancel(pairingId, rejected = false) {
    return this.request('POST', '/v1/pair/cancel', { pairingId, ...(rejected ? { rejected: true } : {}) })
  }

  /** @param {{peerMachineId?: string, all?: true}} target Revocation target. */
  unpair(target) {
    return this.request('POST', '/v1/unpair', target)
  }

  /** @param {string} confirm Literal confirmation phrase. */
  rotateIdentity(confirm) {
    return this.request('POST', '/v1/rotate-identity', { confirm })
  }
}
