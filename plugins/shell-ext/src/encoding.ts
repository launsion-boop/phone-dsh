// SPDX-License-Identifier: MIT
/**
 * Byte-string conversions at the shell ↔ WASI boundary.
 *
 * just-bash hands a command's standard input/output as its `ByteString`: one
 * JS character per byte (latin1-shaped), never decoded text. The WASI toolbox
 * speaks `Uint8Array`. Converting at one shared site keeps the stdin path and
 * the stdout/stderr path on the same byte semantics, so non-ASCII heredocs and
 * binary pipelines cannot pick up divergent encodings (the shell-ext half of
 * the G2 stdin/stdout encoding contract). `gzip`, `tar` and the WASI toolbox's
 * `git` program all import this module instead of keeping a private copy.
 *
 * ## One decode, one encode
 *
 * The G2 byte-boundary class (G2-FIX-43) is a byte buffer decoded twice, or
 * decoded as Latin-1 and then re-encoded as UTF-8 (`王` -> `c3 a7 c2 8e c2 8b`).
 * Every conversion at these command boundaries therefore goes through the
 * shared helpers below:
 *
 * - {@link decodeByteString} / {@link decodeUtf8} decode UTF-8 **exactly
 *   once**, only where a JS string is genuinely required (a command result's
 *   text, a stderr line, an accelerator's textual diagnostic). A buffer that
 *   is forwarded (stdin, stdout, a file body, a git blob) stays a `Uint8Array`
 *   or a byte string and is never decoded in transit.
 * - {@link encodeUtf8} encodes JS text exactly once when a byte channel needs
 *   it.
 *
 * There is no Latin-1/binary fallback decode on these paths: a byte sequence
 * that is not valid UTF-8 keeps its bytes where bytes are expected, and a
 * path that needs text replaces the offending sequence once (U+FFFD) instead
 * of silently re-encoding bytes it never decoded.
 * @module @phone-dsh/dsh-shell-ext/encoding
 */

/** The one UTF-8 decoder the Worker's shell and toolbox layers share. */
const UTF8_DECODER = new TextDecoder('utf-8')

/** The one UTF-8 encoder the Worker's shell and toolbox layers share. */
const UTF8_ENCODER = new TextEncoder()

/** Result fields that mark a command's stdout as raw bytes to just-bash. */
export interface ByteStringOutput {
  /** The latin1-shaped byte string. */
  stdout: string
  /** Explicit byte shape: the pipeline forwards these bytes unchanged. */
  stdoutKind: 'bytes'
  /** Legacy alias for `stdoutKind: 'bytes'`; older engine paths read it. */
  stdoutEncoding: 'binary'
}

/**
 * Convert just-bash's latin1-shaped byte string to bytes, one char per byte.
 * @param value - byte string from `ctx.stdin` or a command's `stdout`.
 * @returns a copy as bytes.
 */
export function byteStringToBytes(value: string): Uint8Array {
  const out = new Uint8Array(value.length)
  for (let index = 0; index < value.length; index += 1) out[index] = value.charCodeAt(index) & 0xff
  return out
}

/**
 * Convert bytes to just-bash's latin1-shaped byte string, one byte per char.
 *
 * This is a transport conversion, not a decode: the returned string carries
 * the same bytes, so a caller that forwards it must also mark its result with
 * {@link byteStringOutput} rather than letting the engine treat it as text.
 * @param bytes - guest output chunk.
 * @returns the byte string a command result carries.
 */
export function bytesToByteString(bytes: Uint8Array): string {
  const chunk = 0x8000
  let out = ''
  for (let offset = 0; offset < bytes.byteLength; offset += chunk) {
    out += String.fromCharCode(...bytes.subarray(offset, offset + chunk))
  }
  return out
}

/**
 * Decode bytes as UTF-8 exactly once.
 *
 * Use where a JS string is genuinely required — a command result's text, a
 * diagnostic line, stdout that leaves the shell. Never use it to "normalise"
 * a buffer that is forwarded to another byte consumer.
 * @param bytes - raw bytes.
 * @returns the decoded text (invalid sequences become U+FFFD once).
 */
export function decodeUtf8(bytes: Uint8Array): string {
  return UTF8_DECODER.decode(bytes)
}

/**
 * Decode a just-bash byte string as UTF-8 exactly once.
 * @param value - latin1-shaped byte string.
 * @returns the decoded text.
 */
export function decodeByteString(value: string): string {
  return decodeUtf8(byteStringToBytes(value))
}

/**
 * Encode JS text as UTF-8 exactly once.
 * @param text - decoded Unicode text.
 * @returns UTF-8 bytes.
 */
export function encodeUtf8(text: string): Uint8Array {
  return UTF8_ENCODER.encode(text)
}

/**
 * Build a command result that marks its stdout as raw bytes.
 * @param stdout - the latin1-shaped byte string a byte-producing command emits.
 * @returns the stdout fields just-bash reads to keep the pipeline binary.
 */
export function byteStringOutput(stdout: string): ByteStringOutput {
  return { stdout, stdoutKind: 'bytes', stdoutEncoding: 'binary' }
}

/**
 * Concatenate byte chunks without decoding them.
 * @param chunks - chunks in stream order.
 * @returns one buffer carrying every byte.
 */
export function concatBytes(chunks: readonly Uint8Array[]): Uint8Array {
  let total = 0
  for (const chunk of chunks) total += chunk.byteLength
  const joined = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    joined.set(chunk, offset)
    offset += chunk.byteLength
  }
  return joined
}
