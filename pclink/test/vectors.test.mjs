/** Runtime conformance against spec/pclink/v1/golden/pclink-v1-vectors.json (crypto rows). */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  aadBytes,
  aeadNonce,
  classifyBytes,
  classifySequence,
  FrameCrypto,
  openE2eBody,
  sealE2eBody,
  SEQ_MAX,
} from '../core/aead.mjs'
import { canonicalJson } from '../core/canonical.mjs'
import { ChunkReassembler, encodeStreamValue, splitChunks } from '../core/chunking.mjs'
import {
  b64urlDecode,
  b64urlEncode,
  fingerprintMatches,
  hexEncode,
  machineIdFromPublicKey,
  normalizeFingerprintInput,
  sha256,
  validateName,
} from '../core/encoding.mjs'
import { decideRejectHandling, deriveHandshakeKeys, HandshakeInitiator, HandshakeResponder, initTranscript, rejectTranscript, validateSessionReject, verifySessionReject } from '../core/handshake.mjs'
import { adminProof } from '../core/identity.mjs'
import { ed25519Verify, testIdentity, x25519Dh, x25519FromSeed } from '../core/identity.mjs'
import { parseStrictJson, parseStrictJsonObject } from '../core/json.mjs'
import {
  buildAuditPairEntry,
  crockfordEncode,
  evaluateRecordAudit,
  formatManualCode,
  normalizeManualCode,
  pairKeyFor,
  pairMac,
  PAIR_DOMAINS,
  parseQrUri,
  rendezvousFor,
} from '../core/pairing.mjs'
import {
  decodeInnerMessage,
  isForbiddenAdminEndpoint,
  missingRequiredCaps,
  normalizeFailure,
  validateInnerMessage,
} from '../core/inner.mjs'
import {
  isPclinkCode,
  SESSION_CLOSE_CODES,
} from '../core/errors.mjs'
import { buildRelayAuth, relayAuthTranscript, requireSameOrigin, validateE2eFrame, validateRelayError } from '../core/relay.mjs'
import { MAX_FRAME_BYTES, MAX_VALUE_BYTES } from '../core/encoding.mjs'
import { parseRelayFrame } from '../core/relay.mjs'

const VECTORS = parseStrictJsonObject(readFileSync(new URL('../../spec/pclink/v1/golden/pclink-v1-vectors.json', import.meta.url)))

const phone = testIdentity(VECTORS.labels.phoneIdentity)
const pc = testIdentity(VECTORS.labels.pcIdentity)

test('golden format and labels', () => {
  assert.equal(VECTORS.format, 'pclink-v1-vectors')
  assert.equal(VECTORS.revision, 'pclink-v1.2')
  assert.equal(VECTORS.suite, 'pclink-x25519-ed25519-chacha20poly1305-1')
})

test('identities: labels derive the same machineIds and keys', () => {
  assert.equal(phone.machineId, VECTORS.identities.phone.machine_id)
  assert.equal(pc.machineId, VECTORS.identities.pc.machine_id)
  assert.equal(b64urlEncode(phone.publicKey), VECTORS.identities.phone.public_key)
  assert.equal(b64urlEncode(pc.publicKey), VECTORS.identities.pc.public_key)
  assert.equal(hexEncode(sha256(phone.publicKey)), VECTORS.identities.phone.sha256_hex)
  assert.equal(machineIdFromPublicKey(pc.publicKey), VECTORS.identities.pc.machine_id)
})

test('strict JSON rejects a raw NUL but preserves an escaped \\u0000 inside DSH data', () => {
  assert.throws(() => parseStrictJson('{"x":"a\u0000b"}'), error => error.code === 'bad_frame')
  assert.deepEqual(parseStrictJson('{"x":"a\\u0000b"}'), { x: 'a\u0000b' })
})

test('NUL boundary: DSH passthrough values keep an escaped \\u0000', () => {
  // A raw NUL byte in the plaintext is still a bad wire frame.
  assert.throws(() => decodeInnerMessage('{"type":"rpc.call","id":"call-1","endpoint":"session/prompt","args":{"text":"a\u0000b"}}'),
    error => error.code === 'bad_frame')

  const call = { type: 'rpc.call', id: 'call-1', endpoint: 'session/prompt', args: { text: 'a\u0000b' } }
  assert.equal(decodeInnerMessage(JSON.stringify(call), { direction: 'phone_to_pc' }).args.text, 'a\u0000b')

  const result = { type: 'rpc.result', id: 'call-1', ok: true, result: { nested: ['a\u0000b'] } }
  assert.equal(decodeInnerMessage(JSON.stringify(result), { direction: 'pc_to_phone' }).result.nested[0], 'a\u0000b')

  const item = { type: 'rpc.stream.item', streamId: 'stream-1', value: { text: 'a\u0000b' } }
  assert.equal(decodeInnerMessage(JSON.stringify(item), { direction: 'pc_to_phone' }).value.text, 'a\u0000b')

  const details = {
    type: 'rpc.result',
    id: 'call-1',
    ok: false,
    error: { code: 'unavailable', message: 'failed', details: { text: 'a\u0000b' } },
  }
  assert.equal(decodeInnerMessage(JSON.stringify(details), { direction: 'pc_to_phone' }).error.details.text, 'a\u0000b')
})

test('NUL boundary: PCLink-owned name/message fields still reject U+0000', () => {
  const nul = 'a\u0000b'
  assert.throws(() => validateName(nul), error => error.code === 'bad_frame')
  const hello = {
    v: 1,
    type: 'peer.hello',
    role: 'phone',
    caps: ['workspace/1'],
    dsh: { version: '0.2.2' },
    app: { name: 'phoneDSH', version: '0.1.0' },
    name: nul,
  }
  assert.throws(() => validateInnerMessage(hello), error => error.code === 'bad_frame')
  assert.throws(() => decodeInnerMessage(JSON.stringify(hello)), error => error.code === 'bad_frame')
  const errorResult = { type: 'rpc.result', id: 'call-1', ok: false, error: { code: 'unavailable', message: nul } }
  assert.throws(() => validateInnerMessage(errorResult), error => error.code === 'bad_frame')
  assert.throws(() => decodeInnerMessage(JSON.stringify(errorResult)), error => error.code === 'bad_frame')
  assert.throws(() => validateInnerMessage({ type: 'rpc.stream.error', streamId: 'stream-1', error: { code: 'unavailable', message: nul } }),
    error => error.code === 'bad_frame')
  assert.throws(() => validateInnerMessage({ type: 'session.close', code: 'unavailable', message: nul }),
    error => error.code === 'bad_frame')
  assert.throws(() => validateInnerMessage({ type: 'call.foo.error', code: 'unavailable', message: nul }),
    error => error.code === 'bad_frame')
  assert.throws(() => validateRelayError({ v: 1, type: 'relay.error', code: 'unavailable', message: nul }),
    error => error.code === 'bad_frame')
  assert.throws(() => validateSessionReject({
    v: 1,
    type: 'session.reject',
    sid: 'ODU-xxharZz-k1yXN2XWRA',
    code: 'unpaired',
    message: nul,
  }), error => error.code === 'bad_frame')

  // The producer sanitizes a DSH failure message instead of emitting an
  // invalid PCLink field.
  const normalized = normalizeFailure({ code: 'unavailable', message: nul })
  assert.equal(normalized.message, 'a\uFFFDb')
  assert.doesNotThrow(() => validateInnerMessage({ type: 'rpc.result', id: 'call-1', ok: false, error: normalized }))
})

test('canonical JSON: scalar key order and literal slash/non-ASCII', () => {
  const scalar = VECTORS.canonical_json.scalar_order
  assert.equal(canonicalJson(scalar.object), scalar.canonical)
  assert.equal(hexEncode(sha256(Buffer.from(scalar.canonical, 'utf8'))), scalar.sha256_hex)
  const slash = VECTORS.canonical_json.slash_and_nonascii
  assert.equal(canonicalJson(slash.object), slash.canonical)
  assert.equal(hexEncode(sha256(Buffer.from(slash.canonical, 'utf8'))), slash.sha256_hex)
})

test('relay auth: transcript and both signatures', () => {
  const nonce = b64urlDecode(VECTORS.relay_auth.nonce, { length: 32 })
  const transcript = relayAuthTranscript(VECTORS.relay_auth.origin, nonce)
  assert.equal(hexEncode(transcript), VECTORS.relay_auth.transcript_hex)
  for (const role of ['phone', 'pc']) {
    const row = VECTORS.relay_auth[role]
    assert.ok(ed25519Verify(b64urlDecode(row.public_key, { length: 32 }), transcript, b64urlDecode(row.signature, { length: 64 })))
    const built = buildRelayAuth(role === 'phone' ? phone : pc, { origin: VECTORS.relay_auth.origin, nonce: VECTORS.relay_auth.nonce }, role)
    assert.deepEqual(built, { v: 1, type: 'peer.auth', machineId: row.machine_id, publicKey: row.public_key, role, sig: row.signature })
  }
})

function fixedHandshake() {
  // The vector labels seed an X25519 key; Ed25519 and X25519 share the seed value.
  const phoneEphSeed = testIdentity(VECTORS.labels.phoneEph)
  const pcEphSeed = testIdentity(VECTORS.labels.pcEph)
  const phoneEphKey = x25519FromSeed(phoneEphSeed.seed)
  const pcEphKey = x25519FromSeed(pcEphSeed.seed)
  const initiator = new HandshakeInitiator({
    identity: phone,
    pcMachineId: VECTORS.handshake.to,
    pcPublicKey: pc.publicKey,
    sid: VECTORS.handshake.sid,
    eph: phoneEphKey,
    nonce: b64urlDecode(VECTORS.handshake.phone_nonce, { length: 32 }),
  })
  const responder = new HandshakeResponder({
    identity: pc,
    phoneMachineId: VECTORS.handshake.from,
    phonePublicKey: phone.publicKey,
    eph: pcEphKey,
    nonce: b64urlDecode(VECTORS.handshake.pc_nonce, { length: 32 }),
  })
  return { initiator, responder, phoneEphKey, pcEphKey }
}

test('handshake: transcripts, init/resp/confirm/reject and derived keys match the vectors', () => {
  const { initiator, responder } = fixedHandshake()
  assert.deepEqual(initiator.buildInit(), VECTORS.handshake.init)
  const response = responder.respond(initiator.buildInit(), {
    from: VECTORS.handshake.from,
    to: VECTORS.handshake.to,
    sid: VECTORS.handshake.sid,
  })
  assert.deepEqual(response.resp, VECTORS.handshake.resp)
  const confirm = initiator.acceptResp(response.resp)
  assert.deepEqual(confirm, VECTORS.handshake.confirm)
  const accepted = responder.acceptConfirm(confirm)
  assert.equal(response.th1.toString('hex'), VECTORS.handshake.transcripts.th1_hex)
  assert.equal(response.th2.toString('hex'), VECTORS.handshake.transcripts.th2_hex)
  assert.equal(b64urlEncode(accepted.keys.phoneToPc), VECTORS.handshake.keys.phone_to_pc)
  assert.equal(b64urlEncode(accepted.keys.pcToPhone), VECTORS.handshake.keys.pc_to_phone)
  assert.equal(b64urlEncode(accepted.keys.confirmPhone), VECTORS.handshake.keys.confirm_phone)
  assert.equal(b64urlEncode(accepted.keys.confirmPc), VECTORS.handshake.keys.confirm_pc)
  const reject = verifySessionReject(pc.publicKey, VECTORS.handshake.reject, {
    sid: VECTORS.handshake.sid,
    th1: response.th1,
  })
  assert.equal(reject.code, 'unpaired')
  assert.equal(rejectTranscript(response.th1, 'unpaired').toString('hex'), VECTORS.handshake.transcripts.reject_hex)
})

test('AEAD: all nine golden frames open and reseal byte-identically', () => {
  const { initiator, responder } = fixedHandshake()
  const response = responder.respond(initiator.buildInit(), { from: VECTORS.handshake.from, to: VECTORS.handshake.to, sid: VECTORS.handshake.sid })
  initiator.acceptResp(response.resp)
  for (const frame of VECTORS.frames) {
    const key = frame.direction === 'phone_to_pc' ? initiator.keys.phoneToPc : initiator.keys.pcToPhone
    const plaintext = openE2eBody({ key, sid: frame.sid, seq: frame.seq, from: frame.from, to: frame.to, body: frame.body })
    assert.equal(plaintext.toString('utf8'), frame.plaintext)
    assert.equal(hexEncode(aadBytes(frame)), frame.aad_hex)
    assert.equal(hexEncode(aeadNonce(frame.seq)), frame.nonce_hex)
    assert.equal(sealE2eBody({ key, sid: frame.sid, seq: frame.seq, from: frame.from, to: frame.to, plaintext: frame.plaintext }), frame.body)
    assert.equal(validateInnerMessage(JSON.parse(frame.plaintext)).type, frame.inner_type)
  }
})

test('chunking: golden small/result/interleaved/threshold sequences reassemble', () => {
  const small = VECTORS.chunking.small
  const smallBytes = Buffer.from(JSON.stringify(small.value), 'utf8')
  assert.deepEqual(splitChunks(smallBytes, small.chunk_bytes), small.chunks)
  const reassembler = new ChunkReassembler()
  let completed
  for (const chunk of small.chunks) {
    completed = reassembler.push({ type: 'rpc.stream.chunk', streamId: 's', ...chunk })
  }
  assert.equal(completed.complete, true)
  assert.deepEqual(completed.value, small.value)
  assert.equal(hexEncode(sha256(Buffer.from(JSON.stringify(completed.value), 'utf8'))), small.reassembled_sha256)

  const result = VECTORS.chunking.result_chunk
  const resultBytes = Buffer.from(JSON.stringify(result.result), 'utf8')
  assert.deepEqual(splitChunks(resultBytes, result.chunk_bytes), result.chunks)

  const interleave = VECTORS.chunking.interleave
  const interleaver = new ChunkReassembler()
  const values = {}
  for (const event of interleave.events) {
    const done = interleaver.push({ type: 'rpc.stream.chunk', ...event })
    if (done.complete) values[done.key] = done.value
  }
  assert.deepEqual(values['stream:stream-a'], interleave.values['stream-a'])
  assert.deepEqual(values['stream:stream-b'], interleave.values['stream-b'])
  assert.equal(hexEncode(sha256(Buffer.from(JSON.stringify(values['stream:stream-a']), 'utf8'))), interleave.reassembled_sha256['stream-a'])

  const threshold = VECTORS.chunking.threshold
  const value = threshold.repeat.repeat(threshold.repeat_count)
  const encoded = encodeStreamValue('stream-t', value, 1_048_576)
  assert.equal(encoded.kind, 'chunks')
  assert.equal(encoded.frames.length, threshold.parts)
  const last = encoded.frames[encoded.frames.length - 1]
  assert.equal(last.last, threshold.last_last)
  const thresholdReassembler = new ChunkReassembler()
  let final
  for (const frame of encoded.frames) final = thresholdReassembler.push(frame)
  assert.equal(final.value, value)
  assert.equal(hexEncode(sha256(Buffer.from(JSON.stringify(final.value), 'utf8'))), threshold.reassembled_sha256)
})

test('chunking: interleaved sequences do not mix and expiry discards partials', () => {
  const reassembler = new ChunkReassembler({ now: () => 0 })
  reassembler.push({ type: 'rpc.stream.chunk', streamId: 'stream-a', part: 0, last: false, data: b64urlEncode(Buffer.from('aa')) })
  reassembler.push({ type: 'rpc.stream.chunk', streamId: 'stream-b', part: 0, last: true, data: b64urlEncode(Buffer.from('"bb"')) })
  reassembler.push({ type: 'rpc.stream.chunk', streamId: 'stream-a', part: 1, last: false, data: b64urlEncode(Buffer.from('aa')) })
  assert.equal(reassembler.size, 1)
  const dropped = reassembler.expire(30_001)
  assert.deepEqual(dropped, ['stream:stream-a'])
  assert.equal(reassembler.size, 0)
})

test('pairing: QR, Crockford manual code, origin-bound rendezvous and keyC MACs', () => {
  const qr = parseQrUri(VECTORS.pairing.qr.uri)
  assert.deepEqual(
    { origin: qr.origin, machineId: qr.machineId, publicKey: qr.publicKey, secret: qr.secret, name: qr.name, ws_url: qr.wsUrl },
    VECTORS.pairing.qr.parsed,
  )
  const manual = VECTORS.pairing.manual
  assert.equal(crockfordEncode(Buffer.from(manual.secret_hex, 'hex')), manual.canonical)
  assert.equal(formatManualCode(manual.canonical), manual.display)
  for (const input of manual.equivalent_inputs) assert.equal(normalizeManualCode(input), manual.normalized)
  assert.equal(rendezvousFor(Buffer.from(manual.secret_hex, 'hex'), VECTORS.pairing.origin), manual.rendezvous)
  assert.equal(rendezvousFor(Buffer.from(VECTORS.pairing.secret_s, 'base64url'), VECTORS.pairing.origin), VECTORS.pairing.rendezvous_s)
  assert.notEqual(rendezvousFor(Buffer.from(VECTORS.pairing.secret_s, 'base64url'), VECTORS.pairing.origin), VECTORS.pairing.rendezvous_s_other_origin)
  assert.equal(b64urlEncode(pairKeyFor(Buffer.from(manual.secret_hex, 'hex'))), manual.pair_key)
  assert.equal(b64urlEncode(pairKeyFor(Buffer.from(VECTORS.pairing.secret_s, 'base64url'))), VECTORS.pairing.pair_key_s)
  const pairKey = pairKeyFor(Buffer.from(manual.secret_hex, 'hex'))
  for (const domain of ['hello', 'auth', 'confirm', 'final']) {
    assert.equal(b64urlEncode(pairMac(pairKey, PAIR_DOMAINS[domain], manual[domain])), manual[domain].mac)
  }
})

test('pairing: audit pair entry, record hash and usable/revoked evaluation', () => {
  const audit = VECTORS.pairing.audit
  assert.deepEqual(buildAuditPairEntry(audit.approved_usable.record, audit.pair_entry.at), audit.pair_entry)
  assert.equal(evaluateRecordAudit(audit.approved_usable.record, audit.approved_usable.audit).usable, true)
  assert.equal(evaluateRecordAudit(VECTORS.resources.confirm_recheck.revoked.record, VECTORS.resources.confirm_recheck.revoked.audit).reason, 'revoked')
})

test('pairing: approval fingerprint normalization, wrong phone blocked', () => {
  const approval = VECTORS.pairing.approval
  for (const input of approval.accepted_inputs) {
    assert.equal(normalizeFingerprintInput(input), approval.peerMachineId.slice(0, 12))
    assert.equal(fingerprintMatches(approval.peerMachineId, input), true)
  }
  assert.equal(fingerprintMatches(approval.peerMachineId, approval.rejected_input), false)
})

test('admin proof HMAC vector', () => {
  const proof = adminProof(b64urlDecode(VECTORS.admin_proof.token, { length: 32 }), b64urlDecode(VECTORS.admin_proof.nonce, { length: 32 }))
  assert.equal(b64urlEncode(proof), VECTORS.admin_proof.proof)
})

test('resources: sid cache limit/eviction and model constants match', async () => {
  const { SidCache } = await import('../plugin/session-manager.mjs')
  const cache = new SidCache({ limit: VECTORS.resources.sid_cache.limit })
  const sidFor = index => {
    const bytes = Buffer.alloc(16)
    bytes.writeUInt32BE(index, 12)
    return b64urlEncode(bytes)
  }
  for (let index = 0; index < VECTORS.resources.sid_cache.cases[0].entries; index += 1) cache.set(sidFor(index), { state: 'rejected' })
  assert.equal(cache.entries.size, 4096)
  const first = cache.entries.keys().next().value
  cache.set(sidFor(5000), { state: 'rejected' })
  if (cache.entries.size > 4096) throw new Error('cache exceeded its limit')
  assert.equal(cache.entries.has(first), false)
  assert.equal(VECTORS.chunking.seq_rekey, 524_288)
  assert.equal(VECTORS.chunking.seq_max, SEQ_MAX)
  assert.equal(MAX_FRAME_BYTES, VECTORS.chunking.max_frame_bytes)
  assert.equal(MAX_VALUE_BYTES, VECTORS.chunking.max_value_bytes)
})

// Every invalid row with `evidence:"crypto"` goes through a real codec below.
test('invalid crypto rows are all rejected with their expected code', async () => {
  const handled = new Set()
  for (const row of VECTORS.invalid) {
    if (row.evidence !== 'crypto') continue
    handled.add(row.case)
    switch (row.kind) {
      case 'handshake_signature':
        assert.equal(ed25519Verify(b64urlDecode(row.public_key, { length: 32 }), Buffer.from(row.transcript_hex, 'hex'), b64urlDecode(row.signature, { length: 64 })), false, row.case)
        break
      case 'handshake_transcript': {
        const transcript = initTranscript({
          phoneMachineId: row.from,
          pcMachineId: row.to,
          sid: row.init.sid,
          suite: row.init.suite,
          ephPhone: b64urlDecode(row.init.eph, { length: 32 }),
          noncePhone: b64urlDecode(row.init.nonce, { length: 32 }),
          version: String(row.init.v),
        })
        assert.notEqual(hexEncode(sha256(transcript)), row.reference_hex, row.case)
        if (row.case === 'hs-init-suite-mutated') {
          const responder = new HandshakeResponder({ identity: pc, phoneMachineId: phone.machineId, phonePublicKey: phone.publicKey })
          assert.throws(() => responder.respond(row.init, { from: row.from, to: row.to, sid: row.init.sid }), error => error.code === 'version_unsupported')
        }
        break
      }
      case 'x25519': {
        const privateKey = x25519FromSeed(testIdentity(row.private_label).seed)
        assert.throws(() => x25519Dh(privateKey, b64urlDecode(row.public_key, { length: 32 })), error => error.code === 'auth_failed', row.case)
        break
      }
      case 'sid_mismatch': {
        assert.notEqual(row.outer_sid, row.body_sid)
        assert.throws(() => {
          const outer = { v: 1, type: 'e2e.handshake', sid: row.outer_sid, from: phone.machineId, to: pc.machineId, body: { v: 1, type: 'session.init', sid: row.body_sid, suite: VECTORS.suite, eph: VECTORS.handshake.phone_eph.public_key, nonce: VECTORS.handshake.phone_nonce } }
          const { HandshakeResponder: Responder } = requireHandshake()
          new Responder({ identity: pc, phoneMachineId: phone.machineId, phonePublicKey: phone.publicKey }).respond(outer.body, outer)
        }, error => error.code === 'bad_frame')
        break
      }
      case 'aead': {
        const frame = row.frame
        const key = row.key_direction === 'pc_to_phone'
          ? deriveHandshakeKeys(
            x25519Dh(x25519FromSeed(testIdentity(VECTORS.labels.phoneEph).seed).privateKey, b64urlDecode(VECTORS.handshake.pc_eph.public_key, { length: 32 })),
            sha256(Buffer.from(VECTORS.handshake.transcripts.resp_hex, 'hex')),
          ).pcToPhone
          : row.key_b64 !== undefined
            ? b64urlDecode(row.key_b64, { length: 32 })
            : (() => {
              const dh = x25519Dh(x25519FromSeed(testIdentity(VECTORS.labels.phoneEph).seed).privateKey, b64urlDecode(VECTORS.handshake.pc_eph.public_key, { length: 32 }))
              return deriveHandshakeKeys(dh, sha256(Buffer.from(VECTORS.handshake.transcripts.resp_hex, 'hex'))).phoneToPc
            })()
        const crypto = new FrameCrypto({
          sendKey: Buffer.alloc(32),
          recvKey: key,
          sid: VECTORS.handshake.sid,
          from: pc.machineId,
          to: phone.machineId,
        })
        crypto.lastSeq = 0
        assert.throws(() => crypto.open(frame), error => error.code === 'auth_failed', row.case)
        break
      }
      case 'seq': {
        const outcome = row.bytes !== undefined
          ? classifyBytes({ bytes: row.bytes - 1, added: 1, hardBytes: 2_147_483_648 })
          : classifySequence({ ...row, lastSeq: row.last_seq })
        assert.equal(outcome, row.expected, row.case)
        break
      }
      case 'encoding':
        assert.throws(() => b64urlDecode(row.text), error => error.code === 'bad_frame', row.case)
        break
      case 'canonical':
        assert.notEqual(canonicalJson(parseStrictJsonObject(row.candidate)), row.candidate, row.case)
        break
      case 'chunk': {
        const reassembler = new ChunkReassembler()
        if (row.bytes !== undefined) {
          const tooLarge = new ChunkReassembler({ maxBytes: 1 })
          assert.throws(() => tooLarge.push({ type: 'rpc.stream.chunk', streamId: 'x', part: 0, last: false, data: b64urlEncode(Buffer.from('aa')) }), error => error.code === 'frame_too_large')
          break
        }
        if (row.case === 'chunk-interleave-missing-last') {
          const reassemblerWithClock = new ChunkReassembler({ now: () => 0 })
          // The incomplete interleaved value is never delivered; the 30 s
          // timeout discards it rather than exposing a partial value.
          let failure
          try {
            for (const event of row.events) reassemblerWithClock.push({ type: 'rpc.stream.chunk', ...event })
          } catch (error) {
            failure = error
          }
          if (failure !== undefined) {
            assert.equal(failure.code, 'bad_frame', row.case)
          } else {
            assert.equal(reassemblerWithClock.size, 1)
            assert.deepEqual(reassemblerWithClock.expire(30_001), ['stream:stream-a'])
          }
          break
        }
        assert.throws(() => {
          for (const event of row.events) reassembler.push({ type: 'rpc.stream.chunk', ...event })
        }, error => error.code === 'bad_frame', row.case)
        break
      }
      case 'qr': {
        if (row.case === 'qr-key-swap') {
          const parsed = parseQrUri(row.uri)
          assert.notEqual(parsed.publicKey, row.expected_public_key, row.case)
          break
        }
        if (row.case === 'qr-machineid-mismatch') {
          assert.throws(() => parseQrUri(row.uri), error => error.code === 'auth_failed', row.case)
          break
        }
        if (row.expected === 'auth_failed') {
          assert.throws(() => parseQrUri(row.uri), error => error.code === 'auth_failed', row.case)
        } else {
          assert.throws(() => parseQrUri(row.uri), error => error.code === 'bad_frame', row.case)
        }
        break
      }
      case 'manual':
        assert.throws(() => normalizeManualCode(row.input), error => error.code === 'bad_frame', row.case)
        break
      case 'name':
        assert.throws(() => validateName(row.name), error => error.code === 'bad_frame', row.case)
        break
      case 'origin':
        assert.throws(() => requireSameOrigin(row.actual, row.expected_origin), error => error.code === 'auth_failed', row.case)
        break
      case 'unknown_code':
        assert.equal(isPclinkCode(row.code), false)
        assert.throws(() => validateRelayError({ v: 1, type: 'relay.error', code: row.code }), error => error.code === 'bad_frame', row.case)
        assert.equal(SESSION_CLOSE_CODES.includes(row.code), false)
        break
      case 'frame':
        assert.throws(() => validateE2eFrame(row.frame), error => error.code === 'bad_frame', row.case)
        break
      case 'size':
        if (row.bytes === 16_777_217) assert.throws(() => parseRelayFrame('x'.repeat(row.bytes)), error => error.code === 'frame_too_large')
        else assert.throws(() => encodeStreamValue('s', 'x'.repeat(row.bytes)), error => error.code === 'frame_too_large')
        break
      case 'suite': {
        const init = { ...VECTORS.handshake.init, suite: row.suite }
        const responder = new HandshakeResponder({ identity: pc, phoneMachineId: phone.machineId, phonePublicKey: phone.publicKey })
        assert.throws(() => responder.respond(init, { from: phone.machineId, to: pc.machineId, sid: init.sid }), error => error.code === 'version_unsupported')
        break
      }
      case 'caps':
        assert.deepEqual(missingRequiredCaps(row.caps), row.required.filter(cap => !row.caps.includes(cap)))
        assert.throws(() => {
          const hello = { v: 1, type: 'peer.hello', role: 'phone', caps: row.caps, dsh: { version: '0.2.2-rc.1' }, app: { name: 'phoneDSH', version: '0.1.0' }, name: 'iPhone' }
          validateInnerMessage(hello)
          if (missingRequiredCaps(hello.caps).length > 0) throw Object.assign(new Error('no caps intersection'), { code: 'version_unsupported' })
        }, error => error.code === 'version_unsupported')
        break
      case 'reject_transcript': {
        const signature = b64urlDecode(row.signature, { length: 64 })
        const ok = ed25519Verify(b64urlDecode(row.public_key, { length: 32 }), rejectTranscript(Buffer.from(row.signed_th1_hex, 'hex'), row.signed_code), signature)
        const verified = ed25519Verify(b64urlDecode(row.public_key, { length: 32 }), rejectTranscript(Buffer.from(row.verified_th1_hex, 'hex'), row.verified_code), signature)
        assert.equal(ok, true)
        assert.equal(verified, false, row.case)
        break
      }
      case 'pair_mac': {
        const key = b64urlDecode(row.pair_key_b64, { length: 32 })
        assert.notEqual(b64urlEncode(pairMac(key, row.domain, row.object)), row.object.mac, row.case)
        break
      }
      case 'fingerprint': {
        const machineId = machineIdFromPublicKey(b64urlDecode(row.public_key, { length: 32 }))
        assert.equal(fingerprintMatches(machineId, row.entered), false, row.case)
        break
      }
      case 'cross_sid': {
        assert.notEqual(row.expected_sid, row.message_sid)
        if (row.message_type === 'session.resp') {
          const { initiator } = fixedHandshake()
          const resp = { ...VECTORS.handshake.resp, sid: row.message_sid }
          assert.throws(() => initiator.acceptResp(resp), error => error.code === 'replay', row.case)
        } else {
          // Confirm cross-sid is a SessionManager replay decision; exercised
          // in plugin.test.mjs with the real pending-handshake state machine.
          assert.equal(row.message_type, 'session.confirm')
        }
        break
      }
      default:
        throw new Error(`unhandled crypto invalid row ${row.case} (${row.kind})`)
    }
  }
  assert.equal(handled.size, VECTORS.invalid.filter(row => row.evidence === 'crypto').length)
})

function requireHandshake() {
  return {
    HandshakeResponder,
  }
}
