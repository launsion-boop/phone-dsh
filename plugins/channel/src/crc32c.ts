// SPDX-License-Identifier: MIT
/**
 * CRC32C (Castagnoli): reflected polynomial 0x82F63B78, initial and final value
 * 0xFFFFFFFF. Table-driven; the known answer for "123456789" is 0xE3069283.
 * @module @phone-dsh/dsh-channel/crc32c
 */

const TABLE = ((): Uint32Array => {
  const table = new Uint32Array(256)
  for (let index = 0; index < 256; index++) {
    let value = index
    for (let bit = 0; bit < 8; bit++) {
      value = (value & 1) === 1 ? (value >>> 1) ^ 0x82f63b78 : value >>> 1
    }
    table[index] = value >>> 0
  }
  return table
})()

/** Incremental CRC32C state. */
export class Crc32c {
  private state = 0xffffffff

  /** Feed one byte array. */
  update(bytes: Uint8Array): this {
    let state = this.state
    for (const byte of bytes) {
      state = TABLE[(state ^ byte) & 0xff]! ^ (state >>> 8)
    }
    this.state = state
    return this
  }

  /** Final CRC as an unsigned 32-bit number. */
  digest(): number {
    return (this.state ^ 0xffffffff) >>> 0
  }
}

/** One-shot CRC32C. */
export function crc32c(bytes: Uint8Array): number {
  return new Crc32c().update(bytes).digest()
}
