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
 * `pack.ts`. Shallow and partial clones, protocol v2 and dumb HTTP are not
 * implemented and fail with a message stating that limitation.
 * @module @phone-dsh/dsh-wasi-toolbox/git/remote
 */
import { posix } from 'node:path'
import { inflate } from './compress.ts'
import { fatal } from './errors.ts'
import { compareStrings, concatBytes, decodeText, encodeText, isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'
import { statEntry, writeIndex } from './gindex.ts'
import type { IndexEntry } from './gindex.ts'
import { applyDelta, buildPack, buildPackIndex, crc32Of, sha1Hex, toHex } from './pack.ts'
import type { PackWriteEntry } from './pack.ts'
import {
  discoverRepository, flattenTree, headOid, headRef, listRefs, parseTree, readCommit, requireWorkTree,
  resolveRef, resolveRevision, writeRef,
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
    if (match !== null) refs.push({ oid: match[1] as string, name: match[2] as string })
  }
  return { refs, capabilities, symrefs }
}

/** One fetched pack result. */
export interface FetchResult {
  readonly pack: Uint8Array | undefined
  readonly serverMessage: string
}

/** Run one `git-upload-pack` negotiation and return the pack bytes. */
export async function fetchPack(
  transport: RemoteTransport,
  url: string,
  wants: readonly string[],
  haves: readonly string[],
  advertisement: RemoteAdvertisement,
): Promise<FetchResult> {
  if (wants.length === 0) return { pack: undefined, serverMessage: '' }
  const supported = new Set(advertisement.capabilities)
  const caps: string[] = ['ofs-delta']
  if (supported.has('side-band-64k')) caps.push('side-band-64k')
  else if (supported.has('side-band')) caps.push('side-band')
  if (supported.has('multi_ack_detailed')) caps.push('multi_ack_detailed')
  else if (supported.has('multi_ack')) caps.push('multi_ack')
  const chunks: Uint8Array[] = []
  wants.forEach((oid, index) => {
    chunks.push(pktLine(`want ${oid}${index === 0 ? ` ${caps.join(' ')}` : ''}\n`))
  })
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

/** Extract the pack out of an upload-pack response (side-band or raw). */
export function parsePackResponse(body: Uint8Array, sideBand: boolean): FetchResult {
  if (!sideBand) {
    // Raw pack starts after the ACK/NAK pkt-lines.
    const { rawStart } = parsePktLines(body)
    const pack = body.subarray(rawStart)
    if (pack.byteLength >= 4 && decodeText(pack.subarray(0, 4)) === 'PACK') {
      return { pack, serverMessage: '' }
    }
    return { pack: undefined, serverMessage: decodeText(body).slice(0, 500) }
  }
  const packChunks: Uint8Array[] = []
  let serverMessage = ''
  const { pkts } = parsePktLines(body)
  for (const pkt of pkts) {
    if (pkt.kind !== 'line' || pkt.payload.byteLength === 0) continue
    const band = pkt.payload[0] as number
    const data = pkt.payload.subarray(1)
    if (band === 1) packChunks.push(data)
    else if (band === 2) serverMessage += decodeText(data)
    else if (band === 3) throw fatal(`remote rejected the fetch: ${decodeText(data).trim()}`)
  }
  const pack = packChunks.length === 0 ? undefined : concatBytes(...packChunks)
  return { pack, serverMessage }
}

/** Find the end of one deflate stream inside a pack by binary search. */
function inflateObject(pack: Uint8Array, start: number, expectedSize: number): { data: Uint8Array; length: number } {
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
  if (best === undefined) throw fatal('received pack contains a truncated or malformed object')
  return best
}

interface ParsedPackObject {
  readonly offset: number
  readonly end: number
  readonly type: number
  readonly data: Uint8Array
}

const TYPE_TEXT: Readonly<Record<number, 'commit' | 'tree' | 'blob' | 'tag'>> = {
  1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag',
}

/** Parse one pack into objects, resolving delta chains. */
export async function parsePack(
  pack: Uint8Array,
  readExternal: (oid: string) => Promise<{ type: string; data: Uint8Array } | undefined>,
): Promise<{ objects: ParsedPackObject[]; packSha: string }> {
  if (pack.byteLength < 32 || decodeText(pack.subarray(0, 4)) !== 'PACK') throw fatal('received object is not a pack file')
  const version = readUint32(pack, 4)
  if (version !== 2 && version !== 3) throw fatal(`unsupported pack version ${version}`)
  const count = readUint32(pack, 8)
  const packSha = sha1Hex(pack.subarray(0, pack.byteLength - 20))
  const trailer = toHex(pack.subarray(pack.byteLength - 20))
  if (packSha !== trailer) throw fatal('received pack checksum mismatch')
  const objects: ParsedPackObject[] = []
  const byOffset = new Map<number, ParsedPackObject>()
  const byOid = new Map<string, { type: string; data: Uint8Array }>()
  let offset = 12
  for (let index = 0; index < count; index += 1) {
    const parsed = await readPackObjectAt(pack, offset, byOffset, byOid, readExternal)
    objects.push(parsed)
    byOffset.set(offset, parsed)
    const type = TYPE_TEXT[parsed.type]
    if (type === undefined) throw fatal(`received pack has unsupported object type ${parsed.type}`)
    byOid.set(sha1Hex(encodeText(`${type} ${parsed.data.byteLength}\0`), parsed.data), { type, data: parsed.data })
    offset = parsed.end
  }
  return { objects, packSha }
}

async function readPackObjectAt(
  pack: Uint8Array,
  offset: number,
  byOffset: Map<number, ParsedPackObject>,
  byOid: Map<string, { type: string; data: Uint8Array }>,
  readExternal: (oid: string) => Promise<{ type: string; data: Uint8Array } | undefined>,
): Promise<ParsedPackObject> {
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
      // The base should be earlier in the pack; parse it on demand.
      base = await readPackObjectAt(pack, baseOffset, byOffset, byOid, readExternal)
      byOffset.set(baseOffset, base)
    }
    const { data, length } = inflateObject(pack, position, size)
    return { offset, end: position + length, type: base.type, data: applyDelta(base.data, data) }
  }
  if (type === 7) {
    const baseOid = toHex(pack.subarray(position, position + 20))
    position += 20
    const byOidEntry = byOid.get(baseOid)
    let base: { type: string; data: Uint8Array } | undefined = byOidEntry
    if (base === undefined) base = await readExternal(baseOid)
    if (base === undefined) throw fatal(`received pack needs a base object ${baseOid} the repository does not have`)
    const { data, length } = inflateObject(pack, position, size)
    const typeNumber = Object.entries(TYPE_TEXT).find(([, name]) => name === base?.type)?.[0]
    return {
      offset,
      end: position + length,
      type: typeNumber === undefined ? 3 : Number(typeNumber),
      data: applyDelta(base.data, data),
    }
  }
  const { data, length } = inflateObject(pack, position, size)
  return { offset, end: position + length, type, data }
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
  const records = parsed.objects.map((object, index) => {
    const type = TYPE_TEXT[object.type] as 'commit' | 'tree' | 'blob' | 'tag'
    const oid = sha1Hex(encodeText(`${type} ${object.data.byteLength}\0`), object.data)
    void index
    return {
      oid,
      offset: object.offset,
      crc: crc32Of(pack.subarray(object.offset, object.end)),
    }
  })
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

/** `git clone`. */
export async function clone(context: CommandContext): Promise<number> {
  let quiet = false
  let branch: string | undefined
  const rest: string[] = []
  for (let index = 0; index < context.args.length; index += 1) {
    const arg = context.args[index] as string
    // `--single-branch`, `--no-tags` and `-o/--origin` change which refs or
    // which remote name the clone produces. They reach the generic
    // unsupported-option error below instead of being dropped as no-ops; in
    // particular a bare `-o` must not swallow its name and clone from it as if
    // it were the URL.
    if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg === '-b' || arg === '--branch') {
      branch = context.args[index + 1]
      index += 1
    } else if (arg.startsWith('--branch=')) branch = arg.slice('--branch='.length)
    else if (arg === '--depth' || arg === '--shallow-since' || arg === '--shallow-exclude' || arg === '--filter' || arg === '--bare' || arg === '--mirror') {
      throw fatal(
        `git clone ${arg} is not supported inside the Worker. Shallow, partial and bare clones need host-side git; `
        + 'the Worker git only provides full smart-HTTP clones.',
      )
    } else if (arg.startsWith('-')) throw fatal(`unsupported clone option '${arg}'`, 129)
    else rest.push(arg)
  }
  const source = rest[0]
  if (source === undefined) throw fatal('clone: missing repository URL', 129)
  if (!/^https?:\/\//i.test(source)) {
    throw fatal(`clone from ${source} is not supported: the Worker git only speaks http(s) smart HTTP`)
  }
  const target = rest[1] ?? posix.basename(source.replace(/\/+$/, '').replace(/\.git$/, ''))
  const directory = context.absolute(target)
  if (await context.fs.exists(`${directory}/.git`)) throw fatal(`destination path '${target}' already exists and is not an empty directory`)
  if (!quiet) context.output.stderr(`Cloning into '${target}'...\n`)
  const transport = transportFor(context)
  const advertisement = await discoverRefs(transport, source, 'git-upload-pack')
  const remoteHeadRef = advertisement.symrefs.get('HEAD')
  const remoteHeadName = remoteHeadRef === undefined ? undefined : remoteHeadRef.replace(/^refs\/heads\//, '')
  if (branch !== undefined && !advertisement.refs.some(ref => ref.name === `refs/heads/${branch}`)) {
    throw fatal(`remote branch ${branch} not found in ${redactUrl(source)}`)
  }
  const localBranch = branch ?? remoteHeadName
  await createRepositorySkeleton(context.fs, directory, localBranch ?? 'master')
  await appendConfig(context.fs, `${directory}/.git`, [
    `[remote "origin"]`,
    `\turl = ${source}`,
    `\tfetch = +refs/heads/*:refs/remotes/origin/*`,
    ...localBranch === undefined ? [] : [`[branch "${localBranch}"]`, `\tremote = origin`, `\tmerge = refs/heads/${localBranch}`],
    '',
  ].join('\n'))
  const wants = advertisement.refs
    .filter(ref => ref.name.startsWith('refs/heads/') || ref.name.startsWith('refs/tags/'))
    .map(ref => ref.oid)
  const fetched = await fetchPack(transport, source, [...new Set(wants)], [], advertisement)
  if (fetched.pack === undefined) throw fatal('the remote sent no objects for this clone')
  const repository = await discoverRepository(context.fs, directory, context.env)
  if (repository === undefined) throw fatal('clone created no repository')
  await importPack(repository, fetched.pack)
  for (const ref of advertisement.refs) {
    if (ref.name.startsWith('refs/heads/')) {
      const name = ref.name.slice('refs/heads/'.length)
      await writeRef(repository, name === localBranch ? `refs/heads/${name}` : `refs/remotes/origin/${name}`, ref.oid)
    } else if (ref.name.startsWith('refs/tags/')) {
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
  if (!quiet) context.output.stderr('done.\n')
  return 0
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
  const rest: string[] = []
  for (const arg of context.args) {
    // `--prune`, `--tags` and `--all` each change the result (deleting stale
    // remote-tracking refs, writing tags, fetching every remote). They are not
    // implemented, so they reach the unsupported-option error below instead of
    // fetching only the default remote and reporting success.
    if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg === '--depth' || arg.startsWith('--depth=')) {
      throw fatal('git fetch --depth is not supported inside the Worker; the Worker git only fetches full history. Nothing was changed.')
    } else if (arg.startsWith('-')) throw fatal(`unsupported fetch option '${arg}'`, 129)
    else rest.push(arg)
  }
  const repository = await context.repository()
  const { name, url } = await remoteUrl(repository, rest[0])
  const transport = transportFor(context)
  const advertisement = await discoverRefs(transport, url, 'git-upload-pack')
  const wants = advertisement.refs
    .filter(ref => ref.name.startsWith('refs/heads/') || ref.name.startsWith('refs/tags/'))
    .map(ref => ref.oid)
  const local = await localTips(repository)
  const fetched = await fetchPack(transport, url, [...new Set(wants)], [...local], advertisement)
  if (fetched.pack !== undefined) await importPack(repository, fetched.pack)
  const refspecs = fetchRefspecs(repository, name)
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
