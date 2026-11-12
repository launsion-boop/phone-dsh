// SPDX-License-Identifier: MIT
/**
 * Cone-mode `git sparse-checkout`.
 *
 * The pattern file is git's cone spelling (slash-star, bang-slash-star-slash,
 * slash-dir-slash), so a system git can read it. Only cone mode is implemented.
 * A selected file is one at the repository root, or one inside a selected
 * directory. Other index entries stay, with the skip-worktree bit set, and are
 * not written to disk.
 *
 * Applying a cone never discards local work. A path whose work-tree file or
 * index entry differs from `HEAD` is left alone and named in the warning, just
 * like the system git's "not up to date and were left despite sparse patterns".
 * @module @phone-dsh/dsh-wasi-toolbox/git/sparse
 */
import { fatal } from './errors.ts'
import { compareStrings, decodeText, isErrno } from './fs.ts'
import { setConfigText } from './config.ts'
import { statEntry, writeIndex } from './gindex.ts'
import type { IndexEntry } from './gindex.ts'
import { readIndex } from './gindex.ts'
import {
  flattenTree, headOid, readCommit, requireWorkTree,
} from './repo.ts'
import type { Repository } from './repo.ts'
import { ensureParent, removeWorktreePath } from './worktree.ts'
import { parseMode } from './tree.ts'
import type { CommandContext } from './cli.ts'

/** Directories of an active cone, or undefined when sparse-checkout is off. */
export async function activeCone(repository: Repository): Promise<readonly string[] | undefined> {
  if (repository.config.getBoolean('core.sparsecheckout') !== true) return undefined
  // A repository initialised by a system git with `--no-cone` is not ours to
  // rewrite. Treat it as a full work tree so ordinary commands (switch,
  // checkout) keep working; only explicit `sparse-checkout` calls touch it.
  if (repository.config.getBoolean('core.sparsecheckoutcone') !== true) return undefined
  const text = await readOptional(repository, 'info/sparse-checkout')
  return text === undefined ? [] : parseCone(text)
}

/** True when sparse-checkout is enabled, whether or not it is cone mode. */
export async function sparseEnabled(repository: Repository): Promise<boolean> {
  return repository.config.getBoolean('core.sparsecheckout') === true
}

/** True when cone mode wants this work-tree file on disk. */
export function coneSelectsFile(path: string, directories: readonly string[]): boolean {
  const slash = path.lastIndexOf('/')
  if (slash < 0) return true
  const parent = path.slice(0, slash)
  return directories.some(dir => parent === dir || parent.startsWith(`${dir}/`))
}

/** Parse a cone-mode sparse-checkout file. Non-cone lines are an error. */
export function parseCone(text: string): string[] {
  const directories: string[] = []
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line === '' || line.startsWith('#')) continue
    if (line === '/*' || line === '!/*/') continue
    const match = /^\/(.+)\/$/.exec(line)
    if (match === null) {
      throw fatal(`sparse-checkout file is not cone mode (${line}); only cone patterns are supported`)
    }
    directories.push(normalizeDir(match[1] as string))
  }
  return directories
}

export function conePatternText(directories: readonly string[]): string {
  const unique = [...new Set(directories)].sort(compareStrings)
  return ['/*', '!/*/', ...unique.map(dir => `/${dir}/`), ''].join('\n')
}

function normalizeDir(raw: string): string {
  const dir = raw.replace(/^\/+|\/+$/g, '')
  if (dir === '' || dir.split('/').some(part => part === '' || part === '.' || part === '..')) {
    throw fatal(`sparse-checkout path '${raw}' is not a directory name`)
  }
  return dir
}

async function readOptional(repository: Repository, path: string): Promise<string | undefined> {
  try {
    return decodeText(await repository.fs.readFile(`${repository.gitDir}/${path}`))
  } catch {
    return undefined
  }
}

async function writeConfig(repository: Repository, updates: readonly [string, string][]): Promise<void> {
  const path = `${repository.gitDir}/config`
  let text = ''
  try {
    text = decodeText(await repository.fs.readFile(path))
  } catch {
    text = ''
  }
  for (const [key, value] of updates) {
    text = setConfigText(text, key, value)
    repository.config.set(key, value)
  }
  await repository.fs.writeFile(path, text)
}

async function writeConeFile(repository: Repository, directories: readonly string[]): Promise<void> {
  await repository.fs.mkdir(`${repository.gitDir}/info`, true)
  await repository.fs.writeFile(`${repository.gitDir}/info/sparse-checkout`, conePatternText(directories))
}

interface WorkInfo {
  readonly exists: boolean
  readonly directory: boolean
}

/** Stat one work-tree path without following a directory into a file read. */
async function workInfo(repository: Repository, path: string): Promise<WorkInfo> {
  try {
    const stat = await repository.fs.lstat(`${requireWorkTree(repository)}/${path}`)
    return { exists: true, directory: stat.isDirectory }
  } catch (error) {
    if (isErrno(error, 'ENOENT', 'ENOTDIR')) return { exists: false, directory: false }
    throw error
  }
}

async function workData(repository: Repository, path: string): Promise<Uint8Array | undefined> {
  try {
    return await repository.fs.readFile(`${requireWorkTree(repository)}/${path}`)
  } catch (error) {
    if (isErrno(error, 'ENOENT', 'ENOTDIR', 'EISDIR')) return undefined
    throw error
  }
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false
  for (let index = 0; index < left.byteLength; index += 1) {
    if (left[index] !== right[index]) return false
  }
  return true
}

/** True when the work-tree file still has exactly the indexed content. */
async function workMatches(repository: Repository, path: string, oid: string): Promise<boolean> {
  const data = await workData(repository, path)
  if (data === undefined) return false
  try {
    return sameBytes(data, (await repository.odb.read(oid)).data)
  } catch {
    return false
  }
}

function modeText(mode: string | number): string {
  return typeof mode === 'number' ? mode.toString(8) : mode
}

function isGitlink(mode: string | number | undefined): boolean {
  return mode !== undefined && modeText(mode) === '160000'
}

/**
 * Make the work tree and index match the cone. Missing blobs of selected
 * files are fetched when the repository is a promisor clone.
 *
 * Clean paths outside the cone are removed; their index entries stay with
 * `skipWorktree`. A path with a modified work-tree file, a staged change, an
 * unstaged deletion or an untracked file at a tracked path is never overwritten
 * or deleted: it stays in place, loses `skipWorktree` when it is outside the
 * cone, and is named in the warning.
 */
export async function applyCone(
  context: CommandContext,
  repository: Repository,
  directories: readonly string[] | undefined,
): Promise<void> {
  const workTree = requireWorkTree(repository)
  const indexMissing = !(await repository.fs.exists(repository.indexPath))
  const index = await readIndex(repository.fs, repository.indexPath)
  if (index.entries.some(entry => entry.stage !== 0)) {
    throw fatal('cannot update sparse-checkout with unmerged index entries. Nothing was changed.')
  }
  const oid = await headOid(repository)
  const flat = oid === undefined ? new Map<string, { readonly mode: string; readonly oid: string }>() : await flattenTree(repository, (await readCommit(repository, oid)).tree)
  const indexed = new Map(index.entries.map(entry => [entry.path, entry]))
  const paths = [...new Set([...flat.keys(), ...indexed.keys()])].sort(compareStrings)
  const selectedOf = (path: string): boolean => directories === undefined || coneSelectsFile(path, directories)

  // Fetch every blob a selected path will need before touching the work tree.
  const wanted: string[] = []
  for (const path of paths) {
    if (!selectedOf(path)) continue
    const head = flat.get(path)
    const indexedEntry = indexed.get(path)
    if (isGitlink(head?.mode ?? indexedEntry?.mode)) continue
    const info = await workInfo(repository, path)
    if (info.exists) continue
    if (indexedEntry !== undefined) {
      if (indexedEntry.skipWorktree === true) wanted.push(indexedEntry.oid)
    } else if (indexMissing && head !== undefined) {
      wanted.push(head.oid)
    }
  }
  if (wanted.length > 0) {
    const { prefetchMissing } = await import('./remote.ts')
    await prefetchMissing(context, repository, wanted)
  }

  const entries: IndexEntry[] = []
  const left: string[] = []
  for (const path of paths) {
    const head = flat.get(path)
    const entry = indexed.get(path)
    const selected = selectedOf(path)
    const info = await workInfo(repository, path)

    // A gitlink is a commit id and a directory, never a blob to check out.
    if (isGitlink(head?.mode ?? entry?.mode)) {
      if (entry !== undefined) {
        entries.push({ ...entry, skipWorktree: !selected })
      } else if (head !== undefined && indexMissing) {
        entries.push({ ...await statEntry(context.fs, workTree, path, head.oid, parseMode(head.mode)), skipWorktree: !selected })
      }
      continue
    }

    if (!selected) {
      if (entry !== undefined) {
        const clean = !info.exists || (!info.directory && await workMatches(repository, path, entry.oid))
        if (clean) {
          if (info.exists) await removeWorktreePath(context.fs, workTree, path)
          entries.push({ ...entry, skipWorktree: true })
        } else {
          left.push(path)
          entries.push({ ...entry, skipWorktree: false })
        }
      } else if (head !== undefined && indexMissing) {
        // No index yet (a fresh clone or a removed index): rebuild the entry
        // for this path from HEAD, but only remove a file that is clean.
        const clean = !info.exists || (!info.directory && await workMatches(repository, path, head.oid))
        const base = await statEntry(context.fs, workTree, path, head.oid, parseMode(head.mode))
        if (clean) {
          if (info.exists) await removeWorktreePath(context.fs, workTree, path)
          entries.push({ ...base, skipWorktree: true })
        } else {
          left.push(path)
          entries.push({ ...base, skipWorktree: false })
        }
      }
      // HEAD has the path but the index does not: a staged deletion. Leave the
      // index alone (do not resurrect the path) and leave any file in place.
      continue
    }

    if (entry !== undefined) {
      if (info.exists) {
        // Keep whatever the user has; only clear the skip bit so status sees it.
        entries.push({ ...entry, skipWorktree: false })
      } else if (entry.skipWorktree === true) {
        const data = (await repository.odb.read(entry.oid)).data
        await ensureParent(context.fs, workTree, path)
        await context.fs.writeFile(`${workTree}/${path}`, data, parseMode(modeText(entry.mode)))
        entries.push(await statEntry(context.fs, workTree, path, entry.oid, parseMode(modeText(entry.mode))))
      } else {
        // Unstaged deletion inside the cone: preserve it, do not restore.
        entries.push({ ...entry, skipWorktree: false })
      }
      continue
    }

    if (head !== undefined && indexMissing) {
      if (!info.exists) {
        const data = (await repository.odb.read(head.oid)).data
        await ensureParent(context.fs, workTree, path)
        await context.fs.writeFile(`${workTree}/${path}`, data, parseMode(head.mode))
        entries.push(await statEntry(context.fs, workTree, path, head.oid, parseMode(head.mode)))
      } else {
        entries.push(await statEntry(context.fs, workTree, path, head.oid, parseMode(head.mode)))
      }
    }
    // HEAD and the index both miss the path: it is untracked. Leave it alone.
  }

  await writeIndex(context.fs, repository.indexPath, { version: 2, entries })
  if (left.length > 0) {
    context.output.stderr('warning: The following paths are not up to date and were left despite sparse patterns:\n')
    for (const path of [...new Set(left)].sort(compareStrings)) context.output.stderr(`\t${path}\n`)
    context.output.stderr('After fixing the above paths, you may want to run `git sparse-checkout reapply`.\n')
  }
}

/** `git sparse-checkout`. */
export async function sparseCheckout(context: CommandContext): Promise<number> {
  const [verb, ...rest] = context.args
  if (verb === undefined || verb === '-h' || verb === '--help') {
    context.output.stdout(
      'usage: git sparse-checkout init --cone | list | set <dir>... | add <dir>... | disable\n'
      + 'Only cone mode is implemented. `set` replaces the directory list; root files stay checked out.\n',
    )
    return verb === undefined ? 1 : 0
  }
  const repository = await context.repository()
  if (verb === 'list') {
    const enabled = await sparseEnabled(repository)
    const cone = await activeCone(repository)
    if (enabled && cone === undefined) {
      throw fatal('this worktree uses non-cone sparse-checkout; only cone mode is supported. '
        + 'Run `git sparse-checkout set <dir>...` to replace it with a cone. Nothing was changed.')
    }
    if (cone === undefined) {
      context.output.stderr('sparse-checkout is disabled\n')
      return 1
    }
    context.output.stdout(cone.map(dir => `${dir}\n`).join(''))
    return 0
  }
  if (verb === 'init') {
    if (!rest.includes('--cone') || rest.some(arg => arg !== '--cone')) {
      throw fatal('git sparse-checkout init only supports --cone. Nothing was changed.')
    }
    await writeConfig(repository, [['core.sparseCheckout', 'true'], ['core.sparseCheckoutCone', 'true']])
    await writeConeFile(repository, [])
    await applyCone(context, repository, [])
    return 0
  }
  if (verb === 'disable') {
    await writeConfig(repository, [['core.sparseCheckout', 'false'], ['core.sparseCheckoutCone', 'false']])
    try {
      await context.fs.rm(`${repository.gitDir}/info/sparse-checkout`, { force: true })
    } catch {
      // already absent
    }
    await applyCone(context, repository, undefined)
    return 0
  }
  if (verb !== 'set' && verb !== 'add') throw fatal(`git sparse-checkout ${verb} is not supported; use init --cone, set, add, list or disable`)
  const added = rest.map(dir => normalizeDir(dir))
  if (added.length === 0) throw fatal(`git sparse-checkout ${verb} needs at least one directory`)
  const current = verb === 'add' ? (await activeCone(repository)) ?? [] : []
  const directories = [...new Set([...current, ...added])].sort(compareStrings)
  await writeConfig(repository, [['core.sparseCheckout', 'true'], ['core.sparseCheckoutCone', 'true']])
  await writeConeFile(repository, directories)
  await applyCone(context, repository, directories)
  return 0
}
