// SPDX-License-Identifier: MIT
/**
 * WPF0 connector-route shape check for the Bot identity-impersonation fix.
 *
 * The real `curl` shim is a production Worker seam: a model-written command
 * becomes one `POST <loopback>/v1/http` request with `x-pdsh-target-url` and
 * `x-pdsh-target-method`. The Swift test
 * `Tests/PhoneDSHTests/BotMCPEgressCredentialInjectionTests.swift` proves the
 * host side: a user-configured connector stored by `PhoneMCPAccessSettings`
 * receives its stored credential for that exact URL. This test proves the
 * Worker side: the shape produced by the real shim can name and reach such a
 * user connector route through the documented `/v1/http` host fixture.
 *
 * The host fixture mirrors the pre-fix production seam (exact path admission
 * plus stored-header injection). WPF1 owns the egress-credential gate and will
 * update this fixture to require `X-PDSH-MCP-Egress`; this file intentionally
 * does not claim that gate exists.
 */
import assert from 'node:assert/strict'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { VfsFileSystem } from '../shell-ext/src/index.ts'
import { runCurl } from '../shell-ext/src/curl.ts'

const CHANNEL_TOKEN = 'wpf0-fixture-channel-token'
const CONNECTOR_TOKEN = 'wpf0-fixture-connector-token'
const BODY = '{"jsonrpc":"2.0","id":"wpf0-connector","method":"tools/list"}'

interface HostSeen {
  readonly method: string
  readonly url: string
  readonly authorization: string | undefined
  readonly target: string
  readonly body: string
}

interface ConnectorSeen {
  readonly method: string
  readonly url: string
  readonly authorization: string | undefined
  readonly body: string
}

function readBody(request: IncomingMessage): Promise<string> {
  return new Promise((accept, refuse) => {
    const chunks: Buffer[] = []
    request.on('data', (chunk: Buffer) => chunks.push(chunk))
    request.on('error', refuse)
    request.on('end', () => accept(Buffer.concat(chunks).toString('utf8')))
  })
}

function listen(server: Server): Promise<string> {
  return new Promise((accept, refuse) => {
    server.once('error', refuse)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address() as AddressInfo
      accept(`http://127.0.0.1:${String(address.port)}`)
    })
  })
}

function close(server: Server): Promise<void> {
  return new Promise((accept, refuse) => {
    server.close(error => (error === undefined ? accept() : refuse(error)))
  })
}

function reply(response: ServerResponse, status: number, body: string): void {
  response.writeHead(status, { 'content-type': 'application/json' })
  response.end(body)
}

/** Exact scheme/host/effective-port/normalized-path comparison. */
function sameExactRoute(left: URL, right: URL): boolean {
  const port = (url: URL): number => url.port !== ''
    ? Number(url.port)
    : url.protocol === 'https:' ? 443 : 80
  const path = (url: URL): string => {
    const segments = url.pathname.split('/').filter(segment => segment !== '' && segment !== '.')
    const normalized: string[] = []
    for (const segment of segments) {
      if (segment === '..') normalized.pop()
      else normalized.push(segment)
    }
    return normalized.length === 0 ? '/' : `/${normalized.join('/')}`
  }
  return left.protocol === right.protocol
    && left.hostname.toLowerCase() === right.hostname.toLowerCase()
    && port(left) === port(right)
    && path(left) === path(right)
}

function scratchRoot(): { root: string; cleanup(): void } {
  const directory = mkdtempSync(join(tmpdir(), 'wpf0-connector-'))
  mkdirSync(join(directory, 'dsh', 'workspace'), { recursive: true })
  mkdirSync(join(directory, 'dsh', 'tmp'), { recursive: true })
  return { root: directory, cleanup: () => rmSync(directory, { recursive: true, force: true }) }
}

test('the real curl shim can target a user connector exact route over /v1/http', async () => {
  const connectorSeen: ConnectorSeen[] = []
  const connector: Server = createServer((request, response) => {
    void (async () => {
      const body = await readBody(request)
      connectorSeen.push({
        method: request.method ?? 'GET',
        url: request.url ?? '/',
        authorization: request.headers.authorization,
        body,
      })
      reply(response, 200, '{"jsonrpc":"2.0","id":"wpf0-connector","result":{"tools":[]}}')
    })()
  })
  const connectorOrigin = await listen(connector)

  const hostSeen: HostSeen[] = []
  const host: Server = createServer((request, response) => {
    void (async () => {
      const body = await readBody(request)
      const target = String(request.headers['x-pdsh-target-url'] ?? '')
      const method = String(request.headers['x-pdsh-target-method'] ?? request.method ?? 'POST').toUpperCase()
      hostSeen.push({
        method: request.method ?? 'GET',
        url: request.url ?? '/',
        authorization: request.headers.authorization,
        target,
        body,
      })
      if (request.method !== 'POST' || (request.url ?? '/') !== '/v1/http') {
        reply(response, 404, '{"error":"not_found"}')
        return
      }
      // The production /v1/http route rejects a request without the loopback
      // channel bearer before it reaches the gateway.
      if (request.headers.authorization !== `Bearer ${CHANNEL_TOKEN}`) {
        reply(response, 401, '{"error":"unauthorized"}')
        return
      }
      let parsed: URL
      try {
        parsed = new URL(target)
      } catch {
        reply(response, 400, '{"error":"bad_target"}')
        return
      }
      // Exact user-connector route. The query does not widen the credential
      // scope, matching `MCPEgressPolicy`.
      if (!sameExactRoute(parsed, new URL(`${connectorOrigin}/mcp`))) {
        // The production gateway answers 403 `forbidden` for a target outside
        // every exact MCP route; the shim maps that to exit 22.
        reply(response, 403, '{"error":"forbidden"}')
        return
      }
      const upstream = await fetch(parsed, {
        method,
        headers: {
          // Pre-fix fixture: the host stores and injects the connector header
          // for this exact route. WPF1 adds the egress-credential gate before
          // this injection; that rejection is covered by the Swift test.
          authorization: `Bearer ${CONNECTOR_TOKEN}`,
          'content-type': 'application/json',
        },
        body,
      })
      reply(response, upstream.status, await upstream.text())
    })()
  })
  const hostOrigin = await listen(host)
  const scratch = scratchRoot()
  try {
    const target = `${connectorOrigin}/mcp?session=wpf0-fixture`
    const result = await runCurl(
      ['-sS', '-X', 'POST', '--data-raw', BODY, target],
      { cwd: '/dsh/workspace', fs: new VfsFileSystem({ root: scratch.root }) },
      { origin: hostOrigin, token: CHANNEL_TOKEN })

    assert.equal(result.exitCode, 0, result.stderr)
    assert.match(result.stdout, /"tools":\[\]/u)

    // Worker -> host: the real shim's documented /v1/http request shape.
    assert.equal(hostSeen.length, 1)
    assert.equal(hostSeen[0]!.method, 'POST')
    assert.equal(hostSeen[0]!.url, '/v1/http')
    assert.equal(hostSeen[0]!.target, target,
      'the target keeps the exact user connector URL and its query')
    assert.equal(hostSeen[0]!.authorization, `Bearer ${CHANNEL_TOKEN}`,
      'the channel bearer authenticates the loopback hop')
    assert.equal(hostSeen[0]!.body, BODY)

    // Host -> connector: the fixture proves the exact route is reachable; the
    // real stored-header injection is asserted by the Swift test.
    assert.equal(connectorSeen.length, 1)
    assert.equal(connectorSeen[0]!.method, 'POST')
    assert.equal(connectorSeen[0]!.url, '/mcp?session=wpf0-fixture')
    assert.equal(connectorSeen[0]!.body, BODY)
  } finally {
    scratch.cleanup()
    await Promise.all([close(host), close(connector)])
  }
})
