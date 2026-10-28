// SPDX-License-Identifier: MIT
/**
 * `clone` / `fetch` / `pull` / `push` over the phone egress.
 *
 * The Worker has no sockets: the production transport POSTs to the host
 * loopback `/v1/http` route, which owns the allow-list. This test stands up
 * exactly that route around the system git's own smart-HTTP plumbing
 * (`upload-pack` / `receive-pack`), so the Worker git speaks the real protocol
 * and every byte crosses the `X-PDSH-Target-URL` hop. A rejected origin must
 * answer 403 and the command must fail without writing a repository.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/remote.test
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createServer } from 'node:http'
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, fixtureEnvironment, systemGit, tempDirectory, workerGit,
} from './helpers.ts'
import type { CommandResult } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

/** Serve one smart-HTTP advertisement or RPC the way git-http-backend does. */
function gitHttp(targetUrl: URL, method: string, body: Buffer, roots: ReadonlyMap<string, string>): { status: number; body: Buffer; contentType?: string } {
  const match = /^\/([^/]+)\/(.*)$/.exec(targetUrl.pathname)
  if (match === null) return { status: 404, body: Buffer.from('unknown path') }
  const root = roots.get(match[1] as string)
  if (root === undefined) return { status: 404, body: Buffer.from('unknown repository') }
  const rest = match[2] as string
  if (method === 'GET' && rest === 'info/refs') {
    const service = targetUrl.searchParams.get('service')
    if (service !== 'git-upload-pack' && service !== 'git-receive-pack') {
      return { status: 400, body: Buffer.from('unknown service') }
    }
    const command = service === 'git-upload-pack' ? 'upload-pack' : 'receive-pack'
    const advertised = spawnSync('git', [command, '--stateless-rpc', '--advertise-refs', root], {
      encoding: 'buffer',
      maxBuffer: 64 * 1024 * 1024,
    })
    const line = `# service=${service}\n`
    const header = Buffer.from(`${(line.length + 4).toString(16).padStart(4, '0')}${line}0000`)
    return {
      status: 200,
      body: Buffer.concat([header, Buffer.from(advertised.stdout ?? '')]),
      contentType: `application/x-${service}-advertisement`,
    }
  }
  if (method === 'POST' && (rest === 'git-upload-pack' || rest === 'git-receive-pack')) {
    const command = rest === 'git-upload-pack' ? 'upload-pack' : 'receive-pack'
    const result = spawnSync('git', [command, '--stateless-rpc', root], {
      input: body,
      encoding: 'buffer',
      maxBuffer: 128 * 1024 * 1024,
    })
    return {
      status: 200,
      body: Buffer.from(result.stdout ?? ''),
      contentType: `application/x-${rest}-result`,
    }
  }
  return { status: 404, body: Buffer.from('unsupported route') }
}

/** One in-process host `/v1/http` route with an origin allow-list. */
interface HostRoute {
  readonly origin: string
  readonly token: string
  readonly port: number
  close(): Promise<void>
}

async function startHostRoute(roots: ReadonlyMap<string, string>, token: string): Promise<HostRoute> {
  let port = 0
  const server: Server = createServer((request: IncomingMessage, response: ServerResponse) => {
    const chunks: Buffer[] = []
    request.on('data', chunk => chunks.push(Buffer.from(chunk)))
    request.on('end', () => {
      if (request.url !== '/v1/http' || request.method !== 'POST') {
        response.statusCode = 404
        response.end('not the host route')
        return
      }
      if (request.headers.authorization !== `Bearer ${token}`) {
        response.statusCode = 401
        response.end('unauthorized')
        return
      }
      const target = request.headers['x-pdsh-target-url']
      const method = (request.headers['x-pdsh-target-method'] as string | undefined) ?? 'GET'
      if (typeof target !== 'string') {
        response.statusCode = 400
        response.end('missing X-PDSH-Target-URL')
        return
      }
      const targetUrl = new URL(target)
      // The allow-list: loopback only, and only the two fixture repositories.
      const allowed = targetUrl.host === `127.0.0.1:${port}`
        && [...roots.keys()].some(name => targetUrl.pathname === `/${name}/info/refs` || targetUrl.pathname === `/${name}/git-upload-pack` || targetUrl.pathname === `/${name}/git-receive-pack`)
      if (!allowed) {
        response.statusCode = 403
        response.end('forbidden by the phone egress allow-list')
        return
      }
      const result = gitHttp(targetUrl, method, Buffer.concat(chunks), roots)
      if (result.contentType !== undefined) response.setHeader('Content-Type', result.contentType)
      response.statusCode = result.status
      response.end(result.body)
    })
  })
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => { resolve() })
  })
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  port = address.port
  return {
    origin: `http://127.0.0.1:${port}`,
    token,
    port,
    close: async () => {
      await new Promise<void>((resolve, reject) => server.close(error => error === undefined ? resolve() : reject(error)))
    },
  }
}

/** Environment that routes the Worker git through the host route. */
function routeEnvironment(base: Record<string, string>, route: HostRoute): Record<string, string> {
  return { ...base, PDSH_CHANNEL_ORIGIN: route.origin, PDSH_CHANNEL_TOKEN: route.token }
}

test('clone, fetch, pull and push speak smart HTTP through /v1/http', { skip }, async () => {
  const temp = tempDirectory()
  let route: HostRoute | undefined
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const origin = join(temp.path, 'origin')
    mkdirSync(origin)
    const git = (repository: string, args: readonly string[]): CommandResult => systemGit(args, repository, env)
    git(origin, ['init', '-q', '-b', 'main'])
    writeFileSync(join(origin, 'a.txt'), 'alpha\n')
    git(origin, ['add', '-A'])
    git(origin, ['commit', '-qm', 'base'])
    const bare = join(temp.path, 'bare.git')
    const bareClone = spawnSync('git', ['clone', '-q', '--bare', origin, bare], { encoding: 'utf8', env: { ...process.env, ...env } })
    assert.equal(bareClone.status, 0, bareClone.stderr)
    route = await startHostRoute(new Map([['origin.git', origin], ['bare.git', bare]]), 'test-token')
    const networkEnv = routeEnvironment(env, route)
    const remote = (name: string): string => `${route?.origin}/${name}`

    const work = join(temp.path, 'work')
    const clone = await workerGit(['clone', remote('origin.git'), work], temp.path, networkEnv)
    assert.equal(clone.code, 0, clone.stderr.toString())
    assert.match(clone.stderr.toString(), /Cloning into/)
    assert.equal(systemGit(['log', '--oneline'], work, env).stdout.toString().trim(), `${systemGit(['rev-parse', 'HEAD'], origin, env).stdout.toString().trim().slice(0, 7)} base`)
    assert.equal(systemGit(['status', '--porcelain'], work, env).stdout.toString(), '')
    assert.equal(systemGit(['fsck', '--strict'], work, env).code, 0)

    // A new upstream commit is fetched into the remote-tracking ref and pulled.
    writeFileSync(join(origin, 'c.txt'), 'gamma\n')
    git(origin, ['add', '-A'])
    git(origin, ['commit', '-qm', 'third'])
    const upstreamHead = systemGit(['rev-parse', 'HEAD'], origin, env).stdout.toString().trim()
    const fetch = await workerGit(['fetch', 'origin'], work, networkEnv)
    assert.equal(fetch.code, 0, fetch.stderr.toString())
    assert.equal(systemGit(['rev-parse', 'refs/remotes/origin/main'], work, env).stdout.toString().trim(), upstreamHead)
    const pull = await workerGit(['pull', 'origin'], work, networkEnv)
    assert.equal(pull.code, 0, pull.stderr.toString())
    assert.equal(existsSync(join(work, 'c.txt')), true)
    assert.equal(systemGit(['status', '--porcelain'], work, env).stdout.toString(), '')

    // Commit locally and push to the bare repository over receive-pack.
    git(work, ['remote', 'add', 'bare', remote('bare.git')])
    writeFileSync(join(work, 'b.txt'), 'beta\n')
    const add = await workerGit(['add', '-A'], work, env)
    assert.equal(add.code, 0, add.stderr.toString())
    const commit = await workerGit(['commit', '-m', 'second'], work, { ...env, GIT_AUTHOR_DATE: '1700000300 +0000', GIT_COMMITTER_DATE: '1700000300 +0000' })
    assert.equal(commit.code, 0, commit.stderr.toString())
    const push = await workerGit(['push', 'bare', 'main'], work, networkEnv)
    assert.equal(push.code, 0, push.stderr.toString())
    assert.match(push.stderr.toString(), /To http:\/\/127\.0\.0\.1:/)
    assert.equal(
      systemGit(['rev-parse', 'refs/heads/main'], bare, env).stdout.toString(),
      systemGit(['rev-parse', 'HEAD'], work, env).stdout.toString(),
    )
    assert.equal(systemGit(['fsck', '--strict'], bare, env).code, 0)
    assert.equal(systemGit(['show', 'main:b.txt'], bare, env).stdout.toString(), 'beta\n')
    assert.equal(systemGit(['show', 'main:c.txt'], bare, env).stdout.toString(), 'gamma\n')

    // A blocked origin is rejected by the host allow-list and nothing is written.
    const blocked = join(temp.path, 'blocked')
    const rejected = await workerGit(['clone', `${route.origin}/secret.git`, blocked], temp.path, networkEnv)
    assert.equal(rejected.code, 128)
    assert.match(rejected.stderr.toString(), /allow-list|403/)
    assert.equal(existsSync(join(blocked, '.git')), false)
    // Local file remotes are not a Worker path either.
    const localRemote = await workerGit(['clone', origin, join(temp.path, 'local')], temp.path, networkEnv)
    assert.equal(localRemote.code, 128)
    assert.match(localRemote.stderr.toString(), /only speaks http\(s\) smart HTTP/)
  } finally {
    if (route !== undefined) await route.close()
    temp.cleanup()
  }
})

test('remote porcelain: unimplemented options fail loud instead of faking success', { skip }, async () => {
  const temp = tempDirectory()
  let route: HostRoute | undefined
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const git = (repository: string, args: readonly string[]): CommandResult => systemGit(args, repository, env)
    const origin = join(temp.path, 'origin')
    mkdirSync(origin)
    git(origin, ['init', '-q', '-b', 'main'])
    writeFileSync(join(origin, 'a.txt'), 'alpha\n')
    git(origin, ['add', '-A'])
    git(origin, ['commit', '-qm', 'base'])
    const bare = join(temp.path, 'bare.git')
    const bareClone = spawnSync('git', ['clone', '-q', '--bare', origin, bare], { encoding: 'utf8', env: { ...process.env, ...env } })
    assert.equal(bareClone.status, 0, bareClone.stderr)
    route = await startHostRoute(new Map([['origin.git', origin], ['bare.git', bare]]), 'test-token')
    const networkEnv = routeEnvironment(env, route)
    const remote = (name: string): string => `${route?.origin}/${name}`
    const work = join(temp.path, 'work')
    const clone = await workerGit(['clone', remote('origin.git'), work], temp.path, networkEnv)
    assert.equal(clone.code, 0, clone.stderr.toString())
    git(work, ['remote', 'add', 'bare', remote('bare.git')])

    // `push -u` must not reach the remote and must not pretend the tracking
    // configuration was written: a false success would exit 0 with state that
    // does not match the request.
    writeFileSync(join(work, 'b.txt'), 'beta\n')
    assert.equal((await workerGit(['add', '-A'], work, env)).code, 0)
    const commit = await workerGit(['commit', '-m', 'second'], work, { ...env, GIT_AUTHOR_DATE: '1700000300 +0000', GIT_COMMITTER_DATE: '1700000300 +0000' })
    assert.equal(commit.code, 0, commit.stderr.toString())
    const remoteHead = git(bare, ['rev-parse', 'refs/heads/main']).stdout.toString().trim()
    // The clone already tracks origin/main; a rejected `push -u bare` must not
    // rewrite that to the bare remote.
    const trackingBefore = git(work, ['config', '--local', '--get', 'branch.main.remote']).stdout.toString()
    for (const option of ['-u', '--set-upstream']) {
      const result = await workerGit(['push', option, 'bare', 'main'], work, networkEnv)
      assert.equal(result.code, 129, `push ${option}: exit 129 (stderr ${JSON.stringify(result.stderr.toString())})`)
      assert.equal(result.stdout.byteLength, 0, `push ${option}: prints nothing on stdout`)
      assert.match(result.stderr.toString(), /unsupported push option/, `push ${option}: names the option`)
    }
    assert.equal(git(bare, ['rev-parse', 'refs/heads/main']).stdout.toString().trim(), remoteHead, 'a rejected push left the remote ref alone')
    assert.equal(git(work, ['config', '--local', '--get', 'branch.main.remote']).stdout.toString(), trackingBefore, 'a rejected push left the tracking config alone')

    // `fetch` options that change the result must not print "Already up to
    // date." and exit 0 as if the request had been carried out.
    for (const option of ['--prune', '--all', '--tags']) {
      const result = await workerGit(['fetch', option, 'origin'], work, networkEnv)
      assert.equal(result.code, 129, `fetch ${option}: exit 129 (stderr ${JSON.stringify(result.stderr.toString())})`)
      assert.equal(result.stdout.byteLength, 0, `fetch ${option}: prints nothing on stdout`)
      assert.match(result.stderr.toString(), /unsupported fetch option/, `fetch ${option}: names the option`)
    }

    // `clone` options that change which refs are fetched or the remote name
    // must not fall through to a full clone under the default name.
    for (const [option, args] of [
      ['--single-branch', ['clone', '--single-branch', remote('origin.git'), join(temp.path, 'single')]],
      ['--no-tags', ['clone', '--no-tags', remote('origin.git'), join(temp.path, 'no-tags')]],
      ['-o', ['clone', '-o', 'upstream', remote('origin.git'), join(temp.path, 'renamed')]],
      ['--origin', ['clone', '--origin', 'upstream', remote('origin.git'), join(temp.path, 'renamed-long')]],
    ] as const) {
      const result = await workerGit(args, temp.path, networkEnv)
      const target = args[args.length - 1] as string
      assert.equal(result.code, 129, `clone ${option}: exit 129 (stderr ${JSON.stringify(result.stderr.toString())})`)
      assert.equal(result.stdout.byteLength, 0, `clone ${option}: prints nothing on stdout`)
      assert.match(result.stderr.toString(), /unsupported clone option/, `clone ${option}: names the option`)
      assert.equal(existsSync(join(target, '.git')), false, `clone ${option}: creates nothing`)
    }
  } finally {
    if (route !== undefined) await route.close()
    temp.cleanup()
  }
})
