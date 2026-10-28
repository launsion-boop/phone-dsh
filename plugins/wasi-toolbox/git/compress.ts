// SPDX-License-Identifier: MIT
/**
 * The zlib codec and CRC-32 that git objects and pack files need.
 *
 * `node:zlib` is not usable here: the DSH Worker's `node:zlib` proxy only
 * carries the Zstandard/gzip family (no `deflateSync`/`inflateSync`/`crc32`),
 * and a browser has no `node:zlib` at all. Git stores every loose object and
 * every pack member as a zlib-wrapped DEFLATE stream, so the codec is plain
 * JavaScript: the MIT `fflate` package supplies the DEFLATE engine through its
 * synchronous API, and this module supplies the zlib envelope rules git relies
 * on plus the pack-index CRC-32.
 *
 * `fflate`'s browser entry is imported (not the package root): the root
 * entry probes `node:worker_threads` through `createRequire` (the Worker
 * runtime only stubs that module). The browser entry is the same synchronous
 * codec without the Node-only worker shim, and behaves identically under Node.
 * @module @phone-dsh/dsh-wasi-toolbox/git/compress
 */
import { unzlibSync, zlibSync } from 'fflate/browser'

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
