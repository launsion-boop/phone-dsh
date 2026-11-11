// SPDX-License-Identifier: MIT
/**
 * Cone-mode `git sparse-checkout`.
 *
 * The pattern file is git's cone spelling (slash-star, bang-slash-star-slash,
 * slash-dir-slash), so a system git can read it. Only cone mode is implemented. A selected file is
 * one at the repository root, or one inside a selected directory. Other index
 * entries stay, with the skip-worktree bit set, and are not written to disk.
 * @module @phone-dsh/dsh-wasi-toolbox/git/sparse
 */
import { fatal } from './errors.ts'
import { decodeText } from './fs.ts'
import { setConfigText } from './config.ts'
import { statEntry, writeIndex } from './gindex.ts'
import type { IndexEntry } from './gindex.ts'
import { readIndex } from './gindex.ts'
import {
  flattenTree, headOid, readCommit, requireWorkTree,
} from './repo.ts'
import type { Repository } from './repo.ts'
import { ensureParent, removeWorktreePath } from './worktree.ts'
import { compareStrings } from './fs.ts'
import { parseMode } from './tree.ts'
import type { CommandContext } from './cli.ts'

/** Directories of an active cone, or undefined when sparse-checkout is off. */
export async function activeCone(repository: Repository): Promise<readonly string[] | undefined> {
  if (repository.config.getBoolean('core.sparsecheckout') !== true) return undefined
  const text = await readOptional(repository, 'info/sparse-checkout')
  return text === undefined ? [] : parseCone(text)
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

/**
 * Make the work tree and index match the cone. Missing blobs of selected
 * files are fetched when the repository is a promisor clone.
 */
export async function applyCone(
  context: CommandContext,
  repository: Repository,
  directories: readonly string[] | undefined,
): Promise<void> {
  const workTree = requireWorkTree(repository)
  const oid = await headOid(repository)
  if (oid === undefined) return
  const tree = (await readCommit(repository, oid)).tree
  const flat = await flattenTree(repository, tree)
  const wanted: string[] = []
  for (const [path, entry] of flat) {
    if (directories !== undefined && !coneSelectsFile(path, directories)) continue
    if (entry.mode === '160000') continue
    if (!(await repository.odb.has(entry.oid))) wanted.push(entry.oid)
  }
  if (wanted.length > 0) {
    const { prefetchMissing } = await import('./remote.ts')
    await prefetchMissing(context, repository, wanted)
  }
  const index = await readIndex(repository.fs, repository.indexPath)
  const previous = new Map(index.entries.filter(entry => entry.stage === 0).map(entry => [entry.path, entry]))
  const entries: IndexEntry[] = []
  for (const [path, entry] of [...flat.entries()].sort(([left], [right]) => compareStrings(left, right))) {
    if (entry.mode === '160000') continue
    const selected = directories === undefined || coneSelectsFile(path, directories)
    if (selected) {
      const data = (await repository.odb.read(entry.oid)).data
      await ensureParent(context.fs, workTree, path)
      await context.fs.writeFile(`${workTree}/${path}`, data, parseMode(entry.mode))
    } else if (await context.fs.exists(`${workTree}/${path}`)) {
      await removeWorktreePath(context.fs, workTree, path)
    }
    const prior = previous.get(path)
    const base = prior !== undefined && prior.oid === entry.oid
      ? prior
      : await statEntry(context.fs, workTree, path, entry.oid, parseMode(entry.mode))
    entries.push({ ...base, skipWorktree: !selected })
  }
  await writeIndex(context.fs, repository.indexPath, { version: 2, entries })
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
    const cone = await activeCone(repository)
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
