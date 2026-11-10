/** CLI planning, TTY approval and install helper tests. */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  addPlugin,
  checkDshVersion,
  checkNativeModule,
  defaultInstallSpec,
  findDsh,
  runInstall,
  waitForPlugin,
} from '../cli/install.mjs'
import {
  createCliAdminClient,
  packageSha256,
  printStatus,
  renderQrCode,
  resolvePairTarget,
  runPair,
  runRotateIdentity,
  runUnpair,
} from '../cli/commands.mjs'

function collector() {
  let text = ''
  return { write: chunk => { text += chunk }, get text() { return text } }
}

function statusWithPairs(extra = {}) {
  return {
    v: 1,
    plugin: { version: '0.2.0', packageSha256: 'a'.repeat(64) },
    identity: { machineId: '7gdxeackpmfrjk3ylal74yyubv', publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', name: 'My PC' },
    relay: { origin: 'https://relay.example', state: 'connected' },
    pairs: [{
      peerMachineId: 'gewra3lzquaxpctdtkvzv2drdp',
      peerName: 'iPhone',
      pairedAt: '2026-11-09T00:00:00Z',
      approvedAt: '2026-11-09T00:00:05Z',
      approvedVia: 'qr',
      online: true,
      usable: true,
    }],
    warnings: [],
    ...extra,
  }
}

test('runPair completes from the phone scan without a TTY, fingerprint or ask', async () => {
  const output = collector()
  const calls = []
  let statusCalls = 0
  const client = {
    pair: async options => { calls.push(['pair', options]); return { v: 1, pairing: { id: 'p1', mode: 'qr', relayOrigin: 'https://relay.example', qrURI: 'pclink://pair?x', expiresAt: '2026-11-09T00:05:00Z' } } },
    status: async () => {
      statusCalls += 1
      return statusCalls >= 2
        ? statusWithPairs({ pairing: { id: 'p1', state: 'completed', mode: 'qr', expiresAt: '2026-11-09T00:05:00Z', peerName: 'iPhone', peerMachineId: 'gewra3lzquaxpctdtkvzv2drdp', peerFingerprint: 'gewr-a3lz-quax' } })
        : statusWithPairs({ pairing: { id: 'p1', state: 'joined', mode: 'qr', expiresAt: '2026-11-09T00:05:00Z', peerName: 'iPhone' } })
    },
    approve: async () => { calls.push('approve'); return { v: 1, approved: true } },
    cancel: async id => { calls.push(['cancel', id]); return { v: 1, cancelled: true } },
  }
  const result = await runPair({
    client, mode: 'qr', output, pollMs: 1,
    // Deliberately no stdinIsTTY/ask: pairing never reads them.
  })
  assert.equal(result.pairing.state, 'completed')
  assert.equal(calls.some(call => call[0] === 'approve'), false)
  assert.deepEqual(calls.find(call => call[0] === 'pair'), ['pair', { mode: 'qr' }])
  assert.match(output.text, /配对完成：iPhone（gewr-a3lz-quax）/)
  assert.match(output.text, /撤销这台手机：pclink unpair gewra3lzquaxpctdtkvzv2drdp/)
  assert.match(output.text, /此手机将能完整操作/)
})

test('runPair retries one transient admin timeout inside the deadline', async () => {
  const output = collector()
  let statusCalls = 0
  const client = {
    pair: async () => ({ v: 1, pairing: { id: 'p1', mode: 'manual', manualCode: '18DJ-RFAE-BXG7-30MK', expiresAt: '2026-11-09T00:05:00Z' } }),
    status: async () => {
      statusCalls += 1
      if (statusCalls === 1) {
        const error = new Error('The operation was aborted due to timeout')
        error.code = 'unavailable'
        throw error
      }
      return statusWithPairs({ pairing: { id: 'p1', state: 'completed', mode: 'manual', expiresAt: '2026-11-09T00:05:00Z', peerName: 'iPhone', peerMachineId: 'gewra3lzquaxpctdtkvzv2drdp', peerFingerprint: 'gewr-a3lz-quax' } })
    },
    cancel: async () => ({ v: 1, cancelled: true }),
  }
  const result = await runPair({ client, mode: 'manual', output, pollMs: 1, timeoutMs: 5_000 })
  assert.equal(result.pairing.state, 'completed')
  assert.equal(statusCalls, 2)
  assert.match(output.text, /等待插件响应/)
  assert.match(output.text, /配对完成/)
})

test('runPair still fails on a terminal pairing failure or a non-transient error', async () => {
  const output = collector()
  const failed = {
    pair: async () => ({ v: 1, pairing: { id: 'p1', mode: 'qr', qrURI: 'pclink://pair?x', expiresAt: '2026-11-09T00:05:00Z' } }),
    status: async () => statusWithPairs({ pairing: { id: 'p1', state: 'failed', mode: 'qr', expiresAt: '2026-11-09T00:05:00Z', error: 'auth_failed' } }),
    cancel: async () => ({ v: 1, cancelled: true }),
  }
  await assert.rejects(() => runPair({ client: failed, mode: 'qr', output, pollMs: 1 }), error => error.code === 'auth_failed')

  const badFrame = {
    pair: async () => ({ v: 1, pairing: { id: 'p1', mode: 'qr', qrURI: 'pclink://pair?x', expiresAt: '2026-11-09T00:05:00Z' } }),
    status: async () => { const error = new Error('bad frame'); error.code = 'bad_frame'; throw error },
    cancel: async () => ({ v: 1, cancelled: true }),
  }
  await assert.rejects(() => runPair({ client: badFrame, mode: 'qr', output, pollMs: 1 }), error => error.code === 'bad_frame')
})

test('runPair tolerates a legacy pre-v1.6 awaiting_approval status without a prompt', async () => {
  const output = collector()
  let calls = 0
  const client = {
    pair: async () => ({ v: 1, pairing: { id: 'p1', mode: 'qr', qrURI: 'pclink://pair?x', expiresAt: '2026-11-09T00:05:00Z' } }),
    status: async () => {
      calls += 1
      return calls === 1
        ? statusWithPairs({ pairing: { id: 'p1', state: 'awaiting_approval', mode: 'qr', expiresAt: '2026-11-09T00:05:00Z', peerName: 'iPhone' } })
        : statusWithPairs({ pairing: { id: 'p1', state: 'completed', mode: 'qr', expiresAt: '2026-11-09T00:05:00Z', peerName: 'iPhone', peerMachineId: 'gewra3lzquaxpctdtkvzv2drdp', peerFingerprint: 'gewr-a3lz-quax' } })
    },
    cancel: async () => ({ v: 1, cancelled: true }),
  }
  const result = await runPair({ client, mode: 'qr', output, pollMs: 1 })
  assert.equal(result.pairing.state, 'completed')
  assert.match(output.text, /旧版配对流程/)
  assert.match(output.text, /配对完成/)
})

test('renderQrCode prefers qrencode and falls back to the bundled encoder', () => {
  const uri = 'pclink://pair?v=1&r=https%3A%2F%2Fpclink.tonoai.cn&m=7gdxeackpmfrjk3ylal74yyubv&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&s=AAAAAAAAAAAAAAAAAAAAAA&n=My%20PC'
  const external = collector()
  assert.equal(renderQrCode(uri, external, { spawnSyncImpl: () => ({ status: 0, stdout: 'EXTERNAL-QR', stderr: '' }) }), true)
  assert.equal(external.text, 'EXTERNAL-QR\n')

  const bundled = collector()
  assert.equal(renderQrCode(uri, bundled, { spawnSyncImpl: () => ({ status: 127, stdout: '', stderr: '' }), ansi: false }), true)
  assert.match(bundled.text, /[▀▄█]/)
  assert.doesNotMatch(bundled.text, /未找到 qrencode/)
  assert.doesNotMatch(bundled.text, /无法在终端渲染二维码/)
})

test('resolvePairTarget matches exact machineId, name and normalized fingerprint', () => {
  const status = statusWithPairs()
  assert.equal(resolvePairTarget(status, 'iPhone').peerName, 'iPhone')
  assert.equal(resolvePairTarget(status, 'gewra3lzquaxpctdtkvzv2drdp').peerName, 'iPhone')
  assert.equal(resolvePairTarget(status, 'GEWR A3LZ QUAX').peerName, 'iPhone')
  assert.throws(() => resolvePairTarget(status, 'unknown'), error => error.code === 'bad_frame')
  const ambiguous = { ...status, pairs: [{ ...status.pairs[0], peerMachineId: 'gewra3lzquaxpctdtkvzv2drdp' }, { ...status.pairs[0], peerMachineId: 'gewrzzzzquaxpctdtkvzv2drdp' }] }
  ambiguous.pairs[1].peerName = 'iPhone'
  assert.throws(() => resolvePairTarget(ambiguous, 'iPhone'), error => error.code === 'bad_frame')
})

test('runUnpair requires a TTY, a typed yes and sends one machineId or all', async () => {
  const output = collector()
  const calls = []
  const client = {
    unpair: async target => { calls.push(target); return { v: 1, removed: target.all === true ? ['a', 'b'] : [target.peerMachineId] } },
  }
  await assert.rejects(() => runUnpair({ client, status: statusWithPairs(), all: true, output, stdinIsTTY: false, confirm: async () => 'yes' }), error => error.code === 'unavailable')
  await assert.rejects(() => runUnpair({ client, status: statusWithPairs(), target: 'iPhone', output, stdinIsTTY: true, confirm: async () => 'no' }), error => error.code === 'unavailable')
  assert.deepEqual(calls, [])
  const result = await runUnpair({ client, status: statusWithPairs(), target: 'iPhone', output, stdinIsTTY: true, confirm: async () => 'yes' })
  assert.deepEqual(result.removed, ['gewra3lzquaxpctdtkvzv2drdp'])
  assert.deepEqual(calls[0], { peerMachineId: 'gewra3lzquaxpctdtkvzv2drdp' })
  await runUnpair({ client, status: statusWithPairs(), all: true, output, stdinIsTTY: true, confirm: async () => 'yes' })
  assert.deepEqual(calls[1], { all: true })
  assert.match(output.text, /先解除全部配对，再运行 pclink rotate-identity/)
})

test('runRotateIdentity requires the literal phrase', async () => {
  const output = collector()
  let called = 0
  const client = { rotateIdentity: async confirm => { called += 1; return { v: 1, rotated: true, oldMachineId: 'a', newMachineId: 'b', confirm } } }
  await assert.rejects(() => runRotateIdentity({ client, output, stdinIsTTY: false, ask: async () => 'rotate-identity' }), error => error.code === 'unavailable')
  await assert.rejects(() => runRotateIdentity({ client, output, stdinIsTTY: true, ask: async () => 'no' }), error => error.code === 'unavailable')
  const result = await runRotateIdentity({ client, output, stdinIsTTY: true, ask: async () => 'rotate-identity' })
  assert.equal(result.rotated, true)
  assert.equal(called, 1)
  assert.match(output.text, /每台手机都必须重新配对/)
})

test('printStatus lists pairs, redacted pending state and warnings', () => {
  const output = collector()
  printStatus(statusWithPairs({ pairing: { id: 'p', state: 'awaiting_approval', mode: 'qr', expiresAt: 'x', peerName: 'iPhone' }, warnings: ['最近配对：iPhone'] }), output)
  assert.match(output.text, /gewr-a3lz-quax/)
  assert.match(output.text, /旧版 PC 流程等待本机操作员确认，手机名称 iPhone/)
  assert.equal(output.text.includes('peerFingerprint'), false)
  assert.match(output.text, /警告：最近配对/)
})

test('findDsh finds PATH, DSH_BIN and source checkouts', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pclink-cli-'))
  const bin = join(directory, 'dsh')
  writeFileSync(bin, '#!/bin/sh\n')
  chmodSync(bin, 0o755)
  const byPath = findDsh({ env: { PATH: directory } })
  assert.equal(byPath.command, bin)
  assert.equal(byPath.source, 'path')
  assert.equal(findDsh({ env: { PATH: '', DSH_BIN: '/x/dsh' } }).source, 'env')
  const source = mkdtempSync(join(tmpdir(), 'pclink-src-'))
  mkdirSync(join(source, 'apps', 'cli', 'lib'), { recursive: true })
  writeFileSync(join(source, 'apps', 'cli', 'lib', 'bin.js'), '')
  const bySource = findDsh({ env: { PATH: '', DSH_SOURCE: source } })
  assert.equal(bySource.source, 'source')
  assert.deepEqual(bySource.args, [join(source, 'apps', 'cli', 'lib', 'bin.js')])
  assert.throws(() => findDsh({ env: { PATH: '', DSH_SOURCE: '/nonexistent' } }), error => error.code === 'unavailable')
})

test('checkDshVersion enforces the tested range', () => {
  const spawn = result => () => result
  const dsh = { command: 'dsh', args: [] }
  assert.equal(checkDshVersion(dsh, { spawnSyncImpl: spawn({ status: 0, stdout: '0.2.2-rc.1\n', stderr: '' }) }), '0.2.2-rc.1')
  assert.throws(() => checkDshVersion(dsh, { spawnSyncImpl: spawn({ status: 0, stdout: '0.3.0\n', stderr: '' }) }), error => error.code === 'version_unsupported')
  assert.throws(() => checkDshVersion(dsh, { spawnSyncImpl: spawn({ status: 1, stdout: '', stderr: 'boom' }) }), error => error.code === 'unavailable')
})

test('checkNativeModule finds the host system.node beside a source checkout', () => {
  const root = mkdtempSync(join(tmpdir(), 'pclink-native-'))
  const path = join(root, 'native', 'system', 'packages', 'darwin-arm64', 'bin', 'system.node')
  mkdirSync(join(path, '..'), { recursive: true })
  writeFileSync(path, '')
  assert.equal(checkNativeModule({ root, source: 'source' }, { platform: 'darwin', arch: 'arm64' }).ok, true)
  assert.equal(checkNativeModule({ root, source: 'source' }, { platform: 'linux', arch: 'x64' }).ok, false)
  assert.equal(checkNativeModule({ command: 'dsh', args: [], source: 'path' }).ok, true)
})

test('defaultInstallSpec honors PCLINK_PLUGIN_SPEC and falls back to this checkout', () => {
  assert.equal(defaultInstallSpec({ env: { PCLINK_PLUGIN_SPEC: 'github:o/r#abc&path:/pclink' } }), 'github:o/r#abc&path:/pclink')
  const local = defaultInstallSpec({ env: {} })
  assert.match(local, /pclink$/)
})

test('packageSha256 is deterministic and content-sensitive', () => {
  const left = mkdtempSync(join(tmpdir(), 'pclink-hash-a-'))
  const right = mkdtempSync(join(tmpdir(), 'pclink-hash-b-'))
  for (const root of [left, right]) {
    mkdirSync(join(root, 'core'))
    writeFileSync(join(root, 'package.json'), '{"name":"x"}')
    writeFileSync(join(root, 'core', 'a.mjs'), 'export const a = 1\n')
  }
  assert.equal(packageSha256(left), packageSha256(right))
  writeFileSync(join(right, 'core', 'a.mjs'), 'export const a = 2\n')
  assert.notEqual(packageSha256(left), packageSha256(right))
})

test('runInstall checks dsh, adds the spec, waits for health and pairs', async () => {
  const output = collector()
  const calls = []
  const dsh = { command: 'dsh', args: [], source: 'path' }
  const result = await runInstall({
    dshHome: '/tmp/dsh-home',
    output,
    ask: async prompt => { calls.push(['ask', prompt]); return 'n' },
    spec: '/local/pclink',
    pair: async options => { calls.push(['pair', options.mode]); return statusWithPairs() },
    env: {},
    findDshImpl: () => dsh,
    spawnSyncImpl: (command, args) => {
      calls.push(['spawn', command, ...args])
      if (args.includes('-V')) return { status: 0, stdout: '0.2.2-rc.1\n', stderr: '' }
      return { status: 0, stdout: '', stderr: '' }
    },
    waitForPluginImpl: async () => { calls.push(['wait']); return statusWithPairs() },
    spawnImpl: () => { throw new Error('must not restart') },
  })
  assert.equal(result.version, '0.2.2-rc.1')
  assert.equal(result.spec, '/local/pclink')
  assert.match(result.sha256, /^[0-9a-f]{64}$/)
  assert.deepEqual(calls.filter(call => call[0] === 'pair'), [['pair', 'qr']])
  const add = calls.find(call => call[0] === 'spawn' && call.includes('add'))
  assert.ok(add)
  assert.ok(add.includes('--profile'))
  assert.ok(add.includes('web'))
  assert.ok(add.includes('/local/pclink'))
  assert.match(output.text, /包 SHA-256：[0-9a-f]{64}/)
  assert.match(output.text, /构建脚本审批/)
  assert.match(output.text, /此手机将能完整操作/)
})

test('addPlugin reports a failed dsh plugin add', () => {
  assert.throws(() => {
    const output = collector()
    const result = addPlugin({ command: 'dsh', args: [] }, 'spec', { output, spawnSyncImpl: () => ({ status: 3 }) })
    if (result.status !== 0) throw Object.assign(new Error('failed'), { status: result.status })
  }, error => error.status === 3)
})

test('waitForPlugin retries until the proof challenge succeeds', async () => {
  let calls = 0
  const client = {
    status: async () => {
      calls += 1
      if (calls < 3) throw Object.assign(new Error('not yet'), { code: 'unavailable' })
      return statusWithPairs()
    },
  }
  const status = await waitForPlugin('/tmp/dsh-home', { timeoutMs: 1_000, pollMs: 1, clientFactory: () => client })
  assert.equal(status.v, 1)
  assert.equal(calls, 3)
})

test('createCliAdminClient points at $DSH_HOME/pclink', () => {
  const client = createCliAdminClient('/tmp/home')
  assert.equal(client.dir, '/tmp/home/pclink')
})
