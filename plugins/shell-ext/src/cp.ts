// SPDX-License-Identifier: MIT
/**
 * `cp` archive/preserve shim for the Worker shell.
 *
 * just-bash 3.6.0's bundled `cp` parses only `-r/-R/-n/-p/-v`, and its parser
 * rejects `-a` and `-d` with `cp: invalid option -- 'a'` / `-- 'd'`. `-p` is
 * accepted but the bundled implementation never consumes it: a mode survives
 * only because the adapter's `node:fs.cp` happens to copy the mode. Nothing
 * explicitly preserves ownership or timestamps, and nothing pins the mode to
 * a regression test (G2-FIX-98).
 *
 * This module shadows the built-in through just-bash's custom-command table and
 * keeps the bundled command as the copy engine (`ctx.origCommand`), so path
 * resolution, error bytes, `-n`/`-v` and the verbose wording stay the
 * built-in's. The shim only owns the archive/preserve surface:
 *
 * - `-a`/`--archive` = `-dR --preserve=all`;
 * - `-p`/`--preserve` = `mode,ownership,timestamps`;
 * - `-d`/`--no-dereference`;
 * - `--preserve=LIST` (repeatable, comma-separated; `mode`, `ownership`,
 *   `timestamps`, `links`, `all`);
 * - combined short clusters such as `-av` and `-aR`, plus the existing
 *   `-r`/`-R`/`-n`/`-v` flags, `--help` and `--`.
 *
 * Every invocation that uses none of those options is delegated byte-for-byte
 * with the original argv. An invocation that does use them is first normalised
 * to the flags the built-in knows (`-R/-p/-v/-n`), then copied, and only after
 * the copy succeeds does the shim apply the preserved metadata to each target:
 * `chmod` (the Worker VFS publishes it as VFS op 4) and `utimes`. Files are
 * restored before directories, and directories deepest-first, so changing a
 * directory mode cannot make a later write fail.
 *
 * Worker VFS limits, documented rather than simulated:
 * - `ownership` has no owner in the Worker VFS; the documented single-user
 *   constants (`stat`'s `1000/user`) stay authoritative.
 * - `links` has no hard-link object in the Worker VFS (the adapter reports one
 *   link per file); there is nothing to replay.
 * - `-d` is accepted and recorded. The Worker VFS has no symlinks, so it is
 *   equivalent to the default. If a backend really hands the shim a symlink,
 *   `-d` fails loud with the VFS limitation instead of silently following it.
 *
 * An invalid `--preserve` attribute fails before any source is read or target
 * created, with GNU's `cp: invalid argument '<x>' for '--preserve'` wording.
 * @module @phone-dsh/dsh-shell-ext/cp
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, IFileSystem } from 'just-bash/browser'
import { shellFailure, withCommandExit } from './contract.ts'

/** Preserve attributes the Worker shim understands. */
export type CpPreserveAttribute = 'mode' | 'ownership' | 'timestamps' | 'links'

/** The four attributes `--preserve=all` expands to. */
const ALL_PRESERVE_ATTRIBUTES: readonly CpPreserveAttribute[] = Object.freeze([
  'mode', 'ownership', 'timestamps', 'links',
])

/** The attributes `-p` / a bare `--preserve` expands to. */
const DEFAULT_PRESERVE_ATTRIBUTES: readonly CpPreserveAttribute[] = Object.freeze([
  'mode', 'ownership', 'timestamps',
])

/** One parsed `cp` invocation. */
export interface CpArguments {
  /** `-a`/`--archive` was given. */
  readonly archive: boolean
  /** Recursive copy (`-a`, `-r` or `-R`). */
  readonly recursive: boolean
  /** Do not overwrite an existing target (`-n`). */
  readonly noClobber: boolean
  /** Explain every copied operand (`-v`). */
  readonly verbose: boolean
  /** `-d`/`--no-dereference`/`-a` was given. */
  readonly noDereference: boolean
  /** Requested preserve attributes after `-p`, `-a` and `--preserve=`. */
  readonly preserve: ReadonlySet<CpPreserveAttribute>
  /** Source operands, then the destination, exactly as written. */
  readonly operands: readonly string[]
  /** argv normalised to the flag subset the bundled `cp` parses. */
  readonly delegated: readonly string[]
  /** `--help` was requested; the bundled help stays authoritative. */
  readonly help: boolean
}

/** A command-line error the shim cannot hand to the bundled parser. */
export class CpUsageError extends Error {
  /**
   * argv the bundled command should parse to reproduce this diagnostic.
   * Undefined for an error the bundled parser would not produce (an invalid
   * `--preserve` attribute).
   */
  readonly delegated: readonly string[] | undefined

  /**
   * @param message - diagnostic body without the `cp: ` prefix.
   * @param delegated - argv to let the built-in render the same error.
   */
  constructor(message: string, delegated?: readonly string[]) {
    super(message)
    this.name = 'CpUsageError'
    this.delegated = delegated
  }
}

/**
 * Whether argv names the archive/preserve/no-dereference surface at all.
 *
 * The command uses this before parsing: every invocation without one of these
 * options must reach the bundled `cp` with the exact original argv, so `cp a
 * b`, `cp -R`, `cp -n`, `cp -v` and every built-in error keep their bytes.
 * @param argv - arguments after the program name.
 * @returns true when an archive, preserve or no-dereference option is present.
 */
export function hasCpArchiveArguments(argv: readonly string[]): boolean {
  let options = true
  for (const argument of argv) {
    if (!options) continue
    if (argument === '--') {
      options = false
      continue
    }
    if (
      argument === '--archive'
      || argument === '--preserve'
      || argument.startsWith('--preserve=')
      || argument === '--no-dereference'
    ) {
      return true
    }
    if (argument.startsWith('--')) continue
    if (argument === '-' || !argument.startsWith('-')) continue
    for (const flag of argument.slice(1)) {
      if (flag === 'a' || flag === 'p' || flag === 'd') return true
    }
  }
  return false
}

/** Add one `--preserve=LIST` list to the accumulated attribute set. */
function addPreserveList(attributes: Set<CpPreserveAttribute>, list: string): void {
  if (list === '') throw new CpUsageError("invalid argument '' for '--preserve'")
  for (const attribute of list.split(',')) {
    if (attribute === '') throw new CpUsageError("invalid argument '' for '--preserve'")
    if (attribute === 'all') {
      for (const expanded of ALL_PRESERVE_ATTRIBUTES) attributes.add(expanded)
      continue
    }
    if (
      attribute === 'mode'
      || attribute === 'ownership'
      || attribute === 'timestamps'
      || attribute === 'links'
    ) {
      attributes.add(attribute)
      continue
    }
    throw new CpUsageError(`invalid argument '${attribute}' for '--preserve'`)
  }
}

/**
 * Parse one `cp` argv into the archive surface plus the delegated argv.
 *
 * The parser is pure: it never touches the filesystem. An option just-bash's
 * `cp` does not know throws {@link CpUsageError} carrying a delegated argv, so
 * the command can let the built-in produce its own exact diagnostic. An
 * invalid `--preserve` attribute throws without a delegated argv; the shim
 * reports it and creates nothing.
 * @param argv - arguments after the program name.
 * @returns the parsed invocation.
 */
export function parseCpArguments(argv: readonly string[]): CpArguments {
  let archive = false
  let recursive = false
  let noClobber = false
  let verbose = false
  let noDereference = false
  let help = false
  let sawDoubleDash = false
  const preserve = new Set<CpPreserveAttribute>()
  const operands: string[] = []

  /** Normalised flags accepted by just-bash's `cp` parser. */
  const flags = (): string[] => {
    const normalised: string[] = []
    if (recursive) normalised.push('-R')
    if (preserve.size > 0) normalised.push('-p')
    if (verbose) normalised.push('-v')
    if (noClobber) normalised.push('-n')
    return normalised
  }

  let options = true
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index] as string
    if (!options) {
      operands.push(argument)
      continue
    }
    if (argument === '--') {
      options = false
      sawDoubleDash = true
      continue
    }
    if (argument === '--help') {
      help = true
      continue
    }
    if (argument === '--archive') {
      archive = true
      continue
    }
    if (argument === '--preserve') {
      for (const attribute of DEFAULT_PRESERVE_ATTRIBUTES) preserve.add(attribute)
      continue
    }
    if (argument.startsWith('--preserve=')) {
      addPreserveList(preserve, argument.slice('--preserve='.length))
      continue
    }
    if (argument === '--no-dereference') {
      noDereference = true
      continue
    }
    if (argument === '--recursive') {
      recursive = true
      continue
    }
    if (argument === '--no-clobber') {
      noClobber = true
      continue
    }
    if (argument === '--verbose') {
      verbose = true
      continue
    }
    if (argument.startsWith('--')) {
      throw new CpUsageError(`unrecognized option '${argument}'`, [
        ...flags(),
        argument,
        ...argv.slice(index + 1),
      ])
    }
    if (argument !== '-' && argument.startsWith('-')) {
      for (let offset = 1; offset < argument.length; offset += 1) {
        const flag = argument[offset] as string
        if (flag === 'a') {
          archive = true
          recursive = true
          for (const attribute of ALL_PRESERVE_ATTRIBUTES) preserve.add(attribute)
        } else if (flag === 'p') {
          for (const attribute of DEFAULT_PRESERVE_ATTRIBUTES) preserve.add(attribute)
        } else if (flag === 'd') {
          noDereference = true
        } else if (flag === 'r' || flag === 'R') {
          recursive = true
        } else if (flag === 'n') {
          noClobber = true
        } else if (flag === 'v') {
          verbose = true
        } else {
          // A short cluster containing an archive/preserve flag reaches this
          // parser. Do not hand the rest of the cluster back to the bundled
          // parser: a cluster ending in `-` would become `--`, an option
          // terminator, and the copy would succeed with a silent status 0.
          // Report the first unknown flag ourselves, before any source is
          // read or target created, with the Worker contract trailer.
          throw new CpUsageError(`invalid option -- '${flag}'`)
        }
      }
      continue
    }
    operands.push(argument)
  }

  if (archive) {
    recursive = true
    noDereference = true
    for (const attribute of ALL_PRESERVE_ATTRIBUTES) preserve.add(attribute)
  }

  const delegated = [
    ...flags(),
    ...sawDoubleDash ? ['--'] : [],
    ...operands,
  ]
  return {
    archive,
    recursive,
    noClobber,
    verbose,
    noDereference,
    preserve,
    operands,
    delegated,
    help,
  }
}

/** One source/destination pair whose metadata must be restored. */
interface CopyPlan {
  /** Source operand as the user wrote it (for diagnostics). */
  readonly operand: string
  /** Absolute source path. */
  readonly source: string
  /** Absolute copy target, matching the built-in's mapping. */
  readonly target: string
}

/** One entry of a source tree and the target it became. */
interface PreservationEntry {
  /** Absolute target path. */
  readonly target: string
  /** Permission and special bits from the source. */
  readonly mode: number
  /** The single timestamp the Worker VFS reports, when it reports one. */
  readonly mtime: Date | undefined
  /** Whether the target is a directory (restored after its files). */
  readonly directory: boolean
  /** Depth below the source root; directories restore deepest-first. */
  readonly depth: number
}

/**
 * The base name the bundled `cp` uses when the target is a directory.
 *
 * It is deliberately the built-in's exact expression (`source.split('/').pop()
 * || source`), including the fallback for a trailing slash, so the shim's
 * target never disagrees with the copy it post-processes.
 */
function copyBaseName(operand: string): string {
  return operand.split('/').pop() || operand
}

/** Join a target directory and a source basename without changing either. */
function copyTarget(directory: string, operand: string): string {
  const base = copyBaseName(operand)
  return posix.normalize(directory === '/' ? `/${base}` : `${directory}/${base}`)
}

/**
 * Plan the exact target the bundled `cp` will copy each source to.
 *
 * The destination is stat'd first: a directory target maps every source to
 * `dest/basename(source)`; a missing destination (or a file destination with
 * one source) maps the single source to the destination itself. Multiple
 * sources with a non-directory destination are left to the built-in's own
 * `target ... is not a directory` error, so the shim plans nothing.
 * @param fs - the shell filesystem.
 * @param cwd - the shell working directory.
 * @param parsed - the parsed invocation.
 * @returns one plan per source that can be pre-stated, or an empty list when
 *   the built-in owns the outcome (missing operands, invalid target).
 */
async function planCopies(fs: IFileSystem, cwd: string, parsed: CpArguments): Promise<CopyPlan[]> {
  if (parsed.operands.length < 2) return []
  const sources = parsed.operands.slice(0, -1)
  const destinationOperand = parsed.operands[parsed.operands.length - 1] as string
  const destination = fs.resolvePath(cwd, destinationOperand)

  let destinationIsDirectory = false
  try {
    destinationIsDirectory = (await fs.stat(destination)).isDirectory
  } catch {
    destinationIsDirectory = false
  }
  if (sources.length > 1 && !destinationIsDirectory) return []

  const plans: CopyPlan[] = []
  for (const operand of sources) {
    const source = fs.resolvePath(cwd, operand)
    try {
      await fs.lstat(source)
    } catch {
      // The built-in owns the missing-source diagnostic.
      continue
    }
    const target = destinationIsDirectory ? copyTarget(destination, operand) : destination
    if (parsed.noClobber) {
      // `-n` skips an existing target before copying; never restore metadata
      // onto a file this invocation did not create.
      let targetExists = true
      try {
        await fs.stat(target)
      } catch {
        targetExists = false
      }
      if (targetExists) continue
    }
    plans.push({ operand, source, target })
  }
  return plans
}

/**
 * Find a symlink below a source path, without following one.
 * @returns the first symlink path, or undefined for a symlink-free tree.
 */
async function findSymlink(fs: IFileSystem, path: string): Promise<string | undefined> {
  let stats
  try {
    stats = await fs.lstat(path)
  } catch {
    return undefined
  }
  if (stats.isSymbolicLink) return path
  if (!stats.isDirectory) return undefined
  let entries
  try {
    entries = await fs.readdir(path)
  } catch {
    return undefined
  }
  for (const entry of entries) {
    const found = await findSymlink(fs, posix.join(path, entry))
    if (found !== undefined) return found
  }
  return undefined
}

/**
 * Collect the metadata of one copied source tree.
 *
 * A symlink is followed for metadata unless `-d` was requested (the command
 * refuses a real symlink before reaching here). Directories are walked only
 * when the copy is recursive; the built-in otherwise refuses the directory
 * itself.
 * @param fs - the shell filesystem.
 * @param source - absolute source path.
 * @param target - absolute target path.
 * @param recursive - whether the copied tree is recursive.
 * @param entries - output list, source order.
 * @param depth - depth below the source root.
 */
async function collectPreservation(
  fs: IFileSystem,
  source: string,
  target: string,
  recursive: boolean,
  entries: PreservationEntry[],
  depth = 0,
): Promise<void> {
  let linkStats
  try {
    linkStats = await fs.lstat(source)
  } catch {
    return
  }
  let stats
  try {
    stats = linkStats.isSymbolicLink ? await fs.stat(source) : linkStats
  } catch {
    return
  }
  entries.push({
    target,
    mode: stats.mode & 0o7777,
    mtime: statMtime(stats),
    directory: stats.isDirectory,
    depth,
  })
  if (!stats.isDirectory || !recursive) return
  let children
  try {
    children = await fs.readdir(source)
  } catch {
    return
  }
  for (const child of children) {
    await collectPreservation(
      fs,
      posix.join(source, child),
      posix.join(target, child),
      recursive,
      entries,
      depth + 1,
    )
  }
}

/** Read the one timestamp a backend exposes (Node Date or `mtimeMs`). */
function statMtime(stats: { readonly mtime?: unknown; readonly mtimeMs?: unknown }): Date | undefined {
  if (stats.mtime instanceof Date) return stats.mtime
  if (typeof stats.mtimeMs === 'number') return new Date(stats.mtimeMs)
  return undefined
}

/** One metadata restoration failure. */
interface PreservationFailure {
  readonly target: string
  readonly message: string
}

/**
 * Restore mode and timestamps, files first and directories deepest-first.
 *
 * `ownership` and `links` are accepted and intentionally have no operation:
 * the Worker VFS has no owner and no hard-link object to replay. A failure is
 * reported and turned into a non-zero command result rather than swallowed.
 */
async function applyPreservation(
  fs: IFileSystem,
  entries: readonly PreservationEntry[],
  preserve: ReadonlySet<CpPreserveAttribute>,
): Promise<PreservationFailure[]> {
  const files = entries.filter(entry => !entry.directory)
  const directories = entries
    .filter(entry => entry.directory)
    .sort((left, right) => right.depth - left.depth)
  const failures: PreservationFailure[] = []
  for (const entry of [...files, ...directories]) {
    try {
      if (preserve.has('mode')) await fs.chmod(entry.target, entry.mode)
      if (preserve.has('timestamps') && entry.mtime !== undefined) {
        // just-bash's command defense membrane proxies a Date across
        // `ctx.fs`, and Node's `toUnixTimestamp` then sees a Proxy rather than
        // a Date. Passing epoch seconds (a primitive) keeps the timestamp
        // intact through the membrane; `VfsFileSystem.utimes` forwards it to
        // `node:fs`, which accepts both forms.
        const seconds = entry.mtime.getTime() / 1000
        await fs.utimes(entry.target, seconds as unknown as Date, seconds as unknown as Date)
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      failures.push({ target: entry.target, message })
    }
  }
  return failures
}

/**
 * Build the `cp` custom command that adds archive/preserve semantics.
 * @returns the `cp` command definition.
 */
export function createCpCommand(): Command {
  return defineCommand('cp', async (args, ctx): Promise<ExecResult> => {
    // just-bash renders --help before option parsing; keep those bytes.
    if (args.includes('--help')) {
      if (ctx.origCommand === undefined) {
        return shellFailure('cp', 'cp: the built-in cp is unavailable in this shell', 'backend-failed')
      }
      return await ctx.origCommand([...args])
    }
    // No archive/preserve/no-dereference option: the built-in owns the whole
    // invocation, down to the exact argv and its error bytes.
    if (!hasCpArchiveArguments(args)) {
      if (ctx.origCommand === undefined) {
        return shellFailure('cp', 'cp: the built-in cp is unavailable in this shell', 'backend-failed')
      }
      return await ctx.origCommand([...args])
    }
    let parsed: CpArguments
    try {
      parsed = parseCpArguments(args)
    } catch (error) {
      if (error instanceof CpUsageError) {
        if (error.delegated !== undefined && ctx.origCommand !== undefined) {
          return await ctx.origCommand([...error.delegated])
        }
        return shellFailure('cp', `cp: ${error.message}`, 'unsupported-option')
      }
      throw error
    }
    if (ctx.origCommand === undefined) {
      return shellFailure('cp', 'cp: the built-in cp is unavailable in this shell', 'backend-failed')
    }

    // Resolve and stat every source before the copy. `-d` must never silently
    // follow a symlink this symlink-free Worker VFS cannot preserve.
    const operands = parsed.operands
    const sources = operands.length >= 2 ? operands.slice(0, -1) : []
    const normalizedSources = sources.map(operand => ctx.fs.resolvePath(ctx.cwd, operand))
    if (parsed.noDereference) {
      for (const source of normalizedSources) {
        const symlink = await findSymlink(ctx.fs, source)
        if (symlink !== undefined) {
          return shellFailure(
            'cp',
            `cp: cannot preserve symbolic link '${symlink}': the Worker VFS is symlink-free, so -d cannot be honoured`,
            'unsupported-option',
          )
        }
      }
    }

    const plans = await planCopies(ctx.fs, ctx.cwd, parsed)
    const entries: PreservationEntry[] = []
    if (parsed.preserve.size > 0) {
      for (const plan of plans) {
        await collectPreservation(ctx.fs, plan.source, plan.target, parsed.recursive, entries)
      }
    }

    const result = await ctx.origCommand([...parsed.delegated])
    // A failed copy is the built-in's result: preserve only targets that were
    // actually copied successfully.
    if (result.exitCode !== 0 || parsed.preserve.size === 0) return result
    const failures = await applyPreservation(ctx.fs, entries, parsed.preserve)
    if (failures.length === 0) return result
    let stderr = result.stderr
    for (const failure of failures) {
      stderr += `cp: preserving metadata for '${failure.target}': ${failure.message}\n`
    }
    return withCommandExit({ ...result, stderr, exitCode: 1 }, 'cp')
  })
}
