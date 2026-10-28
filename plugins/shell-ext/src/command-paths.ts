// SPDX-License-Identifier: MIT
/**
 * The `PATH` face of the Worker shell: materialised command entry points.
 *
 * just-bash resolves a registered command through the filesystem before it runs
 * it. A bare name is looked up in every `PATH` directory, and — when no file
 * matches — its fallback is a **fabricated** `/usr/bin/<name>` path
 * (`command -v`, `type`, `which` and the interpreter's own lookup all share
 * that fallback). The Worker image has no `/usr/bin`, so before this module a
 * `command -v python3` answered `/usr/bin/python3` while `/usr/bin` did not
 * exist: the model believed an executable path that could not be executed, and
 * scenario G2-A05 burned 26 turns probing the environment.
 *
 * A real system writes a small entry per command into its binary directory, and
 * just-bash's own `registerCommandInternal` does exactly that (`/bin/<name>` and
 * `/usr/bin/<name>`, `#!/bin/bash` plus a comment) through
 * `IFileSystem.writeFileSync`. Before this module the `VfsFileSystem` adapter
 * had no synchronous hook, so the directories never existed.
 *
 * This module gives the shell its `PATH` face in one of two modes:
 *
 * - **virtual** (`VfsFileSystem`): `registerCommandNames([])` creates the two
 *   directories in memory, then the adapter's `writeFileSync` records exactly
 *   the commands just-bash actually instantiates as virtual entries. No file
 *   is written, so the real tree and `getAllPaths()` keep only user content,
 *   and a browser-excluded name (`python3`, `sqlite3`, ...) never gets an
 *   executable entry it cannot run;
 * - **real** (a backend with `writeFileSync` but no virtual table, such as the
 *   test `InMemoryFs`): the directories are created and just-bash's own
 *   registration writes fill them;
 * - **fallback** (a backend with neither hook): this module writes one entry
 *   per candidate name through the ordinary asynchronous `IFileSystem`.
 *
 * `/usr/bin` receives one executable entry per registered command (just-bash
 * built-ins plus the Worker command table, toolbox programs and accelerators)
 * and `/bin` receives `bash`/`sh`, the explicit paths POSIX scripts reach for.
 * The entries execute through just-bash's registered-command lookup, so
 * `"$(command -v tar)" -tzf a.tar.gz` runs the Worker `tar` command rather
 * than a second program.
 *
 * The directories live outside the D4 sink roots (`/dsh/home/**`,
 * `/dsh/workspace/**`), so creating them never becomes a persisted VFS
 * mutation; they are as volatile as `/dsh/tmp`. A filesystem that refuses the
 * write (a real read-only `/usr/bin` on a desktop, for example) is left
 * untouched: the shell then keeps just-bash's fallback instead of failing.
 * @module @phone-dsh/dsh-shell-ext/command-paths
 */

import type { IFileSystem } from 'just-bash/browser'

/** Directories the Worker shell advertises on `PATH`, in lookup order. */
export const WORKER_COMMAND_DIRECTORIES: readonly string[] = Object.freeze(['/usr/bin', '/bin'])

/** Commands materialised into `/bin` (the explicit paths POSIX scripts use). */
export const WORKER_BIN_COMMANDS: readonly string[] = Object.freeze(['bash', 'sh'])

/** One materialised entry: content just-bash itself writes for a command. */
export function commandEntryContent(name: string): string {
  return `#!/bin/bash\n# Built-in command: ${name}\n`
}

/** Legal entry name (a bare program name, never a path). */
const ENTRY_NAME = /^[A-Za-z0-9_+.-]+$/u

/** File systems already prepared by this module. */
const READY = new WeakSet<IFileSystem>()

/**
 * True when this filesystem already received its command entries.
 * @param fs - the shell filesystem.
 * @returns whether {@link materializeCommandPaths} succeeded for it.
 */
export function commandPathsReady(fs: IFileSystem): boolean {
  return READY.has(fs)
}

/** Create one executable entry, replacing a stale file. */
async function writeEntry(fs: IFileSystem, path: string): Promise<void> {
  await fs.writeFile(path, commandEntryContent(path.slice(path.lastIndexOf('/') + 1)))
  try {
    await fs.chmod(path, 0o755)
  } catch {
    // A backend without chmod still has a name-resolvable entry; the
    // registered-command lookup does not require the execute bit.
  }
}

/** True when `path` is an existing directory. */
async function isDirectory(fs: IFileSystem, path: string): Promise<boolean> {
  try {
    return (await fs.stat(path)).isDirectory
  } catch {
    return false
  }
}

/**
 * Keep only the `PATH` directories that exist in the filesystem view.
 *
 * A shell that advertises `/usr/bin:/bin` while neither exists sends the model
 * looking for programs that are not there. The Worker shell materialises those
 * two directories, so the default path is truthful; this function drops an
 * inherited entry that this VFS does not have and falls back to
 * {@link WORKER_COMMAND_DIRECTORIES} when every entry was dropped.
 * @param fs - the shell filesystem.
 * @param path - the `PATH` value to sanitise.
 * @returns the non-empty `PATH` to export.
 */
export async function sanitizeCommandPath(fs: IFileSystem, path: string): Promise<string> {
  const kept: string[] = []
  for (const entry of path.split(':')) {
    if (entry === '') continue
    if (await isDirectory(fs, entry)) kept.push(entry)
  }
  return kept.length > 0 ? kept.join(':') : WORKER_COMMAND_DIRECTORIES.join(':')
}

/**
 * Locate a program the way a POSIX shell's `PATH` search does.
 * @param fs - the shell filesystem.
 * @param name - bare program name (no slash).
 * @param path - the current `PATH` value.
 * @returns the existing path, or undefined when no directory has the name.
 */
export async function findCommandPath(fs: IFileSystem, name: string, path: string): Promise<string | undefined> {
  for (const directory of path.split(':')) {
    // The Worker VFS adapter only accepts absolute paths; a relative PATH
    // entry would need a cwd the helper does not have.
    if (!directory.startsWith('/')) continue
    const candidate = `${directory}/${name}`
    try {
      if (!(await fs.exists(candidate))) continue
      const stat = await fs.stat(candidate)
      if (!stat.isDirectory) return candidate
    } catch {
      continue
    }
  }
  return undefined
}

/**
 * Materialise the command entry points once per filesystem.
 *
 * The operation is deliberately best-effort at the filesystem boundary: a
 * backend that cannot create `/usr/bin` keeps the previous behaviour (bare
 * commands still resolve through just-bash's fallback) instead of turning every
 * command into a failure. Nothing is removed on a partial failure — a read-only
 * host tree must never be cleaned up by this module.
 *
 * For the virtual and synchronous modes the directories exist when this
 * function returns; the entries themselves are recorded by just-bash while it
 * constructs the interpreter, immediately afterwards.
 * @param fs - the shell filesystem.
 * @param names - every command name the shell serves (used by the fallback).
 * @returns true when the `PATH` directories are usable.
 */
export async function materializeCommandPaths(fs: IFileSystem, names: readonly string[]): Promise<boolean> {
  if (READY.has(fs)) return true
  const unique = [...new Set(names)].filter(name => ENTRY_NAME.test(name) && !name.includes('/'))
  // The Worker adapter answers the entries from memory. Registering no names
  // only makes `/usr/bin` and `/bin` exist; just-bash's own registration hook
  // (`writeFileSync`) then adds exactly the commands this bundle instantiates.
  // No file is created, so the real tree (and every `find /`) keeps only what
  // the user wrote, and a browser-excluded name never gets a fake executable.
  const synthetic = fs as IFileSystem & {
    registerCommandNames?: (entries: readonly string[]) => void
    writeFileSync?: unknown
  }
  if (typeof synthetic.registerCommandNames === 'function' && typeof synthetic.writeFileSync === 'function') {
    synthetic.registerCommandNames([])
    READY.add(fs)
    return true
  }
  // A backend with just-bash's synchronous registration hook but no virtual
  // command table (the in-memory test filesystem) fills the directories itself
  // once `Bash` is constructed; only the directories have to exist.
  if (typeof synthetic.writeFileSync === 'function') {
    try {
      await fs.mkdir('/usr/bin', { recursive: true })
      await fs.mkdir('/bin', { recursive: true })
      READY.add(fs)
      return true
    } catch {
      return false
    }
  }
  try {
    await fs.mkdir('/usr/bin', { recursive: true })
    await fs.mkdir('/bin', { recursive: true })
    // Prove writability with one throwaway entry before creating the full set:
    // a read-only tree must stay exactly as it was.
    const probe = '/usr/bin/.pdsh-shell-probe'
    await fs.writeFile(probe, '')
    await fs.rm(probe, { force: true })
  } catch {
    return false
  }
  try {
    for (const name of unique) await writeEntry(fs, `/usr/bin/${name}`)
    for (const name of WORKER_BIN_COMMANDS) await writeEntry(fs, `/bin/${name}`)
    READY.add(fs)
    return true
  } catch {
    return false
  }
}
