// SPDX-License-Identifier: MIT
/**
 * Local Streamable HTTP MCP server for the phone-mcp behavior test. It speaks
 * JSON-RPC over POST, requires the exact bearer token it was created with, and
 * exposes two tools whose results come from the request arguments. The token is
 * never printed; tests hold it in memory.
 *
 * @module @phone-dsh/phone-mcp-fixture
 */

import { randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import type { IncomingHttpHeaders, Server } from 'node:http'
import type { AddressInfo } from 'node:net'

/** One observed JSON-RPC request. */
export interface ObservedRequest {
  readonly method: string
  readonly headers: IncomingHttpHeaders
  readonly params: unknown
}

/** Optional failure mode used to reproduce authenticated HTTP error bodies. */
export interface McpFixtureRejection {
  /** HTTP status returned for rejected POSTs. */
  readonly status: number
  /** Reject only this exact Authorization header; omit to reject every POST. */
  readonly authorization?: string
}

/** Running fixture handle. */
export interface McpFixture {
  readonly url: string
  readonly token: string
  readonly requests: ObservedRequest[]
  readonly calls: { readonly name: string; readonly arguments: Record<string, unknown> }[]
  close(): Promise<void>
}

/** Construction options for the local fixture. */
export interface McpFixtureOptions {
  /** Return a non-2xx response that echoes the request Authorization value. */
  readonly reject?: McpFixtureRejection
  /** Accept requests without the bearer (a host-managed-header gateway test). */
  readonly allowAnonymous?: boolean
}

const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26']
/**
 * Ports Node's fetch refuses before sending (`undici`'s bad-port list). A
 * `listen(0)` allocation can land on one, so the helper retries rather than
 * making every caller handle a transport that never reaches the fixture.
 */
const BLOCKED_PORTS = new Set([
  1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95, 101, 102, 103, 104,
  109, 110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465, 512,
  513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 992,
  993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566, 6665, 6666,
  6667, 6668, 6669, 6679, 6697, 10080,
])
const TOOLS = [
  {
    name: 'ping',
    description: 'Return a fixed pong value.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true },
  },
  {
    name: 'echo',
    description: 'Echo a caller-provided message.',
    inputSchema: {
      type: 'object',
      properties: { message: { type: 'string' } },
      required: ['message'],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
]

interface JsonRpcMessage {
  readonly jsonrpc?: string
  readonly id?: string | number
  readonly method?: string
  readonly params?: unknown
}

function reply(id: string | number, result: unknown): object {
  return { jsonrpc: '2.0', id, result }
}

function failure(id: string | number, code: number, message: string): object {
  return { jsonrpc: '2.0', id, error: { code, message } }
}

function answer(message: JsonRpcMessage, calls: McpFixture['calls']): object | undefined {
  if (message.id === undefined) return undefined
  const id = message.id
  switch (message.method) {
    case 'initialize': {
      const requested = (message.params as { protocolVersion?: string } | undefined)?.protocolVersion
      return reply(id, {
        protocolVersion: PROTOCOL_VERSIONS.includes(requested ?? '') ? requested : PROTOCOL_VERSIONS[0],
        capabilities: { tools: {} },
        serverInfo: { name: 'phone-mcp-fixture', version: '0.1.0' },
      })
    }
    case 'ping': return reply(id, {})
    case 'tools/list': return reply(id, { tools: TOOLS })
    case 'tools/call': {
      const params = (message.params ?? {}) as { name?: string; arguments?: Record<string, unknown> }
      const name = params.name ?? ''
      const args = params.arguments ?? {}
      calls.push({ name, arguments: args })
      if (name === 'ping') return reply(id, { content: [{ type: 'text', text: 'pong' }] })
      if (name === 'echo') return reply(id, { content: [{ type: 'text', text: `echo:${String(args.message ?? '')}` }] })
      return failure(id, -32602, `unknown tool: ${name}`)
    }
    default:
      return failure(id, -32601, `method not found: ${String(message.method)}`)
  }
}

/**
 * Start one authenticated MCP fixture on a random loopback port.
 * @param options - optional rejection mode that echoes the request Authorization.
 * @returns The URL, bearer token, observations, and a close function.
 */
export async function startMcpFixture(options: McpFixtureOptions = {}): Promise<McpFixture> {
  const token = randomBytes(24).toString('hex')
  const sessionId = randomBytes(8).toString('hex')
  const requests: ObservedRequest[] = []
  const calls: McpFixture['calls'] = []

  const server: Server = createServer(async (req, res) => {
    if (req.method === 'GET') {
      res.writeHead(405, { allow: 'POST, DELETE' })
      res.end()
      return
    }
    if (req.method === 'DELETE') {
      res.writeHead(200)
      res.end()
      return
    }
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(chunk as Buffer)
    let parsed: JsonRpcMessage | JsonRpcMessage[]
    try {
      parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')) as JsonRpcMessage | JsonRpcMessage[]
    } catch {
      res.writeHead(400)
      res.end()
      return
    }
    const messages = Array.isArray(parsed) ? parsed : [parsed]
    const reject = options.reject !== undefined
      && (options.reject.authorization === undefined || req.headers.authorization === options.reject.authorization)
    if (reject) {
      // Let the era-negotiation probe fall back to legacy, then reject the
      // real connect attempt. The SDK's POST error includes the body, so this
      // is the exact path that would otherwise leak the echoed Authorization.
      if (messages.every(message => message.method === 'server/discover')) {
        const probeReplies = messages
          .map(message => answer(message, calls))
          .filter((value): value is object => value !== undefined)
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify(Array.isArray(parsed) ? probeReplies : probeReplies[0]))
        return
      }
      res.writeHead(options.reject.status, { 'content-type': 'text/plain; charset=utf-8' })
      res.end(`rejected: ${String(req.headers.authorization ?? '')}`)
      return
    }
    if (options.allowAnonymous !== true && req.headers.authorization !== `Bearer ${token}`) {
      res.writeHead(401)
      res.end()
      return
    }
    for (const message of messages) {
      if (message.method !== undefined) {
        requests.push({ method: message.method, headers: req.headers, params: message.params })
      }
    }
    const replies = messages
      .map(message => answer(message, calls))
      .filter((value): value is object => value !== undefined)
    if (replies.length === 0) {
      res.writeHead(202, { 'mcp-session-id': sessionId })
      res.end()
      return
    }
    res.writeHead(200, {
      'content-type': 'application/json',
      'mcp-session-id': sessionId,
    })
    res.end(JSON.stringify(Array.isArray(parsed) ? replies : replies[0]))
  })

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject)
      resolve()
    })
  })
  const address = server.address() as AddressInfo
  if (BLOCKED_PORTS.has(address.port)) {
    server.closeAllConnections()
    await new Promise<void>(resolve => { server.close(() => { resolve() }) })
    return startMcpFixture(options)
  }
  return {
    url: `http://127.0.0.1:${address.port}/mcp`,
    token,
    requests,
    calls,
    async close() {
      server.closeAllConnections()
      await new Promise<void>(resolve => { server.close(() => { resolve() }) })
    },
  }
}
