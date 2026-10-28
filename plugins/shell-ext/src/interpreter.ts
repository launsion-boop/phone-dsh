// SPDX-License-Identifier: MIT
/**
 * The Worker's `bash`/`sh` invocation surface.
 *
 * just-bash ships a bundled `bash`/`sh` command that understands exactly one
 * option: `-c`. Every other first word is opened as a script filename, so
 * `bash -n script.sh` and `bash --version` answer `-n: No such file or
 * directory` (exit 127), and a script that does run goes through a nested
 * interpreter whose result carries the inner execution's output accounting;
 * the pipeline and redirection layers then reject that accounting with
 * `invalid stdout accounting` (exit 126). The real-model phone batch lost the
 * whole class — `bash script.sh`, `/bin/bash script.sh`, `bash -n`,
 * `bash --version` — and rewrote its own deliverable to the shebang form.
 *
 * This module parses the GNU bash option prefix once, for both the top-level
 * `WorkerShell.run` dispatch and the `bash`/`sh` commands the shell registers,
 * so every invocation form shares one decision:
 *
 * - `-c COMMAND` runs the command string (the pre-existing fast path);
 * - `-n` parses without executing (valid: 0, syntax error: 2);
 * - `-s` reads the script from standard input;
 * - a script operand is resolved (literal path, then `PATH`) and read by the
 *   caller, which runs it through the same top-level execution path as
 *   `bash -c`;
 * - `--version` prints one version line and `--help` the usage;
 * - `--` ends option parsing, `-l` is accepted for login-shell compatibility
 *   (the Worker has no profile files);
 * - every other option fails loud with exit 2 and a precise usage diagnostic.
 *   An option word is never treated as a script filename.
 *
 * The parser is pure: it decides *what* to run, never touches the filesystem.
 * `WorkerShell` (shell.ts) executes the plan; the `bash`/`sh` commands below
 * are thin adapters so an invocation inside a `bash -c` script takes the same
 * path as one spawned at the top level.
 * @module @phone-dsh/dsh-shell-ext/interpreter
 */

import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult } from 'just-bash/browser'
import type { ShellRunOptions } from './shell.ts'
import { withOutputAccounting } from './output.ts'
import type { OutputAccounting } from './output.ts'

/** Which shell program the invocation named. */
export type ShellProgram = 'bash' | 'sh'

/**
 * The bash release the pinned engine emulates through `$BASH_VERSION`.
 *
 * just-bash 3.6.0 answers `5.1.0(1)-release` for `$BASH_VERSION`; `bash
 * --version` reports the same number so a script cannot see two versions. The
 * component test compares the two on every run, so an engine upgrade that
 * changes the emulated release fails the gate instead of letting this drift.
 */
export const WORKER_BASH_VERSION = '5.1.0(1)-release'

/** Maximum nested `bash`/`sh` script invocations before the shell fails loud. */
export const MAX_SHELL_NESTING = 64

/** One resolved positional-parameter set: `$0` and `$1...`. */
export interface ShellPositional {
  /** `$0`. */
  readonly name: string
  /** `$1`, `$2`, ... in order. */
  readonly args: readonly string[]
}

/**
 * Interpreter options the Worker shell implements.
 *
 * These are exactly the `set` flags GNU bash accepts on the invocation line
 * and exposes through `$-`: `-e` (errexit), `-u` (nounset) and `-x` (xtrace).
 * They are executed by the engine's own `set` implementation, not guessed at
 * here (see {@link shellOptionPrelude}).
 */
export interface ShellOptions {
  readonly errexit: boolean
  readonly nounset: boolean
  readonly xtrace: boolean
}

/** No invocation-line options (the default for a plain `bash SCRIPT`). */
export const DEFAULT_SHELL_OPTIONS: ShellOptions = Object.freeze({
  errexit: false,
  nounset: false,
  xtrace: false,
})

/** The one `set` line that applies {@link ShellOptions}, or the empty string. */
export function shellOptionPrelude(options: ShellOptions): string {
  const flags = `${options.errexit ? 'e' : ''}${options.nounset ? 'u' : ''}${options.xtrace ? 'x' : ''}`
  return flags === '' ? '' : `set -${flags}\n`
}

/** What one `bash`/`sh` argv asks the shell to do. */
export type ShellPlan =
  | { readonly kind: 'version'; readonly program: ShellProgram }
  | { readonly kind: 'help'; readonly program: ShellProgram }
  | { readonly kind: 'usage'; readonly program: ShellProgram; readonly message: string }
  | {
    readonly kind: 'command'
    readonly program: ShellProgram
    readonly script: string
    readonly positional: ShellPositional
    readonly options: ShellOptions
  }
  | {
    readonly kind: 'script'
    readonly program: ShellProgram
    readonly path: string
    readonly args: readonly string[]
    readonly options: ShellOptions
  }
  | {
    readonly kind: 'stdin'
    readonly program: ShellProgram
    readonly positional: ShellPositional
    readonly options: ShellOptions
  }
  | {
    readonly kind: 'check-command'
    readonly program: ShellProgram
    readonly script: string
    readonly name: string
    readonly options: ShellOptions
  }
  | {
    readonly kind: 'check-script'
    readonly program: ShellProgram
    readonly path: string
    readonly options: ShellOptions
  }
  | { readonly kind: 'check-stdin'; readonly program: ShellProgram; readonly options: ShellOptions }

/** Result shape an invocation plan runner returns. */
export interface ShellInvocationResult {
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
  /** Trusted producer-owned truncation facts from the nested shell. */
  readonly outputAccounting?: OutputAccounting | undefined
}

/** The shell methods the `bash`/`sh` commands call back into. */
export interface ShellInvocationHost {
  /**
   * Execute one parsed invocation in this shell.
   * @param plan - the parsed argv.
   * @param options - cwd, environment, stdin, signal and limits.
   * @returns the bounded command result.
   */
  runInvocation(plan: ShellPlan, options: ShellRunOptions): Promise<ShellInvocationResult>
}

/** The `bash`/`sh` diagnostic prefix (the invoked program's own name). */
function programPrefix(program: ShellProgram): string {
  return program
}

/**
 * The `bash`/`sh` program name an argv[0] names, if any.
 *
 * Absolute path spellings are accepted (`/bin/bash`, `/usr/bin/sh`, the
 * materialised `/usr/bin/bash` entry `command -v bash` answers) because the
 * Worker command table serves the same shell core for each of them. A path
 * whose basename merely contains the word does not match.
 * @param program - argv[0].
 * @returns `bash`, `sh`, or undefined.
 */
export function shellProgramFor(program: string): ShellProgram | undefined {
  const bare = program.slice(program.lastIndexOf('/') + 1)
  return bare === 'bash' || bare === 'sh' ? bare : undefined
}

/**
 * True when argv names a `bash`/`sh` invocation, including path spellings.
 * @param argv - program and arguments.
 * @returns whether the shell core owns this argv.
 */
export function isShellInvocation(argv: readonly string[]): boolean {
  const program = argv[0]
  return program !== undefined && shellProgramFor(program) !== undefined
}

/** Environment entries that make `$0`, `$#`, `$@`, `$*` and `$1...` visible. */
export function positionalEnvironment(positional: ShellPositional): Record<string, string> {
  const joined = positional.args.join(' ')
  const env: Record<string, string> = {
    '0': positional.name,
    '#': String(positional.args.length),
    '@': joined,
    '*': joined,
  }
  positional.args.forEach((argument, index) => {
    env[String(index + 1)] = argument
  })
  return env
}

/** Usage text for `bash --help` / `sh --help`. */
export function shellUsage(program: ShellProgram): string {
  const name = programPrefix(program)
  return `Usage: ${name} [OPTIONS] [SCRIPT_FILE] [ARGUMENTS...]
Run SCRIPT_FILE, a -c command string or standard input in the Worker shell.

Options:
  -c COMMAND   execute COMMAND string
  -e           exit immediately when a command fails (set -e)
  -u           treat unset variables as an error (set -u)
  -x           trace executed commands (set -x)
  -n           read commands but do not execute them (syntax check)
  -s           read commands from standard input
  -l           accepted for login-shell compatibility (no profile is read)
      --help    display this help and exit
      --version output version information and exit

Options outside this list fail with a usage diagnostic; an option word is
never treated as a script filename.
`
}

/** The one line `bash --version` prints. */
export function shellVersion(program: ShellProgram): string {
  return `${programPrefix(program)} ${WORKER_BASH_VERSION} (xl Worker shell; just-bash engine)\n`
}

/**
 * One usage diagnostic for an option this layer does not implement.
 * @param program - invoked program name.
 * @param message - precise cause, without the program prefix.
 * @returns the usage plan.
 */
function usagePlan(program: ShellProgram, message: string): ShellPlan {
  return { kind: 'usage', program, message }
}

/**
 * Parse one `bash`/`sh` argv.
 *
 * GNU semantics the parser keeps: option parsing stops at the first operand or
 * at `--`; `-c` consumes the next word as the command string and the words
 * after it are that command's positionals (not options); `-s` reads the script
 * from stdin and the operands become `$1...`; a lone `-` also selects stdin.
 * Short options may be clustered (`-nc`, `-eux`, `-lc`).
 * @param argv - program and arguments.
 * @returns the plan, or undefined when argv does not name `bash`/`sh`.
 */
export function parseShellInvocation(argv: readonly string[]): ShellPlan | undefined {
  const program = argv.length === 0 ? undefined : shellProgramFor(argv[0] as string)
  if (program === undefined) return undefined
  const words = argv.slice(1)
  let noexec = false
  let stdinMode = false
  let command = false
  let errexit = false
  let nounset = false
  let xtrace = false
  let index = 0
  for (; index < words.length; index += 1) {
    const word = words[index] as string
    if (word === '--') {
      index += 1
      break
    }
    if (word === '-') {
      stdinMode = true
      index += 1
      break
    }
    if (word === '--version') return { kind: 'version', program }
    if (word === '--help') return { kind: 'help', program }
    if (word.startsWith('--')) return usagePlan(program, `unrecognized option '${word}'`)
    if (word.startsWith('-') && !word.startsWith('--')) {
      for (const flag of word.slice(1)) {
        if (flag === 'c') command = true
        else if (flag === 'n') noexec = true
        else if (flag === 's') stdinMode = true
        else if (flag === 'e') errexit = true
        else if (flag === 'u') nounset = true
        else if (flag === 'x') xtrace = true
        else if (flag === 'l') {
          // The Worker image has no /etc/profile or ~/.bash_profile; accepting
          // -l keeps `bash -lc` scripts working without pretending to read one.
        } else {
          return usagePlan(program, `invalid option -- '${flag}'`)
        }
      }
      continue
    }
    if (word.startsWith('+') && word !== '+') return usagePlan(program, `unrecognized option '${word}'`)
    break
  }
  const options: ShellOptions = { errexit, nounset, xtrace }
  const operands = words.slice(index)
  if (command) {
    // GNU reads the command string from the first non-option word, so options
    // may follow -c (`bash -nc 'cmd'`, `bash -c -- 'cmd'`); the words after it
    // are $0/$1... and are not parsed as options.
    const script = operands[0]
    if (script === undefined) return usagePlan(program, `-c: option requires an argument`)
    // `bash -c 'echo $1' _ x` sets $0 to `_` and $1 to `x`; with no operand the
    // shell name itself is $0 (GNU's default for bash/sh).
    const positional: ShellPositional = {
      name: operands[1] ?? program,
      args: operands.slice(2),
    }
    return noexec
      ? { kind: 'check-command', program, script, name: program, options }
      : { kind: 'command', program, script, positional, options }
  }
  if (noexec) {
    const script = stdinMode ? undefined : operands[0]
    return script === undefined
      ? { kind: 'check-stdin', program, options }
      : { kind: 'check-script', program, path: script, options }
  }
  if (!stdinMode && operands.length > 0) {
    const [path, ...args] = operands as [string, ...string[]]
    return { kind: 'script', program, path, args, options }
  }
  return { kind: 'stdin', program, positional: { name: program, args: operands }, options }
}

/**
 * The `bash`/`sh` commands: thin adapters from the engine's command table to
 * the same invocation runner the top-level dispatch uses.
 *
 * Registering them is what fixes the class *inside* a `bash -c` script too: a
 * script that calls `bash helper.sh` reaches this command, not the bundled one
 * that treats `helper.sh` as a nested interpreter/option lookup.
 * @param host - the Worker shell that runs the parsed plan.
 * @returns the `bash` and `sh` command definitions.
 */
export function createShellInterpreterCommands(host: ShellInvocationHost): Command[] {
  return [createShellInterpreterCommand('bash', host), createShellInterpreterCommand('sh', host)]
}

/** One command definition bound to its program name. */
function createShellInterpreterCommand(program: ShellProgram, host: ShellInvocationHost): Command {
  return defineCommand(program, async (args, ctx): Promise<ExecResult> => {
    const plan = parseShellInvocation([program, ...args])
    if (plan === undefined) {
      return { stdout: '', stderr: `${program}: internal error: unrecognized shell invocation\n`, exitCode: 1 }
    }
    const result = await host.runInvocation(plan, {
      cwd: ctx.cwd,
      env: ctx.exportedEnv ?? Object.fromEntries(ctx.env),
      // just-bash's ByteString is a latin1-shaped string at runtime; the
      // nested shell receives it verbatim as `stdinKind: 'bytes'`.
      stdin: typeof ctx.stdin === 'string' ? ctx.stdin : '',
      stdinKind: 'bytes',
      ...ctx.signal === undefined ? {} : { signal: ctx.signal },
    })
    return withOutputAccounting(
      { stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode },
      result.outputAccounting,
    )
  })
}
