// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  captureLogger,
  connectClient,
  createIdentity,
  e2eFrame,
  randomSid,
  startRelay,
} from './helpers.mjs'

const RELAY_ROOT = fileURLToPath(new URL('..', import.meta.url))

function relaySourceFiles() {
  const files = [join(RELAY_ROOT, 'relay.mjs')]
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const full = join(directory, entry.name)
      if (entry.isDirectory()) visit(full)
      else if (entry.isFile() && entry.name.endsWith('.mjs')) files.push(full)
    }
  }
  visit(join(RELAY_ROOT, 'src'))
  return files
}

test('static assertion: relay runtime sources do not import fs or call file-write APIs', () => {
  const forbidden = [
    /from\s+['"]node:fs(?:\/promises)?['"]/,
    /from\s+['"]fs(?:\/promises)?['"]/,
    /require\(\s*['"]node:fs/,
    /require\(\s*['"]fs/,
    /\bwriteFile(?:Sync)?\b/,
    /\bappendFile(?:Sync)?\b/,
    /\bcreateWriteStream\b/,
    /\bmkdir(?:Sync)?\b/,
    /\bopenSync\b/,
    /\brename(?:Sync)?\b/,
    /\bunlink(?:Sync)?\b/,
    /\brm(?:Sync)?\b/,
    /\btruncate(?:Sync)?\b/,
  ]
  for (const file of relaySourceFiles()) {
    const text = fs.readFileSync(file, 'utf8')
    for (const pattern of forbidden) {
      assert.equal(
        pattern.test(text),
        false,
        `${file} matches forbidden runtime file operation ${pattern}`,
      )
    }
    // The relay is self-contained: no pclink/core import and no SAS.
    assert.equal(/from\s+['"][^'"]*pclink\/core/.test(text), false, `${file} imports pclink/core`)
    assert.equal(/\bSAS\b/i.test(text), false, `${file} references a SAS`)
  }
})

test('runtime assertion: a full auth/route/pair cycle performs no fs writes and logs only metadata', async t => {
  const capture = captureLogger()
  const relay = await startRelay({ logger: capture.logger })
  t.after(() => relay.close())
  const pcIdentity = createIdentity()
  const phoneIdentity = createIdentity()
  const { client: pc } = await connectClient({ relay, identity: pcIdentity, role: 'pc' })
  const { client: phone } = await connectClient({ relay, identity: phoneIdentity, role: 'phone' })
  t.after(() => {
    pc.close()
    phone.close()
  })
  pc.send({ v: 1, type: 'relay.allow', peers: [phoneIdentity.machineId] })

  const calls = []
  const patches = []
  const patch = (object, name) => {
    const original = object[name]
    if (typeof original !== 'function') return
    object[name] = (...args) => {
      calls.push(`${name}(${args.length})`)
      throw new Error(`unexpected fs write via ${name}`)
    }
    patches.push(() => { object[name] = original })
  }
  try {
    for (const name of [
      'writeFileSync', 'appendFileSync', 'openSync', 'createWriteStream', 'mkdirSync',
      'renameSync', 'unlinkSync', 'rmSync',
    ]) patch(fs, name)
    for (const name of [
      'writeFile', 'appendFile', 'open', 'createWriteStream', 'mkdir',
      'rename', 'unlink', 'rm',
    ]) patch(fsp, name)

    const rendezvous = 'P'.repeat(22)
    pc.send({ v: 1, type: 'relay.pair.open', rendezvous })
    phone.send({ v: 1, type: 'relay.pair.join', rendezvous })
    await pc.next('relay.pair.joined')
    await phone.next('relay.pair.joined')
    const payload = { hello: 'PAIR_PAYLOAD_MARKER' }
    phone.send({ v: 1, type: 'relay.pair.message', rendezvous, payload })
    await pc.next('relay.pair.message')
    phone.send({ v: 1, type: 'relay.pair.close', rendezvous, reason: 'paired' })
    await pc.next('relay.pair.close')

    const body = 'E2E_BODY_MARKER'.padEnd(22, 'A')
    phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: randomSid(), body }))
    await pc.next('e2e')

    const health = await fetch(`http://127.0.0.1:${relay.port}/healthz`)
    assert.equal(health.status, 200)
    assert.deepEqual(await health.json(), { ok: true })
  } finally {
    for (const restore of patches.reverse()) restore()
  }

  assert.deepEqual(calls, [])
  const logText = capture.text()
  assert.equal(logText.includes(pcIdentity.machineId), false)
  assert.equal(logText.includes(phoneIdentity.machineId), false)
  assert.equal(logText.includes('P'.repeat(22)), false)
  assert.equal(logText.includes('PAIR_PAYLOAD_MARKER'), false)
  assert.equal(logText.includes('E2E_BODY_MARKER'), false)
  assert.equal(logText.includes('frame.forwarded'), true)
  assert.equal(logText.includes('peer.ready'), true)
})
