// SPDX-License-Identifier: MIT
/**
 * L1 behavior for the phone HTTP MCP manager. A real local Streamable HTTP MCP
 * server exercises the official `@deepseek-ai/dsh-mcp-client` mount path, the
 * ToolRuntime projection, `mcp.json` persistence, and the rejection rules.
 * Environment-header values are asserted absent from the file and from failure
 * messages; no test prints them.
 */
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, before, test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import * as mcpClient from '@deepseek-ai/dsh-mcp-client'
import * as phoneMcp from '../phone-mcp/src/index.ts'
import { canonicalMCPEndpoint } from '../phone-mcp/src/client/native.ts'
import { HOST_MANAGED_HEADER_VALUE, resolveHeaders, validateServerInput } from '../phone-mcp/src/schema.ts'
import type { PhoneMcpRemote } from '../phone-mcp/src/remote.ts'
import type { McpSnapshot } from '../phone-mcp/src/protocol.ts'
import { startMcpFixture } from './fixtures/phone-mcp-fixture.ts'
import type { McpFixture } from './fixtures/phone-mcp-fixture.ts'

const ENV_NAME = 'PHONE_MCP_TEST_TOKEN'

let fixture: McpFixture
let temporary: string
let ctx: Context
let service: PhoneMcpRemote
let file: string
let env: NodeJS.ProcessEnv

function snapshot(): McpSnapshot {
  return service.mcpList()
}

/** Render captured logger arguments, including Error messages that JSON would hide. */
function formatLogArgs(args: readonly unknown[]): string {
  return args.map(arg => {
    if (typeof arg === 'string') return arg
    if (arg instanceof Error) return `${arg.name}: ${arg.message}\n${arg.stack ?? ''}`
    try {
      return JSON.stringify(arg) ?? String(arg)
    } catch {
      return String(arg)
    }
  }).join(' ')
}

async function mountPlugin(target: string, environment: NodeJS.ProcessEnv): Promise<{ context: Context; remote: PhoneMcpRemote }> {
  const context = new Context()
  await context.plugin(SystemPrompt)
  await context.plugin(ToolRuntime)
  await context.plugin(phoneMcp, { file: target, env: environment })
  const remote = context.get('phoneMcpRemote') as PhoneMcpRemote | undefined
  assert.ok(remote !== undefined, 'the phone/mcp Remote service must be registered')
  return { context, remote }
}

before(async () => {
  fixture = await startMcpFixture()
  temporary = mkdtempSync(join(tmpdir(), 'pdsh-phone-mcp-'))
  file = join(temporary, 'home', 'mcp.json')
  env = { [ENV_NAME]: `Bearer ${fixture.token}` }
  const mounted = await mountPlugin(file, env)
  ctx = mounted.context
  service = mounted.remote
})

after(async () => {
  await ctx?.fiber.dispose().catch(() => {})
  await fixture?.close().catch(() => {})
  if (temporary !== undefined) rmSync(temporary, { recursive: true, force: true })
})

test('phone-mcp: add, list, real tool result, reconnect, remove', { timeout: 30_000 }, async () => {
  const added = await service.mcpUpsert({
    serverName: 'local',
    url: fixture.url,
    headersFromEnv: { Authorization: ENV_NAME },
    enabled: true,
    toolCallTimeoutMs: 5_000,
  })
  assert.equal(added.serverName, 'local')
  assert.equal(added.status, 'connected')
  assert.equal(added.authentication, 'headers-env')
  assert.deepEqual(added.tools, ['mcp__local__echo', 'mcp__local__ping'])

  const generic = await service.mcp({ action: 'list' }) as McpSnapshot
  assert.equal(generic.servers[0]?.status, 'connected')

  const listed = snapshot()
  assert.equal(listed.servers.length, 1)
  assert.equal(listed.servers[0]?.status, 'connected')
  assert.deepEqual(listed.servers[0]?.tools, ['mcp__local__echo', 'mcp__local__ping'])
  assert.equal(listed.servers[0]?.headersFromEnv.Authorization, ENV_NAME)

  // The MCP tools are real ToolRuntime registrations: call one and observe the
  // server's actual JSON-RPC result.
  const result = await ctx.tools.execute({
    callId: ToolCallId('phone-mcp-echo'),
    name: 'mcp__local__echo',
    arguments: { message: 'from-test' },
    signal: new AbortController().signal,
  })
  assert.equal(result.isError, false)
  assert.match(JSON.stringify(result.content), /echo:from-test/)
  assert.ok(fixture.calls.some(call => call.name === 'echo' && call.arguments.message === 'from-test'))

  const reconnected = await service.mcpReconnect({ serverName: 'local' })
  assert.equal(reconnected.status, 'connected')
  assert.deepEqual(reconnected.tools, ['mcp__local__echo', 'mcp__local__ping'])

  const removed = await service.mcpRemove({ serverName: 'local' })
  assert.deepEqual(removed, { serverName: 'local', removed: true })
  assert.deepEqual(snapshot().servers, [])
  assert.equal(ctx.tools.schemas().some(tool => tool.name.startsWith('mcp__local__')), false)

  const persisted = JSON.parse(readFileSync(file, 'utf8')) as { version: number; servers: unknown[] }
  assert.equal(persisted.version, 1)
  assert.deepEqual(persisted.servers, [])
  assert.deepEqual(readdirSync(join(temporary, 'home')).filter(name => name.endsWith('.tmp')), [])

  // Persisted bytes never contain the resolved environment value.
  const bytes = readFileSync(file, 'utf8')
  assert.equal(bytes.includes(fixture.token), false)
  assert.equal(bytes.includes('Authorization'), false, 'the header value map is gone with the row')
})

test('phone-mcp: concurrent upserts commit one complete registry and stay removable', { timeout: 30_000 }, async () => {
  const mirrorFile = join(temporary, 'concurrent', 'mcp.json')
  const mounted = await mountPlugin(mirrorFile, env)
  try {
    const [alpha, beta] = await Promise.all([
      mounted.remote.mcpUpsert({ serverName: 'alpha', url: fixture.url, headersFromEnv: { Authorization: ENV_NAME }, toolCallTimeoutMs: 5_000 }),
      mounted.remote.mcpUpsert({ serverName: 'beta', url: fixture.url, headersFromEnv: { Authorization: ENV_NAME }, toolCallTimeoutMs: 5_000 }),
    ])
    assert.equal(alpha.status, 'connected')
    assert.equal(beta.status, 'connected')

    const listed = mounted.remote.mcpList()
    assert.deepEqual(listed.servers.map(server => server.serverName), ['alpha', 'beta'])
    assert.deepEqual(listed.servers[0]?.tools, ['mcp__alpha__echo', 'mcp__alpha__ping'])
    assert.deepEqual(listed.servers[1]?.tools, ['mcp__beta__echo', 'mcp__beta__ping'])
    assert.equal(
      mounted.context.tools.schemas().filter(schema => schema.name.startsWith('mcp__beta__')).length,
      2,
      'the second concurrent add must keep its real ToolRuntime registrations',
    )

    const persisted = JSON.parse(readFileSync(mirrorFile, 'utf8')) as {
      version: number
      servers: { serverName: string; toolCallTimeoutMs: number }[]
    }
    assert.deepEqual(persisted.servers.map(server => server.serverName), ['alpha', 'beta'])
    assert.equal(new Set(persisted.servers.map(server => server.serverName)).size, persisted.servers.length)
    assert.equal(readFileSync(mirrorFile, 'utf8').includes(fixture.token), false)

    // The row that used to be lost is visible to the UI and therefore removable.
    await mounted.remote.mcpRemove({ serverName: 'beta' })
    assert.deepEqual(mounted.remote.mcpList().servers.map(server => server.serverName), ['alpha'])
    assert.equal(mounted.context.tools.schemas().some(schema => schema.name.startsWith('mcp__beta__')), false)

    // Same-name writers are serialized too: one row remains, with the last
    // committed configuration, and the file never contains a duplicate.
    await Promise.all([
      mounted.remote.mcpUpsert({ serverName: 'same', url: fixture.url, headersFromEnv: { Authorization: ENV_NAME }, toolCallTimeoutMs: 5_000 }),
      mounted.remote.mcpUpsert({ serverName: 'same', url: fixture.url, headersFromEnv: { Authorization: ENV_NAME }, toolCallTimeoutMs: 9_000 }),
    ])
    const same = mounted.remote.mcpList().servers.filter(server => server.serverName === 'same')
    assert.equal(same.length, 1)
    assert.equal(same[0]?.status, 'connected')
    assert.equal(same[0]?.toolCallTimeoutMs, 9_000)

    // Different operations share the same queue: the remove and the new add
    // both reach the file and the live mount map.
    await Promise.all([
      mounted.remote.mcpUpsert({ serverName: 'gamma', url: fixture.url, headersFromEnv: { Authorization: ENV_NAME }, toolCallTimeoutMs: 5_000 }),
      mounted.remote.mcpRemove({ serverName: 'alpha' }),
    ])
    assert.deepEqual(mounted.remote.mcpList().servers.map(server => server.serverName), ['gamma', 'same'])
    const finalFile = JSON.parse(readFileSync(mirrorFile, 'utf8')) as { servers: { serverName: string }[] }
    assert.deepEqual(finalFile.servers.map(server => server.serverName), ['gamma', 'same'])
    assert.deepEqual(
      mounted.remote.mcpList().servers.find(server => server.serverName === 'gamma')?.tools,
      ['mcp__gamma__echo', 'mcp__gamma__ping'],
    )
  } finally {
    await mounted.context.fiber.dispose()
  }
})

test('phone-mcp: a failed file commit unmounts the newly connected server', { timeout: 30_000 }, async () => {
  const blocker = join(temporary, 'blocked')
  writeFileSync(blocker, 'not a directory')
  const blockedFile = join(blocker, 'mcp.json')
  const mounted = await mountPlugin(blockedFile, env)
  try {
    assert.match(mounted.remote.mcpList().error ?? '', /cannot read/)
    await assert.rejects(
      mounted.remote.mcpUpsert({ serverName: 'unwritable', url: fixture.url, headersFromEnv: { Authorization: ENV_NAME } }),
      /cannot write/,
    )
    assert.deepEqual(mounted.remote.mcpList().servers, [])
    assert.equal(
      mounted.context.tools.schemas().some(schema => schema.name.startsWith('mcp__unwritable__')),
      false,
      'a mount that never reached the file must not stay in ToolRuntime',
    )
  } finally {
    await mounted.context.fiber.dispose()
  }
})

test('phone-mcp: invalid URL, duplicate serverName, and missing env are refused without writes', { timeout: 30_000 }, async () => {
  const before = readFileSync(file, 'utf8').includes('local')

  await assert.rejects(
    service.mcpUpsert({ serverName: 'ftp', url: 'ftp://127.0.0.1:9/mcp' }),
    /url must use http: or https:/,
  )
  await assert.rejects(
    service.mcpUpsert({ serverName: 'creds', url: 'http://user:pass@127.0.0.1:9/mcp' }),
    /must not embed credentials/,
  )
  await assert.rejects(
    service.mcpUpsert({ serverName: 'stdio', url: fixture.url, transport: 'stdio' } as never),
    /transport is not a supported field/,
  )
  await assert.rejects(
    service.mcpUpsert({ serverName: 'missing-env', url: fixture.url, headersFromEnv: { Authorization: 'PHONE_MCP_ABSENT_TOKEN' } }),
    /environment variable PHONE_MCP_ABSENT_TOKEN is not set/,
  )
  await assert.rejects(
    service.mcpUpsert({ serverName: 'bad-env-name', url: fixture.url, headersFromEnv: { Authorization: 'Bearer literal' } }),
    /must name an environment variable/,
  )
  await assert.rejects(
    service.mcpUpsert({ serverName: 'bad name', url: fixture.url }),
    /serverName must match/,
  )
  await assert.rejects(
    service.mcpUpsert({ serverName: 'bad-timeout', url: fixture.url, toolCallTimeoutMs: 0 }),
    /toolCallTimeoutMs/,
  )

  // A live mcp-client already owns this namespace: the official reservation
  // rejects our dynamic mount, and no row is written.
  const official = ctx.plugin({ name: 'mcp-client', inject: mcpClient.inject, apply: mcpClient.apply }, {
    transport: 'streamable-http',
    serverName: 'already-mounted',
    url: fixture.url,
    headers: { Authorization: `Bearer ${fixture.token}` },
    toolCallTimeoutMs: 5_000,
    failOnStartupError: true,
  })
  await official
  try {
    await assert.rejects(
      service.mcpUpsert({ serverName: 'already-mounted', url: fixture.url }),
      /already in use/,
    )
  } finally {
    await official.dispose()
  }

  assert.deepEqual(snapshot().servers, [], 'refused operations must not persist a row')
  assert.equal(readFileSync(file, 'utf8').includes('missing-env'), false)
  assert.equal(readFileSync(file, 'utf8').includes(fixture.token), false)
  assert.equal(before, false)
})

test('phone-mcp: host-managed headers carry only a placeholder and never the device value', { timeout: 30_000 }, async () => {
  const anonymous = await startMcpFixture({ allowAnonymous: true })
  try {
    const parsed = validateServerInput({
      serverName: 'device-key',
      url: anonymous.url,
      headersFromEnv: { Authorization: 'PHONE_MCP_DEVICE_ONLY' },
      hostManagedHeaders: ['Authorization'],
      toolCallTimeoutMs: 5_000,
    })
    assert.deepEqual(resolveHeaders(parsed, {}), { Authorization: HOST_MANAGED_HEADER_VALUE })

    const added = await service.mcpUpsert({
      serverName: 'device-key',
      url: anonymous.url,
      headersFromEnv: { Authorization: 'PHONE_MCP_DEVICE_ONLY' },
      hostManagedHeaders: ['Authorization'],
      toolCallTimeoutMs: 5_000,
    })
    assert.equal(added.status, 'connected')
    assert.deepEqual(added.hostManagedHeaders, ['Authorization'])
    assert.equal(added.authentication, 'host-managed',
      'the UI must be told that the device injects this value, not that it comes from the Worker environment')
    assert.equal(anonymous.requests.length > 0, true)
    assert.equal(
      anonymous.requests.every(request => request.headers.authorization === HOST_MANAGED_HEADER_VALUE),
      true,
      'the Worker must send only the documented placeholder, never an environment value',
    )
    const bytes = readFileSync(file, 'utf8')
    assert.equal(bytes.includes(HOST_MANAGED_HEADER_VALUE), false)
    assert.equal(bytes.includes('"hostManagedHeaders"'), true)
    assert.equal(bytes.includes('PHONE_MCP_DEVICE_ONLY'), true, 'the non-secret env name remains the UI hint')
    await service.mcpRemove({ serverName: 'device-key' })
  } finally {
    await anonymous.close()
  }
})

test('phone-mcp: a host-managed error withholds an upstream body that could echo the injected header', { timeout: 30_000 }, async () => {
  const echo = await startMcpFixture({ reject: { status: 403, authorization: HOST_MANAGED_HEADER_VALUE } })
  const echoFile = join(temporary, 'host-managed-echo', 'mcp.json')
  mkdirSync(join(temporary, 'host-managed-echo'), { recursive: true })
  writeFileSync(echoFile, `${JSON.stringify({
    version: 1,
    servers: [{
      serverName: 'echo-host-key',
      url: echo.url,
      headersFromEnv: { Authorization: 'PHONE_MCP_DEVICE_ONLY' },
      hostManagedHeaders: ['Authorization'],
      enabled: true,
      toolCallTimeoutMs: 1_000,
    }],
  }, null, 2)}\n`)
  const mounted = await mountPlugin(echoFile, {})
  try {
    const row = mounted.remote.mcpList().servers[0]
    assert.equal(row?.serverName, 'echo-host-key')
    assert.equal(row?.status, 'error')
    assert.match(row?.error ?? '', /response detail withheld/)
    assert.equal((row?.error ?? '').includes('rejected:'), false,
      'the host-managed value is not known to the Worker, so the raw body must not be copied')
    assert.equal((row?.error ?? '').includes(HOST_MANAGED_HEADER_VALUE), false)
  } finally {
    await mounted.context.fiber.dispose()
    await echo.close()
  }
})

test('phone-mcp: overlapping serverName prefixes report only their own mount tools', { timeout: 30_000 }, async () => {
  // `a` is both a complete serverName and the prefix of `mcp__a__b__*`.
  const addedA = await service.mcpUpsert({
    serverName: 'a',
    url: fixture.url,
    headersFromEnv: { Authorization: ENV_NAME },
    toolCallTimeoutMs: 5_000,
  })
  assert.equal(addedA.status, 'connected')
  assert.deepEqual(addedA.tools, ['mcp__a__echo', 'mcp__a__ping'])

  const addedAB = await service.mcpUpsert({
    serverName: 'a__b',
    url: fixture.url,
    headersFromEnv: { Authorization: ENV_NAME },
    toolCallTimeoutMs: 5_000,
  })
  assert.equal(addedAB.status, 'connected')
  assert.deepEqual(addedAB.tools, ['mcp__a__b__echo', 'mcp__a__b__ping'])

  const listed = snapshot()
  const byName = new Map(listed.servers.map(server => [server.serverName, server]))
  assert.deepEqual(byName.get('a')?.tools, ['mcp__a__echo', 'mcp__a__ping'])
  assert.deepEqual(byName.get('a__b')?.tools, ['mcp__a__b__echo', 'mcp__a__b__ping'])

  // Removing the shorter-named row must not remove or reattribute the longer
  // mount's tools, and the remaining row keeps its own exact set.
  await service.mcpRemove({ serverName: 'a' })
  const remaining = snapshot()
  assert.deepEqual(remaining.servers.map(server => server.serverName), ['a__b'])
  assert.deepEqual(remaining.servers[0]?.tools, ['mcp__a__b__echo', 'mcp__a__b__ping'])
  const globalNames = new Set(ctx.tools.schemas().map(schema => schema.name))
  assert.equal(globalNames.has('mcp__a__echo'), false)
  assert.equal(globalNames.has('mcp__a__ping'), false)
  assert.equal(globalNames.has('mcp__a__b__echo'), true)
  assert.equal(globalNames.has('mcp__a__b__ping'), true)

  // Removing the longer row leaves no MCP rows or tool registrations behind.
  await service.mcpRemove({ serverName: 'a__b' })
  assert.deepEqual(snapshot().servers, [])
  assert.equal(ctx.tools.schemas().some(schema => schema.name.startsWith('mcp__')), false)
})

test('phone-mcp: startup mounts enabled rows only and reports real connection errors', { timeout: 30_000 }, async () => {
  const startFile = join(temporary, 'startup', 'mcp.json')
  mkdirSync(join(temporary, 'startup'), { recursive: true })
  writeFileSync(startFile, `${JSON.stringify({
    version: 1,
    servers: [
      { serverName: 'enabled', url: fixture.url, headersFromEnv: { Authorization: ENV_NAME }, enabled: true, toolCallTimeoutMs: 5_000 },
      { serverName: 'disabled', url: 'http://127.0.0.1:1/mcp', headersFromEnv: {}, enabled: false, toolCallTimeoutMs: 5_000 },
      { serverName: 'unreachable', url: 'http://127.0.0.1:1/mcp', headersFromEnv: {}, enabled: true, toolCallTimeoutMs: 1_000 },
      { serverName: 'missing-env-startup', url: fixture.url, headersFromEnv: { Authorization: 'PHONE_MCP_ABSENT_TOKEN' }, enabled: true, toolCallTimeoutMs: 1_000 },
    ],
  }, null, 2)}\n`)

  const mounted = await mountPlugin(startFile, env)
  try {
    const listed = mounted.remote.mcpList()
    const byName = new Map(listed.servers.map(server => [server.serverName, server]))
    assert.equal(byName.get('enabled')?.status, 'connected')
    assert.deepEqual(byName.get('enabled')?.tools, ['mcp__enabled__echo', 'mcp__enabled__ping'])
    assert.equal(byName.get('disabled')?.status, 'disabled')
    assert.deepEqual(byName.get('disabled')?.tools, [])
    assert.equal(byName.get('unreachable')?.status, 'error')
    assert.match(byName.get('unreachable')?.error ?? '', /failed to connect/)
    assert.equal(byName.get('missing-env-startup')?.status, 'error')
    assert.match(byName.get('missing-env-startup')?.error ?? '', /PHONE_MCP_ABSENT_TOKEN is not set/)
    assert.deepEqual(byName.get('missing-env-startup')?.tools, [])
    assert.equal(byName.get('missing-env-startup')?.authentication, 'headers-env')
    assert.equal(byName.get('disabled')?.authentication, 'none')
    assert.equal(JSON.stringify(listed).includes(fixture.token), false)
  } finally {
    await mounted.context.fiber.dispose()
  }
})

test('phone-mcp: a corrupt mcp.json is reported and a valid upsert repairs it', { timeout: 30_000 }, async () => {
  const brokenFile = join(temporary, 'broken', 'mcp.json')
  mkdirSync(join(temporary, 'broken'), { recursive: true })
  writeFileSync(brokenFile, '{ not json')
  const mounted = await mountPlugin(brokenFile, env)
  try {
    const broken = mounted.remote.mcpList()
    assert.deepEqual(broken.servers, [])
    assert.match(broken.error ?? '', /not valid JSON/)

    const repaired = await mounted.remote.mcpUpsert({ serverName: 'repaired', url: fixture.url, headersFromEnv: { Authorization: ENV_NAME } })
    assert.equal(repaired.status, 'connected')
    const listed = mounted.remote.mcpList()
    assert.equal(listed.error, undefined)
    assert.equal(listed.servers[0]?.serverName, 'repaired')
    assert.equal(listed.servers[0]?.authentication, 'headers-env')
  } finally {
    await mounted.context.fiber.dispose()
  }
})

test('phone-mcp: a non-2xx body echoing Authorization stays out of snapshot and file errors', { timeout: 30_000 }, async () => {
  const rejecting = await startMcpFixture({ reject: { status: 403 } })
  const leakedSecret = `Bearer synthetic-${randomBytes(18).toString('hex')}`
  const startFile = join(temporary, 'leak-start', 'mcp.json')
  mkdirSync(join(temporary, 'leak-start'), { recursive: true })
  writeFileSync(startFile, `${JSON.stringify({
    version: 1,
    servers: [{
      serverName: 'leaky',
      url: rejecting.url,
      headersFromEnv: { Authorization: ENV_NAME },
      enabled: true,
      toolCallTimeoutMs: 1_000,
    }],
  }, null, 2)}\n`)
  const mounted = await mountPlugin(startFile, { [ENV_NAME]: leakedSecret })
  try {
    const listed = mounted.remote.mcpList()
    const row = listed.servers[0]
    assert.equal(row?.serverName, 'leaky')
    assert.equal(row?.status, 'error')
    assert.deepEqual(row?.tools, [])
    assert.match(row?.error ?? '', /failed to connect/)
    assert.match(row?.error ?? '', /\[redacted\]/, 'the echoed authorization body is kept only as a redacted detail')
    assert.equal((row?.error ?? '').includes(leakedSecret), false)
    assert.equal(JSON.stringify(listed).includes(leakedSecret), false)
    assert.equal(readFileSync(startFile, 'utf8').includes(leakedSecret), false)
    // A failed startup mount is still a repair path: the row stays visible and removable.
    await mounted.remote.mcpRemove({ serverName: 'leaky' })
    assert.deepEqual(mounted.remote.mcpList().servers, [])
  } finally {
    await mounted.context.fiber.dispose()
    await rejecting.close()
  }
})

test('phone-mcp: official client reconnect logs and thrown errors redact an echoed Authorization header', { timeout: 30_000 }, async () => {
  const leakedSecret = `Bearer synthetic-${randomBytes(18).toString('hex')}`
  const rotating = await startMcpFixture({ reject: { status: 403, authorization: leakedSecret } })
  const rotateFile = join(temporary, 'leak-reconnect', 'mcp.json')
  mkdirSync(join(temporary, 'leak-reconnect'), { recursive: true })
  writeFileSync(rotateFile, `${JSON.stringify({
    version: 1,
    servers: [{
      serverName: 'rotated',
      url: rotating.url,
      headersFromEnv: { Authorization: ENV_NAME },
      enabled: true,
      toolCallTimeoutMs: 1_000,
    }],
  }, null, 2)}\n`)
  const rotateEnv: NodeJS.ProcessEnv = { [ENV_NAME]: `Bearer ${rotating.token}` }
  const mounted = await mountPlugin(rotateFile, rotateEnv)
  const records: unknown[][] = []
  const stopLogs = mounted.context.logger.exporter({
    levels: { default: 3 },
    export(message) { records.push(message.args) },
  })
  try {
    const connected = mounted.remote.mcpList().servers[0]
    assert.equal(connected?.status, 'connected')
    assert.deepEqual(connected?.tools, ['mcp__rotated__echo', 'mcp__rotated__ping'])

    rotateEnv[ENV_NAME] = leakedSecret
    let failure: unknown
    try {
      await mounted.remote.mcpReconnect({ serverName: 'rotated' })
    } catch (error) {
      failure = error
    }
    assert.ok(failure instanceof Error, 'a failed reconnect must not be reported as success')
    assert.equal(failure.message.includes(leakedSecret), false)
    assert.match(failure.message, /failed to reconnect|Error POSTing/)
    assert.equal((failure as { cause?: unknown }).cause, undefined, 'the raw transport cause must not be retained')

    // The official client logs its connection attempt before this manager's
    // catch. Both the client warning and the manager row error must be safe.
    const logs = records.map(formatLogArgs).join('\n')
    assert.equal(logs.includes(leakedSecret), false)
    assert.match(logs, /connection attempt failed|failed to reconnect/)
    assert.match(logs, /\[redacted\]/)

    const listed = mounted.remote.mcpList()
    const failed = listed.servers[0]
    assert.equal(failed?.status, 'error')
    assert.equal((failed?.error ?? '').includes(leakedSecret), false)
    assert.equal(JSON.stringify(listed).includes(leakedSecret), false)
    assert.equal(readFileSync(rotateFile, 'utf8').includes(leakedSecret), false)

    // Reconnecting with the valid environment value still recovers the real tools.
    rotateEnv[ENV_NAME] = `Bearer ${rotating.token}`
    const recovered = await mounted.remote.mcpReconnect({ serverName: 'rotated' })
    assert.equal(recovered.status, 'connected')
    assert.deepEqual(recovered.tools, ['mcp__rotated__echo', 'mcp__rotated__ping'])
  } finally {
    await stopLogs()
    await mounted.context.fiber.dispose()
    await rotating.close()
  }
})

test('phone-mcp: client canonical endpoint matches slash/default-port/fragment rules', () => {
  assert.equal(
    canonicalMCPEndpoint('https://MCP.example.com:443/mcp/'),
    canonicalMCPEndpoint('https://mcp.example.com/mcp#fragment'),
    'host case, trailing slash, explicit default port and fragment do not change the endpoint',
  )
  assert.equal(
    canonicalMCPEndpoint('https://mcp.example.com/mcp?x=1'),
    canonicalMCPEndpoint('https://mcp.example.com:443/mcp/?x=1#ignored'),
  )
  assert.notEqual(
    canonicalMCPEndpoint('https://mcp.example.com/mcp?x=1'),
    canonicalMCPEndpoint('https://mcp.example.com/mcp?x=2'),
    'the actual query participates in endpoint identity',
  )
  assert.notEqual(
    canonicalMCPEndpoint('https://mcp.example.com/mcp'),
    canonicalMCPEndpoint('http://mcp.example.com/mcp'),
  )
  assert.equal(canonicalMCPEndpoint('ftp://mcp.example.com/mcp'), undefined)
})
