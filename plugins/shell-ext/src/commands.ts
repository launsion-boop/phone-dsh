// SPDX-License-Identifier: MIT
/**
 * The Worker command table: just-bash built-ins plus the phone commands.
 *
 * `createWorkerCommands` is the only place production code assembles the
 * table. Accelerator names come from the host HELLO caps, so an unadvertised
 * `rg` stays just-bash's Worker-local implementation and only an advertised one
 * crosses the channel (D12). `curl` is always the `/v1/http` shim because the
 * Worker has no sockets. `git` is the Worker's git program over the VFS (the
 * eight `workspace-changes` subcommands plus porcelain), and every program of
 * the installed WASI toolbox (`python3`, ...) is bridged to the same
 * `toolbox.run()` dispatch — all of them stay inside the Worker (D12).
 * `find` is a shim over just-bash's built-in that keeps the full POSIX `-type`
 * grammar (see `find.ts`). `stat` is a shim over just-bash's built-in `-c`
 * formatter, which echoes the directives it does not implement literally (see
 * `stat.ts`). `gzip`/`gunzip`/`zcat` are the Worker codec that resolves Web
 * Compression Streams first and a real `node:zlib` second, because the browser
 * Worker stubs the built-in's `node:zlib` gzip family (see `gzip.ts`). `cmp` is
 * the Worker's POSIX byte comparison over the VFS (see `cmp.ts`): the engine
 * had no program for the class, so `cmp -s a b` answered 127 not-available
 * (G2-D04). `cp` is the bundled copy engine behind an archive shim (see
 * `cp.ts`): `-a`/`-d` were rejected, `-p` was never consumed, and the target
 * mode is restored explicitly as a VFS chmod (G2-FIX-98).
 * `jq` is the just-bash built-in behind the input-family shim (see `jq.ts`):
 * the built-in does not implement `inputs`/`input` and stubs
 * `input_line_number` to 1 (G2-FIX-130). A filter without those bare
 * identifiers is delegated unchanged.
 * @module @phone-dsh/dsh-shell-ext/commands
 */

import type { CustomCommand } from 'just-bash'
import { getWorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'
import type { WorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'
import { NodeGitFs, createGitCommand } from '@phone-dsh/dsh-wasi-toolbox/git'
import type { GitCommandOptions } from '@phone-dsh/dsh-wasi-toolbox/git'
import { createAcceleratorCommands } from './bridge.ts'
import type { AcceleratorHost } from './bridge.ts'
import { createAwkCommand } from './awk.ts'
import { createCmpCommand } from './cmp.ts'
import { createCpCommand } from './cp.ts'
import { createDuCommand } from './du.ts'
import { GNU_CONVENTION_PROGRAMS, applyGnuConventions } from './gnu-conventions.ts'
import { createCurlCommand } from './curl.ts'
import type { CurlOptions } from './curl.ts'
import { createWhichCommand } from './corpus.ts'
import { createFindCommand } from './find.ts'
import { createGrepCommand } from './grep.ts'
import { createJqCommand } from './jq.ts'
import { createOdCommand } from './od.ts'
import { createRealpathCommand, createReadlinkCommand } from './path-commands.ts'
import { createGunzipCommand, createGzipCommand, createZcatCommand } from './gzip.ts'
import type { GzipBackendOptions } from './gzip.ts'
import { createLsCommand } from './ls.ts'
import { createRipgrepCommand } from './ripgrep.ts'
import { createRmdirCommand } from './rmdir.ts'
import { createSortCommand } from './sort.ts'
import { createStatCommand } from './stat.ts'
import { createTarCommand } from './tar.ts'
import { createToolboxCommands, toolboxCommandNames } from './toolbox-commands.ts'
import { createTrapCommand } from './trap.ts'
import { trailerCommand } from './contract.ts'

/** Inputs for the production command table. */
export interface WorkerCommandOptions {
  /** Host-advertised read-only accelerators, or undefined when none are advertised. */
  readonly accelerators?: AcceleratorHost | undefined
  /** `/v1/http` coordinates; pass `false` to omit `curl`. */
  readonly curl?: CurlOptions | false | undefined
  /** Extra names `which` should report as available. */
  readonly whichExtra?: readonly string[] | undefined
  /**
   * `git` options; `false` omits the program. The default runs on
   * `node:fs/promises` (the Worker VFS in production), rooted at
   * `PDSH_VFS_ROOT` for a desktop or test harness.
   */
  readonly git?: GitCommandOptions | false | undefined
  /**
   * WASI toolbox whose programs are bridged to shell commands. Defaults to the
   * toolbox installed with `setWorkerToolbox()` (the `python3` runtime does
   * this); `false` keeps the shell table free of toolbox programs.
   */
  readonly toolbox?: WorkerToolbox | false | undefined
  /**
   * `gzip`/`gunzip`/`zcat` backend overrides; `false` omits the family and
   * leaves just-bash's node:zlib built-ins in place. The default resolves Web
   * Compression Streams first, then a real `node:zlib`.
   */
  readonly gzip?: GzipBackendOptions | false | undefined
}

/**
 * Programs the Worker shell core always serves itself (never a host process).
 *
 * `git` is the Worker program over the VFS. `rg` is the Worker search program:
 * a shell-ext shim over just-bash's built-in that keeps ripgrep's globset
 * contract (see `ripgrep.ts`). A direct spawn of the packaged ripgrep
 * executable path (what DSH's `tool-fs-search` does) is routed to it after
 * program-identity resolution, unless the host HELLO advertises `rg` as an
 * accelerator — in that case the accelerator command overrides it (D12).
 *
 * `find` is just-bash's built-in behind the `-type` shim (see `find.ts`). A
 * direct `spawn(['find', ...])` must reach that same shell table: the runtime's
 * `node:child_process` shim would otherwise run the unshimmed built-in and
 * reject every `-type` outside `f|d`, so the `bash -c` and direct-spawn forms
 * would disagree.
 *
 * `grep` is just-bash's built-in behind the binary-file shim (see `grep.ts`):
 * `-I` / `--binary-files=without-match` — including inside a combined cluster
 * such as `-RIn` — is accepted, and a direct spawn must reach the same table.
 *
 * `stat` is just-bash's built-in behind the `-c` format shim (see `stat.ts`).
 * The built-in echoes unknown directives literally with exit 0; a direct
 * `spawn(['stat', ...])` must reach the same shim so the two forms cannot
 * disagree about a metadata query.
 *
 * `ls` is just-bash's built-in behind the long-format mode shim (see
 * `ls.ts`). The built-in's `-l` first column is a constant; a direct
 * `spawn(['ls', '-l', ...])` must reach the same metadata-backed formatter so
 * the two forms cannot disagree about a file's mode.
 *
 * `gzip`/`gunzip`/`zcat` are the Worker codec, not just-bash's built-ins: the
 * browser Worker's `node:zlib` gzip family is a refusing stub, so a direct
 * spawn must reach the Web Compression Streams backend (see `gzip.ts`).
 *
 * `rmdir` is the Worker's POSIX empty-directory removal (see `rmdir.ts`): the
 * pinned runtime's `node:fs` replacement has no `rmdir`/`rmdirSync`, so the
 * bundled command's directory-removal path dies on a raw JS TypeError. This
 * table shadows it with the same `IFileSystem` faces (and the same VFS remove
 * mutation) the rest of the Worker shell uses.
 *
 * `cmp` is the Worker's POSIX byte comparison (see `cmp.ts`): the engine has no
 * byte-comparison program at all, so before this entry the whole class answered
 * 127 not-available (G2-D04). A direct `spawn(['cmp', ...])` must reach the same
 * VFS-backed program as `bash -c 'cmp ...'`.
 *
 * `cp` is the bundled copy engine plus the archive/preserve shim (see
 * `cp.ts`). The shim accepts `-a`/`-p`/`-d`/`--preserve`, delegates the copy
 * itself and publishes the preserved mode as an explicit VFS chmod (0x10 op 4)
 * instead of relying on `node:fs.cp` copying it by accident (G2-FIX-98). A
 * direct `spawn(['cp', ...])` must reach the same table.
 *
 * `od` is a window-sized shim over the built-in (see `od.ts`): the built-in
 * parses `-N` but formats the whole operand, so `od -An -tx1 -N4 big` over a
 * legal large file exhausts the format-work budget instead of printing four
 * bytes. The shim applies `-N`/`-j` before formatting, and a direct
 * `spawn(['od', ...])` must reach the same table.
 *
 * `jq` is just-bash's built-in behind the input-family shim (see `jq.ts`): a
 * direct `spawn(['jq', ...])` must reach the shim so `inputs`, `input` and
 * `input_line_number` cannot disagree with the `bash -c` form (G2-FIX-130).
 */
export const WORKER_SHELL_PROGRAMS: readonly string[] = Object.freeze([
  'git', 'rg', 'find', 'grep', 'stat', 'ls', 'rmdir', 'gzip', 'gunzip', 'zcat',
  'tar', 'realpath', 'readlink', 'awk', 'cmp', 'cp', 'sort', 'du', 'od', 'jq',
])

/**
 * True when the Worker shell — not the host process layer — serves this
 * program. `subprocess-xl` uses it to route a direct `spawn(['git', ...])` or
 * a path-resolved `rg` through the same table `bash -c` uses (D12).
 * @param program - the resolved program identity (argv[0] after identity
 *   resolution; `git`, `rg`, or a toolbox program name).
 * @returns true for the Worker programs above and every installed toolbox
 *   program.
 */
export function isWorkerShellProgram(program: string): boolean {
  if (WORKER_SHELL_PROGRAMS.includes(program)) return true
  if (GNU_CONVENTION_PROGRAMS.includes(program)) return true
  const toolbox = getWorkerToolbox()
  if (toolbox === undefined) return false
  if (toolbox.has(program)) return true
  // A toolbox alias the Worker declares at registration (`python` ->
  // `python3`) names the same program even when the toolbox itself only
  // lists the canonical name.
  return toolbox.list().some(summary => toolboxCommandNames(summary).includes(program))
}

/**
 * Resolve an absolute program path to the Worker shell identity it names.
 *
 * The shell's `command -v` answers with a materialised path (`/usr/bin/tar`)
 * and a caller may pass that path straight back to a spawn. The Worker serves
 * the program by name, so a path whose basename is one of the
 * {@link WORKER_SHELL_PROGRAMS} (or an installed toolbox program) becomes that
 * bare identity; every other path is returned unchanged and keeps failing
 * loud when no program exists.
 * @param program - argv[0] after confinement-marker stripping.
 * @returns the bare Worker program name, or the path unchanged.
 */
export function workerShellIdentity(program: string): string {
  if (!program.startsWith('/')) return program
  const separator = program.lastIndexOf('/')
  const base = program.slice(separator + 1)
  // `bash`/`sh` are the shell core's own registered commands (shell.ts adds
  // them from interpreter.ts), not entries in WORKER_SHELL_PROGRAMS; their
  // materialised paths still name the same core.
  if (base === 'bash' || base === 'sh') return base
  return isWorkerShellProgram(base) ? base : program
}

/**
 * Build the commands registered next to just-bash's built-ins.
 * @param options - accelerator dispatcher, curl options, git, gzip and toolbox.
 * @returns the custom command table.
 */
export function createWorkerCommands(options: WorkerCommandOptions = {}): CustomCommand[] {
  const acceleratorNames = options.accelerators?.names ?? []
  // Resolve the toolbox exactly once. The jq command receives this resolved
  // binding (including an explicit `false`) so it cannot quietly dispatch
  // through a different Worker's global `__PDSH_WASI_TOOLBOX__`.
  const toolbox = options.toolbox === false ? false : options.toolbox ?? getWorkerToolbox()
  const commands: CustomCommand[] = [
    createFindCommand(),
    createGrepCommand(),
    createStatCommand(),
    createLsCommand(),
    createRmdirCommand(),
    createAwkCommand(),
    createRealpathCommand(),
    createReadlinkCommand(),
    createCmpCommand(),
    createJqCommand(toolbox),
    createCpCommand(),
    createSortCommand(),
    createDuCommand(),
    createOdCommand(),
    createTrapCommand(),
  ]
  // `tar -z` shares the portable codec with gzip/gunzip/zcat (see gzip.ts);
  // `gzip: false` only omits the three standalone commands.
  commands.push(createTarCommand(options.gzip === false ? {} : options.gzip ?? {}))
  // The browser Worker's node:zlib gzip family refuses; the Worker codec owns
  // the family so gzip/gunzip/zcat cannot report an empty success (gzip.ts).
  if (options.gzip !== false) {
    commands.push(
      createGzipCommand(options.gzip ?? {}),
      createGunzipCommand(options.gzip ?? {}),
      createZcatCommand(options.gzip ?? {}),
    )
  }
  // An advertised `rg` is the host accelerator and overrides the Worker-local
  // program; without one the Worker `rg` must keep the ripgrep/globset
  // contract the DSH search tools rely on (see ripgrep.ts).
  if (!acceleratorNames.includes('rg')) commands.push(createRipgrepCommand())
  const installedToolbox = toolbox === false ? undefined : toolbox
  if (installedToolbox !== undefined) commands.push(...createToolboxCommands(installedToolbox))
  if (options.git !== false) {
    commands.push(trailerCommand(createGitCommand(options.git ?? { fs: new NodeGitFs(process.env.PDSH_VFS_ROOT ?? '') }), 'git'))
  }
  if (options.accelerators !== undefined && options.accelerators.names.length > 0) {
    commands.push(...createAcceleratorCommands(options.accelerators))
  }
  if (options.curl !== false) commands.push(createCurlCommand(options.curl ?? {}))
  const names = [
    ...options.accelerators?.names ?? [],
    ...installedToolbox?.list().flatMap(command => toolboxCommandNames(command)) ?? [],
    ...options.git === false ? [] : ['git'],
    ...options.gzip === false ? [] : ['gzip', 'gunzip', 'zcat'],
    'tar', 'realpath', 'readlink', 'awk', 'cmp', 'cp', 'od', 'rmdir', 'ls', 'jq',
    ...options.whichExtra ?? [],
    ...options.curl === false ? [] : ['curl'],
  ]
  commands.push(createWhichCommand(names))
  return applyGnuConventions(commands)
}
