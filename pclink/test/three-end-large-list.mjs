#!/usr/bin/env node
/**
 * Three-end pacing regression (P28, pclink-v1.5): real relay (default pair
 * limits) + real DSH 0.2.2 + the PC plugin + the Node PhonePeer.
 *
 * The script starts both servers on the dedicated test ports (3280 relay,
 * 3281 DSH web), uses a throwaway DSH_HOME with only `.credentials.yaml`
 * copied (0600, never printed), pairs a test phone through the loopback admin
 * API, creates enough DSH sessions that `session/list` exceeds 6 MiB, and
 * asserts the phone reassembled the complete list while the relay logged no
 * `frame.dropped`. Ports 3080/3270 and the user's `dsh-data` are never touched.
 *
 * Usage: node pclink/test/three-end-large-list.mjs
 * Env: PCLINK_E2E_SESSIONS (default 8200), PCLINK_KEEP_E2E=1 (leave servers
 *      running for screenshots; prints the room/log paths).
 */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import {
  chmodSync, copyFileSync, createWriteStream, existsSync, mkdirSync, mkdtempSync, readFileSync,
  rmSync, writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { AdminClient } from '../core/admin.mjs'
import { generateIdentity } from '../core/identity.mjs'
import { fingerprintOf } from '../core/encoding.mjs'
import { PhonePeer } from './phone-peer.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const PCLINK = resolve(HERE, '..')
const ROOT = resolve(PCLINK, '..')
const DSH_PIN = process.env.DSH_PIN_ROOT ?? '/private/tmp/dsh-0.2.2'
const DSH_BIN = join(DSH_PIN, 'apps', 'cli', 'lib', 'bin.js')
const CREDENTIALS = join(ROOT, '.spike', 'home', '.credentials.yaml')
const RELAY_PORT = Number(process.env.PCLINK_E2E_RELAY_PORT ?? 3280)
const WEB_PORT = Number(process.env.PCLINK_E2E_WEB_PORT ?? 3281)
const SESSION_TARGET = Number(process.env.PCLINK_E2E_SESSIONS ?? 8200)
const KEEP = process.env.PCLINK_KEEP_E2E === '1'
const ORIGIN = `http://127.0.0.1:${RELAY_PORT}`

if (!existsSync(DSH_BIN)) throw new Error(`missing pinned DSH at ${DSH_BIN}`)
if (!existsSync(CREDENTIALS)) throw new Error('missing .spike/home/.credentials.yaml')

const room = mkdtempSync(join(tmpdir(), 'pclink-pacing-e2e-'))
const home = join(room, 'home')
const work = join(room, 'work')
const work2 = join(room, 'work2')
mkdirSync(home, { recursive: true })
mkdirSync(work, { recursive: true })
mkdirSync(work2, { recursive: true })
copyFileSync(CREDENTIALS, join(home, '.credentials.yaml'))
chmodSync(join(home, '.credentials.yaml'), 0o600)
const logPath = join(room, 'relay.log')
const relayOut = createWriteStream(logPath)
relayOut.write('')

function delay(ms) { return new Promise(resolveDelay => setTimeout(resolveDelay, ms)) }

async function waitFor(predicate, label, timeoutMs = 60_000, intervalMs = 150) {
  const deadline = Date.now() + timeoutMs
  let last
  while (Date.now() < deadline) {
    try {
      const value = await predicate()
      if (value !== undefined && value !== false) return value
    } catch (error) { last = error }
    await delay(intervalMs)
  }
  throw new Error(`timed out waiting for ${label}${last === undefined ? '' : `: ${last.message}`}`)
}

const relay = spawn(process.execPath, [join(ROOT, 'relay', 'relay.mjs'), '--host', '127.0.0.1', '--port', String(RELAY_PORT)], {
  cwd: ROOT,
  detached: true,
  env: { ...process.env, PCLINK_PUBLIC_ORIGIN: ORIGIN },
  stdio: ['ignore', 'pipe', 'pipe'],
})
relay.stdout.pipe(relayOut)
relay.stderr.pipe(relayOut)

const patchPath = join(home, 'pacing.patch.yml')
writeFileSync(patchPath, [
  '- insert:',
  '    - id: pclink-e2e',
  `      name: '${join(PCLINK, 'plugin', 'index.js')}'`,
  '      config:',
  `        relayUrl: '${ORIGIN}'`,
  "        name: 'Pacing E2E PC'",
  '',
].join('\n'))
const dsh = spawn(process.execPath, [DSH_BIN, 'web', '--patch', patchPath, '--no-open', '--port', String(WEB_PORT)], {
  cwd: ROOT,
  detached: true,
  env: { ...process.env, DSH_HOME: home, DSH_PERMISSION_MODE: 'workspace-write' },
  stdio: ['ignore', 'pipe', 'pipe'],
})
const dshLog = join(room, 'dsh.log')
const dshOut = createWriteStream(dshLog)
dshOut.write('')
dsh.stdout.pipe(dshOut)
dsh.stderr.pipe(dshOut)

let phone
let evidence
try {
  await waitFor(async () => (await fetch(`${ORIGIN}/healthz`)).ok, 'relay healthz', 20_000)
  const client = new AdminClient({ dir: join(home, 'pclink') })
  await waitFor(async () => {
    const status = await client.status()
    return status.relay.state === 'connected' ? status : undefined
  }, 'plugin relay connection', 120_000)

  const identity = generateIdentity()
  phone = new PhonePeer({ origin: ORIGIN, identity })
  await phone.connect()
  const pairing = await client.pair({ mode: 'qr' })
  const phonePairing = phone.pairWithQr(pairing.pairing.qrURI)
  await waitFor(async () => {
    const status = await client.status()
    return status.pairing?.state === 'awaiting_approval' ? status : undefined
  }, 'awaiting approval', 20_000)
  const approved = await client.approve(pairing.pairing.id, fingerprintOf(identity.machineId))
  assert.equal(approved.approved, true, approved.error?.code ?? 'pairing approval failed')
  await phonePairing
  await phone.handshake()

  const workspaceA = await phone.call('workspace/create', { request: { path: work } }, 30_000)
  const workspaceB = await phone.call('workspace/create', { request: { path: work2 } }, 30_000)
  assert.ok(workspaceA.workspace?.workspaceId)
  assert.ok(workspaceB.workspace?.workspaceId)
  // A second, smaller group so the PC workspace picker/drawer has real DSH
  // titles; the bulk stays in the first workspace.
  for (let index = 0; index < 5; index += 1) {
    await phone.call('session/create', { request: { workspaceId: workspaceB.workspace.workspaceId } }, 30_000)
  }

  const before = await phone.call('session/list', { _request: {} }, 60_000)
  const need = Math.max(0, SESSION_TARGET - before.items.length)
  const batchSize = 25
  const started = Date.now()
  for (let offset = 0; offset < need; offset += batchSize) {
    const count = Math.min(batchSize, need - offset)
    await Promise.all(Array.from({ length: count }, () =>
      phone.call('session/create', { request: { workspaceId: workspaceA.workspace.workspaceId } }, 60_000)))
  }
  const createdMs = Date.now() - started
  phone.resultChunkFrames = 0
  phone.resultChunkChars = 0
  const listStarted = Date.now()
  const list = await phone.call('session/list', { _request: {} }, 180_000)
  const listMs = Date.now() - listStarted
  const listBytes = Buffer.byteLength(JSON.stringify(list), 'utf8')
  assert.ok(list.items.length >= SESSION_TARGET, `expected >= ${SESSION_TARGET} sessions, saw ${list.items.length}`)
  assert.ok(listBytes > 6 * 1024 * 1024, `session/list must exceed 6 MiB, saw ${listBytes}`)
  assert.ok(phone.resultChunkFrames >= 2, `expected chunked result, saw ${phone.resultChunkFrames} chunks`)
  // Let the relay's log stream flush before scanning for dropped frames.
  await delay(300)
  const relayText = readFileSync(logPath, 'utf8')
  assert.equal((relayText.match(/"event":"frame\.dropped"/g) ?? []).length, 0,
    'the relay must not drop a paced frame')
  assert.equal(phone.lastRelayError, undefined, 'the phone must not receive relay.error')
  assert.equal(phone.closed, false)
  evidence = {
    sessions: list.items.length,
    listBytes,
    chunks: phone.resultChunkFrames,
    chunkChars: phone.resultChunkChars,
    listMs,
    createSessionsMs: createdMs,
    relay: ORIGIN,
    workspaces: [workspaceA.workspace.title, workspaceB.workspace.title],
  }
  console.log(JSON.stringify({ ok: true, ...evidence, room, relayLogPaths: { dsh: dshLog } }, null, 2))
} finally {
  if (KEEP) {
    console.log(`[three-end] KEEP=1: relay pid=${relay.pid} dsh pid=${dsh.pid}, DSH_HOME=${home}`)
    // Stay alive so the spawned detached servers keep running for screenshots.
    await new Promise(() => {})
  } else {
    await phone?.close().catch(() => {})
    try { process.kill(-dsh.pid, 'SIGTERM') } catch { /* already gone */ }
    try { process.kill(-relay.pid, 'SIGTERM') } catch { /* already gone */ }
    await delay(800)
    rmSync(room, { recursive: true, force: true })
    console.log('[three-end] cleaned up processes and the temporary DSH_HOME')
  }
}
