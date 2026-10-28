// SPDX-License-Identifier: MIT
/**
 * `od`: a window-sized octal/hex/character dump for the Worker shell.
 *
 * just-bash's built-in `od` parses `-N` but never applies it: it reads every
 * operand into one buffer and formats the whole file. Its format work is
 * charged up front (`bytes * formats`), so a legal `od -An -tx1 -N4 big` over a
 * 17 MiB file dies with `od: format work limit exceeded` (exit 126) even though
 * the requested output is 15 bytes. The same class covers `-j`/`--skip`, which
 * the built-in does not implement at all.
 *
 * This command shadows that built-in through the same custom-command seam as
 * `find`, `stat` and `cmp`, but it bounds the work at the window:
 *
 * - `-N`/`--read-bytes` limits how many bytes reach the formatter;
 * - `-j`/`--skip-bytes` skips whole operands through `stat` (never reading
 *   them) and cuts the overlapping operand before formatting; GNU's
 *   unambiguous long-option prefixes are accepted, so `--skip` and
 *   `--skip=4` mean `--skip-bytes`;
 * - operands are concatenated in command-line order, and `-` (or no operand)
 *   is standard input;
 * - the supported output formats are `-t x1`, `-t o1`, `-t c` and the `-c`
 *   alias, with `-A`/`-An` address radices `d`, `o`, `x` and `n`; `-v` keeps
 *   repeated blocks instead of the default `*` collapse;
 * - any other format is a usage boundary (exit 2), never a silent whole-file
 *   dump. Unsupported options behave the same way.
 *
 * The returned bytes are text (ASCII), and the formatter sees only the window,
 * so format work is proportional to what the command can emit. A final
 * `boundOutput` pass still owns the user-visible per-stream cap.
 *
 * Reading is windowed at the filesystem boundary when the backend supports it:
 * `VfsFileSystem.readFileBufferRange` reads only `[start, start + length)` and
 * never materialises the rest of the file. The pinned Worker runtime's
 * `node:fs` bridge may have only whole-file reads; for that backend a file
 * larger than {@link OD_MAX_UNRANGED_READ_BYTES} is refused with
 * `reason=limit-refused` before any read, while a smaller one is read whole
 * and cut immediately (a real, documented bound rather than an unbounded
 * fallback). Files wholly before or after the window are sized with `stat`
 * and never read.
 * @module @phone-dsh/dsh-shell-ext/od
 */

import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, IFileSystem } from 'just-bash/browser'
import { byteStringToBytes, concatBytes } from './encoding.ts'
import { shellFailure } from './contract.ts'

/** Byte width of one display row (GNU od's default). */
const BLOCK_BYTES = 16

/**
 * Largest file a backend without ranged reads may materialise.
 *
 * The adapter exposes {@link IFileSystem} whole-file reads only when its
 * `node:fs` face cannot seek. Keeping that fallback at 1 MiB makes
 * `od -N4` on a large file an explicit `limit-refused` instead of silently
 * reading megabytes the caller never asked for. Real ranged reads have no such
 * limit beyond the adapter's per-read ceiling.
 */
export const OD_MAX_UNRANGED_READ_BYTES = 1024 * 1024

/** One field format this Worker `od` can render. */
export type OdFormat = 'x1' | 'o1' | 'c'

/** Address radix: decimal, octal, hexadecimal, or no address column. */
export type OdAddressRadix = 'd' | 'o' | 'x' | 'n'

/** One parsed `od` invocation. */
export interface OdArguments {
  /** Address radix, or `n` to omit addresses. */
  readonly addressRadix: OdAddressRadix
  /** Requested formats in command-line order (default `o1`). */
  readonly formats: readonly OdFormat[]
  /** Bytes to skip across the concatenated input. */
  readonly skip: number
  /** Bytes to read after the skip, or undefined for the rest of the input. */
  readonly readBytes: number | undefined
  /** Keep repeated blocks instead of collapsing them to `*`. */
  readonly verbose: boolean
  /** File operands; `-` means standard input. */
  readonly operands: readonly string[]
}

/** An option or format outside the implemented `od` surface. */
export class OdUsageError extends Error {
  /**
   * @param message - diagnostic body without the `od: ` prefix.
   */
  constructor(message: string) {
    super(message)
    this.name = 'OdUsageError'
  }
}

/** The supported output format spellings. */
const FORMATS: ReadonlySet<string> = new Set(['x1', 'o1', 'c'])

/** The address radix spellings `-A` accepts. */
const RADICES: ReadonlySet<string> = new Set(['d', 'o', 'x', 'n'])

/** The long options this shim implements, in canonical spelling. */
const LONG_OPTIONS = [
  '--read-bytes',
  '--skip-bytes',
  '--address-radix',
  '--format',
  '--output-duplicates',
] as const

/** One canonical long option name. */
type OdLongOption = (typeof LONG_OPTIONS)[number]

/** Multipliers GNU od accepts after a byte count. */
const BYTE_SUFFIXES: Readonly<Record<string, number>> = Object.freeze({
  b: 512,
  k: 1024,
  K: 1024,
  m: 1024 ** 2,
  M: 1024 ** 2,
  g: 1024 ** 3,
  G: 1024 ** 3,
  t: 1024 ** 4,
  T: 1024 ** 4,
  p: 1024 ** 5,
  P: 1024 ** 5,
  e: 1024 ** 6,
  E: 1024 ** 6,
})

/**
 * Parse one non-negative byte count (`-N`, `-j`).
 *
 * Decimal, `0x` hexadecimal and leading-zero octal are accepted, as is one GNU
 * multiplier suffix (`b`, `k`/`K`, `m`/`M`, ...). A negative, empty or
 * out-of-range value is a usage error.
 * @param raw - the option's value text.
 * @param option - option name for the diagnostic.
 * @returns the byte count.
 * @throws {OdUsageError} when the text is not a byte count.
 */
export function parseOdByteCount(raw: string, option: string): number {
  const match = /^(0[xX][0-9a-fA-F]+|[0-9]+)([bBkKmMgGtTpPeE]?)$/u.exec(raw)
  if (match === null) throw new OdUsageError(`invalid byte count '${raw}' for ${option}`)
  const digits = match[1] as string
  const base = /^0[xX]/u.test(digits)
    ? 16
    : digits.length > 1 && digits.startsWith('0') && /^[0-7]+$/u.test(digits) ? 8 : 10
  const value = Number.parseInt(digits, base)
  const multiplier = match[2] === '' ? 1 : BYTE_SUFFIXES[match[2] as string] as number
  const total = value * multiplier
  if (!Number.isSafeInteger(total)) throw new OdUsageError(`byte count '${raw}' for ${option} is out of range`)
  return total
}

/**
 * Resolve one long option using GNU's unambiguous-prefix rule.
 *
 * `--skip` is not a separate option: it is the unique prefix of
 * `--skip-bytes`, so GNU (and this shim) accept it. An exact spelling wins;
 * a prefix shared by two implemented options is ambiguous and fails loud.
 * @param name - the long option spelling before any `=` value.
 * @returns the canonical option, or undefined when nothing matches.
 * @throws {OdUsageError} when the prefix is ambiguous.
 */
function resolveLongOption(name: string): OdLongOption | undefined {
  if (name.length <= 2) return undefined
  const matches = LONG_OPTIONS.filter(option => option.startsWith(name))
  if (matches.length === 0) return undefined
  if (matches.length > 1) {
    const possibilities = matches.map(option => `'${option}'`).join(' ')
    throw new OdUsageError(`option '${name}' is ambiguous; possibilities: ${possibilities}`)
  }
  return matches[0] as OdLongOption
}

/** Parse one `-A`/`--address-radix` value. */
function parseAddressRadix(raw: string): OdAddressRadix {
  if (RADICES.has(raw)) return raw as OdAddressRadix
  throw new OdUsageError(`invalid address radix '${raw}'; valid radices are 'doxn'`)
}

/** Add one `-t`/`--format` value, refusing a format this shim cannot render. */
function addFormat(formats: OdFormat[], raw: string): void {
  if (!FORMATS.has(raw)) {
    throw new OdUsageError(`unsupported output format '${raw}'; this Worker od supports x1, o1 and c`)
  }
  formats.push(raw as OdFormat)
}

/** Read one option value that may be attached (`-N4`) or separate (`-N 4`). */
function optionValue(attached: string, argv: readonly string[], index: number, option: string): { value: string; next: number } {
  if (attached !== '') return { value: attached, next: index }
  const value = argv[index]
  if (value === undefined) throw new OdUsageError(`option ${option} requires an argument`)
  return { value, next: index + 1 }
}

/**
 * Parse `od`'s option surface.
 *
 * Only the options listed in the module documentation are accepted; everything
 * else is a usage error so a caller cannot believe an unimplemented format was
 * honored. Long options accept any unambiguous prefix of their canonical
 * spelling, matching GNU (`--skip` resolves to `--skip-bytes`).
 * @param argv - arguments after the program name.
 * @returns the parsed invocation.
 * @throws {OdUsageError} for an unsupported option or format.
 */
export function parseOdArguments(argv: readonly string[]): OdArguments {
  let addressRadix: OdAddressRadix = 'o'
  const formats: OdFormat[] = []
  let skip = 0
  let readBytes: number | undefined
  let verbose = false
  const operands: string[] = []
  let options = true
  let index = 0
  while (index < argv.length) {
    const argument = argv[index] as string
    index += 1
    if (!options || argument === '-' || !argument.startsWith('-')) {
      operands.push(argument)
      continue
    }
    if (argument === '--') {
      options = false
      continue
    }
    if (argument.startsWith('--')) {
      const separator = argument.indexOf('=')
      const name = separator === -1 ? argument : argument.slice(0, separator)
      const attached = separator === -1 ? '' : argument.slice(separator + 1)
      const resolved = resolveLongOption(name)
      if (resolved === '--read-bytes' || resolved === '--skip-bytes' || resolved === '--address-radix' || resolved === '--format') {
        const taken = optionValue(attached, argv, index, resolved)
        index = taken.next
        if (resolved === '--read-bytes') readBytes = parseOdByteCount(taken.value, '-N')
        else if (resolved === '--skip-bytes') skip = parseOdByteCount(taken.value, '-j')
        else if (resolved === '--address-radix') addressRadix = parseAddressRadix(taken.value)
        else addFormat(formats, taken.value)
        continue
      }
      if (resolved === '--output-duplicates' && attached === '') {
        verbose = true
        continue
      }
      throw new OdUsageError(`unrecognized option '${argument}'`)
    }
    const body = argument.slice(1)
    for (let position = 0; position < body.length; position += 1) {
      const flag = body[position] as string
      if (flag === 'c') {
        addFormat(formats, 'c')
        continue
      }
      if (flag === 'v') {
        verbose = true
        continue
      }
      if (flag === 'A' || flag === 't' || flag === 'N' || flag === 'j') {
        const taken = optionValue(body.slice(position + 1), argv, index, `-${flag}`)
        index = taken.next
        if (flag === 'A') addressRadix = parseAddressRadix(taken.value)
        else if (flag === 't') addFormat(formats, taken.value)
        else if (flag === 'N') readBytes = parseOdByteCount(taken.value, '-N')
        else skip = parseOdByteCount(taken.value, '-j')
        position = body.length
        continue
      }
      throw new OdUsageError(`invalid option -- '${flag}'`)
    }
  }
  if (formats.length === 0) formats.push('o1')
  return { addressRadix, formats, skip, readBytes, verbose, operands }
}

/** One input participating in the concatenated stream. */
interface OdSource {
  readonly operand: string
  readonly size: number
  readonly stdin: boolean
  readonly path?: string
}

/** Errors from `<operand>: ...` for a stat/read failure. */
const ERRNO_TEXT: Readonly<Record<string, string>> = Object.freeze({
  EACCES: 'Permission denied',
  EISDIR: 'Is a directory',
  ELOOP: 'Too many levels of symbolic links',
  ENAMETOOLONG: 'File name too long',
  ENOENT: 'No such file or directory',
  ENOTDIR: 'Not a directory',
})

/** Render the strerror-shaped tail of one failed operand operation. */
function describeOpenError(error: unknown): string {
  const coded = error as { code?: unknown; message?: unknown } | null
  const code = typeof coded?.code === 'string' && coded.code !== '' ? coded.code : undefined
  if (code !== undefined && ERRNO_TEXT[code] !== undefined) return ERRNO_TEXT[code] as string
  const message = typeof coded?.message === 'string' && coded.message !== '' ? coded.message : String(error)
  return message
}

/** Size every operand without reading file bodies. */
async function collectSources(
  fs: IFileSystem,
  cwd: string,
  operands: readonly string[],
  stdinBytes: Uint8Array,
): Promise<OdSource[]> {
  const sources: OdSource[] = []
  for (const operand of operands) {
    if (operand === '-') {
      sources.push({ operand, size: stdinBytes.byteLength, stdin: true })
      continue
    }
    const path = fs.resolvePath(cwd, operand)
    let size: number
    try {
      const stat = await fs.stat(path)
      if (stat.isDirectory) throw Object.assign(new Error('Is a directory'), { code: 'EISDIR' })
      size = stat.size
    } catch (error) {
      throw new OdInputError(`od: ${operand}: ${describeOpenError(error)}`)
    }
    sources.push({ operand, size, stdin: false, path })
  }
  return sources
}

/** A read of one operand failed after its size was known. */
class OdInputError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'OdInputError'
  }
}

/** A read that this backend cannot serve without materialising too much. */
class OdLimitError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'OdLimitError'
  }
}

/** Filesystem surfaces that can read only the requested window. */
interface RangedReadFileSystem {
  readFileBufferRange?(path: string, start: number, length: number): Promise<Uint8Array>
  readonly supportsRangedReads?: boolean
}

/** True when a backend failure is its own read-budget refusal. */
function isReadLimitError(error: unknown): boolean {
  return (error as { code?: unknown } | null)?.code === 'EFBIG'
}

/** Read one source's bytes, or only the clipped part the formatter needs. */
async function readWindow(
  fs: IFileSystem,
  source: OdSource,
  stdinBytes: Uint8Array,
  start: number,
  length: number,
): Promise<Uint8Array> {
  if (source.stdin) return stdinBytes.subarray(start, start + length)
  const ranged = fs as IFileSystem & RangedReadFileSystem
  const rangeRead = ranged.readFileBufferRange
  const canRange = typeof rangeRead === 'function' && ranged.supportsRangedReads !== false
  try {
    if (canRange) {
      const bytes = await rangeRead.call(ranged, source.path as string, start, length)
      return bytes.subarray(0, length)
    }
    if (source.size > OD_MAX_UNRANGED_READ_BYTES) {
      throw new OdLimitError(
        `od: ${source.operand}: ${String(source.size)} bytes exceeds the `
          + `${String(OD_MAX_UNRANGED_READ_BYTES)}-byte unranged read limit; `
          + 'this filesystem has no ranged read',
      )
    }
    const bytes = await fs.readFileBuffer(source.path as string)
    return bytes.subarray(start, start + length)
  } catch (error) {
    if (error instanceof OdLimitError) throw error
    if (isReadLimitError(error)) {
      throw new OdLimitError(`od: ${source.operand}: ${describeOpenError(error)}`)
    }
    throw new OdInputError(`od: ${source.operand}: ${describeOpenError(error)}`)
  }
}

/** Format one byte as an `x1`, `o1` or `c` field of the requested width. */
function formatByte(format: OdFormat, byte: number, fieldWidth: number): string {
  if (format === 'x1') return `${' '.repeat(fieldWidth - 2)}${byte.toString(16).padStart(2, '0')}`
  if (format === 'o1') return `${' '.repeat(fieldWidth - 3)}${byte.toString(8).padStart(3, '0')}`
  switch (byte) {
    case 0: return '  \\0'
    case 7: return '  \\a'
    case 8: return '  \\b'
    case 9: return '  \\t'
    case 10: return '  \\n'
    case 11: return '  \\v'
    case 12: return '  \\f'
    case 13: return '  \\r'
    default:
      return byte >= 32 && byte < 127
        ? `   ${String.fromCharCode(byte)}`
        : ` ${byte.toString(8).padStart(3, '0')}`
  }
}

/** Render one address in its radix, zero-padded like GNU od. */
function formatAddress(offset: number, radix: OdAddressRadix): string {
  if (radix === 'd') return String(offset).padStart(7, '0')
  if (radix === 'x') return offset.toString(16).padStart(6, '0')
  return offset.toString(8).padStart(7, '0')
}

/** True when two rows carry the same bytes. */
function sameBlock(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false
  for (let index = 0; index < left.byteLength; index += 1) {
    if ((left[index] as number) !== (right[index] as number)) return false
  }
  return true
}

/**
 * Render the clipped window.
 * @param data - bytes selected by `-j`/`-N`.
 * @param options - parsed format options.
 * @param baseOffset - offset of `data[0]` in the concatenated input.
 * @returns the stdout text.
 */
export function formatOdWindow(data: Uint8Array, options: OdArguments, baseOffset: number): string {
  // GNU widens x1 fields to the character field's width when -c (or another
  // four-column format) is also requested, so the columns line up.
  const fieldWidth = options.formats.some(format => format !== 'x1') ? 4 : 3
  const addressWidth = options.addressRadix === 'x' ? 6 : 7
  let stdout = ''
  let previous: Uint8Array | undefined
  let starShown = false
  for (let offset = 0; offset < data.byteLength; offset += BLOCK_BYTES) {
    const block = data.subarray(offset, offset + BLOCK_BYTES)
    if (!options.verbose && previous !== undefined && sameBlock(previous, block)) {
      if (!starShown) {
        stdout += '*\n'
        starShown = true
      }
      continue
    }
    starShown = false
    previous = block
    for (let formatIndex = 0; formatIndex < options.formats.length; formatIndex += 1) {
      const format = options.formats[formatIndex] as OdFormat
      const fields = Array.from(block, byte => formatByte(format, byte, fieldWidth)).join('')
      if (options.addressRadix === 'n') stdout += `${fields}\n`
      else if (formatIndex === 0) stdout += `${formatAddress(baseOffset + offset, options.addressRadix)}${fields}\n`
      else stdout += `${' '.repeat(addressWidth)}${fields}\n`
    }
  }
  if (options.addressRadix !== 'n') {
    stdout += `${formatAddress(baseOffset + data.byteLength, options.addressRadix)}\n`
  }
  return stdout
}

/** Build the `od` command that shadows just-bash's unbounded built-in. */
export function createOdCommand(): Command {
  return defineCommand('od', async (args, ctx): Promise<ExecResult> => {
    let parsed: OdArguments
    try {
      parsed = parseOdArguments(args)
    } catch (error) {
      if (error instanceof OdUsageError) return shellFailure('od', `od: ${error.message}`, 'unsupported-option')
      throw error
    }
    const operands = parsed.operands.length === 0 ? ['-'] : [...parsed.operands]
    const stdinBytes = byteStringToBytes(String(ctx.stdin ?? ''))
    try {
      const sources = await collectSources(ctx.fs, ctx.cwd, operands, stdinBytes)
      const total = sources.reduce((sum, source) => sum + source.size, 0)
      if (!Number.isSafeInteger(total)) throw new OdInputError('od: combined input is too large')
      if (parsed.skip > total) {
        throw new OdInputError('od: cannot skip past end of combined input')
      }
      const chunks: Uint8Array[] = []
      let skip = parsed.skip
      let remaining = parsed.readBytes ?? Number.POSITIVE_INFINITY
      for (const source of sources) {
        if (remaining <= 0) break
        if (skip >= source.size) {
          skip -= source.size
          continue
        }
        const length = Math.min(source.size - skip, remaining)
        if (length <= 0) continue
        chunks.push(await readWindow(ctx.fs, source, stdinBytes, skip, length))
        skip = 0
        remaining -= length
      }
      const window = concatBytes(chunks)
      return { stdout: formatOdWindow(window, parsed, parsed.skip), stderr: '', exitCode: 0 }
    } catch (error) {
      if (error instanceof OdLimitError) {
        return shellFailure('od', error.message, 'limit-refused', {
          hint: 'this backend cannot seek; use a smaller file or a filesystem with ranged reads',
        })
      }
      if (error instanceof OdInputError) return shellFailure('od', error.message, 'command-exited')
      throw error
    }
  })
}
