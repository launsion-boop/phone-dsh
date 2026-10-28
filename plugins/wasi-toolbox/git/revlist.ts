// SPDX-License-Identifier: MIT
/**
 * `git rev-list`: the object-id walker the history porcelain and agents use to
 * enumerate commits without rendering them.
 *
 * The order is git's default date order: committer timestamp, newest first,
 * with ties resolved by the order the commit entered the walk (the order of
 * the command-line tips, then ref-name order for `--all`, then parent order).
 * An oid tiebreak would be stable too, but it disagrees with the system git on
 * multi-tip walks, so this module uses an explicit insertion sequence.
 *
 * A pathspec filters the walk exactly like git's default history
 * simplification for a linear history: a commit is printed when the path
 * differs from its first parent (the empty tree for a root commit). Merge
 * simplification is not implemented, so a merge encountered with a pathspec
 * fails loud (exit 129) instead of printing a history that differs from git.
 * @module @phone-dsh/dsh-wasi-toolbox/git/revlist
 */
import { fatal, usage } from './errors.ts'
import { decodeText } from './fs.ts'
import { matchesPathspec, parsePathspec } from './inspect.ts'
import type { Pathspec } from './inspect.ts'
import { flattenTree, headOid, listRefs, readCommit, resolveRevision } from './repo.ts'
import type { CommitInfo, FlatTreeEntry, Repository } from './repo.ts'
import type { CommandContext } from './cli.ts'

/** One tip source in argv order; `--all` expands where it appears. */
type TipSource =
  | { readonly kind: 'all' }
  | { readonly kind: 'revision'; readonly revision: string }

interface RevListOptions {
  count: boolean
  reverse: boolean
  firstParent: boolean
  maxCount: number
  readonly pathspecs: string[]
  readonly sources: TipSource[]
}

const USAGE = 'usage: git rev-list [<options>] <commit>... [--] [<path>...]'

function parseMaxCount(raw: string | undefined, option: string): number {
  if (raw === undefined || !/^\d+$/.test(raw)) {
    throw fatal(`${option} requires a non-negative integer, not '${raw ?? ''}'`, 129)
  }
  const value = Number(raw)
  if (!Number.isSafeInteger(value)) throw fatal(`${option}: number is too large: '${raw}'`, 129)
  return value
}

function parseOptions(args: readonly string[]): RevListOptions {
  const options: RevListOptions = {
    count: false, reverse: false, firstParent: false,
    maxCount: Number.POSITIVE_INFINITY, pathspecs: [], sources: [],
  }
  let afterSeparator = false
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (afterSeparator) {
      options.pathspecs.push(arg)
      continue
    }
    if (arg === '--') {
      afterSeparator = true
      continue
    }
    if (arg === '--all') options.sources.push({ kind: 'all' })
    else if (arg === '--count') options.count = true
    else if (arg === '--reverse') options.reverse = true
    else if (arg === '--first-parent') options.firstParent = true
    else if (arg === '--max-count' || arg === '-n') {
      options.maxCount = parseMaxCount(args[index + 1], arg)
      index += 1
    } else if (arg.startsWith('--max-count=')) {
      options.maxCount = parseMaxCount(arg.slice('--max-count='.length), '--max-count')
    } else if (/^-n\d+$/.test(arg)) {
      options.maxCount = parseMaxCount(arg.slice(2), '-n')
    } else if (/^-\d+$/.test(arg)) {
      options.maxCount = parseMaxCount(arg.slice(1), '-')
    } else if (arg.startsWith('-')) {
      // --objects, --pretty, --graph and the other output modes change the
      // bytes on stdout. Refusing is the only answer that does not pretend the
      // request was served.
      throw fatal(`unsupported rev-list option '${arg}'. Nothing was printed.`, 129)
    } else {
      options.sources.push({ kind: 'revision', revision: arg })
    }
  }
  return options
}

/**
 * Peel a commit tip, skipping only valid non-commit tree/blob objects.
 *
 * A malformed tag, missing object or excessive tag chain is repository damage,
 * not an empty tip: propagate those failures instead of returning an empty
 * history that looks successful.
 */
async function peelCommitOrSkip(repository: Repository, oid: string): Promise<string | undefined> {
  let current = oid
  for (let depth = 0; depth < 20; depth += 1) {
    const type = await repository.odb.type(current)
    if (type === 'commit') return current
    if (type === 'tree' || type === 'blob') return undefined
    if (type !== 'tag') throw fatal(`object ${current} is a ${type}, not a commit`)
    const text = decodeText((await repository.odb.read(current)).data)
    const match = /^object ([0-9a-f]{40})$/m.exec(text)
    if (match === null) throw fatal(`bad tag object ${current}`)
    current = match[1] as string
  }
  throw fatal(`tag chain too long at ${oid}`)
}

/** Every commit reachable from `start`, used to exclude the left side of `A..B`. */
async function collectReachable(
  repository: Repository,
  start: string,
  into: Set<string>,
): Promise<void> {
  const stack = [start]
  while (stack.length > 0) {
    const oid = stack.pop() as string
    if (into.has(oid)) continue
    into.add(oid)
    const commit = await readCommit(repository, oid)
    for (const parent of commit.parents) stack.push(parent)
  }
}

interface WalkEntry {
  readonly commit: CommitInfo
  readonly sequence: number
}

/** Resolve the command-line tips and the excluded set of `A..B` ranges. */
async function collectTips(
  repository: Repository,
  options: RevListOptions,
): Promise<{ tips: string[]; excluded: Set<string> }> {
  const tips: string[] = []
  const excluded = new Set<string>()
  for (const source of options.sources) {
    if (source.kind === 'all') {
      // refs/ is iterated in ref-name order by listRefs, so equal-timestamp
      // tips enter the walk in a stable order that matches the system git.
      // HEAD is part of --all in git; it usually duplicates the current branch
      // and is then dropped by the tip de-duplication below. Expanding --all
      // here (instead of after the loop) keeps its argv position, which is
      // what decides the order of equal-timestamp commits.
      const refs = await listRefs(repository, 'refs/')
      for (const oid of refs.values()) {
        const commit = await peelCommitOrSkip(repository, oid)
        if (commit !== undefined) tips.push(commit)
      }
      const head = await headOid(repository)
      if (head !== undefined) {
        const commit = await peelCommitOrSkip(repository, head)
        if (commit !== undefined) tips.push(commit)
      }
      continue
    }
    const revision = source.revision
    if (revision.includes('...')) {
      throw fatal(
        `unsupported revision range '${revision}': the Worker git rev-list does not implement `
        + 'symmetric difference (A...B). Nothing was printed.',
        129,
      )
    }
    const separator = revision.indexOf('..')
    if (separator >= 0) {
      const left = revision.slice(0, separator)
      const right = revision.slice(separator + 2)
      const from = left === '' ? 'HEAD' : left
      const to = right === '' ? 'HEAD' : right
      // Git accepts any object as a tip but only walks commits: a tree, blob,
      // `HEAD:path` or a tag that peels to a non-commit contributes no commit
      // and no exclusion, while an unresolved name still fails. Matching that
      // shape means `rev-list <tree>` exits 0 with empty stdout.
      const fromOid = await peelCommitOrSkip(repository, await resolveRevision(repository, from))
      const toOid = await peelCommitOrSkip(repository, await resolveRevision(repository, to))
      if (fromOid !== undefined) await collectReachable(repository, fromOid, excluded)
      if (toOid !== undefined) tips.push(toOid)
      continue
    }
    const oid = await peelCommitOrSkip(repository, await resolveRevision(repository, revision))
    if (oid !== undefined) tips.push(oid)
  }
  return { tips, excluded }
}

/**
 * True when a path is selected by the pathspec list. An exclude-only list means
 * "everything except these paths", matching git; a list with includes starts
 * from those paths and then removes the excluded ones.
 */
function pathSelected(specs: readonly Pathspec[], path: string): boolean {
  const includes = specs.filter(spec => !spec.exclude)
  if (includes.length > 0 && !includes.some(spec => matchesPathspec(spec, path))) return false
  return !specs.some(spec => spec.exclude && matchesPathspec(spec, path))
}

/** True when the path selection changed between the commit and its first parent. */
async function changesPath(
  repository: Repository,
  commit: CommitInfo,
  specs: readonly Pathspec[],
  cache: Map<string, Map<string, FlatTreeEntry>>,
): Promise<boolean> {
  const flattened = async (tree: string): Promise<Map<string, FlatTreeEntry>> => {
    let entries = cache.get(tree)
    if (entries === undefined) {
      entries = await flattenTree(repository, tree)
      cache.set(tree, entries)
    }
    return entries
  }
  const parent = commit.parents[0]
  const before = parent === undefined ? new Map<string, FlatTreeEntry>() : await flattened((await readCommit(repository, parent)).tree)
  const after = await flattened(commit.tree)
  for (const [path, entry] of after) {
    const previous = before.get(path)
    if (previous !== undefined && previous.oid === entry.oid && previous.mode === entry.mode) continue
    if (pathSelected(specs, path)) return true
  }
  for (const path of before.keys()) {
    if (!after.has(path) && pathSelected(specs, path)) return true
  }
  return false
}

/** Walk the tips in git's default date order and collect the selected commits. */
async function selectCommits(
  repository: Repository,
  tips: readonly string[],
  excluded: ReadonlySet<string>,
  options: RevListOptions,
  specs: readonly Pathspec[],
): Promise<CommitInfo[]> {
  const cache = new Map<string, Map<string, FlatTreeEntry>>()
  const seen = new Set<string>(excluded)
  const queue: WalkEntry[] = []
  let sequence = 0
  for (const tip of tips) {
    if (seen.has(tip)) continue
    seen.add(tip)
    queue.push({ commit: await readCommit(repository, tip), sequence: sequence += 1 })
  }
  const selected: CommitInfo[] = []
  while (queue.length > 0 && selected.length < options.maxCount) {
    // Newest committer timestamp first; equal timestamps keep the order the
    // commit entered the walk (tips before parents, ref-name order for --all).
    queue.sort((left, right) => right.commit.committer.timestamp - left.commit.committer.timestamp
      || left.sequence - right.sequence)
    const entry = queue.shift() as WalkEntry
    const commit = entry.commit
    if (specs.length > 0 && commit.parents.length > 1) {
      throw fatal(
        `rev-list with a pathspec does not implement git's merge history simplification; `
        + `commit ${commit.oid} is a merge. Nothing was printed.`,
        129,
      )
    }
    if (specs.length === 0 || await changesPath(repository, commit, specs, cache)) {
      selected.push(commit)
    }
    const parents = options.firstParent ? commit.parents.slice(0, 1) : commit.parents
    for (const parent of parents) {
      if (seen.has(parent)) continue
      seen.add(parent)
      queue.push({ commit: await readCommit(repository, parent), sequence: sequence += 1 })
    }
  }
  return selected
}

/** `git rev-list`. */
export async function revList(context: CommandContext): Promise<number> {
  const options = parseOptions(context.args)
  if (options.sources.length === 0) throw usage(USAGE)
  const repository = await context.repository()
  const { tips, excluded } = await collectTips(repository, options)
  const specs = options.pathspecs.map(path => parsePathspec(repository, context.cwd, path))
  const selected = await selectCommits(repository, tips, excluded, options, specs)
  if (options.reverse) selected.reverse()
  if (options.count) {
    context.output.stdout(`${selected.length}\n`)
    return 0
  }
  for (const commit of selected) context.output.stdout(`${commit.oid}\n`)
  return 0
}
