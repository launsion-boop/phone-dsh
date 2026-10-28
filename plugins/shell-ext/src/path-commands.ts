// SPDX-License-Identifier: MIT
/**
 * `realpath` and `readlink` for the Worker shell.
 *
 * just-bash ships `readlink` but rejects `-m` (`readlink: invalid option --
 * 'm'`) and has no `realpath` at all, so the two commands POSIX scripts use to
 * turn a path into its canonical form were missing from the Worker command
 * surface (G2-A01: `realpath` exit 127 and `readlink -m` exit 1). This module
 * adds both, with the GNU/POSIX canonicalisation modes expressed over the
 * `IFileSystem` the shell already runs on:
 *
 * - the default `realpath` mode and `readlink -f` require every component but
 *   the last to exist;
 * - `-e` requires the whole path to exist;
 * - `-m` canonicalises a path that may not exist (the longest existing prefix
 *   is resolved, the rest is normalised lexically).
 *
 * The Worker VFS is symlink-free, so on the Worker the answer is the
 * normalised absolute path; the implementation still asks the backend for
 * `realpath`/`readlink` so a host backend with symlinks (the test `InMemoryFs`,
 * a desktop mount) keeps POSIX behaviour. `--relative-to` and `-z` are
 * supported for the `realpath` corpus and script idioms; an option outside the
 * documented set fails loud instead of being ignored.
 * @module @phone-dsh/dsh-shell-ext/path-commands
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, IFileSystem } from 'just-bash/browser'
import { shellFailure, withCommandExit } from './contract.ts'

/** Which components of a path must exist during canonicalisation. */
export type CanonicalizeMode = 'existing' | 'all-but-last' | 'missing'

/** A path that cannot be canonicalised in the requested mode. */
export class CanonicalizeError extends Error {
  /** `ENOENT` for a missing component, `EINVAL` for an unusable operand. */
  readonly code: 'ENOENT' | 'EINVAL'

  /**
   * @param code - errno-style code.
   * @param message - GNU-style diagnostic body.
   */
  constructor(code: 'ENOENT' | 'EINVAL', message: string) {
    super(message)
    this.name = 'CanonicalizeError'
    this.code = code
  }
}

/** Absolute, lexically normalised form of `input` relative to `cwd`. */
function absoluteOf(cwd: string, input: string): string {
  if (input === '') throw new CanonicalizeError('ENOENT', 'No such file or directory')
  return posix.normalize(posix.resolve(cwd, input))
}

/** True when `path` exists, treating backend errors as "no". */
async function exists(fs: IFileSystem, path: string): Promise<boolean> {
  try {
    return await fs.exists(path)
  } catch {
    return false
  }
}

/**
 * Resolve the longest existing prefix of `absolute` and append the missing
 * remainder lexically.
 * @param fs - the shell filesystem.
 * @param absolute - normalised absolute path.
 * @returns the canonical path.
 */
async function resolveMissingTail(fs: IFileSystem, absolute: string): Promise<string> {
  const components = absolute.split('/').filter(component => component !== '')
  for (let count = components.length; count >= 0; count -= 1) {
    const prefix = `/${components.slice(0, count).join('/')}`
    if (!(await exists(fs, prefix))) continue
    const resolved = await fs.realpath(prefix)
    const tail = components.slice(count)
    return tail.length === 0 ? resolved : posix.join(resolved, ...tail)
  }
  return absolute
}

/**
 * Canonicalise one path.
 * @param fs - the shell filesystem.
 * @param cwd - virtual working directory.
 * @param input - the operand as written.
 * @param mode - existence requirement of the canonicalisation mode.
 * @param strip - do not resolve symlinks (the lexical `-s` form).
 * @returns the absolute canonical path.
 */
export async function canonicalizePath(
  fs: IFileSystem,
  cwd: string,
  input: string,
  mode: CanonicalizeMode,
  strip = false,
): Promise<string> {
  const absolute = absoluteOf(cwd, input)
  if (strip) return absolute
  if (await exists(fs, absolute)) {
    try {
      return await fs.realpath(absolute)
    } catch {
      return absolute
    }
  }
  if (mode === 'existing') throw new CanonicalizeError('ENOENT', 'No such file or directory')
  if (mode === 'all-but-last') {
    const parent = posix.dirname(absolute)
    if (parent === absolute || !(await exists(fs, parent))) {
      throw new CanonicalizeError('ENOENT', 'No such file or directory')
    }
    const resolved = await resolveMissingTail(fs, parent)
    return posix.join(resolved, posix.basename(absolute))
  }
  return await resolveMissingTail(fs, absolute)
}

/** Parsed `realpath` argv. */
interface RealpathArguments {
  readonly mode: CanonicalizeMode
  readonly strip: boolean
  readonly zero: boolean
  readonly relativeTo: string | undefined
  readonly operands: readonly string[]
  readonly help: boolean
  readonly version: boolean
}

/** Split `--name=value` once. */
function splitLongOption(argument: string): { flag: string; value: string | undefined } {
  const equals = argument.indexOf('=')
  if (equals === -1) return { flag: argument, value: undefined }
  return { flag: argument.slice(0, equals), value: argument.slice(equals + 1) }
}

/** Parse the `realpath` option surface. */
function parseRealpathArguments(argv: readonly string[]): RealpathArguments {
  let mode: CanonicalizeMode = 'all-but-last'
  let strip = false
  let zero = false
  let relativeTo: string | undefined
  let help = false
  let version = false
  const operands: string[] = []
  let options = true
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
    if (argument === '--help') {
      help = true
      continue
    }
    if (argument === '--version') {
      version = true
      continue
    }
    const long = splitLongOption(argument)
    if (long.flag === '--canonicalize-existing') {
      mode = 'existing'
      continue
    }
    if (long.flag === '--canonicalize-missing') {
      mode = 'missing'
      continue
    }
    if (long.flag === '--strip') {
      strip = true
      continue
    }
    if (long.flag === '--zero') {
      zero = true
      continue
    }
    if (long.flag === '--relative-to') {
      const value = long.value ?? argv[index + 1]
      if (value === undefined) throw new Error("option '--relative-to' requires an argument")
      if (long.value === undefined) index += 1
      relativeTo = value
      continue
    }
    if (argument.startsWith('--')) throw new Error(`unrecognized option '${argument}'`)
    for (const letter of argument.slice(1)) {
      if (letter === 'e') mode = 'existing'
      else if (letter === 'm') mode = 'missing'
      else if (letter === 's') strip = true
      else if (letter === 'z') zero = true
      else if (letter === 'L' || letter === 'P' || letter === 'q') {
        // `-L`/`-P` select symlink policy; this VFS is symlink-free. `-q` is
        // the silent form, already the default for a failing operand.
      } else {
        throw new Error(`invalid option -- '${letter}'`)
      }
    }
  }
  return { mode, strip, zero, relativeTo, operands, help, version }
}

/** Usage text for `realpath --help`. */
const REALPATH_HELP = [
  'Usage: realpath [OPTION]... FILE...',
  'Print the resolved absolute file name; all but the last component must exist.',
  '',
  '  -e, --canonicalize-existing  all components must exist',
  '  -m, --canonicalize-missing   no components need exist',
  '  -s, --strip                  do not resolve symlinks',
  '      --relative-to=DIR        print a path relative to DIR',
  '  -z, --zero                   end each output line with NUL, not newline',
  '      --help                   display this help and exit',
  '      --version                output version information and exit',
  '',
].join('\n')

/**
 * Build the `realpath` command.
 * @returns the command definition.
 */
export function createRealpathCommand(): Command {
  return defineCommand('realpath', async (args, ctx): Promise<ExecResult> => {
    let parsed: RealpathArguments
    try {
      parsed = parseRealpathArguments(args)
    } catch (error) {
      return shellFailure('realpath', `realpath: ${error instanceof Error ? error.message : String(error)}`, 'unsupported-option')
    }
    if (parsed.help) return { stdout: REALPATH_HELP, stderr: '', exitCode: 0 }
    if (parsed.version) return { stdout: 'realpath (Worker shell) 1.0\n', stderr: '', exitCode: 0 }
    if (parsed.operands.length === 0) return shellFailure('realpath', 'realpath: missing operand', 'unsupported-option')
    let base: string | undefined
    if (parsed.relativeTo !== undefined) {
      try {
        base = await canonicalizePath(ctx.fs, ctx.cwd, parsed.relativeTo, parsed.mode, parsed.strip)
      } catch (error) {
        return { stdout: '', stderr: `realpath: ${parsed.relativeTo}: ${describe(error)}\n`, exitCode: 1 }
      }
    }
    const lines: string[] = []
    let stderr = ''
    let exitCode = 0
    for (const operand of parsed.operands) {
      try {
        const resolved = await canonicalizePath(ctx.fs, ctx.cwd, operand, parsed.mode, parsed.strip)
        lines.push(base === undefined ? resolved : posix.relative(base, resolved))
      } catch (error) {
        exitCode = 1
        stderr += `realpath: ${operand}: ${describe(error)}\n`
      }
    }
    const result: ExecResult = { stdout: joinLines(lines, parsed.zero), stderr, exitCode }
    return exitCode === 0 ? result : withCommandExit(result, 'realpath')
  })
}

/** Human-readable diagnostic for one canonicalisation failure. */
function describe(error: unknown): string {
  if (error instanceof CanonicalizeError) return error.message
  const code = (error as { code?: unknown } | null)?.code
  if (code === 'ENOENT') return 'No such file or directory'
  if (code === 'EINVAL') return 'Invalid argument'
  if (code === 'EACCES') return 'Permission denied'
  return error instanceof Error ? error.message : String(error)
}

/** Render one list of canonical paths with the selected separator. */
function joinLines(lines: readonly string[], zero: boolean): string {
  if (lines.length === 0) return ''
  // -z separates records as well as terminating the last one; only the
  // terminator was NUL before, so `realpath -z a b` still emitted a newline
  // between the two paths.
  return zero ? `${lines.join('\0')}\0` : `${lines.join('\n')}\n`
}

/** Parsed `readlink` argv. */
interface ReadlinkArguments {
  readonly mode: CanonicalizeMode | undefined
  readonly noNewline: boolean
  readonly zero: boolean
  readonly quiet: boolean
  readonly operands: readonly string[]
  readonly help: boolean
  readonly version: boolean
}

/** Parse the `readlink` option surface. */
function parseReadlinkArguments(argv: readonly string[]): ReadlinkArguments {
  let mode: CanonicalizeMode | undefined
  let noNewline = false
  let zero = false
  let quiet = false
  let help = false
  let version = false
  const operands: string[] = []
  let options = true
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
    if (argument === '--help') {
      help = true
      continue
    }
    if (argument === '--version') {
      version = true
      continue
    }
    const long = splitLongOption(argument)
    if (long.flag === '--canonicalize') {
      mode = 'all-but-last'
      continue
    }
    if (long.flag === '--canonicalize-existing') {
      mode = 'existing'
      continue
    }
    if (long.flag === '--canonicalize-missing') {
      mode = 'missing'
      continue
    }
    if (long.flag === '--no-newline') {
      noNewline = true
      continue
    }
    if (long.flag === '--zero') {
      zero = true
      continue
    }
    if (long.flag === '--quiet' || long.flag === '--silent') {
      quiet = true
      continue
    }
    if (argument.startsWith('--')) throw new Error(`unrecognized option '${argument}'`)
    for (const letter of argument.slice(1)) {
      if (letter === 'f') mode = 'all-but-last'
      else if (letter === 'e') mode = 'existing'
      else if (letter === 'm') mode = 'missing'
      else if (letter === 'n') noNewline = true
      else if (letter === 'z') zero = true
      else if (letter === 'q' || letter === 's') quiet = true
      else throw new Error(`invalid option -- '${letter}'`)
    }
  }
  return { mode, noNewline, zero, quiet, operands, help, version }
}

/** Usage text for `readlink --help`. */
const READLINK_HELP = [
  'Usage: readlink [OPTION]... FILE...',
  'Print value of a symbolic link or canonical file name.',
  '',
  '  -f, --canonicalize           all but the last component must exist',
  '  -e, --canonicalize-existing  all components must exist',
  '  -m, --canonicalize-missing   no components need exist',
  '  -n, --no-newline             do not output the trailing delimiter',
  '  -q, --quiet                  suppress most error messages',
  '  -s, --silent                 same as --quiet',
  '  -z, --zero                   end each output line with NUL, not newline',
  '      --help                   display this help and exit',
  '      --version                output version information and exit',
  '',
].join('\n')

/**
 * Build the `readlink` command that shadows just-bash's option-poor built-in.
 * @returns the command definition.
 */
export function createReadlinkCommand(): Command {
  return defineCommand('readlink', async (args, ctx): Promise<ExecResult> => {
    let parsed: ReadlinkArguments
    try {
      parsed = parseReadlinkArguments(args)
    } catch (error) {
      return shellFailure('readlink', `readlink: ${error instanceof Error ? error.message : String(error)}`, 'unsupported-option')
    }
    if (parsed.help) return { stdout: READLINK_HELP, stderr: '', exitCode: 0 }
    if (parsed.version) return { stdout: 'readlink (Worker shell) 1.0\n', stderr: '', exitCode: 0 }
    if (parsed.operands.length === 0) return shellFailure('readlink', 'readlink: missing operand', 'unsupported-option')
    const lines: string[] = []
    let stderr = ''
    let exitCode = 0
    for (const operand of parsed.operands) {
      try {
        if (parsed.mode === undefined) {
          const absolute = posix.normalize(posix.resolve(ctx.cwd, operand))
          const stat = await ctx.fs.lstat(absolute)
          if (!stat.isSymbolicLink) {
            exitCode = 1
            continue
          }
          lines.push(await ctx.fs.readlink(absolute))
          continue
        }
        lines.push(await canonicalizePath(ctx.fs, ctx.cwd, operand, parsed.mode))
      } catch (error) {
        if (!parsed.quiet) stderr += `readlink: ${operand}: ${describe(error)}\n`
        exitCode = 1
      }
    }
    const result: ExecResult = {
      stdout: joinReadlink(lines, parsed),
      stderr,
      exitCode,
    }
    return exitCode === 0 ? result : withCommandExit(result, 'readlink')
  })
}

/** Render `readlink` output with its delimiters. */
function joinReadlink(lines: readonly string[], parsed: ReadlinkArguments): string {
  if (lines.length === 0) return ''
  if (parsed.zero) return `${lines.join('\0')}\0`
  if (parsed.noNewline) return lines.join('\n')
  return `${lines.join('\n')}\n`
}
