// SPDX-License-Identifier: MIT
/**
 * The Worker shell's `stat -c` format shim.
 *
 * `stat` is a just-bash built-in (Apache-2.0, imported unmodified). Its `-c`
 * formatter understands only `%n %N %s %F %a %A %u %U %g %G`; every other GNU
 * directive (`%i`, `%h`, `%y`, `%z`, ...) is copied to stdout as literal text
 * and the command still exits 0. A Worker metadata query therefore returns
 * silently corrupt data — the G2-A02 defect class.
 *
 * This module shadows the built-in through just-bash's custom-command table
 * (the same seam `find.ts` uses) and renders the directive set the shell corpus
 * exercises from the values `IFileSystem.stat` actually reports:
 *
 * - `%n` name, `%N` quoted name, `%s` size, `%F` file type;
 * - `%a`/`%A` permission bits and symbolic mode; `%i` inode and `%d`/`%D`
 *   device come from the inode and device fields of `FsStat` (`0` when a
 *   backend omits them);
 * - `%y`/`%Y` modification time (human/epoch), `%x`/`%X` and `%z`/`%Z` fall
 *   back to the same modification time because the VFS reports only one
 *   timestamp (it has no separate atime/ctime);
 * - `%u`/`%U`/`%g`/`%G` ownership, `%h` hard links and `%t`/`%T` device type
 *   are the {@link WORKER_STAT_FALLBACKS} constants: the VFS has no ownership,
 *   link count or device number for a regular file, so the shim reports the
 *   constant a single-link, single-user Worker image has rather than inventing
 *   per-file data;
 * - `%b` is the allocated 512-byte block count (`ceil(size / 512)`, matching
 *   `find -printf '%b'`) and `%B` is the 512 block-size unit;
 * - `%%` is a literal percent sign and `\n`/`\t`/`\\` are the supported
 *   backslash escapes.
 *
 * `--format`/`-c` adds one newline after each operand; GNU's `--printf` shares
 * the same parser but concatenates the rendered operands unchanged.
 *
 * A directive this shim does not implement is never echoed. The command fails
 * loud with `stat: unsupported format specifier '%X'` on stderr and exit 2,
 * matching the "never silently lie" rule. The default no-format output (and
 * `--help`) is delegated to the shadowed built-in so it stays byte-identical.
 * @module @phone-dsh/dsh-shell-ext/stat
 */

import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, FsStat } from 'just-bash/browser'
import { shellFailure, withCommandExit } from './contract.ts'

/**
 * Values the Worker VFS cannot report for an individual file.
 *
 * The VFS stat carries mode, size, mtime, dev and ino only: no ownership, link
 * count or device type. These constants are the values of the single-user,
 * single-link Worker image, so a query returns a stable documented value
 * instead of a literal directive. `uid`/`gid`/names keep the values just-bash's
 * built-in already reported, so `%u`/`%U`/`%g`/`%G` do not change.
 */
export const WORKER_STAT_FALLBACKS = Object.freeze({
  uid: '1000',
  userName: 'user',
  gid: '1000',
  groupName: 'group',
  hardLinks: '1',
  majorDevice: '0',
  minorDevice: '0',
} as const)

/** GNU `stat -c` directives this shim renders from `FsStat`. */
export const STAT_FORMAT_SPECIFIERS: readonly string[] = Object.freeze([
  'a', 'A', 'b', 'B', 'd', 'D', 'F', 'g', 'G', 'h', 'i',
  'n', 'N', 's', 't', 'T', 'u', 'U',
  'x', 'X', 'y', 'Y', 'z', 'Z',
])

/** The 512-byte block unit GNU `%b` counts and `%B` reports. */
const STAT_BLOCK_SIZE = 512

/** One parsed piece of a `stat -c` format string. */
export type StatFormatToken =
  | { readonly kind: 'literal'; readonly text: string }
  | { readonly kind: 'specifier'; readonly code: string }

/** A format directive the Worker shim does not implement. */
export class StatFormatError extends Error {
  /** The offending directive, including the leading `%`. */
  readonly specifier: string

  /**
   * @param specifier - the directive text, for example `%Q`.
   */
  constructor(specifier: string) {
    super(`unsupported format specifier '${specifier}'`)
    this.name = 'StatFormatError'
    this.specifier = specifier
  }
}

/** File-type mask and the POSIX type values the VFS can report. */
const S_IFMT = 0o170000
const S_IFIFO = 0o010000
const S_IFCHR = 0o020000
const S_IFDIR = 0o040000
const S_IFBLK = 0o060000
const S_IFREG = 0o100000
const S_IFLNK = 0o120000
const S_IFSOCK = 0o140000

/** Strip Node's file-type bits, keeping the permission and special bits. */
function permissionMode(stat: FsStat): number {
  return stat.mode & 0o7777
}

/** The first column of a symbolic mode (`-`, `d`, `c`, ...). */
function fileTypeLetter(stat: FsStat): string {
  if (stat.isSymbolicLink) return 'l'
  if (stat.isDirectory) return 'd'
  if (stat.isFile) return '-'
  switch (stat.mode & S_IFMT) {
    case S_IFCHR: return 'c'
    case S_IFBLK: return 'b'
    case S_IFIFO: return 'p'
    case S_IFSOCK: return 's'
    default: return '?'
  }
}

/** The symbolic mode column GNU `stat %A` and `find %M` render. */
export function formatSymbolicMode(stat: FsStat): string {
  return symbolicMode(stat)
}

/** One `rwx` triple, honouring the setuid/setgid/sticky bit. */
function permissionTriple(read: boolean, write: boolean, execute: boolean, special: boolean, specialChar: string): string {
  const executeChar = execute
    ? special ? specialChar : 'x'
    : special ? specialChar.toUpperCase() : '-'
  return `${read ? 'r' : '-'}${write ? 'w' : '-'}${executeChar}`
}

/** GNU `%A`: the ten-character symbolic mode string. */
function symbolicMode(stat: FsStat): string {
  const mode = permissionMode(stat)
  return fileTypeLetter(stat)
    + permissionTriple((mode & 0o400) !== 0, (mode & 0o200) !== 0, (mode & 0o100) !== 0, (mode & 0o4000) !== 0, 's')
    + permissionTriple((mode & 0o040) !== 0, (mode & 0o020) !== 0, (mode & 0o010) !== 0, (mode & 0o2000) !== 0, 's')
    + permissionTriple((mode & 0o004) !== 0, (mode & 0o002) !== 0, (mode & 0o001) !== 0, (mode & 0o1000) !== 0, 't')
}

/** GNU `%F`: the human-readable file type. */
function fileTypeName(stat: FsStat): string {
  if (stat.isDirectory) return 'directory'
  if (stat.isSymbolicLink) return 'symbolic link'
  if (stat.isFile) return stat.size === 0 ? 'regular empty file' : 'regular file'
  switch (stat.mode & S_IFMT) {
    case S_IFCHR: return 'character special file'
    case S_IFBLK: return 'block special file'
    case S_IFIFO: return 'fifo'
    case S_IFSOCK: return 'socket'
    case S_IFDIR: return 'directory'
    case S_IFREG: return 'regular file'
    case S_IFLNK: return 'symbolic link'
    default: return 'unknown'
  }
}

/** Render one device or inode number, accepting Node's number or bigint. */
function decimal(value: number | bigint | undefined): string {
  return value === undefined ? '0' : String(value)
}

/** Render one device number in hexadecimal. */
function hexadecimal(value: number | bigint | undefined): string {
  return value === undefined ? '0' : value.toString(16)
}

/** Two-digit zero padding. */
function pad2(value: number): string {
  return String(value).padStart(2, '0')
}

/**
 * GNU human-readable timestamp: `YYYY-MM-DD HH:MM:SS.nnnnnnnnn +ZZZZ`.
 *
 * JavaScript dates carry milliseconds, so the nanosecond field is the
 * millisecond field followed by six zeros. The offset is the process-local
 * timezone, as GNU `stat` uses localtime.
 * @param date - timestamp from `FsStat`.
 * @returns the formatted timestamp.
 */
export function formatStatTime(date: Date): string {
  const year = String(date.getFullYear()).padStart(4, '0')
  const fraction = `${String(date.getMilliseconds()).padStart(3, '0')}000000`
  const offsetMinutes = -date.getTimezoneOffset()
  const sign = offsetMinutes < 0 ? '-' : '+'
  const offset = Math.abs(offsetMinutes)
  return `${year}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`
    + ` ${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())}`
    + `.${fraction} ${sign}${pad2(Math.floor(offset / 60))}${pad2(offset % 60)}`
}

/** Seconds since the epoch, the GNU `%Y`/`%X`/`%Z` form. */
function epochSeconds(date: Date): string {
  return String(Math.floor(date.getTime() / 1000))
}

/**
 * Parse a `stat -c` format string into literal and directive tokens.
 *
 * `%%` becomes a literal `%`, `\n`/`\t`/`\\` become their characters, and every
 * directive outside {@link STAT_FORMAT_SPECIFIERS} throws {@link StatFormatError}
 * before any output is produced.
 * @param format - the `-c`/`--format` value.
 * @returns the ordered tokens.
 */
export function parseStatFormat(format: string): readonly StatFormatToken[] {
  const tokens: StatFormatToken[] = []
  let literal = ''
  const flush = (): void => {
    if (literal !== '') {
      tokens.push({ kind: 'literal', text: literal })
      literal = ''
    }
  }
  for (let index = 0; index < format.length; index += 1) {
    const character = format[index] as string
    if (character === '\\') {
      const escape = format[index + 1]
      if (escape === 'n') {
        literal += '\n'
        index += 1
      } else if (escape === 't') {
        literal += '\t'
        index += 1
      } else if (escape === '\\') {
        literal += '\\'
        index += 1
      } else {
        literal += character
      }
      continue
    }
    if (character !== '%') {
      literal += character
      continue
    }
    const code = format[index + 1]
    if (code === undefined) throw new StatFormatError('%')
    if (code === '%') {
      literal += '%'
      index += 1
      continue
    }
    if (!STAT_FORMAT_SPECIFIERS.includes(code)) throw new StatFormatError(`%${code}`)
    flush()
    tokens.push({ kind: 'specifier', code })
    index += 1
  }
  flush()
  return tokens
}

/**
 * Render parsed format tokens for one file.
 * @param tokens - output of {@link parseStatFormat}.
 * @param name - the operand exactly as the caller wrote it (`%n`).
 * @param stat - the filesystem metadata.
 * @returns the rendered text, without the trailing newline the command adds.
 */
export function formatStat(tokens: readonly StatFormatToken[], name: string, stat: FsStat): string {
  const { dev, ino } = stat
  let output = ''
  for (const token of tokens) {
    if (token.kind === 'literal') {
      output += token.text
      continue
    }
    switch (token.code) {
      case 'a': output += permissionMode(stat).toString(8); break
      case 'A': output += symbolicMode(stat); break
      case 'b': output += String(Math.ceil(stat.size / STAT_BLOCK_SIZE)); break
      case 'B': output += String(STAT_BLOCK_SIZE); break
      case 'd': output += decimal(dev); break
      case 'D': output += hexadecimal(dev); break
      case 'F': output += fileTypeName(stat); break
      case 'g': output += WORKER_STAT_FALLBACKS.gid; break
      case 'G': output += WORKER_STAT_FALLBACKS.groupName; break
      case 'h': output += WORKER_STAT_FALLBACKS.hardLinks; break
      case 'i': output += decimal(stat.ino); break
      case 'n': output += name; break
      case 'N': output += `'${name}'`; break
      case 's': output += String(stat.size); break
      case 't': output += WORKER_STAT_FALLBACKS.majorDevice; break
      case 'T': output += WORKER_STAT_FALLBACKS.minorDevice; break
      case 'u': output += WORKER_STAT_FALLBACKS.uid; break
      case 'U': output += WORKER_STAT_FALLBACKS.userName; break
      // The VFS keeps one timestamp; atime and ctime have no separate value.
      case 'x':
      case 'y':
      case 'z': output += formatStatTime(stat.mtime); break
      case 'X':
      case 'Y':
      case 'Z': output += epochSeconds(stat.mtime); break
      default: throw new StatFormatError(`%${token.code}`)
    }
  }
  return output
}

/** Parsed `stat` argv. */
interface ParsedStatArguments {
  /** The requested format, or undefined when the built-in should render. */
  readonly format: string | undefined
  /** The last format option was `--printf`, which adds no per-file newline. */
  readonly formatIsPrintf: boolean
  /** File operands in command-line order. */
  readonly operands: readonly string[]
  /** argv with the symlink-following switch removed, for delegation. */
  readonly delegated: readonly string[]
  /** `--help` was requested. */
  readonly help: boolean
}

/** An invalid option or missing option value, reported like the built-in. */
class StatUsageError extends Error {}

/**
 * Parse the `stat` argv without reimplementing the default output.
 *
 * Supported flags are `-c FORMAT`, `-cFORMAT`, `--format FORMAT`,
 * `--format=FORMAT`, `--printf FORMAT`, `--printf=FORMAT`, `--` and `--help`;
 * `-L`/`--dereference` is accepted as a no-op because the Worker VFS is
 * symlink-free and is removed from the argv handed to the built-in. A format
 * option keeps the last value seen on the command line, and `--printf` also
 * records that the rendered text must not gain a per-file newline. Any other
 * flag fails loud instead of being ignored.
 * @param argv - arguments after the program name.
 * @returns the parsed invocation.
 */
function parseStatArguments(argv: readonly string[]): ParsedStatArguments {
  let format: string | undefined
  let formatIsPrintf = false
  let help = false
  const operands: string[] = []
  const delegated: string[] = []
  let index = 0
  while (index < argv.length) {
    const token = argv[index] as string
    index += 1
    if (token === '--') {
      delegated.push(token, ...argv.slice(index))
      operands.push(...argv.slice(index))
      break
    }
    if (token === '--help') {
      help = true
      delegated.push(token)
      continue
    }
    if (token === '-L' || token === '--dereference') continue
    if (token === '-c') {
      const value = argv[index]
      if (value === undefined) throw new StatUsageError("stat: option requires an argument -- 'c'\n")
      format = value
      formatIsPrintf = false
      delegated.push(token, value)
      index += 1
      continue
    }
    if (token.startsWith('-c') && token.length > 2) {
      format = token.slice(2)
      formatIsPrintf = false
      delegated.push(token)
      continue
    }
    if (token === '--format') {
      const value = argv[index]
      if (value === undefined) throw new StatUsageError("stat: option '--format' requires an argument\n")
      format = value
      formatIsPrintf = false
      delegated.push(token, value)
      index += 1
      continue
    }
    if (token.startsWith('--format=')) {
      format = token.slice('--format='.length)
      formatIsPrintf = false
      delegated.push(token)
      continue
    }
    if (token === '--printf') {
      const value = argv[index]
      if (value === undefined) throw new StatUsageError("stat: option '--printf' requires an argument\n")
      format = value
      formatIsPrintf = true
      delegated.push(token, value)
      index += 1
      continue
    }
    if (token.startsWith('--printf=')) {
      format = token.slice('--printf='.length)
      formatIsPrintf = true
      delegated.push(token)
      continue
    }
    if (token.startsWith('--')) {
      throw new StatUsageError(`stat: unrecognized option '${token}'\n`)
    }
    if (token.startsWith('-') && token !== '-') {
      throw new StatUsageError(`stat: invalid option -- '${token[1] as string}'\n`)
    }
    operands.push(token)
    delegated.push(token)
  }
  return { format, formatIsPrintf, operands, delegated, help }
}

/** The errno text for one failed stat, GNU-style. */
function statErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    const code = (error as { code?: string }).code
    if (code === 'ENOENT') return 'No such file or directory'
    if (code === 'EACCES') return 'Permission denied'
    if (code === 'ENOTDIR') return 'Not a directory'
    if (code === 'ELOOP') return 'Too many levels of symbolic links'
    if (code === 'ENAMETOOLONG') return 'File name too long'
    return error.message
  }
  return String(error)
}

/**
 * Build the `stat` custom command that shadows just-bash's built-in.
 *
 * A `-c`/`--format`/`--printf` invocation is rendered here; every other
 * invocation is delegated to `ctx.origCommand`, so the default listing,
 * `--help` and their error bytes stay exactly the built-in's.
 * @returns the `stat` command definition.
 */
export function createStatCommand(): Command {
  return defineCommand('stat', async (args, ctx): Promise<ExecResult> => {
    let parsed: ParsedStatArguments
    try {
      parsed = parseStatArguments(args)
    } catch (error) {
      if (error instanceof StatUsageError) return shellFailure('stat', error.message, 'unsupported-option')
      throw error
    }
    if (parsed.help || parsed.format === undefined) {
      if (ctx.origCommand === undefined) {
        return shellFailure('stat', 'stat: the built-in stat is unavailable in this shell', 'backend-failed')
      }
      return await ctx.origCommand([...parsed.delegated])
    }
    let tokens: readonly StatFormatToken[]
    try {
      tokens = parseStatFormat(parsed.format)
    } catch (error) {
      if (error instanceof StatFormatError) {
        // A directive the shim cannot answer is a usage boundary (2), never a
        // literal echo with 0 and never a data failure a caller might retry.
        return shellFailure('stat', `stat: unsupported format specifier '${error.specifier}'`, 'unsupported-option')
      }
      throw error
    }
    if (parsed.operands.length === 0) return shellFailure('stat', 'stat: missing operand', 'unsupported-option')
    let stdout = ''
    let stderr = ''
    let failed = false
    for (const operand of parsed.operands) {
      const path = ctx.fs.resolvePath(ctx.cwd, operand)
      try {
        const stat = await ctx.fs.stat(path)
        stdout += formatStat(tokens, operand, stat)
        if (!parsed.formatIsPrintf) stdout += '\n'
      } catch (error) {
        stderr += `stat: cannot stat '${operand}': ${statErrorMessage(error)}\n`
        failed = true
      }
    }
    const result: ExecResult = { stdout, stderr, exitCode: failed ? 1 : 0 }
    return failed ? withCommandExit(result, 'stat') : result
  })
}

