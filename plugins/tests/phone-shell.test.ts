// SPDX-License-Identifier: MIT
// PHONE-SHELL: the command console runs real Worker bash and real advertised
// accelerator argv through subprocess-xl; it never allocates a PTY.
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import type { ChildProcess } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import type { SubprocessRuntime } from '@deepseek-ai/dsh-subprocess'
import { remoteMethods } from '@deepseek-ai/dsh-typert-protocol'
import { FrameType } from '../channel/src/index.ts'
import { XlExecBridge } from '../exec-bridge/src/index.ts'
import type { ExecTransportKind } from '../exec-bridge/src/index.ts'
import { XlSubprocessRuntime } from '../subprocess-xl/src/index.ts'
import { createPhoneShellClient } from '../phone-shell/src/client/remote.ts'
import { PHONE_SHELL_ENDPOINTS } from '../phone-shell/src/contract.ts'
import { capsFromHello, normalizeConsoleRequest, PhoneShellRemote } from '../phone-shell/src/service.ts'
import { MockChannel, eventually, jsonPayload } from './test-channel.ts'

const roots: string[] = []

interface Harness {
  readonly ctx: Context
  readonly mock: MockChannel
  readonly service: PhoneShellRemote
  readonly subprocess: SubprocessRuntime
  readonly root: string
  /** Replace the Host VFS root for the provider's next `bash -c`. */
  dispose(): Promise<void>
}

function vfsRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-phone-shell-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  mkdirSync(join(root, 'dsh/home'), { recursive: true })
  return root
}

async function harness(options: { caps?: readonly string[]; shellOutputBytes?: number } = {}): Promise<Harness> {
  const root = vfsRoot()
  const previousRoot = process.env.PDSH_VFS_ROOT
  const previousShell = process.env.PDSH_SHELL
  const previousOutput = process.env.PDSH_SHELL_MAX_OUTPUT_BYTES
  process.env.PDSH_VFS_ROOT = root
  process.env.PDSH_SHELL = 'just-bash'
  if (options.shellOutputBytes === undefined) delete process.env.PDSH_SHELL_MAX_OUTPUT_BYTES
  else process.env.PDSH_SHELL_MAX_OUTPUT_BYTES = String(options.shellOutputBytes)
  const mock = new MockChannel({ caps: options.caps ?? [], nextMseq: 1n, ackedMseq: 0n })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  try {
    await ctx.plugin(XlExecBridge, {
      transport: 'channel',
      tokenEnv: 'PDSH_PHONE_SHELL_UNUSED_TOKEN',
      tokenFileEnv: 'PDSH_PHONE_SHELL_UNUSED_TOKEN_FILE',
      connectTimeoutMs: 1_000,
    })
    await ctx.plugin(XlSubprocessRuntime)
    await ctx.plugin(PhoneShellRemote)
    return {
      ctx,
      mock,
      service: ctx.get('phoneShell') as PhoneShellRemote,
      subprocess: ctx.get('subprocess') as SubprocessRuntime,
      root,
      async dispose() {
        await ctx.fiber.dispose()
        delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
        if (previousRoot === undefined) delete process.env.PDSH_VFS_ROOT
        else process.env.PDSH_VFS_ROOT = previousRoot
        if (previousShell === undefined) delete process.env.PDSH_SHELL
        else process.env.PDSH_SHELL = previousShell
        if (previousOutput === undefined) delete process.env.PDSH_SHELL_MAX_OUTPUT_BYTES
        else process.env.PDSH_SHELL_MAX_OUTPUT_BYTES = previousOutput
      },
    }
  } catch (error) {
    delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
    if (previousRoot === undefined) delete process.env.PDSH_VFS_ROOT
    else process.env.PDSH_VFS_ROOT = previousRoot
    if (previousShell === undefined) delete process.env.PDSH_SHELL
    else process.env.PDSH_SHELL = previousShell
    if (previousOutput === undefined) delete process.env.PDSH_SHELL_MAX_OUTPUT_BYTES
    else process.env.PDSH_SHELL_MAX_OUTPUT_BYTES = previousOutput
    await ctx.fiber.dispose().catch(() => {})
    throw error
  }
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** Wait for the Host EXEC_REQ with this argv and return its exec id. */
async function waitHostRun(mock: MockChannel, argv: readonly string[]): Promise<string> {
  await eventually(() => mock.framesOf(FrameType.EXEC_REQ).some((frame) => {
    const body = jsonPayload(frame)
    return JSON.stringify(body['argv']) === JSON.stringify(argv)
  }))
  const frame = mock.framesOf(FrameType.EXEC_REQ).find((candidate) => {
    const body = jsonPayload(candidate)
    return JSON.stringify(body['argv']) === JSON.stringify(argv)
  })
  assert.notEqual(frame, undefined)
  return jsonPayload(frame!)['exec_id'] as string
}

/** Complete one Host EXEC_REQ event stream after its argv frame was observed. */
async function answerHostRun(
  mock: MockChannel,
  argv: readonly string[],
  stdout: string,
  stderr = '',
  exitCode = 0,
): Promise<string> {
  const execId = await waitHostRun(mock, argv)
  mock.execEvent({ type: 'start', exec_id: execId, seq: 0, pid: 7 })
  let seq = 1
  if (stdout !== '') {
    mock.execEvent({ type: 'output', exec_id: execId, seq: seq++, stream: 'stdout', data: Buffer.from(stdout).toString('base64') })
  }
  if (stderr !== '') {
    mock.execEvent({ type: 'output', exec_id: execId, seq: seq++, stream: 'stderr', data: Buffer.from(stderr).toString('base64') })
  }
  mock.execEvent({ type: 'exit', exec_id: execId, seq, code: exitCode, signal: null, status: 'exited', quiescent: true })
  return execId
}

interface SimHarness {
  readonly sim: ChildProcess
  readonly url: string
  readonly token: string
}

/** Start the reference exec-bridge sim and wait for its ready line. */
async function startSim(hostRoot: string, guestRoot: string): Promise<SimHarness> {
  const tokenFile = join(hostRoot, 'token')
  const sim = spawn(process.execPath, [
    fileURLToPath(new URL('../sim/exec-bridge-sim.mjs', import.meta.url)),
    '--workspace', hostRoot,
    '--guest-root', guestRoot,
    '--token-file', tokenFile,
  ], { stdio: ['ignore', 'pipe', 'ignore'] })
  try {
    const ready = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => { reject(new Error('sim did not start')) }, 5_000)
      sim.stdout?.once('data', (chunk: Buffer) => {
        clearTimeout(timer)
        resolve(chunk.toString())
      })
      sim.once('error', reject)
    })
    return { sim, url: (JSON.parse(ready) as { url: string }).url, token: readFileSync(tokenFile, 'utf8').trim() }
  } catch (error) {
    sim.kill('SIGTERM')
    throw error
  }
}

/** Stop the sim and wait for its process to leave. */
async function stopSim(sim: ChildProcess): Promise<void> {
  await new Promise<void>((resolve) => {
    sim.once('exit', () => { resolve() })
    if (sim.exitCode !== null) resolve()
    else sim.kill('SIGTERM')
  })
}

test('caps comes from the live hello and printf writes the real Worker VFS', async () => {
  const h = await harness({ caps: ['accelerator:rg', 'accelerator:jq'] })
  try {
    assert.equal(h.service.typertRemote.namespace, 'phone')
    assert.deepEqual(
      remoteMethods(h.service).map(marker => [marker.method, marker.exportName]).sort(),
      [['cancel', 'shellCancel'], ['caps', 'shellCaps'], ['run', 'shellRun']],
    )
    const caps = h.service.caps()
    assert.equal(caps.linked, true)
    assert.equal(caps.transportSupported, true)
    assert.deepEqual(caps.accelerators, ['rg', 'jq'])
    assert.equal(caps.terminal, false)
    assert.equal(caps.pty, false)
    assert.equal(caps.shell, 'just-bash')
    // The ordered channel HELLO carries caps only: no host provider, mounts
    // or limits are synthesized into xz-shell facts.
    assert.equal(caps.factsSource, 'channel-caps')
    assert.equal(caps.provider, undefined)
    assert.equal(caps.mounts, undefined)
    assert.equal(caps.hostLimits, undefined)
    const bridge = h.ctx.get('xlExecBridge') as XlExecBridge
    assert.equal(bridge.hello.facts_source, 'channel-caps')
    assert.equal(bridge.hello.provider.name, 'unknown')
    assert.deepEqual(bridge.hello.guest.mounts, [])
    assert.deepEqual(bridge.hello.limits, {})
    // The channel HELLO publishes no host mounts. Its mapper is guest-only:
    // guest paths pass through, while an arbitrary host path such as /etc is
    // never claimed as a mount (the old synthetic host=/ -> guest=/ removed).
    assert.equal(bridge.paths.isGuestOnly, true)
    assert.equal(bridge.paths.toHost('/etc'), undefined)
    assert.equal(bridge.paths.toHost('/dsh/workspace'), undefined)
    assert.equal(bridge.paths.toGuest('/dsh/workspace'), '/dsh/workspace')
    assert.equal(bridge.paths.defaultGuestRoot, '/dsh/workspace')

    const printed = await h.service.run({ command: 'printf hello', cwd: '/dsh/workspace' })
    assert.equal(printed.exitCode, 0)
    assert.equal(printed.stdout, 'hello')
    assert.equal(printed.timedOut, false)
    assert.equal(printed.truncated, false)
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0, 'a command stays in the Worker')

    const written = await h.service.run({
      command: "printf 'vfs-visible' > /dsh/workspace/console.txt",
      cwd: '/dsh/workspace',
    })
    assert.equal(written.exitCode, 0)
    assert.equal(readFileSync(join(h.root, 'dsh/workspace/console.txt'), 'utf8'), 'vfs-visible')
  } finally {
    await h.dispose()
  }
})

test('a real HTTP hello projects its provider, mounts and limits; channel placeholders do not', () => {
  const limits = {
    timeoutMs: 30_000, maxTimeoutMs: 120_000, maxOutputBytes: 256 * 1024,
    maxCommandBytes: 64 * 1024, maxArgv: 256,
  }
  const hostCaps = capsFromHello({
    protocol: 'pdsh-exec-bridge/1',
    provider: { name: 'pdsh-phone-loopback', version: '1.0.0' },
    guest: {
      platform: 'posix',
      mounts: [{ host_path: '/var/pdsh/workspace', guest_path: '/dsh/workspace', read_only: true }],
    },
    capabilities: { exec: true, accelerators: ['rg'] },
    limits: { max_concurrent: 4, max_output_bytes_per_stream: 1_048_576 },
  }, limits, 'fetch')
  assert.equal(hostCaps.factsSource, 'exec-bridge-hello')
  assert.equal(hostCaps.provider, 'pdsh-phone-loopback')
  assert.equal(hostCaps.version, '1.0.0')
  assert.deepEqual(hostCaps.mounts, [{
    hostPath: '/var/pdsh/workspace', guestPath: '/dsh/workspace', readOnly: true,
  }])
  assert.deepEqual(hostCaps.hostLimits, { maxConcurrent: 4, maxOutputBytesPerStream: 1_048_576 })

  const channelCaps = capsFromHello({
    protocol: 'pdsh-exec-bridge/1',
    facts_source: 'channel-caps',
    provider: { name: 'unknown' },
    guest: { platform: 'posix', mounts: [] },
    capabilities: { exec: true, accelerators: ['rg'] },
    limits: {},
  }, limits, 'channel')
  assert.equal(channelCaps.factsSource, 'channel-caps')
  assert.equal(channelCaps.provider, undefined)
  assert.equal(channelCaps.mounts, undefined)
  assert.equal(channelCaps.hostLimits, undefined)
  assert.deepEqual(channelCaps.accelerators, ['rg'])
  assert.equal(channelCaps.transportSupported, true)

  // node-http (and an unconfirmed route) never offers an advertised name as a
  // runnable accelerator: the transport itself cannot serve the console.
  for (const route of ['node-http', undefined] as const) {
    const unsupported = capsFromHello({
      protocol: 'pdsh-exec-bridge/1',
      provider: { name: 'pdsh-phone-loopback', version: '1.0.0' },
      guest: {
        platform: 'posix',
        mounts: [{ host_path: '/var/pdsh/workspace', guest_path: '/dsh/workspace', read_only: true }],
      },
      capabilities: { exec: true, accelerators: ['rg'] },
      limits: {},
    }, limits, route)
    assert.equal(unsupported.transportSupported, false)
    assert.equal(unsupported.linked, false)
    assert.deepEqual(unsupported.accelerators, [])
    assert.match(unsupported.note, /does not support the phone console/u)
  }
})

test('Worker VFS cwd and host mount cwd are validated against their real owners', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  const hostCaps = {
    accelerators: ['rg'],
    mounts: [{ hostPath: '/var/pdsh/workspace', guestPath: '/dsh/workspace', readOnly: true }],
  }
  try {
    // Worker commands are bounded by the real VFS roots, not a synthetic `/`.
    assert.throws(
      () => normalizeConsoleRequest({ command: 'printf x', cwd: '/' }, undefined, 'fetch'),
      /outside the Worker VFS roots/u,
    )
    assert.throws(
      () => normalizeConsoleRequest({ command: 'printf x', cwd: '/etc' }, undefined, 'fetch'),
      /outside the Worker VFS roots/u,
    )
    assert.throws(
      () => normalizeConsoleRequest({ command: 'printf x', cwd: '/dsh' }, undefined, 'fetch'),
      /outside the Worker VFS roots/u,
    )
    assert.equal(normalizeConsoleRequest({ command: 'printf x', cwd: '/dsh/home' }, hostCaps, 'fetch').cwd, '/dsh/home')

    // An accelerator with real host mounts is bounded by the host's guest
    // mounts; a Worker-only root outside them is rejected.
    assert.throws(
      () => normalizeConsoleRequest({ argv: ['rg', 'x'], cwd: '/dsh/home' }, hostCaps, 'fetch'),
      /outside every host guest mount/u,
    )
    assert.equal(normalizeConsoleRequest({ argv: ['rg', 'x'], cwd: '/dsh/workspace' }, hostCaps, 'fetch').cwd, '/dsh/workspace')

    // The channel publishes no host mounts, so `/` is still not accepted.
    await assert.rejects(h.service.run({ command: 'printf x', cwd: '/' }), /outside the Worker VFS roots/u)
    await assert.rejects(h.service.run({ argv: ['rg', 'x'], cwd: '/' }), /outside the Worker VFS roots/u)
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
    const home = await h.service.run({ command: 'printf home', cwd: '/dsh/home' })
    assert.equal(home.exitCode, 0)
    assert.equal(home.stdout, 'home')
  } finally {
    await h.dispose()
  }
})

test('an unadvertised argv stays Worker-bound even when the HELLO publishes host-only mounts', async () => {
  const hostCaps = {
    accelerators: ['rg'],
    mounts: [{ hostPath: '/var/pdsh/workspace', guestPath: '/host/workspace', readOnly: true }],
  }
  // Not an advertised accelerator: subprocess-xl keeps it in the Worker shell,
  // so /dsh/workspace is legal and the host guest root is not.
  assert.equal(
    normalizeConsoleRequest({ argv: ['printf', 'worker'], cwd: '/dsh/workspace' }, hostCaps, 'fetch').cwd,
    '/dsh/workspace',
  )
  assert.throws(
    () => normalizeConsoleRequest({ argv: ['printf', 'worker'], cwd: '/host/workspace' }, hostCaps, 'fetch'),
    /outside the Worker VFS roots/u,
  )
  assert.throws(
    () => normalizeConsoleRequest({ command: 'printf worker', cwd: '/host/workspace' }, hostCaps, 'fetch'),
    /outside the Worker VFS roots/u,
  )
  // The advertised accelerator is the only argv owner of the host mounts.
  assert.equal(
    normalizeConsoleRequest({ argv: ['rg', 'x'], cwd: '/host/workspace' }, hostCaps, 'fetch').cwd,
    '/host/workspace',
  )
  assert.throws(
    () => normalizeConsoleRequest({ argv: ['rg', 'x'], cwd: '/dsh/workspace' }, hostCaps, 'fetch'),
    /outside every host guest mount/u,
  )
})

test('a real HELLO with zero mounts rejects the advertised accelerator instead of an implicit host root', () => {
  const emptyCaps = { accelerators: ['rg'], mounts: [] }
  assert.throws(
    () => normalizeConsoleRequest({ argv: ['rg', 'x'], cwd: '/dsh/workspace' }, emptyCaps, 'fetch'),
    /published no guest mount/u,
  )
  assert.throws(
    () => normalizeConsoleRequest({ argv: ['rg', 'x'], cwd: '/host/workspace' }, emptyCaps, 'fetch'),
    /published no guest mount/u,
  )
  // A non-advertised argv never had a host claim: it still runs in the Worker.
  assert.equal(
    normalizeConsoleRequest({ argv: ['printf', 'worker'], cwd: '/dsh/workspace' }, emptyCaps, 'fetch').cwd,
    '/dsh/workspace',
  )
})

test('node-http rejects every request form, including advertised bare names', () => {
  const httpCaps = {
    accelerators: ['rg', 'jq'],
    mounts: [{ hostPath: '/var/pdsh/workspace', guestPath: '/dsh/workspace', readOnly: true }],
  }
  const nodeHttp = 'node-http' as const
  const unsupported = /node-http exec transport is not supported.*desktop Host/u
  const rejectNodeHttp = (
    request: Parameters<typeof normalizeConsoleRequest>[0],
    caps: Parameters<typeof normalizeConsoleRequest>[1] = httpCaps,
  ): void => {
    assert.throws(() => normalizeConsoleRequest(request, caps, nodeHttp), unsupported)
  }

  // There is no Worker-local executor behind node-http: every request would
  // become a Host process, so the route itself is rejected before parsing.
  rejectNodeHttp({ command: 'printf host-write > host.txt', cwd: '/dsh/workspace' })
  for (const program of [
    'rg',
    'jq',
    '/tmp/evil/rg',
    '/plugins/node_modules/@vscode/ripgrep/bin/rg',
    '/plugins/node_modules/@vscode/ripgrep-linux-x64/bin/rg',
    '/usr/bin/rg',
    '/opt/tools/jq',
    './bin/rg',
    'bin/rg',
    'sh',
    '/bin/sh',
  ]) {
    rejectNodeHttp({ argv: [program, 'needle'], cwd: '/dsh/workspace' })
  }
  // A valid host guest-mount cwd does not make node-http usable either.
  assert.throws(
    () => normalizeConsoleRequest({ argv: ['rg', 'needle'], cwd: '/dsh/workspace' }, httpCaps, nodeHttp),
    unsupported,
  )
  // An empty advertised set has no legitimate Host program on node-http.
  rejectNodeHttp({ argv: ['rg', 'needle'], cwd: '/dsh/workspace' }, { accelerators: [], mounts: [] })
  // Unknown transports cannot be confirmed as Worker routes: fail closed.
  for (const route of [undefined, 'auto' as ExecTransportKind]) {
    assert.throws(
      () => normalizeConsoleRequest({ command: 'printf x', cwd: '/dsh/workspace' }, httpCaps, route),
      /cannot be confirmed as channel\/fetch.*fails closed/u,
    )
    assert.throws(
      () => normalizeConsoleRequest({ argv: ['rg', 'needle'], cwd: '/dsh/workspace' }, httpCaps, route),
      /cannot be confirmed as channel\/fetch.*fails closed/u,
    )
  }

  // channel/fetch keep the real route: path-form programs are normalized by
  // subprocess-xl to the advertised bare identity before the Host dispatch,
  // and Worker commands/argv stay in the Worker VFS.
  assert.equal(
    normalizeConsoleRequest({ argv: ['/tmp/evil/rg', 'needle'], cwd: '/dsh/workspace' }, httpCaps, 'channel').argv[0],
    '/tmp/evil/rg',
  )
  assert.equal(
    normalizeConsoleRequest({ command: 'printf worker', cwd: '/dsh/workspace' }, httpCaps, 'channel').cwd,
    '/dsh/workspace',
  )
  assert.equal(
    normalizeConsoleRequest({ argv: ['printf', 'worker'], cwd: '/dsh/workspace' }, httpCaps, 'fetch').cwd,
    '/dsh/workspace',
  )
})

test('node-http rejects every request before spawn on the real sim and never writes the Host', async () => {
  const hostRoot = realpathSync(mkdtempSync(join(tmpdir(), 'pdsh-phone-shell-host-')))
  roots.push(hostRoot)
  writeFileSync(join(hostRoot, 'needle.txt'), 'needle\nother\n')
  // A real executable at a path-form argv[0] whose basename is advertised.
  // Before the route gate, isAccelerator resolved it to `rg` and node-http
  // spawned this path in the Host workspace.
  const evilRoot = realpathSync(mkdtempSync(join(tmpdir(), 'pdsh-phone-shell-evil-')))
  roots.push(evilRoot)
  const evilRg = join(evilRoot, 'rg')
  writeFileSync(evilRg, "#!/bin/sh\nprintf 'host-escape' > host-escape.txt\n")
  chmodSync(evilRg, 0o755)
  let sim: ChildProcess | undefined
  let ctx: Context | undefined
  const previousToken = process.env.PDSH_PHONE_SHELL_SIM_TOKEN
  try {
    // The guest mount is a valid Host cwd, unlike the Worker roots: even a
    // request that could be mapped must still be rejected by the route gate.
    const started = await startSim(hostRoot, '/host/workspace')
    sim = started.sim
    process.env.PDSH_PHONE_SHELL_SIM_TOKEN = started.token
    ctx = new Context()
    await ctx.plugin(XlExecBridge, {
      transport: 'node-http',
      url: started.url,
      tokenEnv: 'PDSH_PHONE_SHELL_SIM_TOKEN',
      tokenFileEnv: 'PDSH_PHONE_SHELL_UNUSED_TOKEN_FILE',
      connectTimeoutMs: 2_000,
      accelerators: ['rg', 'jq'],
    })
    await ctx.plugin(XlSubprocessRuntime)
    await ctx.plugin(PhoneShellRemote)
    const service = ctx.get('phoneShell') as PhoneShellRemote
    const bridge = ctx.get('xlExecBridge') as XlExecBridge
    const subprocess = ctx.get('subprocess') as SubprocessRuntime
    // Prove there is no spawn at all, not merely no completed Host request.
    let spawns = 0
    let terminalCalls = 0
    const originalSpawn = subprocess.spawn.bind(subprocess)
    subprocess.spawn = ((spec) => {
      spawns += 1
      return originalSpawn(spec)
    }) as SubprocessRuntime['spawn']
    subprocess.spawnTerminal = (async () => {
      terminalCalls += 1
      throw new Error('spawnTerminal must not be called')
    }) as SubprocessRuntime['spawnTerminal']
    let hostExecs = 0
    const client = bridge.client
    const originalExec = client.exec.bind(client)
    client.exec = ((...args: Parameters<typeof originalExec>) => {
      hostExecs += 1
      return originalExec(...args)
    }) as typeof client.exec

    const caps = service.caps()
    assert.equal(caps.factsSource, 'exec-bridge-hello')
    assert.equal(caps.transportSupported, false)
    assert.equal(caps.linked, false)
    assert.deepEqual(caps.accelerators, [], 'node-http accelerators are not offered as usable')
    assert.match(caps.note, /does not support the phone console/u)
    assert.deepEqual(caps.mounts, [{ hostPath: hostRoot, guestPath: '/host/workspace', readOnly: false }])

    const unsupported = /node-http exec transport is not supported/u
    for (const request of [
      { command: "printf 'host-write' > host.txt", cwd: '/host/workspace' },
      { command: "printf 'host-write' > host.txt", cwd: '/dsh/workspace' },
      { argv: ['rg', '-n', 'needle', 'needle.txt'], cwd: '/host/workspace' },
      { argv: ['jq', '.answer'], cwd: '/host/workspace' },
      { argv: ['sh', '-c', "printf 'host-write' > host.txt"], cwd: '/host/workspace' },
      { argv: [evilRg, 'needle'], cwd: '/host/workspace' },
      { argv: ['/plugins/node_modules/@vscode/ripgrep/bin/rg', 'needle'], cwd: '/host/workspace' },
      { argv: ['./bin/rg', 'needle'], cwd: '/host/workspace' },
      { argv: ['/bin/sh'], cwd: '/host/workspace' },
    ]) {
      await assert.rejects(service.run(request), unsupported)
    }
    // The old bare-advertised-name exemption is gone too.
    await assert.rejects(service.run({ argv: ['rg', 'needle'], cwd: '/dsh/workspace' }), unsupported)
    assert.equal(spawns, 0, 'no subprocess spawn was attempted on node-http')
    assert.equal(terminalCalls, 0, 'no PTY was allocated')
    assert.equal(hostExecs, 0, 'no EXEC_REQ reached the Host')
    assert.equal(existsSync(join(hostRoot, 'host.txt')), false, 'the Host workspace was not written')
    assert.equal(existsSync(join(hostRoot, 'host-escape.txt')), false, 'the path-form executable did not run')
  } finally {
    if (ctx !== undefined) await ctx.fiber.dispose().catch(() => {})
    if (sim !== undefined) await stopSim(sim)
    if (previousToken === undefined) delete process.env.PDSH_PHONE_SHELL_SIM_TOKEN
    else process.env.PDSH_PHONE_SHELL_SIM_TOKEN = previousToken
  }
})

test('a real HTTP HELLO that publishes zero mounts fails closed on every non-channel transport', async () => {
  let hello: Record<string, unknown> = {}
  const zeroMounts = {
    protocol: 'pdsh-exec-bridge/1',
    provider: { name: 'real-http-zero-mounts' },
    guest: { platform: 'posix', mounts: [] },
    capabilities: { exec: true, accelerators: ['rg'] },
    limits: {},
  }
  const missingMounts = {
    protocol: 'pdsh-exec-bridge/1',
    provider: { name: 'malformed-http-hello' },
    guest: { platform: 'posix' },
    capabilities: { exec: true, accelerators: ['rg'] },
    limits: {},
  }
  const server = createServer((_request, response) => {
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify(hello))
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const previous = process.env.PDSH_PHONE_SHELL_EMPTY_TOKEN
  process.env.PDSH_PHONE_SHELL_EMPTY_TOKEN = 'empty-mount-token-012345'
  try {
    for (const transport of ['node-http', 'fetch'] as const) {
      for (const shape of [zeroMounts, missingMounts]) {
        hello = shape
        const ctx = new Context()
        try {
          await assert.rejects(
            async () => {
              await ctx.plugin(XlExecBridge, {
                transport,
                url,
                tokenEnv: 'PDSH_PHONE_SHELL_EMPTY_TOKEN',
                tokenFileEnv: 'PDSH_PHONE_SHELL_UNUSED_TOKEN_FILE',
                connectTimeoutMs: 1_000,
              })
            },
            /published no guest mounts/u,
          )
          assert.equal(ctx.get('xlExecBridge'), undefined)
        } finally {
          await ctx.fiber.dispose().catch(() => {})
        }
      }
    }
  } finally {
    if (previous === undefined) delete process.env.PDSH_PHONE_SHELL_EMPTY_TOKEN
    else process.env.PDSH_PHONE_SHELL_EMPTY_TOKEN = previous
    server.closeAllConnections()
    await new Promise<void>(resolve => { server.close(() => { resolve() }) })
  }
})

test('without host caps the console reports unlinked and still runs Worker bash without EXEC_REQ', async () => {
  const h = await harness({ caps: [] })
  try {
    const caps = h.service.caps()
    assert.equal(caps.linked, false)
    assert.deepEqual(caps.accelerators, [])
    const result = await h.service.run({ command: 'printf worker-only', cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 0)
    assert.equal(result.stdout, 'worker-only')
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})

test('unadvertised rg runs on a real file through the Worker command table', async () => {
  const h = await harness({ caps: [] })
  try {
    const seeded = await h.service.run({
      command: "printf 'needle\\nother\\n' > /dsh/workspace/notes.txt",
      cwd: '/dsh/workspace',
    })
    assert.equal(seeded.exitCode, 0)
    const rg = await h.service.run({ argv: ['rg', 'needle', '/dsh/workspace/notes.txt'], cwd: '/dsh/workspace' })
    assert.equal(rg.exitCode, 0)
    assert.match(rg.stdout, /needle/u)
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 0)
  } finally {
    await h.dispose()
  }
})

test('advertised rg and jq argv reach the Host as EXEC_REQ and return real output facts', async () => {
  const h = await harness({ caps: ['accelerator:rg', 'accelerator:jq'] })
  try {
    const started = Date.now()
    const rg = h.service.run({
      execId: 'console-rg-1',
      argv: ['rg', '--json', 'needle', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    const rgExecId = await answerHostRun(h.mock, ['rg', '--json', 'needle', '/dsh/workspace'], '{"match":true}\n')
    const rgResult = await rg
    assert.equal(rgResult.exitCode, 0)
    assert.equal(rgResult.stdout, '{"match":true}\n')
    assert.match(rgExecId, /^xl-/u)
    const rgFrame = h.mock.framesOf(FrameType.EXEC_REQ).find(frame => jsonPayload(frame)['exec_id'] === rgExecId)
    assert.notEqual(rgFrame, undefined)
    const rgBody = jsonPayload(rgFrame!)
    assert.deepEqual(rgBody['argv'], ['rg', '--json', 'needle', '/dsh/workspace'])
    assert.equal(rgBody['cwd'], '/dsh/workspace')
    assert.equal((rgBody['env'] as Record<string, string>)['XL_IDEMPOTENCY_KEY'], 'console-rg-1')
    assert.ok(Number(rgBody['deadline']) >= started + 4_000, 'the host deadline follows timeoutMs, not graceMs')
    assert.ok(Number(rgBody['grace_ms']) <= 1_000, 'graceMs stays a short termination grace')

    const jq = h.service.run({
      execId: 'console-jq-1',
      argv: ['jq', '.answer', '/dsh/workspace/data.json'],
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    await answerHostRun(h.mock, ['jq', '.answer', '/dsh/workspace/data.json'], '42\n')
    const jqResult = await jq
    assert.equal(jqResult.exitCode, 0)
    assert.equal(jqResult.stdout, '42\n')
    const jqFrame = h.mock.framesOf(FrameType.EXEC_REQ).find(frame => {
      const body = jsonPayload(frame)
      return JSON.stringify(body['argv']) === JSON.stringify(['jq', '.answer', '/dsh/workspace/data.json'])
    })
    assert.notEqual(jqFrame, undefined)
    assert.deepEqual(jsonPayload(jqFrame!)['argv'], ['jq', '.answer', '/dsh/workspace/data.json'])
    assert.equal(h.mock.framesOf(FrameType.EXEC_REQ).length, 2)
  } finally {
    await h.dispose()
  }
})

test('a channel path-form advertised program still reaches the Host under its bare identity', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  try {
    // subprocess-xl normalizes a path-form advertised program to the bare
    // identity before the channel is asked, so this remains a real Host
    // accelerator path (node-http never reaches this route at all).
    const pending = h.service.run({
      execId: 'console-path-rg',
      argv: ['/tmp/evil/rg', 'needle', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    const hostExecId = await answerHostRun(h.mock, ['rg', 'needle', '/dsh/workspace'], 'needle\n')
    const result = await pending
    assert.equal(result.exitCode, 0)
    assert.equal(result.stdout, 'needle\n')
    const frame = h.mock.framesOf(FrameType.EXEC_REQ).find(candidate => jsonPayload(candidate)['exec_id'] === hostExecId)
    assert.notEqual(frame, undefined)
    const body = jsonPayload(frame!)
    assert.deepEqual(body['argv'], ['rg', 'needle', '/dsh/workspace'])
    assert.equal((body['env'] as Record<string, string>)['XL_IDEMPOTENCY_KEY'], 'console-path-rg')
  } finally {
    await h.dispose()
  }
})

test('invalid argv, cwd, timeout and exec id are rejected before spawn', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  try {
    let spawns = 0
    let terminalCalls = 0
    const originalSpawn = h.subprocess.spawn.bind(h.subprocess)
    h.subprocess.spawn = ((spec) => {
      spawns += 1
      return originalSpawn(spec)
    }) as SubprocessRuntime['spawn']
    h.subprocess.spawnTerminal = (async () => {
      terminalCalls += 1
      throw new Error('spawnTerminal must not be called')
    }) as SubprocessRuntime['spawnTerminal']

    await assert.rejects(h.service.run({ argv: [] }), /argv must name a program/u)
    await assert.rejects(h.service.run({ argv: ['rg', 1 as unknown as string] }), /argv\[1\] must be a string/u)
    await assert.rejects(h.service.run({ argv: ['rg\0', 'x'] }), /must not contain NUL/u)
    await assert.rejects(h.service.run({ command: 'echo x', argv: ['echo'] }), /exactly one/u)
    await assert.rejects(h.service.run({ command: '' }), /non-empty/u)
    await assert.rejects(h.service.run({ command: '   ' }), /must not be blank/u)
    await assert.rejects(h.service.run({ command: 'echo', cwd: 'relative' }), /absolute/u)
    await assert.rejects(h.service.run({ command: 'echo', cwd: '/dsh/workspace/../home' }), /\.\. component/u)
    await assert.rejects(h.service.run({ command: 'echo', timeoutMs: 0 }), /positive integer/u)
    await assert.rejects(h.service.run({ command: 'echo', timeoutMs: -1 }), /positive integer/u)
    await assert.rejects(h.service.run({ command: 'echo', timeoutMs: 1.5 }), /positive integer/u)
    await assert.rejects(h.service.run({ command: 'echo', timeoutMs: 121_000 }), /must not exceed/u)
    await assert.rejects(h.service.run({ command: 'echo', execId: 'bad id' }), /execId/u)
    await assert.rejects(h.service.run({ command: 'echo', execId: 'bad:id' }), /execId/u)
    await assert.rejects(h.service.run({ command: 'echo', execId: 'a'.repeat(62) }), /execId/u)
    await assert.rejects(h.service.run({ command: 'echo', execId: 'a'.repeat(64) }), /execId/u)
    await assert.rejects(h.service.run({ command: 'echo', execId: '' }), /execId/u)
    assert.throws(() => h.service.cancel('bad:id'), /execId/u)
    assert.throws(() => h.service.cancel('a'.repeat(64)), /execId/u)
    assert.equal(spawns, 0)
    assert.equal(terminalCalls, 0)
  } finally {
    await h.dispose()
  }
})

test('a console timeout is reported as exit 124 and the run settles', async () => {
  const h = await harness({ caps: [] })
  try {
    const started = Date.now()
    const result = await h.service.run({
      command: 'sleep 5; printf never',
      cwd: '/dsh/workspace',
      timeoutMs: 100,
    })
    assert.equal(result.timedOut, true)
    assert.equal(result.exitCode, 124)
    assert.equal(result.stdout, '')
    assert.ok(Date.now() - started < 3_000, 'the deadline settles the run instead of waiting for sleep')
  } finally {
    await h.dispose()
  }
})

test('cancel terminates the identified run and never allocates a PTY', async () => {
  const h = await harness({ caps: [] })
  try {
    let terminalCalls = 0
    h.subprocess.spawnTerminal = (async () => {
      terminalCalls += 1
      throw new Error('spawnTerminal must not be called')
    }) as SubprocessRuntime['spawnTerminal']
    const pending = h.service.run({
      execId: 'console-cancel-1',
      command: 'sleep 5; printf never',
      cwd: '/dsh/workspace',
      timeoutMs: 10_000,
    })
    assert.equal(h.service.cancel('console-cancel-1'), true)
    const result = await pending
    assert.equal(result.cancelled, true)
    assert.equal(result.timedOut, false)
    assert.equal(result.exitCode, null)
    assert.equal(h.service.cancel('console-cancel-1'), false)
    assert.equal(terminalCalls, 0)
  } finally {
    await h.dispose()
  }
})

test('a cut output stream is reported as truncated, not as a clean success', async () => {
  const h = await harness({ caps: [], shellOutputBytes: 64 })
  try {
    const result = await h.service.run({ command: 'seq 1 1000', cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 1)
    assert.equal(result.truncated, true)
    assert.match(result.stdout, /output truncated/u)
    assert.match(result.stderr, /reason=output-truncated/u)
  } finally {
    await h.dispose()
  }
})

test('the browser helper sends the documented phone/shell endpoints and args envelope', async () => {
  const calls: Array<{ channel: string; endpoint: string; payload: unknown }> = []
  const caps = {
    linked: true, provider: 'pdsh-shell', accelerators: ['rg'], mounts: [], limits: {
      timeoutMs: 30_000, maxTimeoutMs: 120_000, maxOutputBytes: 1_048_576, maxCommandBytes: 65_536, maxArgv: 256,
    }, transportSupported: true, factsSource: 'exec-bridge-hello', shell: 'just-bash', readOnlyAccelerators: true, terminal: false, pty: false, note: '',
  } as const
  const client = createPhoneShellClient({
    async call(channel, endpoint, payload) {
      calls.push({ channel, endpoint, payload })
      if (endpoint === PHONE_SHELL_ENDPOINTS.caps) return { ok: true, value: caps }
      if (endpoint === PHONE_SHELL_ENDPOINTS.run) return { ok: true, value: { execId: 'id-1', argv: ['rg', 'x'], cwd: '/dsh/workspace', stdout: '', stderr: '', exitCode: 0, signal: null, timedOut: false, cancelled: false, truncated: false, durationMs: 1 } }
      return { ok: true, value: true }
    },
  })
  assert.equal(await client.caps(), caps)
  assert.equal((await client.run({ execId: 'id-1', argv: ['rg', 'x'], cwd: '/dsh/workspace' })).exitCode, 0)
  assert.equal(await client.cancel('id-1'), true)
  assert.deepEqual(calls.map(call => call.endpoint), [
    PHONE_SHELL_ENDPOINTS.caps,
    PHONE_SHELL_ENDPOINTS.run,
    PHONE_SHELL_ENDPOINTS.cancel,
  ])
  assert.deepEqual(calls[0]?.payload, { args: {} })
  assert.deepEqual((calls[1]?.payload as { args: { request: unknown } }).args.request, { execId: 'id-1', argv: ['rg', 'x'], cwd: '/dsh/workspace' })
  assert.deepEqual(calls[2]?.payload, { args: { execId: 'id-1' } })
})

test('an advertised rg typed into the command box crosses bash -c with the console exec identity', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  try {
    const seeded = await h.service.run({
      command: "printf 'needle\\nother\\n' > /dsh/workspace/notes.txt",
      cwd: '/dsh/workspace',
    })
    assert.equal(seeded.exitCode, 0)
    const started = Date.now()
    const pending = h.service.run({
      execId: 'console-rg-command-1',
      command: 'rg needle /dsh/workspace/notes.txt',
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    const hostExecId = await answerHostRun(h.mock, ['rg', 'needle', '/dsh/workspace/notes.txt'], 'needle\n')
    const result = await pending
    assert.equal(result.exitCode, 0)
    assert.equal(result.stdout, 'needle\n')
    assert.match(hostExecId, /^console-rg-command-1-a\d+$/u)
    const frames = h.mock.framesOf(FrameType.EXEC_REQ)
    assert.equal(frames.length, 1)
    const body = jsonPayload(frames[0]!)
    assert.deepEqual(body['argv'], ['rg', 'needle', '/dsh/workspace/notes.txt'])
    assert.equal((body['env'] as Record<string, string>)['XL_IDEMPOTENCY_KEY'], 'console-rg-command-1')
    assert.ok(Number(body['deadline']) >= started + 4_000, 'bash -c accelerator gets the requested deadline too')
  } finally {
    await h.dispose()
  }
})

test('a 61-character exec id leaves the -aN suffix inside the D6 64-character bound', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  const execId = 'a'.repeat(61)
  try {
    const pending = h.service.run({
      execId,
      command: 'rg needle /dsh/workspace/notes.txt',
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    const hostExecId = await answerHostRun(h.mock, ['rg', 'needle', '/dsh/workspace/notes.txt'], 'needle\n')
    assert.equal((await pending).exitCode, 0)
    assert.equal(hostExecId, `${execId}-a0`)
    assert.equal(hostExecId.length, 64)
    assert.match(hostExecId, /^[A-Za-z0-9._-]{1,64}$/u)
  } finally {
    await h.dispose()
  }
})

test('a host run that never reports quiescence still settles at the console deadline', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  try {
    const started = Date.now()
    const pending = h.service.run({
      execId: 'console-no-quiescent',
      argv: ['rg', 'needle', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 100,
    })
    const execId = await waitHostRun(h.mock, ['rg', 'needle', '/dsh/workspace'])
    h.mock.execEvent({ type: 'start', exec_id: execId, seq: 0, pid: 7 })
    // Exit with no `quiescent` flag: `done` can settle but `waitForExit` stays open.
    h.mock.execEvent({ type: 'exit', exec_id: execId, seq: 1, code: 0, signal: null, status: 'exited' })
    const outcome = await Promise.race([
      pending.then(result => ({ kind: 'result' as const, result })),
      new Promise<{ kind: 'hung' }>(resolve => { setTimeout(() => { resolve({ kind: 'hung' }) }, 2_000) }),
    ])
    assert.equal(outcome.kind, 'result')
    if (outcome.kind !== 'result') assert.fail('the console deadline did not settle the run')
    assert.equal(outcome.result.timedOut, true)
    assert.equal(outcome.result.exitCode, 124)
    assert.ok(Date.now() - started < 1_000, 'the hard settlement is not an unbounded wait')

    // A late EXEC_EVT from the forced-settled execution has no observer, and
    // the workspace lane must be free for the next real command.
    h.mock.execEvent({ type: 'quiescent', exec_id: execId, seq: 2 })
    const startedAfter = Date.now()
    const after = h.service.run({
      execId: 'console-after-no-quiescent',
      argv: ['rg', 'after', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    const afterExecId = await answerHostRun(h.mock, ['rg', 'after', '/dsh/workspace'], 'after\n')
    const afterResult = await after
    assert.equal(afterResult.exitCode, 0)
    assert.equal(afterResult.stdout, 'after\n')
    assert.equal(afterResult.timedOut, false)
    assert.notEqual(afterExecId, execId)
    const afterFrame = h.mock.framesOf(FrameType.EXEC_REQ).find(frame => jsonPayload(frame)['exec_id'] === afterExecId)
    assert.notEqual(afterFrame, undefined)
    assert.ok(Number(jsonPayload(afterFrame!)['deadline']) >= startedAfter + 4_000, 'the next EXEC_REQ carries its real deadline')
  } finally {
    await h.dispose()
  }
})

test('cancel hard-settles a host run that ignores the cancel request', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  try {
    const pending = h.service.run({
      execId: 'console-cancel-host',
      argv: ['rg', 'needle', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    await waitHostRun(h.mock, ['rg', 'needle', '/dsh/workspace'])
    const started = Date.now()
    assert.equal(h.service.cancel('console-cancel-host'), true)
    const outcome = await Promise.race([
      pending.then(result => ({ kind: 'result' as const, result })),
      new Promise<{ kind: 'hung' }>(resolve => { setTimeout(() => { resolve({ kind: 'hung' }) }, 2_000) }),
    ])
    assert.equal(outcome.kind, 'result')
    if (outcome.kind !== 'result') assert.fail('cancel did not settle the run')
    assert.equal(outcome.result.cancelled, true)
    assert.equal(outcome.result.timedOut, false)
    assert.equal(outcome.result.exitCode, null)
    assert.ok(Date.now() - started < 1_000, 'cancel is hard-settled before the requested timeout')

    // The provider lane/handle was released, not just the Remote promise: a
    // second command in the same workspace must actually reach the host.
    const after = h.service.run({
      execId: 'console-after-cancel',
      argv: ['rg', 'after-cancel', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    await answerHostRun(h.mock, ['rg', 'after-cancel', '/dsh/workspace'], 'still-alive\n')
    const afterResult = await after
    assert.equal(afterResult.exitCode, 0)
    assert.equal(afterResult.stdout, 'still-alive\n')
    assert.equal(afterResult.cancelled, false)
  } finally {
    await h.dispose()
  }
})

test('a host that never answers a deadline is hard-settled and late events cannot hold the lane', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  try {
    const started = Date.now()
    const pending = h.service.run({
      execId: 'console-deadline-no-host',
      argv: ['rg', 'never', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 100,
    })
    const oldExecId = await waitHostRun(h.mock, ['rg', 'never', '/dsh/workspace'])
    // The host never sends start/output/exit/quiescent and ignores EXEC_CTL.
    const outcome = await Promise.race([
      pending.then(result => ({ kind: 'result' as const, result })),
      new Promise<{ kind: 'hung' }>(resolve => { setTimeout(() => { resolve({ kind: 'hung' }) }, 2_000) }),
    ])
    assert.equal(outcome.kind, 'result')
    if (outcome.kind !== 'result') assert.fail('the console deadline did not settle the unresponsive host')
    assert.equal(outcome.result.timedOut, true)
    assert.equal(outcome.result.exitCode, 124)
    assert.ok(Date.now() - started < 1_000, 'the unresponsive handle is force-settled, not awaited')

    const after = h.service.run({
      execId: 'console-after-deadline',
      argv: ['rg', 'after', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    const afterExecId = await waitHostRun(h.mock, ['rg', 'after', '/dsh/workspace'])
    // The released execution's late events have no observer and cannot leak
    // into the next command's output or settlement.
    h.mock.execEvent({ type: 'start', exec_id: oldExecId, seq: 100, pid: 7 })
    h.mock.execEvent({ type: 'output', exec_id: oldExecId, seq: 101, stream: 'stdout', data: Buffer.from('stale\n').toString('base64') })
    h.mock.execEvent({ type: 'exit', exec_id: oldExecId, seq: 102, code: 9, signal: null, status: 'exited', quiescent: true })
    await answerHostRun(h.mock, ['rg', 'after', '/dsh/workspace'], 'fresh\n')
    const afterResult = await after
    assert.equal(afterResult.exitCode, 0)
    assert.equal(afterResult.stdout, 'fresh\n')
    assert.equal(afterResult.timedOut, false)
    assert.notEqual(afterExecId, oldExecId)
  } finally {
    await h.dispose()
  }
})

test('a host accelerator slower than the 1 s termination grace is not cut off early', async () => {
  const h = await harness({ caps: ['accelerator:rg'] })
  try {
    const pending = h.service.run({
      execId: 'console-slow-host',
      argv: ['rg', 'slow', '/dsh/workspace'],
      cwd: '/dsh/workspace',
      timeoutMs: 5_000,
    })
    const execId = await waitHostRun(h.mock, ['rg', 'slow', '/dsh/workspace'])
    await new Promise(resolve => setTimeout(resolve, 1_100))
    h.mock.execEvent({ type: 'start', exec_id: execId, seq: 0, pid: 7 })
    h.mock.execEvent({ type: 'output', exec_id: execId, seq: 1, stream: 'stdout', data: Buffer.from('slow but legal\n').toString('base64') })
    h.mock.execEvent({ type: 'exit', exec_id: execId, seq: 2, code: 0, signal: null, status: 'exited', quiescent: true })
    const result = await pending
    assert.equal(result.timedOut, false)
    assert.equal(result.exitCode, 0)
    assert.equal(result.stdout, 'slow but legal\n')
  } finally {
    await h.dispose()
  }
})
