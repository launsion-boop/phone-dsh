// SPDX-License-Identifier: MIT
/**
 * Program identity for direct `ctx.subprocess.spawn` calls (PLAN D12).
 *
 * Some upstream plugins address a program by its absolute executable path
 * instead of its bare name. DSH's `tool-fs-search` is the shipped example: it
 * spawns the packaged ripgrep as `resolveRgPath()` — an absolute path under
 * `@vscode/ripgrep` (or the single-file runtime's `<executable>-rg` sidecar).
 *
 * The Worker dispatch routes programs by identity: a host accelerator must
 * match the bare name advertised in the HELLO caps, and a Worker-resident
 * program is served by the shell command table. A path-form program matches
 * neither, so it would fall through to `node:child_process` and fail as a
 * missing binary even though the Worker has (or the host advertises) the same
 * program.
 *
 * {@link resolveProgramIdentity} is deliberately program-based, not
 * caller-based: it recognizes an executable shape once and every caller of
 * that program gets the same route. A path that resolves to no known program
 * is returned unchanged, so it keeps failing loud exactly as before.
 *
 * The Worker-local `rg` is the shell-ext shim over just-bash's built-in. The
 * shim owns a `--glob`/`--iglob` search end to end (globset plus
 * `--sort=modified` ordering), so {@link workerRipgrepArgv} passes such an argv
 * through untouched; for every other search it translates only the flags
 * just-bash documents as unsupported (its own help/options surface) and leaves
 * every search flag in place. The host accelerator receives the untouched DSH
 * flag set.
 * @module @phone-dsh/dsh-subprocess-xl/program
 */

import { posix } from 'node:path'

/** Canonical name of the ripgrep program (mirrors the `accelerator:rg` cap). */
export const RIPGREP_PROGRAM = 'rg'

/** The single-file runtime's sidecar (`<executable>-rg`, `<executable>-rg.exe`). */
const RIPGREP_SIDECAR = /-rg(?:\.exe)?$/u

/** An absolute path inside the `@vscode/ripgrep` package family. */
const RIPGREP_PACKAGE = /(?:^|\/)@vscode\/ripgrep(?:-[^/]*)?\//u

/**
 * True when an absolute path names the packaged ripgrep executable.
 *
 * The shapes are the ones `resolveRgPath()` can return: the platform package's
 * `bin/rg`, the main package's `bin/rg`, and the `pkg` sidecar next to the
 * runtime executable. A bare `rg` is not a path and is handled by identity
 * pass-through.
 * @param program - argv[0] as the caller supplied it.
 * @returns true for the packaged ripgrep executable shapes.
 */
export function isRipgrepExecutable(program: string): boolean {
  if (!posix.isAbsolute(program)) return false
  const base = posix.basename(program).toLowerCase()
  if (base === 'rg' || base === 'rg.exe') return true
  if (RIPGREP_SIDECAR.test(base)) return true
  return RIPGREP_PACKAGE.test(program)
}

/**
 * Resolve argv[0] to the identity the Worker dispatch routes.
 *
 * - the packaged ripgrep executable shape becomes the `rg` program, whether or
 *   not the host advertised it (the Worker shell serves it too);
 * - any other absolute path keeps its own name, but when that basename is an
 *   advertised accelerator name the path names that read-only host program and
 *   is routed by the advertised bare name;
 * - a path that resolves to no known program is returned unchanged.
 * @param program - argv[0] after confinement-marker stripping.
 * @param advertised - the host HELLO accelerator names (bare).
 * @returns the program identity (a bare name for a known program).
 */
export function resolveProgramIdentity(program: string, advertised: readonly string[] = []): string {
  if (!posix.isAbsolute(program)) return program
  if (isRipgrepExecutable(program)) return RIPGREP_PROGRAM
  const base = posix.basename(program)
  return advertised.includes(base) ? base : program
}

/**
 * True when the argv carries a ripgrep `--glob`/`--iglob` filter before the
 * end-of-options marker. This is the same surface the shell-ext `rg` shim
 * intercepts (see `shell-ext/src/ripgrep.ts`).
 * @param argv - the resolved `rg` argv (argv[0] is the program).
 * @returns true when a glob argument is present.
 */
function hasGlobArgument(argv: readonly string[]): boolean {
  let options = true
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index] as string
    if (!options) continue
    if (argument === '--') {
      options = false
      continue
    }
    if (argument === '--glob' || argument === '--iglob' || argument === '-g') return true
    if (argument.startsWith('--glob=') || argument.startsWith('--iglob=')) return true
    if (argument.startsWith('-g') && !argument.startsWith('--') && argument.length > 2) return true
  }
  return false
}

/**
 * Translate a ripgrep argv for the Worker-local `rg` (the shell-ext shim over
 * just-bash's built-in).
 *
 * A search with `--glob`/`--iglob` is owned end to end by the shell-ext shim:
 * it removes the glob filters from the delegated argv, applies ripgrep's
 * globset, and re-applies `--sort=modified` after filtering. Pre-translating
 * the ordering flag here would erase that signal, so a glob argv passes
 * through untouched (argv[0] becomes the program identity) and the shim drops
 * the flags just-bash rejects. Every other search keeps the built-in
 * translation:
 *
 * - `--no-config`: real ripgrep's config-file guard; the Worker shell has no
 *   config files, so it is a no-op and just-bash rejects the unknown flag;
 * - `--sort=modified`: modification-time order is not part of just-bash's
 *   documented `--sort` values; `--sort=path` is the supported deterministic
 *   order;
 * - `--`: real ripgrep's end-of-options marker; just-bash's parser has none,
 *   so the marker is dropped and the operands stay positional (a search root
 *   that itself begins with `-` cannot be expressed Worker-local).
 *
 * Every other argument passes through verbatim, including the search flags.
 * @param argv - the resolved `rg` argv (argv[0] is the program).
 * @returns the argv the Worker-local `rg` accepts.
 */
export function workerRipgrepArgv(argv: readonly string[]): string[] {
  if (hasGlobArgument(argv)) return [RIPGREP_PROGRAM, ...argv.slice(1)]
  const rewritten = [RIPGREP_PROGRAM]
  let options = true
  for (const argument of argv.slice(1)) {
    if (options && argument === '--') {
      options = false
      continue
    }
    if (options && argument === '--no-config') continue
    if (options && argument === '--sort=modified') {
      rewritten.push('--sort=path')
      continue
    }
    rewritten.push(argument)
  }
  return rewritten
}
