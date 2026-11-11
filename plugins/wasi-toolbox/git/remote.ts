// SPDX-License-Identifier: MIT
/**
 * Remote porcelain: `clone`, `fetch`, `pull` and `push` over git's smart HTTP
 * protocol (v0).
 *
 * The transport is injected (`RemoteTransport`); in production it is the host
 * `/v1/http` route, so the Worker never opens a socket and the host allow-list
 * remains the only egress rule. The protocol code is deliberately small:
 * `info/refs` discovery, one `git-upload-pack` request for fetch/clone, one
 * `git-receive-pack` request for push, and the pack reader/writer from
 * `pack.ts`. `--depth`/`--single-branch`/`--no-tags` shallow negotiation is
 * implemented for v0. A bare `git clone` uses the phone default
 * (`--depth 1 --single-branch --no-tags`); `--full` keeps every branch and the
 * whole history. Partial clones, protocol v2 and dumb HTTP are not
 * implemented and fail with a message stating that limitation.
 * @module @phone-dsh/dsh-wasi-toolbox/git/remote
 */
import { posix } from 'node:path'
import { inflateWithConsumed } from './compress.ts'
import { fatal } from './errors.ts'
import { compareStrings, concatBytes, decodeText, encodeText, isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'
import { statEntry, writeIndex } from './gindex.ts'
import type { IndexEntry } from './gindex.ts'
import { applyDelta, buildPack, buildPackIndex, crc32Of, sha1Hex, toHex } from './pack.ts'
import type { PackWriteEntry } from './pack.ts'
import {
  discoverRepository, flattenTree, headOid, headRef, listRefs, parseTree, readCommit, requireWorkTree,
  resolveRef, resolveRevision, writeRef, writeShallow,
} from './repo.ts'
import type { Repository } from './repo.ts'
import { parseMode } from './tree.ts'
import { ensureParent } from './worktree.ts'
import { fastForwardHead, isAncestor, switchTo } from './history.ts'
import type { CommandContext } from './cli.ts'
import { HostHttpTransport, redactUrl } from './http.ts'
import type { HttpResult, RemoteTransport } from './http.ts'

/** A pkt-line token: a payload or the protocol's flush marker. */
type Pkt = { readonly kind: 'line'; readonly payload: Uint8Array } | { readonly kind: 'flush' }

/** Encode one pkt-line. */
export function pktLine(text: string | Uint8Array): Uint8Array {
  const payload = typeof text === 'string' ? encodeText(text) : text
  const header = encodeText((payload.byteLength + 4).toString(16).padStart(4, '0'))
  return concatBytes(header, payload)
}

/** The pkt-line flush marker. */
export const PKT_FLUSH = encodeText('0000')

/** Split a pkt-line stream; returns the tokens and the offset where raw data starts. */
export function parsePktLines(bytes: Uint8Array): { pkts: Pkt[]; rawStart: number } {
  const pkts: Pkt[] = []
  let offset = 0
  while (offset + 4 <= bytes.byteLength) {
    const header = decodeText(bytes.subarray(offset, offset + 4))
    if (!/^[0-9a-fA-F]{4}$/.test(header)) break
    const length = Number.parseInt(header, 16)
    if (length === 0) {
      pkts.push({ kind: 'flush' })
      offset += 4
      continue
    }
    if (length < 4 || offset + length > bytes.byteLength) break
    pkts.push({ kind: 'line', payload: bytes.subarray(offset + 4, offset + length) })
    offset += length
  }
  return { pkts, rawStart: offset }
}

/** One advertised ref. */
export interface RemoteRef {
  readonly oid: string
  readonly name: string
}

/** One `info/refs` answer. */
export interface RemoteAdvertisement {
  readonly refs: RemoteRef[]
  readonly capabilities: readonly string[]
  readonly symrefs: ReadonlyMap<string, string>
}

/** Build the transport for one command. */
export function transportFor(context: CommandContext): RemoteTransport {
  if (context.transport !== undefined) return context.transport
  return new HostHttpTransport({
    ...context.fetch === undefined ? {} : { fetch: context.fetch },
    origin: context.env.PDSH_CHANNEL_ORIGIN ?? context.env.PDSH_EXEC_BRIDGE_URL,
    token: context.env.PDSH_CHANNEL_TOKEN ?? context.env.PDSH_EXEC_BRIDGE_TOKEN,
  })
}

function checkStatus(result: HttpResult, what: string): void {
  if (result.status !== 200) {
    throw fatal(`${what} failed: HTTP ${result.status}${result.body.byteLength > 0 ? `: ${decodeText(result.body).trim().slice(0, 300)}` : ''}`)
  }
}

/** Discover the smart-HTTP refs of one service. */
export async function discoverRefs(
  transport: RemoteTransport,
  url: string,
  service: 'git-upload-pack' | 'git-receive-pack',
): Promise<RemoteAdvertisement> {
  const result = await transport.request({
    url: `${url.replace(/\/+$/, '')}/info/refs?service=${service}`,
    method: 'GET',
    headers: { Accept: `application/x-${service}-advertisement` },
  })
  checkStatus(result, `${service} discovery for ${redactUrl(url)}`)
  const text = decodeText(result.body)
  const { pkts } = parsePktLines(result.body)
  if (pkts.length === 0 || decodeText((pkts[0] as { payload: Uint8Array }).payload ?? new Uint8Array()).startsWith('# service=') === false) {
    throw fatal(
      `the remote at ${redactUrl(url)} did not answer with a smart-HTTP advertisement. `
      + 'Dumb HTTP and plain file remotes are not supported by the Worker git; only smart-HTTP remotes are available in this session.',
    )
  }
  void text
  const refs: RemoteRef[] = []
  const capabilities: string[] = []
  const symrefs = new Map<string, string>()
  for (const pkt of pkts) {
    if (pkt.kind !== 'line') continue
    const payload = decodeText(pkt.payload).replace(/\n$/, '')
    if (payload.startsWith('# service=')) continue
    const nul = payload.indexOf('\0')
    const head = nul < 0 ? payload : payload.slice(0, nul)
    if (nul >= 0) {
      for (const capability of payload.slice(nul + 1).split(' ')) {
        if (capability === '') continue
        capabilities.push(capability)
        if (capability.startsWith('symref=')) {
          const [, from, to] = capability.split(/[=:]/)
          if (from !== undefined && to !== undefined) symrefs.set(from, to)
        }
      }
    }
    const match = /^([0-9a-f]{40}) (.+)$/.exec(head)
    if (match === null) continue
    // v0 advertises a peeled annotated tag as `<peeled-oid> refs/tags/x^{}`.
    // It is a lookup result, not a ref: writing it would create a file whose
    // name (`^{}`) fsck rejects.
    const name = match[2] as string
    if (name.endsWith('^{}')) continue
    refs.push({ oid: match[1] as string, name })
  }
  return { refs, capabilities, symrefs }
}

/** One fetched pack result. */
export interface FetchResult {
  readonly pack: Uint8Array | undefined
  readonly serverMessage: string
  /** New shallow boundary commits the server announced. */
  readonly shallow: readonly string[]
  /** Commits that are no longer shallow (a deepen reached past them). */
  readonly unshallow: readonly string[]
}

/** Shallow-negotiation options of one upload-pack request. */
export interface FetchOptions {
  /** `deepen <n>` depth; undefined for a normal fetch. */
  readonly depth?: number | undefined
  /** Existing `.git/shallow` entries, sent as `shallow <oid>` lines. */
  readonly shallow?: readonly string[]
  /** Request `include-tag` so reachable annotated tags ride along. */
  readonly includeTag?: boolean
}

/** Fail before changing anything when shallow negotiation is unavailable. */
function requireShallowCapability(advertisement: RemoteAdvertisement, url: string): void {
  if (advertisement.capabilities.includes('shallow')) return
  throw fatal(
    `the remote at ${redactUrl(url)} does not advertise the 'shallow' capability, so shallow clone/fetch `
    + 'cannot be negotiated with it. Nothing was changed.',
  )
}

/** Run one `git-upload-pack` negotiation and return the pack bytes. */
export async function fetchPack(
  transport: RemoteTransport,
  url: string,
  wants: readonly string[],
  haves: readonly string[],
  advertisement: RemoteAdvertisement,
  options: FetchOptions = {},
): Promise<FetchResult> {
  if (wants.length === 0) return { pack: undefined, serverMessage: '', shallow: [], unshallow: [] }
  const supported = new Set(advertisement.capabilities)
  const shallows = options.shallow ?? []
  const needsShallow = options.depth !== undefined || shallows.length > 0
  if (needsShallow) requireShallowCapability(advertisement, url)
  const caps: string[] = ['ofs-delta']
  if (options.includeTag !== false && supported.has('include-tag')) caps.push('include-tag')
  if (supported.has('side-band-64k')) caps.push('side-band-64k')
  else if (supported.has('side-band')) caps.push('side-band')
  if (supported.has('multi_ack_detailed')) caps.push('multi_ack_detailed')
  else if (supported.has('multi_ack')) caps.push('multi_ack')
  if (needsShallow) caps.push('shallow')
  const chunks: Uint8Array[] = []
  wants.forEach((oid, index) => {
    chunks.push(pktLine(`want ${oid}${index === 0 ? ` ${caps.join(' ')}` : ''}\n`))
  })
  for (const oid of shallows) chunks.push(pktLine(`shallow ${oid}\n`))
  if (options.depth !== undefined) chunks.push(pktLine(`deepen ${options.depth}\n`))
  chunks.push(PKT_FLUSH)
  for (const oid of haves.slice(0, 256)) chunks.push(pktLine(`have ${oid}\n`))
  chunks.push(pktLine('done\n'))
  const body = concatBytes(...chunks)
  const result = await transport.request({
    url: `${url.replace(/\/+$/, '')}/git-upload-pack`,
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-git-upload-pack-request',
      Accept: 'application/x-git-upload-pack-result',
    },
    body,
  })
  checkStatus(result, `git-upload-pack at ${redactUrl(url)}`)
  return parsePackResponse(result.body, caps.includes('side-band-64k') || caps.includes('side-band'))
}

/** Extract the pack and shallow updates out of an upload-pack response. */
export function parsePackResponse(body: Uint8Array, sideBand: boolean): FetchResult {
  const shallow: string[] = []
  const unshallow: string[] = []
  const noteShallow = (payload: Uint8Array): boolean => {
    const line = decodeText(payload)
    const match = /^(un)?shallow ([0-9a-f]{40})$/.exec(line.trim())
    if (match === null) return false
    if (match[1] === 'un') unshallow.push(match[2] as string)
    else shallow.push(match[2] as string)
    return true
  }
  if (!sideBand) {
    // The response starts with pkt-lines (shallow/deepen announcements, ACK or
    // NAK); the raw pack follows the last one.
    const { pkts, rawStart } = parsePktLines(body)
    for (const pkt of pkts) if (pkt.kind === 'line') noteShallow(pkt.payload)
    const pack = body.subarray(rawStart)
    if (pack.byteLength >= 4 && decodeText(pack.subarray(0, 4)) === 'PACK') {
      return { pack, serverMessage: '', shallow, unshallow }
    }
    return { pack: undefined, serverMessage: decodeText(body).slice(0, 500), shallow, unshallow }
  }
  const packChunks: Uint8Array[] = []
  let serverMessage = ''
  const { pkts } = parsePktLines(body)
  for (const pkt of pkts) {
    if (pkt.kind !== 'line' || pkt.payload.byteLength === 0) continue
    if (noteShallow(pkt.payload)) continue
    const band = pkt.payload[0] as number
    const data = pkt.payload.subarray(1)
    if (band === 1) packChunks.push(data)
    else if (band === 2) serverMessage += decodeText(data)
    else if (band === 3) throw fatal(`remote rejected the fetch: ${decodeText(data).trim()}`)
  }
  const pack = packChunks.length === 0 ? undefined : concatBytes(...packChunks)
  return { pack, serverMessage, shallow, unshallow }
}

/**
 * Inflate one pack member after its header, decoding the DEFLATE stream once.
 *
 * The stream's own byte count replaces the old binary search over the pack
 * remainder: a 64 MiB pack used about log2(64 MiB) ≈ 26 full inflations per
 * object just to locate each stream's end.
 */
function inflateObject(pack: Uint8Array, start: number, expectedSize: number): { data: Uint8Array; length: number } {
  if (start >= pack.byteLength) throw fatal('received pack contains a truncated or malformed object')
  let inflated: { data: Uint8Array; consumed: number }
  try {
    inflated = inflateWithConsumed(pack.subarray(start))
  } catch {
    throw fatal('received pack contains a truncated or malformed object')
  }
  if (inflated.data.byteLength !== expectedSize) {
    throw fatal('received pack contains a truncated or malformed object')
  }
  return { data: inflated.data, length: inflated.consumed }
}

/** One parsed pack object: metadata only, never the decompressed content. */
export interface ParsedPackObject {
  readonly offset: number
  readonly end: number
  readonly type: number
  readonly oid: string
  readonly crc: number
}

/** Byte budget of the delta-base cache (LRU, keyed by pack offset). */
export const PACK_DELTA_CACHE_BYTES = 32 * 1024 * 1024

/** Cache statistics a test (or a profile) can assert against. */
export interface ParsePackStats {
  readonly cacheLimitBytes: number
  readonly peakCacheBytes: number
  readonly cacheHits: number
  readonly cacheMisses: number
}

interface CachedObject {
  readonly type: number
  readonly data: Uint8Array
}

/** Offset-keyed LRU holding resolved delta bases, bounded by bytes. */
class DeltaBaseCache {
  private readonly entries = new Map<number, CachedObject>()
  private bytes = 0
  private peak = 0
  private hits = 0
  private misses = 0
  private readonly limitBytes: number

  constructor(limitBytes: number) {
    this.limitBytes = limitBytes
  }

  get(offset: number): CachedObject | undefined {
    const entry = this.entries.get(offset)
    if (entry === undefined) {
      this.misses += 1
      return undefined
    }
    this.hits += 1
    this.entries.delete(offset)
    this.entries.set(offset, entry)
    return entry
  }

  set(offset: number, entry: CachedObject): void {
    if (entry.data.byteLength > this.limitBytes) return
    const previous = this.entries.get(offset)
    if (previous !== undefined) {
      this.bytes -= previous.data.byteLength
      this.entries.delete(offset)
    }
    while (this.bytes + entry.data.byteLength > this.limitBytes) {
      const oldest = this.entries.keys().next()
      if (oldest.done === true) break
      const victim = this.entries.get(oldest.value as number) as CachedObject
      this.entries.delete(oldest.value as number)
      this.bytes -= victim.data.byteLength
    }
    this.entries.set(offset, entry)
    this.bytes += entry.data.byteLength
    if (this.bytes > this.peak) this.peak = this.bytes
  }

  stats(): ParsePackStats {
    return {
      cacheLimitBytes: this.limitBytes,
      peakCacheBytes: this.peak,
      cacheHits: this.hits,
      cacheMisses: this.misses,
    }
  }
}

const TYPE_TEXT: Readonly<Record<number, 'commit' | 'tree' | 'blob' | 'tag'>> = {
  1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag',
}

/** Reverse of {@link TYPE_TEXT} for an externally supplied base object. */
const TYPE_NUMBER: Readonly<Record<string, number>> = {
  commit: 1, tree: 2, blob: 3, tag: 4,
}

interface ResolvedPackObject {
  readonly type: number
  readonly data: Uint8Array
  readonly end: number
}

/**
 * Parse one pack into metadata, resolving delta chains with a bounded cache.
 *
 * Each object's content is inflated once (deltas included), its SHA-1 and
 * CRC-32 are computed once, and the bytes are then handed to an LRU of at most
 * {@link PACK_DELTA_CACHE_BYTES}; only `{ offset, end, type, oid, crc }` stays
 * for every object. A later delta whose base was evicted re-inflates that base
 * by offset instead of keeping the whole repository in memory.
 */
export async function parsePack(
  pack: Uint8Array,
  readExternal: (oid: string) => Promise<{ type: string; data: Uint8Array } | undefined>,
  cacheLimitBytes: number = PACK_DELTA_CACHE_BYTES,
): Promise<{ objects: ParsedPackObject[]; packSha: string; stats: ParsePackStats }> {
  if (pack.byteLength < 32 || decodeText(pack.subarray(0, 4)) !== 'PACK') throw fatal('received object is not a pack file')
  const version = readUint32(pack, 4)
  if (version !== 2 && version !== 3) throw fatal(`unsupported pack version ${version}`)
  const count = readUint32(pack, 8)
  const packSha = sha1Hex(pack.subarray(0, pack.byteLength - 20))
  const trailer = toHex(pack.subarray(pack.byteLength - 20))
  if (packSha !== trailer) throw fatal('received pack checksum mismatch')
  const objects: ParsedPackObject[] = []
  const byOid = new Map<string, number>()
  // The limit is a parameter so tests can force eviction on a small real pack;
  // production and the importer always use the 32 MiB default.
  const cache = new DeltaBaseCache(cacheLimitBytes)
  const contentEnd = pack.byteLength - 20

  const need = (position: number): void => {
    if (position >= contentEnd) throw fatal('received pack contains a truncated or malformed object')
  }

  async function resolveData(target: number): Promise<{ type: number; data: Uint8Array }> {
    const cached = cache.get(target)
    if (cached !== undefined) return cached
    const resolved = await readPackObjectAt(target)
    cache.set(target, { type: resolved.type, data: resolved.data })
    return resolved
  }

  async function readPackObjectAt(target: number): Promise<ResolvedPackObject> {
    if (target < 12 || target >= contentEnd) throw fatal('received pack contains a truncated or malformed object')
    let position = target
    need(position)
    let byte = pack[position++] as number
    const type = (byte >> 4) & 0x07
    let size = byte & 0x0f
    let shift = 4
    while ((byte & 0x80) !== 0) {
      need(position)
      byte = pack[position++] as number
      size += (byte & 0x7f) * 2 ** shift
      shift += 7
    }
    if (type === 6) {
      need(position)
      let distance = (pack[position++] as number) & 0x7f
      let current = pack[position - 1] as number
      while ((current & 0x80) !== 0) {
        need(position)
        current = pack[position++] as number
        distance = (distance + 1) * 128 + (current & 0x7f)
      }
      const baseOffset = target - distance
      if (distance <= 0 || baseOffset < 12 || baseOffset >= target) {
        throw fatal('received pack contains a truncated or malformed object')
      }
      // The base precedes the delta, but its data may already have been
      // evicted; re-inflating it by offset is cheaper than holding everything.
      const base = await resolveData(baseOffset)
      const { data, length } = inflateObject(pack, position, size)
      return { type: base.type, data: applyDelta(base.data, data), end: position + length }
    }
    if (type === 7) {
      if (position + 20 > contentEnd) throw fatal('received pack contains a truncated or malformed object')
      const baseOid = toHex(pack.subarray(position, position + 20))
      position += 20
      let baseType: number
      let baseData: Uint8Array
      const baseOffset = byOid.get(baseOid)
      if (baseOffset !== undefined) {
        const base = await resolveData(baseOffset)
        baseType = base.type
        baseData = base.data
      } else {
        const external = await readExternal(baseOid)
        if (external === undefined) throw fatal(`received pack needs a base object ${baseOid} the repository does not have`)
        baseType = TYPE_NUMBER[external.type] ?? 3
        baseData = external.data
      }
      const { data, length } = inflateObject(pack, position, size)
      return { type: baseType, data: applyDelta(baseData, data), end: position + length }
    }
    if (TYPE_TEXT[type] === undefined) throw fatal(`received pack has unsupported object type ${type}`)
    const { data, length } = inflateObject(pack, position, size)
    return { type, data, end: position + length }
  }

  let offset = 12
  for (let index = 0; index < count; index += 1) {
    const resolved = await readPackObjectAt(offset)
    if (resolved.end <= offset || resolved.end > contentEnd) {
      throw fatal('received pack contains a truncated or malformed object')
    }
    const type = TYPE_TEXT[resolved.type]
    if (type === undefined) throw fatal(`received pack has unsupported object type ${resolved.type}`)
    const oid = sha1Hex(encodeText(`${type} ${resolved.data.byteLength}\0`), resolved.data)
    const meta: ParsedPackObject = {
      offset,
      end: resolved.end,
      type: resolved.type,
      oid,
      crc: crc32Of(pack.subarray(offset, resolved.end)),
    }
    objects.push(meta)
    byOid.set(oid, offset)
    cache.set(offset, { type: resolved.type, data: resolved.data })
    offset = resolved.end
  }
  return { objects, packSha, stats: cache.stats() }
}

function readUint32(buffer: Uint8Array, offset: number): number {
  return (((buffer[offset] as number) << 24) | ((buffer[offset + 1] as number) << 16)
    | ((buffer[offset + 2] as number) << 8) | (buffer[offset + 3] as number)) >>> 0
}

/** Store a received pack and its freshly built index in the object database. */
export async function importPack(repository: Repository, pack: Uint8Array): Promise<number> {
  const parsed = await parsePack(pack, async oid => {
    try {
      return await repository.odb.read(oid)
    } catch {
      return undefined
    }
  })
  // parsePack computed the object id and CRC while it had the bytes; never
  // decompress or hash a second time here.
  const records = parsed.objects.map(object => ({
    oid: object.oid,
    offset: object.offset,
    crc: object.crc,
  }))
  const index = buildPackIndex(records, parsed.packSha)
  const objectDirectory = repository.odb.directories.primary
  const packDirectory = `${objectDirectory}/pack`
  await repository.fs.mkdir(packDirectory, true)
  await repository.fs.writeFile(`${packDirectory}/pack-${parsed.packSha}.pack`, pack)
  await repository.fs.writeFile(`${packDirectory}/pack-${parsed.packSha}.idx`, index)
  repository.odb.invalidatePacks()
  return parsed.objects.length
}

/** Map a source ref to its destination using one fetch refspec. */
function mapRefspec(spec: string, ref: string): string | undefined {
  const body = spec.startsWith('+') ? spec.slice(1) : spec
  const [source, destination] = body.split(':')
  if (source === undefined || destination === undefined) return undefined
  if (source.endsWith('/*') && destination.endsWith('/*')) {
    const prefix = source.slice(0, -1)
    if (!ref.startsWith(prefix)) return undefined
    return `${destination.slice(0, -1)}${ref.slice(prefix.length)}`
  }
  return source === ref ? destination : undefined
}

/** Append configuration lines to a repository's config file. */
async function appendConfig(fs: GitFs, gitDir: string, text: string): Promise<void> {
  let current = ''
  try {
    current = decodeText(await fs.readFile(`${gitDir}/config`))
  } catch (error) {
    if (!isErrno(error, 'ENOENT', 'ENOTDIR')) throw error
  }
  await fs.writeFile(`${gitDir}/config`, `${current}${current.endsWith('\n') || current === '' ? '' : '\n'}${text}`)
}

/** Create the `.git` skeleton `clone` needs (the same layout `git init` writes). */
async function createRepositorySkeleton(fs: GitFs, directory: string, branch: string): Promise<void> {
  await fs.mkdir(directory, true)
  const gitDir = `${directory}/.git`
  await fs.mkdir(`${gitDir}/objects/info`, true)
  await fs.mkdir(`${gitDir}/objects/pack`, true)
  await fs.mkdir(`${gitDir}/refs/heads`, true)
  await fs.mkdir(`${gitDir}/refs/tags`, true)
  await fs.mkdir(`${gitDir}/refs/remotes`, true)
  await fs.mkdir(`${gitDir}/info`, true)
  await fs.writeFile(`${gitDir}/config`, '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n')
  await fs.writeFile(`${gitDir}/HEAD`, `ref: refs/heads/${branch}\n`)
  await fs.writeFile(`${gitDir}/description`, "Unnamed repository; edit this file 'description' to name the repository.\n")
}

/** Resolve the remote URL and name `fetch`/`push`/`pull` use. */
async function remoteUrl(repository: Repository, name: string | undefined): Promise<{ name: string; url: string }> {
  const remote = name ?? 'origin'
  const url = repository.config.get(`remote.${remote}.url`)
  if (url === undefined) throw fatal(`'${remote}' does not appear to be a git repository`)
  if (!/^https?:\/\//i.test(url)) {
    throw fatal(`remote '${remote}' uses ${url}: the Worker git only supports http(s) smart-HTTP remotes`)
  }
  return { name: remote, url }
}

/** Parse git's positive `--depth` value. */
function parseDepth(value: string): number {
  if (!/^\d+$/.test(value)) throw fatal(`depth ${value} is not a positive number`)
  const depth = Number(value)
  if (!Number.isSafeInteger(depth) || depth <= 0) throw fatal(`depth ${value} is not a positive number`)
  return depth
}

/** Options that change which refs a shallow or single-branch clone produces. */
interface CloneOptions {
  readonly quiet: boolean
  readonly branch: string | undefined
  readonly depth: number | undefined
  readonly singleBranch: boolean
  readonly noTags: boolean
  /** True when no history flag was given and the phone default was applied. */
  readonly phoneDefault: boolean
}

/** Parse `git clone` options, failing loud on the ones that are not modelled. */
function cloneOptions(args: readonly string[]): CloneOptions {
  let quiet = false
  let branch: string | undefined
  let depth: number | undefined
  let singleBranch = false
  let noTags = false
  let full = false
  let explicitDepth = false
  let explicitSingle = false
  let explicitNoTags = false
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg === '-b' || arg === '--branch') {
      const value = args[index + 1]
      if (value === undefined) throw fatal(`option '${arg}' requires a value`, 129)
      branch = value
      index += 1
    } else if (arg.startsWith('--branch=')) branch = arg.slice('--branch='.length)
    else if (arg === '--depth') {
      const value = args[index + 1]
      if (value === undefined) throw fatal("option '--depth' requires a value", 129)
      depth = parseDepth(value)
      explicitDepth = true
      index += 1
    } else if (arg.startsWith('--depth=')) {
      depth = parseDepth(arg.slice('--depth='.length))
      explicitDepth = true
    } else if (arg === '--single-branch') {
      singleBranch = true
      explicitSingle = true
    } else if (arg === '--no-tags') {
      noTags = true
      explicitNoTags = true
    } else if (arg === '--full') full = true
    else if (arg === '--no-single-branch') {
      throw fatal(
        'git clone --no-single-branch is not supported inside the Worker: --depth implies --single-branch. '
        + 'Pass --full to copy every branch and the full history. Nothing was changed.',
      )
    } else if (arg === '--shallow-since' || arg.startsWith('--shallow-since=') || arg === '--shallow-exclude' || arg.startsWith('--shallow-exclude=')) {
      throw fatal(
        `git clone ${arg.split('=')[0]} is not supported inside the Worker; only --depth <n> is available for a shallow clone. `
        + 'Nothing was changed.',
      )
    } else if (arg === '--filter' || arg.startsWith('--filter=')) {
      throw fatal(
        'git clone --filter (partial clone) is not supported inside the Worker; use --depth <n> to limit history instead. '
        + 'Nothing was changed.',
      )
    } else if (arg === '--bare' || arg === '--mirror') {
      throw fatal(
        `git clone ${arg} is not supported inside the Worker; the Worker git only provides non-bare smart-HTTP clones `
        + 'with a work tree. Nothing was changed.',
      )
    } else if (arg.startsWith('-')) {
      // `-o/--origin`, `--no-checkout`, ... each change which refs, names or
      // work-tree state the clone produces; none may be dropped as a no-op.
      throw fatal(`unsupported clone option '${arg}'`, 129)
    }
  }
  if (full && (explicitDepth || explicitSingle || explicitNoTags)) {
    throw fatal(
      'git clone --full cannot be combined with --depth, --single-branch or --no-tags. Nothing was changed.',
    )
  }
  // A bare clone (optional `-b`/`-q`) is the phone default. An explicit
  // history flag is left as written; `--full` is the previous all-branch clone.
  const phoneDefault = !full && !explicitDepth && !explicitSingle && !explicitNoTags
  if (phoneDefault) {
    depth = 1
    singleBranch = true
    noTags = true
  }
  return { quiet, branch, depth, singleBranch, noTags, phoneDefault }
}

/** `git clone`. */
export async function clone(context: CommandContext): Promise<number> {
  const options = cloneOptions(context.args)
  // Consumed option values (`-b <name>`, `--depth <n>`) are not positional
  // arguments, so the URL and target are collected by the same grammar.
  const positional = clonePositionals(context.args)
  const source = positional[0]
  if (source === undefined) throw fatal('clone: missing repository URL', 129)
  if (!/^https?:\/\//i.test(source)) {
    throw fatal(`clone from ${source} is not supported: the Worker git only speaks http(s) smart HTTP`)
  }
  const target = positional[1] ?? posix.basename(source.replace(/\/+$/, '').replace(/\.git$/, ''))
  const directory = context.absolute(target)
  if (await context.fs.exists(`${directory}/.git`)) throw fatal(`destination path '${target}' already exists and is not an empty directory`)
  if (!options.quiet) {
    context.output.stderr(`Cloning into '${target}'...\n`)
    if (options.phoneDefault) {
      context.output.stderr(
        'phone default: --depth 1 --single-branch --no-tags '
        + '(pass --full for every branch and the full history)\n',
      )
    }
  }
  const transport = transportFor(context)
  const advertisement = await discoverRefs(transport, source, 'git-upload-pack')
  // Check before the skeleton is written so a server without the capability
  // leaves no half-cloned directory behind.
  if (options.depth !== undefined) requireShallowCapability(advertisement, source)
  const remoteHeadRef = advertisement.symrefs.get('HEAD')
  const remoteHeadName = remoteHeadRef === undefined ? undefined : remoteHeadRef.replace(/^refs\/heads\//, '')
  const heads = advertisement.refs.filter(ref => ref.name.startsWith('refs/heads/'))
  const tags = advertisement.refs.filter(ref => ref.name.startsWith('refs/tags/'))
  if (options.branch !== undefined && !heads.some(ref => ref.name === `refs/heads/${options.branch}`)) {
    throw fatal(`remote branch ${options.branch} not found in ${redactUrl(source)}`)
  }
  // git's `--depth` implies `--single-branch`; the Worker supports that
  // implication and rejects `--no-single-branch` explicitly above.
  const singleBranch = options.singleBranch || options.depth !== undefined
  let localBranch = options.branch ?? remoteHeadName
  if (singleBranch && localBranch === undefined) {
    localBranch = heads[0]?.name.replace(/^refs\/heads\//, '')
  }
  if (singleBranch && (localBranch === undefined || !heads.some(ref => ref.name === `refs/heads/${localBranch}`))) {
    throw fatal(`remote at ${redactUrl(source)} has no branch to clone with --single-branch`)
  }
  const fetchRefspec = singleBranch
    ? `+refs/heads/${localBranch}:refs/remotes/origin/${localBranch}`
    : '+refs/heads/*:refs/remotes/origin/*'
  await createRepositorySkeleton(context.fs, directory, localBranch ?? 'master')
  await appendConfig(context.fs, `${directory}/.git`, [
    `[remote "origin"]`,
    `\turl = ${source}`,
    `\tfetch = ${fetchRefspec}`,
    ...options.noTags ? ['\ttagOpt = --no-tags'] : [],
    ...localBranch === undefined ? [] : [`[branch "${localBranch}"]`, `\tremote = origin`, `\tmerge = refs/heads/${localBranch}`],
    '',
  ].join('\n'))
  const wants: string[] = []
  if (singleBranch) {
    const tip = heads.find(ref => ref.name === `refs/heads/${localBranch}`)
    if (tip !== undefined) wants.push(tip.oid)
  } else {
    wants.push(...heads.map(ref => ref.oid))
    if (!options.noTags) wants.push(...tags.map(ref => ref.oid))
  }
  const fetched = await fetchPack(transport, source, [...new Set(wants)], [], advertisement, {
    depth: options.depth,
    includeTag: !options.noTags,
  })
  if (fetched.pack === undefined) throw fatal('the remote sent no objects for this clone')
  const shallow = new Set(fetched.shallow)
  for (const oid of fetched.unshallow) shallow.delete(oid)
  // Write the boundary before discovery/checkout so every traversal of the
  // new repository already treats these commits as roots.
  await writeShallow(context.fs, `${directory}/.git`, shallow)
  const repository = await discoverRepository(context.fs, directory, context.env)
  if (repository === undefined) throw fatal('clone created no repository')
  await importPack(repository, fetched.pack)
  for (const ref of advertisement.refs) {
    if (ref.name.startsWith('refs/heads/')) {
      const name = ref.name.slice('refs/heads/'.length)
      if (singleBranch && name !== localBranch) continue
      if (name === localBranch) await writeRef(repository, `refs/heads/${name}`, ref.oid)
      // A full clone keeps other branches only as remote-tracking refs; a
      // single-branch clone records its one branch both ways, like git.
      if (name !== localBranch || singleBranch) {
        await writeRef(repository, `refs/remotes/origin/${name}`, ref.oid)
      }
    } else if (ref.name.startsWith('refs/tags/')) {
      // A single-branch clone only gets tags that `include-tag` (or an explicit
      // want) brought into the pack, exactly like git's auto-following.
      if (options.noTags) continue
      if (!(await repository.odb.has(ref.oid))) continue
      await writeRef(repository, ref.name, ref.oid)
    }
  }
  let checkoutBranch = localBranch
  let checkoutOid = checkoutBranch === undefined ? undefined : await resolveRef(repository, `refs/heads/${checkoutBranch}`)
  if (checkoutOid === undefined) {
    const first = advertisement.refs.find(ref => ref.name.startsWith('refs/heads/'))
    if (first !== undefined) {
      checkoutBranch = first.name.slice('refs/heads/'.length)
      checkoutOid = first.oid
      await writeRef(repository, `refs/heads/${checkoutBranch}`, first.oid)
    }
  }
  if (checkoutBranch !== undefined) await writeRef(repository, 'HEAD', `ref: refs/heads/${checkoutBranch}\n`)
  if (checkoutOid !== undefined) await materializeTree(repository, checkoutOid, context)
  if (!options.quiet) context.output.stderr('done.\n')
  return 0
}

/** Positional clone arguments, skipping values consumed by `--depth`/`--branch`. */
function clonePositionals(args: readonly string[]): string[] {
  const rest: string[] = []
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (arg === '-b' || arg === '--branch' || arg === '--depth') {
      index += 1
      continue
    }
    if (arg.startsWith('-')) continue
    rest.push(arg)
  }
  return rest
}

/** Write one commit's tree into the work tree and index (clone checkout). */
async function materializeTree(repository: Repository, commitOid: string, context: CommandContext): Promise<void> {
  const workTree = requireWorkTree(repository)
  const tree = (await readCommit(repository, commitOid)).tree
  const flat = await flattenTree(repository, tree)
  const entries: IndexEntry[] = []
  for (const [path, entry] of [...flat.entries()].sort(([left], [right]) => compareStrings(left, right))) {
    const data = (await repository.odb.read(entry.oid)).data
    await ensureParent(context.fs, workTree, path)
    await context.fs.writeFile(`${workTree}/${path}`, data, parseMode(entry.mode))
    entries.push(await statEntry(context.fs, workTree, path, entry.oid, parseMode(entry.mode)))
  }
  await writeIndex(context.fs, repository.indexPath, { version: 2, entries })
}

/** `git fetch`. */
export async function fetch(context: CommandContext): Promise<number> {
  let quiet = false
  let depth: number | undefined
  const rest: string[] = []
  for (let index = 0; index < context.args.length; index += 1) {
    const arg = context.args[index] as string
    // `--prune`, `--tags` and `--all` each change the result (deleting stale
    // remote-tracking refs, writing every tag, fetching all remotes). They are
    // not implemented, so they reach the unsupported-option error below
    // instead of fetching only the default refspec and reporting success.
    if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg === '--depth') {
      const value = context.args[index + 1]
      if (value === undefined) throw fatal("option '--depth' requires a value", 129)
      depth = parseDepth(value)
      index += 1
    } else if (arg.startsWith('--depth=')) depth = parseDepth(arg.slice('--depth='.length))
    else if (arg === '--unshallow') {
      throw fatal(
        'git fetch --unshallow is not supported inside the Worker; deepen the history with '
        + '--depth <n> or clone again with --full. Nothing was changed.',
      )
    } else if (arg === '--shallow-since' || arg.startsWith('--shallow-since=') || arg === '--shallow-exclude' || arg.startsWith('--shallow-exclude=')) {
      throw fatal(
        `git fetch ${arg.split('=')[0]} is not supported inside the Worker; use --depth <n> to deepen shallow history. `
        + 'Nothing was changed.',
      )
    } else if (arg === '--filter' || arg.startsWith('--filter=')) {
      throw fatal(
        'git fetch --filter (partial clone) is not supported inside the Worker; use --depth <n> instead. '
        + 'Nothing was changed.',
      )
    } else if (arg.startsWith('-')) throw fatal(`unsupported fetch option '${arg}'`, 129)
    else rest.push(arg)
  }
  const repository = await context.repository()
  const { name, url } = await remoteUrl(repository, rest[0])
  const transport = transportFor(context)
  const advertisement = await discoverRefs(transport, url, 'git-upload-pack')
  const refspecs = fetchRefspecs(repository, name)
  const heads = advertisement.refs.filter(ref => ref.name.startsWith('refs/heads/')
    && refspecs.some(spec => mapRefspec(spec, ref.name) !== undefined))
  const wants = [...new Set(heads.map(ref => ref.oid))]
  const tagOpt = repository.config.get(`remote.${name}.tagopt`)
  const local = await localTips(repository)
  const fetched = await fetchPack(transport, url, wants, [...local], advertisement, {
    depth,
    // In a shallow repository git sends its existing boundaries so the server
    // computes a pack that connects to the objects the client already has.
    shallow: [...repository.shallow],
    includeTag: tagOpt !== '--no-tags',
  })
  if (fetched.pack !== undefined) await importPack(repository, fetched.pack)
  if (fetched.shallow.length > 0 || fetched.unshallow.length > 0) {
    const next = new Set(repository.shallow)
    for (const oid of fetched.shallow) next.add(oid)
    for (const oid of fetched.unshallow) next.delete(oid)
    await writeShallow(repository.fs, repository.commonDir, next)
  }
  const updated: string[] = []
  for (const ref of advertisement.refs) {
    if (!ref.name.startsWith('refs/heads/')) continue
    for (const spec of refspecs) {
      const destination = mapRefspec(spec, ref.name)
      if (destination === undefined) continue
      const old = await resolveRef(repository, destination)
      if (old === ref.oid) continue
      await writeRef(repository, destination, ref.oid)
      updated.push(`${old === undefined ? '0000000' : old.slice(0, 7)}..${ref.oid.slice(0, 7)}\t${ref.name.replace(/^refs\/heads\//, '')} -> ${destination.replace(/^refs\/remotes\//, '')}`)
    }
  }
  // Tag auto-following: `include-tag` put reachable annotated tags into the
  // pack, and a lightweight tag is present when its commit is. This writes only
  // tags whose object the repository now has, so a single-branch fetch cannot
  // create a ref to an object it never downloaded.
  if (tagOpt !== '--no-tags') {
    for (const ref of advertisement.refs) {
      if (!ref.name.startsWith('refs/tags/')) continue
      if (!(await repository.odb.has(ref.oid))) continue
      const old = await resolveRef(repository, ref.name)
      if (old !== ref.oid) await writeRef(repository, ref.name, ref.oid)
    }
  }
  const fetchHead = advertisement.refs.map(ref => `${ref.oid}\t\t${ref.name} of ${url}`).join('\n')
  if (fetchHead !== '') await context.fs.writeFile(`${repository.gitDir}/FETCH_HEAD`, `${fetchHead}\n`)
  if (!quiet) {
    if (updated.length === 0) context.output.stdout('Already up to date.\n')
    else context.output.stdout(`From ${redactUrl(url)}\n${updated.map(line => `   ${line}`).join('\n')}\n`)
  }
  return 0
}

async function localTips(repository: Repository): Promise<string[]> {
  const heads = await refsUnder(repository, 'refs/heads/')
  const remotes = await refsUnder(repository, 'refs/remotes/')
  const tags = await refsUnder(repository, 'refs/tags/')
  return [...new Set([...heads, ...remotes, ...tags])]
}

async function refsUnder(repository: Repository, prefix: string): Promise<string[]> {
  const refs = await listRefs(repository, prefix)
  return [...refs.values()]
}

function fetchRefspecs(repository: Repository, remote: string): string[] {
  const values = repository.config
    .withPrefix(`remote.${remote}.`)
    .filter(([key]) => key.endsWith('.fetch'))
    .map(([, value]) => value)
  return values.length === 0 ? ['+refs/heads/*:refs/remotes/origin/*'] : values
}

/** `git pull` = fetch plus a fast-forward merge. */
export async function pull(context: CommandContext): Promise<number> {
  const repositoryBefore = await context.repository()
  const branch = await headRef(repositoryBefore)
  const name = branch?.replace(/^refs\/heads\//, '') ?? 'master'
  const code = await fetch(context)
  if (code !== 0) return code
  const repository = await context.repository()
  const remoteRef = `refs/remotes/origin/${name}`
  const target = await resolveRef(repository, remoteRef)
  if (target === undefined) throw fatal(`pull: no remote-tracking branch ${remoteRef}`)
  const head = await headOid(repository)
  if (head !== undefined && head === target) {
    context.output.stdout('Already up to date.\n')
    return 0
  }
  if (head !== undefined && await isAncestor(repository, target, head)) {
    context.output.stdout('Already up to date.\n')
    return 0
  }
  if (head !== undefined && !(await isAncestor(repository, head, target))) {
    throw fatal(
      'pull needs a non-fast-forward merge, which the Worker git does not do. Nothing was changed.',
    )
  }
  await switchTo(context, { commit: target, quietHead: true, keepHead: true })
  await fastForwardHead(repository, target)
  context.output.stdout(`Updating ${head === undefined ? '' : head.slice(0, 7)}..${target.slice(0, 7)}\nFast-forward\n`)
  return 0
}

/** `git push`. */
export async function push(context: CommandContext): Promise<number> {
  let quiet = false
  let force = false
  const rest: string[] = []
  for (const arg of context.args) {
    // `-u/--set-upstream` would write branch.<name>.remote/merge after a
    // successful push. The Worker git does not write that config, so it
    // reaches the unsupported-option error below instead of pushing and
    // exiting 0 with tracking that was never written.
    if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg === '-f' || arg === '--force') force = true
    else if (arg.startsWith('-')) throw fatal(`unsupported push option '${arg}'`, 129)
    else rest.push(arg)
  }
  const repository = await context.repository()
  const { name, url } = await remoteUrl(repository, rest[0])
  const refspec = rest[1]
  const current = await headRef(repository)
  const currentBranch = current?.replace(/^refs\/heads\//, '')
  const source = refspec?.split(':')[0] ?? currentBranch
  const destinationRef = refspec?.split(':')[1] ?? source
  if (source === undefined || destinationRef === undefined) throw fatal('push: no branch to push')
  const newOid = await resolveRevision(repository, source)
  const remoteBranch = destinationRef.startsWith('refs/') ? destinationRef : `refs/heads/${destinationRef}`
  const transport = transportFor(context)
  const advertisement = await discoverRefs(transport, url, 'git-receive-pack')
  const remoteOld = advertisement.refs.find(ref => ref.name === remoteBranch)?.oid
  if (remoteOld === newOid) {
    if (!quiet) context.output.stderr('Everything up-to-date\n')
    return 0
  }
  if (remoteOld !== undefined && !force) {
    const isAncestor = await repositoryHasAncestor(repository, remoteOld, newOid).catch(() => false)
    if (!isAncestor) {
      throw fatal(
        `push rejected: ${remoteBranch} on ${redactUrl(url)} has commits the Worker does not have. `
        + 'A non-fast-forward push is not supported by the Worker git; nothing was pushed.',
      )
    }
  }
  const exclude = new Set<string>(advertisement.refs.map(ref => ref.oid))
  const objects = await collectObjects(repository, newOid, exclude)
  const pack = buildPack(objects)
  const supported = new Set(advertisement.capabilities)
  const capabilities = ['report-status', 'ofs-delta']
  if (supported.has('side-band-64k')) capabilities.push('side-band-64k')
  const oldText = remoteOld ?? '0000000000000000000000000000000000000000'
  const command = pktLine(`${oldText} ${newOid} ${remoteBranch}\0${capabilities.join(' ')}\n`)
  const body = concatBytes(command, PKT_FLUSH, pack.pack)
  const result = await transport.request({
    url: `${url.replace(/\/+$/, '')}/git-receive-pack`,
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-git-receive-pack-request',
      Accept: 'application/x-git-receive-pack-result',
    },
    body,
  })
  checkStatus(result, `git-receive-pack at ${redactUrl(url)}`)
  const status = parseReceiveStatus(result.body, capabilities.includes('side-band-64k'))
  if (!status.ok) throw fatal(`push failed: ${status.message}`)
  await writeRef(repository, `refs/remotes/${name}/${destinationRef.replace(/^refs\/heads\//, '')}`, newOid)
  if (!quiet) {
    context.output.stderr(`To ${redactUrl(url)}\n`
      + `   ${(remoteOld ?? '0000000').slice(0, 7)}..${newOid.slice(0, 7)}  ${source ?? ''} -> ${destinationRef}\n`)
  }
  return 0
}

async function repositoryHasAncestor(repository: Repository, ancestor: string, descendant: string): Promise<boolean> {
  const seen = new Set<string>()
  let queue = [descendant]
  while (queue.length > 0) {
    const next: string[] = []
    for (const oid of queue) {
      if (oid === ancestor) return true
      if (seen.has(oid)) continue
      seen.add(oid)
      const commit = await readCommit(repository, oid)
      next.push(...commit.parents)
    }
    queue = next
  }
  return false
}

interface ReceiveStatus {
  readonly ok: boolean
  readonly message: string
}

/** Parse a receive-pack report-status response. */
export function parseReceiveStatus(body: Uint8Array, sideBand: boolean): ReceiveStatus {
  let lines: string[] = []
  if (sideBand) {
    const { pkts } = parsePktLines(body)
    let text = ''
    for (const pkt of pkts) {
      if (pkt.kind !== 'line' || pkt.payload.byteLength === 0) continue
      const band = pkt.payload[0] as number
      if (band === 1) text += decodeText(pkt.payload.subarray(1))
      else if (band === 3) return { ok: false, message: decodeText(pkt.payload.subarray(1)).trim() }
    }
    lines = text.split('\n').filter(line => line !== '')
  } else {
    const { pkts } = parsePktLines(body)
    for (const pkt of pkts) {
      if (pkt.kind === 'line') lines.push(decodeText(pkt.payload).trim())
    }
  }
  if (lines.some(line => line.startsWith('unpack ') && line !== 'unpack ok')) {
    return { ok: false, message: lines.join('; ') }
  }
  const rejected = lines.find(line => line.startsWith('ng '))
  if (rejected !== undefined) return { ok: false, message: rejected }
  return { ok: true, message: lines.join('; ') }
}

/** Collect the objects reachable from `tip` that the remote does not have. */
export async function collectObjects(
  repository: Repository,
  tip: string,
  exclude: ReadonlySet<string>,
): Promise<PackWriteEntry[]> {
  const seenCommits = new Set<string>()
  const seenObjects = new Set<string>()
  const entries: PackWriteEntry[] = []
  const addObject = async (oid: string, type: 'commit' | 'tree' | 'blob' | 'tag'): Promise<boolean> => {
    if (seenObjects.has(oid)) return false
    seenObjects.add(oid)
    const object = await repository.odb.read(oid)
    entries.push({ type, data: object.data })
    return true
  }
  const walkTree = async (treeOid: string): Promise<void> => {
    if (seenObjects.has(treeOid)) return
    await addObject(treeOid, 'tree')
    const object = await repository.odb.read(treeOid)
    for (const entry of parseTree(object.data)) {
      if (entry.mode === '40000') await walkTree(entry.oid)
      else if (entry.mode === '160000') continue
      else await addObject(entry.oid, 'blob')
    }
  }
  const queue = [tip]
  while (queue.length > 0) {
    const oid = queue.shift() as string
    if (seenCommits.has(oid) || exclude.has(oid)) continue
    seenCommits.add(oid)
    const commit = await readCommit(repository, oid)
    await addObject(oid, 'commit')
    await walkTree(commit.tree)
    queue.push(...commit.parents)
  }
  return entries
}

/** Re-export the host transport for tests and the command wrapper. */
export { HostHttpTransport }
