// SPDX-License-Identifier: MIT
/**
 * The eight subcommands DSH's `workspace-changes` plugin drives, plus the
 * plumbing they share:
 *
 *   rev-parse / add --all / write-tree / ls-tree / cat-file / diff-tree /
 *   ls-files / check-ignore -z --stdin
 *
 * Byte-exact output is a requirement, not a nicety: `workspace-changes` parses
 * these streams with fixed regexes and NUL delimiters, and the golden tests
 * compare every one of them against the system git on the same fixture.
 * @module @phone-dsh/dsh-wasi-toolbox/git/inspect
 */
import { posix } from 'node:path'
import { fatal } from './errors.ts'
import { compareStrings, decodeText, encodeText, isInside, relativePath, resolvePath } from './fs.ts'
import { hasUnmerged, readIndex } from './gindex.ts'
import type { GitIndex, IndexEntry } from './gindex.ts'
import { isIgnored, loadIgnoreRules } from './ignore.ts'
import type { IgnoreRules } from './ignore.ts'
import {
  gitPath, headRef, parseTree, readCommit, requireWorkTree, resolveRef, resolveRevision,
} from './repo.ts'
import type { Repository } from './repo.ts'
import { buildTreeFromIndex, diffTrees, readWorktreeBlob } from './tree.ts'
import { countDiff, isBinary, splitLines } from './textdiff.ts'
import { scanWorktree } from './worktree.ts'
import { wildmatchBytes, wildmatchPathnameBytes } from './wildmatch.ts'
import type { CommandContext } from './cli.ts'
import { splitNul } from './cli.ts'

/** One parsed pathspec. */
export interface Pathspec {
  /** Repository-relative path (no leading slash); empty means the root. */
  readonly path: string
  readonly exclude: boolean
  readonly literal: boolean
  /** True for git's `:(glob)` magic: pathname-aware wildcards and `**`. */
  readonly glob: boolean
  /**
   * True when the original pathspec ended in `/` or `/.`, so it selects a
   * directory's contents but never a file that happens to have the same name.
   */
  readonly directoryOnly: boolean
}

/** Convert an argv path to a work-tree-relative path. */
export function workTreePath(repository: Repository, cwd: string, path: string): string {
  const workTree = requireWorkTree(repository)
  let absolute: string
  if (path.startsWith('/')) {
    absolute = posix.normalize(path)
  } else {
    absolute = resolvePath(cwd, path)
  }
  if (!isInside(workTree, absolute)) {
    throw fatal(`'${path}' is outside repository at '${workTree}'`)
  }
  const relative = relativePath(workTree, absolute)
  return relative === '' ? '' : relative
}

/**
 * Convert an argv path to a bare repository's path prefix.
 *
 * A bare repository has no work tree, but `rev-list <commit> -- <path>` still
 * works there: git uses an empty prefix (the repository root) regardless of
 * the current directory, and an absolute path is outside the repository. No
 * command that needs real work-tree files reaches this helper.
 */
function barePathspecPath(repository: Repository, path: string): string {
  const root = repository.gitDir
  const absolute = path.startsWith('/') ? posix.normalize(path) : resolvePath(root, path)
  if (!isInside(root, absolute)) {
    throw fatal(`${absolute}: '${path}' is outside repository at '${root}/.'`)
  }
  const relative = relativePath(root, absolute)
  return relative === '' ? '' : relative
}

/** True when the raw pathspec asks for a directory rather than a file. */
function isDirectoryOnlyPathspec(path: string): boolean {
  return path.endsWith('/') || path.endsWith('/.')
}

/** Parse one pathspec argument, including `:(glob)`, `:(exclude)` and `:(top)` magic. */
export function parsePathspec(repository: Repository, cwd: string, argument: string): Pathspec {
  const literalMode = repository.env.GIT_LITERAL_PATHSPECS
  if (literalMode !== undefined && literalMode !== '' && literalMode !== '0') {
    return {
      path: repository.workTree === undefined
        ? barePathspecPath(repository, argument)
        : workTreePath(repository, cwd, argument),
      exclude: false,
      literal: true,
      glob: false,
      directoryOnly: isDirectoryOnlyPathspec(argument),
    }
  }
  let rest = argument
  let exclude = false
  let literal = false
  let glob = false
  let top = false
  if (rest.startsWith(':(', 0)) {
    const end = rest.indexOf(')')
    if (end < 0) throw fatal(`Missing ')' at the end of pathspec magic in '${argument}'`)
    const magic = rest.slice(2, end).split(',')
    for (const item of magic) {
      if (item === '' || item === 'top') top = true
      else if (item === 'exclude') exclude = true
      else if (item === 'literal') literal = true
      else if (item === 'glob') glob = true
      else throw fatal(`Invalid pathspec magic '${item}' in '${argument}'`)
    }
    if (literal && glob) throw fatal(`${argument}: 'literal' and 'glob' are incompatible`)
    rest = rest.slice(end + 1)
  }
  const directoryOnly = isDirectoryOnlyPathspec(rest)
  if (repository.workTree === undefined) {
    // Bare: the prefix is empty, so cwd and `:(top)` both mean the root.
    const path = rest === '' || rest === '.' ? '' : barePathspecPath(repository, rest)
    return { path, exclude, literal, glob, directoryOnly }
  }
  const base = top ? requireWorkTree(repository) : cwd
  const path = rest === '' || rest === '.' ? (top ? '' : workTreePath(repository, base, '.')) : workTreePath(repository, base, rest)
  return { path, exclude, literal, glob, directoryOnly }
}

/**
 * True when a pathspec has glob syntax rather than only literal bytes.
 *
 * A backslash counts even without `*`, `?` or `[`: it quotes the next byte, so
 * `:(glob)a\\]` must reach the byte matcher to select the literal name `a]`.
 * A pathspec that is only an escape therefore is not a raw literal comparison.
 */
export function hasGlobMetacharacters(path: string): boolean {
  return path.includes('*') || path.includes('?') || path.includes('[') || path.includes('\\')
}

/**
 * Match one repository-relative path against one pathspec.
 *
 * Literal pathspecs select the named file or, when they name a directory, every
 * path below it. A directory-only pathspec (`dir/`, `./dir/`, `dir//`) may only
 * select paths below `dir`, never a regular file named `dir`. Default glob
 * pathspecs are matched against the whole path by the shared byte matcher; `*`
 * spans `/`, which is what git's unanchored pathspec flags do. `:(glob)` uses
 * the pathname-aware matcher instead: `*`/`?` stop at `/`, and `**` is special
 * only at a glob position. A glob that ends in `/` matches no repository file
 * path (there is no trailing slash to compare), as with the system git.
 */
export function matchesPathspec(spec: Pathspec, path: string): boolean {
  if (spec.path === '') return true
  const exact = path === spec.path
  const belowDirectory = path.startsWith(`${spec.path}/`)
  if (spec.directoryOnly) {
    if (belowDirectory) return true
    // `:(glob)a**/` matches the file `a`: the terminal globstar may consume
    // zero directories (and its slash), so a wildcard directory-only pattern
    // still needs the pathname matcher. A literal `dir/` keeps selecting only
    // paths below `dir`, as git does.
    if (!spec.glob || !hasGlobMetacharacters(spec.path)) return false
    // `Pathspec.path` is normalised (the trailing slash is gone), so restore
    // the separator the original directory-only spelling asked for.
    return wildmatchPathnameBytes(encodeText(`${spec.path}/`), encodeText(path))
  }
  // Git checks the literal spelling before it tries wildcard matching. This
  // keeps real names such as `a[` and `[a]` selectable even though those bytes
  // also form malformed or valid glob syntax.
  if (exact || belowDirectory) return true
  if (!spec.literal && hasGlobMetacharacters(spec.path)) {
    const pattern = encodeText(spec.path)
    const candidate = encodeText(path)
    return spec.glob ? wildmatchPathnameBytes(pattern, candidate) : wildmatchBytes(pattern, candidate)
  }
  return false
}

/** True when a path is selected by the include/exclude pathspec list. */
export function selectedByPathspecs(specs: readonly Pathspec[], path: string): boolean {
  const includes = specs.filter(spec => !spec.exclude)
  if (includes.length > 0 && !includes.some(spec => matchesPathspec(spec, path))) return false
  return !specs.some(spec => spec.exclude && matchesPathspec(spec, path))
}

/**
 * Build the snapshot filter for a parsed pathspec list.
 *
 * Tree diffs pass this to rename detection so both snapshots are restricted
 * first, exactly as git walks a tree with a pathspec. With no pathspec the
 * whole tree is selected and the filter is unnecessary.
 */
export function pathspecSelector(specs: readonly Pathspec[]): ((path: string) => boolean) | undefined {
  if (specs.length === 0) return undefined
  return path => selectedByPathspecs(specs, path)
}

/** Read the index once per command. */
export async function loadIndex(repository: Repository): Promise<GitIndex> {
  return await readIndex(repository.fs, repository.indexPath)
}

/** True when the index tracks a path (any stage). */
export function trackedPaths(index: GitIndex): Set<string> {
  return new Set(index.entries.map(entry => entry.path))
}

/** Load ignore rules with the index's tracked set. */
export async function loadIgnores(repository: Repository, index: GitIndex): Promise<IgnoreRules> {
  return await loadIgnoreRules(repository, requireWorkTree(repository), trackedPaths(index))
}

/** Quote a path the way git's default `core.quotePath` does. */
export function quotePath(path: string, quoteHigh = true): string {
  let needsQuote = false
  for (const char of path) {
    const code = char.codePointAt(0) as number
    if (char === '"' || char === '\\' || code < 0x20 || code === 0x7f || (quoteHigh && code >= 0x80)) {
      needsQuote = true
      break
    }
  }
  if (!needsQuote) return path
  let out = '"'
  for (const byte of encodeText(path)) {
    if (byte === 0x22) out += '\\"'
    else if (byte === 0x5c) out += '\\\\'
    else if (byte === 0x0a) out += '\\n'
    else if (byte === 0x09) out += '\\t'
    else if (byte === 0x08) out += '\\b'
    else if (byte === 0x0d) out += '\\r'
    else if (byte === 0x0c) out += '\\f'
    else if (byte < 0x20 || byte >= 0x7f) out += `\\${byte.toString(8).padStart(3, '0')}`
    else out += String.fromCharCode(byte)
  }
  return `${out}"`
}

/** `git rev-parse` on the shapes DSH and the porcelain use. */
export async function revParse(context: CommandContext): Promise<number> {
  const repository = await context.repository()
  const args = [...context.args]
  let quiet = false
  let mode: 'normal' | 'verify' | 'short' | 'abbrev-ref' | 'symbolic-full-name' = 'normal'
  let shortLength = 7
  const pending: string[] = []
  while (args.length > 0) {
    const arg = args.shift() as string
    if (arg === '--') {
      pending.push(...args)
      break
    }
    if (arg === '-q' || arg === '--quiet') { quiet = true; continue }
    if (arg === '--verify') { mode = 'verify'; continue }
    if (arg === '--short') { mode = 'short'; continue }
    if (arg.startsWith('--short=')) { mode = 'short'; shortLength = Number(arg.slice(8)) || 7; continue }
    if (arg === '--abbrev-ref') { mode = 'abbrev-ref'; continue }
    if (arg === '--symbolic-full-name') { mode = 'symbolic-full-name'; continue }
    if (arg === '--show-toplevel') {
      if (repository.workTree === undefined) throw fatal('this operation must be run in a work tree')
      context.output.stdout(`${await repository.fs.realpath(repository.workTree)}\n`)
      continue
    }
    if (arg === '--absolute-git-dir') {
      context.output.stdout(`${await repository.fs.realpath(repository.gitDir)}\n`)
      continue
    }
    if (arg === '--git-dir') {
      const relative = await relativeGitDir(repository)
      context.output.stdout(`${relative}\n`)
      continue
    }
    if (arg === '--git-common-dir') {
      context.output.stdout(`${await relativeCommonDir(repository)}\n`)
      continue
    }
    if (arg === '--git-path') {
      const name = args.shift()
      if (name === undefined) throw fatal('--git-path requires a path')
      const target = gitPath(repository, name)
      context.output.stdout(`${relativeFromCwd(context.cwd, target)}\n`)
      continue
    }
    if (arg === '--is-inside-work-tree') {
      const inside = repository.workTree !== undefined
        && isInside(await repository.fs.realpath(repository.workTree), await repository.fs.realpath(context.cwd))
      context.output.stdout(`${inside ? 'true' : 'false'}\n`)
      continue
    }
    if (arg === '--is-bare-repository') {
      context.output.stdout(`${repository.bare ? 'true' : 'false'}\n`)
      continue
    }
    if (arg === '--is-inside-git-dir') {
      const inside = isInside(repository.gitDir, context.cwd) || isInside(repository.commonDir, context.cwd)
      context.output.stdout(`${inside ? 'true' : 'false'}\n`)
      continue
    }
    if (arg === '--show-prefix') {
      context.output.stdout(`${await showPrefix(repository, context.cwd)}\n`)
      continue
    }
    if (arg === '--show-cdup') {
      context.output.stdout(`${await showCdup(repository, context.cwd)}\n`)
      continue
    }
    if (arg === '--show-superproject-working-tree') {
      context.output.stdout('\n')
      continue
    }
    if (arg.startsWith('-')) throw fatal(`unsupported rev-parse option '${arg}'`, 129)
    pending.push(arg)
  }
  for (const expression of pending) {
    try {
      const oid = await resolveRevision(repository, expression)
      if (mode === 'short') context.output.stdout(`${oid.slice(0, shortLength)}\n`)
      else if (mode === 'abbrev-ref') context.output.stdout(`${await abbreviateRef(repository, expression)}\n`)
      else if (mode === 'symbolic-full-name') context.output.stdout(`${await symbolicName(repository, expression)}\n`)
      else context.output.stdout(`${oid}\n`)
    } catch (error) {
      if (mode === 'verify' && quiet) return 1
      throw error
    }
  }
  return 0
}

async function relativeGitDir(repository: Repository): Promise<string> {
  if (repository.workTree !== undefined) {
    const realWorkTree = await repository.fs.realpath(repository.workTree)
    const realGitDir = await repository.fs.realpath(repository.gitDir)
    const realCwd = await repository.fs.realpath(repository.cwd)
    if (realCwd === realWorkTree) return realGitDir === `${realWorkTree}/.git` ? '.git' : realGitDir
  }
  return await repository.fs.realpath(repository.gitDir)
}

async function relativeCommonDir(repository: Repository): Promise<string> {
  if (repository.commonDir !== repository.gitDir) return await repository.fs.realpath(repository.commonDir)
  return await relativeGitDir(repository)
}

function relativeFromCwd(cwd: string, target: string): string {
  const relative = posix.relative(cwd, target)
  return relative === '' ? '.' : relative
}

async function showPrefix(repository: Repository, cwd: string): Promise<string> {
  if (repository.workTree === undefined) return ''
  const realWorkTree = await repository.fs.realpath(repository.workTree)
  const realCwd = await repository.fs.realpath(cwd)
  if (!isInside(realWorkTree, realCwd)) return ''
  const relative = posix.relative(realWorkTree, realCwd)
  return relative === '' ? '' : `${relative}/`
}

async function showCdup(repository: Repository, cwd: string): Promise<string> {
  if (repository.workTree === undefined) return '..'
  const realWorkTree = await repository.fs.realpath(repository.workTree)
  const realCwd = await repository.fs.realpath(cwd)
  if (!isInside(realWorkTree, realCwd)) return ''
  const relative = posix.relative(realCwd, realWorkTree)
  return relative === '' ? '' : `${relative}/`
}

async function abbreviateRef(repository: Repository, expression: string): Promise<string> {
  if (expression === 'HEAD' || expression === '@') {
    const symbolic = await headRef(repository)
    if (symbolic === undefined) return 'HEAD'
    return await resolveRef(repository, symbolic) === undefined ? 'HEAD' : symbolic.replace(/^refs\/heads\//, '')
  }
  for (const prefix of ['refs/heads/', 'refs/tags/', 'refs/remotes/']) {
    if (await resolveRef(repository, `${prefix}${expression}`) !== undefined) return expression
  }
  return (await resolveRevision(repository, expression)).slice(0, 7)
}

async function symbolicName(repository: Repository, expression: string): Promise<string> {
  for (const prefix of ['refs/heads/', 'refs/tags/', 'refs/remotes/']) {
    if (await resolveRef(repository, `${prefix}${expression}`) !== undefined) return `${prefix}${expression}`
  }
  return expression
}

/** `git write-tree`. */
export async function writeTree(context: CommandContext): Promise<number> {
  if (context.args.length > 0) throw fatal(`unsupported write-tree argument '${context.args[0]}'`, 129)
  const repository = await context.repository()
  const index = await loadIndex(repository)
  if (hasUnmerged(index)) {
    for (const entry of index.entries) {
      if (entry.stage !== 0) context.output.stderr(`${entry.path}: unmerged (${entry.oid})\n`)
    }
    throw fatal('git-write-tree: error building trees')
  }
  const oid = await buildTreeFromIndex(repository, index)
  context.output.stdout(`${oid}\n`)
  return 0
}

interface LsTreeOptions {
  recursive: boolean
  showTrees: boolean
  onlyTrees: boolean
  long: boolean
  nul: boolean
  nameOnly: boolean
}

/** `git ls-tree`. */
export async function lsTree(context: CommandContext): Promise<number> {
  const options: LsTreeOptions = {
    recursive: false, showTrees: false, onlyTrees: false, long: false, nul: false, nameOnly: false,
  }
  const rest: string[] = []
  const pathspecs: string[] = []
  let afterSeparator = false
  for (const arg of context.args) {
    if (afterSeparator) {
      pathspecs.push(arg)
      continue
    }
    if (arg === '--') {
      afterSeparator = true
      continue
    }
    if (arg === '-r') options.recursive = true
    else if (arg === '-t') options.showTrees = true
    else if (arg === '-d') options.onlyTrees = true
    else if (arg === '-l' || arg === '--long') options.long = true
    else if (arg === '-z') options.nul = true
    else if (arg === '--name-only' || arg === '--name-status') options.nameOnly = true
    else if (arg === '--full-name' || arg === '--full-tree') continue
    else if (arg.startsWith('-')) throw fatal(`unsupported ls-tree option '${arg}'`, 129)
    else rest.push(arg)
  }
  const treeish = rest[0]
  if (treeish === undefined) throw fatal('ls-tree: missing tree-ish', 129)
  rest.shift()
  pathspecs.unshift(...rest)
  const repository = await context.repository()
  const oid = await resolveRevision(repository, treeish)
  const tree = await peelToTreeOid(repository, oid)
  const specs = pathspecs.map(path => parsePathspec(repository, context.cwd, path))
  // Native ls-tree only implements the `top` and `literal` magic. It rejects
  // the wildcard and exclude magic with this command-specific message, so the
  // Worker keeps failing instead of silently applying another command's
  // pathspec semantics.
  for (let index = 0; index < specs.length; index += 1) {
    const spec = specs[index] as Pathspec
    const unsupported: string[] = []
    if (spec.glob) unsupported.push("'glob'")
    if (spec.exclude) unsupported.push("'exclude' (mnemonic: '!')")
    if (unsupported.length > 0) {
      throw fatal(
        `${pathspecs[index] as string}: pathspec magic not supported by this command: ${unsupported.join(', ')}`,
        128,
      )
    }
  }
  const emit = (path: string, mode: string, type: string, object: string, size?: number): void => {
    if (options.nameOnly) {
      context.output.stdout(`${path}${options.nul ? '\0' : '\n'}`)
      return
    }
    const sizeText = options.long ? ` ${(size === undefined ? '-' : String(size)).padStart(7)}` : ''
    const name = options.nul ? path : quotePath(path)
    context.output.stdout(`${mode} ${type} ${object}${sizeText}\t${name}${options.nul ? '\0' : '\n'}`)
  }
  const matches = (path: string): boolean => specs.length === 0 || selectedByPathspecs(specs, path)
  const visit = async (treeOid: string, prefix: string): Promise<void> => {
    const object = await repository.odb.read(treeOid)
    for (const entry of parseTree(object.data)) {
      const path = `${prefix}${entry.name}`
      if (entry.mode === '40000') {
        if (options.onlyTrees || options.showTrees || !options.recursive) {
          if (matches(path)) emit(path, '040000', 'tree', entry.oid)
        }
        if (options.recursive) await visit(entry.oid, `${path}/`)
      } else if (!options.onlyTrees) {
        if (!matches(path)) continue
        const type = entry.mode === '160000' ? 'commit' : 'blob'
        const size = options.long && type === 'blob' ? (await repository.odb.size(entry.oid)) : undefined
        emit(path, entry.mode.padStart(6, '0'), type, entry.oid, size)
      }
    }
  }
  // Without -r, only the root tree is listed; with -r, also list `treeish` itself
  // when it names a directory other than the root (git lists the root's children).
  await visit(tree, '')
  return 0
}

async function peelToTreeOid(repository: Repository, oid: string): Promise<string> {
  const type = await repository.odb.type(oid)
  if (type === 'tree') return oid
  if (type === 'commit') return (await readCommit(repository, oid)).tree
  throw fatal(`object ${oid} is a ${type}, not a tree`)
}

/** `git cat-file`. */
export async function catFile(context: CommandContext): Promise<number> {
  const args = [...context.args]
  const repository = await context.repository()
  let mode: 'type' | 'size' | 'exists' | 'pretty' | 'content' = 'content'
  let requestedType: string | undefined
  while (args.length > 0) {
    const arg = args[0] as string
    if (arg === '-t') { mode = 'type'; args.shift() }
    else if (arg === '-s') { mode = 'size'; args.shift() }
    else if (arg === '-e') { mode = 'exists'; args.shift() }
    else if (arg === '-p') { mode = 'pretty'; args.shift() }
    else if (arg === '--allow-unknown-type') { args.shift() }
    else if (arg === 'blob' || arg === 'tree' || arg === 'commit' || arg === 'tag') {
      requestedType = arg
      mode = 'content'
      args.shift()
    } else break
  }
  if (args.length === 0) throw fatal('cat-file: missing object', 129)
  const argument = args[0] as string
  const oid = /^[0-9a-fA-F]{40}$/.test(argument)
    ? argument.toLowerCase()
    : /^[0-9a-fA-F]{4,39}$/.test(argument)
      ? (await expandOidLoose(repository, argument)) ?? argument.toLowerCase()
      : await resolveRevision(repository, argument)
  if (mode === 'exists') {
    return await repository.odb.has(oid) ? 0 : 1
  }
  let object
  try {
    object = await repository.odb.read(oid)
  } catch {
    throw fatal(`git cat-file ${oid}: bad file`)
  }
  if (requestedType !== undefined && requestedType !== object.type) {
    throw fatal(`git cat-file ${oid}: bad file`)
  }
  if (mode === 'type') {
    context.output.stdout(`${object.type}\n`)
  } else if (mode === 'size') {
    context.output.stdout(`${object.data.byteLength}\n`)
  } else if (mode === 'pretty' && object.type === 'tree') {
    for (const entry of parseTree(object.data)) {
      const type = entry.mode === '40000' ? 'tree' : entry.mode === '160000' ? 'commit' : 'blob'
      const mode = entry.mode === '40000' ? '040000' : entry.mode.padStart(6, '0')
      context.output.stdout(`${mode} ${type} ${entry.oid}\t${entry.name}\n`)
    }
  } else {
    // For a commit or tag, `-p` is the stored object text. Emitting those
    // bytes verbatim preserves every field exactly as it was written —
    // including the full epoch-seconds value of the author and committer
    // lines. Re-serializing a signature through a numeric conversion is how
    // the committer field was once shortened (G2-B06).
    context.output.stdout(object.data)
  }
  return 0
}

interface DiffTreeOptions {
  recursive: boolean
  renames: boolean
  threshold: number
  nul: boolean
  numstat: boolean
  nameOnly: boolean
  nameStatus: boolean
  root: boolean
  noCommitId: boolean
}

/** `git diff-tree`. */
export async function diffTree(context: CommandContext): Promise<number> {
  const options: DiffTreeOptions = {
    recursive: false, renames: false, threshold: 50, nul: false,
    numstat: false, nameOnly: false, nameStatus: false, root: false, noCommitId: false,
  }
  const rest: string[] = []
  const pathspecs: string[] = []
  let afterSeparator = false
  for (const arg of context.args) {
    if (afterSeparator) { pathspecs.push(arg); continue }
    if (arg === '--') { afterSeparator = true; continue }
    if (arg === '-r') options.recursive = true
    else if (arg === '-M') { options.renames = true; options.threshold = 50 }
    else if (/^-M\d+%?$/.test(arg)) { options.renames = true; options.threshold = Number(arg.slice(2).replace('%', '')) }
    else if (arg === '-C' || arg === '--find-copies') {
      // Copy detection changes which records appear; the Worker git only pairs
      // exact rename candidates, so a plain diff-tree is not the requested one.
      throw fatal(`unsupported diff-tree option '${arg}': the Worker git does not detect copies. Nothing was printed.`, 129)
    }
    else if (arg === '-z') options.nul = true
    else if (arg === '--numstat') options.numstat = true
    else if (arg === '--name-only') options.nameOnly = true
    else if (arg === '--name-status') options.nameStatus = true
    else if (arg === '--root') options.root = true
    else if (arg === '--no-commit-id') options.noCommitId = true
    else if (arg === '--no-renames') options.renames = false
    else if (arg.startsWith('-')) throw fatal(`unsupported diff-tree option '${arg}'`, 129)
    else rest.push(arg)
  }
  if (rest.length === 0) throw fatal('diff-tree: missing tree', 129)
  const repository = await context.repository()
  const specs = pathspecs.map(path => parsePathspec(repository, context.cwd, path))
  let before: string | undefined
  let after: string
  let commitLine: string | undefined
  if (rest.length >= 2) {
    before = await peelToTreeOid(repository, await resolveRevision(repository, rest[0] as string))
    after = await peelToTreeOid(repository, await resolveRevision(repository, rest[1] as string))
  } else {
    const commitOid = await resolveRevision(repository, rest[0] as string)
    const commit = await readCommit(repository, commitOid)
    commitLine = commitOid
    before = commit.parents.length > 0 && options.root !== true
      ? (await readCommit(repository, commit.parents[0] as string)).tree
      : undefined
    after = commit.tree
  }
  const select = pathspecSelector(specs)
  const changes = before === undefined
    ? options.root || rest.length >= 2
      ? await diffTrees(repository, await emptyTreeOid(repository), after, {
        renames: options.renames, threshold: options.threshold, select,
      })
      : []
    : await diffTrees(repository, before, after, { renames: options.renames, threshold: options.threshold, select })
  if (commitLine !== undefined && !options.noCommitId) context.output.stdout(`${commitLine}\n`)
  const terminator = options.nul ? '\0' : '\n'
  for (const change of changes) {
    if (options.nameOnly) {
      context.output.stdout(`${change.path}${terminator}`)
      continue
    }
    if (options.nameStatus) {
      const code = `${change.status}${change.score === undefined ? '' : String(change.score).padStart(3, '0')}`
      const names = change.oldPath === undefined ? change.path : `${change.oldPath}\t${change.path}`
      context.output.stdout(`${code}\t${names}${terminator}`)
      continue
    }
    if (options.numstat) {
      const stats = await numstatFor(repository, change)
      if (change.oldPath !== undefined) {
        if (options.nul) context.output.stdout(`${stats.added}\t${stats.deleted}\t\0${change.oldPath}\0${change.path}\0`)
        else context.output.stdout(`${stats.added}\t${stats.deleted}\t${change.oldPath} => ${change.path}${terminator}`)
      } else {
        context.output.stdout(`${stats.added}\t${stats.deleted}\t${change.path}${terminator}`)
      }
      continue
    }
    // Raw format: :<oldmode> <newmode> <oldoid> <newoid> <status>\t<path>
    const oldMode = change.oldMode ?? '000000'
    const newMode = change.newMode ?? '000000'
    const oldOid = change.oldOid ?? '0000000000000000000000000000000000000000'
    const newOid = change.newOid ?? '0000000000000000000000000000000000000000'
    const status = change.status === 'R' && change.score !== undefined ? `R${String(change.score).padStart(3, '0')}` : change.status
    const path = options.nul ? `${change.path}\0` : `${quotePath(change.path)}${terminator}`
    context.output.stdout(`:${oldMode.padStart(6, '0')} ${newMode.padStart(6, '0')} ${oldOid} ${newOid} ${status}\t${path}`)
  }
  if (changes.length === 0 && commitLine !== undefined && !options.noCommitId) {
    // diff-tree prints only the commit id when the tree did not change, which
    // is what the line above already did.
    return 0
  }
  return 0
}

async function numstatFor(
  repository: Repository,
  change: { oldOid?: string; newOid?: string },
): Promise<{ added: string; deleted: string }> {
  const oldData = change.oldOid === undefined ? new Uint8Array(0) : (await repository.odb.read(change.oldOid)).data
  const newData = change.newOid === undefined ? new Uint8Array(0) : (await repository.odb.read(change.newOid)).data
  if (isBinary(oldData) || isBinary(newData)) return { added: '-', deleted: '-' }
  const counts = countDiff(splitLines(oldData), splitLines(newData))
  return { added: String(counts.added), deleted: String(counts.deleted) }
}

async function expandOidLoose(repository: Repository, prefix: string): Promise<string | undefined> {
  try {
    const { expandOid } = await import('./repo.ts')
    return await expandOid(repository, prefix)
  } catch {
    return undefined
  }
}

async function emptyTreeOid(repository: Repository): Promise<string> {
  return await repository.odb.write('tree', new Uint8Array(0))
}

interface LsFilesOptions {
  nul: boolean
  stage: boolean
  others: boolean
  modified: boolean
  deleted: boolean
  excludeStandard: boolean
  errorUnmatch: boolean
}

/** `git ls-files`. */
export async function lsFiles(context: CommandContext): Promise<number> {
  const options: LsFilesOptions = {
    nul: false, stage: false, others: false, modified: false, deleted: false,
    excludeStandard: true, errorUnmatch: false,
  }
  const pathspecArgs: string[] = []
  let afterSeparator = false
  for (const arg of context.args) {
    if (afterSeparator) { pathspecArgs.push(arg); continue }
    if (arg === '--') { afterSeparator = true; continue }
    if (arg === '-z') options.nul = true
    else if (arg === '-s' || arg === '--stage') options.stage = true
    else if (arg === '-c' || arg === '--cached') continue
    else if (arg === '-o' || arg === '--others') options.others = true
    else if (arg === '-m' || arg === '--modified') options.modified = true
    else if (arg === '-d' || arg === '--deleted') options.deleted = true
    else if (arg === '--exclude-standard') options.excludeStandard = true
    else if (arg === '--error-unmatch') options.errorUnmatch = true
    else if (arg === '--full-name') continue
    else if (arg.startsWith('-')) throw fatal(`unsupported ls-files option '${arg}'`, 129)
    else pathspecArgs.push(arg)
  }
  const repository = await context.repository()
  const index = await loadIndex(repository)
  const specs = pathspecArgs.map(path => parsePathspec(repository, context.cwd, path))
  const terminator = options.nul ? '\0' : '\n'
  let matched = 0
  const emitIndexEntry = (entry: IndexEntry): void => {
    if (specs.length > 0 && !selectedByPathspecs(specs, entry.path)) return
    matched += 1
    if (options.stage) {
      context.output.stdout(`${entry.mode.toString(8).padStart(6, '0')} ${entry.oid} ${entry.stage}\t${entry.path}${terminator}`)
    } else {
      context.output.stdout(`${entry.path}${terminator}`)
    }
  }
  if (!options.others || options.stage) {
    for (const entry of index.entries) emitIndexEntry(entry)
  }
  if (options.others || options.modified || options.deleted) {
    const files = await scanWorktree(repository)
    const tracked = trackedPaths(index)
    const ignores = options.excludeStandard ? await loadIgnores(repository, index) : undefined
    const paths = [...files.keys()].sort(compareStrings)
    if (options.others) {
      for (const path of paths) {
        const info = files.get(path) as { isDirectory: boolean }
        if (info.isDirectory) continue
        if (tracked.has(path)) continue
        if (specs.length > 0 && !selectedByPathspecs(specs, path)) continue
        if (ignores !== undefined && isIgnored(ignores, path, false)) continue
        matched += 1
        context.output.stdout(`${path}${terminator}`)
      }
    }
    if (options.modified || options.deleted) {
      const entries = index.entries
        .filter(entry => entry.stage === 0)
        .sort((left, right) => compareStrings(left.path, right.path))
      for (const entry of entries) {
        if (specs.length > 0 && !selectedByPathspecs(specs, entry.path)) continue
        const info = files.get(entry.path)
        if (info === undefined || info.isDirectory) {
          if (options.deleted) {
            matched += 1
            context.output.stdout(`${entry.path}${terminator}`)
          }
          continue
        }
        if (options.modified) {
          const blob = await readWorktreeBlob(context.fs, repository, requireWorkTree(repository), entry.path)
          if (blob !== undefined && blob.oid !== entry.oid) {
            matched += 1
            context.output.stdout(`${entry.path}${terminator}`)
          }
        }
      }
    }
  }
  if (options.errorUnmatch && matched === 0 && specs.length > 0) {
    throw fatal(`pathspec '${specs[0]?.path ?? ''}' did not match any file(s) known to git`)
  }
  return 0
}

/** `git check-ignore`. */
export async function checkIgnore(context: CommandContext): Promise<number> {
  let nul = false
  let quiet = false
  let stdinPaths = false
  let noIndex = false
  const args: string[] = []
  for (const arg of context.args) {
    if (arg === '-z') nul = true
    else if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg === '--stdin') stdinPaths = true
    else if (arg === '--no-index') noIndex = true
    else if (arg === '-v' || arg === '--verbose') {
      throw fatal('check-ignore --verbose is not supported by the Worker git (line-numbered rule output)')
    }
    else if (arg === '--') continue
    else if (arg.startsWith('-')) throw fatal(`unsupported check-ignore option '${arg}'`, 129)
    else args.push(arg)
  }
  const repository = await context.repository()
  const workTree = requireWorkTree(repository)
  const index = noIndex ? { version: 2, entries: [] } : await loadIndex(repository)
  const ignores = await loadIgnoreRules(repository, workTree, noIndex ? new Set() : trackedPaths(index))
  const inputs = stdinPaths
    ? (nul ? splitNul(context.stdin) : decodeText(context.stdin).split('\n').filter(line => line !== ''))
    : args
  let ignoredCount = 0
  for (const input of inputs) {
    const relative = workTreePath(repository, context.cwd, input)
    if (isIgnored(ignores, relative, false)) {
      ignoredCount += 1
      if (!quiet) context.output.stdout(`${input}${nul ? '\0' : '\n'}`)
    }
  }
  return ignoredCount > 0 ? 0 : 1
}
