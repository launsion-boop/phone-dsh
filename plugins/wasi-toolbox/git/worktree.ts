// SPDX-License-Identifier: MIT
/**
 * Walking the work tree of a repository that lives on the Worker VFS.
 *
 * `status`, `add --all`, `ls-files --others` and `checkout` all need the same
 * picture: every non-`.git` path, with its kind and stat fields, without
 * following a symlink out of the VFS and without descending into a nested
 * `.git`. The walk is deterministic (byte order), which keeps porcelain output
 * stable and testable.
 * @module @phone-dsh/dsh-wasi-toolbox/git/worktree
 */
import { compareStrings, isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'
import type { Repository } from './repo.ts'

/** One path found under the work tree. */
export interface WorktreeFile {
  readonly isDirectory: boolean
  readonly isSymbolicLink: boolean
  readonly size: number
  readonly mtimeMs: number
  readonly mode: number
}

/** Walk one work tree and return every path (directories included). */
export async function scanWorktree(repository: Repository): Promise<Map<string, WorktreeFile>> {
  const fs = repository.fs
  const workTree = repository.workTree
  const files = new Map<string, WorktreeFile>()
  if (workTree === undefined) return files
  const walk = async (relative: string): Promise<void> => {
    const directory = relative === '' ? workTree : `${workTree}/${relative}`
    let entries
    try {
      entries = await fs.readdir(directory)
    } catch (error) {
      if (isErrno(error, 'ENOENT', 'ENOTDIR')) return
      throw error
    }
    entries.sort((left, right) => compareStrings(left.name, right.name))
    for (const entry of entries) {
      if (entry.name === '.git') continue
      const path = relative === '' ? entry.name : `${relative}/${entry.name}`
      let stat
      try {
        stat = await fs.lstat(`${workTree}/${path}`)
      } catch (error) {
        if (isErrno(error, 'ENOENT', 'ENOTDIR')) continue
        throw error
      }
      files.set(path, {
        isDirectory: stat.isDirectory,
        isSymbolicLink: stat.isSymbolicLink,
        size: stat.size,
        mtimeMs: stat.mtimeMs,
        mode: stat.mode,
      })
      if (stat.isDirectory && !stat.isSymbolicLink) await walk(path)
    }
  }
  await walk('')
  return files
}

/** Remove one file or directory tree from the work tree, git's `remove_file`. */
export async function removeWorktreePath(fs: GitFs, workTree: string, path: string): Promise<void> {
  try {
    const stat = await fs.lstat(`${workTree}/${path}`)
    await fs.rm(`${workTree}/${path}`, { recursive: stat.isDirectory, force: true })
  } catch (error) {
    if (isErrno(error, 'ENOENT', 'ENOTDIR')) return
    throw error
  }
}

/** Create parent directories for one work-tree-relative path. */
export async function ensureParent(fs: GitFs, workTree: string, path: string): Promise<void> {
  const slash = path.lastIndexOf('/')
  if (slash > 0) await fs.mkdir(`${workTree}/${path.slice(0, slash)}`, true)
}
