// SPDX-License-Identifier: MIT
/**
 * The Worker shell's `ls -l` mode shim.
 *
 * `ls` is a just-bash built-in (Apache-2.0, imported unmodified). Its long
 * formatter does not read the mode it is listing: a regular file is always
 * rendered `-rw-r--r--`, a directory `drwxr-xr-x`, and the `.`/`..` rows are
 * emitted with a fixed `drwxr-xr-x ... 0 Jan  1 00:00` body. The Worker VFS
 * does carry a real mode (`chmod 600 f` publishes VFS op 4 and `stat -c '%A' f`
 * reports `-rw-------`), so the shell contradicted itself about one file.
 *
 * This module shadows only the long format. Every non-long invocation is
 * delegated to the built-in byte-for-byte; a long invocation keeps the
 * built-in's columns (`user user`, the five-character size field, the
 * `total N` line and the `Mon DD HH:MM`/`Mon DD  YYYY` timestamp), sorting,
 * headers and diagnostics, and replaces only the values those columns are
 * derived from: the first column and the size/mtime come from the same
 * `IFileSystem.lstat` the `stat` shim reads, and the symbolic mode is rendered
 * by {@link formatSymbolicMode} (the one permission formatter in the layer).
 * The `.` and `..` rows are real stats too, not constants.
 * @module @phone-dsh/dsh-shell-ext/ls
 */

import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, FsStat } from 'just-bash/browser'
import { formatSymbolicMode } from './stat.ts'

/** Long-format switches shared by short and long spellings. */
export interface LsOptions {
  readonly showAll: boolean
  readonly showAlmostAll: boolean
  readonly longFormat: boolean
  readonly humanReadable: boolean
  readonly recursive: boolean
  readonly reverse: boolean
  readonly classify: boolean
  readonly directoryOnly: boolean
  /** `size` for `-S`, `time` for `-t`, otherwise `name`; the last flag wins. */
  readonly sort: 'name' | 'size' | 'time'
}

/** One parsed long `ls` invocation. */
export interface LsInvocation {
  readonly options: LsOptions
  readonly operands: readonly string[]
}

/** A spelling the built-in would reject; the built-in owns that diagnostic. */
export class LsUsageError extends Error {}

/** Mutable flag state while scanning argv. */
interface MutableOptions {
  showAll: boolean
  showAlmostAll: boolean
  longFormat: boolean
  humanReadable: boolean
  recursive: boolean
  reverse: boolean
  classify: boolean
  directoryOnly: boolean
  sort: 'name' | 'size' | 'time'
}

/** The long spellings this shim accepts (the built-in's own option table). */
const LONG_OPTIONS: Readonly<Record<string, keyof MutableOptions | 'help'>> = Object.freeze({
  '--all': 'showAll',
  '--almost-all': 'showAlmostAll',
  '--directory': 'directoryOnly',
  '--human-readable': 'humanReadable',
  '--reverse': 'reverse',
  '--recursive': 'recursive',
  '--classify': 'classify',
  '--help': 'help',
})

/**
 * True when argv asks for the long format. Unknown options are ignored here so
 * a malformed invocation keeps the built-in's own error when delegated; a
 * token after `--` is an operand, never an option.
 * @param argv - arguments after the program name.
 * @returns true when a pre-`--` short cluster contains `l`.
 */
export function requestsLongFormat(argv: readonly string[]): boolean {
  let optionsEnded = false
  for (const token of argv) {
    if (optionsEnded) continue
    if (token === '--') {
      optionsEnded = true
      continue
    }
    if (token.startsWith('-') && !token.startsWith('--') && token.length > 1) {
      if (token.slice(1).includes('l')) return true
    }
  }
  return false
}

/**
 * Parse a long-format `ls` argv. `-1` is a no-op for the long layout, exactly
 * as the built-in treats it, and `--help` is handled by the caller by
 * delegating.
 * @param argv - arguments after the program name.
 * @returns the parsed invocation.
 * @throws LsUsageError for a spelling the built-in owns.
 */
export function parseLsArguments(argv: readonly string[]): LsInvocation {
  const options: MutableOptions = {
    showAll: false,
    showAlmostAll: false,
    longFormat: false,
    humanReadable: false,
    recursive: false,
    reverse: false,
    classify: false,
    directoryOnly: false,
    sort: 'name',
  }
  const operands: string[] = []
  let optionsEnded = false
  for (const token of argv) {
    if (optionsEnded) {
      operands.push(token)
      continue
    }
    if (token === '--') {
      optionsEnded = true
      continue
    }
    if (token.startsWith('--')) {
      const name = LONG_OPTIONS[token]
      if (name === undefined || name === 'help') throw new LsUsageError(`ls: unrecognized option '${token}'`)
      // `sort` is not a long spelling; every other member is boolean.
      ;(options as unknown as Record<string, boolean>)[name] = true
      continue
    }
    if (token.startsWith('-') && token !== '-') {
      for (const letter of token.slice(1)) {
        switch (letter) {
          case 'a': options.showAll = true; break
          case 'A': options.showAlmostAll = true; break
          case 'l': options.longFormat = true; break
          case 'h': options.humanReadable = true; break
          case 'R': options.recursive = true; break
          case 'r': options.reverse = true; break
          case 'F': options.classify = true; break
          case 'd': options.directoryOnly = true; break
          case 'S': options.sort = 'size'; break
          case 't': options.sort = 'time'; break
          case '1': break
          default: throw new LsUsageError(`ls: invalid option -- '${letter}'`)
        }
      }
      continue
    }
    operands.push(token)
  }
  return {
    options: {
      showAll: options.showAll,
      showAlmostAll: options.showAlmostAll,
      longFormat: options.longFormat,
      humanReadable: options.humanReadable,
      recursive: options.recursive,
      reverse: options.reverse,
      classify: options.classify,
      directoryOnly: options.directoryOnly,
      sort: options.sort,
    },
    operands,
  }
}

/** The built-in's `-h` size field (base 1024, one decimal below ten). */
function humanSize(size: number): string {
  if (size < 1024) return String(size)
  if (size < 1024 * 1024) {
    const value = size / 1024
    return value < 10 ? `${value.toFixed(1)}K` : `${Math.round(value)}K`
  }
  if (size < 1024 * 1024 * 1024) {
    const value = size / (1024 * 1024)
    return value < 10 ? `${value.toFixed(1)}M` : `${Math.round(value)}M`
  }
  const value = size / (1024 * 1024 * 1024)
  return value < 10 ? `${value.toFixed(1)}G` : `${Math.round(value)}G`
}

/** The built-in's timestamp column (`Mon DD HH:MM` within 180 days, else year). */
function timestamp(mtime: Date): string {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
  const month = months[mtime.getMonth()] as string
  const day = String(mtime.getDate()).padStart(2, ' ')
  const now = new Date()
  const recent = new Date(now.getTime() - 4320 * 60 * 60 * 1000)
  if (mtime > recent) {
    return `${month} ${day} ${String(mtime.getHours()).padStart(2, '0')}:${String(mtime.getMinutes()).padStart(2, '0')}`
  }
  return `${month} ${day}  ${mtime.getFullYear()}`
}

/** The built-in's `-F` indicator. */
function classify(stat: FsStat): string {
  if (stat.isDirectory) return '/'
  if (stat.isSymbolicLink) return '@'
  return (stat.mode & 0o111) !== 0 ? '*' : ''
}

/** One long-format row, with every metadata column read from `stat`. */
function longLine(name: string, stat: FsStat, options: LsOptions): string {
  const size = options.humanReadable ? humanSize(stat.size) : String(stat.size)
  return `${formatSymbolicMode(stat)} 1 user user ${size.padStart(5)} ${timestamp(stat.mtime ?? new Date(0))} ${name}${options.classify ? classify(stat) : ''}\n`
}

/** Sort names the way the built-in does, then reverse for `-r`. */
async function sortEntryNames(
  names: readonly string[],
  directory: string,
  fs: LsContext['fs'],
  options: LsOptions,
): Promise<string[]> {
  const sorted = [...names]
  if (options.sort === 'name') {
    sorted.sort()
  } else {
    const keys = new Map<string, number>()
    for (const name of sorted) {
      try {
        const stat = await fs.lstat(fs.resolvePath(directory, name))
        keys.set(name, options.sort === 'size' ? stat.size : (stat.mtime ?? new Date(0)).getTime())
      } catch {
        keys.set(name, 0)
      }
    }
    sorted.sort((left, right) => {
      const difference = (keys.get(right) ?? 0) - (keys.get(left) ?? 0)
      return difference !== 0 ? difference : left < right ? -1 : left > right ? 1 : 0
    })
  }
  if (options.reverse) sorted.reverse()
  return sorted
}

/** The context members this shim reads (kept narrow for the direct callers). */
interface LsContext {
  readonly fs: {
    resolvePath(cwd: string, path: string): string
    lstat(path: string): Promise<FsStat>
    readdir(path: string): Promise<readonly string[]>
  }
  readonly cwd: string
}

/**
 * A failed operand's built-in wording, with the reason the filesystem actually
 * gave.
 *
 * The built-in hardcodes "No such file or directory" for every read failure,
 * which reports an execution-surface policy denial as absence. `channel.md`
 * §VFS gives exactly one answer for DSH-internal state (`EACCES` plus the
 * remediation line), and `python3` already gives it, so `ls` must not turn the
 * same path into `ENOENT`.
 * @param operand - operand spelling from argv.
 * @param error - failure from `lstat`/`readdir`.
 * @param directoryListing - whether the diagnostic leads with `cannot access`.
 * @returns the stderr line.
 */
function operandFailure(operand: string, error: unknown, directoryListing: boolean): string {
  const reason = failureReason(error)
  return directoryListing
    ? `ls: cannot access '${operand}': ${reason}\n`
    : `ls: ${operand}: ${reason}\n`
}

/** The errno text for one failed read; a policy denial keeps its full sentence. */
function failureReason(error: unknown): string {
  const code = (error as { code?: unknown } | undefined)?.code
  if (code === 'ENOENT') return 'No such file or directory'
  if (code === 'ENOTDIR') return 'Not a directory'
  if (error instanceof Error && error.message !== '') return error.message
  return String(error)
}

/** The subset of the shell filesystem that can answer the exec read policy. */
interface LsPolicyFace {
  resolvePath(cwd: string, path: string): string
  execReadDenial?(path: string): string | undefined
}

/** One operand the execution surface may not read. */
interface DeniedOperand {
  readonly operand: string
  readonly line: string
}

/**
 * Operand tokens of one `ls` argv: every token the built-in would treat as an
 * operand, i.e. not an option and not after a lone `--`. Every option in the
 * pinned just-bash `ls` table is boolean (`-l`, `-R`, `--all`, ...), so the
 * scan never has to know which option would consume a following value.
 * @param argv - arguments after the program name.
 * @returns the operand and option tokens, in argv order.
 */
function scanLsArguments(argv: readonly string[]): { operands: string[]; options: string[] } {
  const operands: string[] = []
  const options: string[] = []
  let optionsEnded = false
  for (const token of argv) {
    if (!optionsEnded && token === '--') {
      optionsEnded = true
      options.push(token)
      continue
    }
    if (!optionsEnded && token.startsWith('-') && token !== '-') {
      options.push(token)
      continue
    }
    operands.push(token)
  }
  return { operands, options }
}

/**
 * Ask the filesystem adapter which operands this execution surface may not
 * read. A shell whose adapter has no policy face (a real directory root, a
 * test double) denies nothing and keeps verbatim POSIX behaviour.
 * @param fs - the command's filesystem.
 * @param cwd - current directory.
 * @param operands - operand tokens from {@link scanLsArguments}.
 * @returns the denied operands with their `EACCES` line.
 */
function deniedOperands(fs: unknown, cwd: string, operands: readonly string[]): DeniedOperand[] {
  const face = fs as Partial<LsPolicyFace>
  if (typeof face.execReadDenial !== 'function' || typeof face.resolvePath !== 'function') return []
  const denied: DeniedOperand[] = []
  for (const operand of operands) {
    let denial: string | undefined
    try {
      denial = face.execReadDenial(face.resolvePath(cwd, operand))
    } catch {
      denial = undefined
    }
    if (denial !== undefined) denied.push({ operand, line: `ls: cannot access '${operand}': ${denial}\n` })
  }
  return denied
}

/** Render one directory (or a single non-directory operand) in long format. */
async function listPath(
  operand: string,
  ctx: LsContext,
  options: LsOptions,
  header: boolean,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const directory = ctx.fs.resolvePath(ctx.cwd, operand)
  let stat: FsStat
  try {
    stat = await ctx.fs.lstat(directory)
  } catch (error) {
    return { stdout: '', stderr: operandFailure(operand, error, false), exitCode: 2 }
  }
  if (!stat.isDirectory) {
    return { stdout: longLine(operand, stat, options), stderr: '', exitCode: 0 }
  }

  let names: string[]
  try {
    names = [...await ctx.fs.readdir(directory)]
  } catch (error) {
    return { stdout: '', stderr: operandFailure(operand, error, false), exitCode: 2 }
  }
  if (!options.showAll && !options.showAlmostAll) names = names.filter(name => !name.startsWith('.'))
  // The built-in sorts the entries first, prepends `.`/`..` for `-a`, and only
  // then applies `-r` to the combined list. It renders the dot rows as their
  // own leading group, so `-a -r` reverses the dot rows (`..`, `.`) and the
  // ordinary rows independently instead of moving the dots to the end. Do not
  // let sortEntryNames reverse the entries a second time.
  names = await sortEntryNames(names, directory, ctx.fs, { ...options, reverse: false })
  if (options.showAll) names = ['.', '..', ...names]
  if (options.reverse) names.reverse()
  const dotRows = names.filter(name => name === '.' || name === '..')
  const entries = names.filter(name => name !== '.' && name !== '..')
  const rows = [...dotRows, ...entries]

  let stdout = ''
  if (options.recursive || header) stdout += `${operand}:\n`
  stdout += `total ${names.length}\n`
  let stderr = ''
  let exitCode = 0
  const childDirectories: string[] = []
  for (const name of rows) {
    try {
      const entry = await ctx.fs.lstat(ctx.fs.resolvePath(directory, name))
      stdout += longLine(name, entry, options)
      if (entry.isDirectory && name !== '.' && name !== '..') childDirectories.push(name)
    } catch (error) {
      // A race between readdir and stat is a real failure, not a fabricated
      // 644/755 row: name it and keep the rest of the listing.
      stderr += `ls: cannot access '${ctx.fs.resolvePath(directory, name)}': ${failureReason(error)}\n`
      exitCode = 2
    }
  }

  if (options.recursive) {
    const ordered = await sortEntryNames(childDirectories, directory, ctx.fs, options)
    for (const name of ordered) {
      const childOperand = operand === '.' ? `./${name}` : `${operand}/${name}`
      const child = await listPath(childOperand, ctx, options, true)
      stdout += `\n${child.stdout}`
      stderr += child.stderr
      if (child.exitCode !== 0) exitCode = child.exitCode
    }
  }
  return { stdout, stderr, exitCode }
}

/** Render a long `ls` invocation. */
async function longListing(invocation: LsInvocation, ctx: LsContext): Promise<ExecResult> {
  const { options } = invocation
  const operands = invocation.operands.length === 0 ? ['.'] : [...invocation.operands]
  let stdout = ''
  let stderr = ''
  let exitCode = 0

  if (options.directoryOnly) {
    const ordered = await sortEntryNames(operands, ctx.cwd, ctx.fs, options)
    for (const operand of ordered) {
      const path = ctx.fs.resolvePath(ctx.cwd, operand)
      try {
        stdout += longLine(operand, await ctx.fs.lstat(path), options)
      } catch (error) {
        stderr += operandFailure(operand, error, true)
        exitCode = 2
      }
    }
    return { stdout, stderr, exitCode }
  }

  const files: string[] = []
  const directories: string[] = []
  for (const operand of operands) {
    const path = ctx.fs.resolvePath(ctx.cwd, operand)
    try {
      const stat = await ctx.fs.lstat(path)
      if (stat.isDirectory) directories.push(operand)
      else files.push(operand)
    } catch (error) {
      stderr += operandFailure(operand, error, false)
      exitCode = 2
    }
  }

  for (const operand of await sortEntryNames(files, ctx.cwd, ctx.fs, options)) {
    const path = ctx.fs.resolvePath(ctx.cwd, operand)
    try {
      stdout += longLine(operand, await ctx.fs.lstat(path), options)
    } catch (error) {
      stderr += operandFailure(operand, error, false)
      exitCode = 2
    }
  }

  const header = operands.length > 1 || options.recursive
  for (const operand of await sortEntryNames(directories, ctx.cwd, ctx.fs, options)) {
    if (stdout !== '') stdout += '\n'
    const listing = await listPath(operand, ctx, options, header)
    stdout += listing.stdout
    stderr += listing.stderr
    if (listing.exitCode !== 0) exitCode = listing.exitCode
  }
  return { stdout, stderr, exitCode }
}

/**
 * Build the `ls` custom command that shadows the built-in's long format.
 *
 * A non-long invocation (including `--help` and every non-`-l` option
 * spelling) is delegated to `ctx.origCommand`, so its output and diagnostics
 * stay byte-identical — except for one deliberate difference: an operand the
 * execution surface may not read is answered with the contract's `EACCES`
 * remediation line here, before delegation. The built-in words every read
 * failure as "No such file or directory", so delegating a denied operand
 * would report DSH-internal state as absent while `python3` reports `EACCES`
 * for the same path (`channel.md` §VFS has one answer).
 * @returns the `ls` command definition.
 */
export function createLsCommand(): Command {
  return defineCommand('ls', async (args, ctx): Promise<ExecResult> => {
    const runListing = async (argv: readonly string[]): Promise<ExecResult> => {
      let invocation: LsInvocation
      try {
        invocation = parseLsArguments(argv)
      } catch (error) {
        if (!(error instanceof LsUsageError)) throw error
        // The built-in owns the option diagnostics; it raises them before it
        // ever formats a row, so delegation cannot revive the hardcoded mode.
        if (ctx.origCommand === undefined) return { stdout: '', stderr: `${error.message}\n`, exitCode: 1 }
        return await ctx.origCommand([...argv])
      }
      if (!invocation.options.longFormat) {
        if (ctx.origCommand === undefined) return { stdout: '', stderr: 'ls: the built-in ls is unavailable in this shell\n', exitCode: 1 }
        return await ctx.origCommand([...argv])
      }
      return await longListing(invocation, ctx as unknown as LsContext)
    }

    const denied = deniedOperands(ctx.fs, ctx.cwd, scanLsArguments(args).operands)
    if (denied.length === 0) return await runListing(args)

    const stderr = denied.map(entry => entry.line).join('')
    // Mixed operands keep their normal listing: only the denied tokens leave
    // argv, so `ls /dsh/workspace /dsh/home/sessions` still lists the tree it
    // is allowed to see and answers `EACCES` for the one it is not.
    const deniedTokens = new Set(denied.map(entry => entry.operand))
    const allowedArgv = args.filter(token => !deniedTokens.has(token))
    if (scanLsArguments(allowedArgv).operands.length === 0) return { stdout: '', stderr, exitCode: 2 }
    const listed = await runListing(allowedArgv)
    return {
      stdout: listed.stdout,
      stderr: `${stderr}${listed.stderr}`,
      exitCode: Math.max(listed.exitCode, 2),
    }
  })
}
