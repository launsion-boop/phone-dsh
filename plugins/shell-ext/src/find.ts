// SPDX-License-Identifier: MIT
/**
 * The Worker shell's `find` shim: POSIX `-type` plus GNU `-printf`.
 *
 * `find` is a just-bash built-in program (Apache-2.0, imported unmodified). It
 * has two Worker-visible gaps:
 *
 * 1. its predicate parser accepts only `-type f` and `-type d`; every other
 *    POSIX type letter and every comma-separated list (b,c,d,f,l,p,s) exits 1
 *    with `find: Unknown argument to -type` (fixed here since G2-FIX-11);
 * 2. its `-printf` formatter expands only `%P` and the `\n`/`\t` escapes —
 *    every other directive is copied to stdout as literal text with exit 0.
 *    G2-A01's `find . -printf '%P\t%y\n'` printed a literal `%y` for every
 *    entry, so a directory-vs-file listing silently lied.
 *
 * This module shadows the built-in through just-bash's custom-command table
 * (custom commands are registered after bundled ones, so the custom command
 * wins). It never re-implements traversal or matching: the argv keeps every
 * predicate and action and the shadowed built-in does the search. The shim
 * only rewrites what the built-in cannot say:
 *
 * - `-type` words are narrowed to the letters the symlink-free VFS can hold
 *   (`f`, `d`), a mixed list becomes `\( -type f -o -type d \)`, and a list of
 *   impossible letters becomes `-name ''` (no name is empty, so it never
 *   matches);
 * - a single `-printf FORMAT` becomes `-print0` and the shim renders the format
 *   itself for every matched path, so `%y`, `%Y`, `%s`, `%m`, `%M`, `%p`,
 *   `%P`, `%f`, `%h`, `%d`, `%i`, `%n`, `%b`, `%k`, `%u`, `%g`, `%U`, `%G`,
 *   `%l`, `%t`, `%T@`, `%a` and `%c` all expand from `FsStat`. An unsupported
 *   directive fails loud with `find: unsupported format directive '%q'` and
 *   exit 1 — the same never-silently-lie rule as the `stat -c` shim.
 *
 * Multiple `-printf` actions in one expression are refused rather than guessed
 * at: the shim can only tell which matched path produced a `-print0` line, not
 * which alternative branch produced it. All other argv — including `-exec`
 * command words — is passed through untouched.
 * @module @phone-dsh/dsh-shell-ext/find
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, FsStat, IFileSystem } from 'just-bash/browser'
import { shellFailure } from './contract.ts'
import { WORKER_STAT_FALLBACKS, formatStatTime } from './stat.ts'

/** The POSIX `-type` letters the Worker shim accepts. */
export const POSIX_FIND_TYPE_LETTERS: readonly string[] = Object.freeze(['b', 'c', 'd', 'f', 'l', 'p', 's'])

/** GNU `find -printf` directives this shim expands. */
export const FIND_PRINTF_DIRECTIVES: readonly string[] = Object.freeze([
  'a', 'b', 'c', 'd', 'f', 'g', 'h', 'i', 'k', 'l', 'm', 'M', 'n',
  'p', 'P', 's', 't', 'u', 'U', 'G', 'y', 'Y', 'H', 'T',
])

/** Letters that can exist in the Worker VFS. */
const WORKER_FIND_TYPE_LETTERS: ReadonlySet<string> = new Set(['f', 'd'])

/** Leading `find` options that do not start the expression. */
const FIND_LEADING_OPTIONS: ReadonlySet<string> = new Set(['-L', '-H', '-P'])

/**
 * `find` predicates that consume the next argv word as a value. The scanner
 * must not mistake such a value for a `-type` predicate.
 */
const FIND_VALUE_OPTIONS: ReadonlySet<string> = new Set([
  '-name',
  '-iname',
  '-path',
  '-ipath',
  '-regex',
  '-iregex',
  '-mtime',
  '-newer',
  '-size',
  '-perm',
  '-maxdepth',
  '-mindepth',
  '-printf',
])

/** Actions whose command words run until `;` or `+`. */
const FIND_EXEC_ACTIONS: ReadonlySet<string> = new Set(['-exec', '-execdir', '-ok', '-okdir'])

/** An option combination the shim cannot honour without guessing. */
export class FindFormatError extends Error {
  /**
   * @param message - diagnostic body (without the `find: ` prefix).
   */
  constructor(message: string) {
    super(message)
    this.name = 'FindFormatError'
  }
}

/** True when `token` starts the expression in just-bash's `find` scanner. */
function startsFindExpression(token: string): boolean {
  return token.startsWith('-') || token === '(' || token === '\\(' || token === ')' || token === '\\)' || token === '!'
}

/** Index of the first expression token (leading `-L`/`-H`/`-P` skipped). */
function expressionIndex(argv: readonly string[]): number {
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string
    if (FIND_LEADING_OPTIONS.has(token)) continue
    if (startsFindExpression(token)) return index
  }
  return argv.length
}

/**
 * Rewrite the `-type` predicates of one `find` argv for just-bash's built-in.
 *
 * Returns `undefined` when the argv can go to the built-in unchanged: no
 * predicate needed rewriting, the expression is malformed (`-type` without a
 * value) or a type value is outside the POSIX set (the built-in's own error is
 * the contract for those).
 * @param argv - the arguments `find` received, without the program name.
 * @returns a copy with the `-type` words rewritten, or `undefined`.
 */
export function rewriteFindTypeArguments(argv: readonly string[]): string[] | undefined {
  const expression = expressionIndex(argv)
  const rewritten: string[] = argv.slice(0, expression)
  let changed = false
  for (let index = expression; index < argv.length; index += 1) {
    const token = argv[index] as string
    if (token === '-type') {
      const value = argv[index + 1]
      if (value === undefined) return undefined
      const letters = value.split(',')
      if (letters.some(letter => !POSIX_FIND_TYPE_LETTERS.includes(letter))) return undefined
      const possible = new Set(letters.filter(letter => WORKER_FIND_TYPE_LETTERS.has(letter)))
      if (possible.size === 0) {
        rewritten.push('-name', '')
        changed = true
      } else if (possible.size === 1) {
        const only = [...possible][0] as string
        rewritten.push('-type', only)
        changed ||= only !== value
      } else {
        // `f,d` is exactly every entry in a filesystem with no other types.
        rewritten.push('(', '-type', 'f', '-o', '-type', 'd', ')')
        changed = true
      }
      index += 1
      continue
    }
    if (FIND_EXEC_ACTIONS.has(token)) {
      // `-type` and friends inside the executed command are child argv.
      rewritten.push(token)
      index += 1
      while (index < argv.length) {
        const word = argv[index] as string
        rewritten.push(word)
        if (word === ';' || word === '+') break
        index += 1
      }
      continue
    }
    rewritten.push(token)
    if (FIND_VALUE_OPTIONS.has(token)) {
      index += 1
      if (index < argv.length) rewritten.push(argv[index] as string)
    }
  }
  return changed ? rewritten : undefined
}

/** One `find` invocation after the shim's rewrites. */
export interface FindPlan {
  /** argv for the shadowed built-in. */
  readonly args: string[]
  /** `-printf` format to render, or undefined when the built-in prints. */
  readonly format: string | undefined
  /** Starting-point operands, in command-line order. */
  readonly startingPoints: readonly string[]
}

/**
 * Plan one `find` invocation: rewrite `-type` and one `-printf`.
 * @param argv - arguments after the program name.
 * @returns the rewritten argv and the format to render, or undefined when no
 *   rewrite is needed.
 * @throws FindFormatError for multiple `-printf` actions.
 */
export function planFindInvocation(argv: readonly string[]): FindPlan | undefined {
  const typeRewrite = rewriteFindTypeArguments(argv)
  const typed = typeRewrite ?? [...argv]
  const expression = expressionIndex(typed)
  const declared = typed.slice(0, expression).filter(token => !FIND_LEADING_OPTIONS.has(token))
  // GNU's implicit starting point when no operand is given is `.`.
  const startingPoints = declared.length > 0 ? declared : ['.']
  let format: string | undefined
  const args: string[] = typed.slice(0, expression)
  let changed = typeRewrite !== undefined
  for (let index = expression; index < typed.length; index += 1) {
    const token = typed[index] as string
    if (token === '-printf') {
      const value = typed[index + 1]
      if (value === undefined) {
        // Let the built-in report the missing argument.
        args.push(token)
        continue
      }
      if (format !== undefined) {
        throw new FindFormatError('multiple -printf actions are not supported by the Worker shim')
      }
      format = value
      args.push('-print0')
      index += 1
      changed = true
      continue
    }
    if (FIND_EXEC_ACTIONS.has(token)) {
      args.push(token)
      index += 1
      while (index < typed.length) {
        const word = typed[index] as string
        args.push(word)
        if (word === ';' || word === '+') break
        index += 1
      }
      continue
    }
    args.push(token)
    if (FIND_VALUE_OPTIONS.has(token)) {
      index += 1
      if (index < typed.length) args.push(typed[index] as string)
    }
  }
  if (format === undefined) return changed ? { args, format, startingPoints } : undefined
  return { args, format, startingPoints }
}

/** Everything one matched path contributes to a `-printf` format. */
export interface FindFormatEntry {
  /** The path exactly as `find` printed it (`%p`). */
  readonly path: string
  /** Starting point the path was found under (`%H`). */
  readonly startingPoint: string
  /** Path with the starting point removed (`%P`). */
  readonly relative: string
  /** Components below the starting point (`%d`). */
  readonly depth: number
  readonly stat: FsStat
  /** Symlink target, when the entry is a symlink (`%l`). */
  readonly linkTarget?: string
  /** Type letter for a symlink's target (`%Y`). */
  readonly targetType?: string
}

/** The ctime-shaped timestamp GNU find uses for `%t`, `%a` and `%c`. */
function ctimeText(date: Date): string {
  const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
  const pad = (value: number): string => String(value).padStart(2, '0')
  return `${weekdays[date.getDay()] as string} ${months[date.getMonth()] as string} ${String(date.getDate()).padStart(2, ' ')} `
    + `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())} ${String(date.getFullYear())}`
}

/** The `%y`/`%Y` file-type letter of a stat result. */
function typeLetter(stat: FsStat): string {
  if (stat.isSymbolicLink) return 'l'
  if (stat.isDirectory) return 'd'
  if (stat.isFile) return 'f'
  const kind = stat.mode & 0o170000
  if (kind === 0o020000) return 'c'
  if (kind === 0o060000) return 'b'
  if (kind === 0o010000) return 'p'
  if (kind === 0o140000) return 's'
  return '?'
}

/** The symbolic permission column for `%M`. */
function symbolicMode(stat: FsStat): string {
  const bits = stat.mode
  const kind = stat.isDirectory ? 'd' : stat.isSymbolicLink ? 'l' : '-'
  const triple = (shift: number): string => {
    const read = (bits & (4 << shift)) !== 0 ? 'r' : '-'
    const write = (bits & (2 << shift)) !== 0 ? 'w' : '-'
    const execute = (bits & (1 << shift)) !== 0 ? 'x' : '-'
    return `${read}${write}${execute}`
  }
  return `${kind}${triple(6)}${triple(3)}${triple(0)}`
}

/** Render one directive without width handling. */
function renderDirective(code: string, entry: FindFormatEntry, modifier: string | undefined): string {
  switch (code) {
    case 'a':
    case 'c':
    case 't': return ctimeText(entry.stat.mtime)
    case 'b': return String(Math.ceil(entry.stat.size / 512))
    case 'd': return String(entry.depth)
    case 'f': return posix.basename(entry.path)
    case 'g': return WORKER_STAT_FALLBACKS.groupName
    case 'G': return WORKER_STAT_FALLBACKS.gid
    case 'h': return posix.dirname(entry.path)
    case 'H': return entry.startingPoint
    case 'i': return String(entry.stat.ino ?? 0)
    case 'k': return String(Math.ceil(entry.stat.size / 1024))
    case 'l': return entry.linkTarget ?? ''
    case 'm': return (entry.stat.mode & 0o7777).toString(8)
    case 'M': return symbolicMode(entry.stat)
    case 'n': return WORKER_STAT_FALLBACKS.hardLinks
    case 'p': return entry.path
    case 'P': return entry.relative
    case 's': return String(entry.stat.size)
    case 'u': return WORKER_STAT_FALLBACKS.userName
    case 'U': return WORKER_STAT_FALLBACKS.uid
    case 'y': return typeLetter(entry.stat)
    case 'Y': return entry.targetType ?? typeLetter(entry.stat)
    case 'T':
      if (modifier === '@') return String(entry.stat.mtime.getTime() / 1000)
      if (modifier === '+') return formatStatTime(entry.stat.mtime)
      if (modifier === 'k') return `${String(entry.stat.mtime.getHours()).padStart(2, '0')}:${String(entry.stat.mtime.getMinutes()).padStart(2, '0')}`
      return ctimeText(entry.stat.mtime)
    default: throw new FindFormatError(`unsupported format directive '%${code}'`)
  }
}

/**
 * Expand one GNU `find -printf` format for one matched path.
 *
 * Supported escapes are `\a \b \c \f \n \r \t \v \\ \0`; a directive outside
 * {@link FIND_PRINTF_DIRECTIVES} throws {@link FindFormatError} before the
 * output is returned. Field width and `-`/`0` flags are honoured.
 * @param format - the `-printf` value.
 * @param entry - the matched path and its metadata.
 * @returns the rendered text.
 */
export function renderFindFormat(format: string, entry: FindFormatEntry): string {
  let output = ''
  let stopped = false
  for (let index = 0; index < format.length && !stopped; index += 1) {
    const character = format[index] as string
    if (character === '\\') {
      const escape = format[index + 1]
      if (escape === undefined) {
        output += '\\'
        continue
      }
      index += 1
      switch (escape) {
        case 'a': output += '\x07'; break
        case 'b': output += '\b'; break
        case 'c': stopped = true; break
        case 'f': output += '\f'; break
        case 'n': output += '\n'; break
        case 'r': output += '\r'; break
        case 't': output += '\t'; break
        case 'v': output += '\v'; break
        case '0': output += '\0'; break
        case '\\': output += '\\'; break
        default: output += escape; break
      }
      continue
    }
    if (character !== '%') {
      output += character
      continue
    }
    index += 1
    let left = false
    let zero = false
    let width = ''
    for (; index < format.length; index += 1) {
      const flag = format[index] as string
      if (flag === '-') left = true
      else if (flag === '0') zero = true
      else if (flag === ' ' || flag === '+' || flag === '#') continue
      else break
    }
    for (; index < format.length; index += 1) {
      const digit = format[index] as string
      if (digit < '0' || digit > '9') break
      width += digit
    }
    if (format[index] === '.') {
      index += 1
      while (index < format.length) {
        const digit = format[index] as string
        if (digit < '0' || digit > '9') break
        index += 1
      }
    }
    const code = format[index]
    if (code === undefined) throw new FindFormatError("unsupported format directive '%'")
    if (code === '%') {
      output += '%'
      continue
    }
    if (!FIND_PRINTF_DIRECTIVES.includes(code)) throw new FindFormatError(`unsupported format directive '%${code}'`)
    let modifier: string | undefined
    if (code === 'T') {
      const next = format[index + 1]
      // GNU's `%T` takes a one-letter suffix; only the timestamp forms this
      // shim can answer are accepted, every other one fails loud.
      if (next !== undefined && /[A-Za-z@+]/u.test(next)) {
        index += 1
        if (next !== '@' && next !== '+' && next !== 'k') {
          throw new FindFormatError(`unsupported format directive '%T${next}'`)
        }
        modifier = next
      }
    }
    let value = renderDirective(code, entry, modifier)
    const numeric = /^-?\d+$/u.test(value)
    const target = Number(width === '' ? 0 : width)
    if (value.length < target) {
      const fill = zero && !left && numeric ? '0' : ' '
      value = left ? value.padEnd(target, ' ') : value.padStart(target, fill)
    }
    output += value
  }
  return output
}

/** A filesystem entry as the find shim looks it up. */
async function describeEntry(
  fs: Pick<IFileSystem, 'lstat' | 'readlink' | 'stat'>,
  cwd: string,
  path: string,
  startingPoint: string,
  relative: string,
  depth: number,
): Promise<FindFormatEntry> {
  const absolute = posix.resolve(cwd, path)
  const stat = await fs.lstat(absolute)
  if (!stat.isSymbolicLink) return { path, startingPoint, relative, depth, stat }
  let linkTarget: string | undefined
  let targetType: string | undefined
  try {
    linkTarget = await fs.readlink(absolute)
    targetType = typeLetter(await fs.stat(absolute))
  } catch {
    targetType = 'N'
  }
  return { path, startingPoint, relative, depth, stat, linkTarget, targetType }
}

/** Remove one starting-point prefix from a printed path. */
function relativeTo(startingPoints: readonly string[], path: string): { startingPoint: string; relative: string; depth: number } {
  const ordered = [...startingPoints].sort((left, right) => right.length - left.length)
  for (const start of ordered) {
    const normalized = start.length > 1 && start.endsWith('/') ? start.slice(0, -1) : start
    if (path === normalized) return { startingPoint: start, relative: '', depth: 0 }
    if (normalized === '/') {
      if (path.startsWith('/')) {
        const relative = path.replace(/^\/+/, '')
        return { startingPoint: start, relative, depth: relative === '' ? 0 : relative.split('/').length }
      }
      continue
    }
    if (normalized === '.') {
      if (path.startsWith('./')) {
        const relative = path.slice(2)
        return { startingPoint: start, relative, depth: relative === '' ? 0 : relative.split('/').length }
      }
      if (path === '.') return { startingPoint: start, relative: '', depth: 0 }
      continue
    }
    if (path.startsWith(`${normalized}/`)) {
      const relative = path.slice(normalized.length + 1)
      return { startingPoint: start, relative, depth: relative === '' ? 0 : relative.split('/').length }
    }
  }
  const relative = path.replace(/^\.\//u, '')
  return { startingPoint: '.', relative, depth: relative === '' ? 0 : relative.split('/').length }
}

/**
 * Build the `find` custom command that shadows just-bash's built-in.
 *
 * Traversal, predicates and actions stay in the built-in; the shim rewrites
 * `-type` and renders one `-printf` from `FsStat`.
 * @returns the `find` command definition.
 */
export function createFindCommand(): Command {
  return defineCommand('find', async (args, ctx): Promise<ExecResult> => {
    if (ctx.origCommand === undefined) {
      return shellFailure('find', 'find: the built-in find is unavailable in this shell', 'backend-failed')
    }
    let plan: FindPlan | undefined
    try {
      plan = planFindInvocation(args)
    } catch (error) {
      // The shim's own -printf surface is a usage boundary: an action it
      // cannot render is exit 2, never exit 1 or a literal echo.
      return shellFailure('find', `find: ${error instanceof Error ? error.message : String(error)}`, 'unsupported-option')
    }
    if (plan === undefined) return await ctx.origCommand(args)
    if (plan.format === undefined) return await ctx.origCommand(plan.args)
    const result = await ctx.origCommand(plan.args)
    const paths = result.stdout.split('\0')
    if (paths.length > 0 && paths[paths.length - 1] === '') paths.pop()
    let output = ''
    try {
      for (const path of paths) {
        const place = relativeTo(plan.startingPoints, path)
        const entry = await describeEntry(ctx.fs, ctx.cwd, path, place.startingPoint, place.relative, place.depth)
        output += renderFindFormat(plan.format, entry)
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return shellFailure('find', `${result.stderr}find: ${message}`, 'unsupported-option')
    }
    return { stdout: output, stderr: result.stderr, exitCode: result.exitCode }
  })
}
