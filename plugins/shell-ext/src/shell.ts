// SPDX-License-Identifier: MIT
/**
 * The Worker's bash core: just-bash over the VFS adapter, with the output
 * discipline, a per-command wall-clock limit and cooperative cancellation.
 *
 * `subprocess-xl` calls this module for `bash -c` when `PDSH_SHELL` is
 * `just-bash` (the default). It is deliberately one shell instance per command:
 * a DSH `bash -c` step is a fresh shell, and a cancelled or timed-out script
 * must not leave variables, functions or open descriptors for the next step.
 * @module @phone-dsh/dsh-shell-ext/shell
 */

import { posix } from 'node:path'
import { Bash, defineCommand, getCommandNames } from 'just-bash/browser'
import type { CommandName, CustomCommand, ExecOptions, IFileSystem } from 'just-bash/browser'
import type { TransformContext, TransformPlugin, TransformResult } from 'just-bash'
import { MAX_FILE_SIZE, formatByteLimit, formatByteLimitMib } from '../../wasi-toolbox/src/limits.ts'
import { createArithmeticBaseCommand, createArithmeticExpansionPlugin } from './arithmetic.ts'
import { createBashSourcePlugin } from './bash-source.ts'
import { materializeCapabilityManifest } from './capabilities.ts'
import { materializeCommandPaths, sanitizeCommandPath } from './command-paths.ts'
import { decodeByteString } from './encoding.ts'
import {
  appendShellTrailer,
  extractFailureProgram,
  notAvailableTrailer,
  shellFailure,
  truncationAnnotation,
} from './contract.ts'
import { VfsFileSystem } from './filesystem.ts'
import { createFindCommand } from './find.ts'
import { createGrepCommand } from './grep.ts'
import { createJqCommand } from './jq.ts'
import { applyGnuConventions } from './gnu-conventions.ts'
import { createDuCommand } from './du.ts'
import { createOdCommand } from './od.ts'
import {
  MAX_SHELL_NESTING,
  createShellInterpreterCommands,
  isShellInvocation,
  parseShellInvocation,
  positionalEnvironment,
  shellOptionPrelude,
  shellUsage,
  shellVersion,
} from './interpreter.ts'
import type { ShellOptions, ShellPlan, ShellPositional, ShellProgram } from './interpreter.ts'
import { createReadDecodeCommand, createReadDecodePlugin } from './read-encoding.ts'
import { createRipgrepCommand } from './ripgrep.ts'
import { createRmdirCommand } from './rmdir.ts'
import { createSortCommand } from './sort.ts'
import { createStatCommand } from './stat.ts'
import {
  TERMINAL_SEED_SYMBOL,
  TERMINAL_STATE_SYMBOL,
  readTerminalState,
  terminalHandlerEligible,
  terminalSnapshotFromResult,
} from './terminal.ts'
import type { TerminalSeed } from './terminal.ts'
import { createLsCommand } from './ls.ts'
import { boundOutput, maxOutputBytesFromEnv, mergeOutputAccounting, readOutputAccounting } from './output.ts'
import type { OutputAccounting } from './output.ts'
import { TOOLBOX_OUTPUT_LIMIT } from './toolbox-commands.ts'
import type { ToolboxOutputLimit } from './toolbox-commands.ts'
import { WORKER_EXECUTION_LIMITS, workerExecutionLimitsSentence } from './execution-limits.ts'
import {
  TRAP_EXIT_SIGNAL,
  clearTrapState,
  createTrapCommand,
  createTrapToken,
  getTrapHandler,
  isDefaultTrapCommand,
} from './trap.ts'

/** Supported shell-core selections (`PDSH_SHELL`). */
export type ShellMode = 'just-bash' | 'runtime'

/** Environment variables forced for every Worker command (PLAN W5 output discipline). */
export const SHELL_DISCIPLINE_ENV: Readonly<Record<string, string>> = {
  TERM: 'dumb',
  NO_COLOR: '1',
  LANG: 'C.UTF-8',
  LC_ALL: 'C.UTF-8',
  PAGER: 'cat',
  GIT_PAGER: 'cat',
  CLICOLOR: '0',
  FORCE_COLOR: '0',
}

/** Default per-command wall-clock limit (120 s). */
export const DEFAULT_TIMEOUT_MS = 120_000

/**
 * Default time a `stdin: 'pipe'` caller has to close its stream (30 s).
 *
 * The Worker shell cannot start a command that is still waiting for its
 * standard input without guessing how much of it belongs to the command, so a
 * pipe that never reaches EOF would hold the execution lane forever. This
 * bound turns that into a structured failure once the grace expires.
 */
export const DEFAULT_STDIN_EOF_TIMEOUT_MS = 30_000

/**
 * The interpreter's `maxOutputSize` is a memory bound on one command result,
 * not the user-visible per-stream cap. A pipeline stage may carry a legal
 * file's bytes into the next stage (`cat big | wc -c`), so the engine bound
 * must leave room for one whole file (`MAX_FILE_SIZE`, 64 MiB by default) plus
 * the caller's stream cap. The final stdout/stderr discipline is applied below
 * by {@link boundOutput}; a command that actually emits more than
 * `maxOutputBytes` still exits 1 with `reason=output-truncated`.
 */
function pipelineOutputBudget(maxBytes: number): number {
  return Math.max(maxBytes * 4, MAX_FILE_SIZE + maxBytes)
}

/**
 * The single-file budget a filesystem enforces, when it publishes one.
 *
 * `VfsFileSystem.maxFileSize` is the exact value its write checks use. Shell
 * backends that answer no budget fall back to the configured owner default, so
 * a `limit-refused` hint never carries a literal from another era.
 * @param fs - the shell's filesystem.
 * @returns the active byte budget, or undefined when the backend has none.
 */
function fileSizeBudget(fs: IFileSystem | undefined): number | undefined {
  const value = (fs as { readonly maxFileSize?: unknown } | undefined)?.maxFileSize
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined
}

/**
 * The one-line budget label for a `limit-refused` trailer: the MiB spelling
 * when the bound is a whole MiB, the exact byte count otherwise.
 * @param limit - active single-file budget in bytes.
 * @returns the human-readable budget.
 */
function budgetLabel(limit: number): string {
  return formatByteLimitMib(limit) ?? formatByteLimit(limit)
}

/**
 * The program a just-bash execution-ceiling message names, or undefined when
 * the text is not an execution-ceiling failure.
 *
 * just-bash 3.6 reports three shapes, all with a non-zero status:
 * - `bash: too many commands executed (>N), increase executionLimits.maxCommandCount`
 * - `bash: for loop: too many iterations (N), increase executionLimits.maxLoopIterations`
 *   (also `while` and `until`)
 * - `bash: seq: iteration limit exceeded (N)` (also awk, sed and the other
 *   streaming built-ins)
 *
 * The command-count shape carries no program field, so `fallback` (the invoked
 * program) or `bash` names the ceiling. The loop shape names `for`/`while`/
 * `until`; the built-in shape names its own program. Every shape is the same
 * class to the model: an execution ceiling reached (`reason=iterations`).
 * @param stderr - the engine's stderr.
 * @param fallback - program to use when the message names none.
 * @returns the bare program name, or undefined when this is not a ceiling.
 */
export function executionLimitProgram(stderr: string, fallback?: string): string | undefined {
  if (/too many commands executed/iu.test(stderr)) return fallback === undefined ? 'bash' : fallback
  const loop = /^bash: (for|while|until) loop: .*(?:too many iterations|iteration limit exceeded|maximum iterations)/imu.exec(stderr)?.[1]
  if (loop !== undefined) return loop
  const named = /^bash: ([A-Za-z0-9._+-]+): .*(?:too many iterations|iteration limit exceeded|maximum iterations)/imu.exec(stderr)?.[1]
  if (named !== undefined) return named
  // awk reports its own ceiling without the `bash:` prefix
  // (`awk: awk: for loop exceeded maximum iterations (N)`), so the phrase is
  // the durable signal and the leading `program:` word names it.
  if (/(?:too many iterations|iteration limit exceeded|maximum iterations)/iu.test(stderr)) {
    return /^([A-Za-z0-9._+-]+): /mu.exec(stderr)?.[1] ?? fallback
  }
  return undefined
}

/** Parse `PDSH_SHELL`; anything but `runtime` means just-bash. */
export function resolveShellMode(env: Readonly<Record<string, string | undefined>> = process.env): ShellMode {
  const raw = env.PDSH_SHELL
  if (raw === undefined || raw === '' || raw === 'just-bash') return 'just-bash'
  if (raw === 'runtime') return 'runtime'
  throw new Error(`PDSH_SHELL must be 'just-bash' or 'runtime', got ${JSON.stringify(raw)}`)
}

/** Where one command runs and what limits apply. */
export interface ShellRunOptions {
  /** Absolute virtual working directory. */
  readonly cwd: string
  /** Base environment; discipline variables are forced on top. */
  readonly env?: Readonly<Record<string, string | undefined>> | undefined
  /** Standard input text (bytes are decoded as UTF-8 by the shell). */
  readonly stdin?: string | undefined
  /**
   * Shape of {@link stdin}: `text` (default, UTF-8) or `bytes` (the shell's
   * latin1-shaped byte string). The nested `bash`/`sh` command forwards its
   * inherited stdin with `bytes` so a piped `bash script.sh` sees the exact
   * bytes a `bash -c` step would.
   */
  readonly stdinKind?: 'text' | 'bytes' | undefined
  readonly signal?: AbortSignal | undefined
  /** Wall-clock limit; defaults to `PDSH_SHELL_TIMEOUT_MS` or {@link DEFAULT_TIMEOUT_MS}. */
  readonly timeoutMs?: number | undefined
  /** Per-stream byte cap; defaults to `PDSH_SHELL_MAX_OUTPUT_BYTES` or 256 KiB. */
  readonly maxOutputBytes?: number | undefined
}

/** Result of one Worker command. */
export interface ShellResult {
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
  readonly timedOut: boolean
  readonly aborted: boolean
  readonly stdoutTruncated: boolean
  readonly stderrTruncated: boolean
  /** Bytes the command produced before the visible cap (including nested producers). */
  readonly stdoutOriginalBytes?: number | undefined
  /** Bytes stderr produced before the visible cap (including nested producers). */
  readonly stderrOriginalBytes?: number | undefined
  /**
   * Producer-owned truncation facts forwarded from nested shells/WASI programs.
   * Not user-visible: it lets an outer shell account a nested producer's real
   * dropped bytes without parsing marker-looking text.
   */
  readonly outputAccounting?: OutputAccounting | undefined
  /** Program name when a direct invocation hit just-bash's `command not found`. */
  readonly missingProgram?: string | undefined
}

/** Construction inputs for {@link WorkerShell}. */
export interface WorkerShellOptions {
  /**
   * Filesystem backend; defaults to `VfsFileSystem({root: PDSH_VFS_ROOT ?? '/'})`.
   * The Worker's virtual root (`PDSH_VFS_ROOT` unset) enables the adapter's
   * documented `/tmp` -> `/dsh/tmp` alias; a real-directory root is verbatim.
   */
  readonly fs?: IFileSystem | undefined
  /** Commands registered alongside just-bash's built-ins. */
  readonly commands?: readonly CustomCommand[] | undefined
  /**
   * Programs this shell must not advertise or execute. The name is removed
   * from just-bash's built-in set, every default shadow and the synthetic
   * PATH/capability list, so `command -v`, `type` and `which` agree that the
   * program is unavailable. A fork uses this for `jq`, whose baseline
   * implementation consults the live published toolbox.
   */
  readonly disabledCommands?: readonly string[] | undefined
  /** Default per-stream cap. */
  readonly maxOutputBytes?: number | undefined
  /** Default wall-clock limit. */
  readonly timeoutMs?: number | undefined
}

/** Combine an environment with the mandatory discipline variables. */
export function disciplineEnvironment(
  env: Readonly<Record<string, string | undefined>> | undefined,
  cwd: string,
): Record<string, string> {
  const merged: Record<string, string> = {}
  for (const [key, value] of Object.entries(env ?? {})) if (value !== undefined) merged[key] = value
  Object.assign(merged, SHELL_DISCIPLINE_ENV)
  merged.HOME ??= '/dsh/home'
  merged.TMPDIR ??= '/dsh/tmp'
  merged.PATH ??= '/usr/bin:/bin'
  merged.PWD = cwd
  return merged
}

/** Quote one word for a bash command line. */
export function shellQuote(word: string): string {
  return `'${word.replace(/'/g, `'\\''`)}'`
}

/**
 * True when argv names a bash/sh invocation, including absolute path spellings
 * (`/bin/bash`, `/usr/bin/bash`, the materialised `/usr/bin/bash` entry that
 * `command -v bash` answers). The pattern is the program identity, not a
 * caller: the Worker shell serves the same core for every spelling.
 */
export { isShellInvocation } from './interpreter.ts'

/** Extract the `-c` script from a bash/sh argv, if present. */
export function commandScript(argv: readonly string[]): string | undefined {
  if (!isShellInvocation(argv)) return undefined
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index] as string
    if (argument === '-c') return argv[index + 1] ?? ''
    if (argument.startsWith('-') && argument.includes('c') && !argument.startsWith('--')) {
      // Combined flags such as `-lc`: the next argument is the script.
      return argv[index + 1] ?? ''
    }
  }
  return undefined
}

/** Content just-bash writes for a materialised command entry (`command-paths.ts`). */
const COMMAND_ENTRY = /^#!\/bin\/bash\n# Built-in command: [A-Za-z0-9_+.-]+\n?$/u

/** Interpreter basenames that make an executable file a bash script. */
const SHELL_INTERPRETERS: ReadonlySet<string> = new Set(['bash', 'sh', 'dash', 'ksh', 'zsh'])

/**
 * True when a file's `#!` line names a shell (or the file has no `#!` line).
 *
 * A bare text file without a shebang is what the kernel hands to the shell
 * (`ENOEXEC`), and the engine already executes it as bash; every other
 * interpreter keeps the engine's existing path so this shim only widens the
 * set of scripts that reach the composed shell.
 * @param source - file contents.
 * @returns whether the file is a shell script.
 */
function isShellScript(source: string): boolean {
  const shebang = /^#!([^\n]*)/u.exec(source)?.[1]
  if (shebang === undefined) return true
  const words = shebang.trim().split(/\s+/u)
  let interpreter = words[0] ?? ''
  if (interpreter.endsWith('/env')) {
    // `/usr/bin/env [-S] bash ...`
    const index = words[1] === '-S' ? 2 : 1
    interpreter = words[index] ?? ''
  }
  return SHELL_INTERPRETERS.has(interpreter.slice(interpreter.lastIndexOf('/') + 1))
}

/** The three states of a path-form argv that decide the dispatch. */
type ScriptFile =
  | { readonly kind: 'script'; readonly source: string }
  | { readonly kind: 'missing' }
  | { readonly kind: 'other' }

/**
 * Read one source file as text through the shared byte boundary.
 *
 * A script is bytes on disk; the interpreter needs text. The read goes through
 * the backend's raw-byte face when it has one and is decoded as UTF-8 exactly
 * once here, so the same bytes that `cat script.sh` shows are the ones the
 * parser sees (G2-FIX-43). A backend written before `readFileBytes` existed
 * keeps its own text read.
 * @param fs - Worker filesystem.
 * @param path - virtual path to read.
 * @returns the script source text.
 */
async function readSourceText(fs: IFileSystem, path: string): Promise<string> {
  if (typeof fs.readFileBytes === 'function') {
    return decodeByteString(await fs.readFileBytes(path) as unknown as string)
  }
  return await fs.readFile(path)
}

/**
 * Read the shell script `program` names, when it is an executable file.
 *
 * This is the script-file dispatch entry: a `./script.sh` argv names a VFS
 * file, not a registered program, and the engine's bare path executor does not
 * carry the composed shell's transform plugins or command table. Returning the
 * source lets {@link WorkerShell.execute} run it through the same interpreter
 * as `bash -c` and `bash script.sh`.
 *
 * `missing` lets the caller report a spawn-shaped `ENOENT` (the engine's path
 * executor would otherwise return its own 127 as an ordinary command result).
 * @param fs - Worker filesystem.
 * @param cwd - current working directory.
 * @param program - argv[0] as the caller wrote it.
 * @returns the script source, or a state that keeps the engine's own handling.
 */
async function shellScriptFile(
  fs: IFileSystem,
  cwd: string,
  program: string,
): Promise<ScriptFile> {
  // Only a path names a file. A bare name stays a PATH lookup (`bash` and
  // friends are intercepted above; a bare `script.sh` is command-not-found in
  // bash too).
  if (!program.includes('/')) return { kind: 'other' }
  const path = posix.resolve(cwd, program)
  let file
  try {
    file = await fs.stat(path)
  } catch {
    return { kind: 'missing' }
  }
  if (!file.isFile || (file.mode & 0o111) === 0) return { kind: 'other' }
  let source: string
  try {
    source = await readSourceText(fs, path)
  } catch {
    return { kind: 'other' }
  }
  // A materialised command entry is just-bash's own executable alias for a
  // registered command; executing its text as a script would turn, say,
  // `"$(command -v tar)" -xzf a.tar.gz` into a no-op.
  if (COMMAND_ENTRY.test(source) || source.includes('\0') || !isShellScript(source)) {
    return { kind: 'other' }
  }
  return { kind: 'script', source }
}

/**
 * Parse the per-command wall-clock limit from the environment.
 *
 * `subprocess-xl` reads the same value for the job deadline it registers
 * before dispatch, so the account of a command and the shell's own timer agree
 * on the Worker's command budget instead of one bounding the other.
 * @param env - environment to read `PDSH_SHELL_TIMEOUT_MS` from.
 * @returns the positive millisecond limit, or {@link DEFAULT_TIMEOUT_MS}.
 */
export function shellTimeoutFromEnv(env: Readonly<Record<string, string | undefined>>): number {
  const raw = env.PDSH_SHELL_TIMEOUT_MS
  if (raw === undefined || raw.trim() === '') return DEFAULT_TIMEOUT_MS
  const parsed = Number(raw)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`PDSH_SHELL_TIMEOUT_MS must be a positive number of milliseconds, got ${JSON.stringify(raw)}`)
  }
  return Math.floor(parsed)
}

/**
 * Parse the piped-stdin EOF grace from the environment.
 * @param env - environment to read `PDSH_SHELL_STDIN_TIMEOUT_MS` from.
 * @returns the positive millisecond bound, or
 *   {@link DEFAULT_STDIN_EOF_TIMEOUT_MS}.
 */
export function stdinEofTimeoutFromEnv(env: Readonly<Record<string, string | undefined>> = process.env): number {
  const raw = env.PDSH_SHELL_STDIN_TIMEOUT_MS
  if (raw === undefined || raw.trim() === '') return DEFAULT_STDIN_EOF_TIMEOUT_MS
  const parsed = Number(raw)
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(
      `PDSH_SHELL_STDIN_TIMEOUT_MS must be a positive number of milliseconds, got ${JSON.stringify(raw)}`,
    )
  }
  return Math.floor(parsed)
}

/** Why the shell controller fired: the caller cancelled or the wall clock expired. */
type InterruptionCause = 'abort' | 'timeout' | undefined

/**
 * Result for a controller interruption, decided by the cause that arrived
 * first rather than by whichever engine promise happened to settle last.
 *
 * just-bash reports both a caller abort and its own deadline as status 124
 * (`throwIfAborted` raises the deadline error), so the engine's status alone
 * cannot tell the two apart. Recording the first cause keeps cancellation a
 * deterministic 130/`aborted` and a wall-clock cut a deterministic 124.
 * @param cause - the first interruption cause observed, if any.
 * @returns the shell result for that cause.
 */
function interruptionResult(cause: InterruptionCause): ShellResult {
  return interruptedResult(cause !== 'timeout', cause === 'timeout')
}

/** An empty result for an abort/timeout that won the race. */
function interruptedResult(aborted: boolean, timedOut: boolean): ShellResult {
  return {
    stdout: '',
    stderr: aborted
      ? 'pdsh-shell: command cancelled\n'
      : timedOut ? 'pdsh-shell: command exceeded its wall-clock limit\n' : '',
    exitCode: aborted ? 130 : 124,
    timedOut,
    aborted,
    stdoutTruncated: false,
    stderrTruncated: false,
  }
}

/** A completed result with no interruption and no truncation. */
function plainResult(stdout: string, stderr: string, exitCode: number): ShellResult {
  return { stdout, stderr, exitCode, timedOut: false, aborted: false, stdoutTruncated: false, stderrTruncated: false }
}

/**
 * Filesystem methods that can change the workspace.
 *
 * The EXIT handler is another `bash.exec` on the same command's wall clock and
 * abort signal. The engine is cooperative, so an abort can return the command
 * result while a command the handler already started is still unwinding. These
 * methods are gated on that signal: once a deadline or caller abort has fired,
 * a later handler write fails instead of mutating the workspace after the
 * command was reported as 124/130. Reads stay available, so a handler that was
 * only inspecting state can still finish its own unwind.
 */
const ABORT_GATED_WRITE_METHODS: ReadonlySet<string> = new Set([
  'writeFile',
  'appendFile',
  'createExclusive',
  'mkdir',
  'rm',
  'cp',
  'mv',
  'chmod',
  'symlink',
  'link',
  'utimes',
])

/** The internal error a post-abort filesystem write gets; never surfaces as a result. */
function abortedWriteError(): Error {
  const error = new Error('pdsh-shell: command interrupted before the filesystem write')
  error.name = 'AbortError'
  return Object.assign(error, { code: 'ABORT_ERR' })
}

/**
 * Hard bound on waiting for an in-flight handler write to settle.
 *
 * The underlying `node:fs` primitive is not cancellable. Waiting forever would
 * let one non-settling write hold the command past its wall-clock/abort budget,
 * so an interrupted execution waits at most this long for the write (and its
 * rollback), then returns 124/130. A write that settles later is still rolled
 * back by the tracked mutation; the command does not wait for it.
 */
const INTERRUPTION_ROLLBACK_BUDGET_MS = 400

/**
 * Hard bound on removing the source/eval staging file after an interruption.
 *
 * Cleanup is an ordinary backend mutation and therefore can itself be slow or
 * stuck. It runs under the same interruption controller as the rollback but
 * must not extend the command's budget without limit.
 */
const INTERRUPTION_CLEANUP_BUDGET_MS = 200

/**
 * Wait for `work` for at most `budgetMs`.
 *
 * Rejections count as settled: callers only need to know whether waiting is
 * safe to stop, not whether the underlying operation succeeded. The losing
 * promise keeps running (and the caller can attach follow-up work to it); the
 * timer is cleared on every winner so a completed operation leaves no handle.
 * @param work - operation to await.
 * @param budgetMs - maximum wait in milliseconds.
 * @returns true when `work` settled first, false on the deadline.
 */
async function settlesWithin(work: Promise<unknown>, budgetMs: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const deadline = new Promise<false>((resolve) => {
    // Keep this handle referenced: the bounded wait is what lets the command
    // return even when the only other pending work is a non-settling backend
    // promise (which alone would leave the event loop empty).
    timer = setTimeout(() => { resolve(false) }, budgetMs)
  })
  try {
    return await Promise.race([
      work.then(() => true, () => true),
      deadline,
    ])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

/** One undo action for a mutation the EXIT handler already started. */
interface MutationUndo {
  /** False means a snapshot restoration step failed and state is unknown. */
  restore(): Promise<boolean>
}

/** An operation whose prior state could not be read is not safely reversible. */
function unknownStateUndo(): MutationUndo {
  return { async restore(): Promise<boolean> { return false } }
}

/** Whether `lstat` proves that a path was absent rather than unreadable. */
function isMissingPathError(error: unknown): boolean {
  if (typeof error !== 'object' || error === null || !('code' in error)) return false
  const code = (error as { code?: unknown }).code
  return code === 'ENOENT' || code === 'ENOTDIR'
}

/** Missing-path undo: the handler created this entry after the snapshot. */
function missingPathUndo(fs: IFileSystem, path: string): MutationUndo {
  return {
    async restore(): Promise<boolean> {
      try {
        await fs.rm(path, { recursive: true, force: true })
        return true
      } catch {
        return false
      }
    },
  }
}

/** Snapshot one existing path (file, directory tree or symlink) for rollback. */
async function capturePathUndo(fs: IFileSystem, path: string): Promise<MutationUndo> {
  let stat: Awaited<ReturnType<IFileSystem['lstat']>>
  try {
    stat = await fs.lstat(path)
  } catch (error) {
    return isMissingPathError(error) ? missingPathUndo(fs, path) : unknownStateUndo()
  }
  if (stat.isDirectory) {
    let names: string[]
    try { names = await fs.readdir(path) } catch { return unknownStateUndo() }
    const children: MutationUndo[] = []
    for (const name of names) {
      children.push(...await capturePathAndMissing(fs, posix.join(path, name)))
    }
    const mode = stat.mode
    return {
      async restore(): Promise<boolean> {
        let restored = true
        try { await fs.rm(path, { recursive: true, force: true }) } catch { restored = false }
        try { await fs.mkdir(path, { recursive: true }) } catch { restored = false }
        for (const child of children) {
          if (!await child.restore().catch(() => false)) restored = false
        }
        try { await fs.chmod(path, mode) } catch { restored = false }
        return restored
      },
    }
  }
  if (stat.isSymbolicLink) {
    const target = await fs.readlink(path).catch(() => undefined)
    if (target === undefined) return { async restore(): Promise<boolean> { return false } }
    return {
      async restore(): Promise<boolean> {
        let restored = true
        try { await fs.rm(path, { recursive: true, force: true }) } catch { restored = false }
        try { await fs.symlink(target, path) } catch { restored = false }
        return restored
      },
    }
  }
  if (!stat.isFile) return { async restore(): Promise<boolean> { return true } }
  const content = await fs.readFileBuffer(path).catch(() => undefined)
  if (content === undefined) return { async restore(): Promise<boolean> { return false } }
  const mode = stat.mode
  const mtime = stat.mtime
  return {
    async restore(): Promise<boolean> {
      let restored = true
      try { await fs.writeFile(path, content) } catch { restored = false }
      try { await fs.chmod(path, mode) } catch { restored = false }
      if (mtime instanceof Date) {
        try { await fs.utimes(path, mtime, mtime) } catch { restored = false }
      }
      return restored
    },
  }
}

/**
 * Snapshot a target plus every still-missing ancestor.
 *
 * `mkdir -p a/b/c` and a copy into a new tree create ancestors too; undoing
 * only the leaf would leave empty directories behind. The returned actions are
 * in deepest-first order, which is also a safe removal order.
 */
async function capturePathAndMissing(fs: IFileSystem, path: string): Promise<MutationUndo[]> {
  // The target itself existing needs a real snapshot; a missing target needs
  // only the missing ancestor chain that a recursive create may add. Never
  // snapshot an existing ancestor: that would copy an entire workspace subtree
  // just because the handler created one child below it.
  try {
    await fs.lstat(path)
    return [await capturePathUndo(fs, path)]
  } catch (error) {
    if (!isMissingPathError(error)) return [unknownStateUndo()]
    // Fall through to the missing-ancestor walk.
  }
  const actions: MutationUndo[] = []
  let current = path
  while (current !== '/' && current !== '.') {
    try {
      await fs.lstat(current)
      break
    } catch (error) {
      if (!isMissingPathError(error)) {
        actions.push(unknownStateUndo())
        break
      }
      actions.push(missingPathUndo(fs, current))
      const parent = posix.dirname(current)
      if (parent === current) break
      current = parent
    }
  }
  return actions
}

/** Targets one mutating method touched, for snapshot/rollback. */
async function undoForMutation(fs: IFileSystem, method: string, args: readonly unknown[]): Promise<MutationUndo[]> {
  const path = (index: number): string | undefined => typeof args[index] === 'string' ? args[index] as string : undefined
  switch (method) {
    case 'writeFile':
    case 'appendFile':
    case 'createExclusive':
    case 'rm':
    case 'chmod':
    case 'utimes':
      return path(0) === undefined ? [] : capturePathAndMissing(fs, path(0) as string)
    case 'mkdir':
      return path(0) === undefined ? [] : capturePathAndMissing(fs, path(0) as string)
    case 'symlink':
    case 'link':
      return path(1) === undefined ? [] : capturePathAndMissing(fs, path(1) as string)
    case 'cp':
      return path(1) === undefined ? [] : capturePathAndMissing(fs, path(1) as string)
    case 'mv': {
      const actions: MutationUndo[] = []
      if (path(0) !== undefined) actions.push(...await capturePathAndMissing(fs, path(0) as string))
      if (path(1) !== undefined) actions.push(...await capturePathAndMissing(fs, path(1) as string))
      return actions
    }
    default:
      return []
  }
}

/** A filesystem plus the lifecycle of a handler's mutations. */
interface GuardedFileSystem {
  /** The proxy handed to just-bash for the whole execution. */
  readonly fs: IFileSystem
  /** Turn on per-mutation snapshots before the EXIT handler starts. */
  beginHandler(): void
  /** Wait for in-flight mutations and report whether every rollback succeeded. */
  settle(): Promise<boolean>
}

/**
 * Wrap a filesystem so a timeout/abort cannot keep mutating the workspace.
 *
 * Before the handler starts the wrapper only refuses a mutation whose signal is
 * already aborted. For the handler it also snapshots the target before the
 * write. If the signal fires while that write is in flight, the wrapper waits
 * for the underlying node:fs promise within the declared cleanup grace and
 * attempts to restore the snapshot. A non-settling write or failed restore is
 * reported as backend-failed; a late rollback continues in the background.
 * Reads stay ungated so the engine can unwind.
 * @param fs - the command filesystem.
 * @param signal - this execution's abort signal.
 * @returns the gated filesystem and its handler lifecycle.
 */
function guardedFileSystem(fs: IFileSystem, signal: AbortSignal): GuardedFileSystem {
  let handlerMode = false
  let rollbackSucceeded = true
  const pending = new Set<Promise<unknown>>()
  const mutate = async (method: string, args: readonly unknown[]): Promise<unknown> => {
    if (signal.aborted) throw abortedWriteError()
    let undo: MutationUndo[] = []
    if (handlerMode) {
      undo = await undoForMutation(fs, method, args)
      if (signal.aborted) throw abortedWriteError()
    }
    const operation = (async (): Promise<unknown> =>
      await (Reflect.get(fs, method) as (...callArgs: unknown[]) => Promise<unknown>).apply(fs, [...args]))()
    const tracked = (async (): Promise<unknown> => {
      try {
        return await operation
      } finally {
        if (undo.length > 0 && signal.aborted) {
          for (const action of undo) {
            if (!await action.restore().catch(() => false)) rollbackSucceeded = false
          }
        }
      }
    })()
    pending.add(tracked)
    try {
      return await tracked
    } finally {
      pending.delete(tracked)
    }
  }
  const proxy = new Proxy(fs, {
    get(target, property) {
      const value = Reflect.get(target, property, target) as unknown
      if (typeof value !== 'function') return value
      const bound = (value as (...args: unknown[]) => unknown).bind(target)
      if (typeof property === 'string' && ABORT_GATED_WRITE_METHODS.has(property)) {
        return async (...args: unknown[]): Promise<unknown> => await mutate(property, args)
      }
      return bound
    },
  })
  return {
    fs: proxy,
    beginHandler(): void { handlerMode = true },
    async settle(): Promise<boolean> {
      while (pending.size > 0) {
        await Promise.allSettled([...pending])
      }
      return rollbackSucceeded
    },
  }
}

/** Minimal AST node shape this transform edits. */
interface ExitAstNode {
  type: string
  [key: string]: unknown
}

/**
 * Wrap one background pipeline in a subshell.
 *
 * just-bash 3.6 parses `&` but executes the statement synchronously in the
 * current shell, so an `exit` in a background function propagated and ended
 * the whole script. Bash runs every background job in a subshell; making that
 * explicit in the AST keeps the `exit` local and lets the main script continue.
 * The engine still has no asynchronous job control, but the observable status
 * and final cwd/env now belong to the main shell rather than the job.
 * @param pipeline - the original background pipeline.
 * @returns a subshell node around that pipeline.
 */
function backgroundSubshell(pipeline: ExitAstNode): ExitAstNode {
  return {
    type: 'Pipeline',
    commands: [{
      type: 'Subshell',
      body: [{
        type: 'Statement',
        pipelines: [pipeline],
        operators: [],
        background: false,
        sourceText: typeof pipeline.sourceText === 'string' ? pipeline.sourceText : '',
      }],
      redirections: [],
    }],
    negated: false,
    timed: false,
    timePosix: false,
  }
}

/**
 * Run every background job in a real subshell.
 *
 * just-bash parses `&` but executes the statement synchronously in the current
 * shell, so an `exit` there used to end the whole script. POSIX puts every
 * background job in a subshell; making that explicit keeps the exit local and
 * the parent cwd/env/status intact.
 * @param node - AST node, array or primitive.
 */
function isolateBackgroundStatements(node: unknown): void {
  if (Array.isArray(node)) {
    for (const item of node) isolateBackgroundStatements(item)
    return
  }
  if (typeof node !== 'object' || node === null) return
  const typed = node as ExitAstNode
  if (typed.type === 'Statement' && typed.background === true && Array.isArray(typed.pipelines)) {
    typed.pipelines = (typed.pipelines as ExitAstNode[]).map(pipeline => backgroundSubshell(pipeline))
    typed.background = false
  }
  for (const key of Object.keys(typed)) {
    if (key !== 'type') isolateBackgroundStatements(typed[key])
  }
}

/**
 * Build the shell-flow transform.
 *
 * `source`/`.`/`eval` text is transformed by the patched engine's builtins
 * themselves (see the dependency patch), so this plugin no longer rewrites
 * those commands or stages their arguments in shell variables. Pipeline stage
 * isolation belongs to the patched engine, which clones the full shell state
 * for every non-lastpipe stage; predicting that from static command names in
 * the AST missed dynamic words (`$g | cat`) and known names overridden by
 * `eval`/`source`. This transform now only gives background jobs their POSIX
 * subshell. It never predicts terminal state from the script text.
 * @returns the plugin to register with `Bash.registerTransformPlugin`.
 */
function createShellFlowPlugin(): TransformPlugin {
  return {
    name: 'pdsh-shell-flow',
    transform(context: TransformContext): TransformResult {
      isolateBackgroundStatements(context.ast)
      return { ast: context.ast }
    },
  }
}

/** Extra execution context for one `bash`/`sh` plan. */
interface ExecuteInvocation {
  /** `$0` and `$1...` for the script or command string. */
  readonly positional?: ShellPositional | undefined
  /** Parse the script without executing it (`bash -n`). */
  readonly syntaxOnly?: boolean | undefined
  /** Name the parser's diagnostic when {@link syntaxOnly} is set. */
  readonly sourceName?: string | undefined
  /**
   * Resolved script path when a file script is executed.
   *
   * Present only for `bash script.sh` / `./script.sh` (never `bash -c`): it
   * registers the `BASH_SOURCE` transform, whose `${0}` rewrite is supplied by
   * the same positional environment that carries `$0` (see `bash-source.ts`).
   */
  readonly bashSource?: string | undefined
  /**
   * Interpreter options from the invocation line (`-e`/`-u`/`-x`).
   *
   * Applied as one `set -eux` prelude (only the enabled letters) before the
   * engine parses the script, so the engine's own `set` owns the semantics.
   * `-n` ignores them because nothing executes (G2-FIX-95).
   */
  readonly options?: ShellOptions | undefined
}

/** A synthetic ENOENT for a script operand that names no candidate at all. */
function missingPathError(path: string): Error {
  return Object.assign(new Error(`ENOENT: no such file or directory, open '${path}'`), { code: 'ENOENT' })
}

/** True when a backend error means "this candidate does not exist". */
function isMissingPath(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code
  return code === 'ENOENT' || code === 'ENOTDIR'
}

/**
 * The candidate virtual paths for one script operand, in bash's lookup order:
 * the literal path, then each `PATH` directory (an empty entry is cwd).
 */
function scriptCandidates(fs: IFileSystem, path: string, cwd: string, pathVariable: string): string[] {
  if (path === '') return [fs.resolvePath(cwd, path)]
  if (path.includes('/')) return [fs.resolvePath(cwd, path)]
  const candidates = [fs.resolvePath(cwd, path)]
  const seen = new Set(candidates)
  for (const directory of pathVariable.split(':')) {
    const base = directory === '' ? cwd : fs.resolvePath(cwd, directory)
    const candidate = fs.resolvePath(base, path)
    if (seen.has(candidate)) continue
    seen.add(candidate)
    candidates.push(candidate)
  }
  return candidates
}

/** The POSIX text for the read error, without the backend's errno decoration. */
function scriptReadText(error: unknown): string {
  const coded = error as { code?: unknown; message?: unknown } | null
  const code = typeof coded?.code === 'string' ? coded.code : ''
  const message = typeof coded?.message === 'string' ? coded.message : String(error)
  if (code === 'ENOENT' || /no such file or directory/iu.test(message)) return 'No such file or directory'
  if (code === 'EISDIR' || /is a directory/iu.test(message)) return 'Is a directory'
  if (code === 'EACCES' || code === 'EPERM' || /permission denied/iu.test(message)) return 'Permission denied'
  if (code === 'ENOTDIR' || /not a directory/iu.test(message)) return 'Not a directory'
  return message
}

/**
 * The failure a script operand produces when it cannot be opened.
 *
 * GNU bash answers 127 for a missing script and 126 for one it cannot read;
 * the missing case carries the same not-available trailer the generic dispatch
 * produced for `bash missing.sh` before this shim, so the observable bytes of
 * that pre-existing failure do not change.
 */
function scriptReadFailure(
  program: ShellProgram,
  path: string,
  error: unknown,
  manifestPath: string | null,
): ShellResult {
  const text = scriptReadText(error)
  const exitCode = text === 'No such file or directory' ? 127 : 126
  let stderr = `${program}: ${path}: ${text}\n`
  if (exitCode === 127) {
    const bare = path.slice(path.lastIndexOf('/') + 1) || program
    stderr = appendShellTrailer(stderr, notAvailableTrailer(bare, exitCode, manifestPath))
  }
  return plainResult('', stderr, exitCode)
}

/** The Worker shell. */
export class WorkerShell {
  private readonly fs: IFileSystem
  private readonly commands: readonly CustomCommand[]
  private readonly internalCommands: readonly CustomCommand[]
  private readonly maxOutputBytes: number
  private readonly timeoutMs: number
  private readonly commandNames: readonly string[]
  private readonly disabledCommands: ReadonlySet<string>
  /** Current nested `bash`/`sh` script depth (see {@link MAX_SHELL_NESTING}). */
  private shellNesting = 0
  /** The published capability manifest path, or undefined when it could not be written. */
  private manifestPath: string | undefined
  /** One-shot manifest materialisation from this shell's command registry. */
  private manifestReady: Promise<string | undefined> | undefined
  /** The default `trap` command, rebound to a fresh token per execution. */
  private readonly trapCommand: CustomCommand | undefined

  constructor(options: WorkerShellOptions = {}) {
    this.fs = options.fs ?? new VfsFileSystem({ root: process.env.PDSH_VFS_ROOT ?? '/' })
    this.maxOutputBytes = options.maxOutputBytes ?? maxOutputBytesFromEnv()
    const disabled = new Set(options.disabledCommands ?? [])
    this.disabledCommands = disabled
    const commands = [...options.commands ?? []]
    // A toolbox command created by `createWorkerCommands` starts with the
    // default collector cap. The shell now knows the real cap (an explicit
    // option or PDSH_SHELL_MAX_OUTPUT_BYTES), so bind every such command before
    // the table is wrapped; otherwise a configured cap above 256 KiB would let
    // the collector truncate silently while the shell reported a clean exit.
    for (const command of commands) {
      const config = (command as CustomCommand & {
        readonly [TOOLBOX_OUTPUT_LIMIT]?: ToolboxOutputLimit
      })[TOOLBOX_OUTPUT_LIMIT]
      config?.set(this.maxOutputBytes)
    }
    // Every find invocation goes through the type-predicate shim: just-bash's
    // built-in accepts only `-type f|d` (see find.ts). A caller-supplied
    // `find` wins, so the shell stays extensible without double registration.
    if (!disabled.has('find') && !commands.some(command => command.name === 'find')) commands.push(createFindCommand())
    // `grep -I` / `--binary-files=without-match` is missing from just-bash
    // 3.6.0's option parser; the shim keeps the built-in's parser, traversal
    // and formatting and only hides NUL-containing files (see grep.ts). A
    // caller-supplied `grep` wins, as with `find`.
    if (!disabled.has('grep') && !commands.some(command => command.name === 'grep')) commands.push(createGrepCommand())
    // Every `stat -c` invocation goes through the format shim: the built-in
    // echoes directives it does not implement literally (see stat.ts). A
    // caller-supplied `stat` wins, as with `find`.
    if (!disabled.has('stat') && !commands.some(command => command.name === 'stat')) commands.push(createStatCommand())
    // just-bash's `od` ignores -N/-j and charges format work for the whole
    // operand, so a legal `od -An -tx1 -N4 big` exits 126. The shim reads and
    // formats only the requested window (see od.ts); a caller-supplied `od`
    // wins, as with the other shadows.
    if (!disabled.has('od') && !commands.some(command => command.name === 'od')) commands.push(createOdCommand())
    // Long `ls` reads the VFS mode instead of the built-in's constant first
    // column (see ls.ts); every non-long invocation stays the built-in. A
    // caller-supplied `ls` wins, as with the other shadows.
    if (!disabled.has('ls') && !commands.some(command => command.name === 'ls')) commands.push(createLsCommand())
    // `rmdir` must not reach just-bash's built-in over the Worker VFS: the
    // built-in asks the adapter to remove a directory, and the pinned runtime's
    // `node:fs` replacement has no `rmdir` at all (see rmdir.ts). A
    // caller-supplied `rmdir` wins, as with `find`/`stat`.
    if (!disabled.has('rmdir') && !commands.some(command => command.name === 'rmdir')) commands.push(createRmdirCommand())
    // The DSH search tools spawn ripgrep by path; the Worker-local `rg` needs
    // ripgrep's globset contract (see ripgrep.ts). A host-advertised
    // `accelerator:rg` is supplied by the caller and wins here.
    if (!disabled.has('rg') && !commands.some(command => command.name === 'rg')) commands.push(createRipgrepCommand())
    // `jq`'s input family (`inputs`, `input`, `input_line_number`) is missing
    // from the built-in evaluator; the shim parses the stream once and injects
    // the current document and remaining inputs. A caller-supplied `jq` wins,
    // as with the other shadows (see jq.ts).
    if (!disabled.has('jq') && !commands.some(command => command.name === 'jq')) commands.push(createJqCommand())
    // `sort -z` and the GNU `du -h` semantics are Worker shadows over the
    // bundled programs (see sort.ts / du.ts). A caller-supplied entry wins.
    if (!disabled.has('sort') && !commands.some(command => command.name === 'sort')) commands.push(createSortCommand())
    if (!disabled.has('du') && !commands.some(command => command.name === 'du')) commands.push(createDuCommand())
    // `type trap` has always answered "shell builtin", but just-bash has no
    // trap implementation: executing it fell through to the external-command
    // path (127) and EXIT actions never ran. This registers the real EXIT-only
    // builtin; a caller-supplied `trap` wins, as with the other shadows. Our
    // own command (also the one `createWorkerCommands` supplies) is marked, so
    // `execute` can rebind it to a per-execution token without publishing that
    // token in the environment (D10).
    const existingTrap = disabled.has('trap')
      ? undefined
      : commands.find(command => command.name === 'trap')
    let trapCommand: CustomCommand | undefined
    if (disabled.has('trap')) {
      trapCommand = undefined
    } else if (existingTrap === undefined) {
      trapCommand = createTrapCommand()
      commands.push(trapCommand)
    } else if (isDefaultTrapCommand(existingTrap)) {
      trapCommand = existingTrap
    }
    this.trapCommand = trapCommand
    // `bash`/`sh` own the interpreter-invocation surface (see interpreter.ts):
    // the bundled commands treat every non-`-c` first word as a script filename
    // and run scripts through a nested interpreter whose accounting the engine
    // rejects (exit 126). Registering the commands here fixes the same class
    // both for a top-level spawn and for `bash helper.sh` inside a script. A
    // caller-supplied `bash`/`sh` wins, as with the other shadows.
    for (const command of createShellInterpreterCommands(this)) {
      if (!commands.some(existing => existing.name === command.name)) commands.push(command)
    }
    // One owner for the GNU `--`, `--version` and `--help` conventions: it
    // wraps the assembled table idempotently (see gnu-conventions.ts), so a
    // caller-supplied shadow keeps its implementation.
    this.commands = applyGnuConventions(commands)
      .filter(command => !this.disabledCommands.has(command.name))
    // The arithmetic shim's base converter is an implementation detail of the
    // transform plugin: it must run, but it is not part of the user-visible
    // command table / materialised PATH.
    this.internalCommands = [createArithmeticBaseCommand(), createReadDecodeCommand()]
    // The shell's own registration writes become virtual PATH entries, so
    // `command -v` / `type` / `which` can only return a path that exists
    // (command-paths.ts). The candidate list serves the fallback for a backend
    // without a synchronous registration hook; bundled names come from
    // just-bash's registry and the custom table adds toolbox programs/stubs.
    this.commandNames = [...new Set([...getCommandNames(), ...this.commands.map(command => command.name)])]
      .filter(name => !this.disabledCommands.has(name))
    this.timeoutMs = options.timeoutMs ?? shellTimeoutFromEnv(process.env)
  }

  /** The filesystem this shell reads and writes. */
  get filesystem(): IFileSystem { return this.fs }

  /** The per-command wall-clock limit applied when a caller passes none. */
  get commandTimeoutMs(): number { return this.timeoutMs }

  /**
   * Run one argv, the way `subprocess-xl` sees it.
   *
   * `bash`/`sh` argv — `-c`, `-n`, `--version`, a script file with arguments,
   * stdin and path spellings such as `/bin/bash` — is parsed by
   * {@link runInvocation}, which owns the whole class (see interpreter.ts).
   * An executable shell script named by path (`./script.sh`) runs its source
   * through the same interpreter with its arguments as `$1`... (the engine's
   * bare path executor would run it without the composed shell's arithmetic
   * transform and command table, the G2-FIX-66 dispatch split). Any other
   * argv runs the named program through the same shell with each argument
   * passed verbatim (no re-parsing).
   * @param argv - program and arguments.
   * @param options - cwd, environment, stdin, signal and limits.
   * @returns bounded stdout/stderr and the exit status.
   */
  async run(argv: readonly string[], options: ShellRunOptions): Promise<ShellResult> {
    if (argv.length === 0 || argv[0] === '') throw new Error('shell-ext: argv must name a program')
    const cwd = options.cwd
    if (!cwd.startsWith('/')) throw new Error(`shell-ext: cwd must be absolute, got ${JSON.stringify(cwd)}`)
    const plan = parseShellInvocation(argv)
    if (plan !== undefined) return await this.runInvocation(plan, options)
    const program = argv[0] as string
    const file = await shellScriptFile(this.fs, cwd, program)
    if (file.kind === 'script') {
      // Same interpreter construction as `bash -c`: one arithmetic transform,
      // one command table, one dispatch path. `$0`/`$1`... travel as the
      // invocation's positional parameters (positionalEnvironment) because the
      // engine's exec `args` option appends argv to the first command instead
      // of setting them.
      // `$0` is the resolved path, the same value `bash helper.sh` reports
      // through runInvocation (bash-invocation.test.ts locks both forms together).
      const resolved = posix.resolve(cwd, program)
      return await this.execute(file.source, [], cwd, options, program, {
        positional: { name: resolved, args: argv.slice(1) },
        bashSource: resolved,
      })
    }
    const result = await this.execute(shellQuote(program), argv.slice(1), cwd, options, program)
    if (file.kind === 'missing' && result.exitCode === 127 && result.missingProgram === undefined) {
      // A path that does not exist is a failed spawn, not a command that ran
      // and exited 127 (the subprocess seam turns this into ENOENT).
      return { ...result, missingProgram: program }
    }
    return result
  }

  /**
   * Run one parsed `bash`/`sh` invocation.
   *
   * Both the top-level dispatch above and the registered `bash`/`sh` commands
   * call this method, so a script invoked from inside a `bash -c` script takes
   * exactly the same execution path as one spawned at the top level: a fresh
   * `Bash` instance, never the bundled command's nested interpreter (whose
   * result accounting the engine rejects with exit 126).
   * @param plan - the parsed invocation.
   * @param options - cwd, environment, stdin, signal and limits.
   * @returns the command result.
   */
  async runInvocation(plan: ShellPlan, options: ShellRunOptions): Promise<ShellResult> {
    await this.ensureCapabilityManifest()
    switch (plan.kind) {
      case 'version':
        return plainResult(shellVersion(plan.program), '', 0)
      case 'help':
        return plainResult(shellUsage(plan.program), '', 0)
      case 'usage': {
        const failure = shellFailure(plan.program, `${plan.program}: ${plan.message}`, 'unsupported-option', {
          hint: `usage: ${plan.program} [-c COMMAND] [-e] [-u] [-x] [-n] [-s] [-l] [--] [SCRIPT_FILE] [ARGUMENTS...]`,
        })
        return plainResult(failure.stdout, failure.stderr, failure.exitCode)
      }
      case 'command':
        // The words after `-c COMMAND` are `$0/$1...` (G2-FIX-116). Binding
        // them here is also what makes the built-in `find -exec` work: it
        // passes each exact `{}` through `ctx.exec` into the nested `sh -c`,
        // whose operands then become the positional parameters. The find shim
        // itself only audits `-type`/`-printf`, never the `-exec` argv.
        return await this.executeNested(plan.program, () => this.execute(
          plan.script,
          [],
          options.cwd,
          options,
          undefined,
          {
            positional: plan.positional,
            options: plan.options,
          },
        ))
      case 'stdin':
        return await this.executeNested(plan.program, () => this.execute(
          options.stdin ?? '',
          [],
          options.cwd,
          { ...options, stdin: '' },
          undefined,
          {
            positional: plan.positional,
            options: plan.options,
          },
        ))
      case 'check-command':
        return await this.execute(plan.script, [], options.cwd, options, undefined, {
          syntaxOnly: true,
          sourceName: plan.name,
          options: plan.options,
        })
      case 'check-stdin':
        return await this.execute(options.stdin ?? '', [], options.cwd, { ...options, stdin: '' }, undefined, {
          syntaxOnly: true,
          sourceName: plan.program,
          options: plan.options,
        })
      case 'script':
      case 'check-script': {
        const source = await this.readScript(plan.program, plan.path, options)
        if ('failure' in source) return source.failure
        if (plan.kind === 'check-script') {
          return await this.execute(source.text, [], options.cwd, options, undefined, {
            syntaxOnly: true,
            sourceName: plan.path,
            options: plan.options,
          })
        }
        return await this.executeNested(plan.program, () => this.execute(
          source.text,
          [],
          options.cwd,
          options,
          undefined,
          {
            positional: { name: source.resolved, args: plan.args },
            bashSource: source.resolved,
            options: plan.options,
          },
        ))
      }
    }
  }

  /**
   * Read the script file one invocation names.
   *
   * GNU bash tries the literal path (relative to cwd) and then each `PATH`
   * directory when the operand has no slash; the Worker keeps that order so a
   * script staged in the workspace and one installed on `PATH` both run. Any
   * error other than a missing candidate is the script's own failure and is
   * reported immediately.
   * @param program - invoked program name, for the diagnostic.
   * @param path - script operand as written.
   * @param options - cwd and environment.
   * @returns the source and the resolved virtual path, or the failure result.
   */
  private async readScript(
    program: ShellProgram,
    path: string,
    options: ShellRunOptions,
  ): Promise<{ readonly text: string; readonly resolved: string } | { readonly failure: ShellResult }> {
    const env = disciplineEnvironment(options.env, options.cwd)
    let lastError: unknown
    for (const candidate of scriptCandidates(this.fs, path, options.cwd, env.PATH ?? '/usr/bin:/bin')) {
      try {
        return { text: await readSourceText(this.fs, candidate), resolved: candidate }
      } catch (error) {
        if (!isMissingPath(error)) {
          return { failure: scriptReadFailure(program, path, error, this.manifestPath ?? null) }
        }
        lastError = error
      }
    }
    const manifestPath = this.manifestPath ?? null
    return { failure: scriptReadFailure(program, path, lastError ?? missingPathError(path), manifestPath) }
  }

  /** Run one nested shell invocation under the Worker nesting budget. */
  private async executeNested(program: ShellProgram, task: () => Promise<ShellResult>): Promise<ShellResult> {
    if (this.shellNesting >= MAX_SHELL_NESTING) {
      const message = `${program}: maximum nested shell depth (${String(MAX_SHELL_NESTING)}) exceeded`
      const stderr = appendShellTrailer(`${message}\n`, {
        exitCode: 126,
        program,
        reason: 'backend-failed',
        hint: 'each bash/sh script invocation starts a fresh Worker shell; unroll the recursion',
      })
      return plainResult('', stderr, 126)
    }
    this.shellNesting += 1
    try {
      return await task()
    } finally {
      this.shellNesting -= 1
    }
  }

  /**
   * Run a script string directly (the coverage runner and tests use this).
   * @param script - bash source.
   * @param options - cwd, environment, stdin, signal and limits.
   */
  async runScript(script: string, options: ShellRunOptions): Promise<ShellResult> {
    return await this.execute(script, [], options.cwd, options)
  }

  /**
   * Ensure the capability manifest path exists, once per shell instance.
   *
   * The Worker boot entry publishes the authoritative `pdsh-capabilities/1`
   * document before the first command (ENG-05); this shell adopts any file
   * already there and only fills the minimal fallback when no boot entry ran
   * (see `capabilities.ts`). The result is memoised for the life of this
   * {@link WorkerShell}: a failed first materialisation is not retried inside
   * the session, and every later hint omits the path rather than advertise one
   * that may not exist. The next shell evaluates again (every `bash -c` step
   * builds a fresh {@link WorkerShell}; a planned restart, D24, is the explicit
   * case); the semantics are documented in `README.md`.
   * @returns the published manifest path, or undefined.
   */
  private async ensureCapabilityManifest(): Promise<string | undefined> {
    this.manifestReady ??= materializeCapabilityManifest(this.fs, this.commandNames)
    this.manifestPath = await this.manifestReady
    return this.manifestPath
  }

  /** Shared execution path. */
  private async execute(
    script: string,
    args: readonly string[],
    cwd: string,
    options: ShellRunOptions,
    directProgram?: string,
    invocation?: ExecuteInvocation,
  ): Promise<ShellResult> {
    const maxBytes = options.maxOutputBytes ?? this.maxOutputBytes
    const timeoutMs = options.timeoutMs ?? this.timeoutMs
    const controller = new AbortController()
    // First interruption wins: an abort that precedes the wall-clock timer is
    // cancellation, even if the engine reports its own 124 while unwinding.
    let cause: InterruptionCause
    const external = options.signal
    const onAbort = (): void => {
      cause ??= 'abort'
      controller.abort(external?.reason)
    }
    if (external?.aborted === true) return interruptedResult(true, false)
    external?.addEventListener('abort', onAbort, { once: true })
    // Shell bootstrap (command-entry registration and PATH sanitisation) is
    // not part of the command's wall clock, and a caller abort that lands
    // during it must still win. Both are decided before `Bash` exists.
    const env = disciplineEnvironment(options.env, cwd)
    await materializeCommandPaths(this.fs, this.commandNames)
    await this.ensureCapabilityManifest()
    if (controller.signal.aborted) {
      external?.removeEventListener('abort', onAbort)
      return interruptedResult(true, false)
    }
    env.PATH = await sanitizeCommandPath(this.fs, env.PATH ?? '/usr/bin:/bin')
    // The caller may also abort during PATH sanitisation, after the bootstrap
    // check above. Decide before the interpreter exists so no engine status
    // can overwrite the caller's cancellation.
    if (controller.signal.aborted) {
      external?.removeEventListener('abort', onAbort)
      return interruptionResult(cause)
    }
    const timer = setTimeout(() => {
      cause ??= 'timeout'
      controller.abort(new Error('shell-ext: wall-clock limit exceeded'))
    }, timeoutMs)
    // The wall clock and the caller's abort cover the whole execution,
    // including an EXIT handler that runs after the script returns. They are
    // released on every return path below.
    let removeAbortWait: (() => void) | undefined
    const releaseInterruption = (): void => {
      clearTimeout(timer)
      external?.removeEventListener('abort', onAbort)
      removeAbortWait?.()
      removeAbortWait = undefined
    }
    // G2-FIX-107: every execution gets a private trap-state token. It is bound
    // in the `trap` command closure, never written to `env`: the exported
    // environment feeds the accelerator idem_key hash (D10) and host/child
    // processes, and this bookkeeping must stay internal. `new Bash` snapshots
    // the environment, so the rebinding happens before construction.
    const trapToken = createTrapToken()
    const boundTrap = this.trapCommand
    // The patched engine reports the real unwound terminal state on every
    // root return (completion, errexit, typed fatal, explicit exit) and its
    // `source`/`eval` builtins apply this shell's transform plugins to their
    // own text. This layer therefore registers no state-prediction checkpoint,
    // no pre-exit capture and no hidden prepare command/variable.
    const sourceTempPath = `/dsh/tmp/.pdsh-source-${trapToken}.sh`
    const cleanupSourceTemp = async (): Promise<boolean> => {
      try {
        await this.fs.rm(sourceTempPath, { recursive: true, force: true })
        return true
      } catch {
        return false
      }
    }
    const commandTable = boundTrap === undefined
      ? [...this.commands, ...this.internalCommands]
      : [
          ...this.commands.map(command => command === boundTrap ? createTrapCommand(trapToken) : command),
          ...this.internalCommands,
        ]
    const customCommands = commandTable
    // The gate is a no-op until the signal fires; the handler additionally
    // snapshots each target and rolls back a write that was still in flight
    // when the deadline/abort arrived (see guardedFileSystem).
    const fsGuard = guardedFileSystem(this.fs, controller.signal)
    const bash = new Bash({
      fs: fsGuard.fs,
      cwd,
      env,
      customCommands,
      // Restrict just-bash's built-ins only when the caller disabled one (the
      // fork's jq); otherwise keep the engine's full default registry.
      ...this.disabledCommands.size === 0 ? {} : {
        commands: getCommandNames()
          .filter(name => !this.disabledCommands.has(name)) as CommandName[],
      },
      executionLimits: {
        // The shared execution ceilings are phone-dsh's own decision, not an
        // engine default: the shell and the capability manifest read the same
        // frozen constants (G2-FIX-118).
        ...WORKER_EXECUTION_LIMITS,
        maxExecutionTimeMs: timeoutMs + 1_000,
        // A memory bound for one result, not the visible stream cap: pipeline
        // bytes are not final output (see pipelineOutputBudget above).
        maxOutputSize: pipelineOutputBudget(maxBytes),
      },
    })
    // `bash -n`: the engine's parser surface, run without the interpreter and
    // therefore without executing anything. The syntax check runs before the
    // arithmetic transform plugin is registered, so it is a pure parse: a
    // transform is a semantic rewrite, not part of bash's noexec surface.
    // Parse errors are reported with the script's own name and status 2 (GNU
    // bash); they are user-data failures, not this layer's usage surface, so
    // they carry no contract trailer.
    if (invocation?.syntaxOnly === true) {
      releaseInterruption()
      clearTrapState(trapToken)
      const name = invocation.sourceName ?? 'bash'
      try {
        bash.transform(script)
        return plainResult('', '', 0)
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return plainResult('', `${name}: ${message}\n`, 2)
      }
    }
    // G2-FIX-95: invocation-line -e/-u/-x become one `set -eux` line (only the
    // enabled letters) executed by the engine's own `set`, so its errexit,
    // nounset and xtrace semantics are the authority. `-n` returned above, so a
    // syntax-only invocation never inserts or runs this line.
    const executedScript = invocation?.options === undefined
      ? script
      : `${shellOptionPrelude(invocation.options)}${script}`
    // G2-FIX-26: arithmetic `$(( ))` operands lose `${var#pat}` /
    // `${var:off:len}` in just-bash 3.6.0. The transform expands those
    // operands with the shell's own word-expansion path before evaluation
    // (see arithmetic.ts).
    bash.registerTransformPlugin(createArithmeticExpansionPlugin())
    // G2-FIX-43: just-bash's `read` leaves the stdin byte string in its target
    // variables; the plugin appends one decode command per `read` invocation
    // (see read-encoding.ts). It runs after the arithmetic rewriter so both
    // edits compose.
    bash.registerTransformPlugin(createReadDecodePlugin())
    // Source/eval text, state-mutating pipeline stages and background jobs are
    // the only AST rewrites left. Terminal state comes from the engine seam,
    // not from a checkpoint.
    bash.registerTransformPlugin(createShellFlowPlugin())
    // G2-FIX-87: a file script's `${BASH_SOURCE[0]}` is its resolved path;
    // `positionalEnvironment` already carries that path as `$0`. The plugin is
    // registered only here, so `bash -c` keeps GNU's empty top-level value.
    if (invocation?.bashSource !== undefined) bash.registerTransformPlugin(createBashSourcePlugin())
    const positional = invocation?.positional
    let abortWaitListener: (() => void) | undefined
    const aborted = new Promise<undefined>((resolve) => {
      if (controller.signal.aborted) {
        resolve(undefined)
        return
      }
      const listener = (): void => { resolve(undefined) }
      abortWaitListener = listener
      controller.signal.addEventListener('abort', listener, { once: true })
    })
    removeAbortWait = () => {
      if (abortWaitListener === undefined) return
      controller.signal.removeEventListener('abort', abortWaitListener)
      abortWaitListener = undefined
    }
    /**
     * Finish an interrupted execution without waiting indefinitely for an
     * in-flight backend write or staging-file cleanup.
     *
     * The controller's timer/listener stay installed until this returns: the
     * execution timeout is followed by a cleanup grace of at most 400 ms for
     * write settlement and a further 200 ms for staging cleanup. Cleanup waits
     * until stage writes settle so a late write cannot recreate a removed file.
     * A failed or
     * unsettled rollback is labelled backend-failed; when a pending write
     * eventually resolves, its tracked mutation still attempts restoration.
     */
    const finishInterrupted = async (): Promise<ShellResult> => {
      clearTrapState(trapToken)
      let rollbackSucceeded = false
      const settling = fsGuard.settle().then(
        succeeded => { rollbackSucceeded = succeeded },
        () => { rollbackSucceeded = false },
      )
      const settled = await settlesWithin(settling, INTERRUPTION_ROLLBACK_BUDGET_MS)
      let cleanupSucceeded = false
      let cleaned = false
      if (settled) {
        const cleaning = cleanupSourceTemp().then(
          succeeded => { cleanupSucceeded = succeeded },
          () => { cleanupSucceeded = false },
        )
        cleaned = await settlesWithin(cleaning, INTERRUPTION_CLEANUP_BUDGET_MS)
      }
      if (!settled) {
        // The underlying stage write may still complete later; only then is it
        // safe to remove the staged file it could recreate.
        void settling.then(() => cleanupSourceTemp()).catch(() => {})
      }
      releaseInterruption()
      const result = interruptionResult(cause)
      if (settled && rollbackSucceeded && cleaned && cleanupSucceeded) return result
      // The command still reports its original interruption status, but an
      // operation the backend did not settle is a substrate failure and is
      // labelled as such rather than silently claiming a clean unwind. A
      // settled promise whose undo or temp-file cleanup failed is the same
      // uncertainty: the caller must not treat it as a clean rollback.
      const hint = !settled
        ? 'an in-flight filesystem operation did not settle within the interruption grace'
        : !rollbackSucceeded
          ? 'the in-flight filesystem operation settled but its snapshot rollback failed'
          : 'source/eval temporary-file cleanup failed or exceeded its interruption grace'
      return {
        ...result,
        stderr: appendShellTrailer(result.stderr, {
          exitCode: result.exitCode,
          program: 'bash',
          reason: 'backend-failed',
          hint,
        }),
      }
    }
    /**
     * Wait for normal completion work, but leave immediately for an
     * interruption so its bounded finaliser owns the remaining budget.
     */
    const waitOrInterrupt = async (work: Promise<unknown>): Promise<boolean> => {
      const outcome = await Promise.race([
        work.then(() => 'done' as const, () => 'done' as const),
        aborted.then(() => 'interrupted' as const),
      ])
      return outcome === 'done' && !controller.signal.aborted
    }
    const execOptions: ExecOptions & { [key: symbol]: unknown } = {
      cwd,
      signal: controller.signal,
      stdin: options.stdin ?? '',
      ...options.stdinKind === undefined ? {} : { stdinKind: options.stdinKind },
      ...args.length === 0 ? {} : { args: [...args] },
      ...positional === undefined ? {} : { env: positionalEnvironment(positional) },
      // The patched engine stages transformed `source` text at this private
      // path; it is not a shell variable, so `env`/`set`/`set -x` never see it.
      [TERMINAL_SEED_SYMBOL]: { sourceStagePath: sourceTempPath } satisfies TerminalSeed,
    }
    const executing = bash.exec(executedScript, execOptions)
    void executing.catch(() => {})
    let result: Awaited<typeof executing> | undefined
    try {
      result = await Promise.race([executing, aborted])
    } catch (error) {
      if (controller.signal.aborted) return await finishInterrupted()
      clearTrapState(trapToken)
      // The engine itself rejected: this is our execution layer failing, the
      // one class the contract labels `backend-failed` (contract.ts).
      const failure = shellFailure(
        directProgram ?? 'bash',
        `pdsh-shell: ${error instanceof Error ? error.message : String(error)}`,
        'backend-failed',
      )
      let cleaned = false
      const cleaning = cleanupSourceTemp().then(
        succeeded => { cleaned = succeeded },
        () => { cleaned = false },
      )
      if (!await waitOrInterrupt(cleaning)) return await finishInterrupted()
      releaseInterruption()
      if (!cleaned) {
        const stderr = appendShellTrailer(failure.stderr, {
          exitCode: failure.exitCode,
          program: directProgram ?? 'bash',
          reason: 'backend-failed',
          hint: 'source/eval temporary-file cleanup failed after the interpreter error',
        })
        return plainResult(failure.stdout, stderr, failure.exitCode)
      }
      return plainResult(failure.stdout, failure.stderr, failure.exitCode)
    }
    // An engine result is only authoritative when no interruption arrived. A
    // cancelled script must never surface as the engine's synthetic 124 (the
    // G2 loop's spawn-cancel assertion): the caller abort wins.
    if (result === undefined || controller.signal.aborted) return await finishInterrupted()
    // G2-FIX-107: an EXIT trap runs after the root script returns against the
    // engine's authoritative terminal state, in the same filesystem and command
    // table. The handler is not run for `-n`, an abort/timeout, an engine
    // ceiling, a parse/security failure or an engine exception; those are not
    // ordinary shell terminal states. Its stdout/stderr are merged into the
    // command's streams and the original status is kept, as GNU bash does when
    // the handler does not call `exit` itself.
    let trapStdout = ''
    let trapStderr = ''
    let trapAccounting: OutputAccounting | undefined
    let handlerExitCode: number | undefined
    // A handler that cannot run because the engine seam is absent or its
    // record is not authoritative is a backend failure, not a clean exit. If
    // the script itself succeeded, the command must not return 0: fail loud
    // with `backend-failed` instead of silently skipping user cleanup.
    let handlerSeamFailure = false
    const exitHandler = getTrapHandler(trapToken, TRAP_EXIT_SIGNAL)
    if (exitHandler !== undefined) {
      const terminal = readTerminalState(result)
      const skippedExitCode = result.exitCode === 0 ? 1 : result.exitCode
      if (terminal === undefined) {
        handlerSeamFailure = true
        trapStderr = appendShellTrailer('', {
          exitCode: skippedExitCode,
          program: directProgram ?? 'bash',
          reason: 'backend-failed',
          hint: 'EXIT trap skipped because the engine returned no terminal-state record',
        })
      } else if (!terminalHandlerEligible(terminal)) {
        handlerSeamFailure = true
        const detail = terminal.unsupportedReason
          ?? `termination=${terminal.termination} cause=${terminal.cause}`
        trapStderr = appendShellTrailer('', {
          exitCode: skippedExitCode,
          program: directProgram ?? 'bash',
          reason: 'backend-failed',
          hint: `EXIT trap skipped: ${detail} is not an ordinary shell terminal state`,
        })
      } else if (terminal.cwd === undefined || terminal.env === undefined) {
        handlerSeamFailure = true
        trapStderr = appendShellTrailer('', {
          exitCode: skippedExitCode,
          program: directProgram ?? 'bash',
          reason: 'backend-failed',
          hint: 'EXIT trap skipped because the authoritative terminal state has no cwd/env',
        })
      } else {
        // The engine seeds `$?`, PIPESTATUS and the shell options directly
        // from a symbol option. There is no hidden command name or shell
        // variable a user function/alias could shadow, and no internal line in
        // the xtrace.
        const trapScript = exitHandler
        try {
          fsGuard.beginHandler()
          const snapshot = terminalSnapshotFromResult(result)
          if (snapshot === undefined) throw new Error('terminal state snapshot unavailable')
          const trapExecOptions: ExecOptions & { [key: symbol]: unknown } = {
            signal: controller.signal,
            [TERMINAL_STATE_SYMBOL]: snapshot,
            [TERMINAL_SEED_SYMBOL]: {
              status: result.exitCode,
              pipeStatus: terminal.pipeline.statuses,
              ...terminal.options === undefined ? {} : { options: terminal.options },
              ...terminal.shopt === undefined ? {} : { shopt: terminal.shopt },
              sourceStagePath: sourceTempPath,
            } satisfies TerminalSeed,
          }
          const trapExecuting = bash.exec(trapScript, trapExecOptions)
          void trapExecuting.catch(() => {})
          // The handler is part of the command's wall clock and cancellation
          // surface: a slow handler must map to 124 and a caller abort to 130,
          // not return the script's status after the limit has already expired.
          const trapResult = await Promise.race([trapExecuting, aborted])
          if (trapResult === undefined || controller.signal.aborted) return await finishInterrupted()
          trapStdout = trapResult.stdout
          trapStderr = trapResult.stderr
          trapAccounting = readOutputAccounting(trapResult)
          // An explicit `exit N` in the handler changes the command's status,
          // as GNU bash does. A handler that merely fails keeps the script's
          // original status.
          const handlerTerminal = readTerminalState(trapResult)
          if (handlerTerminal?.termination === 'explicit-exit') {
            handlerExitCode = handlerTerminal.status
          }
        } catch (error) {
          trapStderr = `bash: ${error instanceof Error ? error.message : String(error)}\n`
        }
      }
    }
    clearTrapState(trapToken)
    // Keep the wall clock and caller abort installed through the settlement
    // and cleanup grace. A rollback/cleanup error is separate from a promise
    // that has not settled; both are backend failures, never clean success.
    let rollbackSucceeded = false
    const settling = fsGuard.settle().then(
      succeeded => { rollbackSucceeded = succeeded },
      () => { rollbackSucceeded = false },
    )
    if (!await waitOrInterrupt(settling)) return await finishInterrupted()
    if (!rollbackSucceeded) {
      releaseInterruption()
      const failure = shellFailure(
        directProgram ?? 'bash',
        'pdsh-shell: an interrupted filesystem mutation could not be restored',
        'backend-failed',
      )
      return plainResult(failure.stdout, failure.stderr, failure.exitCode)
    }
    let cleanupSucceeded = false
    const cleaning = cleanupSourceTemp().then(
      succeeded => { cleanupSucceeded = succeeded },
      () => { cleanupSucceeded = false },
    )
    if (!await waitOrInterrupt(cleaning)) return await finishInterrupted()
    if (!cleanupSucceeded) {
      releaseInterruption()
      const failure = shellFailure(
        directProgram ?? 'bash',
        'pdsh-shell: source/eval temporary-file cleanup failed',
        'backend-failed',
      )
      return plainResult(failure.stdout, failure.stderr, failure.exitCode)
    }
    if (controller.signal.aborted) return await finishInterrupted()
    releaseInterruption()
    const stdoutSource = result.stdout + trapStdout
    const stderrSource = result.stderr + trapStderr
    const out = boundOutput(stdoutSource, maxBytes)
    const err = boundOutput(stderrSource, maxBytes)
    // A nested producer (a WASI toolbox program or a nested `bash`) already
    // bounded its own stream. Its real byte facts travel on the result object
    // as a symbol the user cannot write; marker-looking text in stdout/stderr
    // is just ordinary text and never changes these numbers.
    const outputAccounting = mergeOutputAccounting(readOutputAccounting(result), trapAccounting)
    const stdoutAccounting = outputAccounting?.stdout
    const stderrAccounting = outputAccounting?.stderr
    const stdoutOriginalBytes = Math.max(
      out.originalBytes,
      out.originalBytes + (stdoutAccounting?.dropped ?? 0) - (stdoutAccounting?.markerBytes ?? 0),
    )
    const stderrOriginalBytes = Math.max(
      err.originalBytes,
      err.originalBytes + (stderrAccounting?.dropped ?? 0) - (stderrAccounting?.markerBytes ?? 0),
    )
    const stdoutTruncated = out.truncated || (stdoutAccounting?.dropped ?? 0) > 0
    const stderrTruncated = err.truncated || (stderrAccounting?.dropped ?? 0) > 0
    let exitCode = handlerExitCode ?? result.exitCode
    if (handlerSeamFailure && exitCode === 0) exitCode = 1
    let stderrText = err.text
    // A cut stream is incomplete data: say so with one contract trailer line
    // and never report the command's 0 over a partial page (contract.ts).
    const truncation = truncationAnnotation(stdoutTruncated, stderrTruncated, maxBytes)
    if (truncation !== undefined) {
      if (exitCode === 0) exitCode = truncation.exitCode
      stderrText = appendShellTrailer(stderrText, { ...truncation.trailer, exitCode })
    } else if (exitCode === 127) {
      // The engine's 127 says only "the program is not here". The Worker knows
      // what it does provide: append the manifest hint so the model does not
      // spend turns probing (G2-A05 tar, G2-E09 python).
      const program = extractFailureProgram(stderrText, directProgram)
      if (program !== undefined) {
        stderrText = appendShellTrailer(stderrText, notAvailableTrailer(program, exitCode, this.manifestPath ?? null))
      }
    } else if (exitCode !== 0) {
      // Execution ceilings are a Worker policy, not a command failure: name
      // them as such wherever the engine surfaced them (any program, not only
      // our shims). just-bash 3.6 names a command-count trip only as
      // `bash: too many commands executed`, and a `for`/`while`/`until` trip as
      // `bash: <loop> loop: too many iterations`, so a plain program extraction
      // would miss both. {@link executionLimitProgram} owns those shapes and
      // the trailer makes the reason the same machine-readable token the
      // manifest discloses (G2-FIX-118).
      //
      // The single-file budget is the other Worker policy: its label is read
      // from the backend's active budget and formatted by the shared owner, so
      // it always matches the enforced size.
      const limitProgram = executionLimitProgram(stderrText, directProgram)
      if (limitProgram !== undefined) {
        stderrText = appendShellTrailer(stderrText, {
          exitCode,
          program: limitProgram,
          reason: 'iterations',
          hint: workerExecutionLimitsSentence(),
        })
      } else if (/EFBIG|file too large|would be \d+ bytes; a file is limited/iu.test(stderrText)) {
        const program = extractFailureProgram(stderrText, directProgram)
        if (program !== undefined) {
          const budget = fileSizeBudget(this.fs) ?? MAX_FILE_SIZE
          stderrText = appendShellTrailer(stderrText, {
            exitCode,
            program,
            reason: 'limit-refused',
            hint: `a single VFS file is limited to ${budgetLabel(budget)} (PLAN D4)`,
          })
        }
      }
    }
    const missing = directProgram !== undefined
      && result.exitCode === 127
      && /command not found/i.test(result.stderr)
      ? directProgram
      : undefined
    return {
      stdout: out.text,
      stderr: stderrText,
      exitCode,
      timedOut: false,
      aborted: false,
      stdoutTruncated,
      stderrTruncated,
      stdoutOriginalBytes,
      stderrOriginalBytes,
      ...outputAccounting === undefined ? {} : { outputAccounting },
      ...missing === undefined ? {} : { missingProgram: missing },
    }
  }
}

/**
 * Run one command with a fresh {@link WorkerShell}.
 * @param argv - program and arguments.
 * @param options - cwd, environment, stdin, signal and limits.
 * @param shellOptions - filesystem and command registration.
 * @returns the bounded result.
 */
export async function runShellCommand(
  argv: readonly string[],
  options: ShellRunOptions,
  shellOptions: WorkerShellOptions = {},
): Promise<ShellResult> {
  const shell = new WorkerShell(shellOptions)
  return await shell.run(argv, options)
}
