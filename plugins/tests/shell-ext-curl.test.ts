// SPDX-License-Identifier: MIT
// W5-SHELL: the curl shim. Every request goes through the host `/v1/http`
// route with X-PDSH-Target-URL / X-PDSH-Target-Method and the channel bearer; the
// supported flag set is GET/HEAD/POST, -H, -d, -o, -s, -S, -L, -f, -w.
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { VfsFileSystem, WorkerShell, createCurlCommand, hostAllowed } from '../shell-ext/src/index.ts'

const roots: string[] = []

function fixture(): { root: string; fs: VfsFileSystem; shell: (fetchImpl: typeof fetch, options?: { allowHosts?: string[] }) => WorkerShell } {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-curl-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  return {
    root,
    fs,
    shell: (fetchImpl, options = {}) => new WorkerShell({
      fs,
      commands: [createCurlCommand({
        fetch: fetchImpl,
        origin: 'http://127.0.0.1:41000',
        token: 'test-token',
        ...options.allowHosts === undefined ? {} : { allowHosts: options.allowHosts },
      })],
    }),
  }
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

interface Call {
  readonly url: string
  readonly target: string
  readonly method: string
  readonly bearer: string | null
  readonly body: string | undefined
  readonly headers: Headers
}

function recorder(body = 'upstream-body\n', status = 200, headers: Record<string, string> = { 'content-type': 'text/plain' }): { fetch: typeof fetch; calls: Call[] } {
  const calls: Call[] = []
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const headers = new Headers(init?.headers)
    calls.push({
      url: String(input),
      target: headers.get('X-PDSH-Target-URL') ?? '',
      method: headers.get('X-PDSH-Target-Method') ?? '',
      bearer: headers.get('Authorization'),
      body: typeof init?.body === 'string' ? init.body : undefined,
      headers,
    })
    const target = headers.get('X-PDSH-Target-Method')
    const nullBody = target === 'HEAD' || status === 204 || status === 304
    return new Response(nullBody ? null : body, { status, headers })
  }) as typeof fetch
  return { fetch: fetchImpl, calls }
}

test('curl: GET goes through POST /v1/http with the target headers and bearer', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const { fetch, calls } = recorder('hello\n')
  const shell = fixtureShell(fs, fetch)
  const result = await shell.run(['bash', '-c', 'curl -s https://api.example.com/v1/thing'], { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, 'hello\n')
  assert.equal(calls.length, 1)
  assert.equal(calls[0]?.url, 'http://127.0.0.1:41000/v1/http')
  assert.equal(calls[0]?.target, 'https://api.example.com/v1/thing')
  assert.equal(calls[0]?.method, 'GET')
  assert.equal(calls[0]?.bearer, 'Bearer test-token')
})

test('curl: -X POST, -H and -d are forwarded; -o writes into the VFS', async () => {
  const { fs, root } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const { fetch, calls } = recorder('created\n')
  const shell = fixtureShell(fs, fetch)
  const result = await shell.run(['bash', '-c', 'curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer upstream-key" -d "{\\"a\\":1}" -o out.json https://api.example.com/items'], {
    cwd: '/dsh/workspace',
  })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stdout, '')
  assert.equal(calls[0]?.method, 'POST')
  assert.equal(calls[0]?.body, '{"a":1}')
  assert.equal(calls[0]?.headers.get('content-type'), 'application/json')
  assert.equal(calls[0]?.headers.get('x-pdsh-upstream-authorization'), 'Bearer upstream-key')
  assert.equal(readFileSync(join(root, 'dsh/workspace/out.json'), 'utf8'), 'created\n')
})

test('curl: -d implies POST and -I asks for HEAD', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const { fetch, calls } = recorder('', 204)
  const shell = fixtureShell(fs, fetch)
  const post = await shell.run(['bash', '-c', 'curl -s -d a=1 https://api.example.com/form'], { cwd: '/dsh/workspace' })
  assert.equal(post.exitCode, 0)
  assert.equal(calls[0]?.method, 'POST')
  const head = await shell.run(['bash', '-c', 'curl -sI https://api.example.com/head'], { cwd: '/dsh/workspace' })
  assert.equal(head.exitCode, 0)
  assert.equal(calls[1]?.method, 'HEAD')
  assert.match(head.stdout, /^HTTP\/1\.1 204/)
})

test('curl: -L follows redirects and -w renders the final status', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const seen: string[] = []
  const fetchImpl = (async (_input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const target = new Headers(init?.headers).get('X-PDSH-Target-URL') ?? ''
    seen.push(target)
    if (target === 'https://api.example.com/start') {
      return new Response(null, { status: 302, headers: { location: 'https://api.example.com/final' } })
    }
    return new Response('done', { status: 200, headers: { 'content-type': 'text/plain' } })
  }) as typeof fetch
  const shell = fixtureShell(fs, fetchImpl)
  const result = await shell.run(['bash', '-c', 'curl -sL -w "%{http_code}\\n" https://api.example.com/start'], { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 0)
  assert.deepEqual(seen, ['https://api.example.com/start', 'https://api.example.com/final'])
  assert.equal(result.stdout, 'done200\n')
})

test('curl: an unsupported method and an unknown flag fail clearly', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const { fetch, calls } = recorder()
  const shell = fixtureShell(fs, fetch)
  const put = await shell.run(['bash', '-c', 'curl -s -X PUT -d x https://api.example.com/key'], { cwd: '/dsh/workspace' })
  assert.equal(put.exitCode, 2)
  assert.match(put.stderr, /method PUT is not allowed/)
  const unknown = await shell.run(['bash', '-c', 'curl --cert client.pem https://api.example.com'], { cwd: '/dsh/workspace' })
  assert.equal(unknown.exitCode, 2)
  assert.match(unknown.stderr, /unsupported option --cert/)
  assert.equal(calls.length, 0)
})

test('curl: the Worker allow-list and a host 403 fail without a second path', async () => {
  const { fs } = fixture()
  await fs.mkdir('/dsh/workspace', { recursive: true })
  const { fetch, calls } = recorder()
  const shell = new WorkerShell({
    fs,
    commands: [createCurlCommand({
      fetch,
      origin: 'http://127.0.0.1:41000',
      token: 'test-token',
      allowHosts: ['api.example.com'],
    })],
  })
  const blocked = await shell.run(['bash', '-c', 'curl -s https://evil.example.com/'], { cwd: '/dsh/workspace' })
  assert.equal(blocked.exitCode, 6)
  assert.match(blocked.stderr, /not in the Worker allow-list/)
  assert.equal(calls.length, 0)
  assert.equal(hostAllowed('api.example.com', ['api.example.com']), true)
  assert.equal(hostAllowed('sub.api.example.com', ['api.example.com']), true)
  assert.equal(hostAllowed('notapi.example.com', ['api.example.com']), false)

  const denied = recorder('forbidden', 403)
  const deniedShell = fixtureShell(fs, denied.fetch)
  const result = await deniedShell.run(['bash', '-c', 'curl -s https://blocked.example.com/x'], { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 22)
  assert.match(result.stderr, /host allow-list rejected/)
})

/** Build the standard shell for one recorder. */
function fixtureShell(fs: VfsFileSystem, fetchImpl: typeof fetch): WorkerShell {
  return new WorkerShell({
    fs,
    commands: [createCurlCommand({ fetch: fetchImpl, origin: 'http://127.0.0.1:41000', token: 'test-token' })],
  })
}
