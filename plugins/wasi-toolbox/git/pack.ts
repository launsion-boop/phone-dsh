// SPDX-License-Identifier: MIT
/**
 * Git pack files: the `pack-*.idx` index (v1 and v2) and the pack (v2/v3)
 * object stream with `ofs-delta` / `ref-delta` resolution. The Worker git has
 * to read a workspace repository that was cloned or garbage-collected on a
 * host, where objects are packed and deltified; `cat-file`, `ls-tree`,
 * `diff-tree` and `checkout` all sit on this reader.
 *
 * A pack writer is included for the two directions that create objects in
 * bulk: `clone`/`fetch` (the received pack is stored as a pack so the next
 * command does not pay a loose-object explosion) and `push` (the local
 * objects the remote is missing).
 *
 * The DEFLATE streams inside a pack (and the loose-object streams) are handled
 * by the package's own pure-JavaScript codec (`./compress.ts`, backed by the
 * MIT `fflate` package) because the Worker's `node:zlib` proxy has no
 * deflate/inflate; `node:crypto` supplies the SHA-1.
 * @module @phone-dsh/dsh-wasi-toolbox/git/pack
 */
import { createHash } from 'node:crypto'
import { crc32, deflate, inflate } from './compress.ts'
import { fsError, isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'

/** Object types as the pack format numbers them. */
export type PackObjectType = 'commit' | 'tree' | 'blob' | 'tag'

/** Object type numbers in a pack. */
const TYPE_NUMBER: Readonly<Record<PackObjectType, number>> = {
  commit: 1,
  tree: 2,
  blob: 3,
  tag: 4,
}

/** Reverse of {@link TYPE_NUMBER} for the four concrete types. */
const NUMBER_TYPE: Readonly<Record<number, PackObjectType>> = {
  1: 'commit',
  2: 'tree',
  3: 'blob',
  4: 'tag',
}

/** One object recovered from a pack. */
export interface PackedObject {
  readonly type: PackObjectType
  readonly data: Uint8Array
}

/** Offset-addressed pack index. */
export interface PackIndex {
  /** Path of the `pack-*.idx` file. */
  readonly indexPath: string
  /** Path of the matching `pack-*.pack` file. */
  readonly packPath: string
  /** Object ids in index order. */
  readonly ids: readonly string[]
  /** Map oid → pack offset. */
  readonly offsets: ReadonlyMap<string, number>
  /** Number of objects. */
  readonly count: number
}

/** Hex-encode bytes. */
export function toHex(bytes: Uint8Array): string {
  let out = ''
  for (const byte of bytes) out += byte.toString(16).padStart(2, '0')
  return out
}

/** Decode hex to bytes. */
export function fromHex(hex: string): Uint8Array {
  if (hex.length % 2 !== 0 || /[^0-9a-f]/i.test(hex)) throw new Error(`not a hex string: ${hex}`)
  const out = new Uint8Array(hex.length / 2)
  for (let index = 0; index < out.length; index += 1) out[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16)
  return out
}

/** SHA-1 of a byte array, as lowercase hex. */
export function sha1Hex(...chunks: readonly Uint8Array[]): string {
  const hash = createHash('sha1')
  for (const chunk of chunks) hash.update(chunk)
  return hash.digest('hex')
}

function readUint32(buffer: Uint8Array, offset: number): number {
  return (((buffer[offset] as number) << 24) | ((buffer[offset + 1] as number) << 16)
    | ((buffer[offset + 2] as number) << 8) | (buffer[offset + 3] as number)) >>> 0
}

function readBigUint64(buffer: Uint8Array, offset: number): number {
  let value = 0
  for (let index = 0; index < 8; index += 1) value = value * 256 + (buffer[offset + index] as number)
  return value
}

function writeUint32(buffer: Uint8Array, offset: number, value: number): void {
  buffer[offset] = (value >>> 24) & 0xff
  buffer[offset + 1] = (value >>> 16) & 0xff
  buffer[offset + 2] = (value >>> 8) & 0xff
  buffer[offset + 3] = value & 0xff
}

function writeBigUint64(buffer: Uint8Array, offset: number, value: number): void {
  let remaining = value
  for (let index = 7; index >= 0; index -= 1) {
    buffer[offset + index] = remaining % 256
    remaining = Math.floor(remaining / 256)
  }
}

/** Parse one `pack-*.idx` file into an oid → offset map. */
export async function readPackIndex(fs: GitFs, indexPath: string): Promise<PackIndex> {
  const bytes = await fs.readFile(indexPath)
  const packPath = indexPath.endsWith('.idx') ? `${indexPath.slice(0, -4)}.pack` : `${indexPath}.pack`
  if (bytes.byteLength < 4 * 256 + 20 * 2) throw fsError('EINVAL', 'truncated pack index', indexPath)
  const magic = readUint32(bytes, 0)
  if (magic === 0xff744f63) {
    const version = readUint32(bytes, 4)
    if (version !== 2) throw fsError('ENOTSUP', `unsupported pack index version ${version}`, indexPath)
    const fanout = 8
    const count = readUint32(bytes, fanout + 255 * 4)
    const shaStart = fanout + 256 * 4
    if (bytes.byteLength < shaStart + count * 20 + count * 4 + count * 4 + 40) {
      throw fsError('EINVAL', 'truncated pack index', indexPath)
    }
    const crcStart = shaStart + count * 20
    const offsetStart = crcStart + count * 4
    const largeStart = offsetStart + count * 4
    const ids: string[] = []
    const offsets = new Map<string, number>()
    for (let index = 0; index < count; index += 1) {
      const oid = toHex(bytes.subarray(shaStart + index * 20, shaStart + (index + 1) * 20))
      const raw = readUint32(bytes, offsetStart + index * 4)
      let offset = raw
      if ((raw & 0x80000000) !== 0) {
        const largeIndex = raw & 0x7fffffff
        const at = largeStart + largeIndex * 8
        if (at + 8 > bytes.byteLength - 40) throw fsError('EINVAL', 'truncated large offset table', indexPath)
        offset = readBigUint64(bytes, at)
      }
      ids.push(oid)
      offsets.set(oid, offset)
    }
    return { indexPath, packPath, ids, offsets, count }
  }
  // Version 1: fanout then (offset, sha1) pairs sorted by sha1.
  const count = readUint32(bytes, 255 * 4)
  const entryStart = 256 * 4
  if (bytes.byteLength < entryStart + count * 24 + 40) throw fsError('EINVAL', 'truncated pack index', indexPath)
  const ids: string[] = []
  const offsets = new Map<string, number>()
  for (let index = 0; index < count; index += 1) {
    const at = entryStart + index * 24
    const offset = readUint32(bytes, at)
    const oid = toHex(bytes.subarray(at + 4, at + 24))
    ids.push(oid)
    offsets.set(oid, offset)
  }
  return { indexPath, packPath, ids, offsets, count }
}

/** Parse a pack object header at `offset` from an in-memory buffer. */
function parseObjectHeader(buffer: Uint8Array, offset: number): { type: number; size: number; headerLength: number } {
  let position = offset
  if (position >= buffer.byteLength) throw fsError('EINVAL', 'pack object offset beyond end of file', 'pack')
  let byte = buffer[position++] as number
  const type = (byte >> 4) & 0x07
  let size = byte & 0x0f
  let shift = 4
  while ((byte & 0x80) !== 0) {
    if (position >= buffer.byteLength) throw fsError('EINVAL', 'truncated pack object header', 'pack')
    byte = buffer[position++] as number
    size += (byte & 0x7f) * 2 ** shift
    shift += 7
  }
  return { type, size, headerLength: position - offset }
}

/** Decode the negative offset of an `ofs-delta` header. */
function parseDeltaOffset(buffer: Uint8Array, offset: number): { baseOffset: number; headerLength: number } {
  let position = offset
  let byte = buffer[position++] as number
  let distance = byte & 0x7f
  while ((byte & 0x80) !== 0) {
    byte = buffer[position++] as number
    distance = (distance + 1) * 128 + (byte & 0x7f)
  }
  return { baseOffset: distance, headerLength: position - offset }
}

/** Read a small prefix of the pack around one object. */
async function readPrefix(fs: GitFs, packPath: string, offset: number, length = 96): Promise<Uint8Array> {
  const bytes = await fs.readFileSlice(packPath, offset, offset + length)
  if (bytes.byteLength === 0) throw fsError('EINVAL', `pack offset ${offset} is past the end of ${packPath}`, packPath)
  return bytes
}

/**
 * Inflate one object after its header at `dataStart`, growing the read window
 * until the deflate stream ends. Packs are read in place because a workspace
 * repository may be much larger than the Worker's memory budget.
 */
async function inflateAt(fs: GitFs, packPath: string, dataStart: number): Promise<Uint8Array> {
  let window = 64 * 1024
  for (;;) {
    // Past 32 MiB the window is the rest of the file; a stream that still has
    // not ended there means the pack itself is malformed.
    const end = window > 32 * 1024 * 1024 ? 0 : dataStart + window
    const chunk = await fs.readFileSlice(packPath, dataStart, end)
    try {
      return inflate(chunk)
    } catch (error) {
      // A window that ends inside the deflate stream is expected for a large
      // object: grow it and retry. A slice shorter than the window already
      // reaches the end of the file, so the pack is genuinely corrupt.
      if (end !== 0 && chunk.byteLength === window) {
        window *= 2
        continue
      }
      throw fsError('EINVAL', `cannot inflate pack object at ${dataStart}: ${(error as Error).message}`, packPath)
    }
  }
}

/** Apply a git delta to a base buffer. */
export function applyDelta(base: Uint8Array, delta: Uint8Array): Uint8Array {
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
  const sourceSize = readVarint()
  if (sourceSize !== base.byteLength) throw fsError('EINVAL', `delta source size ${sourceSize} does not match base ${base.byteLength}`, 'delta')
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
      if ((opcode & 0x08) !== 0) offset = (offset + (delta[position++] as number) * 0x1000000)
      if ((opcode & 0x10) !== 0) size |= delta[position++] as number
      if ((opcode & 0x20) !== 0) size |= (delta[position++] as number) << 8
      if ((opcode & 0x40) !== 0) size |= (delta[position++] as number) << 16
      if (size === 0) size = 0x10000
      if (offset + size > base.byteLength) throw fsError('EINVAL', 'delta copy range outside base', 'delta')
      out.set(base.subarray(offset, offset + size), written)
      written += size
    } else if (opcode !== 0) {
      if (position + opcode > delta.byteLength) throw fsError('EINVAL', 'delta insert beyond delta end', 'delta')
      out.set(delta.subarray(position, position + opcode), written)
      written += opcode
      position += opcode
    } else {
      throw fsError('EINVAL', 'delta opcode 0 is reserved', 'delta')
    }
  }
  if (written !== targetSize) throw fsError('EINVAL', `delta wrote ${written} of ${targetSize} bytes`, 'delta')
  return out
}

/** Read one pack object by offset, resolving delta chains. */
export async function readObjectAt(
  fs: GitFs,
  packPath: string,
  offset: number,
  readBase: (baseOffset: number) => Promise<PackedObject>,
  readBaseObject: (oid: string) => Promise<PackedObject>,
): Promise<PackedObject> {
  const prefix = await readPrefix(fs, packPath, offset)
  const header = parseObjectHeader(prefix, 0)
  let dataStart = offset + header.headerLength
  if (header.type === 6) {
    const delta = parseDeltaOffset(prefix, header.headerLength)
    dataStart += delta.headerLength
    const base = await readBase(offset - delta.baseOffset)
    const deltaData = await inflateAt(fs, packPath, dataStart)
    return { type: base.type, data: applyDelta(base.data, deltaData) }
  }
  if (header.type === 7) {
    const baseOid = toHex(prefix.subarray(header.headerLength, header.headerLength + 20))
    dataStart += 20
    const base = await readBaseObject(baseOid)
    const deltaData = await inflateAt(fs, packPath, dataStart)
    return { type: base.type, data: applyDelta(base.data, deltaData) }
  }
  const type = NUMBER_TYPE[header.type]
  if (type === undefined) throw fsError('EINVAL', `unknown pack object type ${header.type}`, packPath)
  const data = await inflateAt(fs, packPath, dataStart)
  if (data.byteLength !== header.size) {
    throw fsError('EINVAL', `pack object size ${data.byteLength} does not match header ${header.size}`, packPath)
  }
  return { type, data }
}

/** One object to write into a pack. */
export interface PackWriteEntry {
  readonly type: PackObjectType
  readonly data: Uint8Array
}

/** Result of building a pack and its index. */
export interface PackWriteResult {
  readonly pack: Uint8Array
  readonly index: Uint8Array
  /** Pack checksum as lowercase hex, the `pack-<id>` file name. */
  readonly id: string
  /** Object ids in pack order. */
  readonly ids: readonly string[]
  /** Object ids in index (sorted) order. */
  readonly sortedIds: readonly string[]
}

function encodeObjectHeader(type: number, size: number): Uint8Array {
  const bytes: number[] = []
  let first = (type << 4) | (size & 0x0f)
  size = Math.floor(size / 16)
  if (size > 0) first |= 0x80
  bytes.push(first)
  while (size > 0) {
    let byte = size & 0x7f
    size = Math.floor(size / 128)
    if (size > 0) byte |= 0x80
    bytes.push(byte)
  }
  return Uint8Array.from(bytes)
}

/** Build a pack v2 containing the given objects without delta compression. */
export function buildPack(entries: readonly PackWriteEntry[]): PackWriteResult {
  const chunks: Uint8Array[] = []
  const header = new Uint8Array(12)
  header.set([0x50, 0x41, 0x43, 0x4b], 0) // "PACK"
  writeUint32(header, 4, 2)
  writeUint32(header, 8, entries.length)
  chunks.push(header)
  const ids: string[] = []
  const records: { oid: string; offset: number; crc: number }[] = []
  let offset = 12
  for (const entry of entries) {
    const objectHeader = encodeObjectHeader(TYPE_NUMBER[entry.type], entry.data.byteLength)
    const compressed = deflate(entry.data)
    const record = new Uint8Array(objectHeader.byteLength + compressed.byteLength)
    record.set(objectHeader, 0)
    record.set(compressed, objectHeader.byteLength)
    const oid = sha1Hex(new TextEncoder().encode(`${entry.type} ${entry.data.byteLength}\0`), entry.data)
    records.push({ oid, offset, crc: crc32(record) })
    ids.push(oid)
    chunks.push(record)
    offset += record.byteLength
  }
  const body = concat(chunks)
  const packSha = sha1Hex(body)
  const pack = concat([body, fromHex(packSha)])
  const index = buildPackIndex(records, packSha)
  return { pack, index, id: packSha, ids, sortedIds: [...ids].sort() }
}

function concat(chunks: readonly Uint8Array[]): Uint8Array {
  let length = 0
  for (const chunk of chunks) length += chunk.byteLength
  const out = new Uint8Array(length)
  let position = 0
  for (const chunk of chunks) {
    out.set(chunk, position)
    position += chunk.byteLength
  }
  return out
}

/** Build a version-2 pack index for the given records. */
export function buildPackIndex(records: readonly { oid: string; offset: number; crc: number }[], packSha: string): Uint8Array {
  const sorted = [...records].sort((left, right) => (left.oid < right.oid ? -1 : left.oid > right.oid ? 1 : 0))
  const count = sorted.length
  let largeCount = 0
  for (const record of sorted) if (record.offset >= 0x80000000) largeCount += 1
  const size = 8 + 256 * 4 + count * 20 + count * 4 + count * 4 + largeCount * 8 + 40
  const out = new Uint8Array(size)
  writeUint32(out, 0, 0xff744f63)
  writeUint32(out, 4, 2)
  const fanout = 8
  const buckets = new Array<number>(256).fill(0)
  for (const record of sorted) {
    const bucket = Number.parseInt(record.oid.slice(0, 2), 16)
    buckets[bucket] = (buckets[bucket] ?? 0) + 1
  }
  let cumulative = 0
  for (let index = 0; index < 256; index += 1) {
    cumulative += buckets[index] as number
    writeUint32(out, fanout + index * 4, cumulative)
  }
  const shaStart = fanout + 256 * 4
  const crcStart = shaStart + count * 20
  const offsetStart = crcStart + count * 4
  const largeStart = offsetStart + count * 4
  let largeIndex = 0
  for (let index = 0; index < count; index += 1) {
    const record = sorted[index] as { oid: string; offset: number; crc: number }
    out.set(fromHex(record.oid), shaStart + index * 20)
    writeUint32(out, crcStart + index * 4, record.crc)
    if (record.offset >= 0x80000000) {
      writeUint32(out, offsetStart + index * 4, 0x80000000 | largeIndex)
      writeBigUint64(out, largeStart + largeIndex * 8, record.offset)
      largeIndex += 1
    } else {
      writeUint32(out, offsetStart + index * 4, record.offset)
    }
  }
  out.set(fromHex(packSha), size - 40)
  const indexSha = sha1Hex(out.subarray(0, size - 20))
  out.set(fromHex(indexSha), size - 20)
  return out
}

/** CRC-32 of one byte range (the pack index stores it per object). */
export function crc32Of(data: Uint8Array): number {
  return crc32(data)
}

/** Store a pack and its index under `<objectDir>/pack/`. */
export async function storePack(fs: GitFs, objectDir: string, result: PackWriteResult): Promise<string> {
  const packDir = `${objectDir}/pack`
  await fs.mkdir(packDir, true)
  const base = `${packDir}/pack-${result.id}`
  await fs.writeFile(`${base}.pack`, result.pack)
  await fs.writeFile(`${base}.idx`, result.index)
  return base
}

/** True when the error is a missing file (used while probing pack files). */
export function missing(error: unknown): boolean {
  return isErrno(error, 'ENOENT', 'ENOTDIR')
}
