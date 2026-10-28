// SPDX-License-Identifier: MIT
/**
 * Trees: building a tree from an index, flattening a tree, diffing two trees
 * and detecting renames.
 *
 * `write-tree` builds bottom-up from the index with git's tree order (a
 * directory compares as its name plus `/`). `diff-tree` and `status` compare
 * flattened trees, and `-M` pairs a deletion with an addition when the blob
 * identities are equal or the content similarity passes git's default 50%
 * threshold. The similarity estimate is line-based; it agrees with git for
 * exact renames and for edits that keep most lines, which is the case the
 * changed-files card reports.
 * @module @xiaoxhi-link/dsh-wasi-toolbox/git/tree
 */
import { fatal } from './errors.ts'
import { compareStrings, encodeText } from './fs.ts'
import type { GitFs } from './fs.ts'
import type { GitIndex, IndexEntry } from './gindex.ts'
import { hasUnmerged } from './gindex.ts'
import { hashBlob } from './objects.ts'
import { buildTree, flattenTree, readCommit } from './repo.ts'
import type { FlatTreeEntry, Repository } from './repo.ts'
import { similarity } from './textdiff.ts'

/** One changed path between two trees. */
export interface TreeChange {
  /** Destination path (the new path for a rename). */
  readonly path: string
  /** Source path for a rename. */
  readonly oldPath?: string
  readonly oldMode?: string
  readonly newMode?: string
  readonly oldOid?: string
  readonly newOid?: string
  readonly status: 'A' | 'M' | 'D' | 'R' | 'T'
  /** Similarity score for a rename, 0-100. */
  readonly score?: number
  /** Blob bytes when the caller already holds them (work-tree diffs). */
  readonly oldData?: Uint8Array
  /** Blob bytes when the caller already holds them (work-tree diffs). */
  readonly newData?: Uint8Array
}

/** Format an index mode as git's octal mode text. */
export function modeText(mode: number): string {
  return mode.toString(8)
}

/** Parse git's octal mode text. */
export function parseMode(text: string): number {
  return Number.parseInt(text, 8)
}

/** True when an index/tree mode is a directory tree. */
export function isTreeMode(mode: string | number): boolean {
  return (typeof mode === 'number' ? modeText(mode) : mode) === '40000'
}

interface TreeNode {
  readonly files: Map<string, { mode: number; oid: string }>
  readonly dirs: Map<string, TreeNode>
}

function emptyNode(): TreeNode {
  return { files: new Map(), dirs: new Map() }
}

/** Git's tree entry order: a directory sorts as its name followed by '/'. */
export function treeNameCompare(left: string, leftIsDir: boolean, right: string, rightIsDir: boolean): number {
  return compareStrings(left + (leftIsDir ? '/' : ''), right + (rightIsDir ? '/' : ''))
}

/** Write the tree objects for an index and return the root tree id. */
export async function buildTreeFromIndex(repository: Repository, index: GitIndex): Promise<string> {
  if (hasUnmerged(index)) throw fatal('git-write-tree: error building trees')
  const root = emptyNode()
  for (const entry of index.entries) {
    if (entry.stage !== 0) continue
    insertEntry(root, entry)
  }
  return await writeNode(repository, root)
}

function insertEntry(root: TreeNode, entry: IndexEntry): void {
  const parts = entry.path.split('/')
  let node = root
  for (let index = 0; index < parts.length - 1; index += 1) {
    const part = parts[index] as string
    let child = node.dirs.get(part)
    if (child === undefined) {
      child = emptyNode()
      node.dirs.set(part, child)
    }
    node = child
  }
  const name = parts[parts.length - 1] as string
  node.files.set(name, { mode: entry.mode, oid: entry.oid })
}

async function writeNode(repository: Repository, node: TreeNode): Promise<string> {
  const names: { name: string; isDir: boolean }[] = []
  for (const name of node.files.keys()) names.push({ name, isDir: false })
  for (const name of node.dirs.keys()) names.push({ name, isDir: true })
  names.sort((left, right) => treeNameCompare(left.name, left.isDir, right.name, right.isDir))
  const entries: { mode: string; name: string; oid: string }[] = []
  for (const item of names) {
    if (item.isDir) {
      const child = node.dirs.get(item.name) as TreeNode
      const oid = await writeNode(repository, child)
      entries.push({ mode: '40000', name: item.name, oid })
    } else {
      const file = node.files.get(item.name) as { mode: number; oid: string }
      entries.push({ mode: modeText(file.mode), name: item.name, oid: file.oid })
    }
  }
  const data = buildTree(entries)
  return await repository.odb.write('tree', data)
}

/** Parse a `-M` option value (`-M`, `-M50%`, `-M50`) into a threshold. */
export function renameThreshold(value: string | undefined): number | undefined {
  if (value === undefined) return 50
  const match = /^(\d+)%?$/.exec(value)
  if (match === null) throw fatal(`invalid rename threshold '${value}'`)
  const threshold = Number(match[1])
  if (!(threshold >= 0 && threshold <= 100)) throw fatal(`rename threshold out of range: ${value}`)
  return threshold
}

/**
 * Compare two flattened trees, optionally detecting renames.
 *
 * `select` restricts both snapshots before rename detection. Git applies a
 * pathspec while it walks the trees, so a rename whose old and new paths are
 * not both selected is reported as an ordinary deletion and/or addition; it
 * must not be paired first and filtered afterwards.
 */
export async function diffFlatTrees(
  repository: Repository,
  before: ReadonlyMap<string, FlatTreeEntry>,
  after: ReadonlyMap<string, FlatTreeEntry>,
  options: {
    readonly renames?: boolean
    readonly threshold?: number
    readonly select?: (path: string) => boolean
  } = {},
): Promise<TreeChange[]> {
  const select = options.select
  const beforeEntries = select === undefined
    ? before
    : new Map([...before].filter(([path]) => select(path)))
  const afterEntries = select === undefined
    ? after
    : new Map([...after].filter(([path]) => select(path)))
  const paths = new Set([...beforeEntries.keys(), ...afterEntries.keys()])
  const changes: TreeChange[] = []
  const deletions: TreeChange[] = []
  const additions: TreeChange[] = []
  for (const path of [...paths].sort(compareStrings)) {
    const oldEntry = beforeEntries.get(path)
    const newEntry = afterEntries.get(path)
    if (oldEntry === undefined && newEntry === undefined) continue
    if (oldEntry === undefined) {
      additions.push({
        path,
        status: 'A',
        newMode: newEntry?.mode,
        newOid: newEntry?.oid,
      })
      continue
    }
    if (newEntry === undefined) {
      deletions.push({
        path,
        status: 'D',
        oldMode: oldEntry.mode,
        oldOid: oldEntry.oid,
      })
      continue
    }
    if (oldEntry.oid === newEntry.oid) {
      if (oldEntry.mode !== newEntry.mode) {
        changes.push({
          path,
          status: 'M',
          oldMode: oldEntry.mode,
          newMode: newEntry.mode,
          oldOid: oldEntry.oid,
          newOid: newEntry.oid,
        })
      }
      continue
    }
    changes.push({
      path,
      status: 'M',
      oldMode: oldEntry.mode,
      newMode: newEntry.mode,
      oldOid: oldEntry.oid,
      newOid: newEntry.oid,
    })
  }
  if (options.renames === false || deletions.length === 0 || additions.length === 0) {
    return [...changes, ...deletions, ...additions].sort((left, right) => compareStrings(left.path, right.path))
  }
  const threshold = options.threshold ?? 50
  const pairs: { deletion: TreeChange; addition: TreeChange; score: number }[] = []
  const remainingDeletions = new Set(deletions)
  const remainingAdditions = new Set(additions)
  // Exact blob identity first, the way git scores exact renames at 100%.
  // Snapshot the *remaining* additions for every deletion: an addition that
  // already paired with an earlier deletion must not be reused when several
  // deletions share the same blob id.
  for (const deletion of [...remainingDeletions]) {
    for (const addition of [...remainingAdditions]) {
      if (addition.newOid === deletion.oldOid && (deletion.oldMode === undefined || addition.newMode === undefined
        || gitFileType(deletion.oldMode) === gitFileType(addition.newMode))) {
        pairs.push({ deletion, addition, score: 100 })
        remainingDeletions.delete(deletion)
        remainingAdditions.delete(addition)
        break
      }
    }
  }
  if (threshold < 100) {
    const oldData = new Map<string, Uint8Array>()
    const newData = new Map<string, Uint8Array>()
    for (const deletion of remainingDeletions) {
      const data = deletion.oldData ?? await readOptionalObject(repository, deletion.oldOid as string)
      if (data !== undefined) oldData.set(deletion.path, data)
    }
    for (const addition of remainingAdditions) {
      const data = addition.newData ?? await readOptionalObject(repository, addition.newOid as string)
      if (data !== undefined) newData.set(addition.path, data)
    }
    const scored: { deletion: TreeChange; addition: TreeChange; score: number }[] = []
    for (const deletion of remainingDeletions) {
      for (const addition of remainingAdditions) {
        if (!oldData.has(deletion.path) || !newData.has(addition.path)) continue
        if (deletion.oldMode !== undefined && addition.newMode !== undefined
          && gitFileType(deletion.oldMode) !== gitFileType(addition.newMode)) continue
        const score = similarity(oldData.get(deletion.path) as Uint8Array, newData.get(addition.path) as Uint8Array)
        if (score >= threshold) scored.push({ deletion, addition, score })
      }
    }
    scored.sort((left, right) => right.score - left.score || compareStrings(left.deletion.path, right.deletion.path))
    for (const pair of scored) {
      if (!remainingDeletions.has(pair.deletion) || !remainingAdditions.has(pair.addition)) continue
      pairs.push(pair)
      remainingDeletions.delete(pair.deletion)
      remainingAdditions.delete(pair.addition)
    }
  }
  const renamed: TreeChange[] = pairs.map(pair => ({
    path: pair.addition.path,
    oldPath: pair.deletion.path,
    status: 'R',
    oldMode: pair.deletion.oldMode,
    newMode: pair.addition.newMode,
    oldOid: pair.deletion.oldOid,
    newOid: pair.addition.newOid,
    score: pair.score,
  }))
  return [
    ...changes,
    ...renamed,
    ...[...remainingDeletions].map(change => ({ ...change, status: 'D' as const })),
    ...[...remainingAdditions].map(change => ({ ...change, status: 'A' as const })),
  ].sort((left, right) => compareStrings(left.path, right.path))
}

async function readOptionalObject(repository: Repository, oid: string): Promise<Uint8Array | undefined> {
  try {
    return (await repository.odb.read(oid)).data
  } catch {
    return undefined
  }
}

function gitFileType(mode: string): string {
  if (mode === '40000' || mode === '040000') return 'tree'
  if (mode === '160000') return 'commit'
  if (mode === '120000') return 'symlink'
  return 'blob'
}

/** Diff two tree ids, flattening both first. */
export async function diffTrees(
  repository: Repository,
  beforeTree: string,
  afterTree: string,
  options: {
    readonly renames?: boolean
    readonly threshold?: number
    readonly select?: (path: string) => boolean
  } = {},
): Promise<TreeChange[]> {
  if (beforeTree === afterTree) return []
  const before = await flattenTree(repository, beforeTree)
  const after = await flattenTree(repository, afterTree)
  return await diffFlatTrees(repository, before, after, options)
}

/** Diff the tree of two commits (or empty for a root commit). */
export async function diffCommits(
  repository: Repository,
  beforeCommit: string | undefined,
  afterCommit: string,
  options: {
    readonly renames?: boolean
    readonly threshold?: number
    readonly select?: (path: string) => boolean
  } = {},
): Promise<TreeChange[]> {
  const afterTree = (await readCommit(repository, afterCommit)).tree
  if (beforeCommit === undefined) {
    const empty = new Map<string, FlatTreeEntry>()
    return await diffFlatTrees(repository, empty, await flattenTree(repository, afterTree), options)
  }
  const beforeTree = (await readCommit(repository, beforeCommit)).tree
  return await diffTrees(repository, beforeTree, afterTree, options)
}

/** One work-tree file git hashed. */
export interface WorktreeBlob {
  readonly path: string
  readonly mode: string
  readonly oid: string
  readonly data: Uint8Array
}

/** Read one work-tree file and give it git's mode and blob id (no write). */
export async function readWorktreeBlob(
  fs: GitFs,
  repository: Repository,
  workTree: string,
  path: string,
): Promise<WorktreeBlob | undefined> {
  const absolute = `${workTree}/${path}`
  let stat
  try {
    stat = await fs.lstat(absolute)
  } catch {
    return undefined
  }
  if (stat.isDirectory) return undefined
  if (stat.isSymbolicLink) {
    const target = await fs.readlink?.(absolute)
    if (target === undefined) throw fatal('the Worker VFS has no symlink support')
    const data = encodeText(target)
    return { path, mode: '120000', oid: hashBlob(data), data }
  }
  const data = await fs.readFile(absolute)
  const executable = (stat.mode & 0o111) !== 0 && repository.config.getBoolean('core.filemode') !== false
  return { path, mode: executable ? '100755' : '100644', oid: hashBlob(data), data }
}
