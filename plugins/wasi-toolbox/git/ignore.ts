// SPDX-License-Identifier: MIT
/**
 * `.gitignore` matching for `check-ignore`, `status` and `add --all`.
 *
 * Git's ignore semantics are layered: patterns from the repository root down
 * to the file's directory, `.git/info/exclude` and the global excludes file,
 * the deeper file winning over shallower ones and a later pattern winning
 * inside one file. A tracked path is never ignored (that is why `check-ignore`
 * consults the index), and a path below an ignored directory can never be
 * re-included. This module implements those rules over the Worker VFS; it is
 * deliberately pattern-compatible rather than byte-identical to GNU fnmatch.
 * @module @phone-dsh/dsh-wasi-toolbox/git/ignore
 */
import { isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'
import type { Repository } from './repo.ts'

/** One compiled pattern. */
interface IgnorePattern {
  readonly regex: RegExp
  readonly negated: boolean
  readonly directoryOnly: boolean
  /** Directory the pattern's own `.gitignore` lives in, relative to the root. */
  readonly base: string
}

/** Immutable set of ignore rules for one work tree snapshot. */
export interface IgnoreRules {
  readonly patterns: readonly IgnorePattern[]
  /** Tracked paths (relative to the work tree); never reported as ignored. */
  readonly tracked: ReadonlySet<string>
}

/** Convert one gitignore glob to a regular expression body. */
export function globToRegexBody(pattern: string): string {
  let out = ''
  let index = 0
  while (index < pattern.length) {
    const char = pattern[index] as string
    if (char === '*') {
      if (pattern[index + 1] === '*') {
        const before = index === 0 ? '' : pattern[index - 1] as string
        const after = pattern[index + 2]
        if (after === '/') {
          // `**/` matches zero or more directories.
          out += before === '' || before === '/' ? '(?:.*/)?' : '.*/'
          index += 3
          continue
        }
        out += '.*'
        index += 2
        continue
      }
      out += '[^/]*'
      index += 1
      continue
    }
    if (char === '?') {
      out += '[^/]'
      index += 1
      continue
    }
    if (char === '[') {
      let end = index + 1
      while (end < pattern.length && pattern[end] !== ']') end += 1
      if (end >= pattern.length) {
        out += '\\['
        index += 1
        continue
      }
      let body = pattern.slice(index + 1, end)
      if (body.startsWith('!')) body = `^${body.slice(1)}`
      out += `[${body.replace(/\\/g, '\\\\')}]`
      index = end + 1
      continue
    }
    if (char === '\\' && index + 1 < pattern.length) {
      out += escapeRegex(pattern[index + 1] as string)
      index += 2
      continue
    }
    out += escapeRegex(char)
    index += 1
  }
  return out
}

function escapeRegex(char: string): string {
  return /[.*+?^${}()|[\]\\/]/.test(char) ? `\\${char}` : char
}

/** Compile one raw ignore line for a `.gitignore` in `base`. */
export function compilePattern(raw: string, base: string): IgnorePattern | undefined {
  let line = raw.replace(/\r$/, '')
  if (line.trim() === '' || line.startsWith('#')) return undefined
  // Unescaped trailing spaces are trimmed.
  line = line.replace(/(?<!\\)\s+$/, '')
  if (line === '') return undefined
  let negated = false
  if (line.startsWith('!')) {
    negated = true
    line = line.slice(1)
  } else if (line.startsWith('\\!') || line.startsWith('\\#')) {
    line = line.slice(1)
  }
  let directoryOnly = false
  if (line.endsWith('/')) {
    directoryOnly = true
    line = line.slice(0, -1)
  }
  if (line === '') return undefined
  let anchored = false
  if (line.startsWith('/')) {
    anchored = true
    line = line.slice(1)
  } else if (line.includes('/')) {
    anchored = true
  }
  const body = globToRegexBody(line)
  const prefix = base === '' ? '' : `${escapeRegex(base)}/`
  const regex = base === ''
    ? anchored
      ? new RegExp(`^${body}(?:/.*)?$`)
      : new RegExp(`^(?:.*/)?${body}(?:/.*)?$`)
    : new RegExp(`^${prefix}${anchored ? '' : '(?:.*/)?'}${body}(?:/.*)?$`)
  return { regex, negated, directoryOnly, base }
}

/** Load the ignore rules that apply to a work tree. */
export async function loadIgnoreRules(
  repository: Repository,
  workTree: string,
  tracked: ReadonlySet<string>,
): Promise<IgnoreRules> {
  const patterns: IgnorePattern[] = []
  // Global excludes file has the lowest precedence.
  const globalExcludes = repository.config.get('core.excludesfile')
  if (globalExcludes !== undefined) {
    const text = await readOptionalText(repository.fs, globalExcludes)
    if (text !== undefined) pushLines(patterns, text, '')
  }
  const infoExclude = await readOptionalText(repository.fs, `${repository.commonDir}/info/exclude`)
  if (infoExclude !== undefined) pushLines(patterns, infoExclude, '')
  // Walk the work tree and collect every .gitignore, parents before children.
  const walk = async (relative: string): Promise<void> => {
    const directory = relative === '' ? workTree : `${workTree}/${relative}`
    const text = await readOptionalText(repository.fs, `${directory}/.gitignore`)
    if (text !== undefined) pushLines(patterns, text, relative)
    let entries
    try {
      entries = await repository.fs.readdir(directory)
    } catch (error) {
      if (isErrno(error, 'ENOENT', 'ENOTDIR')) return
      throw error
    }
    for (const entry of entries.sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)) {
      if (!entry.isDirectory || entry.name === '.git') continue
      if (entry.isSymbolicLink) continue
      await walk(relative === '' ? entry.name : `${relative}/${entry.name}`)
    }
  }
  await walk('')
  return { patterns, tracked }
}

function pushLines(patterns: IgnorePattern[], text: string, base: string): void {
  for (const line of text.split('\n')) {
    const pattern = compilePattern(line, base)
    if (pattern !== undefined) patterns.push(pattern)
  }
}

async function readOptionalText(fs: GitFs, path: string): Promise<string | undefined> {
  try {
    return new TextDecoder().decode(await fs.readFile(path))
  } catch (error) {
    if (isErrno(error, 'ENOENT', 'ENOTDIR')) return undefined
    throw error
  }
}

/**
 * True when a path (relative to the work tree, no leading slash) is ignored.
 * Every ancestor directory is checked first because gitnever descends into an
 * ignored directory; a tracked path answers false.
 */
export function isIgnored(rules: IgnoreRules, path: string, isDirectory = false): boolean {
  if (rules.tracked.has(path)) return false
  const parts = path.split('/')
  for (let index = 1; index < parts.length; index += 1) {
    const prefix = parts.slice(0, index).join('/')
    if (rules.tracked.has(prefix)) continue
    if (matchPath(rules, prefix, true)) return true
  }
  return matchPath(rules, path, isDirectory)
}

function matchPath(rules: IgnoreRules, path: string, isDirectory: boolean): boolean {
  let ignored = false
  for (const pattern of rules.patterns) {
    if (pattern.directoryOnly && !isDirectory) continue
    if (!pattern.regex.test(path)) continue
    ignored = !pattern.negated
  }
  return ignored
}
