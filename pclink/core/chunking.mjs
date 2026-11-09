/** Chunking and reassembly for 1 MiB items and 8 MiB values (§6.2). */

import {
  b64urlDecode,
  b64urlEncode,
  CHUNK_BYTES,
  decodeUtf8,
  MAX_CHUNK_B64_CHARS,
  MAX_VALUE_BYTES,
  utf8,
} from './encoding.mjs'
import { pclinkError } from './errors.mjs'
import { parseStrictJson } from './json.mjs'

/** 30-second timeout per reassembled value. */
export const REASSEMBLY_TIMEOUT_MS = 30_000

/**
 * Split one byte range into contiguous b64url chunks.
 * @param {Uint8Array} bytes Value encoding.
 * @param {number} [chunkBytes] Raw bytes per chunk.
 * @returns {Array<{part: number, last: boolean, data: string}>} chunk descriptors.
 */
export function splitChunks(bytes, chunkBytes = CHUNK_BYTES) {
  if (!Number.isInteger(chunkBytes) || chunkBytes < 1) throw new Error('chunkBytes must be a positive integer')
  const buffer = Buffer.from(bytes)
  const chunks = []
  let offset = 0
  let part = 0
  do {
    const end = Math.min(offset + chunkBytes, buffer.length)
    const data = b64urlEncode(buffer.subarray(offset, end))
    if (data.length > MAX_CHUNK_B64_CHARS) throw pclinkError('frame_too_large', 'chunk data exceeds the relay-safe limit')
    chunks.push({ part, last: end === buffer.length, data })
    offset = end
    part += 1
  } while (offset < buffer.length)
  return chunks
}

/**
 * Encode one stream value: a single item when ≤1 MiB, otherwise chunk frames.
 * @param {string} streamId Stream id.
 * @param {unknown} value JSON value yielded by DSH.
 * @param {number} [chunkBytes] Test/chunk size override.
 * @returns {{kind: 'item', frame: Record<string, unknown>} | {kind: 'chunks', frames: Array<Record<string, unknown>>, bytes: number}} encoding.
 */
export function encodeStreamValue(streamId, value, chunkBytes = CHUNK_BYTES) {
  const json = JSON.stringify(value)
  const bytes = utf8(json)
  if (bytes.length > MAX_VALUE_BYTES) throw pclinkError('frame_too_large', 'value exceeds 8 MiB')
  if (bytes.length <= CHUNK_BYTES) {
    return { kind: 'item', frame: { type: 'rpc.stream.item', streamId, value } }
  }
  const frames = splitChunks(bytes, chunkBytes).map(chunk => ({
    type: 'rpc.stream.chunk', streamId, part: chunk.part, last: chunk.last, data: chunk.data,
  }))
  return { kind: 'chunks', frames, bytes: bytes.length }
}

/**
 * Encode one unary result: a normal rpc.result when its JSON is ≤1 MiB, otherwise result chunks.
 * @param {Record<string, unknown>} resultFrame The complete `rpc.result` object.
 * @param {number} [chunkBytes] Test/chunk size override.
 * @returns {{kind: 'result', frame: Record<string, unknown>} | {kind: 'chunks', frames: Array<Record<string, unknown>>, bytes: number}} encoding.
 */
export function encodeUnaryResult(resultFrame, chunkBytes = CHUNK_BYTES) {
  if (resultFrame.type !== 'rpc.result' || typeof resultFrame.id !== 'string') throw new Error('encodeUnaryResult expects an rpc.result')
  const json = JSON.stringify(resultFrame)
  const bytes = utf8(json)
  if (bytes.length > MAX_VALUE_BYTES) throw pclinkError('frame_too_large', 'result exceeds 8 MiB')
  if (bytes.length <= CHUNK_BYTES) return { kind: 'result', frame: resultFrame }
  const frames = splitChunks(bytes, chunkBytes).map(chunk => ({
    type: 'rpc.result.chunk', id: resultFrame.id, part: chunk.part, last: chunk.last, data: chunk.data,
  }))
  return { kind: 'chunks', frames, bytes: bytes.length }
}

/**
 * Reassemble chunk sequences keyed by streamId (streams) or id (unary results).
 * Different keys may interleave; one key may not interleave two values.
 */
export class ChunkReassembler {
  /**
   * @param {{timeoutMs?: number, maxBytes?: number, now?: () => number}} [options] Limits and clock.
   */
  constructor(options = {}) {
    this.timeoutMs = options.timeoutMs ?? REASSEMBLY_TIMEOUT_MS
    this.maxBytes = options.maxBytes ?? MAX_VALUE_BYTES
    this.now = options.now ?? Date.now
    this.entries = new Map()
  }

  /**
   * Reassembly key for a chunk frame.
   * @param {Record<string, unknown>} event Chunk frame.
   * @returns {string} key.
   */
  static keyOf(event) {
    if (event.type === 'rpc.result.chunk') return `id:${String(event.id)}`
    return `stream:${String(event.streamId)}`
  }

  /**
   * Push one chunk; returns the parsed value when `last` completes a sequence.
   * @param {Record<string, unknown>} event `rpc.stream.chunk` or `rpc.result.chunk`.
   * @returns {{complete: false} | {complete: true, value: unknown, bytes: number, key: string, kind: 'stream'|'result'}} result.
   */
  push(event) {
    const isResult = event.type === 'rpc.result.chunk'
    if (!isResult && event.type !== 'rpc.stream.chunk') throw pclinkError('bad_frame', 'not a chunk frame')
    const key = ChunkReassembler.keyOf(event)
    if (typeof event.part !== 'number' || !Number.isInteger(event.part) || event.part < 0) throw pclinkError('bad_frame', 'chunk part')
    if (typeof event.last !== 'boolean') throw pclinkError('bad_frame', 'chunk last')
    if (typeof event.data !== 'string' || event.data.length > MAX_CHUNK_B64_CHARS) throw pclinkError('bad_frame', 'chunk data')
    const data = b64urlDecode(event.data)
    const now = this.now()
    this.expire(now)
    let entry = this.entries.get(key)
    if (entry === undefined) {
      if (event.part !== 0) throw pclinkError('bad_frame', 'chunk sequence does not start at part 0')
      entry = { nextPart: 0, parts: [], bytes: 0, updatedAt: now, lastSeen: false }
      this.entries.set(key, entry)
    }
    if (event.part !== entry.nextPart) throw pclinkError('bad_frame', 'duplicate, missing or interleaved chunk part')
    if (entry.lastSeen) throw pclinkError('bad_frame', 'chunk after last')
    entry.parts.push(data)
    entry.bytes += data.length
    if (entry.bytes > this.maxBytes) {
      this.entries.delete(key)
      throw pclinkError('frame_too_large', 'value exceeds 8 MiB')
    }
    entry.nextPart += 1
    entry.updatedAt = now
    if (!event.last) return { complete: false }
    entry.lastSeen = true
    this.entries.delete(key)
    const bytes = Buffer.concat(entry.parts)
    let value
    try {
      value = parseStrictJson(decodeUtf8(bytes))
    } catch (error) {
      throw pclinkError('bad_frame', `reassembled value is not one JSON value: ${error.message}`)
    }
    return { complete: true, value, bytes: bytes.length, key, kind: isResult ? 'result' : 'stream' }
  }

  /**
   * Drop entries idle for longer than the 30-second budget.
   * @param {number} [now] Current epoch ms.
   * @returns {string[]} dropped keys.
   */
  expire(now = this.now()) {
    const dropped = []
    for (const [key, entry] of this.entries) {
      if (now - entry.updatedAt > this.timeoutMs) {
        this.entries.delete(key)
        dropped.push(key)
      }
    }
    return dropped
  }

  /**
   * Drop one key (cancel/terminal stream or failed call).
   * @param {string} key Reassembly key.
   */
  discard(key) {
    this.entries.delete(key)
  }

  /** Drop all partial values. */
  clear() {
    this.entries.clear()
  }

  /** Number of in-progress values. */
  get size() {
    return this.entries.size
  }
}
