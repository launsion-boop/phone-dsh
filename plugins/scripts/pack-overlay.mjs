#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Pack a workspace directory into the uncompressed POSIX tar the phone host
 * hands to the Worker as its data overlay.
 *
 * Only `home/` and `workspace/` are overlay content: runtime code,
 * configuration, and the lowering manifest stay owned by the base image, so an
 * overlay must not be able to replace them. The archive is deterministic
 * (byte-wise sorted entries, normalized modes, mtime 0) and streamed: file
 * bodies are read one chunk at a time and never held in memory as a whole.
 *
 * Usage:
 *   node scripts/pack-overlay.mjs <dir> --out <file.tar>
 *
 * Symbols and every other filesystem object type are rejected rather than
 * followed or silently skipped.
 * @module @phone-dsh/dsh-plugins/scripts/pack-overlay
 */
import { createReadStream, createWriteStream, lstatSync, readdirSync, realpathSync } from 'node:fs'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { fileURLToPath } from 'node:url'

/** Tar block size in bytes. */
export const TAR_BLOCK = 512

/** Top-level directories an overlay may carry. */
export const OVERLAY_ROOTS = Object.freeze(['home', 'workspace'])

/** One planned archive entry. */
/**
 * @typedef {object} OverlayEntry
 * @property {string} path - archive path, directory entries end with `/`.
 * @property {'file' | 'directory'} kind - object type.
 * @property {string} source - absolute source path.
 * @property {number} size - file size or 0.
 */

/**
 * Normalized tar numeric field.
 * @param value - non-negative integer.
 * @param width - field width in bytes.
 * @returns NUL-terminated octal digits.
 */
function octal(value, width) {
  return `${value.toString(8).padStart(width - 1, '0')}\0`
}

/**
 * Split an archive path into the ustar name/prefix pair.
 * @param path - archive path.
 * @returns The header name and prefix fields.
 * @throws {Error} When no split fits ustar's 100/155-byte fields.
 */
function splitName(path) {
  if (Buffer.byteLength(path, 'utf8') <= 100) return { name: path, prefix: '' }
  for (let at = path.lastIndexOf('/'); at > 0; at = path.lastIndexOf('/', at - 1)) {
    const prefix = path.slice(0, at)
    const name = path.slice(at + 1)
    if (Buffer.byteLength(prefix, 'utf8') <= 155 && Buffer.byteLength(name, 'utf8') <= 100) {
      return { name, prefix }
    }
  }
  throw new Error(`overlay path does not fit the ustar header fields: ${path}`)
}

/**
 * Build one ustar header block.
 * @param entry - planned entry.
 * @returns A 512-byte header.
 */
export function tarHeader(entry) {
  const isDirectory = entry.kind === 'directory'
  const archivePath = isDirectory ? entry.path.replace(/\/?$/, '/') : entry.path
  const { name, prefix } = splitName(archivePath)
  const header = Buffer.alloc(TAR_BLOCK)
  header.write(name, 0, 100, 'utf8')
  header.write(octal(isDirectory ? 0o755 : 0o644, 8), 100, 8, 'ascii')
  header.write(octal(0, 8), 108, 8, 'ascii')
  header.write(octal(0, 8), 116, 8, 'ascii')
  header.write(octal(isDirectory ? 0 : entry.size, 12), 124, 12, 'ascii')
  header.write(octal(0, 12), 136, 12, 'ascii')
  header.fill(0x20, 148, 156)
  header.write(isDirectory ? '5' : '0', 156, 1, 'ascii')
  header.write('ustar\0', 257, 6, 'ascii')
  header.write('00', 263, 2, 'ascii')
  header.write(prefix, 345, 155, 'utf8')
  let checksum = 0
  for (const byte of header) checksum += byte
  const checksumField = checksum.toString(8).padStart(6, '0')
  header.write(`${checksumField}\0 `, 148, 8, 'ascii')
  return header
}

/**
 * List the archive entries under one overlay directory.
 * @param directory - existing overlay directory.
 * @returns Entries in deterministic byte-wise path order.
 * @throws {Error} On an unknown top-level root, a symlink, or a special file.
 */
export function listOverlay(directory) {
  const top = readdirSync(directory, { withFileTypes: true })
  for (const entry of top) {
    if (entry.isSymbolicLink()) throw new Error(`overlay: refusing symlink ${entry.name}`)
    if (!OVERLAY_ROOTS.includes(entry.name)) {
      throw new Error(
        `overlay: refusing root ${JSON.stringify(entry.name)}; only ${OVERLAY_ROOTS.join(', ')} may be packed`,
      )
    }
    if (!entry.isDirectory()) throw new Error(`overlay: ${entry.name} must be a directory`)
  }
  if (top.length === 0) throw new Error(`overlay: ${directory} contains neither home/ nor workspace/`)

  /** @type {OverlayEntry[]} */
  const entries = []
  const walk = (absolute, relative) => {
    const children = readdirSync(absolute, { withFileTypes: true })
      .sort((left, right) => Buffer.compare(Buffer.from(left.name), Buffer.from(right.name)))
    for (const child of children) {
      const childAbsolute = resolve(absolute, child.name)
      const childRelative = `${relative}/${child.name}`
      if (child.isSymbolicLink()) throw new Error(`overlay: refusing symlink ${childRelative}`)
      if (child.isDirectory()) {
        entries.push({ path: childRelative, kind: 'directory', source: childAbsolute, size: 0 })
        walk(childAbsolute, childRelative)
        continue
      }
      if (child.isFile()) {
        const { size } = statFile(childAbsolute)
        entries.push({ path: childRelative, kind: 'file', source: childAbsolute, size })
        continue
      }
      throw new Error(`overlay: refusing special file ${childRelative}`)
    }
  }
  for (const entry of top) {
    entries.push({ path: entry.name, kind: 'directory', source: resolve(directory, entry.name), size: 0 })
    walk(resolve(directory, entry.name), entry.name)
  }
  entries.sort((left, right) => Buffer.compare(Buffer.from(left.path), Buffer.from(right.path)))
  return entries
}

/**
 * Stat a regular file without following a link (the caller already rejected
 * symbolic entries; this guards a replacement race at the same path).
 * @param file - absolute path.
 * @returns Its size.
 */
function statFile(file) {
  const stats = lstatSync(file)
  if (!stats.isFile()) throw new Error(`overlay: refusing non-regular file ${file}`)
  return { size: stats.size }
}

/**
 * Write one overlay archive.
 * @param directory - directory holding `home/` and/or `workspace/`.
 * @param output - tar file to write (replaced).
 * @returns Entry count and archive size.
 * @throws {Error} On an invalid tree or write failure.
 */
export async function packOverlay(directory, output) {
  const entries = listOverlay(resolve(directory))
  const target = resolve(output)
  let bytes = 0
  const chunks = async function* () {
    for (const entry of entries) {
      const header = tarHeader(entry)
      bytes += header.byteLength
      yield header
      if (entry.kind === 'file') {
        for await (const chunk of createReadStream(entry.source)) {
          bytes += chunk.byteLength
          yield chunk
        }
        const padding = (TAR_BLOCK - (entry.size % TAR_BLOCK)) % TAR_BLOCK
        if (padding > 0) {
          const tail = Buffer.alloc(padding)
          bytes += tail.byteLength
          yield tail
        }
      }
    }
    const end = Buffer.alloc(TAR_BLOCK * 2)
    bytes += end.byteLength
    yield end
  }
  await pipeline(Readable.from(chunks()), createWriteStream(target))
  return { entries: entries.length, bytes }
}

/** Whether this file is the process entry point. */
function invokedByCli() {
  const entry = process.argv[1]
  if (entry === undefined) return false
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(resolve(entry))
  } catch {
    return false
  }
}

async function main() {
  let parsed
  try {
    parsed = parseArgs({
      allowPositionals: true,
      options: { out: { type: 'string' } },
    })
  } catch (reason) {
    process.stderr.write(`pack-overlay: ${reason instanceof Error ? reason.message : String(reason)}\n`)
    process.exitCode = 2
    return
  }
  const { values, positionals } = parsed
  if (positionals.length !== 1 || typeof values.out !== 'string' || values.out === '') {
    process.stderr.write('usage: node scripts/pack-overlay.mjs <dir> --out <file.tar>\n')
    process.exitCode = 2
    return
  }
  try {
    const result = await packOverlay(positionals[0], values.out)
    process.stdout.write(`pack-overlay: ${result.entries} entries, ${result.bytes} bytes -> ${resolve(values.out)}\n`)
  } catch (reason) {
    process.stderr.write(`pack-overlay: ${reason instanceof Error ? reason.message : String(reason)}\n`)
    process.exitCode = 1
  }
}

if (invokedByCli()) await main()
