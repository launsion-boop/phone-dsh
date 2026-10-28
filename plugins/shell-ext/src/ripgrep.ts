// SPDX-License-Identifier: MIT
/**
 * The Worker's `rg` shim: ripgrep/globset semantics for the DSH search tools.
 *
 * DSH's `glob` and `grep` tools spawn the packaged ripgrep by absolute path.
 * When the host does not advertise `accelerator:rg`, `subprocess-xl` routes
 * that spawn to the Worker shell, where just-bash's built-in `rg` would serve
 * it. The built-in implements a smaller glob dialect: its `**` always spans at
 * least one path component (`**\/*.py` misses root-level files) and it matches
 * `--glob` values against both the basename and the path with a private
 * translation, so a paired VCS exclude such as `!**\/.git` /
 * `!**\/.git\/**` never matches. The search then exits successfully with an
 * empty result, which DSH reports as "No files found".
 *
 * This module shadows the built-in the same way `find.ts` does: only a search
 * with `--files`/`--json` and at least one `--glob`/`--iglob` is intercepted.
 * The built-in still does traversal, ignore handling, regex matching and JSON
 * encoding; this shim removes the glob arguments (and the Worker-incompatible
 * `--no-config` / `--` transport flags) from the delegated argv and applies
 * the ripgrep globset contract to the resulting paths:
 *
 * - a glob without `/` matches a basename at any depth;
 * - a glob with `/` is rooted at the search path;
 * - `**\/` matches zero or more complete path components;
 * - `**`, `*`, `?`, character classes and `{a,b}` alternation follow the
 *   globset translation;
 * - include and `!` exclude globs combine, with the later glob winning;
 * - an excluded directory prunes its contents, so `!**\/.git` alone keeps VCS
 *   metadata out while `.github` stays visible.
 *
 * Invalid globs fail loud with ripgrep's `error parsing glob` wording, which
 * DSH classifies as `SEARCH_INVALID_PATTERN` instead of a clean empty result.
 * @module @phone-dsh/dsh-shell-ext/ripgrep
 */

import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, ResolvedCommandContext } from 'just-bash/browser'
import { shellFailure } from './contract.ts'

/** One `--glob`/`--iglob` value after prefix parsing. */
export interface RipgrepGlobPattern {
  /** Glob text with the leading `!` still intact. */
  readonly pattern: string
  /** True for `--iglob` (or under `--glob-case-insensitive`). */
  readonly caseInsensitive?: boolean
}

/** A parsed Worker-local search whose globs the shim must apply itself. */
export interface ParsedRipgrepGlobs {
  /** Glob arguments in command-line order. */
  readonly patterns: readonly RipgrepGlobPattern[]
  /** The argv to delegate to the built-in, without glob arguments. */
  readonly argv: readonly string[]
  /** Requested ordering (`modified` was translated to `none` for the built-in). */
  readonly sort: 'path' | 'none' | 'modified' | undefined
  /** `--files` was requested. */
  readonly files: boolean
  /** `--json` was requested. */
  readonly json: boolean
}

/** A glob that cannot be translated to ripgrep's dialect. */
export class RipgrepGlobError extends Error {
  /** The offending glob text. */
  readonly glob: string

  /**
   * @param glob - the offending glob text.
   * @param message - the ripgrep-style detail.
   */
  constructor(glob: string, message: string) {
    super(message)
    this.name = 'RipgrepGlobError'
    this.glob = glob
  }
}

/** A positive or negated glob compiled to a matcher. */
interface CompiledGlob {
  readonly negated: boolean
  readonly directoryOnly: boolean
  readonly regex: RegExp
}

/** Escape one character for a regular expression literal. */
function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')
}

/** True when a glob has an unescaped `/` (which roots it). */
function hasUnescapedSlash(pattern: string): boolean {
  let escaped = false
  for (const character of pattern) {
    if (escaped) {
      escaped = false
      continue
    }
    if (character === '\\') {
      escaped = true
      continue
    }
    if (character === '/') return true
  }
  return false
}

/** Split a brace alternation at its top-level commas. */
function splitAlternatives(body: string): string[] {
  const parts: string[] = []
  let start = 0
  let depth = 0
  let escaped = false
  for (let index = 0; index < body.length; index += 1) {
    const character = body[index] as string
    if (escaped) {
      escaped = false
      continue
    }
    if (character === '\\') {
      escaped = true
      continue
    }
    if (character === '{') depth += 1
    else if (character === '}') depth -= 1
    else if (character === ',' && depth === 0) {
      parts.push(body.slice(start, index))
      start = index + 1
    }
  }
  parts.push(body.slice(start))
  return parts
}

/**
 * Expand `{a,b}` alternations into plain globs. A brace group without a
 * top-level comma is literal, matching globset's treatment of `{word}`.
 * @param pattern - the glob text after `!`/trailing-slash processing.
 * @returns one or more brace-free globs.
 */
function expandBraces(pattern: string): string[] {
  let start = -1
  let escaped = false
  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index] as string
    if (escaped) {
      escaped = false
      continue
    }
    if (character === '\\') {
      escaped = true
      continue
    }
    if (character === '{') {
      start = index
      break
    }
  }
  if (start === -1) return [pattern]

  let depth = 0
  let end = -1
  let comma = false
  escaped = false
  for (let index = start; index < pattern.length; index += 1) {
    const character = pattern[index] as string
    if (escaped) {
      escaped = false
      continue
    }
    if (character === '\\') {
      escaped = true
      continue
    }
    if (character === '{') depth += 1
    else if (character === '}') {
      depth -= 1
      if (depth === 0) {
        end = index
        break
      }
    } else if (character === ',' && depth === 1) {
      comma = true
    }
  }
  if (end === -1) throw new RipgrepGlobError(pattern, 'unclosed alternate group')
  if (!comma) {
    // Literal braces: translate them as ordinary characters.
    const before = pattern.slice(0, start)
    const after = pattern.slice(start + 1)
    return expandBraces(`${before}\\{${after}`)
  }
  const body = pattern.slice(start + 1, end)
  const before = pattern.slice(0, start)
  const after = pattern.slice(end + 1)
  return splitAlternatives(body).flatMap(alternative => expandBraces(`${before}${alternative}${after}`))
}

/** Translate one brace-free glob body to a regular-expression source. */
function translateGlob(pattern: string): string {
  let source = ''
  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index] as string
    if (character === '\\') {
      index += 1
      const escaped = pattern[index]
      if (escaped === undefined) throw new RipgrepGlobError(pattern, 'trailing escape')
      source += escapeRegExp(escaped)
      continue
    }
    if (character === '*') {
      const starStart = index
      let stars = 0
      while (pattern[index] === '*') {
        stars += 1
        index += 1
      }
      const starEnd = index
      const componentStart = starStart === 0 || pattern[starStart - 1] === '/'
      const componentEnd = starEnd === pattern.length || pattern[starEnd] === '/'
      if (stars >= 2 && componentStart && componentEnd) {
        if (pattern[starEnd] === '/') {
          // `**/` matches zero or more complete path components.
          source += '(?:[^/]+/)*'
          index = starEnd + 1
        } else {
          // A trailing `**` component spans the rest of the path.
          source += '.*'
          index = starEnd
        }
      } else {
        // Adjacent stars outside a whole path component are one `*`: they
        // never cross a `/`.
        source += '[^/]*'
        index = starEnd
      }
      index -= 1
      continue
    }
    if (character === '?') {
      source += '[^/]'
      continue
    }
    if (character === '[') {
      let cursor = index + 1
      let negated = false
      if (pattern[cursor] === '!' || pattern[cursor] === '^') {
        negated = true
        cursor += 1
      }
      let content = ''
      let first = true
      for (; cursor < pattern.length; cursor += 1) {
        const member = pattern[cursor] as string
        if (member === ']' && !first) break
        if (member === '\\') {
          cursor += 1
          const escaped = pattern[cursor]
          if (escaped === undefined) throw new RipgrepGlobError(pattern, 'trailing escape in character class')
          content += `\\${escaped}`
        } else if (member === '^' && !first) {
          content += '\\^'
        } else if (member === ']' && first) {
          content += '\\]'
        } else {
          content += member
        }
        first = false
      }
      if (cursor >= pattern.length) throw new RipgrepGlobError(pattern, 'unclosed character class')
      source += `[${negated ? '^' : ''}${content}]`
      index = cursor
      continue
    }
    source += character === '/' ? '/' : escapeRegExp(character)
  }
  return source
}

/** Compile one `--glob` value into a matcher. */
function compileGlob(value: string, caseInsensitive: boolean): CompiledGlob {
  let pattern = value
  let negated = false
  if (pattern.startsWith('\\!')) pattern = pattern.slice(1)
  else if (pattern.startsWith('!')) {
    negated = true
    pattern = pattern.slice(1)
  }
  let directoryOnly = false
  if (pattern.endsWith('/')) {
    directoryOnly = true
    pattern = pattern.replace(/\/+$/u, '')
  }
  while (pattern.startsWith('./')) pattern = pattern.slice(2)
  let rooted = hasUnescapedSlash(pattern)
  if (pattern.startsWith('/')) {
    rooted = true
    pattern = pattern.slice(1)
  }
  const expanded = expandBraces(pattern).map(translateGlob)
  const body = expanded.length === 1 ? (expanded[0] as string) : `(?:${expanded.join('|')})`
  const regex = new RegExp(rooted ? `^${body}$` : `(?:^|/)${body}$`, caseInsensitive ? 'iu' : 'u')
  return { negated, directoryOnly, regex }
}

/** Normalise a delegated output path for glob matching. */
function normalizeMatchPath(path: string): string {
  let normalized = path
  while (normalized.startsWith('./')) normalized = normalized.slice(2)
  normalized = normalized.replace(/^\/+/u, '')
  return normalized
}

/** The directory paths above one normalised path, nearest-last. */
function ancestorDirectories(path: string): string[] {
  const parts = path.split('/')
  const ancestors: string[] = []
  let current = ''
  for (let index = 0; index < parts.length - 1; index += 1) {
    const part = parts[index] as string
    if (part === '') continue
    current = current === '' ? part : `${current}/${part}`
    ancestors.push(current)
  }
  return ancestors
}

/**
 * Ordered include/exclude globs with ripgrep's later-glob-wins precedence.
 *
 * A glob without `/` matches basenames at any depth; a glob with `/` is rooted.
 * With at least one positive glob the default is "excluded"; with only
 * negated globs the default is "included". A negated glob that matches a
 * directory prunes that directory's contents.
 */
export class RipgrepGlobSet {
  private readonly globs: readonly CompiledGlob[]
  private readonly hasPositive: boolean

  /**
   * @param patterns - glob arguments in command-line order.
   * @throws {@link RipgrepGlobError} when a glob is syntactically invalid.
   */
  constructor(patterns: readonly RipgrepGlobPattern[]) {
    this.globs = patterns.map(entry => compileGlob(entry.pattern, entry.caseInsensitive === true))
    this.hasPositive = this.globs.some(glob => !glob.negated)
  }

  /** The last glob matching a path (or directory), if any. */
  private lastMatch(path: string, directory: boolean): CompiledGlob | undefined {
    let matched: CompiledGlob | undefined
    for (const glob of this.globs) {
      if (glob.directoryOnly && !directory) continue
      if (glob.regex.test(path)) matched = glob
    }
    return matched
  }

  /** True when the path is selected by the include/exclude combination. */
  matches(path: string): boolean {
    const normalized = normalizeMatchPath(path)
    for (const ancestor of ancestorDirectories(normalized)) {
      if (this.lastMatch(ancestor, true)?.negated === true) return false
    }
    const last = this.lastMatch(normalized, false)
    if (last !== undefined) return !last.negated
    return !this.hasPositive
  }
}

/** One parsed glob argument and how many argv elements it consumed. */
interface GlobArgument {
  readonly value: string
  readonly consumed: number
  readonly caseInsensitive: boolean
}

/** Read a `--glob`/`--iglob`/`-g` argument at one index. */
function readGlobArgument(args: readonly string[], index: number): GlobArgument | undefined {
  const argument = args[index]
  if (argument === undefined) return undefined
  if (argument === '--glob' || argument === '-g') {
    const value = args[index + 1]
    return value === undefined ? undefined : { value, consumed: 2, caseInsensitive: false }
  }
  if (argument.startsWith('--glob=')) {
    return { value: argument.slice('--glob='.length), consumed: 1, caseInsensitive: false }
  }
  if (argument === '--iglob') {
    const value = args[index + 1]
    return value === undefined ? undefined : { value, consumed: 2, caseInsensitive: true }
  }
  if (argument.startsWith('--iglob=')) {
    return { value: argument.slice('--iglob='.length), consumed: 1, caseInsensitive: true }
  }
  if (argument.startsWith('-g') && !argument.startsWith('--') && argument.length > 2) {
    return { value: argument.slice(2), consumed: 1, caseInsensitive: false }
  }
  return undefined
}

/** Read a `--sort` argument that this shim can apply itself. */
function readSortArgument(args: readonly string[], index: number): { value: 'path' | 'none' | 'modified'; consumed: number } | undefined {
  const argument = args[index]
  if (argument === undefined) return undefined
  const value = argument === '--sort'
    ? args[index + 1]
    : argument.startsWith('--sort=') ? argument.slice('--sort='.length) : undefined
  if (value !== 'path' && value !== 'none' && value !== 'modified') return undefined
  return { value, consumed: argument === '--sort' ? 2 : 1 }
}

/**
 * Parse a Worker-local search whose globs this shim has to apply.
 *
 * Returns `undefined` when the argv has no glob or is neither `--files` nor
 * `--json` grep, so every other `rg` invocation keeps the built-in's behavior.
 * Glob arguments are removed from {@link ParsedRipgrepGlobs.argv}; `--` and
 * `--no-config` are removed because just-bash has no end-of-options marker and
 * no config files; `--sort=modified` is translated to `--sort=none` and
 * re-applied after filtering.
 * @param args - `rg` arguments without the program name.
 * @returns the parsed glob search, or undefined to delegate unchanged.
 */
export function parseRipgrepGlobs(args: readonly string[]): ParsedRipgrepGlobs | undefined {
  const patterns: RipgrepGlobPattern[] = []
  const argv: string[] = []
  let files = false
  let json = false
  let sort: 'path' | 'none' | 'modified' | undefined
  let globCaseInsensitive = false
  let endOfOptions = false
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index] as string
    if (endOfOptions) {
      argv.push(argument)
      continue
    }
    if (argument === '--') {
      endOfOptions = true
      continue
    }
    // DSH prepends ripgrep's config-file guard. The Worker shell has no
    // config files, so the flag is a no-op there and just-bash rejects it.
    if (argument === '--no-config') continue
    if (argument === '--files') {
      files = true
      argv.push(argument)
      continue
    }
    if (argument === '--json') {
      json = true
      argv.push(argument)
      continue
    }
    if (argument === '--glob-case-insensitive') {
      globCaseInsensitive = true
      argv.push(argument)
      continue
    }
    const glob = readGlobArgument(args, index)
    if (glob !== undefined) {
      patterns.push({ pattern: glob.value, caseInsensitive: glob.caseInsensitive })
      index += glob.consumed - 1
      continue
    }
    const parsedSort = readSortArgument(args, index)
    if (parsedSort !== undefined) {
      sort = parsedSort.value
      argv.push(parsedSort.value === 'modified' ? '--sort=none' : `--sort=${parsedSort.value}`)
      index += parsedSort.consumed - 1
      continue
    }
    argv.push(argument)
  }
  if (patterns.length === 0 || (!files && !json)) return undefined
  return {
    patterns: patterns.map(entry => ({
      pattern: entry.pattern,
      caseInsensitive: entry.caseInsensitive || globCaseInsensitive,
    })),
    argv,
    sort,
    files,
    json,
  }
}

/**
 * Validate the glob arguments of any `rg` invocation before it is delegated.
 *
 * The built-in still owns plain-match output (and its own `--glob` filter),
 * but its invalid-glob diagnostic exits 1 with different wording. Ripgrep's
 * contract is a usage error (exit 2, `error parsing glob`): a malformed glob
 * must not be indistinguishable from "no matches".
 * @param args - `rg` arguments without the program name.
 * @returns the usage failure, or undefined when every glob parses.
 */
function validateGlobArguments(args: readonly string[]): ExecResult | undefined {
  const patterns: RipgrepGlobPattern[] = []
  for (let index = 0; index < args.length; index += 1) {
    const glob = readGlobArgument(args, index)
    if (glob === undefined) continue
    patterns.push({ pattern: glob.value, caseInsensitive: glob.caseInsensitive })
    index += glob.consumed - 1
  }
  if (patterns.length === 0) return undefined
  try {
    void new RipgrepGlobSet(patterns)
  } catch (error) {
    return globFailure(error)
  }
  return undefined
}

/** Build the ripgrep-style failure for an invalid glob. */
function globFailure(error: unknown): ExecResult {
  if (error instanceof RipgrepGlobError) {
    return shellFailure('rg', `rg: error parsing glob '${error.glob}': ${error.message}`, 'unsupported-option')
  }
  const message = error instanceof Error ? error.message : String(error)
  return shellFailure('rg', `rg: error parsing glob: ${message}`, 'unsupported-option')
}

/** Sort delegated paths by modification time, oldest first. */
async function sortByModificationTime(paths: readonly string[], ctx: ResolvedCommandContext): Promise<string[]> {
  const ordered: Array<{ path: string; index: number; time: number }> = []
  for (let index = 0; index < paths.length; index += 1) {
    const path = paths[index] as string
    let time = Number.POSITIVE_INFINITY
    try {
      const stats = await ctx.fs.stat(ctx.fs.resolvePath(ctx.cwd, path))
      time = stats.mtime.getTime()
    } catch {
      // A path the listing just produced but cannot stat keeps a stable tail.
    }
    ordered.push({ path, index, time })
  }
  ordered.sort((left, right) => left.time - right.time || left.index - right.index)
  return ordered.map(entry => entry.path)
}

/** Apply the globset to one `--files` listing. */
async function runFiles(parsed: ParsedRipgrepGlobs, ctx: ResolvedCommandContext): Promise<ExecResult> {
  let globSet: RipgrepGlobSet
  try {
    globSet = new RipgrepGlobSet(parsed.patterns)
  } catch (error) {
    return globFailure(error)
  }
  const delegated = await ctx.origCommand?.([...parsed.argv])
  if (delegated === undefined) return shellFailure('rg', 'rg: the built-in rg is unavailable in this shell', 'backend-failed')
  if (delegated.exitCode !== 0 && delegated.exitCode !== 1) return delegated
  let paths = delegated.stdout.split('\n').filter(path => path !== '')
  paths = paths.filter(path => globSet.matches(path))
  if (parsed.sort === 'modified') paths = await sortByModificationTime(paths, ctx)
  return {
    stdout: paths.length === 0 ? '' : `${paths.join('\n')}\n`,
    stderr: delegated.stderr,
    exitCode: paths.length === 0 ? 1 : 0,
  }
}

/** The path of one ripgrep `--json` record, when it carries one. */
function recordPath(record: unknown): string | undefined {
  if (typeof record !== 'object' || record === null) return undefined
  const data = (record as { data?: unknown }).data
  if (typeof data !== 'object' || data === null) return undefined
  const path = (data as { path?: unknown }).path
  if (typeof path !== 'object' || path === null) return undefined
  const text = (path as { text?: unknown }).text
  return typeof text === 'string' ? text : undefined
}

/** Apply the globset to one `--json` grep stream. */
async function runJson(parsed: ParsedRipgrepGlobs, ctx: ResolvedCommandContext): Promise<ExecResult> {
  let globSet: RipgrepGlobSet
  try {
    globSet = new RipgrepGlobSet(parsed.patterns)
  } catch (error) {
    return globFailure(error)
  }
  const delegated = await ctx.origCommand?.([...parsed.argv])
  if (delegated === undefined) return shellFailure('rg', 'rg: the built-in rg is unavailable in this shell', 'backend-failed')
  if (delegated.exitCode !== 0 && delegated.exitCode !== 1) return delegated
  const kept: string[] = []
  let matches = 0
  for (const line of delegated.stdout.split('\n')) {
    if (line === '') continue
    let record: unknown
    try {
      record = JSON.parse(line)
    } catch {
      // Preserve a malformed record so DSH classifies the search as failed
      // instead of silently dropping output.
      kept.push(line)
      continue
    }
    const path = recordPath(record)
    if (path !== undefined && !globSet.matches(path)) continue
    kept.push(line)
    if (typeof record === 'object' && record !== null && (record as { type?: unknown }).type === 'match') matches += 1
  }
  if (matches === 0) return { stdout: '', stderr: delegated.stderr, exitCode: 1 }
  return { stdout: `${kept.join('\n')}\n`, stderr: delegated.stderr, exitCode: 0 }
}

/**
 * Build the `rg` custom command that shadows just-bash's built-in.
 *
 * The built-in still handles listing, ignore rules, regex matching and JSON
 * encoding; this command takes over only when a glob has to be applied with
 * ripgrep semantics.
 * @returns the `rg` command definition.
 */
export function createRipgrepCommand(): Command {
  return defineCommand('rg', async (args, ctx): Promise<ExecResult> => {
    if (ctx.origCommand === undefined) {
      return shellFailure('rg', 'rg: the built-in rg is unavailable in this shell', 'backend-failed')
    }
    const invalid = validateGlobArguments(args)
    if (invalid !== undefined) return invalid
    const parsed = parseRipgrepGlobs(args)
    if (parsed === undefined) return await ctx.origCommand(args)
    return parsed.files ? await runFiles(parsed, ctx) : await runJson(parsed, ctx)
  })
}
