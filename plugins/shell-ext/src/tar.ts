// SPDX-License-Identifier: MIT
/**
 * `tar` for the Worker shell: create, list and extract on the VFS.
 *
 * `tar` is not in just-bash's browser bundle — the name resolves to
 * `bash: tar: command not available in browser environments` with exit 127.
 * G2-A05's backup script (`tar -czf notes-backup.tar.gz notes/`, then
 * `tar -tzf ... | wc -l`) therefore never ran, and the scenario spent its
 * budget discovering that the documented backup tool did not exist.
 *
 * This module implements the POSIX.1-1988 `ustar` interchange format over the
 * same `IFileSystem` the rest of the shell uses. `-z` does not carry a second
 * gzip implementation: it uses the portable backend from `gzip.ts` (Web
 * Compression Streams first, a real `node:zlib` second, fail loud when neither
 * works), so `tar -czf` and `gzip` cannot disagree about what a member is.
 *
 * Supported surface: `-c/-t/-x`, `-z`, `-f ARCHIVE` (including `-`), `-C DIR`
 * (ordered for create, target for extract), `-v`, `-p`, GNU long options for
 * the same set, and `--help`/`--version`. GNU long-name (`L`) and pax (`x`)
 * records are understood when reading an archive another tool produced. An
 * option outside that surface fails loud (exit 2) instead of being ignored.
 *
 * Archive names are stored the way GNU tar stores them: a leading `/` is
 * stripped and a directory operand keeps its relative spelling (`notes/`,
 * `notes/recipe-matcha.md`). Extraction refuses absolute names and any `..`
 * component — the VFS has no business letting an archive escape its target.
 * @module @phone-dsh/dsh-shell-ext/tar
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, IFileSystem, ResolvedCommandContext } from 'just-bash/browser'
import { shellFailure, type ShellReason, withCommandExit } from './contract.ts'
import { byteStringToBytes, bytesToByteString } from './encoding.ts'
import { GzipBackendUnavailableError, resolveGzipBackend } from './gzip.ts'
import type { GzipBackendOptions } from './gzip.ts'

/** `ustar` block size. */
const BLOCK = 512

/** One parsed `tar` entry. */
interface TarEntry {
  readonly name: string
  readonly mode: number
  readonly size: number
  readonly mtime: number
  /** POSIX typeflag: `0` file, `5` directory, `2` symlink, `1` hard link. */
  readonly type: string
  readonly linkname: string
}

/** One item of the ordered command line. */
type TarAction =
  | { readonly kind: 'operand'; readonly value: string }
  | { readonly kind: 'chdir'; readonly value: string }

/** Parsed `tar` argv. */
interface TarArguments {
  readonly operation: 'create' | 'list' | 'extract' | undefined
  readonly gzip: boolean
  readonly archive: string | undefined
  readonly verbose: boolean
  readonly preservePermissions: boolean
  readonly actions: readonly TarAction[]
  readonly help: boolean
  readonly version: boolean
}

/** A fatal `tar` command-line or archive error. */
export class TarError extends Error {
  /** GNU exit status: 2 for a fatal error, 1 for a difference. */
  readonly exitCode: number

  /**
   * @param message - diagnostic body (without the `tar: ` prefix).
   * @param exitCode - process status.
   */
  constructor(message: string, exitCode = 2) {
    super(message)
    this.name = 'TarError'
    this.exitCode = exitCode
  }
}

/** The option letters a traditional first word (`czf`) may contain. */
const TRADITIONAL_LETTERS = new Set(['c', 't', 'x', 'z', 'v', 'f', 'C', 'p', 'h', 'P'])

/** Parse the `tar` option surface into one operation. */
export function parseTarArguments(argv: readonly string[]): TarArguments {
  let operation: TarArguments['operation']
  let gzip = false
  let archive: string | undefined
  let verbose = false
  let preservePermissions = false
  let help = false
  let version = false
  const actions: TarAction[] = []

  const setOperation = (next: 'create' | 'list' | 'extract'): void => {
    if (operation !== undefined && operation !== next) {
      throw new TarError("You may not specify more than one '-Acdtrux', '--delete' or '--test-label' option", 2)
    }
    operation = next
  }

  let index = 0
  // Traditional first word: `tar czf archive dir`. It is only a cluster when
  // every letter is a tar option; `notes` is an operand, not an option word.
  const first = argv[0]
  if (first !== undefined && !first.startsWith('-') && first !== '' && [...first].every(letter => TRADITIONAL_LETTERS.has(letter))) {
    const cluster = first
    index = 1
    for (let position = 0; position < cluster.length; position += 1) {
      const letter = cluster[position] as string
      if (letter === 'f') {
        const value = cluster.slice(position + 1) !== '' ? cluster.slice(position + 1) : argv[index]
        if (value === undefined) throw new TarError('option requires an argument -- \'f\'', 2)
        if (cluster.slice(position + 1) === '') index += 1
        archive = value
        position = cluster.length
        continue
      }
      if (letter === 'C') {
        const value = cluster.slice(position + 1) !== '' ? cluster.slice(position + 1) : argv[index]
        if (value === undefined) throw new TarError('option requires an argument -- \'C\'', 2)
        if (cluster.slice(position + 1) === '') index += 1
        actions.push({ kind: 'chdir', value })
        position = cluster.length
        continue
      }
      if (letter === 'c') setOperation('create')
      else if (letter === 't') setOperation('list')
      else if (letter === 'x') setOperation('extract')
      else if (letter === 'z') gzip = true
      else if (letter === 'v') verbose = true
      else if (letter === 'p') preservePermissions = true
    }
  }

  let options = true
  for (; index < argv.length; index += 1) {
    const argument = argv[index] as string
    if (!options || argument === '-' || !argument.startsWith('-')) {
      actions.push({ kind: 'operand', value: argument })
      continue
    }
    if (argument === '--') {
      options = false
      continue
    }
    if (argument === '--help') {
      help = true
      continue
    }
    if (argument === '--version') {
      version = true
      continue
    }
    if (argument.startsWith('--')) {
      const equals = argument.indexOf('=')
      const flag = equals === -1 ? argument : argument.slice(0, equals)
      const inline = equals === -1 ? undefined : argument.slice(equals + 1)
      const valueOf = (): string => {
        const value = inline ?? argv[index + 1]
        if (value === undefined) throw new TarError(`option '${flag}' requires an argument`, 2)
        if (inline === undefined) index += 1
        return value
      }
      if (flag === '--create') setOperation('create')
      else if (flag === '--list') setOperation('list')
      else if (flag === '--extract' || flag === '--get') setOperation('extract')
      else if (flag === '--gzip' || flag === '--gunzip' || flag === '--ungzip') gzip = true
      else if (flag === '--verbose') verbose = true
      else if (flag === '--preserve-permissions' || flag === '--same-permissions') preservePermissions = true
      else if (flag === '--file') archive = valueOf()
      else if (flag === '--directory') actions.push({ kind: 'chdir', value: valueOf() })
      else if (flag === '--no-same-owner' || flag === '--no-same-permissions' || flag === '--overwrite' || flag === '--force-local') {
        // Accepted no-ops: the VFS is single-user and extraction overwrites.
      } else throw new TarError(`unrecognized option '${argument}'`, 2)
      continue
    }
    const cluster = argument.slice(1)
    for (let position = 0; position < cluster.length; position += 1) {
      const letter = cluster[position] as string
      if (letter === 'f' || letter === 'C') {
        const rest = cluster.slice(position + 1)
        const value = rest !== '' ? rest : argv[index + 1]
        if (value === undefined) throw new TarError(`option requires an argument -- '${letter}'`, 2)
        if (rest === '') index += 1
        if (letter === 'f') archive = value
        else actions.push({ kind: 'chdir', value })
        position = cluster.length
        continue
      }
      if (letter === 'c') setOperation('create')
      else if (letter === 't') setOperation('list')
      else if (letter === 'x') setOperation('extract')
      else if (letter === 'z') gzip = true
      else if (letter === 'v') verbose = true
      else if (letter === 'p') preservePermissions = true
      else if (letter === 'j' || letter === 'J') {
        throw new TarError(`compression option '${letter}' is not supported in the Worker shell (only -z)`, 2)
      } else if (letter === 'h' || letter === 'P') {
        // Follow symlinks / absolute names: accepted, the VFS is symlink-free.
      } else throw new TarError(`invalid option -- '${letter}'`, 2)
    }
  }
  return { operation, gzip, archive, verbose, preservePermissions, actions, help, version }
}

/** Usage text for `tar --help`. */
const TAR_HELP = [
  'Usage: tar [OPTION...] [FILE]...',
  'Worker shell tar (POSIX ustar) over the virtual filesystem.',
  '',
  '  -c, --create               create a new archive',
  '  -t, --list                 list the contents of an archive',
  '  -x, --extract, --get       extract files from an archive',
  '  -z, --gzip                 filter the archive through gzip',
  '  -f, --file=ARCHIVE         use archive file or device ARCHIVE',
  '  -C, --directory=DIR        change to directory DIR',
  '  -v, --verbose              verbosely list files processed',
  '  -p, --preserve-permissions extract permissions exactly',
  '      --help                 display this help and exit',
  '      --version              output version information and exit',
  '',
].join('\n')

/** Encode ASCII/UTF-8 text as bytes. */
const ENCODER = new TextEncoder()

/** Decode a byte range as UTF-8 text with NUL trimming. */
function readString(block: Uint8Array, offset: number, length: number): string {
  let end = offset
  const limit = offset + length
  while (end < limit && block[end] !== 0) end += 1
  return new TextDecoder().decode(block.subarray(offset, end))
}

/** Read one octal header field (`0` when blank). */
function readOctal(block: Uint8Array, offset: number, length: number): number {
  const text = readString(block, offset, length).trim()
  if (text === '') return 0
  const value = Number.parseInt(text, 8)
  return Number.isFinite(value) ? value : 0
}

/** Write one NUL-padded octal field. */
function writeOctal(block: Uint8Array, offset: number, length: number, value: number): void {
  const text = value.toString(8).padStart(length - 1, '0').slice(-(length - 1))
  block.set(ENCODER.encode(`${text}\0`), offset)
}

/** Write one NUL-padded string field. */
function writeString(block: Uint8Array, offset: number, length: number, value: string): void {
  const bytes = ENCODER.encode(value)
  block.set(bytes.subarray(0, length), offset)
}

/** Split a name into the ustar `prefix`/`name` fields. */
function splitTarName(name: string): { name: string; prefix: string } {
  if (ENCODER.encode(name).byteLength <= 100) return { name, prefix: '' }
  const parts = name.split('/')
  for (let count = parts.length - 1; count >= 1; count -= 1) {
    const prefix = parts.slice(0, count).join('/')
    const rest = parts.slice(count).join('/')
    if (ENCODER.encode(prefix).byteLength <= 155 && ENCODER.encode(rest).byteLength <= 100 && rest !== '') {
      return { name: rest, prefix }
    }
  }
  throw new TarError(`file name is too long (cannot be split into prefix/name): ${name}`, 2)
}

/** Build one 512-byte ustar header. */
function buildHeader(entry: TarEntry): Uint8Array {
  const header = new Uint8Array(BLOCK)
  const split = splitTarName(entry.name)
  writeString(header, 0, 100, split.name)
  writeOctal(header, 100, 8, entry.mode & 0o7777)
  writeOctal(header, 108, 8, 0)
  writeOctal(header, 116, 8, 0)
  writeOctal(header, 124, 12, entry.size)
  writeOctal(header, 136, 12, Math.max(0, Math.floor(entry.mtime)))
  header.fill(0x20, 148, 156)
  writeString(header, 156, 1, entry.type)
  writeString(header, 157, 100, entry.linkname)
  writeString(header, 257, 6, 'ustar\0')
  writeString(header, 263, 2, '00')
  writeString(header, 265, 32, 'root')
  writeString(header, 297, 32, 'root')
  writeOctal(header, 329, 8, 0)
  writeOctal(header, 337, 8, 0)
  writeString(header, 345, 155, split.prefix)
  let checksum = 0
  for (const byte of header) checksum += byte
  const text = checksum.toString(8).padStart(6, '0').slice(-6)
  header.set(ENCODER.encode(`${text}\0 `), 148)
  return header
}

/** Concatenate byte chunks. */
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

/** Pad a byte array to the next 512-byte boundary. */
function padToBlocks(bytes: Uint8Array): Uint8Array {
  const remainder = bytes.byteLength % BLOCK
  if (remainder === 0) return bytes
  const padded = new Uint8Array(bytes.byteLength + (BLOCK - remainder))
  padded.set(bytes)
  return padded
}

/** A human-readable filesystem failure without a stack or local path. */
function describeFsError(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code
  if (code === 'ENOENT') return 'No such file or directory'
  if (code === 'EISDIR') return 'Is a directory'
  if (code === 'ENOTDIR') return 'Not a directory'
  if (code === 'EACCES' || code === 'EPERM') return 'Permission denied'
  if (code === 'EFBIG') return 'File too large'
  return error instanceof Error ? error.message : String(error)
}

/** Strip a leading `/` and trailing `/` from an archive member name. */
function archiveNameOf(operand: string): string {
  let name = operand.replace(/^\/+/, '')
  // GNU tar removes leading `../` components from member names (with a
  // warning) so an archive never carries an upward path; the same rule keeps
  // the shim's own output extractable by its own safety check.
  while (name.startsWith('../')) name = name.slice(3)
  while (name.length > 1 && name.endsWith('/')) name = name.slice(0, -1)
  if (name === '' || name === '.') return name === '' ? '/' : '.'
  const leadingDot = name.startsWith('./')
  const normalized = posix.normalize(name)
  return leadingDot && !normalized.startsWith('./') && normalized !== '.' ? `./${normalized}` : normalized
}

/** True when a member name is safe to extract below the target root. */
function isSafeMemberName(name: string): boolean {
  if (name.startsWith('/')) return false
  return !name.split('/').includes('..')
}

/** One collected archive member and its bytes (files only). */
interface CollectedEntry {
  readonly entry: TarEntry
  readonly data: Uint8Array | undefined
}

/** Build the ordered entries of one filesystem operand. */
async function collectCreateEntries(
  fs: IFileSystem,
  cwd: string,
  operand: string,
  output: CollectedEntry[],
): Promise<void> {
  const name = archiveNameOf(operand)
  const absolute = posix.resolve(cwd, operand)
  let stat
  try {
    stat = await fs.lstat(absolute)
  } catch (error) {
    throw new TarError(`${operand}: Cannot stat: ${describeFsError(error)}`)
  }
  const mode = stat.mode & 0o7777
  const mtime = Math.floor(stat.mtime.getTime() / 1000)
  if (stat.isDirectory) {
    output.push({ entry: { name: `${name}/`, mode, size: 0, mtime, type: '5', linkname: '' }, data: undefined })
    let children: string[]
    try {
      children = await fs.readdir(absolute)
    } catch (error) {
      throw new TarError(`${operand}: Cannot read directory: ${describeFsError(error)}`)
    }
    for (const child of [...children].sort()) {
      await collectCreateEntries(fs, cwd, `${operand.replace(/\/+$/u, '')}/${child}`, output)
    }
    return
  }
  if (stat.isSymbolicLink) {
    const target = await fs.readlink(absolute)
    output.push({ entry: { name, mode, size: 0, mtime, type: '2', linkname: target }, data: undefined })
    return
  }
  let bytes: Uint8Array
  try {
    bytes = await fs.readFileBuffer(absolute)
  } catch (error) {
    throw new TarError(`${operand}: Cannot open: ${describeFsError(error)}`)
  }
  output.push({
    entry: { name, mode, size: bytes.byteLength, mtime, type: '0', linkname: '' },
    data: bytes,
  })
}

/** Append one entry (header + padded data) to the archive chunks. */
function appendEntry(chunks: Uint8Array[], entry: TarEntry, data: Uint8Array | undefined): void {
  chunks.push(buildHeader(entry))
  if (data !== undefined && data.byteLength > 0) chunks.push(padToBlocks(data))
}

/** Read and parse an archive into entries with their data. */
export async function readTarArchive(bytes: Uint8Array, options: { readonly gzip: boolean; readonly backend?: GzipBackendOptions } = { gzip: false }): Promise<Array<{ entry: TarEntry; data: Uint8Array }>> {
  let raw = bytes
  // GNU tar detects compression from the member header even without -z.
  const isGzip = raw.byteLength >= 2 && raw[0] === 0x1f && raw[1] === 0x8b
  if (options.gzip || isGzip) {
    if (!isGzip) throw new TarError('the archive is not compressed, but -z was given', 2)
    const backend = await resolveGzipBackend(options.backend ?? {})
    raw = await backend.decompress(raw)
  }
  // A short, non-empty input is not a tar archive. Without this check the
  // header loop never ran for an input shorter than one block and `tar -tf`
  // reported an empty listing with exit 0 — the G2-A05 zero-byte-success
  // shape applied to a corrupt archive.
  if (raw.byteLength === 0) throw new TarError('This does not look like a tar archive', 2)
  if (raw.byteLength < BLOCK) throw new TarError('This does not look like a tar archive', 2)
  const entries: Array<{ entry: TarEntry; data: Uint8Array }> = []
  let offset = 0
  let pendingName: string | undefined
  let pendingLink: string | undefined
  let paxPath: string | undefined
  let paxLink: string | undefined
  let zeroBlocks = 0
  while (offset + BLOCK <= raw.byteLength) {
    const header = raw.subarray(offset, offset + BLOCK)
    offset += BLOCK
    const blank = header.every(byte => byte === 0)
    if (blank) {
      zeroBlocks += 1
      if (zeroBlocks >= 2) break
      continue
    }
    zeroBlocks = 0
    const expected = readOctal(header, 148, 8)
    let sum = 0
    for (let index = 0; index < BLOCK; index += 1) sum += index >= 148 && index < 156 ? 0x20 : (header[index] as number)
    if (sum !== expected) throw new TarError('invalid tar header (checksum mismatch)', 2)
    const type = String.fromCharCode(header[156] as number) === '\0' ? '0' : String.fromCharCode(header[156] as number)
    const size = readOctal(header, 124, 12)
    const dataStart = offset
    const dataEnd = Math.min(dataStart + Math.max(0, size), raw.byteLength)
    const data = raw.subarray(dataStart, dataEnd)
    offset = dataStart + Math.ceil(Math.max(0, size) / BLOCK) * BLOCK
    if (type === 'L') {
      pendingName = new TextDecoder().decode(data).replace(/\0+$/u, '')
      continue
    }
    if (type === 'K') {
      pendingLink = new TextDecoder().decode(data).replace(/\0+$/u, '')
      continue
    }
    if (type === 'x' || type === 'g') {
      for (const record of new TextDecoder().decode(data).split('\n')) {
        const equals = record.indexOf('=')
        if (equals === -1) continue
        const key = record.slice(0, equals)
        const value = record.slice(equals + 1).replace(/\n$/u, '')
        if (key === 'path') paxPath = value
        else if (key === 'linkpath') paxLink = value
      }
      continue
    }
    const baseName = readString(header, 0, 100)
    const prefix = readString(header, 345, 155)
    const name = pendingName ?? paxPath ?? (prefix === '' ? baseName : `${prefix}/${baseName}`)
    const linkname = pendingLink ?? paxLink ?? readString(header, 157, 100)
    pendingName = undefined
    pendingLink = undefined
    paxPath = undefined
    paxLink = undefined
    entries.push({
      entry: {
        name,
        mode: readOctal(header, 100, 8),
        size,
        mtime: readOctal(header, 136, 12),
        type,
        linkname,
      },
      data: type === '0' || type === '7' ? data : new Uint8Array(0),
    })
  }
  return entries
}

/** One symbolic-mode string for `tar -tv`. */
function symbolicMode(entry: TarEntry): string {
  const type = entry.type === '5' ? 'd' : entry.type === '2' ? 'l' : '-'
  const bits = entry.mode
  const triple = (shift: number): string => {
    const read = (bits & (4 << shift)) !== 0 ? 'r' : '-'
    const write = (bits & (2 << shift)) !== 0 ? 'w' : '-'
    const execute = (bits & (1 << shift)) !== 0 ? 'x' : '-'
    return `${read}${write}${execute}`
  }
  return `${type}${triple(6)}${triple(3)}${triple(0)}`
}

/** One `tar -tv` listing line (GNU shape). */
function verboseListing(entry: TarEntry): string {
  const date = new Date(entry.mtime * 1000)
  const stamp = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')} ${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
  return `${symbolicMode(entry)} root/root ${String(entry.size).padStart(9)} ${stamp} ${entry.name}\n`
}

/** Apply the ordered `-C` words to the create operands. */
function createGroups(actions: readonly TarAction[], cwd: string): Array<{ directory: string; operands: string[] }> {
  const groups: Array<{ directory: string; operands: string[] }> = []
  let directory = cwd
  let current: string[] = []
  const flush = (): void => {
    if (current.length > 0) groups.push({ directory, operands: current })
    current = []
  }
  for (const action of actions) {
    if (action.kind === 'chdir') {
      flush()
      directory = posix.resolve(directory, action.value)
    } else current.push(action.value)
  }
  flush()
  return groups
}

/** Resolve the archive path for a `-f` value. */
function archivePathOf(cwd: string, archive: string): string {
  return posix.resolve(cwd, archive)
}

/** The extract target directory (last `-C`, or the cwd). */
function extractDirectory(actions: readonly TarAction[], cwd: string): string {
  let directory = cwd
  for (const action of actions) if (action.kind === 'chdir') directory = posix.resolve(directory, action.value)
  return directory
}

/** Create the archive bytes for one command. */
async function createArchive(
  fs: IFileSystem,
  options: TarArguments,
  cwd: string,
): Promise<{ bytes: Uint8Array; names: readonly string[] }> {
  const groups = createGroups(options.actions, cwd)
  const operands = groups.flatMap(group => group.operands)
  if (operands.length === 0) throw new TarError('Cowardly refusing to create an empty archive', 2)
  const entries: CollectedEntry[] = []
  for (const group of groups) {
    for (const operand of group.operands) await collectCreateEntries(fs, group.directory, operand, entries)
  }
  const chunks: Uint8Array[] = []
  for (const { entry, data } of entries) appendEntry(chunks, entry, data)
  chunks.push(new Uint8Array(BLOCK * 2))
  return { bytes: concatBytes(chunks), names: entries.map(({ entry }) => entry.name) }
}

/** List or extract one parsed archive. */
async function readAndApply(
  fs: IFileSystem,
  options: TarArguments,
  cwd: string,
  ctx: ResolvedCommandContext,
): Promise<{ stdout: string; stderr: string; bytes: Uint8Array | undefined; exitCode: number }> {
  if (options.archive === undefined) throw new TarError('no archive specified', 2)
  let raw: Uint8Array
  if (options.archive === '-') raw = byteStringToBytes(String(ctx.stdin ?? ''))
  else {
    try {
      raw = await fs.readFileBuffer(archivePathOf(cwd, options.archive))
    } catch (error) {
      throw new TarError(`${options.archive}: Cannot open: ${describeFsError(error)}`)
    }
  }
  const entries = await readTarArchive(raw, { gzip: options.gzip })
  let stdout = ''
  let stderr = ''
  if (options.operation === 'list') {
    for (const { entry } of entries) {
      stdout += options.verbose ? verboseListing(entry) : `${entry.name}\n`
    }
    return { stdout, stderr, bytes: undefined, exitCode: 0 }
  }
  const target = extractDirectory(options.actions, cwd)
  for (const { entry, data } of entries) {
    if (!isSafeMemberName(entry.name)) {
      stderr += `tar: ${entry.name}: Member name contains '..'\n`
      return { stdout, stderr, bytes: undefined, exitCode: 2 }
    }
    const destination = posix.resolve(target, entry.name)
    if (!destination.startsWith(target === '/' ? '/' : `${target}/`) && destination !== target) {
      stderr += `tar: ${entry.name}: Member name escapes the extraction directory\n`
      return { stdout, stderr, bytes: undefined, exitCode: 2 }
    }
    try {
      if (entry.type === '5') {
        await fs.mkdir(destination, { recursive: true })
        if (options.preservePermissions) await fs.chmod(destination, entry.mode & 0o7777)
      } else if (entry.type === '2') {
        await fs.mkdir(posix.dirname(destination), { recursive: true })
        await fs.symlink(entry.linkname, destination)
      } else if (entry.type === '1') {
        await fs.mkdir(posix.dirname(destination), { recursive: true })
        await fs.link(posix.resolve(target, entry.linkname), destination)
      } else {
        await fs.mkdir(posix.dirname(destination), { recursive: true })
        await fs.writeFile(destination, data)
        await fs.chmod(destination, entry.mode & 0o7777)
      }
      if (options.verbose) stdout += `${entry.name}\n`
    } catch (error) {
      stderr += `tar: ${entry.name}: Cannot extract: ${describeFsError(error)}\n`
      return { stdout, stderr, bytes: undefined, exitCode: 2 }
    }
  }
  return { stdout, stderr, bytes: undefined, exitCode: 0 }
}

/** True when a fatal tar message is a usage/option error, not an I/O failure. */
function isUsageMessage(message: string): boolean {
  return /^(?:unrecognized option|invalid option|option |compression option|You may not specify|You must specify|no archive specified|Cowardly refusing)/u.test(message)
}

/**
 * Build the `tar` command.
 * @param gzip - backend overrides shared with `gzip`/`gunzip`/`zcat`.
 * @returns the command definition.
 */
export function createTarCommand(gzip: GzipBackendOptions = {}): Command {
  return defineCommand('tar', async (args, ctx): Promise<ExecResult> => {
    let options: TarArguments
    try {
      options = parseTarArguments(args)
    } catch (error) {
      const status = error instanceof TarError ? error.exitCode : 2
      return shellFailure('tar', `tar: ${error instanceof Error ? error.message : String(error)}`, 'unsupported-option', {
        exitCode: status,
      })
    }
    if (options.help) return { stdout: TAR_HELP, stderr: '', exitCode: 0 }
    if (options.version) return { stdout: 'tar (Worker shell, POSIX ustar) 1.0\n', stderr: '', exitCode: 0 }
    if (options.operation === undefined) {
      return shellFailure('tar', "tar: You must specify one of the '-Acdtrux', '--delete' or '--test-label' options\n", 'unsupported-option')
    }
    try {
      if (options.operation === 'create') {
        if (options.archive === undefined) throw new TarError('no archive specified', 2)
        const created = await createArchive(ctx.fs, options, ctx.cwd)
        let bytes = created.bytes
        if (options.gzip) {
          const backend = await resolveGzipBackend(gzip)
          bytes = await backend.compress(bytes)
        }
        const listing = options.verbose ? `${created.names.join('\n')}\n` : ''
        if (options.archive === '-') {
          // Verbose output must not corrupt an archive written to stdout.
          return { stdout: bytesToByteString(bytes), stdoutKind: 'bytes', stderr: listing, exitCode: 0 }
        }
        try {
          await ctx.fs.writeFile(archivePathOf(ctx.cwd, options.archive), bytes)
        } catch (error) {
          throw new TarError(`${options.archive}: Cannot write: ${describeFsError(error)}`)
        }
        return { stdout: listing, stderr: '', exitCode: 0 }
      }
      const applied = await readAndApply(ctx.fs, options, ctx.cwd, ctx)
      const result: ExecResult = { stdout: applied.stdout, stderr: applied.stderr, exitCode: applied.exitCode }
      // tar ran and reported its own failure (a corrupt member, a missing
      // input): the status and stderr are the explanation (contract.ts).
      return result.exitCode === 0 ? result : withCommandExit(result, 'tar')
    } catch (error) {
      // A data-path refusal (a filesystem error) is failure 1; only a TarError
      // carries GNU tar's fatal status 2, and only the compression codec
      // missing is our own layer's failure (contract.ts).
      const status = error instanceof TarError ? error.exitCode : 1
      const body = `tar: ${error instanceof Error ? error.message : String(error)}`
      // Only the shared compression codec failing is our layer's own failure;
      // every other throw is tar's own data-path error (contract.ts).
      const reason: ShellReason = error instanceof GzipBackendUnavailableError
        ? 'backend-failed'
        : isUsageMessage(body.slice('tar: '.length)) ? 'unsupported-option' : 'command-exited'
      return shellFailure('tar', body, reason, { exitCode: status })
    }
  })
}
