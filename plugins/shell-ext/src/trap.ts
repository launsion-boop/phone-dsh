// SPDX-License-Identifier: MIT
/**
 * The Worker shell's minimal, real `trap` builtin.
 *
 * just-bash 3.6.0 knows `trap` as a shell keyword for `type`/`command -v`, but
 * it has no builtin implementation: `trap 'echo bye' EXIT` fell through to the
 * external-command path (`bash: trap: command not found`, 127) and the EXIT
 * action never ran. That made `type trap` a lie and let a silent-degradation
 * scenario pass.
 *
 * This module implements the smallest honest surface the Worker needs:
 *
 * - `trap HANDLER EXIT` / `trap HANDLER 0` stores one EXIT action;
 * - `trap - EXIT` and `trap '' EXIT` remove it;
 * - `trap -p [EXIT]` prints the stored form, `trap` with no arguments does the
 *   same, and `trap -l` lists the supported signal name;
 * - any other signal (`TERM`, `INT`, their numeric spellings, ...) is refused
 *   with status 2 and the `unsupported-option` trailer. The Worker shell does
 *   not deliver asynchronous signals, so pretending to install a TERM handler
 *   would be a fake capability.
 *
 * Handlers live in a module-level map keyed by an opaque token. The production
 * `createWorkerCommands()` table registers the unbound command (a fallback for
 * callers that carry the token themselves); `WorkerShell.execute` replaces that
 * one entry with a per-execute command bound to a fresh token, then runs the
 * EXIT handler against the final result environment in the same filesystem,
 * final cwd and command table, merges its output and keeps the original status
 * (see `shell.ts`). The handler starts with the script's final `$?` and
 * `-e`/`-u`/`-x` state, and remains inside the command's wall clock and abort
 * surface (124/130). The token never enters the engine or exported
 * environment, so it cannot leak into an accelerator's environment hash. The
 * engine also attaches a private shell-scope id to the command context, so
 * entries are keyed by token and scope: a subshell, pipeline child or command
 * substitution can change only its own trap table, and the child entry is
 * discarded with that scope. The token entry is removed afterwards, so one
 * command can never inherit another command's traps.
 *
 * The handler runs as an ordinary shell command after `Bash.exec` returns;
 * it is not a fabricated signal delivery and it deliberately does not run for
 * `bash -n`, a caller abort or a wall-clock timeout.
 * @module @phone-dsh/dsh-shell-ext/trap
 */

import { defineCommand } from 'just-bash/browser'
import type { CustomCommand, ExecResult } from 'just-bash/browser'
import { shellFailure } from './contract.ts'

/**
 * Environment variable a *standalone* command table can use to carry the trap
 * state token.
 *
 * It is only a compatibility fallback for an unbound {@link createTrapCommand}:
 * `WorkerShell` binds the token directly in the command closure instead and
 * never publishes this variable, so it cannot reach a host accelerator or a
 * child process.
 */
export const TRAP_TOKEN_ENV = 'PDSH_SHELL_TRAP_TOKEN'

/** Marker that identifies the shell's own default `trap` command. */
export const DEFAULT_TRAP_COMMAND = Symbol.for('@phone-dsh/dsh-shell-ext/trap/default')

/**
 * True when a command is the shell's default `trap` implementation (rather
 * than a caller-provided shadow). `WorkerShell` uses this to bind that one
 * entry to a per-execute token.
 * @param command - a custom command from the shell table.
 * @returns whether it is the default trap command.
 */
export function isDefaultTrapCommand(command: CustomCommand): boolean {
  return (command as CustomCommand & { readonly [DEFAULT_TRAP_COMMAND]?: boolean })[DEFAULT_TRAP_COMMAND] === true
}

/** The only signal the Worker shell can deliver. */
export const TRAP_EXIT_SIGNAL = 'EXIT'

/**
 * Symbol the patched engine attaches to a custom command's context, naming the
 * real shell scope that is invoking it.
 *
 * The root shell is `root`; every engine subshell, background job and command
 * substitution has its own virtual `BASHPID` and therefore its own value. A
 * function call stays in the current shell scope, matching how `trap` changes
 * the caller's trap table. The value is context-only: it is never written to
 * the environment or any user-visible stream.
 */
export const TRAP_SCOPE_SYMBOL: unique symbol = Symbol.for('@phone-dsh/just-bash/trap-scope/v1')

/** The scope id of the command's root shell. */
const ROOT_TRAP_SCOPE = 'root'

/** Trap handlers installed by one execution and shell scope. */
const TRAPS = new Map<string, Map<string, string>>()

/** The private map key for one execution token and shell scope. */
function trapStateKey(token: string, scope: string): string {
  return `${token}\u0000${scope}`
}

/** Read the invoking shell scope from a command context. */
function contextScope(ctx: object): string {
  const value = (ctx as Record<symbol, unknown>)[TRAP_SCOPE_SYMBOL]
  return typeof value === 'string' && value.length > 0 ? value : ROOT_TRAP_SCOPE
}

/** Monotonic part of the per-execute token. */
let trapSequence = 0

/**
 * Create a token unique to one `WorkerShell.execute` call.
 * @returns an opaque token used only as an in-process closure key.
 */
export function createTrapToken(): string {
  trapSequence += 1
  return `${Date.now().toString(36)}-${trapSequence.toString(36)}-${Math.random().toString(36).slice(2)}`
}

/** The trap map for a token and scope, if it has one. */
function tokenTraps(token: string | undefined, scope: string): Map<string, string> | undefined {
  return token === undefined ? undefined : TRAPS.get(trapStateKey(token, scope))
}

/** Normalise a signal spelling to the one supported name. */
function supportedSignal(spec: string): typeof TRAP_EXIT_SIGNAL | undefined {
  return spec === 'EXIT' || spec === '0' ? TRAP_EXIT_SIGNAL : undefined
}

/**
 * Store one EXIT handler.
 * @param token - per-execute token.
 * @param signal - normalised signal name.
 * @param handler - shell source to run on exit.
 */
export function setTrapHandler(token: string, signal: string, handler: string, scope = ROOT_TRAP_SCOPE): void {
  const key = trapStateKey(token, scope)
  let handlers = TRAPS.get(key)
  if (handlers === undefined) {
    handlers = new Map()
    TRAPS.set(key, handlers)
  }
  handlers.set(signal, handler)
}

/**
 * Read one handler without removing it (the caller may still list it).
 * @param token - per-execute token.
 * @param signal - normalised signal name.
 * @returns the handler, or undefined.
 */
export function getTrapHandler(token: string, signal: string, scope = ROOT_TRAP_SCOPE): string | undefined {
  return tokenTraps(token, scope)?.get(signal)
}

/**
 * Remove one handler (`trap - EXIT` / `trap '' EXIT`).
 * @param token - per-execute token.
 * @param signal - normalised signal name.
 */
export function clearTrapHandler(token: string, signal: string, scope = ROOT_TRAP_SCOPE): void {
  const key = trapStateKey(token, scope)
  const handlers = TRAPS.get(key)
  if (handlers === undefined) return
  handlers.delete(signal)
  if (handlers.size === 0) TRAPS.delete(key)
}

/**
 * List the handlers installed by one execution.
 * @param token - per-execute token.
 * @returns the stored signal/handler pairs.
 */
export function listTrapHandlers(
  token: string,
  scope = ROOT_TRAP_SCOPE,
): { readonly signal: string; readonly handler: string }[] {
  const handlers = TRAPS.get(trapStateKey(token, scope))
  return handlers === undefined
    ? []
    : [...handlers.entries()].map(([signal, handler]) => ({ signal, handler }))
}

/**
 * Drop every handler for one execution.
 *
 * `WorkerShell` calls this after the EXIT handler (or after a non-running
 * path), so the module map cannot grow with finished commands.
 * @param token - per-execute token.
 */
export function clearTrapState(token: string): void {
  const prefix = `${token}\u0000`
  for (const key of [...TRAPS.keys()]) {
    if (key.startsWith(prefix)) TRAPS.delete(key)
  }
}

/** Quote one handler for `trap -p`, the way bash re-emits it. */
function trapQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`
}

/** The `trap -l` body: this shell implements exactly one signal. */
export function trapSignalList(): string {
  return ` 0) ${TRAP_EXIT_SIGNAL}\n`
}

/** A usage error for the minimal surface. */
function trapUsage(message: string): ExecResult {
  return shellFailure('trap', `trap: ${message}`, 'unsupported-option', {
    hint: 'usage: trap [-lp] [[handler] EXIT] (the Worker shell delivers EXIT only)',
  })
}

/** The EXIT-only capability diagnostic. */
function unsupportedSignal(spec: string): ExecResult {
  return shellFailure(
    'trap',
    `trap: ${spec}: only EXIT (or 0) is supported in the Worker shell`,
    'unsupported-option',
    { hint: 'asynchronous signal delivery is not implemented; use an EXIT trap' },
  )
}

/** Resolve the token from the command context. */
function contextToken(ctx: { env?: Map<string, string>; exportedEnv?: Record<string, string> }): string | undefined {
  return ctx.env?.get(TRAP_TOKEN_ENV) ?? ctx.exportedEnv?.[TRAP_TOKEN_ENV]
}

/**
 * Build the `trap` command definition.
 *
 * Registration is what makes `type trap` honest: the engine still answers
 * "shell builtin" (it is a reserved builtin name), and executing `trap` now
 * takes this real, EXIT-only implementation instead of the external-command
 * fallback.
 *
 * A bound token keeps trap state private to one execution without touching the
 * environment. The unbound form (the production-table fallback) reads
 * {@link TRAP_TOKEN_ENV} from the command context instead.
 * @param boundToken - per-execute token, when the caller binds one.
 * @returns the `trap` command.
 */
export function createTrapCommand(boundToken?: string): CustomCommand {
  const command = defineCommand('trap', async (args, ctx): Promise<ExecResult> => {
    let index = 0
    let printMode = false
    while (index < args.length) {
      const word = args[index] as string
      if (word === '--') {
        index += 1
        break
      }
      if (word === '-l') return { stdout: trapSignalList(), stderr: '', exitCode: 0 }
      if (word === '-p') {
        printMode = true
        index += 1
        continue
      }
      if (word.length > 2 && word.startsWith('-') && !word.startsWith('--')) {
        // GNU allows `-lp` and `-pl` in one cluster; only these two flags have
        // a meaning in the Worker surface.
        if ([...word.slice(1)].every(flag => flag === 'l' || flag === 'p')) {
          if ([...word.slice(1)].includes('l')) return { stdout: trapSignalList(), stderr: '', exitCode: 0 }
          printMode = true
          index += 1
          continue
        }
      }
      break
    }
    const rest = args.slice(index)
    const token = boundToken ?? contextToken(ctx)
    const scope = contextScope(ctx)
    const signals = printMode ? rest : rest.slice(1)

    if (printMode) {
      if (signals.length === 0) {
        if (token === undefined) return { stdout: '', stderr: '', exitCode: 0 }
        const lines = listTrapHandlers(token, scope)
          .map(({ signal, handler }) => `trap -- ${trapQuote(handler)} ${signal}\n`)
          .join('')
        return { stdout: lines, stderr: '', exitCode: 0 }
      }
      for (const spec of signals) {
        if (supportedSignal(spec) === undefined) return unsupportedSignal(spec)
      }
      const handler = token === undefined ? undefined : getTrapHandler(token, TRAP_EXIT_SIGNAL, scope)
      return {
        stdout: handler === undefined ? '' : `trap -- ${trapQuote(handler)} ${TRAP_EXIT_SIGNAL}\n`,
        stderr: '',
        exitCode: 0,
      }
    }

    if (rest.length === 0) {
      // Bare `trap` prints every installed trap, like `trap -p`.
      if (token === undefined) return { stdout: '', stderr: '', exitCode: 0 }
      const lines = listTrapHandlers(token, scope)
        .map(({ signal, handler }) => `trap -- ${trapQuote(handler)} ${signal}\n`)
        .join('')
      return { stdout: lines, stderr: '', exitCode: 0 }
    }
    if (signals.length === 0) return trapUsage('missing signal specification')
    // Validate every signal before changing state: `trap x EXIT TERM` must not
    // install EXIT and then fail.
    for (const spec of signals) {
      if (supportedSignal(spec) === undefined) return unsupportedSignal(spec)
    }
    if (token === undefined) {
      return shellFailure('trap', 'trap: trap state is unavailable in this shell', 'backend-failed', {
        hint: 'run trap through WorkerShell.execute',
      })
    }
    const action = rest[0] as string
    for (const spec of signals) {
      const signal = supportedSignal(spec) as string
      if (action === '-' || action === '') clearTrapHandler(token, signal, scope)
      else setTrapHandler(token, signal, action, scope)
    }
    return { stdout: '', stderr: '', exitCode: 0 }
  })
  Object.defineProperty(command, DEFAULT_TRAP_COMMAND, { value: true })
  return command
}
