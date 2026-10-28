#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Minimal stand-in for the host app's loopback MCP endpoint (streamable HTTP,
// bearer token, JSON responses). Serves one read-only phone tool so the
// simulation can prove the MCP path under `--jitless`, including the
// X-PDSH-Idempotency-Key header the fetch transport adds inside a tool call.
//
//   node sim/phone-mcp-sim.mjs [--port 0]
// Prints {"ready":true,"url":".../mcp","token":...} on stdout (simulation only).

import { randomBytes } from 'node:crypto'
import http from 'node:http'
import { parseArgs } from 'node:util'

const { values: opts } = parseArgs({ options: { port: { type: 'string', default: '0' } } })
const token = randomBytes(24).toString('hex')
const VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26']
const tools = [{
  name: 'clipboard_get',
  description: 'Read the phone clipboard (simulated).',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  annotations: { readOnlyHint: true },
}]

function answer(message, headers) {
  const reply = result => ({ jsonrpc: '2.0', id: message.id, result })
  switch (message.method) {
    case 'initialize': {
      const requested = message.params?.protocolVersion
      return reply({ protocolVersion: VERSIONS.includes(requested) ? requested : VERSIONS[0], capabilities: { tools: {} }, serverInfo: { name: 'phone-sim', version: '0.1.0' } })
    }
    case 'ping': return reply({})
    case 'tools/list': return reply({ tools })
    case 'tools/call': {
      const key = headers['x-pdsh-idempotency-key'] ?? 'none'
      process.stderr.write(`phone-mcp: tools/call ${message.params?.name} idempotency=${key}\n`)
      return reply({ content: [{ type: 'text', text: `clipboard text: "meeting at 3pm" (request idempotency key: ${key})` }] })
    }
    default:
      return { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: `method not found: ${message.method}` } }
  }
}

const server = http.createServer(async (req, res) => {
  if (req.headers.authorization !== `Bearer ${token}`) { res.writeHead(401); res.end(); return }
  if (req.method === 'GET') { res.writeHead(405, { allow: 'POST, DELETE' }); res.end(); return }
  if (req.method === 'DELETE') { res.writeHead(200); res.end(); return }
  const chunks = []
  for await (const chunk of req) chunks.push(chunk)
  const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'))
  const messages = Array.isArray(parsed) ? parsed : [parsed]
  process.stderr.write(`phone-mcp: ${messages.map(m => m.method ?? 'response').join(',')}\n`)
  const replies = messages.filter(m => m.id !== undefined && m.method !== undefined).map(m => answer(m, req.headers))
  if (replies.length === 0) { res.writeHead(202); res.end(); return }
  const body = JSON.stringify(Array.isArray(parsed) ? replies : replies[0])
  res.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': 'sim-session' })
  res.end(body)
})

server.listen(Number(opts.port), '127.0.0.1', () => {
  process.stdout.write(`${JSON.stringify({ ready: true, url: `http://127.0.0.1:${server.address().port}/mcp`, token })}\n`)
})
process.on('SIGTERM', () => process.exit(0))
