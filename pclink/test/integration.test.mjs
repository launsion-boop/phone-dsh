/**
 * Real-DSH integration for PCLink C (P28).
 *
 * Requires the pinned DSH checkout (default /private/tmp/dsh-0.2.2) and
 * `.spike/home/.credentials.yaml`. Every run creates a fresh DSH_HOME under
 * `.spike/`, copies only the credentials file (mode 0600), removes the
 * directory afterwards, and never prints its contents. The relay is the local
 * test double; the phone is the core-based test client.
 *
 * The model-dependent prompt/approval steps live in their own subtest and are
 * skipped by `PCLINK_SKIP_MODEL=1`; every other integration step still runs.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import {
  chmodSync,
  copyFileSync,
  createWriteStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomUUID } from 'node:crypto'
import { generateIdentity } from '../core/identity.mjs'
import { AdminClient } from '../core/admin.mjs'
import { fingerprintOf } from '../core/encoding.mjs'
import { runPair, runUnpair } from '../cli/commands.mjs'
import { RelayStub } from './relay-stub.mjs'
import { PhonePeer } from './phone-peer.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const PCLINK = resolve(HERE, '..')
const ROOT = resolve(PCLINK, '..')
const SPIKE = join(ROOT, '.spike')
const DSH_PIN = process.env.DSH_PIN_ROOT ?? '/private/tmp/dsh-0.2.2'
const DSH_BIN = join(DSH_PIN, 'apps', 'cli', 'lib', 'bin.js')
const CREDENTIALS = join(SPIKE, 'home', '.credentials.yaml')
const LOGS = join(SPIKE, 'pclink-c-integration')
const PLUGIN_INDEX = join(PCLINK, 'plugin', 'index.js')
const APPROVAL_POLICY = join(HERE, 'dsh-approval-policy.mjs')
const WORKSPACE = join(SPIKE, 'workspace')
const WEB_PORT = 3230
const MODEL_TIMEOUT_MS = 180_000
const SKIP_MODEL = process.env.PCLINK_SKIP_MODEL === '1'

const available = existsSync(DSH_BIN) && existsSync(CREDENTIALS)

function collector() {
  let text = ''
  return { write: chunk => { text += chunk }, get text() { return text } }
}

function delay(ms) {
  return new Promise(resolveDelay => setTimeout(resolveDelay, ms))
}

async function waitFor(predicate, label, timeoutMs = 30_000, intervalMs = 200) {
  const deadline = Date.now() + timeoutMs
  let lastError
  while (Date.now() < deadline) {
    try {
      const value = await predicate()
      if (value !== undefined && value !== false) return value
    } catch (error) {
      lastError = error
    }
    await delay(intervalMs)
  }
  throw new Error(`timed out waiting for ${label}${lastError === undefined ? '' : `: ${lastError.message}`}`)
}

function pluginLogTail(logPath) {
  try {
    return readFileSync(logPath, 'utf8').split('\n').filter(line => line.includes('[pclink]') || line.includes('[integration-policy]')).slice(-40).join('\n')
  } catch {
    return ''
  }
}

/**
 * Create the per-run DSH_HOME and copy only the managed credentials document.
 * The directory is 0700 (mkdtemp) and the copy is forced to 0600; neither the
 * file nor its contents are ever printed.
 * @returns {string} fresh DSH_HOME path.
 */
function freshDshHome() {
  mkdirSync(SPIKE, { recursive: true })
  const home = mkdtempSync(join(SPIKE, 'dsh-home-'))
  try {
    const credentials = join(home, '.credentials.yaml')
    copyFileSync(CREDENTIALS, credentials)
    chmodSync(credentials, 0o600)
    const mode = statSync(credentials).mode & 0o777
    if (mode !== 0o600) throw new Error(`copied credentials mode is ${mode.toString(8)}, expected 600`)
    return home
  } catch (error) {
    rmSync(home, { recursive: true, force: true })
    throw error
  }
}

async function readTurn(stream, afterSeq, label, timeoutMs = MODEL_TIMEOUT_MS) {
  const seen = { events: [], chunks: 0, assistantText: '', turnStart: false, toolCalls: [], toolResults: [], turnEnd: false, turnEndSeq: undefined }
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const remaining = deadline - Date.now()
    if (remaining <= 0) throw new Error(`${label}: no turn/end (saw ${seen.events.join(',')})`)
    const item = await stream.next(remaining, `${label} follow item`)
    if (item.type === 'session.close') throw new Error(`${label}: session closed ${item.code}`)
    if (item.type === 'error') throw new Error(`${label}: stream error ${item.error?.code}: ${item.error?.message}`)
    if (item.type !== 'item') continue
    const frame = item.value
    if (frame?.type === 'assistant-stream') { seen.chunks += 1; continue }
    if (frame?.type !== 'event') continue
    const event = frame.event
    if (event.seq !== undefined && event.seq <= afterSeq) continue
    seen.events.push(event.type)
    if (event.type === 'turn/start') seen.turnStart = true
    if (event.type === 'assistant/message') {
      const text = (event.data?.message?.content ?? []).filter(part => part?.type === 'text').map(part => part.text).join('')
      if (text !== '') seen.assistantText = text.slice(0, 500)
    }
    if (event.type === 'tool/call') seen.toolCalls.push({ name: event.data?.name })
    if (event.type === 'tool/result') {
      const content = event.data?.message?.content ?? event.data?.content ?? []
      const text = Array.isArray(content) ? content.filter(part => part?.type === 'text').map(part => part.text).join('') : ''
      seen.toolResults.push({ text, isError: event.data?.isError })
    }
    if (event.type === 'turn/end') {
      seen.turnEnd = true
      seen.turnEndSeq = event.seq
      return seen
    }
  }
}

test('PCLink C integration: pair, handshake, DSH calls/streams/prompt/approval, cancel, remote admin ban and unpair', { timeout: 900_000, skip: !available && `missing ${DSH_BIN} or ${CREDENTIALS}` }, async t => {
  mkdirSync(SPIKE, { recursive: true })
  rmSync(LOGS, { recursive: true, force: true })
  mkdirSync(LOGS, { recursive: true })
  mkdirSync(WORKSPACE, { recursive: true })
  const DSH_HOME = freshDshHome()
  console.log(`[integration] fresh DSH_HOME=${DSH_HOME} (credentials copied with mode 0600)`)
  if (SKIP_MODEL) console.log('[integration] SKIP model-dependent subtest: PCLINK_SKIP_MODEL=1')

  const webLog = join(LOGS, 'web.log')
  const clientLog = join(LOGS, 'client.log')
  const relay = new RelayStub()
  let webProcess
  let phone
  let client
  let phoneIdentity
  let pairedStatus
  let created
  let cliOutputText = ''
  try {
    await relay.start()
    console.log(`[integration] relay ${relay.origin}`)
    const patch = [
      '# Generated by pclink/test/integration.test.mjs — runtime only, gitignored.',
      '- insert:',
      '    - id: pclink-integration',
      `      name: '${PLUGIN_INDEX}'`,
      '      config:',
      `        relayUrl: '${relay.wsUrl()}'`,
      "        name: 'Integration PC'",
      '    - id: pclink-test-approval-policy',
      `      name: '${APPROVAL_POLICY}'`,
      '',
      '# The test host has no usable sandbox-exec backend, so the pinned session',
      '# runs unconfined while the composed approval policy stays `ask` and the',
      '# test-only pre-execute policy asks for every bash call.',
      '- id: permission',
      '  config:',
      '    presets:',
      '      integration-full-access-ask:',
      '        sandbox: danger-full-access',
      '        approval: ask',
      '    defaultPreset: integration-full-access-ask',
      '',
    ].join('\n')
    const patchPath = join(DSH_HOME, 'integration.patch.yml')
    writeFileSync(patchPath, patch)
    const logStream = createWriteStream(webLog)
    webProcess = spawn(process.execPath, [DSH_BIN, 'web', '--patch', patchPath, '--no-open', '--port', String(WEB_PORT)], {
      cwd: ROOT,
      env: { ...process.env, DSH_HOME, DSH_PERMISSION_MODE: 'workspace-write' },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    webProcess.stdout.pipe(logStream, { end: false })
    webProcess.stderr.pipe(logStream, { end: false })
    client = new AdminClient({ dir: join(DSH_HOME, 'pclink') })
    let status
    try {
      status = await waitFor(async () => {
        if (webProcess.exitCode !== null) throw new Error(`dsh web exited ${String(webProcess.exitCode)}`)
        const current = await client.status()
        return current.relay.state === 'connected' ? current : undefined
      }, 'plugin relay connection', 120_000, 500)
    } catch (error) {
      throw new Error(`${error.message}\nplugin log:\n${pluginLogTail(webLog)}`)
    }
    console.log(`[integration] plugin up relay=${status.relay.state} pc=${status.identity.machineId}`)
    phoneIdentity = generateIdentity()
    phone = new PhonePeer({ origin: relay.origin, identity: phoneIdentity, log: line => console.log(`[phone] ${line}`) })
    await phone.connect()
    console.log(`[integration] phone relay ready ${phoneIdentity.machineId}`)

    await t.test('pairing, owner admin route, handshake and session bootstrap', async () => {
      // 1. A wrong fingerprint destroys the slot and never writes a record.
      const firstPair = await client.pair({ mode: 'qr' })
      const firstPhonePair = phone.pairWithQr(firstPair.pairing.qrURI).then(() => 'paired', error => error.code ?? error.message)
      const awaiting = await waitFor(async () => {
        const current = await client.status()
        return current.pairing?.state === 'awaiting_approval' ? current : undefined
      }, 'awaiting_approval', 30_000, 100)
      assert.equal(awaiting.pairing.peerName, 'Test iPhone')
      for (const forbidden of ['peerMachineId', 'peerFingerprint', 'peerPublicKey']) {
        assert.equal(JSON.stringify(awaiting).includes(forbidden), false, forbidden)
      }
      const wrong = await client.approve(firstPair.pairing.id, '2222-2222-2222')
      assert.equal(wrong.approved, false)
      assert.equal(wrong.error.code, 'auth_failed')
      assert.equal(await firstPhonePair, 'auth_failed')
      assert.equal((await client.status()).pairs.length, 0)
      console.log('[integration] wrong-fingerprint approval voided the slot')

      // 2. Pair through the real TTY-gated CLI path; the injected ask stands in for the operator.
      let started
      let startedResolve
      const startedPromise = new Promise(resolveStarted => { startedResolve = resolveStarted })
      const cliOutput = collector()
      const wrapped = {
        pair: async options => { started = await client.pair(options); startedResolve(started); return started },
        status: () => client.status(),
        approve: (id, fingerprint) => client.approve(id, fingerprint),
        cancel: (id, rejected) => client.cancel(id, rejected),
      }
      const pairPromise = runPair({
        client: wrapped,
        mode: 'qr',
        output: cliOutput,
        stdinIsTTY: true,
        pollMs: 100,
        ask: async () => fingerprintOf(phoneIdentity.machineId),
      })
      await startedPromise
      const phonePair = await phone.pairWithQr(started.pairing.qrURI).catch(error => {
        throw new Error(`phone pairing failed: ${error.message}\nCLI:\n${cliOutput.text}`)
      })
      await pairPromise
      pairedStatus = await client.status()
      assert.equal(pairedStatus.pairs.length, 1)
      assert.equal(pairedStatus.pairs[0].peerMachineId, phoneIdentity.machineId)
      assert.match(cliOutput.text, /配对完成/)
      cliOutputText = cliOutput.text
      console.log(`[integration] pairing completed via CLI (${phonePair.record.peerName})`)

      // Real CLI status against the loopback admin API.
      const cliStatus = spawnSync(process.execPath, [join(PCLINK, 'cli', 'bin.mjs'), 'status'], {
        env: { ...process.env, DSH_HOME },
        encoding: 'utf8',
        timeout: 20_000,
      })
      assert.equal(cliStatus.status, 0, cliStatus.stderr)
      assert.match(cliStatus.stdout, /已配对手机/)
      assert.match(cliStatus.stdout, new RegExp(phoneIdentity.machineId))

      // 3. E2E handshake with the pinned QR key, then real DSH calls.
      await phone.handshake()
      const list = await phone.call('session/list', { _request: {} }, 30_000)
      assert.equal(Array.isArray(list.items), true)
      assert.equal(list.items.length, 0, 'a fresh DSH_HOME must not contain prior sessions')
      created = await phone.call('session/create', { request: { cwd: WORKSPACE } }, 30_000)
      assert.equal(typeof created.sessionId, 'string')
      console.log(`[integration] session/list items=${String(list.items.length)} created=${created.sessionId}`)

      // 4. Real owner route through DSH's browser/API authentication (the page path).
      const launch = await waitFor(() => {
        const text = readFileSync(webLog, 'utf8')
        const match = /dsh web: (https?:\/\/[^\s]+)/.exec(text)
        return match === null ? undefined : match[1]
      }, 'dsh web launch URL', 30_000, 200)
      const launchUrl = new URL(launch)
      const connectUrl = new URL('/connect', launchUrl.origin)
      connectUrl.searchParams.set('token', launchUrl.searchParams.get('token'))
      connectUrl.searchParams.set('interactions', 'none')
      const connectResponse = await fetch(connectUrl, { redirect: 'manual' })
      const cookies = connectResponse.headers.getSetCookie?.() ?? []
      if (connectResponse.status === 302 && cookies.length > 0) {
        const cookie = cookies[0].split(';', 1)[0]
        const adminResponse = await fetch(new URL('/api/pclink.admin/status', launchUrl.origin), {
          method: 'POST',
          headers: { cookie, 'content-type': 'application/json', origin: launchUrl.origin },
          body: '{}',
        })
        assert.equal(adminResponse.status, 200)
        const adminBody = await adminResponse.json()
        assert.equal(adminBody.identity.machineId, pairedStatus.identity.machineId)
        console.log('[integration] DSH owner /api/pclink.admin/status returned the status body')
      } else {
        console.log(`[integration] owner route skipped: /connect ${String(connectResponse.status)} cookies=${String(cookies.length)}`)
      }
    })

    await t.test('model-dependent: prompt turn, duplicate requestId and bash approval', {
      timeout: 300_000,
      skip: SKIP_MODEL ? 'PCLINK_SKIP_MODEL=1' : false,
    }, async () => {
      const events = phone.openStream('$events', { args: {} })
      const readyEntry = await events.until(value => value.type === 'item' && value.value.type === 'ready', 20_000, '$events ready')
      const ready = readyEntry.value
      assert.equal(typeof ready.clientId, 'string')
      const answered = []
      let approvalsStopped = false
      const approvalLoop = (async () => {
        for (;;) {
          if (approvalsStopped) return
          const entry = await events.next(120_000, 'approval waterfall')
          if (entry.type === 'end' || entry.type === 'error' || entry.type === 'session.close') return
          if (entry.type !== 'item') continue
          const frame = entry.value
          if (frame.type !== 'waterfall' || frame.event !== 'approval/request') continue
          const toolName = frame.request?.toolName
          console.log(`[integration] approval ${String(frame.eventId)} tool=${String(toolName)} reason=${String(frame.request?.reason ?? '')}`)
          const result = await phone.call('$events/result', {
            clientId: ready.clientId,
            eventId: frame.eventId,
            outcome: { kind: 'result', value: 'allowed-once' },
          }, 20_000)
          answered.push({ eventId: frame.eventId, toolName, result })
          console.log(`[integration] approval answered ${String(frame.eventId)} outcome=${JSON.stringify(result)}`)
        }
      })().catch(error => { if (!approvalsStopped) throw error })

      const follow = phone.openStream('session/follow', {
        args: { request: { address: { kind: 'session', sessionId: created.sessionId }, maxMessages: 1, assistantStream: true } },
      })
      try {
        const snapshotEntry = await follow.until(value => value.type === 'item' && value.value.type === 'snapshot', 20_000, 'session/follow snapshot')
        const snapshot = snapshotEntry.value
        const promptRequestId = `prompt-${randomUUID()}`
        const promptAccepted = await phone.call('session/prompt', {
          request: { requestId: promptRequestId, sessionId: created.sessionId, mode: 'queue', content: [{ type: 'text', text: '只回复 OK' }] },
        }, 30_000)
        assert.equal(promptAccepted.accepted, true)
        const turn = await readTurn(follow, snapshot.cursor, 'prompt OK turn')
        assert.equal(turn.turnEnd, true)
        assert.equal(turn.assistantText.length > 0, true)
        assert.equal(turn.turnStart, true)
        assert.equal(turn.chunks > 0, true)
        console.log(`[integration] prompt turn events=${turn.events.length} chunks=${String(turn.chunks)} text=${JSON.stringify(turn.assistantText)}`)

        // Same requestId is deduplicated by DSH: no second turn/start.
        let duplicateTurn = false
        const secondAccepted = await phone.call('session/prompt', {
          request: { requestId: promptRequestId, sessionId: created.sessionId, mode: 'queue', content: [{ type: 'text', text: '只回复 OK' }] },
        }, 30_000)
        assert.equal(secondAccepted.accepted, true)
        const dedupeDeadline = Date.now() + 4_000
        while (Date.now() < dedupeDeadline) {
          try {
            const item = await follow.next(Math.max(1, dedupeDeadline - Date.now()), 'dedupe window')
            if (item.type === 'item' && item.value?.type === 'event' && item.value.event?.type === 'turn/start') {
              duplicateTurn = true
              break
            }
          } catch (error) {
            if (!/timed out/.test(error.message)) throw error
            break
          }
        }
        assert.equal(duplicateTurn, false)
        console.log('[integration] duplicate requestId produced no second turn/start')

        // The test-only policy asks for every bash call; answer the waterfall and
        // verify the tool actually ran and returned a result to the model.
        const followApproval = phone.openStream('session/follow', {
          args: { request: { address: { kind: 'session', sessionId: created.sessionId }, maxMessages: 1, assistantStream: true } },
        })
        const snapshotApprovalEntry = await followApproval.until(value => value.type === 'item' && value.value.type === 'snapshot', 20_000, 'approval follow snapshot')
        const snapshotApproval = snapshotApprovalEntry.value
        const approvalAccepted = await phone.call('session/prompt', {
          request: {
            requestId: `approval-${randomUUID()}`,
            sessionId: created.sessionId,
            mode: 'queue',
            content: [{ type: 'text', text: '请使用 bash 工具执行 date 命令并返回输出。本会话中每个 bash 调用都会请求审批；请等待审批通过后再继续，不要只回复文字。' }],
          },
        }, 30_000)
        assert.equal(approvalAccepted.accepted, true)
        const approvalTurn = await readTurn(followApproval, snapshotApproval.cursor, 'approval turn')
        assert.equal(approvalTurn.turnEnd, true)
        assert.ok(answered.length >= 1, `expected at least one answered approval; saw ${JSON.stringify(answered)}`)
        assert.ok(answered.some(entry => entry.toolName === 'bash'), `expected a bash approval; saw ${JSON.stringify(answered.map(entry => entry.toolName))}`)
        assert.equal(approvalTurn.toolCalls.some(call => call.name === 'bash'), true)
        assert.ok(approvalTurn.toolResults.length > 0, 'expected a bash tool result')
        assert.ok(approvalTurn.toolResults.some(result => result.isError !== true), `expected a successful bash result; saw ${JSON.stringify(approvalTurn.toolResults)}`)
        console.log(`[integration] approvals answered=${String(answered.length)} toolResults=${JSON.stringify(approvalTurn.toolResults.map(result => result.text.slice(0, 120)))}`)
      } finally {
        approvalsStopped = true
        try { events.cancel() } catch { /* stream already gone */ }
        await Promise.allSettled([approvalLoop])
      }
    })

    await t.test('stream cancel, remote admin fence, unpair and signed reject', async () => {
      // 5. Stream cancel: the PC aborts, returns the iterator and then sends end.
      const cancelStream = phone.openStream('session/follow', {
        args: { request: { address: { kind: 'session', sessionId: created.sessionId }, maxMessages: 1, assistantStream: true } },
      })
      await cancelStream.until(value => value.type === 'item' && value.value.type === 'snapshot', 20_000, 'cancel snapshot')
      cancelStream.cancel()
      const ended = await cancelStream.until(value => value.type === 'end' || value.type === 'error', 20_000, 'cancel end')
      assert.equal(ended.type, 'end')
      console.log('[integration] stream cancel returned end')

      // 6. PCLink admin is refused to the remote phone Peer.
      await assert.rejects(() => phone.call('pclink.admin/status', {}, 20_000), error => error.code === 'forbidden')
      const forbiddenStream = phone.openStream('pclink.admin/unpair', { args: {} })
      const forbiddenTerminal = await forbiddenStream.next(20_000, 'admin stream ban')
      assert.equal(forbiddenTerminal.type, 'error')
      assert.equal(forbiddenTerminal.error.code, 'forbidden')
      console.log('[integration] remote pclink.admin calls are forbidden')

      // 7. Authoritative unpair through the CLI, then the old session and a signed reject.
      const beforeUnpair = await client.status()
      const unpairOutput = collector()
      await runUnpair({
        client,
        status: beforeUnpair,
        target: 'Test iPhone',
        output: unpairOutput,
        stdinIsTTY: true,
        confirm: async () => 'yes',
      })
      const closed = await phone.inner.until(message => message.type === 'session.close', 20_000, 'session.close unpaired')
      assert.equal(closed.code, 'unpaired')
      assert.equal((await client.status()).pairs.length, 0)
      await waitFor(() => {
        const allow = relay.allowlists.get(pairedStatus.identity.machineId)
        return allow !== undefined && !allow.has(phoneIdentity.machineId)
      }, 'relay allowlist update', 20_000, 100)
      await assert.rejects(() => phone.call('session/list', { _request: {} }, 1_000), error => error.code === 'unavailable')
      const rejected = await phone.reconnectHandshakeExpectingReject()
      assert.equal(rejected.reject.code, 'unpaired')
      assert.equal(rejected.verified.code, 'unpaired')
      assert.ok(phone.record !== undefined, 'phone must not auto-delete its record')
      console.log('[integration] unpair closed the session, updated the allowlist and produced a signed unpaired reject')

      writeFileSync(clientLog, [
        cliOutputText,
        unpairOutput.text,
        `relay events: ${JSON.stringify(relay.events.slice(-10))}`,
      ].join('\n'))
    })
  } catch (error) {
    console.error(`[integration] FAILED: ${error.stack ?? error.message}`)
    console.error(`[integration] plugin log tail:\n${pluginLogTail(webLog)}`)
    console.error(`[integration] relay allowlists=${JSON.stringify([...relay.allowlists].map(([machine, set]) => [machine, [...set]]))}`)
    console.error(`[integration] relay events tail=${JSON.stringify(relay.events.slice(-20))}`)
    console.error(`[integration] pending calls=${JSON.stringify([...phone?.calls.keys() ?? []])} streams=${JSON.stringify([...phone?.streams.keys() ?? []])}`)
    throw error
  } finally {
    try { await phone?.close() } catch { /* ignore */ }
    await relay.stop().catch(() => {})
    if (webProcess !== undefined) {
      webProcess.kill('SIGTERM')
      const deadline = Date.now() + 10_000
      while (webProcess.exitCode === null && Date.now() < deadline) await delay(100)
      if (webProcess.exitCode === null) webProcess.kill('SIGKILL')
    }
    rmSync(DSH_HOME, { recursive: true, force: true })
    console.log('[integration] removed fresh DSH_HOME')
  }
})
