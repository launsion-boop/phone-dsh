// SPDX-License-Identifier: MIT
/**
 * The zlib codec and CRC-32 that git objects and pack files need.
 *
 * `node:zlib` is not usable here: the DSH Worker's `node:zlib` proxy only
 * carries the Zstandard/gzip family (no `deflateSync`/`inflateSync`/`crc32`),
 * and a browser has no `node:zlib` at all. Git stores every loose object and
 * every pack member as a zlib-wrapped DEFLATE stream, so the codec is plain
 * JavaScript: the MIT `fflate` package supplies the DEFLATE engine (synchronous
 * for whole buffers, streaming for the one-pass pack reader), and this module
 * supplies the zlib envelope rules git relies on plus the pack-index CRC-32 and
 * the zlib Adler-32 check.
 *
 * `fflate`'s browser entry is imported (not the package root): the root
 * entry probes `node:worker_threads` through `createRequire` (the Worker
 * runtime only stubs that module). The browser entry is the same synchronous
 * codec without the Node-only worker shim, and behaves identically under Node.
 * @module @phone-dsh/dsh-wasi-toolbox/git/compress
 */
import { Unzlib, unzlibSync, zlibSync } from 'fflate/browser'

/**
 * Compress bytes the way git stores loose objects and pack members.
 * @param data - raw object bytes.
 * @returns a zlib-wrapped DEFLATE stream.
 */
export function deflate(data: Uint8Array): Uint8Array {
  return zlibSync(data)
}

/**
 * Decompress a zlib-wrapped DEFLATE stream.
 *
 * A zlib envelope is at least eight bytes (two-byte header, a two-byte empty
 * DEFLATE stream and a four-byte Adler-32). `fflate` answers an empty array
 * instead of failing for two-to-six-byte prefixes; pack reads rely on a
 * truncated stream failing so they can grow their read window, so such a
 * prefix is rejected explicitly.
 * @param data - zlib-wrapped DEFLATE bytes.
 * @returns the raw object bytes.
 */
export function inflate(data: Uint8Array): Uint8Array {
  if (data.byteLength < 8) throw new Error('truncated zlib stream')
  return unzlibSync(data)
}

/** One zlib stream decoded from a larger buffer, and its input length. */
export interface InflatedStream {
  /** The decompressed bytes. */
  readonly data: Uint8Array
  /** Input bytes the zlib envelope occupied (header + DEFLATE + Adler-32). */
  readonly consumed: number
}

/**
 * Internal state of `fflate`'s streaming `Unzlib` (0.8.3, exact-pinned).
 *
 * `Unzlib` has no public "bytes consumed" answer, but after a push the
 * decompressor keeps only the unconsumed input tail in `p` and the bit offset
 * inside its first byte in `s.p`. The SDK's type declarations mark these
 * private; the version is pinned in `wasi-toolbox/package.json`, and the oracle
 * tests compare the derived length against a binary-search implementation, so
 * a dependency upgrade that changes the fields fails loudly here.
 */
interface UnzlibInternals {
  /** Unconsumed input tail after the latest push. */
  p: Uint8Array
  /** DEFLATE decoder state: `f` is the final-block flag, `l` the live table. */
  s: { readonly f?: number; readonly l?: unknown; readonly p?: number }
}

/** The streaming inflater's private fields, checked before first use. */
function unzlibInternals(stream: Unzlib): UnzlibInternals {
  const value = stream as unknown as UnzlibInternals
  if (!(value.p instanceof Uint8Array) || value.s === null || typeof value.s !== 'object') {
    throw new Error('fflate streaming inflater internals changed: cannot report the consumed length')
  }
  return value
}

/** Adler-32, the checksum zlib puts in its trailer. */
export function adler32(data: Uint8Array, previous = 1): number {
  let a = previous & 0xffff
  let b = (previous >>> 16) & 0xffff
  let offset = 0
  while (offset < data.byteLength) {
    const end = Math.min(offset + 5552, data.byteLength)
    for (; offset < end; offset += 1) {
      a += data[offset] as number
      b += a
    }
    a %= 65521
    b %= 65521
  }
  return ((b << 16) | a) >>> 0
}

/**
 * Incremental zlib decoder that also reports how many input bytes the stream
 * occupied, so a pack reader can advance to the next object after one pass.
 *
 * The caller pushes successive slices of a larger buffer. Once the DEFLATE
 * stream ends, the zlib trailer (four Adler-32 bytes, starting at the next
 * byte boundary) must also be present; {@link finish} verifies it and returns
 * the data. A truncated stream or a bad trailer throws.
 */
export class ZlibInflateStream {
  private readonly stream: Unzlib
  private readonly chunks: Uint8Array[] = []
  private checksum = 1
  private pushed = 0
  private done = false
  private consumed = 0

  constructor() {
    this.stream = new Unzlib(chunk => {
      if (chunk.byteLength === 0) return
      this.chunks.push(chunk)
      this.checksum = adler32(chunk, this.checksum)
    })
  }

  /**
   * Feed the next input slice.
   * @returns true once the DEFLATE stream has ended.
   */
  push(chunk: Uint8Array): boolean {
    if (this.done) return true
    if (chunk.byteLength === 0) return false
    this.pushed += chunk.byteLength
    this.stream.push(chunk, false)
    const internals = unzlibInternals(this.stream)
    // A final Huffman block leaves `l` as null; a final stored block leaves it
    // undefined (it never built a table). A stream interrupted mid-block keeps
    // a live table (`l` set) even when the block's BFINAL bit was 1.
    if (internals.s.f !== 1 || (internals.s.l !== null && internals.s.l !== undefined)) return false
    // The stream ended inside the pushed bytes. `p` starts at the last
    // partially decoded byte (if the final block did not end on a byte
    // boundary), followed by the four-byte Adler-32 trailer and any further
    // input the caller supplied.
    const partial = (internals.s.p ?? 0) === 0 ? 0 : 1
    const consumed = this.pushed - internals.p.byteLength + partial + 4
    const trailerAt = partial
    // A chunked caller may finish the DEFLATE stream before it has pushed the
    // four Adler-32 bytes. That is not an error yet: keep the bytes buffered
    // and wait for the next push. `finish()` still fails a stream that never
    // gets its trailer.
    if (consumed > this.pushed || internals.p.byteLength < trailerAt + 4) return false
    const trailer = internals.p.subarray(trailerAt, trailerAt + 4)
    const expected = ((trailer[0] as number) << 24 | (trailer[1] as number) << 16
      | (trailer[2] as number) << 8 | (trailer[3] as number)) >>> 0
    if (expected !== this.checksum) throw new Error('invalid zlib checksum')
    this.consumed = consumed
    this.done = true
    return true
  }

  /** True once {@link push} has seen the end of the stream. */
  get ended(): boolean {
    return this.done
  }

  /** Return the decoded bytes and the exact zlib stream length. */
  finish(): InflatedStream {
    if (!this.done) throw new Error('truncated zlib stream')
    if (this.chunks.length === 1) return { data: this.chunks[0] as Uint8Array, consumed: this.consumed }
    let length = 0
    for (const chunk of this.chunks) length += chunk.byteLength
    const data = new Uint8Array(length)
    let offset = 0
    for (const chunk of this.chunks) {
      data.set(chunk, offset)
      offset += chunk.byteLength
    }
    return { data, consumed: this.consumed }
  }
}

/** Input slice fed to the streaming decoder at a time. */
const INFLATE_PUSH_BYTES = 64 * 1024

/**
 * Decode one complete zlib stream that starts at byte 0 of `input`.
 *
 * Unlike {@link inflate}, this reports how many bytes the stream used, which
 * is what a pack reader needs to find the next object without binary-search
 * retries. Trailing bytes are allowed.
 */
export function inflateWithConsumed(input: Uint8Array): InflatedStream {
  if (input.byteLength === 0) throw new Error('truncated zlib stream')
  const stream = new ZlibInflateStream()
  // Push bounded slices, not the whole remaining pack: after a push the
  // streaming decoder copies its unconsumed tail, and a 64 MiB tail per object
  // would make a large pack quadratic in time and allocation churn.
  for (let offset = 0; offset < input.byteLength; offset += INFLATE_PUSH_BYTES) {
    const end = Math.min(offset + INFLATE_PUSH_BYTES, input.byteLength)
    if (stream.push(input.subarray(offset, end))) break
  }
  return stream.finish()
}

/**
 * CRC-32 table for the reflected IEEE 802.3 polynomial `0xedb88320`.
 *
 * Built once; the pack index stores this checksum per object, and git's own
 * `pack-objects` writes the same values.
 */
const CRC32_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let index = 0; index < 256; index += 1) {
    let value = index
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) === 0 ? value >>> 1 : (0xedb88320 ^ (value >>> 1)) >>> 0
    }
    table[index] = value >>> 0
  }
  return table
})()

/**
 * CRC-32 of a byte range.
 * @param data - bytes to checksum.
 * @param previous - CRC of the preceding chunk, for incremental callers.
 * @returns the unsigned 32-bit checksum.
 */
export function crc32(data: Uint8Array, previous = 0): number {
  let crc = (previous ^ 0xffffffff) >>> 0
  for (const byte of data) {
    crc = ((CRC32_TABLE[(crc ^ byte) & 0xff] as number) ^ (crc >>> 8)) >>> 0
  }
  return (crc ^ 0xffffffff) >>> 0
}
