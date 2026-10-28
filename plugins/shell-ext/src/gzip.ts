// SPDX-License-Identifier: MIT
/**
 * The Worker shell's `gzip`/`gunzip`/`zcat` commands.
 *
 * just-bash's bundled gzip family calls `node:zlib.gzipSync` / `gunzipSync`.
 * The pinned DSH browser Worker deliberately replaces that family with
 * `notImplementedFail` stubs, so the built-in cannot produce bytes there: it
 * writes an empty output and the upstream refusal surfaces as a console error
 * (the G2-A05 defect). This module shadows the family in the Worker command
 * table with one explicit backend resolution:
 *
 * 1. Web Compression Streams (`CompressionStream`/`DecompressionStream`),
 *    the Web API family the pinned runtime's own gzip overlay path uses;
 * 2. `node:zlib` when Web streams are absent and its gzip family is usable —
 *    the optional backend for hosts that genuinely carry a codec;
 * 3. otherwise the command fails loud: non-zero status, a stderr message and
 *    no output.
 *
 * The Web `DecompressionStream('gzip')` decodes exactly one member: it rejects
 * trailing bytes after the first member ("Trailing junk found after the end of
 * the compressed stream" in Node, "Extra bytes past the end."/"Failed to
 * Decode Data." in WebKit). RFC 1952 files may concatenate any number of
 * members, and the scenario batch hit that shape (G2-E10): every decode failed
 * and the command wrote a 0-byte output. The Worker codec therefore implements
 * the gzip container itself on top of the Web platform streams:
 *
 * - the header (including FEXTRA/FNAME/FCOMMENT/FHCRC) is parsed in this layer;
 * - each member's payload is inflated with `DecompressionStream('deflate-raw')`
 *   (or `node:zlib.inflateRawSync` on the optional fallback backend);
 * - the CRC32 and ISIZE trailer is verified in this layer, so a checksum
 *   failure still keeps the bytes it decoded before reporting the error;
 * - concatenated members are decoded in order.
 *
 * Every transform completes and validates before any byte reaches stdout or a
 * file: compressed output must be a complete gzip member that decompresses
 * back to the exact input, and a decompression error is an error. An empty or
 * truncated result can therefore never be presented as success.
 * @module @phone-dsh/dsh-shell-ext/gzip
 */

import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, ResolvedCommandContext } from 'just-bash/browser'
import * as nodeZlib from 'node:zlib'
import { appendShellTrailer, shellFailure } from './contract.ts'
import { byteStringToBytes, bytesToByteString } from './encoding.ts'

/** The gzip-family surface of a Node-compatible `node:zlib`. */
export interface GzipZlib {
  gzipSync(data: Uint8Array, options?: { readonly level?: number }): Uint8Array
  gunzipSync(data: Uint8Array): Uint8Array
  /** Raw-DEFLATE inflate used by the gzip container decoder, when present. */
  inflateRawSync?(data: Uint8Array): Uint8Array
}

/** The readable/writable pair a Compression Stream exposes. */
interface GzipStream {
  readonly readable: ReadableStream<Uint8Array>
  readonly writable: WritableStream<Uint8Array>
}

/** The Web compression formats this module drives. */
export type GzipStreamFormat = 'gzip' | 'deflate-raw'

/** Constructor shape of `CompressionStream`/`DecompressionStream`. */
export type GzipStreamConstructor = new (format: GzipStreamFormat) => GzipStream

/** Backend overrides, primarily for tests and non-standard hosts. */
export interface GzipBackendOptions {
  /** `node:zlib`-shaped codec; `null` removes the optional zlib backend. */
  readonly zlib?: GzipZlib | null
  /** `CompressionStream` constructor; `null` removes the Web backend. */
  readonly compressionStream?: GzipStreamConstructor | null
  /** `DecompressionStream` constructor; `null` removes the Web backend. */
  readonly decompressionStream?: GzipStreamConstructor | null
}

/** One resolved gzip codec. */
export interface GzipBackend {
  readonly kind: 'web-compression' | 'node:zlib'
  compress(data: Uint8Array, level?: number): Promise<Uint8Array>
  decompress(data: Uint8Array): Promise<Uint8Array>
}

/** No gzip codec is usable in this host. */
export class GzipBackendUnavailableError extends Error {
  constructor() {
    super('no compression backend is available: neither Web CompressionStream/DecompressionStream nor node:zlib produced a valid gzip member')
    this.name = 'GzipBackendUnavailableError'
  }
}

/**
 * The resolved codec produced bytes that fail its own portability check.
 *
 * This is the only gzip failure that is the Worker layer's fault; a missing or
 * corrupt *input* is the command's own data error (`command-exited`).
 */
export class GzipBackendIntegrityError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'GzipBackendIntegrityError'
  }
}

/**
 * The gzip *input* is invalid, truncated, or failed its trailer check.
 *
 * This is a data error of the command, not a backend failure: the command ran
 * and the file is bad (`command-exited`, never `backend-failed`).
 * `decoded` keeps every payload byte produced before the error, so a checksum
 * failure can still emit the bytes it decoded (GNU gzip's behaviour).
 */
export class GzipDecodeError extends Error {
  /** Payload bytes decoded before the error was detected. */
  readonly decoded: Uint8Array

  constructor(message: string, decoded: Uint8Array = new Uint8Array(0)) {
    super(message)
    this.name = 'GzipDecodeError'
    this.decoded = decoded
  }
}

/** The trailer CRC32/ISIZE did not match the decoded payload. */
export class GzipChecksumError extends GzipDecodeError {
  /** Which trailer field failed. */
  readonly field: 'crc' | 'length'

  constructor(field: 'crc' | 'length', decoded: Uint8Array) {
    super(field === 'crc' ? 'invalid compressed data--crc error' : 'invalid compressed data--length error', decoded)
    this.name = 'GzipChecksumError'
    this.field = field
  }
}

/**
 * Is `node:zlib.inflateRawSync` present?
 *
 * The browser Worker's `node:zlib` replacement carries only the named codec
 * stubs; reading the raw entry point through `Reflect` keeps that host's
 * composition free of a static "no matching export" import. A host without
 * the entry point decodes through `gunzipSync` instead (one member at a time,
 * with the codec doing its own trailer check).
 */
const NODE_RAW_INFLATE = Reflect.get(nodeZlib, 'inflateRawSync')

/** The default `node:zlib` backend: calls are deferred, never made at import. */
const DEFAULT_ZLIB: GzipZlib = {
  gzipSync: (data, options) => nodeZlib.gzipSync(data, options),
  gunzipSync: data => nodeZlib.gunzipSync(data),
  ...typeof NODE_RAW_INFLATE === 'function'
    ? { inflateRawSync: (data: Uint8Array) => (NODE_RAW_INFLATE as (bytes: Uint8Array) => Uint8Array)(data) }
    : {},
}

/** Copy a codec result into a plain `Uint8Array` (Node hands back Buffers). */
function toBytes(value: Uint8Array): Uint8Array {
  return new Uint8Array(value)
}

/** True when `bytes` starts with a structurally valid gzip header. */
export function isGzipMember(bytes: Uint8Array): boolean {
  if (bytes.byteLength < 18) return false
  if (bytes[0] !== 0x1f || bytes[1] !== 0x8b || bytes[2] !== 0x08) return false
  // Bits 5-7 of FLG are reserved and must be zero in a conforming member.
  return ((bytes[3] as number) & 0xe0) === 0
}

/** Concatenate byte chunks without spreading a large array into a call. */
function concatBytes(chunks: readonly Uint8Array[]): Uint8Array {
  let total = 0
  for (const chunk of chunks) total += chunk.byteLength
  const out = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out
}

/** Byte-wise equality used by the compression roundtrip check. */
function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false
  for (let index = 0; index < left.byteLength; index += 1) {
    if (left[index] !== right[index]) return false
  }
  return true
}

/** Fixed gzip header size (RFC 1952 §2.3). */
const GZIP_FIXED_HEADER = 10

/** Trailer size: CRC32 and ISIZE, both little-endian (RFC 1952 §2.3). */
const GZIP_TRAILER = 8

/** One raw-DEFLATE inflate attempt. */
interface RawInflateAttempt {
  /** Inflated bytes, empty when the attempt failed. */
  readonly bytes: Uint8Array
  /** Stream refusal, undefined on success. */
  readonly error: Error | undefined
}

/** Inflate one raw DEFLATE payload (a gzip member's body without its frame). */
type RawInflater = (payload: Uint8Array) => Promise<RawInflateAttempt>

/** CRC32 (IEEE 802.3, the gzip/zlib polynomial), built once. */
const CRC32_TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256)
  for (let index = 0; index < 256; index += 1) {
    let value = index
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) === 1 ? (0xedb88320 ^ (value >>> 1)) >>> 0 : value >>> 1
    }
    table[index] = value >>> 0
  }
  return table
})()

/**
 * CRC32 of a byte range.
 * @param bytes - bytes to fold.
 * @param seed - previous result, so a stream can be folded incrementally.
 * @returns the unsigned 32-bit CRC.
 */
function crc32(bytes: Uint8Array, seed = 0): number {
  let crc = (seed ^ 0xffffffff) >>> 0
  for (let index = 0; index < bytes.byteLength; index += 1) {
    crc = ((CRC32_TABLE[(crc ^ (bytes[index] as number)) & 0xff] as number) ^ (crc >>> 8)) >>> 0
  }
  return (crc ^ 0xffffffff) >>> 0
}

/** Read one little-endian u32 at `offset`. */
function readUint32LE(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] as number)
    | ((bytes[offset + 1] as number) << 8)
    | ((bytes[offset + 2] as number) << 16)
    | ((bytes[offset + 3] as number) << 24)) >>> 0
}

/**
 * Parse one member header and return the first payload byte.
 *
 * Handles every RFC 1952 optional field (FEXTRA, FNAME, FCOMMENT, FHCRC) so a
 * member another implementation wrote is not mistaken for a corrupt one.
 * @param data - the complete gzip byte string.
 * @param offset - member start.
 * @returns index of the first DEFLATE payload byte.
 * @throws GzipDecodeError when the header is invalid or truncated.
 */
function parseGzipHeader(data: Uint8Array, offset: number): number {
  if (data.byteLength - offset < 2 || data[offset] !== 0x1f || data[offset + 1] !== 0x8b) {
    throw new GzipDecodeError('not in gzip format')
  }
  const truncated = (): never => {
    throw new GzipDecodeError('unexpected end of file')
  }
  if (data.byteLength - offset < GZIP_FIXED_HEADER) return truncated()
  if (data[offset + 2] !== 0x08) throw new GzipDecodeError('invalid compressed data--format violated')
  const flags = data[offset + 3] as number
  // Bits 5-7 are reserved and must be zero in a conforming member.
  if ((flags & 0xe0) !== 0) throw new GzipDecodeError('invalid compressed data--format violated')
  let cursor = offset + GZIP_FIXED_HEADER
  if ((flags & 0x04) !== 0) {
    if (cursor + 2 > data.byteLength) return truncated()
    const extraLength = (data[cursor] as number) | ((data[cursor + 1] as number) << 8)
    cursor += 2
    if (cursor + extraLength > data.byteLength) return truncated()
    cursor += extraLength
  }
  for (const flag of [0x08, 0x10] as const) {
    if ((flags & flag) === 0) continue
    const terminator = data.indexOf(0, cursor)
    if (terminator === -1) return truncated()
    cursor = terminator + 1
  }
  if ((flags & 0x02) !== 0) {
    if (cursor + 2 > data.byteLength) return truncated()
    const expected = (data[cursor] as number) | ((data[cursor + 1] as number) << 8)
    if ((crc32(data.subarray(offset, cursor)) & 0xffff) !== expected) {
      throw new GzipDecodeError('invalid compressed data--format violated')
    }
    cursor += 2
  }
  return cursor
}

/**
 * Index of the next plausible gzip member header at or after `from`, or -1.
 *
 * The first four header bytes are checked (magic, DEFLATE method, FLG reserved
 * bits) so a chance `1f 8b` pair inside a compressed payload is not treated as
 * a member boundary. A header truncated to two or three bytes still names the
 * start of a member, so the previous member decodes before the truncation is
 * reported.
 */
function nextGzipMagic(data: Uint8Array, from: number): number {
  for (let index = from; index + 1 < data.byteLength; index += 1) {
    if (data[index] !== 0x1f || data[index + 1] !== 0x8b) continue
    if (index + 2 >= data.byteLength) return index
    if (data[index + 2] !== 0x08) continue
    if (index + 3 >= data.byteLength) return index
    if (((data[index + 3] as number) & 0xe0) === 0) return index
  }
  return -1
}

/** Concatenate the decoded members so far for an error's partial output. */
function decodedSoFar(members: readonly Uint8Array[]): Uint8Array {
  return members.length === 0 ? new Uint8Array(0) : concatBytes(members)
}

/**
 * Decode an RFC 1952 gzip byte string (zero or more concatenated members).
 *
 * A member ends where its raw DEFLATE payload ends; that boundary is found by
 * inflating candidate payload slices, not by trusting the Web
 * `DecompressionStream('gzip')`, which only accepts a single member. Candidates
 * are the eight bytes before each later plausible `1f 8b 08` header and the
 * final eight bytes of the input; inflating a slice that is not exactly one
 * complete DEFLATE stream fails, so the first successful slice is the member
 * boundary. The trailer is then verified here, which keeps the decoded bytes
 * available when only the CRC32 or ISIZE is wrong.
 * @param data - gzip bytes.
 * @param inflateRaw - raw DEFLATE decoder (Web stream or zlib).
 * @returns the concatenated member payloads.
 * @throws GzipDecodeError on invalid/truncated input.
 * @throws GzipChecksumError when a trailer field does not match.
 */
async function decodeGzip(data: Uint8Array, inflateRaw: RawInflater): Promise<Uint8Array> {
  const members: Uint8Array[] = []
  let offset = 0
  for (;;) {
    // Zero padding between members is skipped before the next header.
    while (offset > 0 && offset < data.byteLength && data[offset] === 0) offset += 1
    if (offset >= data.byteLength) break
    let payloadStart: number
    try {
      payloadStart = parseGzipHeader(data, offset)
    } catch (error) {
      if (error instanceof GzipDecodeError && error.decoded.byteLength === 0) {
        throw new GzipDecodeError(error.message, decodedSoFar(members))
      }
      throw error
    }
    if (payloadStart > data.byteLength - GZIP_TRAILER) {
      throw new GzipDecodeError('unexpected end of file', decodedSoFar(members))
    }
    // Candidate payload ends, in ascending order: the eight bytes before each
    // later plausible member header, then the final eight bytes of the input.
    // Inflating a slice that is not exactly one complete DEFLATE stream fails,
    // so the first successful slice is the end of this member.
    let decoded: Uint8Array | undefined
    let memberEnd = -1
    let lastError: Error | undefined
    let search = payloadStart
    for (;;) {
      const magic = nextGzipMagic(data, search)
      const candidate = magic === -1 ? data.byteLength - GZIP_TRAILER : magic - GZIP_TRAILER
      if (candidate >= payloadStart && candidate + GZIP_TRAILER <= data.byteLength) {
        const attempt = await inflateRaw(data.subarray(payloadStart, candidate))
        if (attempt.error === undefined) {
          decoded = attempt.bytes
          memberEnd = candidate
          break
        }
        lastError = attempt.error
      }
      if (magic === -1) break
      search = magic + 1
    }
    if (decoded === undefined) {
      const detail = lastError?.message ?? ''
      throw new GzipDecodeError(detail === '' ? 'unexpected end of file' : detail, decodedSoFar(members))
    }
    const expectedCrc = readUint32LE(data, memberEnd)
    if (crc32(decoded) !== expectedCrc) {
      throw new GzipChecksumError('crc', concatBytes([...members, decoded]))
    }
    if ((decoded.byteLength >>> 0) !== readUint32LE(data, memberEnd + 4)) {
      throw new GzipChecksumError('length', concatBytes([...members, decoded]))
    }
    members.push(decoded)
    offset = memberEnd + GZIP_TRAILER
  }
  return decodedSoFar(members)
}

/** Transform one buffer through a Web Compression/Decompression Stream. */
async function transformWith(
  ctor: GzipStreamConstructor,
  format: GzipStreamFormat,
  data: Uint8Array,
): Promise<Uint8Array> {
  const stream = new ctor(format)
  const writer = stream.writable.getWriter()
  const reader = stream.readable.getReader()
  const chunks: Uint8Array[] = []
  const reading = (async (): Promise<void> => {
    for (;;) {
      const next = await reader.read()
      if (next.done === true) return
      const value = next.value
      if (value !== undefined) chunks.push(value)
    }
  })()
  // The reader loop starts before the write; keep an early stream error from
  // becoming an unhandled rejection while the write is still in flight.
  void reading.catch(() => {})
  try {
    await writer.write(data)
    await writer.close()
    await reading
  } catch (error) {
    await writer.abort().catch(() => {})
    await reader.cancel().catch(() => {})
    await reading.catch(() => {})
    throw error
  }
  return concatBytes(chunks)
}

/** Wrap `node:zlib` as a backend. */
function createZlibBackend(zlib: GzipZlib): GzipBackend {
  const inflateRawSync = zlib.inflateRawSync
  return {
    kind: 'node:zlib',
    async compress(data, level) {
      const options = level === undefined ? undefined : { level }
      return toBytes(zlib.gzipSync(data, options))
    },
    async decompress(data) {
      if (typeof inflateRawSync !== 'function') {
        // A zlib shim without the raw entry point still decodes one member.
        return toBytes(zlib.gunzipSync(data))
      }
      return await decodeGzip(data, async (payload) => {
        try {
          return { bytes: toBytes(inflateRawSync(payload)), error: undefined }
        } catch (error) {
          return { bytes: new Uint8Array(0), error: error instanceof Error ? error : new Error(String(error)) }
        }
      })
    },
  }
}

/** Wrap Web Compression Streams as a backend. */
function createWebBackend(
  compression: GzipStreamConstructor,
  decompression: GzipStreamConstructor,
): GzipBackend {
  const inflateRaw: RawInflater = async (payload) => {
    try {
      return { bytes: await transformWith(decompression, 'deflate-raw', payload), error: undefined }
    } catch (error) {
      return { bytes: new Uint8Array(0), error: error instanceof Error ? error : new Error(String(error)) }
    }
  }
  return {
    kind: 'web-compression',
    async compress(data) {
      return await transformWith(compression, 'gzip', data)
    },
    async decompress(data) {
      return await decodeGzip(data, inflateRaw)
    },
  }
}

/** Probe a candidate with one empty member; false means "do not use it". */
async function backendWorks(backend: GzipBackend): Promise<boolean> {
  try {
    const member = await backend.compress(new Uint8Array(0))
    if (!isGzipMember(member)) return false
    const roundtrip = await backend.decompress(member)
    return roundtrip.byteLength === 0
  } catch {
    return false
  }
}

/** Read a Web constructor from the global object, if the host published one. */
function webConstructor(name: 'CompressionStream' | 'DecompressionStream'): GzipStreamConstructor | undefined {
  const value = (globalThis as unknown as Record<string, unknown>)[name]
  return typeof value === 'function' ? value as GzipStreamConstructor : undefined
}

/**
 * Resolve the one codec this host will use.
 *
 * Web Compression Streams are preferred where both constructors exist, which
 * keeps browser Worker hosts on the path that does not touch the deliberately
 * stubbed `node:zlib`. `node:zlib` remains the optional backend for a host
 * without Web streams (and is never probed when the Web backend works, so the
 * upstream stub's console refusal is not triggered on the normal path).
 * @param options - backend overrides for tests or non-standard hosts.
 * @returns a probed backend.
 * @throws GzipBackendUnavailableError when no candidate produces a valid member.
 */
export async function resolveGzipBackend(options: GzipBackendOptions = {}): Promise<GzipBackend> {
  const compression = options.compressionStream === undefined
    ? webConstructor('CompressionStream')
    : options.compressionStream
  const decompression = options.decompressionStream === undefined
    ? webConstructor('DecompressionStream')
    : options.decompressionStream
  if (typeof compression === 'function' && typeof decompression === 'function') {
    const backend = createWebBackend(compression, decompression)
    if (await backendWorks(backend)) return backend
  }
  const zlib = options.zlib === undefined ? DEFAULT_ZLIB : options.zlib
  if (zlib !== null && typeof zlib.gzipSync === 'function' && typeof zlib.gunzipSync === 'function') {
    const backend = createZlibBackend(zlib)
    if (await backendWorks(backend)) return backend
  }
  throw new GzipBackendUnavailableError()
}

/** A human-readable file-system failure without a stack or local path. */
function describeFsError(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code
  if (code === 'ENOENT') return 'No such file or directory'
  if (code === 'EISDIR') return 'Is a directory'
  if (code === 'EACCES' || code === 'EPERM') return 'Permission denied'
  if (code === 'EFBIG') return 'File too large'
  return error instanceof Error ? error.message : String(error)
}

/** A gzip syntax problem (unknown option, missing value, unsupported mode). */
class GzipUsageError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'GzipUsageError'
  }
}

/** Mode defaults for one member of the gzip family. */
interface CodecDefaults {
  readonly decompress: boolean
  readonly stdout: boolean
  readonly keep: boolean
}

/** Parsed gzip argv. */
interface ParsedArguments {
  readonly help: boolean
  readonly decompress: boolean
  readonly stdout: boolean
  readonly keep: boolean
  readonly force: boolean
  readonly test: boolean
  readonly suffix: string
  readonly level: number | undefined
  readonly inputs: readonly string[]
}

/** Split `--name=value` once. */
function splitLongOption(argument: string): { readonly flag: string; readonly value: string | undefined } {
  const equals = argument.indexOf('=')
  if (equals === -1) return { flag: argument, value: undefined }
  return { flag: argument.slice(0, equals), value: argument.slice(equals + 1) }
}

/** Parse the gzip option surface into one explicit mode. */
function parseArguments(name: string, argv: readonly string[], defaults: CodecDefaults): ParsedArguments {
  let decompress = defaults.decompress
  let stdout = defaults.stdout
  let keep = defaults.keep
  let force = false
  let test = false
  let help = false
  let suffix = '.gz'
  let level: number | undefined
  const inputs: string[] = []
  let endOfOptions = false

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index] as string
    if (endOfOptions || argument === '-' || !argument.startsWith('-')) {
      inputs.push(argument)
      continue
    }
    if (argument === '--') {
      endOfOptions = true
      continue
    }
    if (argument.startsWith('--')) {
      const { flag, value } = splitLongOption(argument)
      if (value !== undefined && flag !== '--suffix') {
        throw new GzipUsageError(`option '${flag}' does not take a value`)
      }
      switch (flag) {
        case '--stdout':
        case '--to-stdout':
          stdout = true
          break
        case '--decompress':
        case '--uncompress':
          decompress = true
          break
        case '--keep':
          keep = true
          break
        case '--force':
          force = true
          break
        case '--test':
          test = true
          decompress = true
          break
        case '--quiet':
        case '--verbose':
        case '--no-name':
        case '--name':
          // Accepted: the Worker command has no warnings, stores no name and
          // emits no ratio line, so these flags change nothing.
          break
        case '--fast':
          level = 1
          break
        case '--best':
          level = 9
          break
        case '--help':
          help = true
          break
        case '--suffix': {
          const next = value ?? argv[index + 1]
          if (next === undefined) throw new GzipUsageError(`option '${flag}' requires a value`)
          if (value === undefined) index += 1
          suffix = next
          break
        }
        case '--recursive':
        case '--list':
          throw new GzipUsageError(`option '${flag}' is not supported by the Worker ${name}`)
        default:
          throw new GzipUsageError(`unrecognized option '${flag}'`)
      }
      continue
    }
    for (let position = 1; position < argument.length; position += 1) {
      const letter = argument[position] as string
      switch (letter) {
        case 'c':
          stdout = true
          break
        case 'd':
          decompress = true
          break
        case 'f':
          force = true
          break
        case 'k':
          keep = true
          break
        case 'q':
        case 'v':
        case 'n':
        case 'N':
          break
        case 't':
          test = true
          decompress = true
          break
        case 'h':
          help = true
          break
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
        case '6':
        case '7':
        case '8':
        case '9':
          level = Number(letter)
          break
        case 'S': {
          const rest = argument.slice(position + 1)
          if (rest !== '') {
            suffix = rest
            position = argument.length
          } else {
            const next = argv[index + 1]
            if (next === undefined) throw new GzipUsageError("option '-S' requires a value")
            suffix = next
            index += 1
          }
          break
        }
        case 'r':
        case 'l':
          throw new GzipUsageError(`option '-${letter}' is not supported by the Worker ${name}`)
        default:
          throw new GzipUsageError(`invalid option -- '${letter}'`)
      }
    }
  }
  if (suffix === '') throw new GzipUsageError('suffix must not be empty')
  return { help, decompress, stdout, keep, force, test, suffix, level, inputs }
}

/** Usage text for `--help`. */
function helpText(name: string): string {
  return [
    `Usage: ${name} [OPTION]... [FILE]...`,
    'Compress or expand FILEs; with no FILE, read standard input.',
    '',
    '  -c, --stdout       write to standard output, keep input files',
    '  -d, --decompress   decompress',
    '  -f, --force        overwrite existing output files',
    '  -k, --keep         keep input files',
    '  -t, --test         test compressed file integrity',
    '  -q, --quiet        suppress warnings',
    '  -S, --suffix=SUF   use suffix SUF (default: .gz)',
    '  -1 .. -9           compression level',
    '      --help         display this help and exit',
    '',
  ].join('\n')
}

/**
 * Throw unless `data` starts with the gzip magic, naming the source.
 *
 * Only the two magic bytes are checked here: the container decoder owns the
 * rest of the header so a header that is short or malformed is reported as
 * truncated/invalid instead of as the wrong file type.
 */
function assertGzipInput(data: Uint8Array, source: string): void {
  if (data.byteLength < 2 || data[0] !== 0x1f || data[1] !== 0x8b) {
    throw new GzipDecodeError(`${source}: not in gzip format`)
  }
}

/** Throw unless `member` is complete and decompresses to `input` exactly. */
async function assertCompleteMember(backend: GzipBackend, member: Uint8Array, input: Uint8Array): Promise<void> {
  if (!isGzipMember(member)) throw new GzipBackendIntegrityError('compression backend produced an invalid gzip member')
  let roundtrip: Uint8Array
  try {
    roundtrip = await backend.decompress(member)
  } catch (error) {
    if (error instanceof GzipDecodeError) {
      throw new GzipBackendIntegrityError(`compression backend produced an invalid gzip member: ${error.message}`)
    }
    throw error
  }
  if (!bytesEqual(roundtrip, input)) throw new GzipBackendIntegrityError('compression backend failed its gzip roundtrip check')
}

/** Write one output file, refusing to overwrite unless forced. */
async function writeOutput(
  ctx: ResolvedCommandContext,
  display: string,
  path: string,
  bytes: Uint8Array,
  force: boolean,
): Promise<void> {
  if (!force && await ctx.fs.exists(path)) throw new Error(`${display}: already exists; not overwritten`)
  try {
    await ctx.fs.writeFile(path, bytes)
  } catch (error) {
    throw new Error(`${display}: ${describeFsError(error)}`)
  }
}

/** Remove one successfully consumed input, mapping its error like a read. */
async function removeInput(ctx: ResolvedCommandContext, display: string, path: string): Promise<void> {
  try {
    await ctx.fs.rm(path)
  } catch (error) {
    throw new Error(`${display}: ${describeFsError(error)}`)
  }
}

/** Result of one input: stdout bytes and/or the data error to report. */
interface ProcessedInput {
  /** Bytes this mode prints before any error is reported. */
  readonly output?: Uint8Array | undefined
  /** Data error to report as the command's own failure. */
  readonly error?: Error | undefined
}

/** Compress or expand one input; return stdout bytes and any data error. */
async function processInput(
  input: string,
  parsed: ParsedArguments,
  backend: GzipBackend,
  ctx: ResolvedCommandContext,
): Promise<ProcessedInput> {
  const fromStdin = input === '-'
  const virtualPath = fromStdin ? undefined : ctx.fs.resolvePath(ctx.cwd, input)
  let data: Uint8Array
  if (fromStdin) {
    data = byteStringToBytes(String(ctx.stdin ?? ''))
  } else {
    try {
      data = await ctx.fs.readFileBuffer(virtualPath as string)
    } catch (error) {
      throw new Error(`${input}: ${describeFsError(error)}`)
    }
  }
  const source = fromStdin ? 'stdin' : input

  /**
   * Decode one input, keeping the payload bytes an invalid trailer produced.
   * The source name is added here so every diagnostic reads
   * `gzip: <file>: <reason>` like GNU gzip.
   */
  const decode = async (): Promise<{ readonly expanded: Uint8Array; readonly error: GzipDecodeError | undefined }> => {
    try {
      return { expanded: await backend.decompress(data), error: undefined }
    } catch (error) {
      if (!(error instanceof GzipDecodeError)) throw error
      const named = new GzipDecodeError(`${source}: ${error.message}`, error.decoded)
      return { expanded: error.decoded, error: named }
    }
  }

  if (parsed.test) {
    assertGzipInput(data, source)
    const { error } = await decode()
    return error === undefined ? {} : { error }
  }

  if (parsed.decompress) {
    assertGzipInput(data, source)
    const { expanded, error } = await decode()
    if (parsed.stdout || fromStdin) {
      return {
        output: expanded.byteLength === 0 ? undefined : expanded,
        error,
      }
    }
    // In-place mode does not replace the input with a corrupt output; the
    // decoded bytes are only surfaced where they were explicitly requested.
    if (error !== undefined) return { error }
    if (!input.endsWith(parsed.suffix) || input.length === parsed.suffix.length) {
      throw new Error(`${input}: unknown suffix -- ignored`)
    }
    const target = input.slice(0, -parsed.suffix.length)
    await writeOutput(ctx, target, ctx.fs.resolvePath(ctx.cwd, target), expanded, parsed.force)
    if (!parsed.keep) await removeInput(ctx, source, virtualPath as string)
    return {}
  }

  if (virtualPath !== undefined && input.endsWith(parsed.suffix)) {
    throw new Error(`${input} already has ${parsed.suffix} suffix -- unchanged`)
  }
  const member = await backend.compress(data, parsed.level)
  await assertCompleteMember(backend, member, data)
  if (parsed.stdout || fromStdin) return { output: member }
  const target = `${input}${parsed.suffix}`
  await writeOutput(ctx, target, `${virtualPath as string}${parsed.suffix}`, member, parsed.force)
  if (!parsed.keep) await removeInput(ctx, source, virtualPath as string)
  return {}
}

/** Run one gzip-family command body. */
async function execute(
  name: string,
  argv: readonly string[],
  ctx: ResolvedCommandContext,
  defaults: CodecDefaults,
  backendOptions: GzipBackendOptions,
): Promise<ExecResult> {
  const message = (error: unknown): string => `${name}: ${error instanceof Error ? error.message : String(error)}`
  let parsed: ParsedArguments
  try {
    parsed = parseArguments(name, argv, defaults)
  } catch (error) {
    // An option this Worker codec does not implement is a usage error (2),
    // never a 1 that a caller could read as a data failure.
    return shellFailure(name, message(error), 'unsupported-option')
  }
  if (parsed.help) return { stdout: helpText(name), stderr: '', exitCode: 0 }
  let backend: GzipBackend
  try {
    backend = await resolveGzipBackend(backendOptions)
  } catch (error) {
    return shellFailure(name, message(error), 'backend-failed', {
      hint: 'no gzip backend in this Worker; Web Compression Streams and node:zlib both failed',
    })
  }
  const inputs = parsed.inputs.length === 0 ? ['-'] : parsed.inputs
  const chunks: Uint8Array[] = []
  let stderr = ''
  let exitCode = 0
  // Only a codec that produced bad bytes is our layer's failure. A missing or
  // corrupt input is the command's own data error and must read
  // `command-exited` (contract.ts).
  let backendFailed = false
  for (const input of inputs) {
    try {
      const processed = await processInput(input, parsed, backend, ctx)
      if (processed.output !== undefined) chunks.push(processed.output)
      if (processed.error !== undefined) {
        stderr += `${name}: ${processed.error.message}\n`
        exitCode = 1
      }
    } catch (error) {
      if (error instanceof GzipBackendIntegrityError) backendFailed = true
      stderr += `${name}: ${error instanceof Error ? error.message : String(error)}\n`
      exitCode = 1
    }
  }
  return {
    stdout: bytesToByteString(concatBytes(chunks)),
    stdoutKind: 'bytes',
    stdoutEncoding: 'binary',
    // One trailer for the batch; the per-input lines above stay as the
    // command's own diagnostics.
    stderr: exitCode === 0
      ? stderr
      : appendShellTrailer(stderr, {
        exitCode,
        program: name,
        reason: backendFailed ? 'backend-failed' : 'command-exited',
      }),
    exitCode,
  }
}

/** Build one gzip-family command over the resolved backend. */
function createCodecCommand(
  name: string,
  defaults: CodecDefaults,
  options: GzipBackendOptions,
): Command {
  return defineCommand(name, async (args, ctx) => await execute(name, args, ctx, defaults, options))
}

/**
 * The Worker `gzip` command (decompress with `-d` or `gunzip`).
 * @param options - backend overrides for tests and non-standard hosts.
 */
export function createGzipCommand(options: GzipBackendOptions = {}): Command {
  return createCodecCommand('gzip', { decompress: false, stdout: false, keep: false }, options)
}

/**
 * The Worker `gunzip` command (`gzip -d` semantics).
 * @param options - backend overrides for tests and non-standard hosts.
 */
export function createGunzipCommand(options: GzipBackendOptions = {}): Command {
  return createCodecCommand('gunzip', { decompress: true, stdout: false, keep: false }, options)
}

/**
 * The Worker `zcat` command (`gzip -dc` semantics: expand to stdout).
 * @param options - backend overrides for tests and non-standard hosts.
 */
export function createZcatCommand(options: GzipBackendOptions = {}): Command {
  return createCodecCommand('zcat', { decompress: true, stdout: true, keep: true }, options)
}
