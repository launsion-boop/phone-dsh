// SPDX-License-Identifier: MIT
/**
 * `sort -z` / `--zero-terminated`: NUL-delimited record sorting.
 *
 * just-bash 3.6.0's bundled `sort` implements the text-record surface
 * (`-r -n -u -f -b -o -k -t`, ...) but its option parser rejects `-z` with
 * `sort: invalid option -- 'z'`. That makes the canonical binary pipeline
 * `find ... -print0 | sort -z | xargs -0` impossible even though `find` and
 * `xargs` on this command surface already speak the NUL protocol.
 *
 * This module is a shadow over the bundled program:
 *
 * - every invocation without `-z`/`--zero-terminated` is delegated to
 *   `ctx.origCommand` **unchanged**, so the existing option/`-k`/`-t`
 *   behaviour is not re-implemented or narrowed here;
 * - with `-z`, the shim parses the documented Worker surface (`-r`, `-n`,
 *   `-u`, `-f`, `-b`, `-o`, `--` and combined short clusters such as `-rz`),
 *   switches records on the NUL byte, sorts them and writes the result with a
 *   trailing NUL after every record. `-k`/`-t` are refused with exit 2 rather
 *   than silently mis-sorted, because the bundled key grammar is outside the
 *   surface this shim owns;
 * - stdin, file operands, `-` (stdin), missing files, `--` and output files
 *   are handled over the same `IFileSystem` faces the rest of the Worker shell
 *   uses.
 *
 * Records stay latin1-shaped byte strings end to end (`encoding.ts`'s
 * `bytesToByteString` / `byteStringToBytes`), so a NUL byte or a non-ASCII
 * UTF-8 sequence is never re-decoded/re-encoded on its way through the sort.
 * @module @phone-dsh/dsh-shell-ext/sort
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, IFileSystem } from 'just-bash/browser'
import { byteStringToBytes, bytesToByteString, byteStringOutput } from './encoding.ts'

/** One parsed `sort` invocation. */
export interface SortArguments {
  readonly zero: boolean
  readonly reverse: boolean
  readonly numeric: boolean
  readonly unique: boolean
  readonly ignoreCase: boolean
  readonly ignoreBlanks: boolean
  readonly output: string | undefined
  readonly operands: readonly string[]
  /** Options the bundled parser knows but this shim refuses with `-z`. */
  readonly unsupported: readonly string[]
}

/** A `sort` option outside the record-sorting surface. */
export class SortUsageError extends Error {
  /**
   * @param message - diagnostic body without the `sort: ` prefix.
   */
  constructor(message: string) {
    super(message)
    this.name = 'SortUsageError'
  }
}

/**
 * Parse the `sort -z` surface.
 *
 * The parser is deliberately total: it records unsupported options instead of
 * throwing, so an invocation without `-z` can still be delegated to the
 * bundled program byte for byte. Only a `-z` invocation validates the
 * recorded options (see {@link createSortCommand}).
 * @param argv - arguments after the program name.
 * @returns the parsed invocation.
 */
export function parseSortArguments(argv: readonly string[]): SortArguments {
  let options = true
  let zero = false
  let reverse = false
  let numeric = false
  let unique = false
  let ignoreCase = false
  let ignoreBlanks = false
  let output: string | undefined
  const operands: string[] = []
  const unsupported: string[] = []

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index] as string
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
      const value = separator === -1 ? undefined : argument.slice(separator + 1)
      if (name === '--zero-terminated' && value === undefined) zero = true
      else if (name === '--reverse' && value === undefined) reverse = true
      else if (name === '--numeric-sort' && value === undefined) numeric = true
      else if (name === '--unique' && value === undefined) unique = true
      else if (name === '--ignore-case' && value === undefined) ignoreCase = true
      else if (name === '--ignore-leading-blanks' && value === undefined) ignoreBlanks = true
      else if (name === '--output') {
        const next = value ?? argv[index + 1]
        if (next === undefined) unsupported.push(argument)
        else {
          output = next
          if (value === undefined) index += 1
        }
      } else unsupported.push(argument)
      continue
    }
    for (let offset = 1; offset < argument.length; offset += 1) {
      const flag = argument[offset] as string
      if (flag === 'r') reverse = true
      else if (flag === 'n') numeric = true
      else if (flag === 'u') unique = true
      else if (flag === 'f') ignoreCase = true
      else if (flag === 'b') ignoreBlanks = true
      else if (flag === 'z') zero = true
      else if (flag === 'o') {
        const attached = argument.slice(offset + 1)
        const next = attached === '' ? argv[index + 1] : attached
        if (next === undefined) unsupported.push('-o')
        else {
          output = next
          if (attached === '') index += 1
        }
        break
      } else unsupported.push(`-${flag}`)
    }
  }
  return { zero, reverse, numeric, unique, ignoreCase, ignoreBlanks, output, operands, unsupported }
}

/** The portable text of the errno codes a record read can surface. */
const ERRNO_TEXT: Readonly<Record<string, string>> = Object.freeze({
  EACCES: 'Permission denied',
  EFBIG: 'File too large',
  EIO: 'Input/output error',
  EISDIR: 'Is a directory',
  ELOOP: 'Too many levels of symbolic links',
  ENAMETOOLONG: 'File name too long',
  ENOENT: 'No such file or directory',
  ENOMEM: 'Cannot allocate memory',
  ENOTDIR: 'Not a directory',
})

/** Render the strerror-shaped tail of one failed record read. */
function describeReadError(error: unknown): string {
  const coded = error as { code?: unknown; message?: unknown } | null
  const code = typeof coded?.code === 'string' && coded.code !== '' ? coded.code : undefined
  if (code !== undefined && ERRNO_TEXT[code] !== undefined) return ERRNO_TEXT[code] as string
  const message = typeof coded?.message === 'string' && coded.message !== '' ? coded.message : String(error)
  return message
}

/** Fold ASCII upper case exactly as the C-locale `-f` comparison does. */
function foldAscii(value: string): string {
  return value.replace(/[A-Z]/gu, character => character.toLowerCase())
}

/** Compare two latin1-shaped byte strings by code unit (= byte) order. */
function compareBytes(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}

/** The comparable key of one record under the selected options. */
function recordKey(record: string, parsed: SortArguments): string {
  let key = parsed.ignoreBlanks ? record.replace(/^[ \t]+/u, '') : record
  if (parsed.ignoreCase) key = foldAscii(key)
  return key
}

/** Parse the leading number of a record the way `sort -n` does. */
function numericPrefix(value: string): number {
  const match = /^[ \t]*([+-]?(?:\d+(?:\.\d*)?|\.\d+))/u.exec(value)
  if (match === null) return 0
  const parsed = Number.parseFloat(match[1] as string)
  return Number.isNaN(parsed) ? 0 : parsed
}

/**
 * Compare two record keys, ignoring the last-resort tie-break.
 *
 * Under `-n` two records whose numeric prefixes are equal have the same key
 * even when their spellings differ (`01` and `1`); under `-f`/`-b` the folded
 * or blank-stripped keys decide likewise. Returning 0 here is what lets `-u`
 * drop those duplicates instead of treating the raw bytes as a second key.
 */
function compareKeys(left: string, right: string, parsed: SortArguments): number {
  if (parsed.numeric) {
    const difference = numericPrefix(left) - numericPrefix(right)
    if (difference !== 0) return difference < 0 ? -1 : 1
    return 0
  }
  return compareBytes(left, right)
}

/**
 * The full comparator: key first, then GNU's last-resort whole-line comparison,
 * with `-r` applied to both.
 */
function compareRecords(left: string, right: string, parsed: SortArguments): number {
  let comparison = compareKeys(recordKey(left, parsed), recordKey(right, parsed), parsed)
  if (comparison === 0) comparison = compareBytes(left, right)
  return parsed.reverse ? -comparison : comparison
}

/**
 * Split one input source's byte stream into NUL-delimited records.
 *
 * A trailing NUL terminates the final record instead of creating an empty one;
 * empty input has no records at all. Each file/stdin source is split on its
 * own so a final unterminated record does not join the next source.
 * @param input - the latin1-shaped byte string of one source.
 * @returns the records in input order.
 */
export function splitNulRecords(input: string): string[] {
  if (input === '') return []
  const records = input.split('\0')
  if (records[records.length - 1] === '') records.pop()
  return records
}

/**
 * Build the `sort` command over the Worker shell's filesystem.
 * @returns the command definition.
 */
export function createSortCommand(): Command {
  return defineCommand('sort', async (args, ctx): Promise<ExecResult> => {
    const parsed = parseSortArguments(args)
    // Without NUL records the bundled program stays authoritative: every
    // option it implements (including `-k`/`-t`) keeps its exact behaviour.
    if (!parsed.zero) {
      if (ctx.origCommand === undefined) {
        return { stdout: '', stderr: 'sort: command unavailable\n', exitCode: 127 }
      }
      return await ctx.origCommand([...args])
    }
    for (const option of parsed.unsupported) {
      try {
        throwOption(option)
      } catch (error) {
        if (error instanceof SortUsageError) {
          return { stdout: '', stderr: `sort: ${error.message}\n`, exitCode: 2 }
        }
        throw error
      }
    }
    const { records, stderr } = await readSortInput(ctx.fs, ctx.cwd, parsed.operands, String(ctx.stdin ?? ''))
    // GNU suppresses every output record when any source cannot be read; it
    // must not emit a partial sort (and must not create an `-o` file).
    if (stderr !== '') return { stdout: '', stderr, exitCode: 2 }
    let outputRecords = records
    if (parsed.unique) {
      // `-u` compares keys only (no last-resort whole-line comparison) and a
      // stable sort keeps the first input record of an equal-key run.
      records.sort((left, right) => {
        const comparison = compareKeys(recordKey(left, parsed), recordKey(right, parsed), parsed)
        return parsed.reverse ? -comparison : comparison
      })
      const unique: string[] = []
      for (const record of records) {
        const previous = unique[unique.length - 1]
        if (previous !== undefined && compareKeys(recordKey(previous, parsed), recordKey(record, parsed), parsed) === 0) continue
        unique.push(record)
      }
      outputRecords = unique
    } else {
      records.sort((left, right) => compareRecords(left, right, parsed))
    }
    const output = outputRecords.length === 0 ? '' : `${outputRecords.join('\0')}\0`
    const exitCode = 0
    if (parsed.output !== undefined && parsed.output !== '-') {
      try {
        await ctx.fs.writeFile(
          posix.normalize(ctx.fs.resolvePath(ctx.cwd, parsed.output)),
          byteStringToBytes(output),
        )
      } catch (error) {
        return { stdout: '', stderr: `sort: ${parsed.output}: ${describeReadError(error)}\n`, exitCode: 2 }
      }
      return { stdout: '', stderr, exitCode }
    }
    return { ...byteStringOutput(output), stderr, exitCode }
  })
}

/** Throw the usage error for one unsupported `-z`-surface option. */
function throwOption(option: string): never {
  if (option === '-k' || option === '--key' || option.startsWith('--key=')) {
    throw new SortUsageError('option -k/--key is not implemented together with -z')
  }
  if (option === '-t' || option === '--field-separator' || option.startsWith('--field-separator=')) {
    throw new SortUsageError('option -t/--field-separator is not implemented together with -z')
  }
  throw new SortUsageError(`option ${option} is not implemented together with -z`)
}

/**
 * Read every record source, splitting each source into NUL records separately.
 *
 * GNU `sort -z` treats each file as its own record stream: a final record
 * without a trailing NUL does not join the first record of the next file. File
 * contents and stdin stay latin1-shaped byte strings, and a missing file is
 * reported in GNU's `cannot read` shape.
 * @param fs - the Worker filesystem.
 * @param cwd - the shell working directory.
 * @param operands - file operands (`-` means stdin).
 * @param stdin - the already-decoded stdin byte string.
 * @returns the records in source order and the accumulated diagnostics.
 */
async function readSortInput(
  fs: IFileSystem,
  cwd: string,
  operands: readonly string[],
  stdin: string,
): Promise<{ readonly records: string[]; readonly stderr: string }> {
  const records: string[] = []
  let stderr = ''
  let stdinConsumed = false
  const sources = operands.length === 0 ? ['-'] : operands
  for (const operand of sources) {
    if (operand === '-') {
      if (!stdinConsumed) {
        records.push(...splitNulRecords(stdin))
        stdinConsumed = true
      }
      continue
    }
    try {
      const bytes = await fs.readFileBuffer(posix.normalize(fs.resolvePath(cwd, operand)))
      records.push(...splitNulRecords(bytesToByteString(bytes)))
    } catch (error) {
      stderr += `sort: cannot read: ${operand}: ${describeReadError(error)}\n`
    }
  }
  return { records, stderr }
}
