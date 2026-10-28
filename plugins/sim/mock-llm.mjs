#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Scripted, stateless mock of a Messages-compatible model endpoint (the wire
// format DSH's DeepSeek adapter speaks: POST <base>/v1/messages, SSE stream).
// No model, no credentials: every response is derived from the request's
// message history, so a resumed session continues the script deterministically.
//
//   node sim/mock-llm.mjs [--port 0] [--sleep 6] [--script ledger|search|mcp]
//
// Script (the demo task; `--script search` first runs a read-only grep):
//   1. bash: append one line carrying $XL_IDEMPOTENCY_KEY to ledger.txt, sleep, echo charged
//      (a non-idempotent side effect with a window to kill the harness in)
//   2. if the bash result reports an UNKNOWN outcome: bash grep for the idempotency key (verify)
//   3. write: report.md
//   4. final text
// Prints {"ready":true,"url":...} on stdout; logs one line per request on stderr.

import http from 'node:http'
import { parseArgs } from 'node:util'

const { values: opts } = parseArgs({
  options: {
    port: { type: 'string', default: '0' },
    sleep: { type: 'string', default: '6' },
    // ledger: start with the non-idempotent bash charge; search: start with a read-only grep;
    // mcp: call the phone MCP tool, then write clipboard.md.
    script: { type: 'string', default: 'ledger' },
  },
})
let requests = 0

function textOf(content) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.map(block => block.type === 'text' ? block.text : block.type === 'tool_result' ? textOf(block.content) : '').join('\n')
}

/** Decide the next assistant turn from the transcript. */
function decide(messages) {
  const toolUses = []
  const results = new Map()
  for (const message of messages) {
    if (!Array.isArray(message.content)) continue
    for (const block of message.content) {
      if (message.role === 'assistant' && block.type === 'tool_use') toolUses.push(block)
      if (message.role === 'user' && block.type === 'tool_result') results.set(block.tool_use_id, { text: textOf(block.content), isError: block.is_error === true })
    }
  }
  const last = toolUses.at(-1)
  if (last === undefined && opts.script === 'mcp') {
    return {
      text: 'I will read the phone clipboard through the app first.',
      tool: { name: 'mcp__phone__clipboard_get', input: {} },
    }
  }
  if (last?.name === 'mcp__phone__clipboard_get' && results.has(last.id)) {
    return {
      text: 'Now I will save what the clipboard said.',
      tool: { name: 'write', input: { file_path: 'clipboard.md', content: `${results.get(last.id).text}\n` } },
    }
  }
  if (last === undefined && opts.script === 'search') {
    return {
      text: 'First I will look for earlier charges.',
      tool: { name: 'grep', input: { pattern: 'charge' } },
    }
  }
  if (last === undefined || (opts.script === 'search' && toolUses.length === 1 && results.has(last.id))) {
    return {
      text: 'I will record the charge in the ledger first.',
      tool: { name: 'bash', input: { description: 'Record one charge in the ledger', command: `printf 'charge %s\\n' "$XL_IDEMPOTENCY_KEY" >> ledger.txt && sleep ${Number(opts.sleep)} && echo charged` } },
    }
  }
  const result = results.get(last.id)
  if (result === undefined) return { text: 'Waiting for the tool result.' }
  if (last.name === 'bash' && last.input.command.includes('>> ledger.txt')) {
    const key = /Idempotency key: (xl1-[0-9a-f]+)/.exec(result.text)?.[1]
    if (/outcome is UNKNOWN/i.test(result.text) && key !== undefined) {
      return {
        text: 'The ledger command was interrupted and its outcome is unknown, so I will check the ledger for its idempotency key instead of charging again.',
        tool: { name: 'bash', input: { description: 'Check the ledger for the interrupted charge', command: `grep -c -F '${key}' ledger.txt || echo 0` } },
      }
    }
  }
  if (last.name === 'bash') {
    return {
      text: 'Now I will write the report.',
      tool: { name: 'write', input: { file_path: 'report.md', content: `# Ledger report\n\nLast shell result:\n\n\`\`\`\n${result.text.slice(0, 400)}\n\`\`\`\n` } },
    }
  }
  return { text: opts.script === 'mcp' ? 'Done: the clipboard was saved to clipboard.md.' : 'Done: the ledger was charged once and report.md was written.' }
}

function sse(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`)
}

const server = http.createServer(async (req, res) => {
  const chunks = []
  for await (const chunk of req) chunks.push(chunk)
  if (req.method !== 'POST' || !req.url?.endsWith('/v1/messages')) {
    res.writeHead(404, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: `no route ${req.method} ${req.url}` } }))
    return
  }
  const body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
  const turn = decide(body.messages ?? [])
  requests++
  process.stderr.write(`mock-llm: request ${requests} (${(body.messages ?? []).length} messages, idempotency=${req.headers['x-pdsh-idempotency-key'] ?? '-'}) -> ${turn.tool ? `tool ${turn.tool.name}` : 'text'}\n`)
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
  sse(res, 'message_start', { message: { id: `msg_mock_${requests}`, type: 'message', role: 'assistant', model: body.model, content: [], usage: { input_tokens: 100, output_tokens: 0 } } })
  let index = 0
  sse(res, 'content_block_start', { index, content_block: { type: 'text', text: '' } })
  sse(res, 'content_block_delta', { index, delta: { type: 'text_delta', text: turn.text } })
  sse(res, 'content_block_stop', { index })
  if (turn.tool !== undefined) {
    index++
    sse(res, 'content_block_start', { index, content_block: { type: 'tool_use', id: `toolu_mock_${requests}_${Math.random().toString(16).slice(2, 10)}`, name: turn.tool.name, input: {} } })
    sse(res, 'content_block_delta', { index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(turn.tool.input) } })
    sse(res, 'content_block_stop', { index })
  }
  sse(res, 'message_delta', { delta: { stop_reason: turn.tool ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 20 } })
  sse(res, 'message_stop', {})
  res.end()
})

server.listen(Number(opts.port), '127.0.0.1', () => {
  process.stdout.write(`${JSON.stringify({ ready: true, url: `http://127.0.0.1:${server.address().port}` })}\n`)
})
process.on('SIGTERM', () => process.exit(0))
