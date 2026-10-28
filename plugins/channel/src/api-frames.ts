// SPDX-License-Identifier: MIT
/**
 * Remote-API frame codecs (channel.md §3.7–§3.10, §4.9). Every API frame starts
 * with `req_id u32`; 0x40 and 0x41 carry a length-prefixed canonical JSON head
 * followed by raw body bytes.
 * @module @phone-dsh/dsh-channel/api-frames
 */
import { decodeUtf8, encodeUtf8, readU32be, writeU32be } from './bytes.ts'
import { canonicalStringify } from './canonical-json.ts'
import { FrameError } from './errors.ts'
import type { ApiRequestHead, ApiResponseHead } from './payloads.ts'
import {
  isValidApiPath, isValidHeaderName, isValidHttpMethod,
} from './validate.ts'

/** API_REQ and API_RES bodies are at most 4 MiB (channel.md §3.7). */
export const MAX_API_BODY_BYTES = 4 * 1024 * 1024

/** Decoded API_REQ payload. */
export interface ApiRequestFrame {
  readonly reqId: number
  readonly head: ApiRequestHead
  readonly body: Uint8Array
}

/** Decoded API_RES payload; `head` is present on the first chunk only. */
export interface ApiResponseFrame {
  readonly reqId: number
  readonly head: ApiResponseHead | undefined
  readonly body: Uint8Array
}

/** Decoded API_ABORT payload. */
export interface ApiAbortFrame {
  readonly reqId: number
  readonly reason: string
}

function requireReqId(value: unknown): number {
  if (!Number.isInteger(value) || (value as number) < 0 || (value as number) > 0xffffffff) {
    throw new FrameError('BAD_PAYLOAD', 'req_id must be a u32')
  }
  return value as number
}

function requireHeaders(value: unknown): Record<string, string> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new FrameError('BAD_PAYLOAD', 'headers must be an object')
  }
  const headers: Record<string, string> = {}
  for (const [name, headerValue] of Object.entries(value as Record<string, unknown>)) {
    if (!isValidHeaderName(name)) throw new FrameError('BAD_PAYLOAD', `header name ${JSON.stringify(name)} is not lowercase`)
    if (typeof headerValue !== 'string') throw new FrameError('BAD_PAYLOAD', `header ${name} must be a string`)
    headers[name] = headerValue
  }
  return headers
}

/** Validate an API_REQ head. */
export function validateApiRequestHead(head: unknown): ApiRequestHead {
  if (head === null || typeof head !== 'object' || Array.isArray(head)) {
    throw new FrameError('BAD_PAYLOAD', 'API_REQ head must be an object')
  }
  const record = head as Record<string, unknown>
  if (!isValidHttpMethod(record['method'])) throw new FrameError('BAD_PAYLOAD', 'API_REQ method is not an HTTP token')
  if (!isValidApiPath(record['path'])) throw new FrameError('BAD_PAYLOAD', 'API_REQ path must start with /')
  return {
    method: record['method'],
    path: record['path'],
    headers: requireHeaders(record['headers']),
  }
}

/** Validate an API_RES head. */
export function validateApiResponseHead(head: unknown): ApiResponseHead {
  if (head === null || typeof head !== 'object' || Array.isArray(head)) {
    throw new FrameError('BAD_PAYLOAD', 'API_RES head must be an object')
  }
  const record = head as Record<string, unknown>
  const status = record['status']
  if (!Number.isInteger(status) || (status as number) < 100 || (status as number) > 599) {
    throw new FrameError('BAD_PAYLOAD', 'API_RES status must be an integer in 100..599')
  }
  return { status: status as number, headers: requireHeaders(record['headers']) }
}

function encodeHead(head: ApiRequestHead | ApiResponseHead): Uint8Array {
  return encodeUtf8(canonicalStringify(head))
}

function decodeHead(payload: Uint8Array, offset: number, headLength: number): unknown {
  let text: string
  try {
    text = decodeUtf8(payload.subarray(offset, offset + headLength))
  } catch {
    throw new FrameError('BAD_PAYLOAD', 'API head is not valid UTF-8')
  }
  try {
    return JSON.parse(text) as unknown
  } catch {
    throw new FrameError('BAD_PAYLOAD', 'API head is not valid JSON')
  }
}

/** Encode an API_REQ payload. */
export function encodeApiRequest(frame: ApiRequestFrame): Uint8Array {
  const reqId = requireReqId(frame.reqId)
  const head = encodeHead(validateApiRequestHead(frame.head))
  if (head.byteLength === 0) throw new FrameError('BAD_PAYLOAD', 'API_REQ head must not be empty')
  if (frame.body.byteLength > MAX_API_BODY_BYTES) {
    throw new FrameError('BAD_PAYLOAD', `API_REQ body exceeds ${MAX_API_BODY_BYTES} bytes`)
  }
  const out = new Uint8Array(8 + head.byteLength + frame.body.byteLength)
  writeU32be(out, 0, reqId)
  writeU32be(out, 4, head.byteLength)
  out.set(head, 8)
  out.set(frame.body, 8 + head.byteLength)
  return out
}

/** Decode an API_REQ payload. */
export function decodeApiRequest(payload: Uint8Array): ApiRequestFrame {
  if (payload.byteLength < 8) throw new FrameError('BAD_PAYLOAD', 'API_REQ payload is shorter than its header')
  const reqId = readU32be(payload, 0)
  const headLength = readU32be(payload, 4)
  if (headLength === 0 || 8 + headLength > payload.byteLength) {
    throw new FrameError('BAD_PAYLOAD', 'API_REQ head length is zero or overruns the payload')
  }
  const body = payload.slice(8 + headLength)
  if (body.byteLength > MAX_API_BODY_BYTES) {
    throw new FrameError('BAD_PAYLOAD', `API_REQ body exceeds ${MAX_API_BODY_BYTES} bytes`)
  }
  return {
    reqId,
    head: validateApiRequestHead(decodeHead(payload, 8, headLength)),
    body,
  }
}

/** Encode an API_RES payload; an undefined `head` is a continuation chunk. */
export function encodeApiResponse(frame: ApiResponseFrame): Uint8Array {
  const reqId = requireReqId(frame.reqId)
  const head = frame.head === undefined ? new Uint8Array(0) : encodeHead(validateApiResponseHead(frame.head))
  if (frame.body.byteLength > MAX_API_BODY_BYTES) {
    throw new FrameError('BAD_PAYLOAD', `API_RES body exceeds ${MAX_API_BODY_BYTES} bytes`)
  }
  const out = new Uint8Array(8 + head.byteLength + frame.body.byteLength)
  writeU32be(out, 0, reqId)
  writeU32be(out, 4, head.byteLength)
  out.set(head, 8)
  out.set(frame.body, 8 + head.byteLength)
  return out
}

/** Decode an API_RES payload. */
export function decodeApiResponse(payload: Uint8Array): ApiResponseFrame {
  if (payload.byteLength < 8) throw new FrameError('BAD_PAYLOAD', 'API_RES payload is shorter than its header')
  const reqId = readU32be(payload, 0)
  const headLength = readU32be(payload, 4)
  if (8 + headLength > payload.byteLength) {
    throw new FrameError('BAD_PAYLOAD', 'API_RES head length overruns the payload')
  }
  const body = payload.slice(8 + headLength)
  if (body.byteLength > MAX_API_BODY_BYTES) {
    throw new FrameError('BAD_PAYLOAD', `API_RES body exceeds ${MAX_API_BODY_BYTES} bytes`)
  }
  return {
    reqId,
    head: headLength === 0 ? undefined : validateApiResponseHead(decodeHead(payload, 8, headLength)),
    body,
  }
}

/** Encode an API_END payload (exactly 4 bytes). */
export function encodeApiEnd(reqId: number): Uint8Array {
  const out = new Uint8Array(4)
  writeU32be(out, 0, requireReqId(reqId))
  return out
}

/** Decode an API_END payload. */
export function decodeApiEnd(payload: Uint8Array): number {
  if (payload.byteLength !== 4) throw new FrameError('BAD_PAYLOAD', `API_END payload is ${payload.byteLength} bytes, expected 4`)
  return readU32be(payload, 0)
}

/** Encode an API_ABORT payload: `req_id` followed by `{"reason":...}`. */
export function encodeApiAbort(reqId: number, reason: string): Uint8Array {
  if (typeof reason !== 'string') throw new FrameError('BAD_PAYLOAD', 'API_ABORT reason must be a string')
  const json = encodeUtf8(canonicalStringify({ reason }))
  const out = new Uint8Array(4 + json.byteLength)
  writeU32be(out, 0, requireReqId(reqId))
  out.set(json, 4)
  return out
}

/** Decode an API_ABORT payload. */
export function decodeApiAbort(payload: Uint8Array): ApiAbortFrame {
  if (payload.byteLength < 5) throw new FrameError('BAD_PAYLOAD', 'API_ABORT payload is too short')
  const reqId = readU32be(payload, 0)
  let parsed: unknown
  try {
    parsed = JSON.parse(decodeUtf8(payload.subarray(4))) as unknown
  } catch {
    throw new FrameError('BAD_PAYLOAD', 'API_ABORT reason is not valid UTF-8 JSON')
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new FrameError('BAD_PAYLOAD', 'API_ABORT payload must be a JSON object')
  }
  const reason = (parsed as Record<string, unknown>)['reason']
  if (typeof reason !== 'string') throw new FrameError('BAD_PAYLOAD', 'API_ABORT reason must be a string')
  return { reqId, reason }
}
