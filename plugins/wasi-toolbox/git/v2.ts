// SPDX-License-Identifier: MIT
/**
 * Git protocol v2 (stateless smart HTTP) for partial clone.
 *
 * v0 stays the path for ordinary clone/fetch. `--filter=blob:none` needs v2:
 * the server must advertise `fetch=... filter`. A server that does not is a
 * hard error, never a silent full clone. Shallow `deepen` is sent on the same
 * fetch when the caller also passed `--depth`.
 * @module @phone-dsh/dsh-wasi-toolbox/git/v2
 */
import { fatal } from './errors.ts'
import { concatBytes, decodeText, encodeText } from './fs.ts'
import { redactUrl } from './http.ts'
import type { HttpResult, RemoteTransport } from './http.ts'

/** One advertised ref from `ls-refs`. */
export interface V2Ref {
  readonly oid: string
  readonly name: string
  /** `symref-target:` value when the line is HEAD. */
  readonly target?: string
}

/** What `info/refs` said when the client asked for version 2. */
export interface V2Advertisement {
  readonly capabilities: readonly string[]
  readonly fetchFeatures: readonly string[]
}

function pkt(text: string): Uint8Array {
  const payload = encodeText(text.endsWith('\n') ? text : `${text}\n`)
  return concatBytes(encodeText((payload.byteLength + 4).toString(16).padStart(4, '0')), payload)
}

const FLUSH = encodeText('0000')
const DELIM = encodeText('0001')

interface V2Pkt {
  readonly kind: 'line' | 'flush' | 'delim'
  readonly payload: Uint8Array
}

/** Walk pkt-lines, including the v2 delimiter (`0001`). */
export function walkV2(bytes: Uint8Array): V2Pkt[] {
  const pkts: V2Pkt[] = []
  let offset = 0
  while (offset + 4 <= bytes.byteLength) {
    const header = decodeText(bytes.subarray(offset, offset + 4))
    if (!/^[0-9a-fA-F]{4}$/.test(header)) break
    const length = Number.parseInt(header, 16)
    if (length === 0) {
      pkts.push({ kind: 'flush', payload: new Uint8Array() })
      offset += 4
      continue
    }
    if (length === 1) {
      pkts.push({ kind: 'delim', payload: new Uint8Array() })
      offset += 4
      continue
    }
    if (length < 4 || offset + length > bytes.byteLength) break
    pkts.push({ kind: 'line', payload: bytes.subarray(offset + 4, offset + length) })
    offset += length
  }
  return pkts
}

function linesOf(pkts: readonly V2Pkt[]): string[] {
  return pkts.filter(pkt => pkt.kind === 'line').map(pkt => decodeText(pkt.payload).replace(/\n$/, ''))
}

async function request(
  transport: RemoteTransport,
  url: string,
  method: 'GET' | 'POST',
  body?: Uint8Array,
): Promise<HttpResult> {
  const result = await transport.request({
    url,
    method,
    headers: {
      'Git-Protocol': 'version=2',
      ...method === 'GET'
        ? { Accept: 'application/x-git-upload-pack-advertisement' }
        : {
            'Content-Type': 'application/x-git-upload-pack-request',
            Accept: 'application/x-git-upload-pack-result',
          },
    },
    ...body === undefined ? {} : { body },
  })
  if (result.status !== 200) {
    throw fatal(`git protocol v2 ${method} ${redactUrl(url)} failed: HTTP ${result.status}`)
  }
  return result
}

/** Read the v2 capability advertisement, or undefined when the server spoke v0. */
export async function discoverV2(transport: RemoteTransport, url: string): Promise<V2Advertisement | undefined> {
  const result = await request(
    transport,
    `${url.replace(/\/+$/, '')}/info/refs?service=git-upload-pack`,
    'GET',
  )
  const text = linesOf(walkV2(result.body))
  if (!text.includes('version 2')) return undefined
  const fetchLine = text.find(line => line.startsWith('fetch=')) ?? 'fetch='
  return {
    capabilities: text.filter(line => line !== 'version 2'),
    fetchFeatures: fetchLine.slice('fetch='.length).split(' ').filter(feature => feature !== ''),
  }
}

/** `ls-refs` for heads, tags and HEAD. */
export async function listRefsV2(transport: RemoteTransport, url: string): Promise<V2Ref[]> {
  const body = concatBytes(
    pkt('command=ls-refs'),
    DELIM,
    pkt('peel'),
    pkt('symrefs'),
    pkt('ref-prefix refs/heads/'),
    pkt('ref-prefix refs/tags/'),
    pkt('ref-prefix HEAD'),
    FLUSH,
  )
  const result = await request(transport, `${url.replace(/\/+$/, '')}/git-upload-pack`, 'POST', body)
  const refs: V2Ref[] = []
  for (const line of linesOf(walkV2(result.body))) {
    const match = /^([0-9a-f]{40}) (\S+)(.*)$/.exec(line)
    if (match === null) continue
    const name = match[2] as string
    if (name.endsWith('^{}')) continue
    const target = /symref-target:(\S+)/.exec(match[3] ?? '')
    refs.push({
      oid: match[1] as string,
      name,
      ...target?.[1] === undefined ? {} : { target: target[1] },
    })
  }
  return refs
}

export interface V2FetchOptions {
  readonly wants: readonly string[]
  /** `blob:none` omits blobs. Undefined fetches the requested objects whole. */
  readonly filter?: 'blob:none' | undefined
  readonly depth?: number | undefined
}

/**
 * One stateless v2 `fetch`. The caller sends `done` immediately, which is what
 * stateless HTTP requires for a single round trip.
 */
export async function fetchPackV2(
  transport: RemoteTransport,
  url: string,
  options: V2FetchOptions,
): Promise<{ pack: Uint8Array | undefined; shallow: readonly string[]; message: string }> {
  if (options.wants.length === 0) return { pack: undefined, shallow: [], message: '' }
  const parts: Uint8Array[] = [
    pkt('command=fetch'),
    DELIM,
    pkt('ofs-delta'),
    pkt('no-progress'),
  ]
  if (options.filter !== undefined) parts.push(pkt(`filter ${options.filter}`))
  if (options.depth !== undefined) parts.push(pkt(`deepen ${options.depth}`))
  for (const oid of options.wants) parts.push(pkt(`want ${oid}`))
  parts.push(pkt('done'), FLUSH)
  const result = await request(transport, `${url.replace(/\/+$/, '')}/git-upload-pack`, 'POST', concatBytes(...parts))
  return parseV2Fetch(result.body)
}

/** Pull the packfile section out of a v2 fetch response. Sideband 1 is the pack. */
export function parseV2Fetch(body: Uint8Array): { pack: Uint8Array | undefined; shallow: readonly string[]; message: string } {
  const shallow: string[] = []
  const chunks: Uint8Array[] = []
  let message = ''
  let inPack = false
  for (const pkt of walkV2(body)) {
    if (pkt.kind !== 'line' || pkt.payload.byteLength === 0) continue
    const text = decodeText(pkt.payload).replace(/\n$/, '')
    const shallowMatch = /^(un)?shallow ([0-9a-f]{40})$/.exec(text)
    if (shallowMatch !== null) {
      if (shallowMatch[1] !== 'un') shallow.push(shallowMatch[2] as string)
      continue
    }
    if (text === 'packfile') {
      inPack = true
      continue
    }
    if (!inPack) {
      if (text.startsWith('ERR ')) throw fatal(`remote rejected the fetch: ${text.slice(4)}`)
      continue
    }
    const band = pkt.payload[0] as number
    const data = pkt.payload.subarray(1)
    if (band === 1) chunks.push(data)
    else if (band === 2) message += decodeText(data)
    else if (band === 3) throw fatal(`remote rejected the fetch: ${decodeText(data).trim()}`)
  }
  const pack = chunks.length === 0 ? undefined : concatBytes(...chunks)
  if (pack !== undefined && decodeText(pack.subarray(0, 4)) !== 'PACK') {
    throw fatal('protocol v2 packfile section did not contain a pack')
  }
  return { pack, shallow, message }
}
