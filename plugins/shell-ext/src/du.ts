// SPDX-License-Identifier: MIT
/**
 * `du`: GNU-compatible `-h`/allocation-block disk usage over the Worker VFS.
 *
 * just-bash 3.6.0 already scales sizes at or above 1 KiB under `-h`, but the
 * pre-fix program had three observable gaps against GNU `du`:
 *
 * 1. `-h` printed a bare byte count below 1 KiB (`du -h five-bytes` -> `5`),
 *    where GNU prints `4.0K` because a non-empty file occupies one 4 KiB
 *    allocation block;
 * 2. `--human-readable` was rejected as an unknown long option;
 * 3. the reported size was the apparent byte size (then rounded up to 1 KiB),
 *    not the st_blocks-style 4 KiB allocation count. An empty file must be `0`
 *    blocks and every non-empty file one or more whole 4 KiB blocks.
 *
 * This module shadows the bundled command and owns the surface scripts use:
 * `-h`/`--human-readable`, `-a`, `-s`, `-c`, `--max-depth=N`, `--` and
 * operands. Directory totals are the sum of their files' allocation blocks;
 * the directory entry itself adds no block. A missing operand keeps GNU's
 * `du: cannot access '<name>': <reason>` diagnostic and exit status 1.
 *
 * The human formatter is the GNU `human_readable` ceiling shape: whole bytes
 * below 1 KiB, one decimal place below ten scaled units (`4.0K`, `1.5K`,
 * `1.0M`) and integer units from ten upwards (`10K`, `1.2M` is not emitted
 * because block counts are whole 4 KiB units). It is exported separately so
 * the formatting rule can be tested without inventing a fractional block.
 * @module @phone-dsh/dsh-shell-ext/du
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, IFileSystem } from 'just-bash/browser'

/** The allocation unit GNU `du` reports (4 KiB, st_blocks-style). */
export const DU_BLOCK_BYTES = 4096

/** The help text this shim prints for `du --help`. */
export const DU_HELP = `Usage: du [OPTION]... [FILE]...
Summarize disk usage of each FILE, recursively for directories.

  -a, --all             write counts for all files, not just directories
  -h, --human-readable  print sizes in human readable format (e.g., 1K 234M 2G)
  -s, --summarize       display only a total for each argument
  -c, --total           produce a grand total
      --max-depth=N     print the total for a directory only if it is N or
                        fewer levels deep
      --help            display this help and exit
      --version         output version information and exit
`

/** The `just-bash` engine version the single version line names. */
export const JUST_BASH_VERSION = '3.6.0'

/** One parsed `du` invocation. */
export interface DuArguments {
  readonly human: boolean
  readonly all: boolean
  readonly summarize: boolean
  readonly grandTotal: boolean
  readonly maxDepth: number | null
  readonly operands: readonly string[]
  readonly help: boolean
  readonly version: boolean
}

/** A `du` option outside the Worker surface. */
export class DuUsageError extends Error {
  /**
   * @param message - diagnostic body without the `du: ` prefix.
   */
  constructor(message: string) {
    super(message)
    this.name = 'DuUsageError'
  }
}

/**
 * Parse `du`'s option surface.
 * @param argv - arguments after the program name.
 * @returns the parsed invocation.
 * @throws {DuUsageError} for an unknown or malformed option.
 */
export function parseDuArguments(argv: readonly string[]): DuArguments {
  let options = true
  let human = false
  let all = false
  let summarize = false
  let grandTotal = false
  let maxDepth: number | null = null
  let help = false
  let version = false
  const operands: string[] = []

  const readDepth = (value: string | undefined): number => {
    if (value === undefined) throw new DuUsageError("option '--max-depth' requires an argument")
    if (!/^\d+$/u.test(value)) throw new DuUsageError(`invalid maximum depth '${value}'`)
    return Number.parseInt(value, 10)
  }

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
      if (name === '--human-readable' && value === undefined) human = true
      else if (name === '--all' && value === undefined) all = true
      else if (name === '--summarize' && value === undefined) summarize = true
      else if (name === '--total' && value === undefined) grandTotal = true
      else if (name === '--max-depth') {
        maxDepth = readDepth(value ?? argv[index + 1])
        if (value === undefined) index += 1
      } else if (name === '--help' && value === undefined) help = true
      else if (name === '--version' && value === undefined) version = true
      else throw new DuUsageError(`unrecognized option '${argument}'`)
      continue
    }
    for (let offset = 1; offset < argument.length; offset += 1) {
      const flag = argument[offset] as string
      if (flag === 'h') human = true
      else if (flag === 'a') all = true
      else if (flag === 's') summarize = true
      else if (flag === 'c') grandTotal = true
      else throw new DuUsageError(`invalid option -- '${flag}'`)
    }
  }
  return { human, all, summarize, grandTotal, maxDepth, operands, help, version }
}

/**
 * Format one byte count the way GNU `du -h` does.
 *
 * Below 1 KiB the exact byte count is printed. Otherwise the value is scaled
 * by 1024 while it exceeds 1023 units (the GNU autoscale ceiling), rounded up
 * to one decimal place below ten units and up to the next whole unit from ten
 * upwards.
 * @param bytes - size in bytes (a non-negative integer).
 * @returns the GNU-style human-readable size.
 */
export function formatHuman(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0'
  if (bytes < 1024) return String(Math.trunc(bytes))
  const units = ['K', 'M', 'G', 'T', 'P', 'E'] as const
  let unit = 1024
  let index = 0
  while (bytes > unit * 1023 && index < units.length - 1) {
    unit *= 1024
    index += 1
  }
  const scaled = bytes / unit
  const label = units[index] as string
  if (scaled < 10) return `${(Math.ceil(scaled * 10) / 10).toFixed(1)}${label}`
  return `${Math.ceil(scaled)}${label}`
}

/**
 * The GNU allocation size of one entry: empty files occupy zero blocks and
 * every non-empty entry occupies at least one whole 4 KiB block.
 * @param size - apparent byte size.
 * @returns the allocated byte count, a multiple of {@link DU_BLOCK_BYTES}.
 */
export function allocatedBytes(size: number): number {
  if (!Number.isFinite(size) || size <= 0) return 0
  return Math.ceil(size / DU_BLOCK_BYTES) * DU_BLOCK_BYTES
}

/** The portable text of the errno codes a `du` operand can surface. */
const ERRNO_TEXT: Readonly<Record<string, string>> = Object.freeze({
  EACCES: 'Permission denied',
  EIO: 'Input/output error',
  ELOOP: 'Too many levels of symbolic links',
  ENAMETOOLONG: 'File name too long',
  ENOENT: 'No such file or directory',
  ENOTDIR: 'Not a directory',
})

/** Render the strerror-shaped tail of one failed operand stat. */
function describeStatError(error: unknown): string {
  const coded = error as { code?: unknown; message?: unknown } | null
  const code = typeof coded?.code === 'string' && coded.code !== '' ? coded.code : undefined
  if (code !== undefined && ERRNO_TEXT[code] !== undefined) return ERRNO_TEXT[code] as string
  const message = typeof coded?.message === 'string' && coded.message !== '' ? coded.message : String(error)
  return message
}

/** Render one `<size>\t<path>` line. */
function usageLine(bytes: number, path: string, human: boolean): string {
  return `${human ? formatHuman(bytes) : String(bytes / 1024)}\t${path}\n`
}

/** Render a child display path without a doubled separator. */
function childDisplay(base: string, name: string): string {
  if (base === '/') return `/${name}`
  return `${base.replace(/\/+$/u, '')}/${name}`
}

/** What one recursive walk needs. */
interface WalkOptions {
  readonly human: boolean
  readonly all: boolean
  readonly summarize: boolean
  readonly maxDepth: number | null
  readonly lines: string[]
  readonly errors: string[]
}

/** True when a depth is inside the configured maximum. */
function withinDepth(depth: number, maxDepth: number | null): boolean {
  return maxDepth === null || depth <= maxDepth
}

/**
 * Walk one directory and return its allocated total.
 *
 * Files are added to the directory's total; a child directory's own line is
 * emitted after its subtree, matching GNU's post-order listing. `-s` suppresses
 * every child line, and `--max-depth` bounds which depths are printed (the
 * operand's own line is always emitted by the caller).
 */
async function walkDirectory(
  fs: IFileSystem,
  absolute: string,
  display: string,
  depth: number,
  options: WalkOptions,
): Promise<number> {
  let names: string[]
  try {
    names = await fs.readdir(absolute)
  } catch (error) {
    options.errors.push(`du: cannot access '${display}': ${describeStatError(error)}\n`)
    return 0
  }
  let total = 0
  for (const name of names) {
    const childAbsolute = posix.join(absolute, name)
    const child = childDisplay(display, name)
    let stat
    try {
      stat = await fs.lstat(childAbsolute)
    } catch (error) {
      options.errors.push(`du: cannot access '${child}': ${describeStatError(error)}\n`)
      continue
    }
    if (stat.isDirectory) {
      const subtotal = await walkDirectory(fs, childAbsolute, child, depth + 1, options)
      total += subtotal
      if (!options.summarize && withinDepth(depth + 1, options.maxDepth)) {
        options.lines.push(usageLine(subtotal, child, options.human))
      }
      continue
    }
    const blocks = allocatedBytes(stat.size)
    total += blocks
    if (options.all && !options.summarize && withinDepth(depth + 1, options.maxDepth)) {
      options.lines.push(usageLine(blocks, child, options.human))
    }
  }
  return total
}

/**
 * Build the `du` command over the Worker shell's filesystem.
 * @returns the command definition.
 */
export function createDuCommand(): Command {
  return defineCommand('du', async (args, ctx): Promise<ExecResult> => {
    let parsed: DuArguments
    try {
      parsed = parseDuArguments(args)
    } catch (error) {
      if (error instanceof DuUsageError) return { stdout: '', stderr: `du: ${error.message}\n`, exitCode: 1 }
      throw error
    }
    if (parsed.help) return { stdout: DU_HELP, stderr: '', exitCode: 0 }
    if (parsed.version) return { stdout: `du (just-bash) ${JUST_BASH_VERSION}\n`, stderr: '', exitCode: 0 }
    const operands = parsed.operands.length === 0 ? ['.'] : parsed.operands
    const options: WalkOptions = {
      human: parsed.human,
      all: parsed.all,
      summarize: parsed.summarize,
      maxDepth: parsed.maxDepth,
      lines: [],
      errors: [],
    }
    let grandTotal = 0
    for (const operand of operands) {
      const absolute = posix.normalize(ctx.fs.resolvePath(ctx.cwd, operand))
      let stat
      try {
        stat = await ctx.fs.lstat(absolute)
      } catch (error) {
        options.errors.push(`du: cannot access '${operand}': ${describeStatError(error)}\n`)
        continue
      }
      let total: number
      if (stat.isDirectory) {
        total = await walkDirectory(ctx.fs, absolute, operand, 0, options)
      } else {
        total = allocatedBytes(stat.size)
      }
      grandTotal += total
      options.lines.push(usageLine(total, operand, parsed.human))
    }
    if (parsed.grandTotal) {
      options.lines.push(usageLine(grandTotal, 'total', parsed.human))
    }
    return {
      stdout: options.lines.join(''),
      stderr: options.errors.join(''),
      exitCode: options.errors.length === 0 ? 0 : 1,
    }
  })
}
