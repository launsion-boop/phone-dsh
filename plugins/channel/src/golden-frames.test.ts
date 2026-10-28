// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  bytesToHex, canonicalStringify, decodeUtf8, encodeUtf8, FrameDecoder, FrameError,
  FrameType, hexToBytes, isFrameType, MAX_FRAME_PAYLOAD,
  decodeApiAbort, decodeApiEnd, decodeApiRequest, decodeApiResponse,
  decodeJournal, decodeJournalAck, decodeVfsAck, decodeVfsBarrier, decodeVfsMutation, decodeVfsResync,
  encodeApiAbort, encodeApiEnd, encodeApiRequest, encodeApiResponse,
  encodeFrame, encodeJournal, encodeJournalAck, encodeVfsAck, encodeVfsBarrier, encodeVfsMutation, encodeVfsResync,
  type ApiRequestHead, type ApiResponseHead, type Frame, type VfsMutation,
} from './index.ts'

interface GoldenFrame {
  readonly type: string
  readonly type_byte: number
  readonly seq: number
  readonly fields: unknown
  readonly payload_hex: string
  readonly frame_hex: string
}

const goldenRoot = join(dirname(fileURLToPath(import.meta.url)), '../../../spec/v1/golden')
const framesDir = join(goldenRoot, 'frames')
const JSON_FRAME_TYPES = new Set<number>([
  FrameType.HELLO,
  FrameType.EXEC_REQ,
  FrameType.EXEC_EVT,
  FrameType.EXEC_CTL,
  FrameType.LIFECYCLE,
  FrameType.CONSOLE,
  FrameType.FENCE,
  FrameType.ERROR,
])
const goldenFiles = readdirSync(framesDir).filter(name => name.endsWith('.json')).sort()
const goldens = goldenFiles.map((name) => {
  const golden = JSON.parse(readFileSync(join(framesDir, name), 'utf8')) as GoldenFrame
  return { name, golden }
})

function fieldsOf(golden: GoldenFrame): Record<string, unknown> {
  return golden.fields as Record<string, unknown>
}

function numberField(fields: Record<string, unknown>, name: string): number {
  const value = fields[name]
  if (typeof value !== 'number') throw new TypeError(`golden field ${name} is not a number`)
  return value
}

function stringField(fields: Record<string, unknown>, name: string): string {
  const value = fields[name]
  if (typeof value !== 'string') throw new TypeError(`golden field ${name} is not a string`)
  return value
}

function levelField(fields: Record<string, unknown>, name: string): 1 | 2 {
  const value = numberField(fields, name)
  if (value !== 1 && value !== 2) throw new TypeError(`golden field ${name} is not 1 or 2`)
  return value
}

function encodeGoldenPayload(typeByte: number, fields: Record<string, unknown>): Uint8Array {
  switch (typeByte) {
    case FrameType.VFS_MUT: {
      const data = hexToBytes(stringField(fields, 'data_hex'))
      assert.equal(numberField(fields, 'data_len'), data.byteLength)
      const mutation: VfsMutation = {
        mseq: BigInt(numberField(fields, 'mseq')),
        op: numberField(fields, 'op') as VfsMutation['op'],
        mode: numberField(fields, 'mode'),
        mflags: numberField(fields, 'mflags'),
        appendFrom: BigInt(numberField(fields, 'append_from')),
        path: stringField(fields, 'path'),
        data,
      }
      return encodeVfsMutation(mutation)
    }
    case FrameType.VFS_ACK:
      return encodeVfsAck({ level: levelField(fields, 'level'), uptoMseq: BigInt(numberField(fields, 'upto_mseq')) })
    case FrameType.VFS_BARRIER:
      return encodeVfsBarrier({ wantLevel: levelField(fields, 'want_level'), uptoMseq: BigInt(numberField(fields, 'upto_mseq')) })
    case FrameType.VFS_RESYNC:
      return encodeVfsResync({ path: stringField(fields, 'path') })
    case FrameType.JOURNAL:
      return encodeJournal({
        jseq: BigInt(numberField(fields, 'jseq')),
        sessionId: stringField(fields, 'session_id'),
        record: hexToBytes(stringField(fields, 'record_hex')),
      })
    case FrameType.JOURNAL_ACK:
      return encodeJournalAck({
        level: levelField(fields, 'level'),
        sessionId: stringField(fields, 'session_id'),
        uptoJseq: BigInt(numberField(fields, 'upto_jseq')),
      })
    case FrameType.API_REQ:
      return encodeApiRequest({
        reqId: numberField(fields, 'req_id'),
        head: fields['head'] as ApiRequestHead,
        body: hexToBytes(stringField(fields, 'body_hex')),
      })
    case FrameType.API_RES:
      return encodeApiResponse({
        reqId: numberField(fields, 'req_id'),
        head: fields['head'] === null ? undefined : fields['head'] as ApiResponseHead,
        body: hexToBytes(stringField(fields, 'body_hex')),
      })
    case FrameType.API_END:
      return encodeApiEnd(numberField(fields, 'req_id'))
    case FrameType.API_ABORT:
      return encodeApiAbort(numberField(fields, 'req_id'), stringField(fields, 'reason'))
    default:
      if (JSON_FRAME_TYPES.has(typeByte)) return encodeUtf8(canonicalStringify(fields))
      throw new Error(`no encoder for golden type byte ${typeByte}`)
  }
}

function fieldify(typeByte: number, payload: Uint8Array): unknown {
  switch (typeByte) {
    case FrameType.VFS_MUT: {
      const mutation = decodeVfsMutation(payload)
      return {
        mseq: Number(mutation.mseq),
        op: mutation.op,
        mode: mutation.mode,
        mflags: mutation.mflags,
        append_from: Number(mutation.appendFrom),
        path: mutation.path,
        data_len: mutation.data.byteLength,
        data_hex: bytesToHex(mutation.data),
      }
    }
    case FrameType.VFS_ACK: {
      const ack = decodeVfsAck(payload)
      return { level: ack.level, upto_mseq: Number(ack.uptoMseq) }
    }
    case FrameType.VFS_BARRIER: {
      const barrier = decodeVfsBarrier(payload)
      return { want_level: barrier.wantLevel, upto_mseq: Number(barrier.uptoMseq) }
    }
    case FrameType.VFS_RESYNC:
      return { path: decodeVfsResync(payload).path }
    case FrameType.JOURNAL: {
      const journal = decodeJournal(payload)
      return { jseq: Number(journal.jseq), session_id: journal.sessionId, record_hex: bytesToHex(journal.record) }
    }
    case FrameType.JOURNAL_ACK: {
      const ack = decodeJournalAck(payload)
      return { level: ack.level, session_id: ack.sessionId, upto_jseq: Number(ack.uptoJseq) }
    }
    case FrameType.API_REQ: {
      const request = decodeApiRequest(payload)
      return { req_id: request.reqId, head: request.head, body_hex: bytesToHex(request.body) }
    }
    case FrameType.API_RES: {
      const response = decodeApiResponse(payload)
      return { req_id: response.reqId, head: response.head ?? null, body_hex: bytesToHex(response.body) }
    }
    case FrameType.API_END:
      return { req_id: decodeApiEnd(payload) }
    case FrameType.API_ABORT: {
      const abort = decodeApiAbort(payload)
      return { req_id: abort.reqId, reason: abort.reason }
    }
    default:
      return JSON.parse(decodeUtf8(payload)) as unknown
  }
}

test('the golden directory has a vector for every one of the 18 frame types', () => {
  assert.ok(goldens.length >= 18)
  const covered = new Set(goldens.map(({ golden }) => golden.type_byte))
  for (const type of Object.values(FrameType)) {
    assert.ok(covered.has(type), `missing golden vector for type byte 0x${type.toString(16)}`)
  }
})

for (const { name, golden } of goldens) {
  test(`golden ${name} encodes and decodes byte-exactly`, () => {
    const payload = encodeGoldenPayload(golden.type_byte, fieldsOf(golden))
    assert.equal(bytesToHex(payload), golden.payload_hex, 'payload bytes')

    const frameBytes = encodeFrame({
      type: golden.type_byte as FrameType,
      seq: BigInt(golden.seq),
      payload,
    })
    assert.equal(bytesToHex(frameBytes), golden.frame_hex, 'frame bytes')

    const decoded = new FrameDecoder().push(hexToBytes(golden.frame_hex))
    assert.equal(decoded.length, 1)
    const frame = decoded[0]!
    assert.equal(frame.type, golden.type_byte)
    assert.equal(frame.seq, BigInt(golden.seq))
    assert.deepEqual(fieldify(golden.type_byte, frame.payload), golden.fields)

    if (JSON_FRAME_TYPES.has(golden.type_byte)) {
      const text = decodeUtf8(frame.payload)
      const parsed = JSON.parse(text) as unknown
      assert.deepEqual(parsed, golden.fields, 'semantic JSON')
      assert.equal(canonicalStringify(parsed), text, 'canonical re-encoding')
    }
  })
}

function groupedFrames(): Uint8Array {
  return hexToBytes(goldens.map(({ golden }) => golden.frame_hex).join(''))
}

test('streaming decode accepts one byte at a time', () => {
  const decoder = new FrameDecoder()
  const decoded: Frame[] = []
  for (const byte of groupedFrames()) decoded.push(...decoder.push(Uint8Array.of(byte)))
  assert.equal(decoded.length, goldens.length)
  for (let index = 0; index < decoded.length; index++) {
    assert.equal(bytesToHex(encodeFrame(decoded[index]!)), goldens[index]!.golden.frame_hex)
  }
})

function mulberry32(seed: number): () => number {
  let state = seed
  return () => {
    state = (state + 0x6d2b79f5) | 0
    let value = Math.imul(state ^ (state >>> 15), 1 | state)
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296
  }
}

test('streaming decode accepts deterministic random chunk boundaries', () => {
  const random = mulberry32(0x5a4c)
  const decoder = new FrameDecoder()
  const decoded: Frame[] = []
  const all = groupedFrames()
  let offset = 0
  while (offset < all.byteLength) {
    const size = 1 + Math.floor(random() * 17)
    decoded.push(...decoder.push(all.subarray(offset, offset + size)))
    offset += size
  }
  assert.equal(decoded.length, goldens.length)
  for (let index = 0; index < decoded.length; index++) {
    assert.equal(bytesToHex(encodeFrame(decoded[index]!)), goldens[index]!.golden.frame_hex)
  }
})

test('a partial header and a partial payload decode to nothing until complete', () => {
  const bytes = hexToBytes(goldens[0]!.golden.frame_hex)
  for (let prefix = 0; prefix < 16; prefix++) {
    const decoder = new FrameDecoder()
    assert.deepEqual(decoder.push(bytes.subarray(0, prefix)), [])
    assert.equal(decoder.push(bytes.subarray(prefix)).length, 1)
  }
  const decoder = new FrameDecoder()
  assert.deepEqual(decoder.push(bytes.subarray(0, bytes.byteLength - 1)), [])
  assert.equal(decoder.buffered, bytes.byteLength - 1)
  assert.equal(decoder.push(bytes.subarray(bytes.byteLength - 1)).length, 1)
  assert.equal(decoder.buffered, 0)
})

function expectFrameError(action: () => unknown, code: FrameError['code']): void {
  assert.throws(action, (error: unknown) => error instanceof FrameError && error.code === code)
}

test('header violations are typed errors', () => {
  const valid = hexToBytes(goldens[0]!.golden.frame_hex)

  const badMagic = valid.slice()
  badMagic[1] = 0x4d
  expectFrameError(() => new FrameDecoder().push(badMagic), 'BAD_MAGIC')

  const badFlags = valid.slice()
  badFlags[3] = 1
  expectFrameError(() => new FrameDecoder().push(badFlags), 'BAD_PAYLOAD')

  const zeroLength = hexToBytes('5a4c0100000000000000000100000000')
  expectFrameError(() => new FrameDecoder().push(zeroLength), 'BAD_PAYLOAD')

  const overLimit = hexToBytes('5a4c0100000000000000000101000001')
  expectFrameError(() => new FrameDecoder().push(overLimit), 'BAD_PAYLOAD')

  const overSixtyFourMib = hexToBytes('5a4c0100000000000000000104000001')
  expectFrameError(() => new FrameDecoder().push(overSixtyFourMib), 'BAD_PAYLOAD')

  const unknownType = hexToBytes('5a4c0200000000000000000100000001ff')
  expectFrameError(() => new FrameDecoder().push(unknownType), 'BAD_PAYLOAD')

  assert.equal(MAX_FRAME_PAYLOAD, 16 * 1024 * 1024)
  assert.equal(isFrameType(0x02), false)
})

test('the decoder keeps a rejected connection state local', () => {
  const valid = hexToBytes(goldens[0]!.golden.frame_hex)
  const badMagic = valid.slice()
  badMagic[0] = 0
  expectFrameError(() => new FrameDecoder().push(badMagic), 'BAD_MAGIC')
  const decoder = new FrameDecoder()
  assert.equal(decoder.push(valid).length, 1)
})
