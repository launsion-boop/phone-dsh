// SPDX-License-Identifier: MIT
/**
 * Byte-faithful string writes at the pinned runtime's `node:fs` seam.
 *
 * The runtime's `node:fs` replacement is a bridge over the in-memory VFS: a
 * `writeFile`/`appendFile` call whose data is a string is stored as the UTF-8
 * encoding of that string, and a declared string encoding (`{encoding}` or a
 * bare encoding argument, as Node accepts) is ignored. That is a contract gap
 * against Node, and it silently corrupts every write whose producer supplies
 * Node's byte encodings:
 *
 * - just-bash's redirection writes the captured stdout as its latin1-shaped
 *   `ByteString` with `{encoding: 'binary'}` (`cat > f <<'EOF'`, `tee`,
 *   `cmd > f`); the runtime re-encodes the string as UTF-8, so a two-byte
 *   UTF-8 scalar becomes four bytes (`c3 ad` -> `c3 83 c2 ad`), four-byte
 *   scalars and arbitrary binary bytes are mangled the same way;
 * - the persistence chain (sink -> 0x10 -> WAL -> materialize -> overlay)
 *   faithfully carries the already-corrupted bytes, so the damage only
 *   surfaces after the next read or after a park/resume (G2-B05).
 *
 * The runtime is consumed from the pinned checkout and is never patched, so
 * this module supplies the narrowest shim at our layer: it materializes the
 * declared encoding into bytes before the encoding-ignoring VFS sees the call,
 * and removes the now-consumed encoding from the forwarded options. Only the
 * promise write faces used by the Worker shell are wrapped; UTF-8 writes keep
 * the runtime's own path. Removing the shim restores the original members.
 *
 * Upstream fix (recorded contract gap): the runtime should honor Node's string
 * encodings in `node:fs`/`node:fs/promises` instead of always UTF-8-encoding a
 * string.
 * @module @phone-dsh/dsh-worker-entry/write-encoding
 */

/** Structural shape of the runtime VFS promise faces this shim wraps. */
export interface FsStringWriteFace {
  writeFile(path: unknown, data: unknown, options?: unknown): Promise<unknown>
  appendFile?(path: unknown, data: unknown, options?: unknown): Promise<unknown>
}

/** Node buffer encodings this shim can materialize without `Buffer`. */
const LATIN1_ENCODINGS = new Set(['latin1', 'binary'])
const UTF16_ENCODINGS = new Set(['utf16le', 'utf-16le', 'ucs2', 'ucs-2'])
const UTF8_ENCODINGS = new Set(['utf8', 'utf-8'])
const HEX_DIGITS = '0123456789abcdef'
const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

/**
 * Split a Node write-options argument into the declared encoding and the
 * options the VFS still needs (`flag`, `mode`).
 * @param options - string encoding or an options object.
 * @returns the encoding name, if one was declared, and the forwarded options.
 */
export function splitWriteEncoding(options: unknown): {
  readonly encoding: string | undefined
  readonly forwarded: unknown
} {
  if (typeof options === 'string') return { encoding: options, forwarded: undefined }
  if (options === null || typeof options !== 'object') {
    return { encoding: undefined, forwarded: options }
  }
  const record = options as { encoding?: unknown }
  const encoding = typeof record.encoding === 'string' ? record.encoding : undefined
  if (encoding === undefined) return { encoding: undefined, forwarded: options }
  const { encoding: _consumed, ...forwarded } = options as Record<string, unknown>
  return {
    encoding,
    forwarded: Object.keys(forwarded).length === 0 ? undefined : forwarded,
  }
}

/**
 * Materialize a Node string encoding into the exact bytes it names.
 *
 * Returns `undefined` for UTF-8 (the runtime's own path is already correct) and
 * for encodings this shim does not implement; the caller then leaves the call
 * untouched instead of guessing.
 * @param text - string handed to `writeFile`/`appendFile`.
 * @param encoding - declared Node buffer encoding.
 * @returns the bytes to store, or `undefined` when no conversion is needed.
 */
export function encodeTextForVfs(text: string, encoding: string): Uint8Array | undefined {
  const name = encoding.toLowerCase()
  if (UTF8_ENCODINGS.has(name)) return undefined
  if (LATIN1_ENCODINGS.has(name)) {
    const bytes = new Uint8Array(text.length)
    for (let index = 0; index < text.length; index += 1) bytes[index] = text.charCodeAt(index) & 0xff
    return bytes
  }
  if (name === 'ascii') {
    const bytes = new Uint8Array(text.length)
    for (let index = 0; index < text.length; index += 1) bytes[index] = text.charCodeAt(index) & 0x7f
    return bytes
  }
  if (UTF16_ENCODINGS.has(name)) {
    const bytes = new Uint8Array(text.length * 2)
    for (let index = 0; index < text.length; index += 1) {
      const unit = text.charCodeAt(index)
      bytes[index * 2] = unit & 0xff
      bytes[index * 2 + 1] = (unit >> 8) & 0xff
    }
    return bytes
  }
  if (name === 'hex') return decodeHex(text)
  if (name === 'base64' || name === 'base64url') return decodeBase64(text, name === 'base64url')
  return undefined
}

function hexValue(code: number): number | undefined {
  if (code >= 0x30 && code <= 0x39) return code - 0x30
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10
  return undefined
}

function decodeHex(text: string): Uint8Array | undefined {
  const length = text.length - (text.length % 2)
  const bytes = new Uint8Array(length / 2)
  for (let index = 0; index < length; index += 2) {
    const high = hexValue(text.charCodeAt(index))
    const low = hexValue(text.charCodeAt(index + 1))
    if (high === undefined || low === undefined) return undefined
    bytes[index / 2] = high << 4 | low
  }
  return bytes
}

function decodeBase64(text: string, url: boolean): Uint8Array | undefined {
  const alphabet = url ? BASE64_ALPHABET.replace('+/', '-_') : BASE64_ALPHABET
  let cleaned = ''
  for (const character of text) {
    if (character === '=' || character === '\n' || character === '\r') continue
    if (alphabet.indexOf(character) === -1) return undefined
    cleaned += character
  }
  if (cleaned.length % 4 === 1) return undefined
  const bytes: number[] = []
  let buffer = 0
  let bits = 0
  for (const character of cleaned) {
    buffer = buffer << 6 | alphabet.indexOf(character)
    bits += 6
    if (bits >= 8) {
      bits -= 8
      bytes.push((buffer >> bits) & 0xff)
    }
  }
  return new Uint8Array(bytes)
}

/**
 * Wrap the runtime VFS promise write faces so a declared string encoding is
 * materialized into bytes before the encoding-ignoring VFS sees the write.
 * @param face - the shared `node:fs` promise face of the Worker runtime.
 * @returns a disposer restoring the original members (LIFO with the other
 *   `node:fs` policy installers).
 */
export function installByteFaithfulWrites(face: FsStringWriteFace): () => void {
  const restores: (() => void)[] = []
  for (const name of ['writeFile', 'appendFile'] as const) {
    const original = face[name]
    if (typeof original !== 'function') continue
    const wrapped = async (path: unknown, data: unknown, options?: unknown): Promise<unknown> => {
      if (typeof data !== 'string') return original.call(face, path, data, options)
      const { encoding, forwarded } = splitWriteEncoding(options)
      if (encoding === undefined) return original.call(face, path, data, forwarded)
      const bytes = encodeTextForVfs(data, encoding)
      if (bytes === undefined) return original.call(face, path, data, forwarded)
      return original.call(face, path, bytes, forwarded)
    }
    face[name] = wrapped as never
    restores.push(() => { face[name] = original as never })
  }
  return () => {
    while (restores.length > 0) restores.pop()?.()
  }
}
