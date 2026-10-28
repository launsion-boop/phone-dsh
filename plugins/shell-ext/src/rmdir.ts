// SPDX-License-Identifier: MIT
/**
 * `rmdir`: POSIX empty-directory removal for the Worker shell.
 *
 * just-bash's bundled `rmdir` calls `fs.rm(dir, {recursive:false})`; this
 * layer's adapter answered a directory there by calling `nodeFs.rmdir`. The
 * pinned runtime's `node:fs` replacement implements `rm`/`unlink` but not
 * `rmdir`/`rmdirSync` (packages/experimental/webworker-runtime/src/node/
 * builtin_modules/implemented/fs.ts:291-300,841-842), so every `rmdir` in the
 * Worker died with a raw `this.nodeFs.rmdir is not a function` TypeError while
 * `rm -rf` on the same directory worked (G2-D06 transcript L515/L519; the
 * adapter's own contract is `filesystem.ts`).
 *
 * This module shadows the built-in through just-bash's custom-command table.
 * The whole command runs over the `IFileSystem` faces the Worker actually
 * provides:
 *
 * - one empty directory per operand, left to right;
 * - `-p`/`--parents` also removes each now-empty ancestor;
 * - `-v`/`--verbose` prints the removal line;
 * - missing path -> exit 1, `ENOENT` in the diagnostic;
 * - operand is a file (or symlink) -> exit 1, `ENOTDIR`;
 * - non-empty directory -> exit 1, `ENOTEMPTY`, and the tree is left exactly as
 *   it was (the check runs before any removal).
 *
 * Every successful removal is the backend's own `rm` of that one directory, so
 * the runtime VFS publishes a remove mutation (VFS op 3) and the WAL and
 * materialized copy observe it exactly as they observe `rm -r`.
 * @module @phone-dsh/dsh-shell-ext/rmdir
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, IFileSystem } from 'just-bash/browser'
import { shellFailure, withCommandExit } from './contract.ts'

/** The help text the Worker shim prints for `rmdir --help`. */
export const RMDIR_HELP = `Usage: rmdir [-pv] DIRECTORY...
Remove empty directories.

Options:
  -p, --parents   Remove DIRECTORY and its ancestors
  -v, --verbose   Output a diagnostic for every directory processed
      --help      Display this help and exit
      --version   Output version information and exit
`

/** One parsed `rmdir` invocation. */
export interface RmdirArguments {
  /** Also remove every ancestor that becomes empty (`-p`/`--parents`). */
  readonly parents: boolean
  /** Print one line per removed directory (`-v`/`--verbose`). */
  readonly verbose: boolean
  /** Directory operands in command-line order. */
  readonly operands: readonly string[]
  readonly help: boolean
  readonly version: boolean
}

/** An option word the shim does not implement. */
export class RmdirUsageError extends Error {
  /**
   * @param message - diagnostic body without the `rmdir: ` prefix.
   */
  constructor(message: string) {
    super(message)
    this.name = 'RmdirUsageError'
  }
}

/**
 * Parse `rmdir`'s option surface.
 * @param argv - arguments after the program name.
 * @returns the parsed invocation.
 * @throws {RmdirUsageError} for an option outside the documented set.
 */
export function parseRmdirArguments(argv: readonly string[]): RmdirArguments {
  let parents = false
  let verbose = false
  let help = false
  let version = false
  const operands: string[] = []
  let options = true
  for (const argument of argv) {
    if (!options || argument === '-' || !argument.startsWith('-')) {
      operands.push(argument)
      continue
    }
    if (argument === '--') {
      options = false
      continue
    }
    if (argument === '--parents') {
      parents = true
      continue
    }
    if (argument === '--verbose') {
      verbose = true
      continue
    }
    if (argument === '--help') {
      help = true
      continue
    }
    if (argument === '--version') {
      version = true
      continue
    }
    if (argument.startsWith('--')) throw new RmdirUsageError(`unrecognized option '${argument}'`)
    for (const flag of argument.slice(1)) {
      if (flag === 'p') parents = true
      else if (flag === 'v') verbose = true
      else throw new RmdirUsageError(`invalid option -- '${flag}'`)
    }
  }
  return { parents, verbose, operands, help, version }
}

/**
 * The portable text of the errno codes a directory removal can surface.
 *
 * The diagnostic names the code (`ENOTEMPTY: Directory not empty`) because the
 * scenario and the tool journal quote it: the bare just-bash text named no
 * code, and a raw JS TypeError named neither the code nor a POSIX condition.
 */
const ERRNO_TEXT: Readonly<Record<string, string>> = Object.freeze({
  EACCES: 'Permission denied',
  EBUSY: 'Device or resource busy',
  EEXIST: 'File exists',
  EINVAL: 'Invalid argument',
  EIO: 'Input/output error',
  ELOOP: 'Too many levels of symbolic links',
  ENAMETOOLONG: 'File name too long',
  ENOENT: 'No such file or directory',
  ENOTDIR: 'Not a directory',
  ENOTEMPTY: 'Directory not empty',
  EPERM: 'Operation not permitted',
  EROFS: 'Read-only file system',
})

/** One failed operand removal. */
interface RmdirFailure {
  readonly ok: false
  /** Diagnostic body: `rmdir: failed to remove '<operand>': <code>: <text>`. */
  readonly message: string
}

/** One successful operand removal. */
interface RmdirSuccess {
  readonly ok: true
}

/** Render one failure with the errno name the scenario expects. */
function failure(operand: string, error: unknown): RmdirFailure {
  const coded = error as { code?: unknown; message?: unknown }
  const code = typeof coded.code === 'string' && coded.code !== '' ? coded.code : 'EIO'
  const text = ERRNO_TEXT[code]
  if (text !== undefined) {
    return { ok: false, message: `rmdir: failed to remove '${operand}': ${code}: ${text}` }
  }
  const message = typeof coded.message === 'string' && coded.message !== '' ? coded.message : String(error)
  const detail = message.includes(code) ? message : `${code}: ${message}`
  return { ok: false, message: `rmdir: failed to remove '${operand}': ${detail}` }
}

/** Render one known POSIX condition without a thrown backend error. */
function condition(operand: string, code: 'ENOTDIR' | 'ENOTEMPTY'): RmdirFailure {
  return { ok: false, message: `rmdir: failed to remove '${operand}': ${code}: ${ERRNO_TEXT[code] as string}` }
}

/**
 * Remove exactly one empty directory.
 *
 * `lstat` keeps a symlink to a directory out of the removal path (`ENOTDIR`),
 * the `readdir` emptiness check makes a populated tree an `ENOTEMPTY` before
 * anything is removed, and the final `rm` is the backend's one mutation — the
 * remove VFS op the sink observes.
 * @param fs - the shell filesystem.
 * @param absolute - normalised absolute path to the directory.
 * @param operand - path as the user wrote it, for the diagnostic.
 * @returns success, or the diagnostic body.
 */
async function removeOneDirectory(fs: IFileSystem, absolute: string, operand: string): Promise<RmdirSuccess | RmdirFailure> {
  let stats
  try {
    stats = await fs.lstat(absolute)
  } catch (error) {
    return failure(operand, error)
  }
  // A symlink is never a directory for rmdir, even when it points at one.
  if (stats.isSymbolicLink || !stats.isDirectory) return condition(operand, 'ENOTDIR')
  let entries
  try {
    entries = await fs.readdir(absolute)
  } catch (error) {
    return failure(operand, error)
  }
  if (entries.length > 0) return condition(operand, 'ENOTEMPTY')
  try {
    await fs.rm(absolute, { recursive: false, force: false })
  } catch (error) {
    return failure(operand, error)
  }
  return { ok: true }
}

/**
 * `rmdir` over the Worker shell's filesystem.
 * @returns the command definition.
 */
export function createRmdirCommand(): Command {
  return defineCommand('rmdir', async (args, ctx): Promise<ExecResult> => {
    let parsed: RmdirArguments
    try {
      parsed = parseRmdirArguments(args)
    } catch (error) {
      if (error instanceof RmdirUsageError) return shellFailure('rmdir', `rmdir: ${error.message}`, 'unsupported-option')
      throw error
    }
    if (parsed.help) return { stdout: RMDIR_HELP, stderr: '', exitCode: 0 }
    if (parsed.version) return { stdout: 'rmdir (Worker shell) 1.0\n', stderr: '', exitCode: 0 }
    if (parsed.operands.length === 0) {
      // POSIX rmdir exits 1 for a missing operand; the reason token stays the
      // usage-boundary one, with the status the engine and GNU use.
      return shellFailure('rmdir', 'rmdir: missing operand', 'unsupported-option', { exitCode: 1 })
    }
    let stdout = ''
    let stderr = ''
    let failed = false
    for (const operand of parsed.operands) {
      const absolute = posix.normalize(ctx.fs.resolvePath(ctx.cwd, operand))
      const removed = await removeOneDirectory(ctx.fs, absolute, operand)
      if (!removed.ok) {
        stderr += `${removed.message}\n`
        failed = true
        continue
      }
      if (parsed.verbose) stdout += `rmdir: removing directory, '${operand}'\n`
      if (!parsed.parents) continue
      // `-p` walks the operand's ancestors while they are empty. The walk stops
      // at the cwd spelling `.`/`/`, so it never removes the working directory
      // through a bare operand and never calls `rm('/')`.
      let display = operand
      let parentAbsolute = posix.dirname(absolute)
      for (;;) {
        const displayParent = posix.dirname(display)
        if (displayParent === '.' || displayParent === '/' || displayParent === '' || displayParent === display) break
        if (parentAbsolute === '/' || parentAbsolute === '') break
        const parentRemoved = await removeOneDirectory(ctx.fs, parentAbsolute, displayParent)
        if (!parentRemoved.ok) {
          // GNU -p stops at the first ancestor it cannot remove; the already
          // removed descendants stay removed.
          stderr += `${parentRemoved.message}\n`
          failed = true
          break
        }
        if (parsed.verbose) stdout += `rmdir: removing directory, '${displayParent}'\n`
        display = displayParent
        parentAbsolute = posix.dirname(parentAbsolute)
      }
    }
    const result: ExecResult = { stdout, stderr, exitCode: failed ? 1 : 0 }
    return failed ? withCommandExit(result, 'rmdir') : result
  })
}
