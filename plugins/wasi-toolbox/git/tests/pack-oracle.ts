// SPDX-License-Identifier: MIT
/**
 * The pre-optimisation pack parser, kept only as a test oracle.
 *
 * `oracleInflateObject` is the binary-search inflater that ran a full
 * `inflate` for every halving of the remaining pack (about 26 passes per
 * object on a 64 MiB pack). `oracleParsePack` is the old `parsePack`, which
 * kept every decompressed object in memory. Tests compare the one-pass
 * implementation and its metadata against these byte-for-byte.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/pack-oracle
 */
import { inflate } from '../compress.ts'
import { sha1Hex } from '../pack.ts'

/** The old binary-search inflater, kept verbatim as the oracle. */
export function oracleInflateObject(pack: Uint8Array, start: number, expectedSize: number): { data: Uint8Array; length: number } {
  let low = 1
  let high = pack.byteLength - start
  let best: { data: Uint8Array; length: number } | undefined
  while (low <= high) {
    const middle = (low + high) >> 1
    try {
      const data = inflate(pack.subarray(start, start + middle))
      if (data.byteLength === expectedSize) {
        best = { data, length: middle }
        high = middle - 1
      } else {
        low = middle + 1
      }
    } catch {
      low = middle + 1
    }
  }
  if (best === undefined) throw new Error('oracle could not inflate the stream')
  return best
}

export interface OracleObject {
  readonly offset: number
  readonly end: number
  readonly type: number
  readonly data: Uint8Array
}

/** The old `parsePack`, kept as the metadata oracle (including its SHA-1s). */
export async function oracleParsePack(
  pack: Uint8Array,
  readExternal: (oid: string) => Promise<{ type: string; data: Uint8Array } | undefined>,
): Promise<OracleObject[]> {
  const readUint32 = (buffer: Uint8Array, offset: number): number =>
    (((buffer[offset] as number) << 24) | ((buffer[offset + 1] as number) << 16)
      | ((buffer[offset + 2] as number) << 8) | (buffer[offset + 3] as number)) >>> 0
  const toHex = (bytes: Uint8Array): string => Buffer.from(bytes).toString('hex')
  const typeText: Readonly<Record<number, 'commit' | 'tree' | 'blob' | 'tag'>> = {
    1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag',
  }
  if (pack.byteLength < 32 || Buffer.from(pack.subarray(0, 4)).toString() !== 'PACK') throw new Error('not a pack')
  const count = readUint32(pack, 8)
  const objects: OracleObject[] = []
  const byOffset = new Map<number, OracleObject>()
  const byOid = new Map<string, { type: string; data: Uint8Array }>()
  const readAt = async (offset: number): Promise<OracleObject> => {
    let position = offset
    let byte = pack[position++] as number
    const type = (byte >> 4) & 0x07
    let size = byte & 0x0f
    let shift = 4
    while ((byte & 0x80) !== 0) {
      byte = pack[position++] as number
      size += (byte & 0x7f) * 2 ** shift
      shift += 7
    }
    if (type === 6) {
      let distance = (pack[position++] as number) & 0x7f
      let current = pack[position - 1] as number
      while ((current & 0x80) !== 0) {
        current = pack[position++] as number
        distance = (distance + 1) * 128 + (current & 0x7f)
      }
      const baseOffset = offset - distance
      let base = byOffset.get(baseOffset)
      if (base === undefined) {
        base = await readAt(baseOffset)
        byOffset.set(baseOffset, base)
      }
      const { data, length } = oracleInflateObject(pack, position, size)
      return { offset, end: position + length, type: base.type, data: applyDeltaOracle(base.data, data) }
    }
    if (type === 7) {
      const baseOid = toHex(pack.subarray(position, position + 20))
      position += 20
      let base: { type: string; data: Uint8Array } | undefined = byOid.get(baseOid)
      if (base === undefined) base = await readExternal(baseOid)
      if (base === undefined) throw new Error('missing external base')
      const { data, length } = oracleInflateObject(pack, position, size)
      const number = Object.entries(typeText).find(([, name]) => name === base?.type)?.[0]
      return {
        offset,
        end: position + length,
        type: number === undefined ? 3 : Number(number),
        data: applyDeltaOracle(base.data, data),
      }
    }
    const { data, length } = oracleInflateObject(pack, position, size)
    return { offset, end: position + length, type, data }
  }
  let offset = 12
  for (let index = 0; index < count; index += 1) {
    const parsed = await readAt(offset)
    objects.push(parsed)
    byOffset.set(offset, parsed)
    const text = typeText[parsed.type]
    if (text === undefined) throw new Error('bad type')
    byOid.set(sha1Hex(new TextEncoder().encode(`${text} ${parsed.data.byteLength}\0`), parsed.data), { type: text, data: parsed.data })
    offset = parsed.end
  }
  return objects
}

/** The old delta applier, needed only by the metadata oracle's data model. */
export function applyDeltaOracle(base: Uint8Array, delta: Uint8Array): Uint8Array {
  let position = 0
  const readVarint = (): number => {
    let value = 0
    let shift = 0
    for (;;) {
      const byte = delta[position++] as number
      value += (byte & 0x7f) * 2 ** shift
      if ((byte & 0x80) === 0) return value
      shift += 7
    }
  }
  readVarint()
  const targetSize = readVarint()
  const out = new Uint8Array(targetSize)
  let written = 0
  while (position < delta.byteLength) {
    const opcode = delta[position++] as number
    if ((opcode & 0x80) !== 0) {
      let offset = 0
      let size = 0
      if ((opcode & 0x01) !== 0) offset |= delta[position++] as number
      if ((opcode & 0x02) !== 0) offset |= (delta[position++] as number) << 8
      if ((opcode & 0x04) !== 0) offset |= (delta[position++] as number) << 16
      if ((opcode & 0x08) !== 0) offset = offset + (delta[position++] as number) * 0x1000000
      if ((opcode & 0x10) !== 0) size |= delta[position++] as number
      if ((opcode & 0x20) !== 0) size |= (delta[position++] as number) << 8
      if ((opcode & 0x40) !== 0) size |= (delta[position++] as number) << 16
      if (size === 0) size = 0x10000
      out.set(base.subarray(offset, offset + size), written)
      written += size
    } else if (opcode !== 0) {
      out.set(delta.subarray(position, position + opcode), written)
      written += opcode
      position += opcode
    } else {
      throw new Error('reserved delta opcode')
    }
  }
  return out
}
