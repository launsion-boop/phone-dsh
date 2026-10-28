// SPDX-License-Identifier: MIT
/**
 * Porcelain that changes the working tree or the index: `add`, `status`,
 * `commit` (including `--amend`), `restore`, `rm` and `init`.
 *
 * Every write here is an ordinary Worker VFS mutation (PLAN D12): blobs and
 * index entries are written through the same `node:fs` the runtime uses, so the
 * WAL sink sees them before the tool result is journaled. `status` compares
 * three snapshots — HEAD tree, index and work tree — and reproduces git's
 * `--porcelain=v1` (including `-z`) format because that is what an agent reads.
 * @module @phone-dsh/dsh-wasi-toolbox/git/porcelain
 */
import { errorFailure, fatal } from './errors.ts'
import { compareStrings, decodeText, encodeText } from './fs.ts'
import { statEntry, writeIndex } from './gindex.ts'
import type { GitIndex, IndexEntry } from './gindex.ts'
import { isIgnored } from './ignore.ts'
import { objectId } from './objects.ts'
import {
  flattenTree, headOid, headRef, readCommit, requireWorkTree, resolveRevision, writeRef,
} from './repo.ts'
import type { Repository, Signature } from './repo.ts'
import { buildTreeFromIndex, diffFlatTrees, parseMode, readWorktreeBlob } from './tree.ts'
import type { TreeChange } from './tree.ts'
import { countDiff, isBinary, splitLines } from './textdiff.ts'
import { ensureParent, removeWorktreePath, scanWorktree } from './worktree.ts'
import { wildmatchBytes, wildmatchPathnameBytes } from './wildmatch.ts'
import type { CommandContext } from './cli.ts'
import {
  hasGlobMetacharacters, loadIgnores, loadIndex, matchesPathspec, parsePathspec, pathspecSelector,
  selectedByPathspecs, trackedPaths,
} from './inspect.ts'
import type { Pathspec } from './inspect.ts'

/** One status row. */
export interface StatusRow {
  readonly path: string
  readonly oldPath?: string
  /** Index-vs-HEAD status code. */
  readonly indexStatus: string
  /** Work-tree-vs-index status code. */
  readonly worktreeStatus: string
}

/** A tree-shaped map entry (mode text plus blob id). */
interface SnapshotEntry {
  readonly mode: string
  readonly oid: string
}

/** HEAD's tree as path → mode/oid; empty for an unborn branch. */
export async function headTree(repository: Repository): Promise<Map<string, SnapshotEntry>> {
  const oid = await headOid(repository)
  if (oid === undefined) return new Map()
  const commit = await readCommit(repository, oid)
  return await flattenTree(repository, commit.tree)
}

function indexTree(index: GitIndex): Map<string, SnapshotEntry> {
  const map = new Map<string, SnapshotEntry>()
  for (const entry of index.entries) {
    if (entry.stage !== 0) {
      // An unmerged path is shown as unmerged by status; keep the first stage
      // so the path still participates in the comparison.
      if (!map.has(entry.path)) map.set(entry.path, { mode: entry.mode.toString(8), oid: entry.oid })
      continue
    }
    map.set(entry.path, { mode: entry.mode.toString(8), oid: entry.oid })
  }
  return map
}

/** Staged changes (HEAD tree vs index). */
export async function stagedChanges(
  repository: Repository,
  index: GitIndex,
  select?: (path: string) => boolean,
): Promise<TreeChange[]> {
  return await diffFlatTrees(repository, await headTree(repository), indexTree(index), { renames: true, select })
}

/** Unstaged changes (index vs work tree). */
export async function unstagedChanges(repository: Repository, index: GitIndex): Promise<TreeChange[]> {
  const workTree = requireWorkTree(repository)
  const files = await scanWorktree(repository)
  const changes: TreeChange[] = []
  for (const entry of index.entries) {
    if (entry.stage !== 0) continue
    const info = files.get(entry.path)
    if (info === undefined || info.isDirectory) {
      changes.push({ path: entry.path, status: 'D', oldMode: entry.mode.toString(8), oldOid: entry.oid })
      continue
    }
    const blob = await readWorktreeBlob(repository.fs, repository, workTree, entry.path)
    if (blob === undefined) continue
    if (blob.oid !== entry.oid || parseMode(blob.mode) !== entry.mode) {
      changes.push({
        path: entry.path,
        status: blob.mode === entry.mode.toString(8) || parseMode(blob.mode) === entry.mode ? 'M' : 'T',
        oldMode: entry.mode.toString(8),
        newMode: blob.mode,
        oldOid: entry.oid,
        newOid: blob.oid,
      })
    }
  }
  return changes.sort((left, right) => compareStrings(left.path, right.path))
}

/** Every ancestor directory of a repository-relative path, shallowest first. */
function parentDirectories(path: string): string[] {
  const parts = path.split('/')
  const directories: string[] = []
  for (let index = 1; index < parts.length; index += 1) directories.push(parts.slice(0, index).join('/'))
  return directories
}

/** True when git may collapse this untracked directory into one `?? dir/` row. */
function isCollapsibleDirectory(
  directory: string,
  files: Map<string, { isDirectory: boolean }>,
  tracked: ReadonlySet<string>,
): boolean {
  return files.get(directory)?.isDirectory === true
    && !tracked.has(directory)
    && !hasTrackedUnder(tracked, directory)
}

/**
 * True when a pathspec reaches a parent directory for `status` collapsing.
 *
 * The caller only asks this for directories above a file the pathspec already
 * selected, so a wildcard cannot manufacture a directory row from a path git
 * would never list. With the default `-unormal` report git shows `?? dir/`
 * when the directory itself is inside the pathspec; then every file below it
 * is part of the result. A non-directory patternspec matches the directory
 * spelling with its trailing slash, which is why `:(glob)u/*` includes
 * `u/deep/x` while `:(glob)u/*.txt` does not. A directory-only literal (`u/`)
 * already matches its directory directly, so it needs no extra slash.
 */
function directoryIncludedBySpec(spec: Pathspec, directory: string): boolean {
  if (spec.directoryOnly) {
    // A literal `dir/` matches the directory path itself even though the file
    // matcher deliberately refuses it (only paths below `dir` are files).
    return directory === spec.path || matchesPathspec(spec, directory)
  }
  return matchesPathspec(spec, `${directory}/`)
}

/**
 * True when an exclude pathspec prunes a whole directory.
 *
 * Git tests a directory with its trailing slash. A non-directory pattern such
 * as `:(exclude)??` or `:(glob,exclude)u*` is matched against `dir/`, which is
 * why the former prunes the root directory `u` while the latter does not. A
 * directory-only pattern keeps that trailing slash on both sides: the
 * normalized bare `u*` plus `/` is matched against `u/`, and a terminal
 * globstar plus `/` is matched against `u/`; matching the bare `u*` against
 * `u` instead would incorrectly make the `u/[star]/` spelling prune `u`
 * itself. A literal directory name is an exact comparison, never a wildcard.
 */
function directoryExcludedBySpec(spec: Pathspec, directory: string): boolean {
  if (spec.directoryOnly) {
    if (spec.literal || !hasGlobMetacharacters(spec.path)) return directory === spec.path
    const pattern = encodeText(`${spec.path}/`)
    const candidate = encodeText(`${directory}/`)
    return spec.glob
      ? wildmatchPathnameBytes(pattern, candidate)
      : wildmatchBytes(pattern, candidate)
  }
  const wildcard = !spec.literal && hasGlobMetacharacters(spec.path)
  if (wildcard) return matchesPathspec(spec, `${directory}/`)
  return matchesPathspec(spec, directory) || matchesPathspec(spec, `${directory}/`)
}

/**
 * True when an exclude pathspec removes an untracked path.
 *
 * Only a directory with no tracked entry below it may be pruned: git still
 * walks a directory that contains tracked files, so an exclude that merely
 * matches its spelling (for example `??` matching `u/`) must not hide the
 * untracked files beside `u/tracked.txt`.
 */
function pathExcludedBySpecs(
  path: string,
  specs: readonly Pathspec[],
  files: Map<string, { isDirectory: boolean }>,
  tracked: ReadonlySet<string>,
): boolean {
  const excludes = specs.filter(spec => spec.exclude)
  if (excludes.length === 0) return false
  const directories = parentDirectories(path)
  return excludes.some(spec =>
    matchesPathspec(spec, path)
    || directories.some(directory =>
      isCollapsibleDirectory(directory, files, tracked)
      && directoryExcludedBySpec(spec, directory)))
}

/** The selected untracked file paths, before directory collapsing. */
function selectUntrackedFiles(
  untracked: readonly string[],
  specs: readonly Pathspec[],
  files: Map<string, { isDirectory: boolean }>,
  tracked: ReadonlySet<string>,
): string[] {
  const includes = specs.filter(spec => !spec.exclude)
  const selected: string[] = []
  for (const path of untracked) {
    const included = includes.length === 0 || includes.some(spec => matchesPathspec(spec, path))
    if (!included) continue
    if (!pathExcludedBySpecs(path, specs, files, tracked)) selected.push(path)
  }
  return selected
}

/**
 * Collapse one selected file to the directory row git prints.
 *
 * With an include pathspec git only collapses a directory that the pathspec
 * itself reaches (`u/*`, `u/deep/`); a pattern that only selects files
 * keeps printing those files. An exclude-only list behaves like
 * an unqualified status: every remaining untracked directory collapses.
 */
function collapsedUntrackedPath(
  path: string,
  specs: readonly Pathspec[],
  mode: 'normal' | 'all',
  files: Map<string, { isDirectory: boolean }>,
  tracked: ReadonlySet<string>,
): string {
  if (mode === 'all') return ''
  const includes = specs.filter(spec => !spec.exclude)
  if (includes.length === 0) return findCollapsibleDirectory(path, files, tracked)
  for (const directory of parentDirectories(path)) {
    if (!isCollapsibleDirectory(directory, files, tracked)) continue
    if (includes.some(spec => directoryIncludedBySpec(spec, directory))) return directory
  }
  return ''
}

/** Untracked paths, with directory collapsing (`status -unormal` default). */
export async function untrackedPaths(
  repository: Repository,
  index: GitIndex,
  mode: 'no' | 'normal' | 'all',
  specs: readonly Pathspec[] = [],
): Promise<string[]> {
  if (mode === 'no') return []
  const files = await scanWorktree(repository)
  const tracked = trackedPaths(index)
  const ignores = await loadIgnores(repository, index)
  const untracked: string[] = []
  for (const [path, info] of files) {
    if (info.isDirectory) continue
    if (tracked.has(path)) continue
    if (isIgnored(ignores, path, false)) continue
    untracked.push(path)
  }
  const selected = selectUntrackedFiles(untracked, specs, files, tracked)
  if (mode === 'all') return selected.sort(compareStrings)
  const collapsed: string[] = []
  const hidden: string[] = []
  for (const path of selected.sort(compareStrings)) {
    if (hidden.some(prefix => path.startsWith(`${prefix}/`))) continue
    const directory = collapsedUntrackedPath(path, specs, mode, files, tracked)
    if (directory !== '') {
      collapsed.push(`${directory}/`)
      hidden.push(directory)
    } else {
      collapsed.push(path)
    }
  }
  return collapsed
}

/** The shallowest ancestor directory of an untracked file with no tracked entry. */
function findCollapsibleDirectory(
  path: string,
  files: Map<string, { isDirectory: boolean }>,
  tracked: ReadonlySet<string>,
): string {
  const parts = path.split('/')
  for (let index = 1; index < parts.length; index += 1) {
    const candidate = parts.slice(0, index).join('/')
    if (!tracked.has(candidate) && !hasTrackedUnder(tracked, candidate)) {
      // Only collapse when the directory itself exists and the untracked file
      // is not the only thing git would show by name.
      if (files.get(candidate)?.isDirectory === true) return candidate
    }
  }
  return ''
}

function hasTrackedUnder(tracked: ReadonlySet<string>, directory: string): boolean {
  for (const path of tracked) if (path.startsWith(`${directory}/`)) return true
  return false
}

/** Compute the status rows in git's order. */
export async function statusRows(
  repository: Repository,
  index: GitIndex,
  untrackedMode: 'no' | 'normal' | 'all',
  specs: readonly Pathspec[] = [],
): Promise<StatusRow[]> {
  const select = pathspecSelector(specs)
  // Restrict HEAD and index before rename pairing so a pathspec that selects
  // only one side of a staged rename yields the deletion or addition git shows.
  const staged = await stagedChanges(repository, index, select)
  const unstaged = new Map<string, TreeChange>()
  for (const change of await unstagedChanges(repository, index)) unstaged.set(change.path, change)
  const rows: StatusRow[] = []
  const seen = new Set<string>()
  for (const change of staged) {
    seen.add(change.path)
    const worktree = unstaged.get(change.path)
    rows.push({
      path: change.path,
      ...change.oldPath === undefined ? {} : { oldPath: change.oldPath },
      indexStatus: change.status,
      worktreeStatus: worktree?.status ?? ' ',
    })
  }
  for (const [path, change] of unstaged) {
    if (seen.has(path)) continue
    rows.push({ path, indexStatus: ' ', worktreeStatus: change.status })
  }
  rows.sort((left, right) => compareStrings(left.path, right.path))
  for (const path of await untrackedPaths(repository, index, untrackedMode, specs)) {
    rows.push({ path, indexStatus: '?', worktreeStatus: '?' })
  }
  return rows
}

/** `git status`. */
export async function status(context: CommandContext): Promise<number> {
  let porcelain = false
  let nul = false
  let untrackedMode: 'no' | 'normal' | 'all' = 'normal'
  let showBranch = false
  const pathArgs: string[] = []
  for (const arg of context.args) {
    if (arg === '--porcelain' || arg === '--porcelain=v1') porcelain = true
    else if (arg === '--short' || arg === '-s') porcelain = true
    // `--long` is git's default report: after a `--short` it restores it.
    else if (arg === '--long') porcelain = false
    else if (arg === '-z') nul = true
    else if (arg === '-b' || arg === '--branch') showBranch = true
    else if (arg === '-uno' || arg === '--untracked-files=no') untrackedMode = 'no'
    else if (arg === '-unormal' || arg === '--untracked-files=normal') untrackedMode = 'normal'
    else if (arg === '-uall' || arg === '--untracked-files=all') untrackedMode = 'all'
    else if (arg === '--ignored' || arg === '--ignored=traditional') {
      // Listing ignored files is a different status report; a normal status
      // must not be returned as if the filter had been applied.
      throw fatal("unsupported status option '--ignored': the Worker git does not list ignored files. Nothing was printed.", 129)
    }
    else if (arg === '--') continue
    else if (arg.startsWith('-')) throw fatal(`unsupported status option '${arg}'`, 129)
    else pathArgs.push(arg)
  }
  const repository = await context.repository()
  const index = await loadIndex(repository)
  const specs = pathArgs.map(path => parsePathspec(repository, context.cwd, path))
  let rows = await statusRows(repository, index, untrackedMode, specs)
  if (specs.length > 0) rows = rows.filter(row => selectedByPathspecs(specs, row.path))
  // `--long` is git's default report (the flag only overrides an earlier
  // `--short`); the short porcelain rows are printed only when requested.
  if (!porcelain) {
    const unborn = (await headOid(repository)) === undefined ? 'status' : undefined
    await renderLongStatus(context, repository, index, rows, unborn)
    return 0
  }
  if (showBranch) {
    const branch = await currentBranchName(repository)
    context.output.stdout(`## ${branch ?? 'HEAD (no branch)'}${nul ? '\0' : '\n'}`)
  }
  for (const row of rows) {
    if (row.indexStatus === '?' && row.worktreeStatus === '?') {
      context.output.stdout(`?? ${row.path}${nul ? '\0' : '\n'}`)
      continue
    }
    const codes = `${row.indexStatus}${row.worktreeStatus}`
    if (row.oldPath !== undefined) {
      if (nul) context.output.stdout(`${codes} ${row.path}\0${row.oldPath}\0`)
      else context.output.stdout(`${codes} ${row.oldPath} -> ${row.path}\n`)
    } else {
      context.output.stdout(`${codes} ${row.path}${nul ? '\0' : '\n'}`)
    }
  }
  return 0
}

/** The branch HEAD points at (undefined when detached). */
export async function currentBranchName(repository: Repository): Promise<string | undefined> {
  const symbolic = await headRef(repository)
  return symbolic?.replace(/^refs\/heads\//, '')
}

/**
 * Render git's long status report.
 *
 * The report is shared by `git status` and the `git commit` precondition: when
 * nothing is staged, real git prints the work-tree report (including unstaged
 * modifications) and exits 1, while a genuinely clean tree prints the
 * "nothing to commit, working tree clean" line. `unborn` adds the two headers
 * git only shows before the first commit ("No commits yet" for status,
 * "Initial commit" for commit) and selects the unborn-branch wording.
 */
async function renderLongStatus(
  context: CommandContext,
  repository: Repository,
  index: GitIndex,
  rows: readonly StatusRow[],
  unborn?: 'status' | 'commit',
): Promise<void> {
  const branch = await currentBranchName(repository)
  context.output.stdout(`On branch ${branch ?? 'HEAD (no branch)'}\n`)
  if (unborn !== undefined) {
    context.output.stdout(`\n${unborn === 'commit' ? 'Initial commit' : 'No commits yet'}\n\n`)
  }
  const staged = rows.filter(row => row.indexStatus !== ' ' && row.indexStatus !== '?')
  const unstaged = rows.filter(row => row.worktreeStatus !== ' ' && row.worktreeStatus !== '?')
  const untracked = rows.filter(row => row.indexStatus === '?')
  if (staged.length > 0) {
    context.output.stdout('Changes to be committed:\n')
    // Before the first commit git cannot restore a path from HEAD, so it
    // offers `git rm --cached` instead of `git restore --staged`.
    context.output.stdout(`  (use "git ${unborn === undefined ? 'restore --staged' : 'rm --cached'} <file>..." to unstage)\n`)
    for (const row of staged) {
      if (row.indexStatus === 'R') {
        context.output.stdout(`\t${'renamed:'.padEnd(12)}${row.oldPath ?? ''} -> ${row.path}\n`)
      } else {
        const label = row.indexStatus === 'A' ? 'new file:' : row.indexStatus === 'D' ? 'deleted:' : 'modified:'
        context.output.stdout(`\t${label.padEnd(12)}${row.path}\n`)
      }
    }
    context.output.stdout('\n')
  }
  if (unstaged.length > 0) {
    context.output.stdout('Changes not staged for commit:\n')
    // A deleted path is updated with `git add/rm`; if every unstaged path is a
    // modification, git offers the narrower `git add`.
    const update = unstaged.some(row => row.worktreeStatus === 'D') ? 'git add/rm' : 'git add'
    context.output.stdout(`  (use "${update} <file>..." to update what will be committed)\n`)
    context.output.stdout('  (use "git restore <file>..." to discard changes in working directory)\n')
    for (const row of unstaged) {
      const label = row.worktreeStatus === 'D' ? 'deleted:' : row.worktreeStatus === 'T' ? 'typechange:' : 'modified:'
      context.output.stdout(`\t${label.padEnd(12)}${row.path}\n`)
    }
    context.output.stdout('\n')
  }
  if (untracked.length > 0) {
    context.output.stdout('Untracked files:\n')
    context.output.stdout('  (use "git add <file>..." to include in what will be committed)\n')
    for (const row of untracked) context.output.stdout(`\t${row.path}\n`)
    context.output.stdout('\n')
  }
  if (staged.length === 0 && unstaged.length === 0 && untracked.length === 0) {
    context.output.stdout(unborn === undefined
      ? 'nothing to commit, working tree clean\n'
      : 'nothing to commit (create/copy files and use "git add" to track)\n')
  } else if (staged.length === 0 && unstaged.length === 0) {
    context.output.stdout('nothing added to commit but untracked files present (use "git add" to track)\n')
  } else if (staged.length === 0) {
    context.output.stdout('no changes added to commit (use "git add" and/or "git commit -a")\n')
  }
  void index
}

/** Options of one `git restore` invocation. */
interface RestoreOptions {
  readonly staged: boolean
  readonly worktree: boolean
  readonly source?: string | undefined
  readonly pathArgs: readonly string[]
}

function parseRestoreOptions(args: readonly string[]): RestoreOptions {
  let staged = false
  let worktree = false
  let source: string | undefined
  const pathArgs: string[] = []
  let pathsOnly = false
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (pathsOnly) {
      pathArgs.push(arg)
      continue
    }
    if (arg === '--') {
      pathsOnly = true
    } else if (arg === '--staged' || arg === '-S') {
      staged = true
    } else if (arg === '--worktree' || arg === '-W') {
      worktree = true
    } else if (arg === '--source' || arg === '-s') {
      const value = args[index + 1]
      if (value === undefined) throw fatal('restore: --source requires a tree-ish', 129)
      source = value
      index += 1
    } else if (arg.startsWith('--source=')) {
      source = arg.slice('--source='.length)
    } else if (arg.startsWith('-')) {
      throw fatal(`unsupported restore option '${arg}'`, 129)
    } else {
      pathArgs.push(arg)
    }
  }
  // The default is the work tree; specifying only --staged leaves the work
  // tree alone (git's -W/-S pair selects the two targets independently).
  return { staged, worktree: worktree || !staged, source, pathArgs }
}

/** Read the tree a restore should take its content from. */
async function restoreSourceTree(repository: Repository, expression: string): Promise<Map<string, SnapshotEntry>> {
  if (expression === 'HEAD' && (await headOid(repository)) === undefined) throw fatal('could not resolve HEAD')
  const oid = await resolveRevision(repository, expression)
  const type = await repository.odb.type(oid)
  if (type === 'tree') return await flattenTree(repository, oid)
  if (type !== 'commit') throw fatal(`object ${oid} is a ${type}, not a tree`)
  return await flattenTree(repository, (await readCommit(repository, oid)).tree)
}

interface RestoreRequest {
  readonly specs: readonly Pathspec[]
  /** The argv pathspecs, used verbatim in git's unmatched-pathspec error. */
  readonly pathArgs: readonly string[]
  readonly staged: boolean
  readonly worktree: boolean
  /** Explicit source tree, or the HEAD tree for a staged-only restore. */
  readonly sourceTree?: Map<string, SnapshotEntry> | undefined
}

/**
 * The one restore primitive: copy blobs from a source snapshot into the work
 * tree and/or the index.
 *
 * `git restore` and `git checkout -- <paths>` both call this, so the two
 * spellings cannot drift. A work-tree restore with no explicit source reads
 * the index; with `--source` it reads that tree and removes work-tree paths
 * that the index tracks but the source does not (git's checkout semantics).
 * A `--staged` restore writes the index from the source and leaves the work
 * tree untouched unless `--worktree` is also given.
 */
async function applyRestore(context: CommandContext, repository: Repository, request: RestoreRequest): Promise<number> {
  const workTree = requireWorkTree(repository)
  const index = await loadIndex(repository)
  const indexSnapshot = new Map<string, SnapshotEntry>()
  for (const entry of index.entries) {
    if (entry.stage === 0) indexSnapshot.set(entry.path, { mode: entry.mode.toString(8), oid: entry.oid })
  }
  const worktreeSource = request.sourceTree ?? indexSnapshot
  const worktreePaths = new Set<string>(worktreeSource.keys())
  if (request.sourceTree !== undefined) {
    for (const entry of index.entries) if (entry.stage === 0) worktreePaths.add(entry.path)
  }
  // Validate every include pathspec before touching the work tree or the
  // index, so a command with one unmatched path changes nothing (git checks
  // the whole argument list first).
  if (request.specs.length > 0) {
    const universe = new Set<string>(worktreePaths)
    if (request.sourceTree !== undefined) for (const path of request.sourceTree.keys()) universe.add(path)
    for (let index = 0; index < request.specs.length; index += 1) {
      const spec = request.specs[index] as Pathspec
      if (spec.exclude) continue
      if (![...universe].some(path => matchesPathspec(spec, path))) {
        throw errorFailure(`pathspec '${request.pathArgs[index] ?? ''}' did not match any file(s) known to git`, 1)
      }
    }
  }
  if (request.worktree) {
    const paths = worktreePaths
    for (const path of [...paths].sort(compareStrings)) {
      if (!selectedByPathspecs(request.specs, path)) continue
      const entry = worktreeSource.get(path)
      if (entry === undefined) {
        await removeWorktreePath(context.fs, workTree, path)
        continue
      }
      const data = (await repository.odb.read(entry.oid)).data
      await ensureParent(context.fs, workTree, path)
      await removeWorktreePath(context.fs, workTree, path)
      await context.fs.writeFile(`${workTree}/${path}`, data, parseMode(entry.mode))
    }
  }
  if (request.staged) {
    const source = request.sourceTree as Map<string, SnapshotEntry>
    const paths = new Set<string>(source.keys())
    for (const entry of index.entries) if (entry.stage === 0) paths.add(entry.path)
    let entries = [...index.entries]
    for (const path of [...paths].sort(compareStrings)) {
      if (!selectedByPathspecs(request.specs, path)) continue
      entries = entries.filter(entry => entry.path !== path)
      const target = source.get(path)
      if (target !== undefined) {
        entries.push(await restoredIndexEntry(context, repository, workTree, path, target))
      }
    }
    entries.sort((left, right) => compareStrings(left.path, right.path) || left.stage - right.stage)
    await writeIndex(context.fs, repository.indexPath, { version: 2, entries })
  }
  return 0
}

/** Restore work-tree paths from the index, shared with `checkout -- <paths>`. */
export async function restoreWorktreePaths(
  context: CommandContext,
  repository: Repository,
  pathArgs: readonly string[],
): Promise<number> {
  const specs = pathArgs.map(path => parsePathspec(repository, context.cwd, path))
  return await applyRestore(context, repository, {
    specs,
    pathArgs,
    staged: false,
    worktree: true,
  })
}

/**
 * Build the index entry for a blob restored from a source tree.
 *
 * The stat cache may only describe work-tree bytes that are known to equal the
 * blob. When the work-tree file still holds different content (the common
 * `git restore --staged` case) the entry gets a zero stat so the next status
 * hashes the file; copying that file's stat onto the source oid made the
 * system git trust a stale cache and report a dirty file as clean (G2-B06).
 */
async function restoredIndexEntry(
  context: CommandContext,
  repository: Repository,
  workTree: string,
  path: string,
  target: SnapshotEntry,
): Promise<IndexEntry> {
  const mode = parseMode(target.mode)
  const blob = await readWorktreeBlob(context.fs, repository, workTree, path)
  if (blob !== undefined && blob.oid === target.oid && parseMode(blob.mode) === mode) {
    return await statEntry(context.fs, workTree, path, target.oid, mode)
  }
  return {
    path,
    mode,
    oid: target.oid,
    stage: 0,
    ctimeSeconds: 0,
    ctimeNanoseconds: 0,
    mtimeSeconds: 0,
    mtimeNanoseconds: 0,
    device: 0,
    ino: 0,
    uid: 0,
    gid: 0,
    size: 0,
    assumeValid: false,
  }
}

/** `git restore`: undo work-tree and/or index changes from a source tree. */
export async function restore(context: CommandContext): Promise<number> {
  const options = parseRestoreOptions(context.args)
  if (options.pathArgs.length === 0) throw fatal('you must specify path(s) to restore')
  const repository = await context.repository()
  const specs = options.pathArgs.map(path => parsePathspec(repository, context.cwd, path))
  let sourceTree: Map<string, SnapshotEntry> | undefined
  if (options.source !== undefined) {
    sourceTree = await restoreSourceTree(repository, options.source)
  } else if (options.staged) {
    if ((await headOid(repository)) === undefined) throw fatal('could not resolve HEAD')
    sourceTree = await headTree(repository)
  }
  return await applyRestore(context, repository, {
    specs,
    pathArgs: options.pathArgs,
    staged: options.staged,
    worktree: options.worktree,
    sourceTree,
  })
}

/** `git add`. */
export async function add(context: CommandContext): Promise<number> {
  let all = false
  let update = false
  let ignoreErrors = false
  let dryRun = false
  let verbose = false
  let force = false
  const pathArgs: string[] = []
  for (const arg of context.args) {
    if (arg === '-A' || arg === '--all' || arg === '--no-ignore-removal') all = true
    else if (arg === '-u' || arg === '--update') update = true
    else if (arg === '--ignore-errors') ignoreErrors = true
    else if (arg === '-n' || arg === '--dry-run') dryRun = true
    else if (arg === '-v' || arg === '--verbose') verbose = true
    else if (arg === '-f' || arg === '--force') force = true
    else if (arg === '-N' || arg === '--intent-to-add') throw fatal('add --intent-to-add is not supported by the Worker git')
    else if (arg === '--') continue
    else if (arg.startsWith('-')) throw fatal(`unsupported add option '${arg}'`, 129)
    else pathArgs.push(arg)
  }
  const repository = await context.repository()
  const workTree = requireWorkTree(repository)
  const index = await loadIndex(repository)
  const ignores = await loadIgnores(repository, index)
  const specs = pathArgs.map(path => parsePathspec(repository, context.cwd, path))
  if (!all && !update && specs.length === 0) {
    context.output.stdout('Nothing specified, nothing added.\n')
    context.output.stdout("hint: Maybe you wanted to say 'git add .'?\n")
    context.output.stdout('hint: Disable this message with "git config set advice.addEmptyPathspec false"\n')
    return 0
  }
  const files = await scanWorktree(repository)
  const tracked = new Map<string, IndexEntry>()
  for (const entry of index.entries) {
    if (entry.stage === 0 && !tracked.has(entry.path)) tracked.set(entry.path, entry)
  }
  const trackedSet = new Set(tracked.keys())
  const candidates = new Set<string>()
  const include = (path: string): void => { candidates.add(path) }
  // The same parsed pathspecs decide which work-tree paths are candidates and
  // which candidates the final selection keeps; using one matcher here means
  // `add` follows `ls-files` for default globs and `:(glob)` instead of
  // treating a wildcard as a literal file name. An exclude-only list has no
  // include to narrow the candidate set, so it starts from every path.
  const includes = specs.filter(spec => !spec.exclude)
  const selectedCandidate = (path: string): boolean => includes.length === 0
    || includes.some(spec => matchesPathspec(spec, path))
  // An exclude pathspec that names an untracked directory removes its whole
  // subtree before `add` even walks it, exactly as `status` collapses it. A
  // directory with tracked files is still walked, so only an untracked file
  // can be hidden this way.
  const excludedUntracked = (path: string): boolean => !tracked.has(path)
    && pathExcludedBySpecs(path, specs, files, trackedSet)
  if (all || update) {
    for (const [path, info] of files) {
      if (info.isDirectory) continue
      if (!all && !tracked.has(path)) continue
      if (excludedUntracked(path)) continue
      include(path)
    }
    // `-u` also has to see tracked paths that no longer exist in the work tree:
    // a deletion, or a file that was replaced by a directory, is a candidate
    // whose index entry must be removed. The pathspec filter below still
    // decides whether each path is in scope.
    if (all || update) {
      for (const path of tracked.keys()) {
        if (!files.has(path) || files.get(path)?.isDirectory === true) include(path)
      }
    }
  } else {
    for (const [path, info] of files) {
      if (!info.isDirectory && selectedCandidate(path) && !excludedUntracked(path)) include(path)
    }
    for (const path of tracked.keys()) {
      const info = files.get(path)
      // A tracked path that vanished is a deletion. A tracked file replaced by
      // a directory keeps its spelling in `files`, so `files.has(path)` alone
      // would hide the index entry that has to disappear; add it as a
      // candidate even when only a descendant matches the pathspec.
      if (info === undefined ? selectedCandidate(path) : info.isDirectory) include(path)
    }
  }
  // Validate every include pathspec against the files this add mode would
  // actually consider before touching the index. `-u` only looks at the
  // index; a normal or `-A` add looks at the work tree but never at ignored
  // files unless `--force` asked for them. Git still fails the transaction
  // (exit 128) when one include matches nothing, and a mixed
  // `git add -- b.txt ':(glob)nope*'` must not stage b.txt as a side effect.
  const validationPaths: string[] = []
  if (update) {
    for (const path of tracked.keys()) validationPaths.push(path)
  } else {
    for (const [path, info] of files) {
      if (info.isDirectory) continue
      if (!force && !tracked.has(path) && isIgnored(ignores, path, false)) continue
      validationPaths.push(path)
    }
    for (const path of tracked.keys()) if (!files.has(path)) validationPaths.push(path)
  }
  for (const [specIndex, spec] of specs.entries()) {
    if (spec.exclude) continue
    // The root always exists, even in an empty repository (`git add .`).
    if (spec.path === '') continue
    // A tracked path validates its include pathspec even when an exclude also
    // names it: excludes decide what is staged, not whether an index path the
    // user named exists. A worktree-only candidate, however, must survive the
    // excludes; otherwise `add ':(glob)shape/**'
    // ':(glob,exclude)shape/**'` would pass validation but have nothing left
    // to add.
    if (validationPaths.some(path => matchesPathspec(spec, path)
      && (tracked.has(path) || !pathExcludedBySpecs(path, specs, files, trackedSet)))) continue
    // A non-update literal pathspec may name a directory itself (including an empty

    // one). A glob pathspec only matches files, so `:(glob)emptydir` still
    // fails; a non-empty glob directory was already accepted by the directory
    // prefix inside `matchesPathspec`, exactly like the system git.
    const target = files.get(spec.path)
    if (!update && target?.isDirectory && (spec.literal || (!spec.glob && !hasGlobMetacharacters(spec.path)))) continue
    if (update && target?.isDirectory && (spec.literal || (!spec.glob && !hasGlobMetacharacters(spec.path)))) {
      throw errorFailure(`pathspec '${pathArgs[specIndex] ?? ''}' did not match any file(s) known to git`, 128)
    }
    throw fatal(`pathspec '${pathArgs[specIndex] ?? ''}' did not match any files`)
  }
  // Git walks a directory even when the include pathspec only reaches paths
  // below it. When a tracked file was replaced by a directory, selecting any
  // surviving path under `path/` also selects the index deletion of `path`
  // itself: `:(glob)shape/**` stages `D shape` beside `A shape/inner.txt`.
  const orderedCandidates = [...candidates].sort(compareStrings)
  const selectsTrackedDirectoryReplacement = (path: string): boolean =>
    !update
    && tracked.has(path)
    && files.get(path)?.isDirectory === true
    && orderedCandidates.some(candidate =>
      candidate.startsWith(`${path}/`)
      && (specs.length === 0 || selectedByPathspecs(specs, candidate))
      && !excludedUntracked(candidate))
  let entries = [...index.entries]
  let errors = 0
  const touched: string[] = []
  for (const path of orderedCandidates) {
    if (specs.length > 0 && !selectedByPathspecs(specs, path)
      && !selectsTrackedDirectoryReplacement(path)) continue
    if (excludedUntracked(path)) continue
    const info = files.get(path)
    if (info === undefined || info.isDirectory) {
      if (tracked.has(path) || all) {
        entries = entries.filter(entry => entry.path !== path)
        touched.push(path)
      }
      continue
    }
    const isTracked = tracked.has(path)
    if (!isTracked && !force && isIgnored(ignores, path, false)) continue
    try {
      if (dryRun) {
        touched.push(path)
        continue
      }
      const blob = await readWorktreeBlob(context.fs, repository, workTree, path)
      if (blob === undefined) continue
      const mode = await addMode(repository, tracked.get(path), blob.mode)
      const oid = await repository.odb.write('blob', blob.data)
      entries = entries.filter(entry => entry.path !== path)
      if (verbose) context.output.stdout(`add '${path}'\n`)
      entries.push(await statEntry(context.fs, workTree, path, oid, mode))
      touched.push(path)
    } catch (error) {
      if (!ignoreErrors) {
        throw fatal(`unable to index file '${path}': ${error instanceof Error ? error.message : String(error)}`)
      }
      errors += 1
      context.output.stderr(`error: unable to index file '${path}'\n`)
    }
  }
  if (!dryRun) {
    entries.sort((left, right) => compareStrings(left.path, right.path) || left.stage - right.stage)
    await writeIndex(context.fs, repository.indexPath, { version: 2, entries })
  }
  void touched
  return errors > 0 ? 1 : 0
}

async function addMode(repository: Repository, existing: IndexEntry | undefined, blobMode: string): Promise<number> {
  if (repository.config.getBoolean('core.filemode') !== false) return parseMode(blobMode)
  const current = existing?.mode ?? 0o100644
  const executable = (current & 0o111) !== 0
  return executable ? 0o100755 : 0o100644
}

/** `git rm`. */
export async function rm(context: CommandContext): Promise<number> {
  const pathArgs: string[] = []
  let cached = false
  let force = false
  for (const arg of context.args) {
    if (arg === '--cached') cached = true
    else if (arg === '-f' || arg === '--force') force = true
    else if (arg === '-r') continue
    else if (arg === '--') continue
    else if (arg.startsWith('-')) throw fatal(`unsupported rm option '${arg}'`, 129)
    else pathArgs.push(arg)
  }
  if (pathArgs.length === 0) throw fatal('rm: missing paths', 129)
  const repository = await context.repository()
  const workTree = requireWorkTree(repository)
  const index = await loadIndex(repository)
  const specs = pathArgs.map(path => parsePathspec(repository, context.cwd, path))
  const files = await scanWorktree(repository)
  // Validate every include pathspec against the index before removing a work
  // tree file or writing the index. Git fails the whole transaction when a
  // mixed list contains one pathspec that matches nothing.
  for (const [specIndex, spec] of specs.entries()) {
    if (spec.exclude) continue
    if (index.entries.some(entry => entry.stage === 0 && matchesPathspec(spec, entry.path))) continue
    throw fatal(`pathspec '${pathArgs[specIndex] ?? ''}' did not match any files`)
  }
  const selected = index.entries.filter(entry => entry.stage === 0 && selectedByPathspecs(specs, entry.path))
  const removed: string[] = []
  for (const entry of selected) {
    const info = files.get(entry.path)
    if (info !== undefined && !cached) {
      const blob = await readWorktreeBlob(context.fs, repository, workTree, entry.path)
      if (blob !== undefined && blob.oid !== entry.oid && !force) {
        throw fatal(`the following file has local modifications: ${entry.path} (use --force to remove it)`)
      }
      await removeWorktreePath(context.fs, workTree, entry.path)
    }
    removed.push(entry.path)
  }
  // An include that matched the index but whose paths were all excluded is a
  // successful no-op, as are exclude-only lists with nothing left.
  if (removed.length === 0) return 0
  const remaining = index.entries.filter(entry => !removed.includes(entry.path))
  await writeIndex(context.fs, repository.indexPath, { version: 2, entries: remaining })
  for (const path of removed.sort(compareStrings)) context.output.stdout(`rm '${path}'\n`)
  return 0
}

/** `git init`. */
export async function init(context: CommandContext): Promise<number> {
  let bare = false
  let quiet = false
  let initialBranch: string | undefined
  const rest: string[] = []
  const args = [...context.args]
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (arg === '--bare') bare = true
    else if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg === '-b' || arg === '--initial-branch') {
      const value = args[index + 1]
      if (value === undefined) throw fatal('init: -b requires a branch name', 129)
      initialBranch = value
      index += 1
    } else if (arg.startsWith('--initial-branch=')) initialBranch = arg.slice('--initial-branch='.length)
    else if (arg === '--template' || arg === '--separate-git-dir') {
      throw fatal(`init ${arg} is not supported by the Worker git`, 129)
    }
    else if (arg.startsWith('-')) throw fatal(`unsupported init option '${arg}'`, 129)
    else rest.push(arg)
  }
  const directory = rest[0] === undefined ? context.cwd : context.absolute(rest[0])
  const repositoryDirectory = bare ? directory : `${directory}/.git`
  const fs = context.fs
  const already = await fs.exists(`${repositoryDirectory}/config`)
  await fs.mkdir(repositoryDirectory, true)
  await fs.mkdir(`${repositoryDirectory}/objects/info`, true)
  await fs.mkdir(`${repositoryDirectory}/objects/pack`, true)
  await fs.mkdir(`${repositoryDirectory}/refs/heads`, true)
  await fs.mkdir(`${repositoryDirectory}/refs/tags`, true)
  await fs.mkdir(`${repositoryDirectory}/info`, true)
  if (!already) {
    const branch = initialBranch ?? 'master'
    const configText = `[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = ${bare ? 'true' : 'false'}\n${bare ? '' : '\tlogallrefupdates = true\n'}`
    await fs.writeFile(`${repositoryDirectory}/config`, configText)
    await fs.writeFile(`${repositoryDirectory}/HEAD`, `ref: refs/heads/${branch}\n`)
    await fs.writeFile(`${repositoryDirectory}/description`, "Unnamed repository; edit this file 'description' to name the repository.\n")
    await fs.writeFile(`${repositoryDirectory}/info/exclude`, '# git ls-files --others --exclude-from=.git/info/exclude\n')
  } else if (initialBranch !== undefined) {
    // `git init -b` on an existing repository only repoints an unborn HEAD.
    const head = decodeText(await fs.readFile(`${repositoryDirectory}/HEAD`))
    if (head.trim().startsWith('ref:') && !(await fs.exists(`${repositoryDirectory}/refs/heads/${initialBranch}`))) {
      await fs.writeFile(`${repositoryDirectory}/HEAD`, `ref: refs/heads/${initialBranch}\n`)
    }
  }
  if (!quiet) {
    const real = await fs.realpath(directory)
    const suffix = bare ? '/' : '/.git/'
    context.output.stdout(`${already ? 'Reinitialized existing' : 'Initialized empty'} Git repository in ${real}${suffix}\n`)
  }
  return 0
}

/** The empty tree, the comparison base of an amended root commit. */
const EMPTY_TREE = objectId('tree', new Uint8Array(0))

/** `git commit` (including `--amend`). */
export async function commit(context: CommandContext): Promise<number> {  const messages: string[] = []
  let all = false
  let allowEmpty = false
  let quiet = false
  let amend = false
  let noEdit = false
  let authorOverride: string | undefined
  for (let index = 0; index < context.args.length; index += 1) {
    const arg = context.args[index] as string
    if (arg === '-m' || arg === '--message') {
      const value = context.args[index + 1]
      if (value === undefined) throw fatal('switch `m` requires a value', 129)
      messages.push(value)
      index += 1
    } else if (arg.startsWith('-m') && arg.length > 2) {
      messages.push(arg.slice(2))
    } else if (arg === '-a' || arg === '--all') all = true
    else if (arg === '--allow-empty') allowEmpty = true
    else if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg === '--amend') amend = true
    else if (arg === '--no-edit') noEdit = true
    else if (arg === '--edit' || arg === '-e') {
      throw fatal("unsupported commit option '--edit': the Worker git has no editor; pass -m or --no-edit. Nothing was committed.", 129)
    } else if (arg === '--author') {
      authorOverride = context.args[index + 1]
      index += 1
    } else if (arg.startsWith('--author=')) authorOverride = arg.slice('--author='.length)
    else if (arg === '--no-verify' || arg === '--no-gpg-sign') continue
    else if (arg === '--verbose' || arg === '-v') {
      throw fatal("unsupported commit option '--verbose': the Worker git does not print the commit diff. Nothing was committed.", 129)
    }
    else if (arg === '--') continue
    else if (arg.startsWith('-')) throw fatal(`unsupported commit option '${arg}'`, 129)
    else throw fatal(`commit pathspec '${arg}' is not supported by the Worker git; run \`git add\` first`)
  }
  // `--no-edit` is the only message source that needs no editor: it reuses
  // HEAD's message on an amend. Everything else passes -m, exactly like the
  // non-amend path; there is no interactive editor in the Worker.
  if (messages.length === 0 && !(amend && noEdit)) {
    throw fatal(amend
      ? 'commit --amend needs a message: pass -m <message> or --no-edit (the Worker git has no editor)'
      : 'commit message is required (-m <message>); the Worker git has no editor')
  }
  const repository = await context.repository()
  const workTree = requireWorkTree(repository)
  if (all) await stageTracked(context, repository, workTree)
  const index = await loadIndex(repository)
  const tree = await buildTreeFromIndex(repository, index)
  const head = await headOid(repository)
  if (amend && head === undefined) throw fatal('You have nothing to amend.')
  const amended = amend ? await readCommit(repository, head as string) : undefined
  // An amend replaces HEAD but keeps its parents; a normal commit appends to
  // HEAD. The difference is what makes the branch move to the new object.
  const parents = amended === undefined ? (head === undefined ? [] : [head]) : amended.parents
  if (!allowEmpty) {
    // The precondition is the whole report, not just the index: a work tree
    // with unstaged modifications has no staged change but is *not* clean.
    // Comparing only the index tree against HEAD hid those modifications and
    // reported a clean tree for a dirty checkout (G2-B07), so the same status
    // computation `git status` uses decides what the caller sees. An amend is
    // empty when the new tree matches the tree of the commit it will replace
    // as seen from *its* parent, so a root amend is compared with the empty
    // tree instead of being always allowed.
    const comparison = amended === undefined
      ? (head === undefined ? undefined : (await readCommit(repository, head)).tree)
      : (parents[0] === undefined ? EMPTY_TREE : (await readCommit(repository, parents[0] as string)).tree)
    const empty = amended === undefined
      ? (head === undefined ? !index.entries.some(entry => entry.stage === 0) : tree === comparison)
      : tree === comparison
    if (empty) {
      if (amended !== undefined) {
        // The system git answers an amend that would create an empty commit
        // with the branch plus "No changes" and this hint; no report sections.
        const branch = await currentBranchName(repository)
        context.output.stdout(`On branch ${branch ?? 'HEAD (no branch)'}\nNo changes\n`)
        context.output.stdout(
          'You asked to amend the most recent commit, but doing so would make\n'
          + 'it empty. You can repeat your command with --allow-empty, or you can\n'
          + 'remove the commit entirely with "git reset HEAD^".\n',
        )
        return 1
      }
      const rows = await statusRows(repository, index, 'normal')
      await renderLongStatus(context, repository, index, rows, head === undefined ? 'commit' : undefined)
      return 1
    }
  }
  const identity = commitIdentity(context, repository, authorOverride, amended?.author)
  const message = cleanCommitMessage(messages.length > 0 ? messages.join('\n\n') : (amended?.message ?? ''))
  const chunks: string[] = [`tree ${tree}\n`]
  for (const parent of parents) chunks.push(`parent ${parent}\n`)
  chunks.push(`author ${identity.author}\n`)
  chunks.push(`committer ${identity.committer}\n`)
  const body = `${chunks.join('')}\n${message}\n`
  const oid = await repository.odb.write('commit', encodeText(body))
  const ref = await updateCurrentBranch(repository, oid)
  if (!quiet) {
    const branch = ref === 'HEAD' ? 'HEAD' : ref.replace(/^refs\/heads\//, '')
    const detail = await commitSummary(repository, parents[0], oid, tree, parents.length === 0)
    const root = parents.length === 0 ? ' (root-commit)' : ''
    const subject = message.split('\n')[0] ?? ''
    context.output.stdout(`[${branch}${root} ${oid.slice(0, 7)}] ${subject}\n`)
    context.output.stdout(detail)
  }
  return 0
}

function cleanCommitMessage(message: string): string {
  return message.replace(/[ \t]+$/gm, '').replace(/\n+$/, '')
}

interface Identity {
  readonly author: string
  readonly committer: string
}

/**
 * Author/committer idents for one commit.
 *
 * An amend keeps the replaced commit's author (name, email, timestamp and
 * timezone) unless `--author` names a new one, which is what the system git
 * does; the committer is always the current identity. `preservedAuthor` is
 * undefined for a normal commit, where the existing environment/config rules
 * apply unchanged.
 */
function commitIdentity(
  context: CommandContext,
  repository: Repository,
  authorOverride?: string,
  preservedAuthor?: Signature,
): Identity {
  const env = context.env
  const now = Math.floor(Date.now() / 1000)
  let authorName: string | undefined
  let authorEmail: string | undefined
  let authorDate: { timestamp: number; timezone: string }
  if (authorOverride !== undefined) {
    authorName = parseAuthorName(authorOverride)
    authorEmail = parseAuthorEmail(authorOverride)
    // An amended commit keeps the replaced author's date even when --author
    // names a different person; only --reset-author/--date change it, and
    // neither option is implemented here.
    authorDate = preservedAuthor === undefined
      ? parseGitDate(env.GIT_AUTHOR_DATE, now)
      : { timestamp: preservedAuthor.timestamp, timezone: preservedAuthor.timezone }
  } else if (preservedAuthor !== undefined) {
    authorName = preservedAuthor.name
    authorEmail = preservedAuthor.email
    authorDate = { timestamp: preservedAuthor.timestamp, timezone: preservedAuthor.timezone }
  } else {
    authorName = env.GIT_AUTHOR_NAME ?? repository.config.get('user.name')
    authorEmail = env.GIT_AUTHOR_EMAIL ?? repository.config.get('user.email')
    authorDate = parseGitDate(env.GIT_AUTHOR_DATE, now)
  }
  if (authorName === undefined || authorEmail === undefined) {
    throw fatal('unable to auto-detect author identity; set user.name and user.email or GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL')
  }
  // The committer is the current identity. An amend must not inherit the
  // replaced commit's author name through the fallback: git uses user.* for
  // the committer unless GIT_COMMITTER_* is set.
  const committerFallbackName = preservedAuthor === undefined
    ? authorName
    : repository.config.get('user.name') ?? authorName
  const committerFallbackEmail = preservedAuthor === undefined
    ? authorEmail
    : repository.config.get('user.email') ?? authorEmail
  const committerName = env.GIT_COMMITTER_NAME ?? committerFallbackName
  const committerEmail = env.GIT_COMMITTER_EMAIL ?? committerFallbackEmail
  const committerDate = parseGitDate(env.GIT_COMMITTER_DATE, now)
  return {
    author: `${authorName} <${authorEmail}> ${authorDate.timestamp} ${authorDate.timezone}`,
    committer: `${committerName} <${committerEmail}> ${committerDate.timestamp} ${committerDate.timezone}`,
  }
}

function parseAuthorName(text: string): string {
  const match = /^(.*?)\s*<[^>]*>$/.exec(text)
  return match?.[1] ?? text
}

function parseAuthorEmail(text: string): string | undefined {
  return /<([^>]*)>/.exec(text)?.[1]
}

/**
 * Render the local UTC offset of one instant as git's `+HHMM`/`-HHMM`.
 *
 * git uses the local zone when a date has no explicit offset (a bare epoch,
 * an ISO timestamp without a suffix, or fallback text with no zone). Node's
 * `getTimezoneOffset()` is positive west of UTC and already accounts for DST
 * at that instant, so negating it gives the offset git prints.
 */
function localTimezone(timestamp: number): string {
  const date = new Date(timestamp * 1000)
  const offset = -date.getTimezoneOffset()
  const sign = offset < 0 ? '-' : '+'
  const absolute = Math.abs(offset)
  const pad = (value: number): string => String(value).padStart(2, '0')
  return `${sign}${pad(Math.floor(absolute / 60))}${pad(absolute % 60)}`
}

/** Normalize a numeric offset spelling that git treats as UTC. */
function normalizeGitTimezone(timezone: string): string {
  const compact = timezone.replace(':', '')
  return compact === '-0000' ? '+0000' : compact
}

/**
 * Read the explicit offset at the end of an approxidate text.
 *
 * `Date.parse` accepts `%ai`-shaped and RFC 2822 dates, but it only returns the
 * instant and loses the supplied zone. git stores that zone verbatim (for
 * example `2023-11-14 22:13:20 +0000` stays `+0000` under `TZ=Asia/Shanghai`),
 * so keep a trailing `[+-]HHMM`/`[+-]HH:MM` rather than replacing it with the
 * host zone. RFC 2822's unambiguous UTC spellings are the only named zones
 * mapped here; other names stay on the local-zone path instead of being
 * guessed.
 */
function trailingTimezone(text: string): string | undefined {
  const normalized = text.trim()
  // Date.parse accepts RFC 2822 comments after the explicit offset, but git
  // preserves that offset rather than falling back to the host zone.
  const withoutTrailingComment = normalized.replace(/\s+\([^()]*\)\s*$/, '')
  const numeric = /([+-])(\d{2}):?(\d{2})$/.exec(withoutTrailingComment)
  if (numeric !== null) {
    const hours = Number(numeric[2])
    const minutes = Number(numeric[3])
    if (hours <= 23 && minutes <= 59) {
      return normalizeGitTimezone(`${numeric[1]}${numeric[2]}${numeric[3]}`)
    }
  }
  if (/(?:^|\s)(?:Z|UTC|GMT)$/i.test(withoutTrailingComment)) return '+0000'
  return undefined
}

/** Parse a small set of RFC-style timezone abbreviations without guessing. */
function namedDateTimezone(text: string): { parseText: string; timezone: string } | undefined {
  const normalized = text.trim().replace(/\s+\([^()]*\)\s*$/, '')
  const match = /^(.*\d{1,2}:\d{2}(?::\d{2})?\s+)([A-Za-z]{2,5})$/.exec(normalized)
  if (match === null) return undefined
  const name = (match[2] as string).toUpperCase()
  // AM/PM are clock markers, not timezone abbreviations.
  if (name === 'AM' || name === 'PM') return undefined
  const offsets: Readonly<Record<string, string>> = {
    EST: '-0500',
    PDT: '-0700',
    CET: '+0100',
  }
  const timezone = offsets[name]
  if (timezone === undefined) {
    if (name === 'UTC' || name === 'GMT' || name === 'UT') {
      return { parseText: `${match[1]}GMT+0000`, timezone: '+0000' }
    }
    // Do not silently substitute the host zone for an unrecognized named zone.
    throw fatal(`invalid date format: ${text}`)
  }
  return { parseText: `${match[1]}GMT${timezone}`, timezone }
}

/**
 * Parse the date forms `--date` and `GIT_*_DATE` accept in scripts.
 *
 * `fallbackSeconds` is already an epoch-seconds value (git's wire unit), never
 * milliseconds. The fallback used to be documented as milliseconds and the
 * committer fallback was the author's already-parsed seconds, so a commit with
 * no `GIT_COMMITTER_DATE` divided the author timestamp by 1000 and stored
 * `1792960` where the author stored `1792960425` (G2-B06). One unit for the
 * parameter, and integer seconds on the wire, keeps both ident fields full.
 */
export function parseGitDate(
  text: string | undefined,
  fallbackSeconds: number,
): { timestamp: number; timezone: string } {
  if (text === undefined || text.trim() === '') {
    const timestamp = Math.floor(fallbackSeconds)
    return { timestamp, timezone: localTimezone(timestamp) }
  }
  const raw = /^@?(-?\d+)\s+([+-]\d{4})$/.exec(text.trim())
  if (raw !== null) {
    return {
      timestamp: Number(raw[1]),
      timezone: normalizeGitTimezone(raw[2] as string),
    }
  }
  // A bare epoch is the internal form without the zone field; git then uses
  // the local timezone, not UTC. The old parser fell through to Date.parse and
  // rejected the value outright, so `GIT_COMMITTER_DATE=1700000000` failed.
  const epoch = /^@?(-?\d+)$/.exec(text.trim())
  if (epoch !== null) {
    const timestamp = Number(epoch[1])
    return { timestamp, timezone: localTimezone(timestamp) }
  }
  const iso = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/.exec(text.trim())
  if (iso !== null) {
    const [, year, month, day, hour, minute, second, zone] = iso
    if (zone === undefined) {
      // No suffix: git interprets the wall clock in the local zone.
      const local = new Date(
        Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second),
      )
      const timestamp = Math.floor(local.getTime() / 1000)
      return { timestamp, timezone: localTimezone(timestamp) }
    }
    const timezone = normalizeGitTimezone(zone === 'Z' ? '+0000' : zone)
    const utc = Date.UTC(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second))
    const offsetMinutes = timezone === '+0000' ? 0
      : (timezone.startsWith('-') ? -1 : 1) * (Number(timezone.slice(1, 3)) * 60 + Number(timezone.slice(3, 5)))
    return { timestamp: Math.floor(utc / 1000) - offsetMinutes * 60, timezone }
  }
  // JavaScript Date.parse accepts a bare calendar date, but Git's commit date
  // parser requires a time (or an epoch/approxidate form) in this context.
  if (/^\d{4}-\d{2}-\d{2}$/.test(text.trim())) {
    throw fatal(`invalid date format: ${text}`)
  }
  const namedZone = namedDateTimezone(text)
  const parsed = Date.parse(namedZone?.parseText ?? text)
  if (Number.isFinite(parsed)) {
    const timestamp = Math.floor(parsed / 1000)
    return {
      timestamp,
      timezone: namedZone?.timezone ?? trailingTimezone(text) ?? localTimezone(timestamp),
    }
  }
  throw fatal(`invalid date format: ${text}`)
}

/** Stage tracked-file modifications and deletions (`commit -a`). */
async function stageTracked(context: CommandContext, repository: Repository, workTree: string): Promise<void> {
  const index = await loadIndex(repository)
  const files = await scanWorktree(repository)
  let entries = [...index.entries]
  for (const entry of index.entries) {
    if (entry.stage !== 0) continue
    const info = files.get(entry.path)
    if (info === undefined || info.isDirectory) {
      entries = entries.filter(candidate => candidate.path !== entry.path)
      continue
    }
    const blob = await readWorktreeBlob(context.fs, repository, workTree, entry.path)
    if (blob === undefined || blob.oid === entry.oid) continue
    const oid = await repository.odb.write('blob', blob.data)
    entries = entries.filter(candidate => candidate.path !== entry.path)
    entries.push(await statEntry(context.fs, workTree, entry.path, oid, parseMode(blob.mode)))
  }
  entries.sort((left, right) => compareStrings(left.path, right.path) || left.stage - right.stage)
  await writeIndex(context.fs, repository.indexPath, { version: 2, entries })
}

async function updateCurrentBranch(repository: Repository, oid: string): Promise<string> {
  const symbolic = await headRef(repository)
  if (symbolic === undefined) {
    await writeRef(repository, 'HEAD', oid)
    return 'HEAD'
  }
  await writeRef(repository, symbolic, oid)
  return symbolic
}

async function commitSummary(
  repository: Repository,
  parent: string | undefined,
  oid: string,
  tree: string,
  root: boolean,
): Promise<string> {
  const before: Map<string, { mode: string; oid: string }> = root || parent === undefined
    ? new Map()
    : await flattenTree(repository, (await readCommit(repository, parent)).tree)
  const after = await flattenTree(repository, tree)
  const changes = await diffFlatTrees(repository, before, after, { renames: true })
  let filesChanged = 0
  let insertions = 0
  let deletions = 0
  const lines: string[] = []
  for (const change of changes) {
    filesChanged += 1
    const oldData = change.oldOid === undefined ? new Uint8Array(0) : (await repository.odb.read(change.oldOid)).data
    const newData = change.newOid === undefined ? new Uint8Array(0) : (await repository.odb.read(change.newOid)).data
    if (!isBinary(oldData) && !isBinary(newData)) {
      const counts = countDiff(splitLines(oldData), splitLines(newData))
      insertions += counts.added
      deletions += counts.deleted
    }
    if (change.status === 'A') lines.push(` create mode ${change.newMode?.padStart(6, '0') ?? '100644'} ${change.path}\n`)
    else if (change.status === 'D') lines.push(` delete mode ${change.oldMode?.padStart(6, '0') ?? '100644'} ${change.path}\n`)
    else if (change.status === 'R') lines.push(` rename ${change.oldPath} => ${change.path} (${change.score ?? 100}%)\n`)
  }
  void oid
  const parts = [
    ` ${filesChanged} file${filesChanged === 1 ? '' : 's'} changed`,
    `${insertions} insertion${insertions === 1 ? '' : 's'}(+)`,
    `${deletions} deletion${deletions === 1 ? '' : 's'}(-)`,
  ]
  return `${parts.join(', ')}\n${lines.join('')}`
}
