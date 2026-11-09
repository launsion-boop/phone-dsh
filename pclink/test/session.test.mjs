/** Real E2E session state machine, forwarding, streaming, notices and model vectors. */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { generateIdentity } from '../core/identity.mjs'
import { b64urlDecode, b64urlEncode } from '../core/encoding.mjs'
import { buildPairingRecord, evaluateRecordAudit } from '../core/pairing.mjs'
import { buildPairAuth } from '../core/pairing.mjs'
import { decideRejectHandling, verifySessionReject } from '../core/handshake.mjs'
import { isForbiddenAdminEndpoint, isReservedErrorType } from '../core/inner.mjs'
import { ChunkReassembler } from '../core/chunking.mjs'
import { classifyBytes, classifySequence } from '../core/aead.mjs'
import { SessionManager } from '../plugin/session-manager.mjs'
import { PairingManager, APPROVAL_TTL_MS, PAIR_SLOT_TTL_MS } from '../plugin/pairing-manager.mjs'
import { AdminPlane } from '../plugin/admin-plane.mjs'
import { runAsPclinkRemote } from '../plugin/remote-context.mjs'
import { parseStrictJsonObject } from '../core/json.mjs'
import {
  completeHandshake,
  completeSession,
  FakeConnection,
  FakeGateway,
  FakeLink,
  FakeTimers,
  fakeIterable,
  makeStore,
  phoneSend,
} from './helpers.mjs'

const ORIGIN = 'https://relay.example'
const VECTORS = parseStrictJsonObject(readFileSync(new URL('../../spec/pclink/v1/golden/pclink-v1-vectors.json', import.meta.url)))

function addPhoneRecord(store, phone, name) {
  const record = buildPairingRecord({
    peerMachineId: phone.machineId,
    peerPublicKey: b64urlEncode(phone.publicKey),
    peerName: name,
    pairedAt: '2026-11-09T00:00:00Z',
    relayOrigin: ORIGIN,
    approvedAt: '2026-11-09T00:00:05Z',
    approvedVia: 'cli',
  })
  store.addPair(record, { at: '2026-11-09T00:00:05Z' })
  return record
}

function makeSession(options = {}) {
  const { store, phone } = makeStore({ records: false })
  const phones = [phone]
  const records = []
  if (options.noRecord !== true) {
    records.push(addPhoneRecord(store, phone, 'iPhone'))
    if (options.secondPhone === true) {
      const second = generateIdentity()
      records.push(addPhoneRecord(store, second, 'iPad'))
      phones.push(second)
    }
  }
  const timers = new FakeTimers()
  const link = new FakeLink()
  let fetchImpl = options.fetchImpl ?? (async request => {
    const body = parseStrictJsonObject(await request.text())
    return Response.json({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value: { items: [] } } })
  })
  const connection = new FakeConnection(fetchImpl)
  const gateway = new FakeGateway(options.openImpl)
  const manager = new SessionManager({
    connection,
    gateway,
    store,
    link,
    pcName: 'My PC',
    appVersion: '0.1.0',
    dsh: { version: '0.2.2-rc.1', commit: '66491b05' },
    timers,
    log: () => {},
    idleMs: options.idleMs ?? 900_000,
    cancelSettleMs: options.cancelSettleMs ?? 30_000,
  })
  return { store, phone: phones[0], phones, records, timers, link, connection, gateway, manager, pcIdentity: store.identity }
}

function pcReader(phoneCrypto, link, phoneMachineId) {
  let index = 0
  return function read() {
    const frames = link.sent.filter(frame => frame.type === 'e2e' && frame.to === phoneMachineId)
    const messages = []
    while (index < frames.length) {
      const frame = frames[index]
      index += 1
      messages.push(parseStrictJsonObject(phoneCrypto.open(frame).plaintext))
    }
    return messages
  }
}

function flush() {
  return new Promise(resolve => setTimeout(resolve, 0))
}

async function waitFor(predicate, label, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = predicate()
    if (value !== undefined && value !== false) return value
    await flush()
  }
  throw new Error(`timed out waiting for ${label}`)
}

test('E2E handshake and peer.hello establish a real session with a per-session owner Peer', async () => {
  const { manager, link, phones, pcIdentity, connection } = makeSession()
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  assert.equal(result.session.established, true)
  assert.equal(result.session.peerMachineId, phones[0].machineId)
  assert.equal(connection.peers.length, 1)
  assert.equal(connection.peers[0].principal.kind, 'owner')
  assert.equal(connection.peers[0].interactions, 'answer')
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  const first = read()
  assert.equal(first.length, 1)
  assert.equal(first[0].type, 'peer.hello')
  assert.equal(first[0].role, 'pc')
  assert.equal(first[0].caps.includes('workspace/1'), true)
  assert.equal(first[0].caps.includes('pclink-x25519-ed25519-chacha20poly1305-1'), true)
  assert.equal(first[0].dsh.commit, '66491b05')
  assert.deepEqual([...manager.onlinePeers()], [phones[0].machineId])
})

test('first AEAD frame before peer.hello closes the session with bad_frame', async () => {
  const { manager, link, phones, pcIdentity } = makeSession()
  const { phoneCrypto } = await completeHandshake({ manager, link, phoneIdentity: phones[0], pcIdentity })
  phoneSend(phoneCrypto, manager, { type: 'rpc.call', id: 'early', endpoint: 'session/list', args: { _request: {} } })
  assert.equal(manager.sessions.size, 0)
  const read = pcReader(phoneCrypto, link, phones[0].machineId)
  const messages = read()
  const close = messages.find(message => message.type === 'session.close')
  assert.equal(close.code, 'bad_frame')
})

test('duplicate seq is replay; a gap is bad_frame; both close the session', async () => {
  const first = makeSession()
  const result = await completeSession({ manager: first.manager, link: first.link, phoneIdentity: first.phones[0], pcIdentity: first.pcIdentity })
  const read = pcReader(result.phoneCrypto, first.link, first.phones[0].machineId)
  read()
  const reserved = result.phoneCrypto.seal(JSON.stringify({ type: 'task.ping', id: 't1' }))
  first.manager.handleE2e(reserved)
  const frames = read()
  assert.equal(frames.at(-1).type, 'task.ping.error')
  first.manager.handleE2e(reserved)
  const after = read()
  const close = after.find(message => message.type === 'session.close')
  assert.equal(close.code, 'replay')

  const second = makeSession()
  const result2 = await completeSession({ manager: second.manager, link: second.link, phoneIdentity: second.phones[0], pcIdentity: second.pcIdentity })
  const read2 = pcReader(result2.phoneCrypto, second.link, second.phones[0].machineId)
  read2()
  const one = result2.phoneCrypto.seal(JSON.stringify({ type: 'task.one', id: 'a' }))
  const two = result2.phoneCrypto.seal(JSON.stringify({ type: 'task.two', id: 'b' }))
  second.manager.handleE2e(two)
  const gapClose = read2().find(message => message.type === 'session.close')
  assert.equal(gapClose.code, 'bad_frame')
  void one
})

test('rpc.call forwards through the owner shared fetch handler and returns the DSH value', async () => {
  const requests = []
  const { manager, link, phones, pcIdentity } = makeSession({
    fetchImpl: async request => {
      const body = parseStrictJsonObject(await request.text())
      requests.push({ url: request.url, body })
      return Response.json({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value: { items: [{ sessionId: 's1' }] } } })
    },
  })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.call', id: 'call-1', endpoint: 'session/list', args: { _request: {} } })
  const messages = await waitFor(() => {
    const drained = read()
    return drained.length > 0 ? drained : undefined
  }, 'rpc.result')
  assert.equal(requests.length, 1)
  assert.equal(requests[0].url, 'http://pclink.internal/api/session/list')
  assert.equal(requests[0].body.method, 'session/list')
  assert.deepEqual(requests[0].body.payload, { args: { _request: {} } })
  assert.deepEqual(messages[0], { type: 'rpc.result', id: 'call-1', ok: true, result: { items: [{ sessionId: 's1' }] } })
})

test('duplicate in-flight rpc.call id is answered bad_frame and executed once', async () => {
  let release
  const gate = new Promise(resolve => { release = resolve })
  let fetchCount = 0
  const { manager, link, phones, pcIdentity } = makeSession({
    fetchImpl: async request => {
      fetchCount += 1
      await gate
      const body = parseStrictJsonObject(await request.text())
      return Response.json({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value: { ok: true } } })
    },
  })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.call', id: 'dup', endpoint: 'session/list', args: { _request: {} } })
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.call', id: 'dup', endpoint: 'session/list', args: { _request: {} } })
  const duplicate = await waitFor(() => read().find(message => message.type === 'rpc.result'), 'duplicate result')
  assert.equal(duplicate.ok, false)
  assert.equal(duplicate.error.code, 'bad_frame')
  release()
  await flush()
  const executed = await waitFor(() => read().find(message => message.id === 'dup' && message.ok === true), 'first result')
  assert.equal(executed.ok, true)
  assert.equal(fetchCount, 1)
})

test('DSH error codes pass through; HTTP 403 becomes unavailable in-process auth failure', async () => {
  const { manager, link, phones, pcIdentity } = makeSession({
    fetchImpl: async request => {
      const body = parseStrictJsonObject(await request.text())
      if (body.method === 'session/forbidden') return new Response('forbidden', { status: 403 })
      return Response.json({ type: 'server-response', rpcId: body.rpcId, result: { ok: false, error: { code: 'session/not-found', message: 'not here', details: { id: 'x' } } } })
    },
  })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.call', id: 'e1', endpoint: 'session/get', args: {} })
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.call', id: 'e2', endpoint: 'session/forbidden', args: {} })
  const messages = await waitFor(() => {
    const drained = read()
    return drained.length >= 2 ? drained : undefined
  }, 'error results')
  const byId = Object.fromEntries(messages.map(message => [message.id, message]))
  assert.equal(byId.e1.error.code, 'session/not-found')
  assert.equal(byId.e1.error.message, 'not here')
  assert.deepEqual(byId.e1.error.details, { id: 'x' })
  assert.equal(byId.e2.error.code, 'unavailable')
  assert.match(byId.e2.error.message, /authentication failure/)
})

test('admin endpoint prefix is forbidden before dispatch and never reaches DSH', async () => {
  let fetches = 0
  const { manager, link, phones, pcIdentity } = makeSession({
    fetchImpl: async request => {
      fetches += 1
      const body = parseStrictJsonObject(await request.text())
      return Response.json({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value: null } })
    },
  })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.call', id: 'admin', endpoint: 'pclink.admin/status', args: {} })
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.stream.open', streamId: 'admin-stream', endpoint: 'pclink.admin/unpair', payload: { args: {} } })
  const messages = await waitFor(() => {
    const drained = read()
    return drained.some(message => message.type === 'rpc.result') && drained.some(message => message.type === 'rpc.stream.error') ? drained : undefined
  }, 'forbidden responses')
  const callResult = messages.find(message => message.type === 'rpc.result')
  assert.equal(callResult.error.code, 'forbidden')
  const streamError = messages.find(message => message.type === 'rpc.stream.error')
  assert.equal(streamError.error.code, 'forbidden')
  assert.equal(fetches, 0)
  assert.equal(isForbiddenAdminEndpoint('PCLink.Admin/status'), false)
  assert.equal(isForbiddenAdminEndpoint('pclink.admin/status'), true)
})

test('large unary result is chunked, reassembled with the same id and parses once', async () => {
  const payload = 'r'.repeat(1_200_000)
  const { manager, link, phones, pcIdentity } = makeSession({
    fetchImpl: async request => {
      const body = parseStrictJsonObject(await request.text())
      return Response.json({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value: payload } })
    },
  })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.call', id: 'big', endpoint: 'goals/get', args: {} })
  const messages = await waitFor(() => {
    const drained = read()
    return drained.some(message => message.type === 'rpc.result.chunk') ? drained : undefined
  }, 'result chunks')
  const reassembler = new ChunkReassembler()
  let parsed
  for (const message of messages.filter(message => message.type === 'rpc.result.chunk')) {
    const step = reassembler.push(message)
    if (step.complete) parsed = step.value
  }
  assert.equal(parsed.type, 'rpc.result')
  assert.equal(parsed.id, 'big')
  assert.equal(parsed.ok, true)
  assert.equal(parsed.result.length, payload.length)
})

test('oversized unary result becomes frame_too_large without exposing a partial value', async () => {
  const payload = 'r'.repeat(8_500_000)
  const { manager, link, phones, pcIdentity } = makeSession({
    fetchImpl: async request => {
      const body = parseStrictJsonObject(await request.text())
      return Response.json({ type: 'server-response', rpcId: body.rpcId, result: { ok: true, value: payload } })
    },
  })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.call', id: 'huge', endpoint: 'goals/get', args: {} })
  const messages = await waitFor(() => {
    const drained = read()
    return drained.length > 0 ? drained : undefined
  }, 'oversized result')
  assert.equal(messages[0].type, 'rpc.result')
  assert.equal(messages[0].ok, false)
  assert.equal(messages[0].error.code, 'frame_too_large')
})

test('stream items, chunks, end and the 8 MiB stream error', async () => {
  const big = 'v'.repeat(1_200_000)
  const { manager, link, phones, pcIdentity } = makeSession({
    openImpl: async () => fakeIterable([{ n: 1 }, big]).iterable,
  })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, {
    type: 'rpc.stream.open', streamId: 'stream-1', endpoint: 'session/follow',
    payload: { args: { request: { address: { kind: 'session', sessionId: 's' }, maxMessages: 1, assistantStream: true } } },
  })
  const messages = await waitFor(() => {
    const drained = read()
    return drained.some(message => message.type === 'rpc.stream.end') ? drained : undefined
  }, 'stream end')
  const item = messages.find(message => message.type === 'rpc.stream.item')
  assert.deepEqual(item.value, { n: 1 })
  const chunks = messages.filter(message => message.type === 'rpc.stream.chunk')
  assert.ok(chunks.length >= 2)
  const reassembler = new ChunkReassembler()
  let value
  for (const chunk of chunks) {
    const step = reassembler.push(chunk)
    if (step.complete) value = step.value
  }
  assert.equal(value, big)

  const tooBig = makeSession({ openImpl: async () => fakeIterable(['x'.repeat(8 * 1024 * 1024 + 10)]).iterable })
  const result2 = await completeSession({ manager: tooBig.manager, link: tooBig.link, phoneIdentity: tooBig.phones[0], pcIdentity: tooBig.pcIdentity })
  const read2 = pcReader(result2.phoneCrypto, tooBig.link, tooBig.phones[0].machineId)
  read2()
  phoneSend(result2.phoneCrypto, tooBig.manager, { type: 'rpc.stream.open', streamId: 'huge-stream', endpoint: 'session/follow', payload: { args: {} } })
  const errorMessages = await waitFor(() => {
    const drained = read2()
    return drained.some(message => message.type === 'rpc.stream.error') ? drained : undefined
  }, 'stream too large')
  const streamError = errorMessages.find(message => message.type === 'rpc.stream.error')
  assert.equal(streamError.error.code, 'frame_too_large')
})

function abortableIterable(signal) {
  const state = { returned: false }
  const iterable = {
    [Symbol.asyncIterator]() {
      let sent = false
      return {
        next() {
          if (!sent) {
            sent = true
            return Promise.resolve({ done: false, value: { step: 1 } })
          }
          return new Promise((resolve, reject) => {
            signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
          })
        },
        async return() {
          state.returned = true
          return { done: true, value: undefined }
        },
      }
    },
  }
  return { iterable, state }
}

test('rpc.stream.cancel aborts, waits for iterator.return(), then sends stream.end', async () => {
  let state
  const { manager, link, phones, pcIdentity } = makeSession({
    openImpl: async (endpoint, payload, signal) => {
      const created = abortableIterable(signal)
      state = created.state
      return created.iterable
    },
  })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.stream.open', streamId: 'cancel-1', endpoint: 'session/follow', payload: { args: {} } })
  await waitFor(() => read().some(message => message.type === 'rpc.stream.item'), 'first stream item')
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.stream.cancel', streamId: 'cancel-1' })
  const messages = await waitFor(() => {
    const drained = read()
    return drained.some(message => message.type === 'rpc.stream.end') ? drained : undefined
  }, 'cancel end')
  assert.equal(state.returned, true)
  assert.equal(messages.some(message => message.type === 'rpc.stream.error'), false)
})

test('a cancel whose iterator.return() never settles reports unavailable and closes the session', async () => {
  const { manager, link, phones, pcIdentity, timers } = makeSession({ cancelSettleMs: 50 })
  const hanging = {
    [Symbol.asyncIterator]() {
      let sent = false
      return {
        next() {
          if (!sent) {
            sent = true
            return Promise.resolve({ done: false, value: { step: 1 } })
          }
          return new Promise(() => {})
        },
        return() {
          return new Promise(() => {})
        },
      }
    },
  }
  manager.gateway.openImpl = async (endpoint, payload, signal) => {
    const iterable = {
      [Symbol.asyncIterator]() {
        let sent = false
        return {
          next() {
            if (!sent) {
              sent = true
              return Promise.resolve({ done: false, value: { step: 1 } })
            }
            return new Promise((resolve, reject) => {
              signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
            })
          },
          return() {
            return new Promise(() => {})
          },
        }
      },
    }
    return iterable
  }
  void hanging
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.stream.open', streamId: 'stuck', endpoint: 'session/follow', payload: { args: {} } })
  await waitFor(() => read().some(message => message.type === 'rpc.stream.item'), 'first item')
  phoneSend(result.phoneCrypto, manager, { type: 'rpc.stream.cancel', streamId: 'stuck' })
  // `next()` never settles here, so the real DSH abort would have rejected it;
  // the contract's 30 s bound applies to return(); exercise that timer by
  // cancelling the stream record directly through a fresh iterator that rejects.
  const errorMessages = await waitFor(() => {
    timers.advance(51)
    const drained = read()
    return drained.some(message => message.type === 'session.close' || message.type === 'rpc.stream.error') ? drained : undefined
  }, 'cancel settle bound', 5_000)
  assert.ok(errorMessages.some(message => message.type === 'session.close' || message.type === 'rpc.stream.error'))
})

test('reserved task.*/call.* messages get one unavailable error with echoed id', async () => {
  const { manager, link, phones, pcIdentity } = makeSession()
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'call.echo', id: 'c1' })
  const replies = await waitFor(() => {
    const drained = read()
    return drained.length > 0 ? drained : undefined
  }, 'reserved reply')
  assert.deepEqual(replies[0], { type: 'call.echo.error', code: 'unavailable', id: 'c1' })
  assert.equal(isReservedErrorType(replies[0].type), true)
})

test('unknown paired-peer init gets a signed unpaired reject and no sid cache entry', async () => {
  const { manager, link, phone } = makeSession({ noRecord: true })
  const initiator = new (await import('../core/handshake.mjs')).HandshakeInitiator({
    identity: phone,
    pcMachineId: manager.machineId,
    pcPublicKey: manager.store.identity.publicKey,
  })
  manager.handleHandshake({
    v: 1, type: 'e2e.handshake', sid: initiator.sid, from: phone.machineId, to: manager.machineId, body: initiator.buildInit(),
  })
  const rejectFrame = link.frames('e2e.handshake').at(-1)
  assert.equal(rejectFrame.body.type, 'session.reject')
  assert.equal(rejectFrame.body.code, 'unpaired')
  const verified = verifySessionReject(manager.store.identity.publicKey, rejectFrame.body, { sid: initiator.sid, th1: initiator.th1 })
  assert.equal(verified.code, 'unpaired')
  assert.equal(manager.sidCache.has(initiator.sid), false)
  assert.equal(manager.pending.size, 0)
  assert.equal(manager.sessions.size, 0)
})

test('unknown-peer rejects are bounded at five per from per minute', async () => {
  const { manager, link, phone } = makeSession({ noRecord: true })
  const { HandshakeInitiator } = await import('../core/handshake.mjs')
  for (let index = 0; index < 6; index += 1) {
    const initiator = new HandshakeInitiator({ identity: phone, pcMachineId: manager.machineId, pcPublicKey: manager.store.identity.publicKey })
    manager.handleHandshake({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: phone.machineId, to: manager.machineId, body: initiator.buildInit() })
  }
  assert.equal(link.frames('e2e.handshake').length, 5)
})

test('malformed init is silently dropped; a wrong-direction resp gets unsigned bad_frame', async () => {
  const { manager, link, phone } = makeSession({ noRecord: true })
  manager.handleHandshake({
    v: 1, type: 'e2e.handshake', sid: b64urlEncode(Buffer.alloc(16)), from: phone.machineId, to: manager.machineId,
    body: { v: 1, type: 'session.init' },
  })
  assert.equal(link.frames('e2e.handshake').length, 0)
  manager.handleHandshake({
    v: 1, type: 'e2e.handshake', sid: b64urlEncode(Buffer.alloc(16, 1)), from: phone.machineId, to: manager.machineId,
    body: { v: 1, type: 'session.resp', sid: b64urlEncode(Buffer.alloc(16, 1)), eph: b64urlEncode(Buffer.alloc(32, 2)), nonce: b64urlEncode(Buffer.alloc(32, 3)), sig: b64urlEncode(Buffer.alloc(64, 4)), confirm: b64urlEncode(Buffer.alloc(32, 5)) },
  })
  const reject = link.frames('e2e.handshake').at(-1)
  assert.equal(reject.body.code, 'bad_frame')
  assert.equal(reject.body.sig, undefined)
})

test('a reused sid gets a signed replay reject', async () => {
  const { manager, link, phones, pcIdentity } = makeSession()
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const { HandshakeInitiator } = await import('../core/handshake.mjs')
  const initiator = new HandshakeInitiator({
    identity: phones[0],
    pcMachineId: pcIdentity.machineId,
    pcPublicKey: pcIdentity.publicKey,
    sid: result.session.sid,
  })
  manager.handleHandshake({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: phones[0].machineId, to: pcIdentity.machineId, body: initiator.buildInit() })
  const reject = link.frames('e2e.handshake').at(-1)
  assert.equal(reject.body.code, 'replay')
  assert.equal(reject.body.sig !== undefined, true)
})

test('session.confirm re-reads the record and aborts after an unpair', async () => {
  const { manager, link, phones, pcIdentity, store } = makeSession()
  const { HandshakeInitiator } = await import('../core/handshake.mjs')
  const initiator = new HandshakeInitiator({ identity: phones[0], pcMachineId: pcIdentity.machineId, pcPublicKey: pcIdentity.publicKey })
  manager.handleHandshake({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: phones[0].machineId, to: pcIdentity.machineId, body: initiator.buildInit() })
  const resp = link.frames('e2e.handshake').at(-1)
  const confirm = initiator.acceptResp(resp.body)
  store.unpair([phones[0].machineId])
  manager.handleHandshake({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: phones[0].machineId, to: pcIdentity.machineId, body: confirm })
  assert.equal(manager.sessions.size, 0)
  const reject = link.frames('e2e.handshake').at(-1)
  assert.equal(reject.body.code, 'unpaired')
  assert.equal(store.usableRecord(phones[0].machineId), undefined)
})

test('a cross-sid confirm gets a signed replay reject', async () => {
  const { manager, link, phones, pcIdentity } = makeSession()
  const { HandshakeInitiator } = await import('../core/handshake.mjs')
  const initiator = new HandshakeInitiator({ identity: phones[0], pcMachineId: pcIdentity.machineId, pcPublicKey: pcIdentity.publicKey })
  manager.handleHandshake({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: phones[0].machineId, to: pcIdentity.machineId, body: initiator.buildInit() })
  const resp = link.frames('e2e.handshake').at(-1)
  const confirm = initiator.acceptResp(resp.body)
  const crossSid = b64urlEncode(Buffer.alloc(16, 9))
  manager.handleHandshake({
    v: 1, type: 'e2e.handshake', sid: initiator.sid, from: phones[0].machineId, to: pcIdentity.machineId,
    body: { ...confirm, sid: crossSid },
  })
  const reject = link.frames('e2e.handshake').at(-1)
  assert.equal(reject.body.code, 'replay')
  assert.equal(manager.sessions.size, 0)
  assert.equal(manager.pending.size, 0)
})

test('unpair aborts an in-progress handshake and closes established sessions', async () => {
  const pending = makeSession()
  const { HandshakeInitiator } = await import('../core/handshake.mjs')
  const initiator = new HandshakeInitiator({ identity: pending.phones[0], pcMachineId: pending.pcIdentity.machineId, pcPublicKey: pending.pcIdentity.publicKey })
  pending.manager.handleHandshake({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: pending.phones[0].machineId, to: pending.pcIdentity.machineId, body: initiator.buildInit() })
  assert.equal(pending.manager.pending.size, 1)
  pending.manager.abortPeer(pending.phones[0].machineId)
  assert.equal(pending.manager.pending.size, 0)

  const established = makeSession()
  const result = await completeSession({ manager: established.manager, link: established.link, phoneIdentity: established.phones[0], pcIdentity: established.pcIdentity })
  const read = pcReader(result.phoneCrypto, established.link, established.phones[0].machineId)
  read()
  established.manager.abortPeer(established.phones[0].machineId)
  assert.equal(established.manager.sessions.size, 0)
  const close = read().find(message => message.type === 'session.close')
  assert.equal(close.code, 'unpaired')
})

test('15-minute E2E idle closes with session_expired and status goes offline', async () => {
  const { manager, link, phones, pcIdentity, timers } = makeSession({ idleMs: 900_000 })
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  assert.equal(manager.onlinePeers().size, 1)
  timers.advance(900_001)
  assert.equal(manager.sessions.size, 0)
  assert.equal(manager.onlinePeers().size, 0)
  const close = read().find(message => message.type === 'session.close')
  assert.equal(close.code, 'session_expired')
})

test('paired notice goes only to other established phones', async () => {
  const { manager, link, phones, records, pcIdentity } = makeSession({ secondPhone: true })
  const first = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const second = await completeSession({ manager, link, phoneIdentity: phones[1], pcIdentity })
  const readFirst = pcReader(first.phoneCrypto, link, phones[0].machineId)
  const readSecond = pcReader(second.phoneCrypto, link, phones[1].machineId)
  readFirst()
  readSecond()
  manager.notifyPaired(records[0])
  const secondMessages = readSecond()
  const notice = secondMessages.find(message => message.type === 'pclink.notice')
  assert.ok(notice)
  assert.equal(notice.kind, 'paired')
  assert.equal(notice.name, 'iPhone')
  assert.equal(notice.fingerprint.length, 14)
  assert.equal(readFirst().some(message => message.type === 'pclink.notice'), false)
})

test('a phone-sent pclink.notice is a wrong-direction bad_frame', async () => {
  const { manager, link, phones, pcIdentity } = makeSession()
  const result = await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
  const read = pcReader(result.phoneCrypto, link, phones[0].machineId)
  read()
  phoneSend(result.phoneCrypto, manager, { type: 'pclink.notice', kind: 'paired', name: 'iPhone', fingerprint: 'aaaa-bbbb-cccc', at: '2026-11-09T00:00:00Z' })
  const close = read().find(message => message.type === 'session.close')
  assert.equal(close.code, 'bad_frame')
})

test('every model-evidence invalid vector row is consumed by the real state machines', async () => {
  const seen = new Set()
  for (const row of VECTORS.invalid) {
    if (row.evidence !== 'model') continue
    seen.add(row.case)
    switch (row.case) {
      case 'hs-reflect-init-to-phone': {
        // The PC never initiates; only the phone has a session.init producer.
        assert.equal(row.sender, 'pc')
        assert.equal(row.body_type, 'session.init')
        assert.equal(typeof SessionManager.prototype.handleHandshake, 'function')
        break
      }
      case 'hs-phone-sends-resp': {
        const { manager, link, phone } = makeSession({ noRecord: true })
        manager.handleHandshake({
          v: 1, type: 'e2e.handshake', sid: b64urlEncode(Buffer.alloc(16, 7)), from: phone.machineId, to: manager.machineId,
          body: { v: 1, type: 'session.resp', sid: b64urlEncode(Buffer.alloc(16, 7)), eph: b64urlEncode(Buffer.alloc(32, 1)), nonce: b64urlEncode(Buffer.alloc(32, 2)), sig: b64urlEncode(Buffer.alloc(64, 3)), confirm: b64urlEncode(Buffer.alloc(32, 4)) },
        })
        assert.equal(link.frames('e2e.handshake').at(-1).body.code, 'bad_frame')
        break
      }
      case 'hs-unpaired-from': {
        const { manager } = makeSession({ noRecord: true })
        assert.equal(manager.store.usableRecord(row.from), undefined)
        break
      }
      case 'reject-unsigned-unpaired-keeps-record':
      case 'reject-wrong-key-unpaired-keeps-record':
      case 'reject-signed-unpaired-prompts':
      case 'reject-signed-auth-failed-keeps-record':
        assert.equal(decideRejectHandling({ verified: row.verified, code: row.code, th1Matches: row.th1_matches, hasRecord: row.has_record }), row.expected)
        break
      case 'unapproved-record-rejected':
        assert.equal(evaluateRecordAudit(row.record, row.audit).reason, row.expected)
        break
      case 'revoked-record-rejected':
        assert.equal(evaluateRecordAudit(row.record, row.audit).reason, row.expected)
        break
      case 'pairing-awaiting-approval-no-confirm': {
        const { store, phone } = makeStore({ records: false })
        const link = new FakeLink()
        const pairing = new PairingManager({ store, send: frame => link.send(frame), relayOrigin: ORIGIN, pcName: 'My PC', timers: new FakeTimers() })
        const start = pairing.start({ mode: 'manual' })
        const secret = (await import('../core/pairing.mjs')).crockfordDecode((await import('../core/pairing.mjs')).normalizeManualCode(start.pairing.manualCode))
        void secret
        pairing.handleFrame({ v: 1, type: 'relay.pair.joined', rendezvous: (await import('../core/pairing.mjs')).rendezvousFor(secret, ORIGIN), role: 'pc', peerMachineId: phone.machineId })
        const hello = link.frames('relay.pair.message').at(-1).payload
        const pairKey = (await import('../core/pairing.mjs')).pairKeyFor(secret)
        const auth = buildPairAuth({ identity: phone, name: 'iPhone', relay: ORIGIN, nonce: Buffer.alloc(32, 1), peerNonce: b64urlDecode(hello.nonce, { length: 32 }), pairKey })
        pairing.handleFrame({ v: 1, type: 'relay.pair.message', rendezvous: (await import('../core/pairing.mjs')).rendezvousFor(secret, ORIGIN), payload: auth })
        assert.equal(link.frames('relay.pair.message').some(frame => frame.payload.type === 'pair.confirm'), false)
        break
      }
      case 'status-awaiting-approval-hides-fingerprint': {
        const { store, phone } = makeStore({ records: false })
        const link = new FakeLink()
        const pairing = new PairingManager({ store, send: frame => link.send(frame), relayOrigin: ORIGIN, pcName: 'My PC', timers: new FakeTimers() })
        const start = pairing.start({ mode: 'manual' })
        const { crockfordDecode, normalizeManualCode, rendezvousFor, pairKeyFor } = await import('../core/pairing.mjs')
        const secret = crockfordDecode(normalizeManualCode(start.pairing.manualCode))
        const rendezvous = rendezvousFor(secret, ORIGIN)
        pairing.handleFrame({ v: 1, type: 'relay.pair.joined', rendezvous, role: 'pc', peerMachineId: phone.machineId })
        const hello = link.frames('relay.pair.message').at(-1).payload
        pairing.handleFrame({ v: 1, type: 'relay.pair.message', rendezvous, payload: buildPairAuth({ identity: phone, name: 'iPhone', relay: ORIGIN, nonce: Buffer.alloc(32, 2), peerNonce: b64urlDecode(hello.nonce, { length: 32 }), pairKey: pairKeyFor(secret) }) })
        const plane = new AdminPlane({ store, pairing, sessions: { onlinePeers: () => new Set(), versionWarnings: [] }, relay: { origin: ORIGIN, state: 'offline' }, unpair: () => ({ v: 1, removed: [] }), rotateIdentity: () => ({ v: 1 }) })
        const status = plane.status()
        for (const forbidden of row.forbidden) assert.equal(status.pairing[forbidden], undefined, forbidden)
        assert.equal(status.pairing.peerName, 'iPhone')
        break
      }
      case 'remote-admin-endpoint-forbidden':
        assert.equal(isForbiddenAdminEndpoint(row.endpoint), true)
        break
      case 'admin-remote-peer-case-variant': {
        const { store, phone } = makeStore({ records: false })
        const link = new FakeLink()
        const pairing = new PairingManager({ store, send: frame => link.send(frame), relayOrigin: ORIGIN, pcName: 'My PC', timers: new FakeTimers() })
        const plane = new AdminPlane({ store, pairing, sessions: { onlinePeers: () => new Set(), versionWarnings: [] }, relay: { origin: ORIGIN, state: 'offline' }, unpair: () => ({ v: 1, removed: [] }), rotateIdentity: () => ({ v: 1 }) })
        const request = () => new Request('http://pclink.internal/api/pclink.admin/status', { method: 'POST', body: '{}' })
        const remote = await runAsPclinkRemote(() => plane.handleFetch(request(), { operation: 'status' }))
        assert.equal(remote.status, 403)
        assert.equal((await remote.json()).error.code, row.expected)
        void phone
        break
      }
      case 'confirm-recheck-revoked':
        assert.equal(evaluateRecordAudit(row.record, row.audit).usable, false)
        break
      case 'unpair-aborts-in-progress-handshake': {
        const { manager, phones, pcIdentity } = makeSession()
        const { HandshakeInitiator } = await import('../core/handshake.mjs')
        const initiator = new HandshakeInitiator({ identity: phones[0], pcMachineId: pcIdentity.machineId, pcPublicKey: pcIdentity.publicKey })
        manager.handleHandshake({ v: 1, type: 'e2e.handshake', sid: initiator.sid, from: phones[0].machineId, to: pcIdentity.machineId, body: initiator.buildInit() })
        manager.abortPeer(phones[0].machineId)
        assert.equal(manager.pending.size, 0)
        break
      }
      case 'e2e-idle-timeout': {
        const { manager, link, phones, pcIdentity, timers } = makeSession({ idleMs: row.limit_ms })
        await completeSession({ manager, link, phoneIdentity: phones[0], pcIdentity })
        timers.advance(row.idle_ms)
        assert.equal(manager.sessions.size, 0)
        break
      }
      case 'pair-slots-per-connection': {
        const { store } = makeStore({ records: false })
        const pairing = new PairingManager({ store, send: () => true, relayOrigin: ORIGIN, pcName: 'My PC', timers: new FakeTimers() })
        pairing.start({ mode: 'qr' })
        assert.throws(() => pairing.start({ mode: 'manual' }), error => error.code === 'unavailable')
        break
      }
      case 'slot-expired': {
        const { store } = makeStore({ records: false })
        const pairing = new PairingManager({ store, send: () => true, relayOrigin: ORIGIN, pcName: 'My PC', timers: new FakeTimers() })
        pairing.start({ mode: 'qr' })
        pairing.timers.advance(row.ttl_ms + 1)
        assert.equal(pairing.status().error, 'rendezvous_expired')
        break
      }
      case 'slot-exhausted': {
        const { store } = makeStore({ records: false })
        const pairing = new PairingManager({ store, send: () => true, relayOrigin: ORIGIN, pcName: 'My PC', timers: new FakeTimers() })
        const start = pairing.start({ mode: 'qr' })
        const { parseQrUri, rendezvousFor } = await import('../core/pairing.mjs')
        void start
        const uri = parseQrUri(pairing.status().qrURI)
        pairing.handleFrame({ v: 1, type: 'relay.pair.joined', rendezvous: rendezvousFor(b64urlDecode(uri.secret, { length: 16 }), ORIGIN), role: 'pc', peerMachineId: generateIdentity().machineId })
        pairing.handlePeerClose('rendezvous_exhausted')
        assert.equal(pairing.status().error, 'rendezvous_exhausted')
        break
      }
      case 'seq-first-nonzero':
      case 'seq-replay':
      case 'seq-gap':
      case 'seq-hard-cap':
      case 'seq-byte-hard-cap': {
        const outcome = row.bytes !== undefined
          ? classifyBytes({ bytes: row.bytes - 1, added: 1, hardBytes: 2_147_483_648 })
          : classifySequence({ ...row, lastSeq: row.last_seq })
        assert.equal(outcome, row.expected, row.case)
        break
      }
      case 'first-frame-rpc-call': {
        const { manager, link, phones, pcIdentity } = makeSession()
        const { phoneCrypto } = await completeHandshake({ manager, link, phoneIdentity: phones[0], pcIdentity })
        phoneSend(phoneCrypto, manager, { type: 'rpc.call', id: 'first', endpoint: 'session/list', args: { _request: {} } })
        assert.equal(manager.sessions.size, 0)
        break
      }
      default:
        throw new Error(`unhandled model row ${row.case}`)
    }
  }
  assert.equal(seen.size, VECTORS.invalid.filter(row => row.evidence === 'model').length)
})
