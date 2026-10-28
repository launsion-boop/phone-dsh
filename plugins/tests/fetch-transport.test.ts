// SPDX-License-Identifier: MIT
// The `fetch` exec transport: same-origin loopback /v1/exec* over the Worker's
// own fetch, bearer-authenticated, NDJSON streaming.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { after, before, test } from 'node:test'
import { FetchExecTransport } from '../exec-bridge/src/transport.ts'
import type { ExecEvent } from '../exec-bridge/src/client.ts'

let base = ''
const requests: Array<{ method: string; url: string; authorization: string | undefined }> = []
const server = createServer((req: IncomingMessage, res: ServerResponse) => {
  requests.push({ method: req.method ?? '', url: req.url ?? '', authorization: req.headers.authorization })
  if (req.url === '/v1/hello') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    res.end(JSON.stringify({
      protocol: 'pdsh-exec-bridge/1',
      provider: { name: 'loopback-test' },
      guest: { platform: 'posix', mounts: [{ host_path: '/dsh', guest_path: '/dsh', read_only: false }] },
      capabilities: { exec: true, stdin_pipe: true, lifecycle: true, confine: [], accelerators: ['rg'] },
      limits: {},
    }))
    return
  }
  if (req.method === 'POST' && req.url === '/v1/exec') {
    res.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' })
    res.write(`${JSON.stringify({ type: 'start', exec_id: 'xl1-test-0', seq: 0, pid: 7 })}\n`)
    res.write(`${JSON.stringify({ type: 'output', exec_id: 'xl1-test-0', seq: 1, stream: 'stdout', data: Buffer.from('match\n').toString('base64') })}\n`)
    setTimeout(() => {
      res.end(`${JSON.stringify({ type: 'exit', exec_id: 'xl1-test-0', seq: 2, code: 0, signal: null, status: 'exited', quiescent: true })}\n`)
    }, 10)
    return
  }
  if (req.method === 'POST' && req.url === '/v1/exec/xl1-test-0/cancel') {
    res.writeHead(202)
    res.end()
    return
  }
  res.writeHead(404)
  res.end()
})

before(async () => { await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve)); base = `http://127.0.0.1:${(server.address() as AddressInfo).port}` })
after(() => { server.closeAllConnections(); server.close() })

test('fetch transport: hello facts, bearer auth and streamed events', async () => {
  const transport = new FetchExecTransport({ url: base, token: 'fetch-token-0123456789', accelerators: ['rg'] })
  const hello = await transport.hello()
  assert.equal(hello.protocol, 'pdsh-exec-bridge/1')
  assert.deepEqual(hello.capabilities.accelerators, ['rg'])
  assert.equal(requests[0]?.authorization, 'Bearer fetch-token-0123456789')

  const events: ExecEvent[] = []
  const stream = await transport.exec({
    exec_id: 'xl1-test-0',
    argv: ['rg', 'needle'],
    cwd: '/dsh/workspace',
    env: { TERM: 'dumb' },
    grace_ms: 3000,
    stdin: { mode: 'ignore' },
    requires_mseq: 47,
    idem_key: '2d3562b36e18c2441bd7bb4ed95c67bd72a86983387bd7f04f6d1ef1668cc81a',
  })
  for await (const event of stream) events.push(event)
  assert.deepEqual(events.map(event => [event.type, event.seq]), [['start', 0], ['output', 1], ['exit', 2]])
  const posted = requests.find(request => request.url === '/v1/exec')
  assert.equal(posted?.authorization, 'Bearer fetch-token-0123456789')

  await transport.cancel('xl1-test-0')
  assert.ok(requests.some(request => request.url === '/v1/exec/xl1-test-0/cancel'))
  assert.equal(transport.lastMseq(), 0n)
  transport.destroy()
})

test('fetch transport rejects a non-loopback base URL', () => {
  assert.throws(() => new FetchExecTransport({ url: 'http://exec.example:1234', token: 'fetch-token-0123456789' }), /loopback/)
})
