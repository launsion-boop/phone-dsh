// SPDX-License-Identifier: MIT
/**
 * Partial clone (`--filter=blob:none`) and cone-mode sparse-checkout.
 *
 * The HTTP fixture is the system git's upload-pack with protocol v2 enabled,
 * the same stateless smart HTTP the Worker speaks through `/v1/http`.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createServer } from 'node:http'
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import { HAS_GIT, SKIP_NO_GIT, fixtureEnvironment, systemGit, tempDirectory, workerGit } from './helpers.ts'
import { runGit } from '../cli.ts'
import type { HttpRequest, HttpResult, RemoteTransport } from '../http.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

function gitHttp(targetUrl: URL, method: string, body: Buffer, root: string, protocol: string | undefined): { status: number; body: Buffer } {
  const rest = targetUrl.pathname.replace(/^\//, '')
  const env = { ...process.env, ...protocol === undefined ? {} : { GIT_PROTOCOL: protocol } }
  if (method === 'GET' && rest === 'info/refs') {
    const advertised = spawnSync('git', ['upload-pack', '--stateless-rpc', '--advertise-refs', root], {
      cwd: root, env, encoding: 'buffer', maxBuffer: 8 * 1024 * 1024,
    })
    return { status: 200, body: Buffer.from(advertised.stdout ?? '') }
  }
  if (method === 'POST' && rest === 'git-upload-pack') {
    const result = spawnSync('git', ['upload-pack', '--stateless-rpc', root], {
      cwd: root, env, input: body, encoding: 'buffer', maxBuffer: 32 * 1024 * 1024,
    })
    return { status: 200, body: Buffer.from(result.stdout ?? '') }
  }
  return { status: 404, body: Buffer.from('unsupported') }
}

async function serve(root: string, token: string): Promise<{ origin: string; close: () => Promise<void> }> {
  let port = 0
  const server: Server = createServer((request: IncomingMessage, response: ServerResponse) => {
    const chunks: Buffer[] = []
    request.on('data', chunk => chunks.push(Buffer.from(chunk)))
    request.on('end', () => {
      if (request.url !== '/v1/http' || request.headers.authorization !== `Bearer ${token}`) {
        response.statusCode = 401
        response.end('unauthorized')
        return
      }
      const target = request.headers['x-pdsh-target-url']
      if (typeof target !== 'string') {
        response.statusCode = 400
        response.end('missing target')
        return
      }
      const targetUrl = new URL(target)
      const protocol = request.headers['git-protocol']
      const result = gitHttp(targetUrl, (request.headers['x-pdsh-target-method'] as string | undefined) ?? 'GET', Buffer.concat(chunks), root, Array.isArray(protocol) ? protocol[0] : protocol)
      response.statusCode = result.status
      response.end(result.body)
    })
  })
  await new Promise<void>(resolve => { server.listen(0, '127.0.0.1', () => resolve()) })
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  port = address.port
  return {
    origin: `http://127.0.0.1:${port}`,
    close: async () => { await new Promise<void>((resolve, reject) => server.close(error => error === undefined ? resolve() : reject(error))) },
  }
}

test('cone sparse-checkout materializes only the selected directories', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repo = join(temp.path, 'repo')
    mkdirSync(repo)
    const run = (args: readonly string[]) => workerGit(args, repo, environment.env)
    assert.equal((await run(['init', '-b', 'main'])).code, 0)
    writeFileSync(join(repo, 'README.md'), 'root\n')
    mkdirSync(join(repo, 'src'))
    writeFileSync(join(repo, 'src', 'a.txt'), 'code\n')
    mkdirSync(join(repo, 'docs'))
    writeFileSync(join(repo, 'docs', 'guide.md'), 'guide\n')
    assert.equal((await run(['add', '-A'])).code, 0)
    assert.equal((await run(['commit', '-m', 'base'])).code, 0)
    const set = await run(['sparse-checkout', 'set', 'src'])
    assert.equal(set.code, 0, set.stderr.toString())
    assert.equal(existsSync(join(repo, 'README.md')), true)
    assert.equal(readFileSync(join(repo, 'src', 'a.txt'), 'utf8'), 'code\n')
    assert.equal(existsSync(join(repo, 'docs', 'guide.md')), false)
    const status = await run(['status', '--porcelain'])
    assert.equal(status.stdout.toString(), '', status.stderr.toString())
    const list = await run(['sparse-checkout', 'list'])
    assert.equal(list.stdout.toString(), 'src\n')
    const added = await run(['sparse-checkout', 'add', 'docs'])
    assert.equal(added.code, 0, added.stderr.toString())
    assert.equal(readFileSync(join(repo, 'docs', 'guide.md'), 'utf8'), 'guide\n')
    const disabled = await run(['sparse-checkout', 'disable'])
    assert.equal(disabled.code, 0, disabled.stderr.toString())
    assert.equal(existsSync(join(repo, 'docs', 'guide.md')), true)
    assert.equal(existsSync(join(repo, 'src', 'a.txt')), true)
    assert.equal(existsSync(join(repo, '.git', 'info', 'sparse-checkout')), false)
  } finally {
    temp.cleanup()
  }
})

test('clone --filter=blob:none --sparse fetches blobs only for the cone', { skip }, async () => {
  const temp = tempDirectory()
  let route: { origin: string; close: () => Promise<void> } | undefined
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const origin = join(temp.path, 'origin')
    mkdirSync(origin)
    const git = (args: readonly string[]) => systemGit(args, origin, env)
    git(['init', '-q', '-b', 'main'])
    git(['config', 'uploadpack.allowFilter', 'true'])
    git(['config', 'uploadpack.allowAnySHA1InWant', 'true'])
    writeFileSync(join(origin, 'README.md'), 'hello\n')
    mkdirSync(join(origin, 'src'))
    writeFileSync(join(origin, 'src', 'a.txt'), 'payload\n')
    git(['add', '-A'])
    git(['commit', '-qm', 'base'])
    route = await serve(origin, 'test-token')
    const network = { ...env, PDSH_CHANNEL_ORIGIN: route.origin, PDSH_CHANNEL_TOKEN: 'test-token' }
    const work = join(temp.path, 'work')
    const clone = await workerGit(['clone', '--filter=blob:none', '--sparse', `${route.origin}/`, work], temp.path, network)
    assert.equal(clone.code, 0, clone.stderr.toString())
    assert.equal(readFileSync(join(work, 'README.md'), 'utf8'), 'hello\n')
    assert.equal(existsSync(join(work, 'src', 'a.txt')), false, 'the sparse cone did not materialize src')
    const config = readFileSync(join(work, '.git', 'config'), 'utf8')
    assert.match(config, /promisor = true/)
    assert.match(config, /partialclonefilter = blob:none/)
    assert.equal(existsSync(join(work, '.git', 'objects', 'pack')), true)
    const show = await workerGit(['show', 'HEAD:src/a.txt'], work, network)
    assert.equal(show.code, 0, show.stderr.toString())
    assert.equal(show.stdout.toString(), 'payload\n')
    const widened = await workerGit(['sparse-checkout', 'set', 'src'], work, network)
    assert.equal(widened.code, 0, widened.stderr.toString())
    assert.equal(readFileSync(join(work, 'src', 'a.txt'), 'utf8'), 'payload\n')
    assert.equal((await workerGit(['status', '--porcelain'], work, network)).stdout.toString(), '')
  } finally {
    if (route !== undefined) await route.close()
    temp.cleanup()
  }
})

test('live public GitHub partial clone', {
  skip: process.env.PDSH_GIT_PARTIAL_LIVE === '1' ? false : 'set PDSH_GIT_PARTIAL_LIVE=1 to clone a public repository',
}, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const transport: RemoteTransport = {
      async request(request: HttpRequest): Promise<HttpResult> {
        const response = await fetch(request.url, {
          method: request.method,
          headers: request.headers,
          ...request.body === undefined ? {} : { body: request.body },
        })
        return { status: response.status, body: new Uint8Array(await response.arrayBuffer()) }
      },
    }
    const work = join(temp.path, 'hello')
    const result = await runGit(
      ['clone', '--filter=blob:none', '--sparse', '--depth', '1', 'https://github.com/octocat/Hello-World.git', work],
      { cwd: temp.path, env: environment.env, transport },
    )
    assert.equal(result.exitCode, 0, new TextDecoder().decode(result.stderr))
    assert.equal(existsSync(join(work, 'README')), true)
  } finally {
    temp.cleanup()
  }
})
