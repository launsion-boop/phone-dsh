/** Loopback admin HTTP carrier with the §8.1 fence and §8.2 server proof. */

import { createServer } from 'node:http'
import { timingSafeEqual } from 'node:crypto'
import { b64urlDecode, b64urlEncode, randomBytes } from '../core/encoding.mjs'
import { adminProof } from '../core/identity.mjs'
import { pclinkError } from '../core/errors.mjs'
import { parseStrictJsonObject } from '../core/json.mjs'
import { saveAdminFile } from '../core/store.mjs'
import { MAX_ADMIN_REQUEST_BYTES, MAX_ADMIN_RESPONSE_BYTES } from './admin-plane.mjs'

function tokenMatches(header, tokenText) {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return false
  const presented = Buffer.from(header.slice('Bearer '.length), 'utf8')
  const expected = Buffer.from(tokenText, 'utf8')
  return presented.length === expected.length && timingSafeEqual(presented, expected)
}

function sendJson(response, status, body) {
  const text = JSON.stringify(body)
  response.writeHead(status, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text, 'utf8'),
  })
  response.end(text)
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let bytes = 0
    request.on('data', chunk => {
      bytes += chunk.length
      if (bytes > MAX_ADMIN_REQUEST_BYTES) {
        reject(pclinkError('frame_too_large', 'admin request body exceeds 64 KiB'))
        request.destroy()
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    request.on('error', reject)
  })
}

/**
 * Start the loopback admin server bound to 127.0.0.1 only.
 *
 * The token is generated here, written to admin.json atomically after the
 * listener is up, and never logged. The `/v1/challenge` route is the only one
 * accepted without a Bearer header.
 */
export class AdminServer {
  /**
   * @param {{
   *   dir: string,
   *   plane: import('./admin-plane.mjs').AdminPlane,
   *   log?: (...args: unknown[]) => void,
   *   random?: () => number,
   *   port?: number,
   * }} options State dir and transport dependencies.
   */
  constructor(options) {
    this.dir = options.dir
    this.plane = options.plane
    this.log = options.log ?? (() => {})
    this.random = options.random ?? Math.random
    this.requestedPort = options.port
    this.token = randomBytes(32)
    this.tokenText = b64urlEncode(this.token)
    this.server = undefined
    this.port = undefined
  }

  /** Pick a port in the §8.1 range. */
  pickPort() {
    if (this.requestedPort !== undefined) return this.requestedPort
    return 49152 + Math.floor(this.random() * (65535 - 49152 + 1))
  }

  /** Start listening and publish admin.json. */
  async start() {
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const port = this.pickPort()
      try {
        await this.listen(port)
        this.port = port
        saveAdminFile(this.dir, { port, token: this.token })
        this.log(`admin loopback listening port=${String(port)}`)
        return
      } catch (error) {
        if (error.code !== 'EADDRINUSE' || this.requestedPort !== undefined) throw error
      }
    }
    throw pclinkError('unavailable', 'could not bind the loopback admin server')
  }

  listen(port) {
    return new Promise((resolve, reject) => {
      const server = createServer((request, response) => {
        void this.handle(request, response).catch(error => {
          if (!response.headersSent) sendJson(response, 500, { v: 1, error: { code: 'unavailable', message: error.message } })
          else response.end()
        })
      })
      server.on('error', reject)
      server.listen(port, '127.0.0.1', () => {
        server.off('error', reject)
        server.on('error', error => this.log(`admin server error: ${error.message}`))
        this.server = server
        resolve()
      })
    })
  }

  /** @returns {Promise<void>} close the listener. */
  async stop() {
    const server = this.server
    this.server = undefined
    if (server === undefined) return
    await new Promise(resolve => server.close(() => resolve()))
  }

  async handle(request, response) {
    const host = request.headers.host
    if (host !== `127.0.0.1:${String(this.port)}`) {
      response.writeHead(400, { 'cache-control': 'no-store' })
      response.end()
      return
    }
    if (request.headers.origin !== undefined) {
      response.writeHead(403, { 'cache-control': 'no-store' })
      response.end()
      return
    }
    const url = new URL(request.url ?? '/', `http://${host}`)
    if (url.pathname === '/v1/challenge') {
      if (request.method !== 'POST') {
        response.writeHead(405, { 'cache-control': 'no-store' })
        response.end()
        return
      }
      if (!isJsonContentType(request.headers['content-type'])) {
        response.writeHead(415, { 'cache-control': 'no-store' })
        response.end()
        return
      }
      let body
      try {
        body = parseStrictJsonObject(await readBody(request))
        const nonce = b64urlDecode(body.nonce, { length: 32 })
        const proof = adminProof(this.token, nonce)
        sendJson(response, 200, { v: 1, nonce: body.nonce, proof: b64urlEncode(proof) })
      } catch (error) {
        sendJson(response, 400, { v: 1, error: { code: 'bad_frame', message: error.message } })
      }
      return
    }
    if (!tokenMatches(request.headers.authorization, this.tokenText)) {
      sendJson(response, 401, { v: 1, error: { code: 'unavailable', message: 'unauthorized' } })
      return
    }
    try {
      if (url.pathname === '/v1/status') {
        if (request.method !== 'GET') {
          response.writeHead(405, { 'cache-control': 'no-store' })
          response.end()
          return
        }
        const status = this.plane.status()
        const text = JSON.stringify(status)
        if (Buffer.byteLength(text, 'utf8') > MAX_ADMIN_RESPONSE_BYTES) throw pclinkError('frame_too_large', 'status exceeds 256 KiB')
        sendJson(response, 200, status)
        return
      }
      const operation = {
        '/v1/pair': 'pair',
        '/v1/pair/approve': 'pair/approve',
        '/v1/pair/cancel': 'pair/cancel',
        '/v1/unpair': 'unpair',
        '/v1/rotate-identity': 'rotate-identity',
      }[url.pathname]
      if (operation === undefined) {
        response.writeHead(404, { 'cache-control': 'no-store' })
        response.end()
        return
      }
      if (request.method !== 'POST') {
        response.writeHead(405, { 'cache-control': 'no-store' })
        response.end()
        return
      }
      if (!isJsonContentType(request.headers['content-type'])) {
        response.writeHead(415, { 'cache-control': 'no-store' })
        response.end()
        return
      }
      let body = {}
      try {
        const text = await readBody(request)
        body = text === '' ? {} : parseStrictJsonObject(text)
      } catch (error) {
        sendJson(response, 400, { v: 1, error: { code: 'bad_frame', message: error.message } })
        return
      }
      const result = this.plane.handle(operation, body, { via: 'cli' })
      const text = JSON.stringify(result)
      if (Buffer.byteLength(text, 'utf8') > MAX_ADMIN_RESPONSE_BYTES) {
        sendJson(response, 500, { v: 1, error: { code: 'frame_too_large', message: 'admin response exceeds 256 KiB' } })
        return
      }
      sendJson(response, 200, result)
    } catch (error) {
      const code = typeof error.code === 'string' ? error.code : 'unavailable'
      const status = code === 'bad_frame' ? 400 : code === 'frame_too_large' ? 413 : 409
      sendJson(response, status, { v: 1, error: { code, message: error.message } })
    }
  }
}

function isJsonContentType(value) {
  if (typeof value !== 'string') return false
  const [type, ...parameters] = value.split(';').map(part => part.trim())
  if (type.toLowerCase() !== 'application/json') return false
  return parameters.every(parameter => parameter === '' || /^charset=utf-8$/i.test(parameter))
}

/**
 * Generate a loopback token (test helper).
 * @returns {string} 32-byte base64url token.
 */
export function newAdminToken() {
  return b64urlEncode(randomBytes(32))
}
