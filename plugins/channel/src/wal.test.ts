// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  bytesToHex, concatBytes, crc32c, decodeWalRecord, decodeWalSegmentHeader, encodeWalRecord,
  encodeWalSegmentHeader, hexToBytes, WalError, WAL_SEGMENT_HEADER_SIZE,
  type VfsMutationBody, type WalRecord, type VfsOp,
} from './index.ts'

interface GoldenRecord {
  readonly kind: 'mutation' | 'epoch_close'
  readonly fields: Record<string, unknown>
  readonly crc32c: number
  readonly record_hex: string
}

interface GoldenWal {
  readonly header: {
    readonly format: number
    readonly reserved: number
    readonly first_mseq: number
    readonly boot_id_hex: string
    readonly header_crc32c: number
    readonly header_hex: string
  }
  readonly records: readonly GoldenRecord[]
  readonly file_hex: string
}

const walDir = join(dirname(fileURLToPath(import.meta.url)), '../../../spec/v1/golden/wal')
const walFiles = readdirSync(walDir).filter(name => name.endsWith('.json')).sort()
const vectors = walFiles.map((name) => ({
  name,
  golden: JSON.parse(readFileSync(join(walDir, name), 'utf8')) as GoldenWal,
}))

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

function mutationBody(fields: Record<string, unknown>): VfsMutationBody {
  const data = hexToBytes(stringField(fields, 'data_hex'))
  assert.equal(numberField(fields, 'data_len'), data.byteLength)
  return {
    op: numberField(fields, 'op') as VfsOp,
    mode: numberField(fields, 'mode'),
    mflags: numberField(fields, 'mflags'),
    appendFrom: BigInt(numberField(fields, 'append_from')),
    path: stringField(fields, 'path'),
    data,
  }
}

function encodeGoldenRecord(record: GoldenRecord): Uint8Array {
  const fields = record.fields
  if (record.kind === 'mutation') {
    return encodeWalRecord({
      kind: 'mutation',
      mseq: BigInt(numberField(fields, 'mseq')),
      mutation: mutationBody(fields),
    })
  }
  return encodeWalRecord({
    kind: 'epoch_close',
    mseq: BigInt(numberField(fields, 'mseq')),
    wallMs: BigInt(numberField(fields, 'wall_ms')),
    durableUpto: BigInt(numberField(fields, 'durable_upto')),
  })
}

function fieldifyRecord(record: WalRecord): { kind: string; fields: Record<string, unknown> } {
  if (record.kind === 'mutation') {
    return {
      kind: 'mutation',
      fields: {
        mseq: Number(record.mseq),
        op: record.mutation.op,
        mode: record.mutation.mode,
        mflags: record.mutation.mflags,
        append_from: Number(record.mutation.appendFrom),
        path: record.mutation.path,
        data_len: record.mutation.data.byteLength,
        data_hex: bytesToHex(record.mutation.data),
      },
    }
  }
  return {
    kind: 'epoch_close',
    fields: {
      mseq: Number(record.mseq),
      op: 0xff,
      wall_ms: Number(record.wallMs),
      durable_upto: Number(record.durableUpto),
    },
  }
}

for (const { name, golden } of vectors) {
  test(`WAL golden ${name} header round-trips byte-exactly`, () => {
    const bytes = encodeWalSegmentHeader({
      firstMseq: BigInt(golden.header.first_mseq),
      bootId: hexToBytes(golden.header.boot_id_hex),
    })
    assert.equal(bytes.byteLength, WAL_SEGMENT_HEADER_SIZE)
    assert.equal(bytesToHex(bytes), golden.header.header_hex)
    const decoded = decodeWalSegmentHeader(bytes)
    assert.equal(decoded.format, golden.header.format)
    assert.equal(decoded.reserved, golden.header.reserved)
    assert.equal(decoded.firstMseq, BigInt(golden.header.first_mseq))
    assert.equal(bytesToHex(decoded.bootId), golden.header.boot_id_hex)
    assert.equal(decoded.headerCrc32c, golden.header.header_crc32c)
  })

  test(`WAL golden ${name} records round-trip with CRC verification`, () => {
    for (const record of golden.records) {
      const bytes = encodeGoldenRecord(record)
      assert.equal(bytesToHex(bytes), record.record_hex)
      assert.equal(crc32c(bytes.subarray(8)), record.crc32c)
      const decoded = decodeWalRecord(bytes)
      assert.equal(decoded.crc32c, record.crc32c)
      const view = fieldifyRecord(decoded)
      assert.equal(view.kind, record.kind)
      assert.deepEqual(view.fields, record.fields)
    }
  })

  test(`WAL golden ${name} file is header followed by every record`, () => {
    const header = encodeWalSegmentHeader({
      firstMseq: BigInt(golden.header.first_mseq),
      bootId: hexToBytes(golden.header.boot_id_hex),
    })
    const records = golden.records.map(record => encodeGoldenRecord(record))
    assert.equal(bytesToHex(concatBytes([header, ...records])), golden.file_hex)
  })
}

test('the hand-computed wal.md header for first_mseq 1 round-trips', () => {
  const header = encodeWalSegmentHeader({ firstMseq: 1n, bootId: new Uint8Array(16) })
  assert.equal(
    bytesToHex(header),
    '584c57414c310000000100000000000000000001000000000000000000000000000000000b0f9536',
  )
  assert.equal(decodeWalSegmentHeader(header).headerCrc32c, 0x0b0f9536)
})

function expectWalError(action: () => unknown, code: WalError['code']): void {
  assert.throws(action, (error: unknown) => error instanceof WalError && error.code === code)
}

test('header and record corruption is reported with typed WAL errors', () => {
  const golden = vectors[0]!.golden
  const header = encodeWalSegmentHeader({
    firstMseq: BigInt(golden.header.first_mseq),
    bootId: hexToBytes(golden.header.boot_id_hex),
  })
  const corruptHeader = header.slice()
  corruptHeader[20] = corruptHeader[20]! ^ 0xff
  expectWalError(() => decodeWalSegmentHeader(corruptHeader), 'WAL_BAD_HEADER')

  const badMagic = header.slice()
  badMagic[0] = 0
  expectWalError(() => decodeWalSegmentHeader(badMagic), 'WAL_BAD_HEADER')

  const recordBytes = encodeGoldenRecord(golden.records[0]!)
  const corruptRecord = recordBytes.slice()
  corruptRecord[corruptRecord.byteLength - 1] = corruptRecord[corruptRecord.byteLength - 1]! ^ 0xff
  expectWalError(() => decodeWalRecord(corruptRecord), 'WAL_BAD_CRC')

  const truncated = recordBytes.subarray(0, recordBytes.byteLength - 1)
  expectWalError(() => decodeWalRecord(truncated), 'WAL_BAD_RECORD')
})

test('the epoch-close record mseq must equal durable_upto', () => {
  assert.throws(() => encodeWalRecord({
    kind: 'epoch_close',
    mseq: 9n,
    wallMs: 1n,
    durableUpto: 8n,
  }), (error: unknown) => error instanceof WalError && error.code === 'WAL_BAD_RECORD')
})
