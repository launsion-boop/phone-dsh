// SPDX-License-Identifier: MIT
/**
 * Binary envelope of the VFS proxy: a little-endian u32 JSON length, the JSON
 * body, then one binary blob. File contents travel in the blob (not base64), so
 * the async `postMessage` path and the SharedArrayBuffer path share exactly one
 * codec: the async path posts the envelope as a `Uint8Array`, the SAB path copies
 * the same bytes into a shared region.
 * @module @phone-dsh/dsh-wasi-toolbox/vfs-protocol
 */
import { VfsProxyError } from './errors.ts'
import type { VfsRequest, VfsResponse, VfsStat, VfsValue } from './types.ts'

/** One request with the correlation id the response repeats. */
export interface RequestRecord {
  readonly id: number
  readonly request: VfsRequest
}

/** One response with the correlation id of its request. */
export interface ResponseRecord {
  readonly id: number
  readonly response: VfsResponse
}

interface WireRequest {
  id: number
  op: VfsRequest['op']
  path?: string
  from?: string
  to?: string
  offset?: number
  length?: number
  append?: boolean
  create?: boolean
  truncate?: boolean
  exclusive?: boolean
  directory?: boolean
  mode?: number
  dataLength?: number
}

interface WireValue {
  kind: VfsValue['kind']
  stat?: VfsStat
  entries?: readonly { name: string; kind: string; ino: number }[]
  dataOffset?: number
  dataLength?: number
  written?: number
}

interface WireResponse {
  id: number
  ok: boolean
  value?: WireValue
  code?: string
  message?: string
}

const encoder = new TextEncoder()
const decoder = new TextDecoder()

/** Encode requests, appending any write payloads to the binary section. */
export function encodeRequests(records: readonly RequestRecord[]): Uint8Array {
  const binary: Uint8Array[] = []
  let binaryLength = 0
  const wire: WireRequest[] = records.map((record): WireRequest => {
    const request = record.request
    switch (request.op) {
      case 'stat':
      case 'readdir':
      case 'sync':
        return { id: record.id, op: request.op, path: 'path' in request ? request.path : undefined }
      case 'open':
        return {
          id: record.id,
          op: request.op,
          path: request.path,
          create: request.create,
          truncate: request.truncate,
          exclusive: request.exclusive,
          directory: request.directory,
          mode: request.mode,
        }
      case 'read':
        return { id: record.id, op: request.op, path: request.path, offset: request.offset, length: request.length }
      case 'write': {
        binary.push(request.data)
        binaryLength += request.data.byteLength
        return {
          id: record.id,
          op: request.op,
          path: request.path,
          offset: request.offset,
          append: request.append,
          create: request.create,
          mode: request.mode,
          dataLength: request.data.byteLength,
        }
      }
      case 'truncate':
        return { id: record.id, op: request.op, path: request.path, length: request.length }
      case 'mkdir':
        return { id: record.id, op: request.op, path: request.path, mode: request.mode }
      case 'unlink':
        return { id: record.id, op: request.op, path: request.path, directory: request.directory }
      case 'rename':
        return { id: record.id, op: request.op, from: request.from, to: request.to }
      default:
        throw new VfsProxyError('EINVAL', `unknown VFS op ${String((request as { op?: unknown }).op)}`)
    }
  })
  return encodeEnvelope({ requests: wire }, joinBinary(binary, binaryLength))
}

/** Decode a request frame. Throws `VfsProxyError('EINVAL')` on a malformed frame. */
export function decodeRequests(frame: Uint8Array): RequestRecord[] {
  const { json, binary } = decodeEnvelope(frame)
  const requests = (json as { requests?: unknown }).requests
  if (!Array.isArray(requests)) throw new VfsProxyError('EINVAL', 'frame has no requests array')
  let cursor = 0
  return requests.map(value => {
    const wire = value as WireRequest
    const id = requireInteger(wire.id, 'request id')
    let request: VfsRequest
    switch (wire.op) {
      case 'stat':
        request = { op: 'stat', path: requireString(wire.path, 'path') }
        break
      case 'readdir':
        request = { op: 'readdir', path: requireString(wire.path, 'path') }
        break
      case 'open':
        request = {
          op: 'open',
          path: requireString(wire.path, 'path'),
          create: Boolean(wire.create),
          truncate: Boolean(wire.truncate),
          exclusive: Boolean(wire.exclusive),
          directory: Boolean(wire.directory),
          ...(wire.mode === undefined ? {} : { mode: requireInteger(wire.mode, 'mode') }),
        }
        break
      case 'read':
        request = {
          op: 'read',
          path: requireString(wire.path, 'path'),
          offset: requireInteger(wire.offset, 'offset'),
          length: requireInteger(wire.length, 'length'),
        }
        break
      case 'write': {
        const dataLength = requireInteger(wire.dataLength, 'dataLength')
        if (cursor + dataLength > binary.byteLength) {
          throw new VfsProxyError('EINVAL', 'write payload shorter than dataLength')
        }
        request = {
          op: 'write',
          path: requireString(wire.path, 'path'),
          offset: requireInteger(wire.offset, 'offset'),
          append: Boolean(wire.append),
          create: Boolean(wire.create),
          ...(wire.mode === undefined ? {} : { mode: requireInteger(wire.mode, 'mode') }),
          data: binary.slice(cursor, cursor + dataLength),
        }
        cursor += dataLength
        break
      }
      case 'truncate':
        request = {
          op: 'truncate',
          path: requireString(wire.path, 'path'),
          length: requireInteger(wire.length, 'length'),
        }
        break
      case 'mkdir':
        request = {
          op: 'mkdir',
          path: requireString(wire.path, 'path'),
          ...(wire.mode === undefined ? {} : { mode: requireInteger(wire.mode, 'mode') }),
        }
        break
      case 'unlink':
        request = {
          op: 'unlink',
          path: requireString(wire.path, 'path'),
          directory: Boolean(wire.directory),
        }
        break
      case 'rename':
        request = {
          op: 'rename',
          from: requireString(wire.from, 'from'),
          to: requireString(wire.to, 'to'),
        }
        break
      case 'sync':
        request = { op: 'sync' }
        break
      default:
        throw new VfsProxyError('EINVAL', `unknown VFS op ${String(wire.op)}`)
    }
    return { id, request }
  })
}

/** Encode responses, appending `data` values to the binary section. */
export function encodeResponses(records: readonly ResponseRecord[]): Uint8Array {
  const binary: Uint8Array[] = []
  let binaryLength = 0
  const wire: WireResponse[] = records.map((record): WireResponse => {
    const response = record.response
    if (!response.ok) {
      return { id: record.id, ok: false, code: response.code, message: response.message }
    }
    const value = response.value
    switch (value.kind) {
      case 'stat':
        return { id: record.id, ok: true, value: { kind: value.kind, stat: value.stat } }
      case 'entries':
        return { id: record.id, ok: true, value: { kind: value.kind, entries: value.entries } }
      case 'data': {
        const dataOffset = binaryLength
        binary.push(value.data)
        binaryLength += value.data.byteLength
        return {
          id: record.id,
          ok: true,
          value: { kind: value.kind, dataOffset, dataLength: value.data.byteLength },
        }
      }
      case 'written':
        return { id: record.id, ok: true, value: { kind: value.kind, written: value.written } }
      case 'void':
        return { id: record.id, ok: true, value: { kind: value.kind } }
      default:
        throw new VfsProxyError('EINVAL', `unknown VFS value ${String((value as { kind?: unknown }).kind)}`)
    }
  })
  return encodeEnvelope({ responses: wire }, joinBinary(binary, binaryLength))
}

/** Decode a response frame. */
export function decodeResponses(frame: Uint8Array): ResponseRecord[] {
  const { json, binary } = decodeEnvelope(frame)
  const responses = (json as { responses?: unknown }).responses
  if (!Array.isArray(responses)) throw new VfsProxyError('EINVAL', 'frame has no responses array')
  return responses.map(value => {
    const wire = value as WireResponse
    const id = requireInteger(wire.id, 'response id')
    if (!wire.ok) {
      return {
        id,
        response: {
          ok: false as const,
          code: typeof wire.code === 'string' ? wire.code : 'EIO',
          message: typeof wire.message === 'string' ? wire.message : 'proxy request failed',
        },
      }
    }
    const wireValue = wire.value ?? { kind: 'void' }
    let response: VfsResponse
    switch (wireValue.kind) {
      case 'stat':
        response = { ok: true, value: { kind: 'stat', stat: requireStat(wireValue.stat) } }
        break
      case 'entries':
        response = {
          ok: true,
          value: {
            kind: 'entries',
            entries: (wireValue.entries ?? []).map(entry => ({
              name: requireString(entry.name, 'entry name'),
              kind: entry.kind === 'directory' || entry.kind === 'symlink' ? entry.kind : 'file',
              ino: requireInteger(entry.ino, 'entry ino'),
            })),
          },
        }
        break
      case 'data': {
        const offset = requireInteger(wireValue.dataOffset, 'dataOffset')
        const length = requireInteger(wireValue.dataLength, 'dataLength')
        if (offset + length > binary.byteLength) {
          throw new VfsProxyError('EINVAL', 'response data out of range')
        }
        response = { ok: true, value: { kind: 'data', data: binary.slice(offset, offset + length) } }
        break
      }
      case 'written':
        response = { ok: true, value: { kind: 'written', written: requireInteger(wireValue.written, 'written') } }
        break
      default:
        response = { ok: true, value: { kind: 'void' } }
    }
    return { id, response }
  })
}

/** JSON length prefix plus JSON plus binary blob. */
function encodeEnvelope(json: unknown, binary: Uint8Array): Uint8Array {
  const body = encoder.encode(JSON.stringify(json))
  const frame = new Uint8Array(4 + body.byteLength + binary.byteLength)
  new DataView(frame.buffer).setUint32(0, body.byteLength, true)
  frame.set(body, 4)
  frame.set(binary, 4 + body.byteLength)
  return frame
}

function decodeEnvelope(frame: Uint8Array): { json: unknown; binary: Uint8Array } {
  if (frame.byteLength < 4) throw new VfsProxyError('EINVAL', 'frame shorter than its header')
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength)
  const jsonLength = view.getUint32(0, true)
  if (jsonLength > frame.byteLength - 4) throw new VfsProxyError('EINVAL', 'frame JSON length out of range')
  const json = JSON.parse(decoder.decode(frame.subarray(4, 4 + jsonLength))) as unknown
  return { json, binary: frame.subarray(4 + jsonLength) }
}

function joinBinary(parts: readonly Uint8Array[], length: number): Uint8Array {
  if (parts.length === 0) return new Uint8Array(0)
  const joined = new Uint8Array(length)
  let offset = 0
  for (const part of parts) {
    joined.set(part, offset)
    offset += part.byteLength
  }
  return joined
}

function requireInteger(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new VfsProxyError('EINVAL', `invalid ${field}`)
  }
  return value
}

function requireNumber(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new VfsProxyError('EINVAL', `invalid ${field}`)
  }
  return value
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.length === 0) throw new VfsProxyError('EINVAL', `invalid ${field}`)
  return value
}

function requireStat(value: VfsStat | undefined): VfsStat {
  if (value === undefined || typeof value !== 'object') throw new VfsProxyError('EINVAL', 'missing stat')
  return {
    kind: value.kind === 'directory' || value.kind === 'symlink' ? value.kind : 'file',
    size: requireInteger(value.size, 'stat size'),
    mode: requireInteger(value.mode, 'stat mode'),
    mtimeMs: requireNumber(value.mtimeMs, 'stat mtimeMs'),
    ino: requireInteger(value.ino, 'stat ino'),
  }
}
