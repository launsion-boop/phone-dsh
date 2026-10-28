// SPDX-License-Identifier: MIT
/**
 * The object database: loose objects, packs, and the read-through alternates
 * DSH's workspace-changes snapshots set up (`GIT_OBJECT_DIRECTORY` for writes,
 * `GIT_ALTERNATE_OBJECT_DIRECTORIES` for reads).
 *
 * `git add`/`write-tree` write through `GIT_OBJECT_DIRECTORY` into a private
 * store, while `ls-tree`/`cat-file`/`diff-tree` must still read the repository's
 * own objects. That is exactly the git contract this class implements: a
 * writable primary directory, then a list of read-only alternates, each of
 * which may hold loose objects and packs.
 * @module @phone-dsh/dsh-wasi-toolbox/git/objects
 */
import { createHash } from 'node:crypto'
import { deflate, inflate } from './compress.ts'
import { decodeText, encodeText, isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'
import { missing, readObjectAt, readPackIndex, sha1Hex, storePack } from './pack.ts'
import type { PackIndex, PackedObject } from './pack.ts'

/** A named git object. */
export interface GitObject {
  readonly type: 'blob' | 'tree' | 'commit' | 'tag'
  readonly data: Uint8Array
}

/** Directories one object database reads from. */
export interface ObjectDirectories {
  /** Writable object directory (`GIT_OBJECT_DIRECTORY` or `<gitdir>/objects`). */
  readonly primary: string
  /** Read-only alternates (`GIT_ALTERNATE_OBJECT_DIRECTORIES`). */
  readonly alternates: readonly string[]
}

/** Compute a git object id from type and content. */
export function objectId(type: string, data: Uint8Array): string {
  return sha1Hex(encodeText(`${type} ${data.byteLength}\0`), data)
}

/** Parse a loose object file (`<type> <size>\0<data>`, zlib-deflated). */
function parseLoose(bytes: Uint8Array): GitObject {
  const raw = inflate(bytes)
  const nul = raw.indexOf(0)
  if (nul < 0) throw new Error('loose object has no header terminator')
  const header = decodeText(raw.subarray(0, nul))
  const space = header.indexOf(' ')
  if (space < 0) throw new Error('loose object header is malformed')
  const type = header.slice(0, space)
  const size = Number(header.slice(space + 1))
  if (type !== 'blob' && type !== 'tree' && type !== 'commit' && type !== 'tag') {
    throw new Error(`unknown loose object type ${type}`)
  }
  const data = raw.subarray(nul + 1)
  if (data.byteLength !== size) throw new Error(`loose object size ${data.byteLength} does not match header ${size}`)
  return { type, data }
}

/** The object database of one repository plus its alternates. */
export class ObjectDatabase {
  private readonly fs: GitFs
  readonly directories: ObjectDirectories
  private readonly packIndexes = new Map<string, PackIndex[]>()
  private readonly objectCache = new Map<string, PackedObject>()
  private readonly packObjectCache = new Map<string, PackedObject>()

  constructor(fs: GitFs, directories: ObjectDirectories) {
    this.fs = fs
    this.directories = directories
  }

  /** Every directory reads consult, primary first. */
  get readDirectories(): readonly string[] {
    return [this.directories.primary, ...this.directories.alternates]
  }

  /** True when the object exists in the primary or an alternate. */
  async has(oid: string): Promise<boolean> {
    if (this.objectCache.has(oid)) return true
    for (const directory of this.readDirectories) {
      if (await this.hasLoose(directory, oid)) return true
      for (const pack of await this.packs(directory)) if (pack.offsets.has(oid)) return true
    }
    return false
  }

  /** Read one object by id. */
  async read(oid: string): Promise<GitObject> {
    const cached = this.objectCache.get(oid)
    if (cached !== undefined) return cached
    for (const directory of this.readDirectories) {
      const loose = await this.readLoose(directory, oid)
      if (loose !== undefined) {
        this.remember(oid, loose)
        return loose
      }
      for (const pack of await this.packs(directory)) {
        const offset = pack.offsets.get(oid)
        if (offset === undefined) continue
        const object = await this.readPacked(pack, offset)
        this.remember(oid, object)
        return object
      }
    }
    throw new Error(`object ${oid} is missing`)
  }

  /** Object type without returning the bytes. */
  async type(oid: string): Promise<GitObject['type']> {
    return (await this.read(oid)).type
  }

  /** Object size in bytes. */
  async size(oid: string): Promise<number> {
    return (await this.read(oid)).data.byteLength
  }

  /** Write one object into the primary directory; returns its id. */
  async write(type: GitObject['type'], data: Uint8Array): Promise<string> {
    const oid = objectId(type, data)
    if (await this.has(oid)) return oid
    const header = encodeText(`${type} ${data.byteLength}\0`)
    const body = new Uint8Array(header.byteLength + data.byteLength)
    body.set(header, 0)
    body.set(data, header.byteLength)
    const compressed = deflate(body)
    const directory = `${this.directories.primary}/${oid.slice(0, 2)}`
    await this.fs.mkdir(directory, true)
    const target = `${directory}/${oid.slice(2)}`
    const temporary = `${directory}/tmp_obj_${Math.random().toString(16).slice(2)}`
    await this.fs.writeFile(temporary, compressed)
    await this.fs.rename(temporary, target)
    this.remember(oid, { type, data })
    return oid
  }

  /** Write an already-compressed pack (clone/fetch) into the primary store. */
  async writePack(pack: Uint8Array, index: Uint8Array, id: string): Promise<void> {
    await storePack(this.fs, this.directories.primary, {
      pack,
      index,
      id,
      ids: [],
      sortedIds: [],
    })
    this.packIndexes.delete(this.directories.primary)
  }

  /** Drop cached pack indexes; used after writing a new pack. */
  invalidatePacks(): void {
    this.packIndexes.clear()
  }

  private remember(oid: string, object: PackedObject): void {
    if (this.objectCache.size > 4096) this.objectCache.clear()
    this.objectCache.set(oid, object)
  }

  private async hasLoose(directory: string, oid: string): Promise<boolean> {
    try {
      await this.fs.stat(`${directory}/${oid.slice(0, 2)}/${oid.slice(2)}`)
      return true
    } catch (error) {
      if (isErrno(error, 'ENOENT', 'ENOTDIR')) return false
      throw error
    }
  }

  private async readLoose(directory: string, oid: string): Promise<PackedObject | undefined> {
    const path = `${directory}/${oid.slice(0, 2)}/${oid.slice(2)}`
    let bytes: Uint8Array
    try {
      bytes = await this.fs.readFile(path)
    } catch (error) {
      if (isErrno(error, 'ENOENT', 'ENOTDIR')) return undefined
      throw error
    }
    return parseLoose(bytes)
  }

  private async packs(directory: string): Promise<readonly PackIndex[]> {
    const cached = this.packIndexes.get(directory)
    if (cached !== undefined) return cached
    const packDirectory = `${directory}/pack`
    let names: string[]
    try {
      names = (await this.fs.readdir(packDirectory)).filter(entry => entry.isFile && entry.name.endsWith('.idx')).map(entry => entry.name)
    } catch (error) {
      if (isErrno(error, 'ENOENT', 'ENOTDIR')) {
        this.packIndexes.set(directory, [])
        return []
      }
      throw error
    }
    const indexes: PackIndex[] = []
    for (const name of names.sort()) {
      try {
        indexes.push(await readPackIndex(this.fs, `${packDirectory}/${name}`))
      } catch (error) {
        // A pack written by a concurrent git can be half-visible; skip a
        // malformed index rather than making every read fail.
        if (missing(error)) continue
        throw error
      }
    }
    this.packIndexes.set(directory, indexes)
    return indexes
  }

  private async readPacked(pack: PackIndex, offset: number): Promise<PackedObject> {
    const key = `${pack.packPath}:${offset}`
    const cached = this.packObjectCache.get(key)
    if (cached !== undefined) return cached
    const result = await readObjectAt(
      this.fs,
      pack.packPath,
      offset,
      async baseOffset => await this.readPacked(pack, baseOffset),
      async baseOid => await this.read(baseOid),
    )
    if (this.packObjectCache.size > 1024) this.packObjectCache.clear()
    this.packObjectCache.set(key, result)
    return result
  }
}

/** Hash arbitrary bytes as a blob and return its id (no write). */
export function hashBlob(data: Uint8Array): string {
  return createHash('sha1').update(`blob ${data.byteLength}\0`).update(data).digest('hex')
}
