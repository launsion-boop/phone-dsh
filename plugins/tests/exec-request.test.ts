// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { PathMapper } from '../exec-bridge/src/paths.ts'
import type { Hello } from '../exec-bridge/src/client.ts'
import { toolCallStorage } from '../exec-bridge/src/call-context.ts'
import { CONFINE_MARKER, buildExecRequest, nextExecId } from '../subprocess-xl/src/index.ts'

const hello = (confine: Hello['capabilities']['confine'] = []): Hello => ({
  protocol: 'pdsh-exec-bridge/1',
  provider: { name: 'test' },
  guest: { platform: 'posix', mounts: [{ host_path: '/app/ws', guest_path: '/var/minis/workspace' }] },
  capabilities: { exec: true, stdin_pipe: false, confine },
  limits: {},
})
const bridge = { paths: new PathMapper(hello().guest.mounts), hello: hello(['workspace-write']) }
const collect = { maxBytes: 1024 }

test('cwd is mapped host to guest; env tombstones become null; stdin data is base64', () => {
  const request = buildExecRequest(bridge as never, {
    argv: ['bash', '-c', 'ls'], cwd: '/app/ws/src', graceMs: 3000,
    stdio: { stdin: { data: 'héllo' }, stdout: collect, stderr: collect },
    env: { TERM: 'dumb', LANG: undefined },
  }, 'xl-1')
  assert.equal(request.cwd, '/var/minis/workspace/src')
  assert.deepEqual(request.env, { TERM: 'dumb', LANG: null })
  assert.deepEqual(request.stdin, { mode: 'data', data: Buffer.from('héllo').toString('base64') })
  assert.equal(request.grace_ms, 3000)
  assert.equal(request.confine, undefined)
})

test('the confinement marker becomes the request\'s confine field', () => {
  const request = buildExecRequest(bridge as never, {
    argv: [CONFINE_MARKER, 'workspace-write', '/app/ws', '--', 'bash', '-c', 'make'], cwd: '/app/ws', graceMs: 1000,
    stdio: { stdin: 'ignore', stdout: collect, stderr: collect },
  }, 'xl-2')
  assert.deepEqual(request.argv, ['bash', '-c', 'make'])
  assert.deepEqual(request.confine, { mode: 'workspace-write', workspace_root: '/var/minis/workspace' })
})

test('piped stdin needs the capability; a guest path inside a mount passes through', () => {
  assert.throws(() => buildExecRequest(bridge as never, {
    argv: ['cat'], cwd: '/app/ws', graceMs: 1000, stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' },
  }, 'xl-3'), /piped stdin/)
  const request = buildExecRequest(bridge as never, {
    argv: ['pwd'], cwd: '/var/minis/workspace/x', graceMs: 1000, stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' },
  }, 'xl-4')
  assert.equal(request.cwd, '/var/minis/workspace/x')
})

test('exec ids are deterministic per tool call and spawn ordinal; random outside calls', () => {
  const ids = toolCallStorage().run({ sessionId: 's', callId: 'c', key: 'xl1-k', spawns: 0 }, () => [nextExecId(), nextExecId()])
  assert.deepEqual(ids, ['xl1-k-0', 'xl1-k-1'])
  assert.match(nextExecId(), /^xl-[0-9a-f-]{36}$/)
  const request = toolCallStorage().run({ sessionId: 's', callId: 'c', key: 'xl1-k', spawns: 0 }, () => buildExecRequest(bridge as never, {
    argv: ['true'], cwd: '/app/ws', graceMs: 1000, stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' },
  }, 'xl1-k-0'))
  assert.equal(request.env?.XL_IDEMPOTENCY_KEY, 'xl1-k')
})
