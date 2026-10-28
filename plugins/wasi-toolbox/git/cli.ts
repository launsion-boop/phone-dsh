// SPDX-License-Identifier: MIT
/**
 * The `git` program for the Worker shell: argument handling, repository
 * context, output collection and command dispatch.
 *
 * The program is a plain async function, {@link runGit}, so the same code path
 * serves `bash -c "git ..."` inside the DSH Worker (where `node:fs` is the
 * in-memory VFS) and the tests that compare it byte-for-byte with the system
 * git. Writes stay in the Worker (PLAN D12); only `clone`/`fetch`/`push` reach
 * the network, and those go through an injected `fetch` — in production the
 * host `/v1/http` route.
 * @module @phone-dsh/dsh-wasi-toolbox/git/cli
 */
import { GitFailure, fatal } from './errors.ts'
import { NodeGitFs, encodeText, resolvePath } from './fs.ts'
import type { GitFs } from './fs.ts'
import { discoverRepository } from './repo.ts'
import type { Repository } from './repo.ts'
import { commandTable } from './commands.ts'
import { REFLOG_COMMANDS, captureReflogState, recordReflog } from './reflog.ts'
import type { RemoteTransport } from './http.ts'

/** One invocation's inputs. */
export interface GitRunContext {
  /** Filesystem; defaults to `node:fs/promises`, the Worker VFS. */
  readonly fs?: GitFs | undefined
  /** Working directory (absolute; the shell's cwd inside the Worker VFS). */
  readonly cwd: string
  /** Environment (the shell exports, including `GIT_*` and `HOME`). */
  readonly env?: Readonly<Record<string, string | undefined>> | undefined
  /** Standard input bytes (for `check-ignore --stdin` and `cat-file --batch`). */
  readonly stdin?: Uint8Array | string | undefined
  /** Fetch implementation for the host `/v1/http` hop (clone/fetch/push). */
  readonly fetch?: typeof fetch | undefined
  /** Override the smart-HTTP transport (tests use an in-process server). */
  readonly transport?: RemoteTransport | undefined
}

/** Settled result of one command. */
export interface GitRunResult {
  readonly stdout: Uint8Array
  readonly stderr: Uint8Array
  readonly exitCode: number
}

/** Mutable output collector shared by the command implementations. */
export class Output {
  private readonly out: Uint8Array[] = []
  private readonly err: Uint8Array[] = []

  /** Append bytes or text to stdout. */
  stdout(chunk: Uint8Array | string): void {
    this.out.push(typeof chunk === 'string' ? encodeText(chunk) : chunk)
  }

  /** Append bytes or text to stderr. */
  stderr(chunk: Uint8Array | string): void {
    this.err.push(typeof chunk === 'string' ? encodeText(chunk) : chunk)
  }

  /** Collected stdout. */
  stdoutBytes(): Uint8Array {
    return concat(this.out)
  }

  /** Collected stderr. */
  stderrBytes(): Uint8Array {
    return concat(this.err)
  }

  /** Reset both streams (a command that falls back to another implementation). */
  clear(): void {
    this.out.length = 0
    this.err.length = 0
  }
}

function concat(chunks: readonly Uint8Array[]): Uint8Array {
  let length = 0
  for (const chunk of chunks) length += chunk.byteLength
  const out = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out
}

/** Everything one subcommand receives. */
export interface CommandContext {
  readonly fs: GitFs
  readonly cwd: string
  readonly env: Readonly<Record<string, string | undefined>>
  readonly args: readonly string[]
  readonly stdin: Uint8Array
  readonly output: Output
  readonly fetch?: typeof fetch | undefined
  readonly transport?: RemoteTransport | undefined
  /** Config entries from `git -c key=value`, applied after discovery. */
  readonly configOverrides: readonly string[]
  /** Discover the enclosing repository (fails with git's message when absent). */
  repository(): Promise<Repository>
  /** Text of one argv path resolved against the process cwd. */
  absolute(path: string): string
  /** Work-tree-relative form of one argv path, or undefined when outside. */
  relativeToWorkTree(path: string): string | undefined
}

/** One subcommand implementation. */
export type CommandHandler = (context: CommandContext) => Promise<number>

/**
 * All implemented subcommands, resolved lazily.
 *
 * `capability.ts` imports `commandTable()` from `commands.ts`. Resolving the
 * table at module-evaluation time would re-enter this module while
 * `commands.ts` is still initialising when capability is the entry point, so
 * the dispatch table is built on first use instead.
 */
let commandsCache: Readonly<Record<string, CommandHandler>> | undefined
function implementedCommands(): Readonly<Record<string, CommandHandler>> {
  commandsCache ??= commandTable()
  return commandsCache
}

/** Subcommands that exist in git but deliberately stay off the Worker path. */
const UNSUPPORTED: Readonly<Record<string, string>> = {
  rebase: 'rewrites commits and needs an interactive editor and conflict resolution',
  stash: 'needs a second working-tree snapshot and reflog-backed stash refs',
  submodule: 'needs network recursion and a nested repository per submodule',
  'filter-branch': 'rewrites history and is unsafe on a device',
  'cherry-pick': 'needs three-way conflict resolution',
  revert: 'needs three-way conflict resolution',
  am: 'applies mailbox patches and needs three-way conflict resolution',
  bisect: 'needs repeated checkouts and a build/test loop',
  lfs: 'needs the Git LFS HTTP protocol and a content store',
  gc: 'repacks objects and needs long-running background work',
  prune: 'rewrites the object database',
  repack: 'rewrites the object database',
  'update-server-info': 'serves dumb HTTP and is a host-side publishing step',
  archive: 'writes tar/zip streams and is a host-side export step',
  'format-patch': 'is an export step that belongs on the host',
  bundle: 'is an export step that belongs on the host',
  notes: 'needs a notes ref and merge machinery',
  worktree: 'needs a second working tree on the real filesystem',
  daemon: 'needs a listening socket',
  receive: 'only a host serves repositories',
  'upload-pack': 'only a host serves repositories',
}

/** Parse global options and run one subcommand. */
export async function runGit(argv: readonly string[], context: GitRunContext): Promise<GitRunResult> {
  const output = new Output()
  const fs = context.fs ?? new NodeGitFs()
  const env = context.env ?? process.env
  let cwd = context.cwd
  let exitCode = 0
  try {
    const parsed = parseGlobalOptions(argv, cwd)
    cwd = parsed.cwd
    if (parsed.mode === 'version') {
      output.stdout('git version 2.50.1 (phone-dsh Worker git)\n')
    } else if (parsed.mode === 'help' || parsed.command === undefined) {
      output.stdout(USAGE)
      exitCode = parsed.mode === 'help' ? 0 : 1
    } else if (parsed.command === 'help') {
      output.stdout(USAGE)
    } else {
      exitCode = await dispatch(fs, cwd, env, parsed, context, output)
    }
  } catch (error) {
    if (error instanceof GitFailure) {
      output.stderr(error.stderr)
      exitCode = error.exitCode
    } else {
      const message = error instanceof Error ? error.message : String(error)
      output.stderr(`fatal: ${message}\n`)
      exitCode = 128
    }
  }
  return { stdout: output.stdoutBytes(), stderr: output.stderrBytes(), exitCode }
}

interface ParsedGlobal {
  readonly command?: string | undefined
  readonly args: readonly string[]
  readonly cwd: string
  readonly configOverrides: readonly string[]
  readonly envOverrides: Readonly<Record<string, string>>
  readonly mode?: 'version' | 'help' | undefined
}

function parseGlobalOptions(argv: readonly string[], initialCwd: string): ParsedGlobal {
  let cwd = initialCwd
  const configOverrides: string[] = []
  const envOverrides: Record<string, string> = {}
  let index = 0
  while (index < argv.length) {
    const arg = argv[index] as string
    if (arg === '-C') {
      const value = argv[index + 1]
      if (value === undefined) throw new GitFailure(129, 'fatal: no directory specified for -C\n')
      cwd = resolvePath(cwd, value)
      index += 2
      continue
    }
    if (arg === '-c') {
      const value = argv[index + 1]
      if (value === undefined) throw new GitFailure(129, 'fatal: no config value specified for -c\n')
      configOverrides.push(value)
      index += 2
      continue
    }
    if (arg === '--git-dir' || arg === '--work-tree') {
      const value = argv[index + 1]
      if (value === undefined) throw new GitFailure(129, `fatal: no value specified for ${arg}\n`)
      envOverrides[arg === '--git-dir' ? 'GIT_DIR' : 'GIT_WORK_TREE'] = value
      index += 2
      continue
    }
    if (arg.startsWith('--git-dir=')) { envOverrides.GIT_DIR = arg.slice('--git-dir='.length); index += 1; continue }
    if (arg.startsWith('--work-tree=')) { envOverrides.GIT_WORK_TREE = arg.slice('--work-tree='.length); index += 1; continue }
    if (arg === '--no-pager' || arg === '--no-replace-objects'
      || arg === '--no-optional-locks' || arg === '--paginate' || arg === '-P') {
      // These change paging, object replacement or lock placement; the Worker
      // git's behaviour already matches their effect. Pathspec-affecting flags
      // such as --literal-pathspecs are not in this list: the implementation
      // cannot claim they were applied.
      index += 1
      continue
    }
    if (arg === '--version') return { args: [], cwd, configOverrides, envOverrides, mode: 'version' }
    if (arg === '--help' || arg === '-h') return { args: [], cwd, configOverrides, envOverrides, mode: 'help' }
    if (arg.startsWith('-')) {
      // Silently dropping a global flag would run a different command than the
      // caller asked for; fail loud with the flag's name instead.
      throw new GitFailure(129, `fatal: unsupported global option '${arg}'. Nothing was run.\n`)
    }
    return { command: arg, args: argv.slice(index + 1), cwd, configOverrides, envOverrides }
  }
  return { args: [], cwd, configOverrides, envOverrides }
}

async function dispatch(
  fs: GitFs,
  cwd: string,
  env: Readonly<Record<string, string | undefined>>,
  parsed: ParsedGlobal,
  run: GitRunContext,
  output: Output,
): Promise<number> {
  const command = parsed.command as string
  const effectiveEnv: Readonly<Record<string, string | undefined>> = { ...env, ...parsed.envOverrides }
  const stdin = typeof run.stdin === 'string'
    ? encodeText(run.stdin)
    : run.stdin ?? new Uint8Array(0)
  let repositoryPromise: Promise<Repository> | undefined
  const context: CommandContext = {
    fs,
    cwd,
    env: effectiveEnv,
    args: parsed.args,
    stdin,
    output,
    ...run.fetch === undefined ? {} : { fetch: run.fetch },
    ...run.transport === undefined ? {} : { transport: run.transport },
    configOverrides: parsed.configOverrides,
    repository: async () => {
      repositoryPromise ??= (async () => {
        const repository = await discoverRepository(fs, cwd, effectiveEnv)
        if (repository === undefined) throw fatal('not a git repository (or any of the parent directories): .git')
        for (const override of parsed.configOverrides) {
          const equals = override.indexOf('=')
          if (equals > 0) repository.config.set(override.slice(0, equals).trim(), override.slice(equals + 1).trim())
        }
        return repository
      })()
      return await repositoryPromise
    },
    absolute: path => resolvePath(cwd, path),
    relativeToWorkTree: path => {
      const absolute = resolvePath(cwd, path)
      return absolute
    },
  }
  const handler = implementedCommands()[command]
  if (handler !== undefined) {
    // Ref moves are bookkept here, once, at the dispatch boundary: the command
    // bodies keep owning refs while this module owns `.git/logs`. The capture
    // happens before the handler so an initial commit and the old branch tip
    // are still visible; only a successful run appends entries, while branch
    // deletions are reconciled even when the command fails partway through.
    const reflog = REFLOG_COMMANDS.has(command)
      ? await captureReflogState(fs, cwd, effectiveEnv, parsed.configOverrides)
      : undefined
    let exitCode: number
    try {
      exitCode = await handler(context)
    } catch (error) {
      if (reflog !== undefined) await recordReflog(command, parsed.args, reflog, false)
      throw error
    }
    if (reflog !== undefined) await recordReflog(command, parsed.args, reflog, exitCode === 0)
    return exitCode
  }
  if (command === 'version') {
    output.stdout('git version 2.50.1 (phone-dsh Worker git)\n')
    return 0
  }
  if (command in UNSUPPORTED) {
    throw fatal(
      `git ${command}: unsupported inside the Worker (${UNSUPPORTED[command]}). `
      + 'Nothing was changed. This operation needs host-side git and is not '
      + 'available in this session; the Worker git only runs the commands it implements.',
    )
  }
  output.stderr(`git: '${command}' is not a git command. See 'git --help'.\n`)
  return 1
}

/** Read stdin as NUL-separated paths, git's `-z --stdin` form. */
export function splitNul(input: Uint8Array): string[] {
  const text = new TextDecoder().decode(input)
  return text.split('\0').filter(entry => entry !== '')
}

/** The program's synopsis. */
const USAGE = `usage: git [-C <path>] [-c <name>=<value>] <command> [<args>]

Worker git (phone-dsh phone DSH): isomorphic-git-style porcelain over the
in-memory VFS. Implemented: init, add, status, commit (including --amend),
restore (--staged, --source, pathspecs), log (including --format/--pretty and
-n), config, diff, diff-tree, ls-tree, ls-files, cat-file, write-tree,
rev-parse, check-ignore, branch, tag (list, annotated/lightweight create,
delete), checkout (including checkout -- <paths>),
switch, merge (fast-forward only), clone, fetch, pull, push, remote, show, rm.
Unsupported commands and options fail loud with a message naming the
unsupported word and stating the Worker git's limitation.
`
