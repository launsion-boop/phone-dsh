// SPDX-License-Identifier: MIT
/**
 * The git index (`DIRC`) file: read v2/v3, write v2.
 *
 * DSH snapshots seed a private index from the repository's own index and then
 * run `git add --all` + `git write-tree`, so the index this program writes must
 * be one the system git can read afterwards, and vice versa. Only the fields
 * that matter for tree building are retained; optional extensions are dropped
 * on write (git regenerates `TREE` on demand), and unknown *required*
 * extensions fail loudly instead of silently corrupting the index.
 * @module @phone-dsh/dsh-wasi-toolbox/git/gindex
 */
import { createHash } from 'node:crypto'
import { fatal } from './errors.ts'
import { compareStrings, decodeText, encodeText, isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'
import { toHex } from './pack.ts'

/** One index entry. */
export interface IndexEntry {
  /** Slash-separated path relative to the work tree. */
  readonly path: string
  /** Permission and type bits (`0o100644`, `0o100755`, `0o120000`). */
  readonly mode: number
  readonly oid: string
  /** 0 for a normal entry, 1-3 for an unmerged stage. */
  readonly stage: number
  readonly ctimeSeconds: number
  readonly ctimeNanoseconds: number
  readonly mtimeSeconds: number
  readonly mtimeNanoseconds: number
  readonly device: number
  readonly ino: number
  readonly uid: number
  readonly gid: number
  readonly size: number
  readonly assumeValid: boolean
}

/** A parsed index. */
export interface GitIndex {
  readonly version: number
  readonly entries: readonly IndexEntry[]
}

/** An empty index (a repository that has not staged anything yet). */
export const EMPTY_INDEX: GitIndex = { version: 2, entries: [] }

function readUint16(buffer: Uint8Array, offset: number): number {
  return ((buffer[offset] as number) << 8) | (buffer[offset + 1] as number)
}

function readUint32(buffer: Uint8Array, offset: number): number {
  return (((buffer[offset] as number) << 24) | ((buffer[offset + 1] as number) << 16)
    | ((buffer[offset + 2] as number) << 8) | (buffer[offset + 3] as number)) >>> 0
}

function writeUint16(buffer: Uint8Array, offset: number, value: number): void {
  buffer[offset] = (value >>> 8) & 0xff
  buffer[offset + 1] = value & 0xff
}

function writeUint32(buffer: Uint8Array, offset: number, value: number): void {
  buffer[offset] = (value >>> 24) & 0xff
  buffer[offset + 1] = (value >>> 16) & 0xff
  buffer[offset + 2] = (value >>> 8) & 0xff
  buffer[offset + 3] = value & 0xff
}

/** Parse an index file. */
export function parseIndex(bytes: Uint8Array): GitIndex {
  if (bytes.byteLength === 0) return EMPTY_INDEX
  if (bytes.byteLength < 12 + 20) throw fatal('index file corrupt')
  if (decodeText(bytes.subarray(0, 4)) !== 'DIRC') throw fatal('index file corrupt: bad signature')
  const version = readUint32(bytes, 4)
  if (version !== 2 && version !== 3) {
    throw fatal(`index file version ${version} is not supported by the Worker git (only 2 and 3 are)`)
  }
  const count = readUint32(bytes, 8)
  const entries: IndexEntry[] = []
  let offset = 12
  for (let index = 0; index < count; index += 1) {
    if (offset + 62 > bytes.byteLength) throw fatal('index file corrupt: truncated entry')
    const ctimeSeconds = readUint32(bytes, offset)
    const ctimeNanoseconds = readUint32(bytes, offset + 4)
    const mtimeSeconds = readUint32(bytes, offset + 8)
    const mtimeNanoseconds = readUint32(bytes, offset + 12)
    const device = readUint32(bytes, offset + 16)
    const ino = readUint32(bytes, offset + 20)
    const mode = readUint32(bytes, offset + 24)
    const uid = readUint32(bytes, offset + 28)
    const gid = readUint32(bytes, offset + 32)
    const size = readUint32(bytes, offset + 36)
    const oid = toHex(bytes.subarray(offset + 40, offset + 60))
    const flags = readUint16(bytes, offset + 60)
    const extended = (flags & 0x4000) !== 0
    if (extended) {
      throw fatal('index file uses an extended (v3) entry; rewrite it with `git update-index --index-version 2`')
    }
    let nameLength = flags & 0x0fff
    let nameStart = offset + 62
    if (nameLength === 0x0fff) {
      const nul = bytes.indexOf(0, nameStart)
      if (nul < 0) throw fatal('index file corrupt: unterminated name')
      nameLength = nul - nameStart
    }
    if (nameStart + nameLength > bytes.byteLength) throw fatal('index file corrupt: truncated name')
    const path = decodeText(bytes.subarray(nameStart, nameStart + nameLength))
    const entrySize = (62 + nameLength + 8) & ~7
    offset += entrySize
    entries.push({
      path,
      mode,
      oid,
      stage: (flags >> 12) & 0x3,
      ctimeSeconds,
      ctimeNanoseconds,
      mtimeSeconds,
      mtimeNanoseconds,
      device,
      ino,
      uid,
      gid,
      size,
      assumeValid: (flags & 0x8000) !== 0,
    })
  }
  // Extensions follow the entries; an unknown required one (lowercase
  // signature) cannot be ignored.
  while (offset + 8 <= bytes.byteLength - 20) {
    const signature = decodeText(bytes.subarray(offset, offset + 4))
    const length = readUint32(bytes, offset + 4)
    if (signature === '' || length < 0 || offset + 8 + length > bytes.byteLength) break
    if (signature[0] !== undefined && signature[0] >= 'a' && signature[0] <= 'z') {
      throw fatal(`index file uses required extension '${signature}' that the Worker git does not understand`)
    }
    offset += 8 + length
  }
  return { version, entries }
}

/** Encode an index as a version-2 file with a valid trailing SHA-1. */
export function encodeIndex(index: GitIndex): Uint8Array {
  const entries = [...index.entries].sort((left, right) => compareStrings(left.path, right.path) || left.stage - right.stage)
  let size = 12
  for (const entry of entries) {
    const nameLength = encodeText(entry.path).byteLength
    size += (62 + nameLength + 8) & ~7
  }
  size += 20
  const out = new Uint8Array(size)
  out.set(encodeText('DIRC'), 0)
  writeUint32(out, 4, 2)
  writeUint32(out, 8, entries.length)
  let offset = 12
  for (const entry of entries) {
    const name = encodeText(entry.path)
    writeUint32(out, offset, entry.ctimeSeconds)
    writeUint32(out, offset + 4, entry.ctimeNanoseconds)
    writeUint32(out, offset + 8, entry.mtimeSeconds)
    writeUint32(out, offset + 12, entry.mtimeNanoseconds)
    writeUint32(out, offset + 16, entry.device)
    writeUint32(out, offset + 20, entry.ino)
    writeUint32(out, offset + 24, entry.mode)
    writeUint32(out, offset + 28, entry.uid)
    writeUint32(out, offset + 32, entry.gid)
    writeUint32(out, offset + 36, entry.size)
    out.set(Uint8Array.from(entry.oid.match(/.{2}/g)?.map(byte => Number.parseInt(byte, 16)) ?? []), offset + 40)
    const flags = (entry.assumeValid ? 0x8000 : 0) | ((entry.stage & 0x3) << 12) | Math.min(name.byteLength, 0x0fff)
    writeUint16(out, offset + 60, flags)
    out.set(name, offset + 62)
    offset += (62 + name.byteLength + 8) & ~7
  }
  const digest = createHash('sha1').update(out.subarray(0, size - 20)).digest()
  out.set(digest, size - 20)
  return out
}

/** Read the index at `path`, or an empty index when the file does not exist. */
export async function readIndex(fs: GitFs, path: string): Promise<GitIndex> {
  let bytes: Uint8Array
  try {
    bytes = await fs.readFile(path)
  } catch (error) {
    if (isErrno(error, 'ENOENT', 'ENOTDIR')) return EMPTY_INDEX
    throw error
  }
  if (bytes.byteLength === 0) return EMPTY_INDEX
  // Verify the trailing checksum before trusting any entry.
  const digest = createHash('sha1').update(bytes.subarray(0, bytes.byteLength - 20)).digest()
  const trailer = bytes.subarray(bytes.byteLength - 20)
  if (digest.byteLength !== trailer.byteLength || digest.some((byte, index) => byte !== trailer[index])) {
    throw fatal('index file corrupt: bad checksum')
  }
  return parseIndex(bytes)
}

/** Write an index atomically (temp file plus rename, like git's lock file). */
export async function writeIndex(fs: GitFs, path: string, index: GitIndex): Promise<void> {
  const slash = path.lastIndexOf('/')
  if (slash > 0) await fs.mkdir(path.slice(0, slash), true)
  const temporary = `${path}.lock`
  await fs.writeFile(temporary, encodeIndex(index))
  await fs.rename(temporary, path)
}

/** Look up one path's stage-0 entry. */
export function indexEntry(index: GitIndex, path: string): IndexEntry | undefined {
  return index.entries.find(entry => entry.path === path && entry.stage === 0)
}

/** True when the index holds unmerged entries. */
export function hasUnmerged(index: GitIndex): boolean {
  return index.entries.some(entry => entry.stage !== 0)
}

/** Remove every entry for a path (all stages). */
export function removePath(index: GitIndex, path: string): IndexEntry[] {
  return index.entries.filter(entry => entry.path !== path)
}

/** Build a `stat`-derived index entry. */
export async function statEntry(
  fs: GitFs,
  workTree: string,
  path: string,
  oid: string,
  mode: number,
): Promise<IndexEntry> {
  let stat
  try {
    stat = await fs.lstat(`${workTree}/${path}`)
  } catch {
    stat = undefined
  }
  return {
    path,
    mode,
    oid,
    stage: 0,
    ctimeSeconds: Math.floor((stat?.ctimeMs ?? 0) / 1000),
    ctimeNanoseconds: Math.floor(((stat?.ctimeMs ?? 0) % 1000) * 1e6),
    mtimeSeconds: Math.floor((stat?.mtimeMs ?? 0) / 1000),
    mtimeNanoseconds: Math.floor(((stat?.mtimeMs ?? 0) % 1000) * 1e6),
    device: stat?.device ?? 0,
    ino: stat?.ino ?? 0,
    uid: stat?.uid ?? 0,
    gid: stat?.gid ?? 0,
    size: stat?.size ?? 0,
    assumeValid: false,
  }
}
