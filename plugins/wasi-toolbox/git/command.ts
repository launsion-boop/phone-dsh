// SPDX-License-Identifier: MIT
/**
 * The `git` program as the Worker shell command table sees it.
 *
 * `createGitCommand()` returns a just-bash-shaped custom command: the shell
 * calls `execute(args, ctx)` with its cwd, exported environment, stdin and
 * abort signal, and gets back the byte-string outputs it expects. The same
 * object is what `createWorkerCommands` in `@phone-dsh/dsh-shell-ext`
 * appends to the production table (the exact one-line wiring is in the package
 * README; that file is outside this work package's write scope).
 *
 * A toolbox-style descriptor (`createGitToolboxProgram`) is also exported for
 * a table that routes JavaScript programs: it answers `program: 'git'`,
 * carries the description shown by `toolbox.list()`, and runs the same
 * {@link runGit}. The image registers no such table yet (the WASI toolbox's
 * `ToolboxCommand` requires a WebAssembly module); the shell descriptor above
 * is the production route.
 * @module @phone-dsh/dsh-wasi-toolbox/git/command
 */
import { NodeGitFs, decodeText } from './fs.ts'
import type { GitFs } from './fs.ts'
import { runGit } from './cli.ts'
import type { GitRunResult } from './cli.ts'
import type { RemoteTransport } from './http.ts'
// The shell owns the one latin1-shaped byte-string conversion (G2-FIX-43).
// This is a dependency-free leaf module, so importing it here does not pull
// the shell command table into the git program.
import { byteStringOutput, byteStringToBytes, bytesToByteString } from '../../shell-ext/src/encoding.ts'

/** Options shared by the command wrappers. */
export interface GitCommandOptions {
  /** Filesystem; inside the Worker this is the runtime's VFS `node:fs`. */
  readonly fs?: GitFs | undefined
  /** Fetch used for the host `/v1/http` hop (clone/fetch/push). */
  readonly fetch?: typeof fetch | undefined
  /** Explicit smart-HTTP transport (tests); overrides `fetch`. */
  readonly transport?: RemoteTransport | undefined
}

/** The subset of a just-bash command context the git program uses. */
export interface GitShellContext {
  readonly cwd: string
  readonly env?: ReadonlyMap<string, string> | Readonly<Record<string, string>> | undefined
  readonly exportedEnv?: Readonly<Record<string, string>> | undefined
  readonly stdin?: unknown
  readonly signal?: AbortSignal | undefined
}

/** A just-bash compatible custom command. */
export interface GitShellCommand {
  readonly name: 'git'
  readonly description: string
  /**
   * Run one git invocation. `stdout` is a latin1-shaped byte string and the
   * result carries `stdoutKind: 'bytes'`, so a blob, a path with non-ASCII
   * bytes or `cat-file` output reaches a pipe/redirection unchanged; `stderr`
   * is decoded UTF-8 text (G2-FIX-43).
   */
  execute(args: readonly string[], context: GitShellContext): Promise<{
    stdout: string
    stderr: string
    exitCode: number
    stdoutKind?: 'bytes'
    stdoutEncoding?: 'binary'
  }>
}

/** Environment of a just-bash context as a plain record. */
export function shellEnvironment(context: GitShellContext): Record<string, string> {
  if (context.exportedEnv !== undefined) return { ...context.exportedEnv }
  if (context.env === undefined) return {}
  if (context.env instanceof Map) return Object.fromEntries(context.env)
  return { ...(context.env as Record<string, string>) }
}

/** Run the git program for a shell invocation and convert its byte output. */
export async function runGitForShell(
  args: readonly string[],
  context: GitShellContext,
  options: GitCommandOptions = {},
): Promise<{ stdout: string; stderr: string; exitCode: number; stdoutKind: 'bytes'; stdoutEncoding: 'binary' }> {
  const stdin = typeof context.stdin === 'string'
    ? byteStringToBytes(context.stdin)
    : context.stdin instanceof Uint8Array ? context.stdin : undefined
  const result: GitRunResult = await runGit(args, {
    fs: options.fs ?? new NodeGitFs(),
    cwd: context.cwd,
    env: shellEnvironment(context),
    ...stdin === undefined ? {} : { stdin },
    ...options.fetch === undefined ? {} : { fetch: options.fetch },
    ...options.transport === undefined ? {} : { transport: options.transport },
  })
  if (context.signal?.aborted === true) {
    return { ...byteStringOutput(''), stderr: 'git: interrupted\n', exitCode: 130 }
  }
  return {
    ...byteStringOutput(bytesToByteString(result.stdout)),
    stderr: decodeText(result.stderr),
    exitCode: result.exitCode,
  }
}

/** Build the `git` custom command for the Worker shell's command table. */
export function createGitCommand(options: GitCommandOptions = {}): GitShellCommand {
  return {
    name: 'git',
    description: 'Git porcelain over the in-memory VFS (isomorphic-git surface: the eight DSH workspace-changes subcommands plus status/log/diff/add/commit/checkout/branch/init/clone/fetch/push)',
    async execute(args, context) {
      return await runGitForShell(args, context, options)
    },
  }
}

/** The shape the WASI toolbox's routing table records. */
export interface GitToolboxProgram {
  readonly program: 'git'
  readonly aliases: readonly string[]
  readonly description: string
  /** A toolbox-style run request: argv, cwd, env, stdin and output hooks. */
  run(request: {
    readonly argv?: readonly string[]
    readonly cwd?: string
    readonly env?: Readonly<Record<string, string>>
    readonly stdin?: Uint8Array
    readonly signal?: AbortSignal
    readonly onStdout?: (chunk: Uint8Array) => void
    readonly onStderr?: (chunk: Uint8Array) => void
  }): Promise<{ exitCode: number }>
}

/**
 * Build the toolbox descriptor for `git`. The WASI table's `ToolboxCommand`
 * currently requires a `WebAssembly.Module`; `git` is JavaScript, so this
 * descriptor is the routing record a JS-program kind can register. It shares
 * the same `runGit` implementation as the shell command.
 */
export function createGitToolboxProgram(options: GitCommandOptions = {}): GitToolboxProgram {
  return {
    program: 'git',
    aliases: [],
    description: 'Git porcelain over the in-memory VFS',
    async run(request) {
      const result = await runGit(request.argv ?? [], {
        fs: options.fs ?? new NodeGitFs(),
        cwd: request.cwd ?? '/',
        env: request.env ?? {},
        ...request.stdin === undefined ? {} : { stdin: request.stdin },
        ...options.fetch === undefined ? {} : { fetch: options.fetch },
        ...options.transport === undefined ? {} : { transport: options.transport },
      })
      if (result.stdout.byteLength > 0) request.onStdout?.(result.stdout)
      if (result.stderr.byteLength > 0) request.onStderr?.(result.stderr)
      return { exitCode: result.exitCode }
    },
  }
}

/** A registry any command table can expose: `register(command)`. */
export interface GitCommandRegistry<T = unknown> {
  register(command: T): void
}

/**
 * Register `git` in a command table that exposes `register(command)`.
 * Returns the command object that was registered.
 */
export function registerGitCommand<T extends { name: string }>(
  registry: GitCommandRegistry<T>,
  options: GitCommandOptions = {},
): T {
  const command = createGitCommand(options) as unknown as T
  registry.register(command)
  return command
}

/** Register the toolbox descriptor in a program table with `register`. */
export function registerGitProgram(
  registry: GitCommandRegistry<GitToolboxProgram>,
  options: GitCommandOptions = {},
): GitToolboxProgram {
  const program = createGitToolboxProgram(options)
  registry.register(program)
  return program
}
