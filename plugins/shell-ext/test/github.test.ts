// SPDX-License-Identifier: MIT
/**
 * `github` talks to api.github.com only through the host `/v1/http` route.
 *
 * The Worker must not attach a GitHub token. The loopback Authorization header
 * is the channel bearer, which the gateway strips before injecting the host
 * credential for api.github.com.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createWorkerCommands, WORKER_SHELL_PROGRAMS } from '../src/commands.ts'
import {
  GITHUB_DESCRIPTION,
  GITHUB_MAX_FILE_BYTES,
  GITHUB_MAX_OUTPUT_BYTES,
  createGithubCommand,
  redactGithubText,
  runGithub,
} from '../src/github.ts'

const ORIGIN = 'http://127.0.0.1:41000'
const CHANNEL = 'loopback-channel-token'

interface Seen {
  readonly target: string
  readonly method: string
  readonly bearer: string | null
  readonly upstreamAuthorization: string | null
  readonly userAgent: string | null
  readonly body: string | undefined
}

function mock(handler: (seen: Seen) => { status: number; body: string; headers?: Record<string, string> }): {
  fetch: typeof fetch
  calls: Seen[]
} {
  const calls: Seen[] = []
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const headers = new Headers(init?.headers)
    const seen: Seen = {
      target: headers.get('X-PDSH-Target-URL') ?? '',
      method: headers.get('X-PDSH-Target-Method') ?? '',
      bearer: headers.get('Authorization'),
      upstreamAuthorization: headers.get('X-PDSH-Upstream-Authorization'),
      userAgent: headers.get('User-Agent'),
      body: typeof init?.body === 'string' ? init.body : undefined,
    }
    calls.push(seen)
    assert.equal(String(input), `${ORIGIN}/v1/http`)
    const result = handler(seen)
    return new Response(result.body, { status: result.status, headers: result.headers })
  }) as typeof fetch
  return { fetch: fetchImpl, calls }
}

function command(fetchImpl: typeof fetch) {
  return createGithubCommand({
    fetch: fetchImpl, origin: ORIGIN, token: CHANNEL,
    authenticated: true, writeEnabled: true,
  })
}

test('github is on the worker command table and describes the no-token rule', async () => {
  assert.ok(WORKER_SHELL_PROGRAMS.includes('github'))
  const table = createWorkerCommands({ git: false, curl: false, toolbox: false, ubuntu: false, gzip: false })
  const github = table.find(entry => entry.name === 'github')
  assert.ok(github !== undefined)
  assert.match(GITHUB_DESCRIPTION, /no local clone/)
  assert.match(GITHUB_DESCRIPTION, /Never pass a token/)
  const help = await runGithub(['--help'])
  assert.equal(help.exitCode, 0)
  assert.match(help.stdout, /api\.github\.com/)
  assert.match(help.stdout, /createCommitOnBranch/)
  assert.equal(help.stderr, '')
})

test('github get decodes a contents blob and does not send a GitHub token', async () => {
  const { fetch, calls } = mock(() => ({
    status: 200,
    body: JSON.stringify({
      type: 'file',
      path: 'README.md',
      sha: 'abc',
      encoding: 'base64',
      content: Buffer.from('hello\n', 'utf8').toString('base64'),
    }),
  }))
  const result = await command(fetch).execute(['get', 'octo/example', 'README.md', '--ref', 'main'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(result.exitCode, 0, result.stderr)
  const parsed = JSON.parse(result.stdout) as { content: string; encoding: string }
  assert.equal(parsed.encoding, 'utf-8')
  assert.equal(parsed.content, 'hello\n')
  assert.equal(calls.length, 1)
  assert.equal(calls[0]?.method, 'GET')
  assert.equal(calls[0]?.target, 'https://api.github.com/repos/octo/example/contents/README.md?ref=main')
  assert.equal(calls[0]?.bearer, `Bearer ${CHANNEL}`)
  assert.equal(calls[0]?.upstreamAuthorization, null)
  assert.equal(calls[0]?.userAgent, 'phone-dsh')
  assert.equal(result.stdout.includes(CHANNEL), false)
})

test('a successful response body is data, not redacted', async () => {
  const { fetch } = mock(() => ({
    status: 200,
    body: JSON.stringify([{ path: 'Bearer token.txt', type: 'file', sha: 's' }]),
  }))
  const result = await command(fetch).execute(['get', 'octo/example', ''], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(result.exitCode, 2)
  const dir = await command(fetch).execute(['get', 'octo/example', 'docs'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(dir.exitCode, 0, dir.stderr)
  const parsed = JSON.parse(dir.stdout) as { entries: { path: string }[] }
  assert.equal(parsed.entries[0]?.path, 'Bearer token.txt')
})

test('github tree filters a prefix and search pins the repo qualifier', async () => {
  const { fetch, calls } = mock(seen => {
    if (seen.target.includes('/git/trees/')) {
      return {
        status: 200,
        body: JSON.stringify({
          sha: 'tree',
          truncated: false,
          tree: [
            { path: 'src/a.ts', type: 'blob', sha: '1', size: 3 },
            { path: 'README.md', type: 'blob', sha: '2', size: 4 },
          ],
        }),
      }
    }
    return {
      status: 200,
      body: JSON.stringify({
        total_count: 1,
        items: [{ path: 'src/a.ts', html_url: 'https://github.com/octo/example/blob/main/src/a.ts', sha: '1' }],
      }),
    }
  })
  const github = command(fetch)
  const tree = await github.execute(['tree', 'octo/example', '--ref', 'main', '--path', 'src'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(tree.exitCode, 0, tree.stderr)
  const listed = JSON.parse(tree.stdout) as { entries: { path: string }[] }
  assert.deepEqual(listed.entries.map(entry => entry.path), ['src/a.ts'])
  const search = await github.execute(['search', 'octo/example', 'hello world'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(search.exitCode, 0, search.stderr)
  assert.match(calls[1]?.target ?? '', /\/search\/code\?q=/)
  assert.match(decodeURIComponent(calls[1]?.target ?? ''), /repo:octo\/example/)
  assert.equal(calls.every(call => call.upstreamAuthorization === null), true)
})

test('github commit sends one createCommitOnBranch mutation and redacts echoed tokens', async () => {
  const { fetch, calls } = mock(seen => {
    if (seen.method === 'GET') {
      return { status: 200, body: JSON.stringify({ object: { sha: 'a'.repeat(40) } }) }
    }
    return {
      status: 200,
      body: JSON.stringify({
        data: { createCommitOnBranch: { commit: { oid: 'b'.repeat(40), url: 'https://github.com/octo/example/commit/b' } } },
      }),
    }
  })
  const result = await command(fetch).execute([
    'commit', 'octo/example',
    '--branch', 'feature',
    '--message', 'fix readme\n\nmore',
    '--file', 'README.md', '--text', 'hello',
    '--file', 'old.txt', '--delete',
  ], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(calls.length, 2)
  assert.match(calls[0]?.target ?? '', /\/git\/ref\/heads\/feature$/)
  assert.equal(calls[1]?.target, 'https://api.github.com/graphql')
  const body = JSON.parse(calls[1]?.body ?? '{}') as {
    query: string
    variables: { input: { expectedHeadOid: string; fileChanges: { additions: { contents: string }[]; deletions: { path: string }[] }; message: { headline: string; body: string } } }
  }
  assert.match(body.query, /createCommitOnBranch/)
  assert.equal(body.variables.input.expectedHeadOid, 'a'.repeat(40))
  assert.equal(body.variables.input.message.headline, 'fix readme')
  assert.equal(body.variables.input.message.body, 'more')
  assert.equal(body.variables.input.fileChanges.additions[0]?.contents, Buffer.from('hello', 'utf8').toString('base64'))
  assert.deepEqual(body.variables.input.fileChanges.deletions, [{ path: 'old.txt' }])
  assert.equal(calls[1]?.upstreamAuthorization, null)

  const leaked = `token is ghp_${'A'.repeat(20)} and ${CHANNEL}`
  assert.equal(redactGithubText(leaked, [CHANNEL]).includes('ghp_'), false)
  assert.equal(redactGithubText(leaked, [CHANNEL]).includes(CHANNEL), false)
})

test('github commit accepts binary content through --base64 and stdin', async () => {
  const { fetch, calls } = mock(seen => seen.method === 'GET'
    ? { status: 200, body: JSON.stringify({ object: { sha: 'a'.repeat(40) } }) }
    : { status: 200, body: JSON.stringify({ data: { createCommitOnBranch: { commit: { oid: 'b'.repeat(40) } } } }) })
  const github = command(fetch)
  const args = ['commit', 'octo/example', '--branch', 'main', '--message', 'binary', '--file', 'bin.dat', '--base64', 'AAEC']
  const result = await github.execute(args, { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(result.exitCode, 0, result.stderr)
  const body = JSON.parse(calls[1]?.body ?? '{}') as { variables: { input: { fileChanges: { additions: { path: string; contents: string }[] } } } }
  assert.deepEqual(body.variables.input.fileChanges.additions, [{ path: 'bin.dat', contents: 'AAEC' }])
  const stdin = await github.execute(
    ['commit', 'octo/example', '--branch', 'main', '--message', 'binary stdin'],
    { cwd: '/', stdin: JSON.stringify({ files: [{ path: 'bin.dat', base64: 'AAEC' }] }), env: {}, fs: undefined as never },
  )
  assert.equal(stdin.exitCode, 0, stdin.stderr)
  const invalid = await github.execute(
    ['commit', 'octo/example', '--branch', 'main', '--message', 'bad', '--file', 'bin.dat', '--base64', 'not base64'],
    { cwd: '/', stdin: '', env: {}, fs: undefined as never },
  )
  assert.equal(invalid.exitCode, 2)
})

test('a gateway refusal is reported without echoing the channel token', async () => {
  const { fetch, calls } = mock(() => ({
    status: 403,
    headers: { 'x-pdsh-proxy-error': 'host_not_allowed' },
    body: JSON.stringify({ error: { message: `denied for ${CHANNEL}` } }),
  }))
  const result = await command(fetch).execute(['get', 'octo/example', 'README.md'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /host_not_allowed/)
  assert.equal(result.stderr.includes(CHANNEL), false)
  assert.equal(result.stdout.includes(CHANNEL), false)
  assert.equal(calls[0]?.upstreamAuthorization, null)
})

test('oversized commits and unsafe paths never reach the network', async () => {
  const { fetch, calls } = mock(() => ({ status: 500, body: '{}' }))
  const huge = 'x'.repeat(GITHUB_MAX_FILE_BYTES + 1)
  const big = await command(fetch).execute([
    'commit', 'octo/example', '--branch', 'feature', '--message', 'big', '--file', 'a.txt', '--text', huge,
  ], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(big.exitCode, 2)
  assert.match(big.stderr, /limit/)
  const traversal = await command(fetch).execute(['get', 'octo/example', '../secret'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(traversal.exitCode, 2)
  assert.match(traversal.stderr, /path/)
  const url = await command(fetch).execute(['get', 'https://github.com/octo/example', 'README.md'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(url.exitCode, 2)
  assert.equal(calls.length, 0)
})

test('without a host credential only anonymous get/tree send a request', async () => {
  const { fetch, calls } = mock(() => ({ status: 200, body: JSON.stringify({ type: 'file', path: 'x', sha: 's' }) }))
  const readOnly = createGithubCommand({
    fetch, origin: ORIGIN, token: CHANNEL,
    authenticated: false, writeEnabled: true,
  })
  for (const args of [
    ['search', 'octo/example', 'needle'],
    ['branch', 'octo/example', 'feature', '--from', 'main'],
    ['commit', 'octo/example', '--branch', 'main', '--message', 'm', '--file', 'a.txt', '--text', 'x'],
    ['pr', 'octo/example', '--head', 'feature', '--base', 'main', '--title', 't'],
  ]) {
    const result = await readOnly.execute(args, { cwd: '/', stdin: '', env: {}, fs: undefined as never })
    assert.equal(result.exitCode, 1, args[0])
    assert.match(result.stderr, /GitHub credential/)
    assert.doesNotMatch(result.stderr, new RegExp(CHANNEL))
  }
  assert.equal(calls.length, 0)
  const read = await readOnly.execute(['get', 'octo/example', 'x'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(read.exitCode, 0, read.stderr)
  assert.equal(calls.length, 1)
})

test('a read credential enables search but not writes until the opt-in', async () => {
  const { fetch, calls } = mock(() => ({
    status: 200,
    body: JSON.stringify({ total_count: 0, items: [] }),
  }))
  const readCredential = createGithubCommand({
    fetch, origin: ORIGIN, token: CHANNEL,
    authenticated: true, writeEnabled: false,
  })
  const search = await readCredential.execute(['search', 'octo/example', 'needle'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(search.exitCode, 0, search.stderr)
  assert.equal(calls.length, 1)
  const commit = await readCredential.execute(
    ['commit', 'octo/example', '--branch', 'main', '--message', 'm', '--file', 'a.txt', '--text', 'x'],
    { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(commit.exitCode, 1)
  assert.match(commit.stderr, /writes are disabled/)
  assert.equal(calls.length, 1)
})

test('a file larger than the output budget is reported instead of truncated JSON', async () => {
  const content = Buffer.alloc(GITHUB_MAX_OUTPUT_BYTES, 0x61).toString('base64')
  const { fetch } = mock(() => ({
    status: 200,
    body: JSON.stringify({ type: 'file', path: 'big.txt', sha: 's', size: GITHUB_MAX_OUTPUT_BYTES, encoding: 'base64', content }),
  }))
  const result = await command(fetch).execute(['get', 'octo/example', 'big.txt'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(result.exitCode, 0, result.stderr)
  const parsed = JSON.parse(result.stdout) as { truncated?: boolean; content?: string; size?: number }
  assert.equal(parsed.truncated, true)
  assert.equal(parsed.content, undefined)
  assert.equal(parsed.size, GITHUB_MAX_OUTPUT_BYTES)
  assert.equal(Buffer.byteLength(result.stdout) <= GITHUB_MAX_OUTPUT_BYTES, true)
})

test('github branch and pr post the GitHub JSON and read stdin commits', async () => {
  const { fetch, calls } = mock(seen => {
    if (seen.method === 'GET') return { status: 200, body: JSON.stringify({ object: { sha: 'c'.repeat(40) } }) }
    if (seen.target.endsWith('/git/refs')) return { status: 201, body: JSON.stringify({ ref: 'refs/heads/feature' }) }
    if (seen.target.endsWith('/graphql')) {
      return { status: 200, body: JSON.stringify({ data: { createCommitOnBranch: { commit: { oid: 'd'.repeat(40) } } } }) }
    }
    return { status: 201, body: JSON.stringify({ number: 7, html_url: 'https://github.com/octo/example/pull/7', state: 'open' }) }
  })
  const github = command(fetch)
  const branch = await github.execute(['branch', 'octo/example', 'feature', '--from', 'main'], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(branch.exitCode, 0, branch.stderr)
  const branchBody = JSON.parse(calls[1]?.body ?? '{}') as { ref: string; sha: string }
  assert.equal(branchBody.ref, 'refs/heads/feature')
  assert.equal(branchBody.sha, 'c'.repeat(40))
  const commit = await github.execute(
    ['commit', 'octo/example', '--branch', 'feature', '--message', 'from stdin'],
    { cwd: '/', stdin: JSON.stringify({ files: [{ path: 'a.txt', text: 'from-stdin' }] }), env: {}, fs: undefined as never },
  )
  assert.equal(commit.exitCode, 0, commit.stderr)
  const pr = await github.execute([
    'pr', 'octo/example', '--head', 'feature', '--base', 'main', '--title', 'Ship it', '--body', 'notes',
  ], { cwd: '/', stdin: '', env: {}, fs: undefined as never })
  assert.equal(pr.exitCode, 0, pr.stderr)
  const opened = JSON.parse(pr.stdout) as { number: number; url: string }
  assert.equal(opened.number, 7)
  assert.equal(opened.url, 'https://github.com/octo/example/pull/7')
  const prBody = JSON.parse(calls.at(-1)?.body ?? '{}') as { title: string; head: string; base: string; body: string }
  assert.deepEqual(prBody, { title: 'Ship it', head: 'feature', base: 'main', body: 'notes' })
})
