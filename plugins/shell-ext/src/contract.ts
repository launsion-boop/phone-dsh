// SPDX-License-Identifier: MIT
/**
 * The Worker command surface's class-level contract.
 *
 * The Worker shell is an assembly: just-bash's engine and built-ins, the
 * shell-ext shadows, the WASI toolbox programs and the Worker `git` program.
 * Before this module the assembly had no contract of its own, so two kinds of
 * silent lie reached the scenarios:
 *
 * 1. a shadowed built-in printed an error or a literal placeholder and still
 *    exited 0 (G2-A05's zero-byte `gzip`, `find -printf '%y'`); and
 * 2. a program the Worker does not serve exited 127 with no statement about
 *    what the Worker *does* provide (G2-A05's `tar`, G2-E09's bare `python`).
 *
 * The contract has three parts, all enforced by the corpus gate
 * (`tools/shell-corpus/contract.mjs`) and the golden vectors:
 *
 * - **Exit taxonomy.** {@link SHELL_REASONS} is the closed set of failure
 *   kinds and {@link SHELL_REASON_EXIT} is the status a pure member of that
 *   kind uses. Data-integrity failures are `exit 1`, usage/unsupported surface
 *   is `exit 2`, an unimplemented program is `127`. A command must never use
 *   `exit 0` together with error output or an empty result for a mode that
 *   promised bytes.
 * - **Stderr trailer.** Every failure this layer produces ends with exactly one
 *   `pdsh-shell: exit=<n> program=<p> reason=<token> hint=<text>` line. The
 *   upstream `tool-bash` merges stderr into the tool result text, so the line
 *   is visible to the model and auditable in the journal without a DSH patch.
 * - **Program availability.** A program the Worker cannot serve names the
 *   capability manifest ({@link SHELL_MANIFEST_PATH}) in its trailer. The
 *   Worker boot entry publishes the full `pdsh-capabilities/1` document from the
 *   real command registry before the first request (`worker-entry`), so the
 *   referent provably exists in the same VFS; the shell only fills the path in
 *   when no boot entry ran and never overwrites an existing manifest
 *   (`capabilities.ts`). `notAvailableTrailer` accepts `null` for a backend
 *   that cannot make the path exist and then names no path at all. The
 *   registry is diagnostic: registering a no-op `Command` for `unzip` would
 *   make `command -v unzip` report a path just-bash cannot execute, which is
 *   the fabricated-path defect of G2-A05, so the not-found path stays a
 *   diagnostic instead of a fake executable.
 *
 * ## Failure classification (the one owner)
 *
 * Before G2-FIX-58 every non-zero result of a Worker program was decorated by
 * the command that failed, with no shared classification rule. `stat` on a
 * missing file (exit 1, its own "No such file or directory") and a genuine
 * codec failure both read `reason=backend-failed`, which told the model the
 * execution backend had broken when the command had simply exited. The
 * three-way distinction that decoration must preserve is:
 *
 * - **`not-available`** — the Worker does not serve this program at all. The
 *   shell could not resolve it; the hint names the capability manifest.
 * - **`command-exited`** — the program *is* a Worker program and it ran. Its
 *   own exit status and stderr are the whole explanation, so the trailer only
 *   records the classification and repeats the status. A command that exits
 *   non-zero with its own stderr is never `backend-failed`.
 * - **`backend-failed`** — the Worker's own execution substrate could not
 *   carry the command: a just-bash built-in or the compression codec is
 *   missing, a toolbox dispatch threw, or the nesting budget was hit. This is
 *   the only class the layer may label on its own behalf.
 *
 * `unsupported-option`, `limit-refused`, `iterations`, `output-truncated` and
 * `network-denied` refine a command-level boundary (a usage surface, a Worker
 * budget, a cut capture, a denied egress route); they never mean "the backend
 * broke". {@link classifyFailure} is the fallback for a result that carries no
 * more specific token and now resolves to `command-exited`; every command that
 * decorates its own failure calls the helpers here instead of writing a
 * trailer by hand, and the filesystem's resource refusals render their line
 * through {@link trailerLine} with `program=vfs` (the sink is not a command,
 * and such a line only ever carries `limit-refused`).
 * @module @phone-dsh/dsh-shell-ext/contract
 */

import type { Command, ExecResult } from 'just-bash/browser'

/**
 * The capability manifest a not-available program's hint points at.
 *
 * The path is a single shared constant: the Worker boot publishes the
 * `pdsh-capabilities/1` document here before the first request, the shell's
 * fallback writes it only when absent (`capabilities.ts`), and every hint is
 * rendered from this constant.
 */
export const SHELL_MANIFEST_PATH = '/dsh/home/capabilities.json'

/** The exact stderr prefix of one contract trailer line. */
export const SHELL_TRAILER_PREFIX = 'pdsh-shell: '

/** Closed set of failure reasons the Worker command surface reports. */
export type ShellReason =
  | 'not-available'
  | 'command-exited'
  | 'unsupported-option'
  | 'limit-refused'
  | 'iterations'
  | 'output-truncated'
  | 'backend-failed'
  | 'network-denied'

/** Every reason token, in taxonomy order (handy for tests and the gate). */
export const SHELL_REASONS: readonly ShellReason[] = Object.freeze([
  'not-available',
  'command-exited',
  'unsupported-option',
  'limit-refused',
  'iterations',
  'output-truncated',
  'backend-failed',
  'network-denied',
])

/**
 * Status a pure member of each reason kind uses.
 *
 * `not-available` is 127 and `unsupported-option` 2 (the shell/usage
 * boundaries). `command-exited` is 1 only as a fallback: the command's own
 * status is authoritative and the caller passes it. `limit-refused`,
 * `iterations`, `output-truncated`, `backend-failed` and `network-denied` keep 1: the
 * command ran (or started) and the data path failed. A command that surfaces
 * curl's own status (7/22/23) keeps that finer code; the reason token remains
 * the contract.
 */
export const SHELL_REASON_EXIT: Readonly<Record<ShellReason, number>> = Object.freeze({
  'not-available': 127,
  'command-exited': 1,
  'unsupported-option': 2,
  'limit-refused': 1,
  'iterations': 1,
  'output-truncated': 1,
  'backend-failed': 1,
  'network-denied': 1,
})

/** One trailer line, split into its fields. */
export interface ShellTrailer {
  /** Final status of the command. */
  readonly exitCode: number
  /** Program identity (bare name; path spells are reduced to their basename). */
  readonly program: string
  /** Taxonomy token. */
  readonly reason: ShellReason
  /** One-line remediation, free text to the end of the line. */
  readonly hint?: string | undefined
}

/** Hints for programs the Worker does not implement but a model may reach for. */
export const UNAVAILABLE_PROGRAMS: Readonly<Record<string, string>> = Object.freeze({
  zip: `no archiver program in the Worker; ${SHELL_MANIFEST_PATH} lists tar/gzip`,
  unzip: `no archiver program in the Worker; ${SHELL_MANIFEST_PATH} lists tar/gzip`,
  '7z': `no archiver program in the Worker; ${SHELL_MANIFEST_PATH} lists tar/gzip`,
  '7za': `no archiver program in the Worker; ${SHELL_MANIFEST_PATH} lists tar/gzip`,
  bzip2: `no bzip2 codec in the Worker; ${SHELL_MANIFEST_PATH} lists gzip`,
  bunzip2: `no bzip2 codec in the Worker; ${SHELL_MANIFEST_PATH} lists gzip`,
  xz: `no xz codec in the Worker; ${SHELL_MANIFEST_PATH} lists gzip`,
  unxz: `no xz codec in the Worker; ${SHELL_MANIFEST_PATH} lists gzip`,
  zstd: `no zstd codec in the Worker; ${SHELL_MANIFEST_PATH} lists gzip`,
  ssh: `no ssh transport in the Worker; only curl reaches /v1/http; see ${SHELL_MANIFEST_PATH}`,
  scp: `no ssh transport in the Worker; only curl reaches /v1/http; see ${SHELL_MANIFEST_PATH}`,
  sftp: `no ssh transport in the Worker; only curl reaches /v1/http; see ${SHELL_MANIFEST_PATH}`,
  rsync: `no rsync transport in the Worker; only curl reaches /v1/http; see ${SHELL_MANIFEST_PATH}`,
  wget: `no wget in the Worker; use curl, which reaches the host /v1/http route; see ${SHELL_MANIFEST_PATH}`,
  nc: `no socket program in the Worker; only curl reaches /v1/http; see ${SHELL_MANIFEST_PATH}`,
  ping: `no socket program in the Worker; only curl reaches /v1/http; see ${SHELL_MANIFEST_PATH}`,
  openssl: `no openssl binary in the Worker; see ${SHELL_MANIFEST_PATH}`,
  make: `no host toolchain in the Worker; see ${SHELL_MANIFEST_PATH}`,
  gcc: `no host toolchain in the Worker; see ${SHELL_MANIFEST_PATH}`,
  cc: `no host toolchain in the Worker; see ${SHELL_MANIFEST_PATH}`,
  clang: `no host toolchain in the Worker; see ${SHELL_MANIFEST_PATH}`,
  python: `python is not a Worker program; python3 comes from the WASI toolbox when the image stages it; see ${SHELL_MANIFEST_PATH}`,
  python3: `python3 comes from the WASI toolbox only when the image stages it; see ${SHELL_MANIFEST_PATH}`,
  pip: `no pip in the Worker; the image's python3 is stdlib-only; see ${SHELL_MANIFEST_PATH}`,
})

/** Escape one literal for a `RegExp` source. */
function literal(pattern: string): string {
  return pattern.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')
}

/**
 * Remove every capability-manifest reference from a hint.
 *
 * Used when the shell could not publish the manifest: a hint may name a path
 * only when that path exists (see {@link unavailableHint}).
 */
function withoutManifestReference(hint: string): string {
  return hint
    .replace(new RegExp(`; ${literal(SHELL_MANIFEST_PATH)} lists `, 'gu'), '; the Worker lists ')
    .replace(new RegExp(`; the capability manifest is ${literal(SHELL_MANIFEST_PATH)}`, 'gu'), '')
    .replace(new RegExp(`; see ${literal(SHELL_MANIFEST_PATH)}`, 'gu'), '')
}

/**
 * The default hint when no program-specific one exists.
 * @param program - program the shell could not resolve.
 * @param manifestPath - the published manifest path, or null when the boot
 *   could not materialise one (then no path is advertised).
 * @returns one-line remediation text.
 */
export function unavailableHint(program: string, manifestPath: string | null = SHELL_MANIFEST_PATH): string {
  const bare = program.slice(program.lastIndexOf('/') + 1)
  const hint = UNAVAILABLE_PROGRAMS[bare] ?? `not a Worker program; the capability manifest is ${SHELL_MANIFEST_PATH}`
  return manifestPath === null ? withoutManifestReference(hint) : hint
}

/** Reduce a program word to the bare identity used in a trailer. */
function bareProgram(program: string): string {
  const bare = program.slice(program.lastIndexOf('/') + 1).trim()
  return bare === '' ? 'bash' : bare.replace(/\s+/gu, '_')
}

/** Collapse a hint to one line and keep the trailer parseable. */
function oneLine(hint: string): string {
  return hint.replace(/[\r\n]+/gu, ' ').trim()
}

/**
 * Render one trailer line (with its terminating newline).
 * @param trailer - fields to render.
 * @returns `pdsh-shell: exit=… program=… reason=…` plus an optional `hint=…`.
 */
export function trailerLine(trailer: ShellTrailer): string {
  const base = `${SHELL_TRAILER_PREFIX}exit=${String(trailer.exitCode)} program=${bareProgram(trailer.program)} reason=${trailer.reason}`
  return trailer.hint === undefined || oneLine(trailer.hint) === ''
    ? `${base}\n`
    : `${base} hint=${oneLine(trailer.hint)}\n`
}

/**
 * True when the text already carries a parseable contract trailer.
 *
 * The `pdsh-shell: ` prefix is also used by filesystem remediation lines
 * (`pdsh-shell: writable roots are ...`), so a plain substring check would
 * suppress the taxonomy trailer exactly when a command failed for two
 * reasons. Only the `exit=/program=/reason=` shape counts here.
 */
export function hasShellTrailer(stderr: string): boolean {
  return stderr.split('\n').some(line => line.startsWith(`${SHELL_TRAILER_PREFIX}exit=`) && parseShellTrailer(line) !== undefined)
}

/**
 * Append a trailer to an existing stream, idempotently.
 *
 * The trailer is always the last line. A stream that does not end in a newline
 * gets one first so the trailer cannot be mistaken for part of the error body.
 * @param stderr - existing stderr text.
 * @param trailer - trailer to append, or undefined to leave the text unchanged.
 * @returns the (possibly unchanged) text.
 */
export function appendShellTrailer(stderr: string, trailer: ShellTrailer | undefined): string {
  if (trailer === undefined || hasShellTrailer(stderr)) return stderr
  const separator = stderr === '' || stderr.endsWith('\n') ? '' : '\n'
  return `${stderr}${separator}${trailerLine(trailer)}`
}

/** Parse one trailer line, or undefined when the line is not one. */
export function parseShellTrailer(line: string): ShellTrailer | undefined {
  const match = /^pdsh-shell: exit=(\d+) program=(\S+) reason=(not-available|command-exited|unsupported-option|limit-refused|iterations|output-truncated|backend-failed|network-denied)(?: hint=(.*))?$/u.exec(line.replace(/\n$/u, ''))
  if (match === null) return undefined
  const reason = match[3] as ShellReason
  return {
    exitCode: Number(match[1]),
    program: match[2] as string,
    reason,
    ...match[4] === undefined ? {} : { hint: match[4] },
  }
}

/**
 * Extract the failing program from just-bash / POSIX-shaped stderr.
 *
 * Handles `bash: name: command not found`, `bash: line 3: name: command not
 * available in browser environments…`, `bash: /usr/bin/x: No such file or
 * directory` and the ordinary `name: message` shape. Returns undefined when
 * the text names nothing.
 * @param stderr - the command's stderr.
 * @param fallback - program to use when the text names one ambiguously.
 * @returns the bare program name, or undefined.
 */
export function extractFailureProgram(stderr: string, fallback?: string): string | undefined {
  const notFound = /^bash: (?:line \d+: )?(.+?): (?:command not found|command not available|No such file or directory)/mu.exec(stderr)
  if (notFound !== null) return bareProgram(notFound[1] as string)
  const prefixed = /^([A-Za-z0-9._+-]+): /mu.exec(stderr)
  if (prefixed !== null) return bareProgram(prefixed[1] as string)
  return fallback === undefined ? undefined : bareProgram(fallback)
}

/** Failure produced by one of this layer's commands, with its trailer. */
export interface ShellFailureOptions {
  /** Status override; defaults to {@link SHELL_REASON_EXIT} for the reason. */
  readonly exitCode?: number | undefined
  /** One-line remediation. */
  readonly hint?: string | undefined
  /** Output already produced before the failure (kept). */
  readonly stdout?: string | undefined
}

/**
 * Build a failing {@link ExecResult} carrying exactly one trailer line.
 * @param program - program identity.
 * @param message - diagnostic body (already prefixed with `program: `).
 * @param reason - taxonomy token.
 * @param options - status override, hint and any stdout produced so far.
 * @returns the command result.
 */
export function shellFailure(
  program: string,
  message: string,
  reason: ShellReason,
  options: ShellFailureOptions = {},
): ExecResult {
  const exitCode = options.exitCode ?? SHELL_REASON_EXIT[reason]
  const body = message === '' || message.endsWith('\n') ? message : `${message}\n`
  return {
    stdout: options.stdout ?? '',
    stderr: appendShellTrailer(body, {
      exitCode,
      program,
      reason,
      ...options.hint === undefined ? {} : { hint: options.hint },
    }),
    exitCode,
  }
}

/**
 * Append a trailer to a command result that already has output.
 * @param result - the result so far.
 * @param program - program identity.
 * @param reason - taxonomy token.
 * @param hint - optional remediation.
 * @returns a copy with the trailer appended (stdout preserved).
 */
export function withShellTrailer(
  result: ExecResult,
  program: string,
  reason: ShellReason,
  hint?: string,
): ExecResult {
  return {
    ...result,
    stderr: appendShellTrailer(result.stderr, {
      exitCode: result.exitCode,
      program,
      reason,
      ...hint === undefined ? {} : { hint },
    }),
  }
}

/**
 * Trailer for a Worker program's own non-zero exit.
 *
 * The command ran and returned this status; its stderr is the explanation.
 * This helper is the only sanctioned way a command decorates its own failure,
 * so no command can choose `backend-failed` for an ordinary exit
 * (see the taxonomy in the module doc).
 * @param result - the command result (stdout preserved).
 * @param program - program identity.
 * @param hint - optional remediation.
 * @returns a copy with the `command-exited` trailer appended.
 */
export function withCommandExit(result: ExecResult, program: string, hint?: string): ExecResult {
  return withShellTrailer(result, program, 'command-exited', hint)
}

/**
 * Wrap one command so every non-zero result carries a trailer.
 *
 * Used for commands implemented outside this module (the Worker `git` program)
 * where adding the line at each return would duplicate the taxonomy.
 * @param command - command to wrap.
 * @param program - program identity for the trailer (defaults to the name).
 * @param classify - reason for the result; defaults to {@link classifyFailure}.
 * @returns the wrapped command.
 */
export function trailerCommand(
  command: Command,
  program: string = command.name,
  classify: (result: ExecResult) => ShellReason = result => classifyFailure(program, result),
): Command {
  return {
    ...command,
    execute: async (args, ctx) => {
      const result = await command.execute(args, ctx)
      if (result.exitCode === 0) return result
      return withShellTrailer(result, program, classify(result))
    },
  }
}

/**
 * Classify an untagged failure from its status and message.
 *
 * This is the fallback owner for a result that did not name its own token
 * (the Worker `git` program is wrapped with it). A program that ran and
 * exited non-zero is `command-exited` — its status and stderr are the
 * explanation — never `backend-failed` (see the taxonomy in the module doc).
 * @param program - program identity (reserved for finer classification).
 * @param result - the command result.
 * @returns the most specific reason the text supports.
 */
export function classifyFailure(program: string, result: Pick<ExecResult, 'exitCode' | 'stderr'>): ShellReason {
  if (result.exitCode === 127) return 'not-available'
  if (result.exitCode === 2) return 'unsupported-option'
  if (/EFBIG|file too large|would exceed|limit exceeded/iu.test(result.stderr)) return 'limit-refused'
  if (/allow-list|network|offline|ENETUNREACH|ECONNREFUSED|EAI_AGAIN|timed? ?out/iu.test(result.stderr)) return 'network-denied'
  void program
  return 'command-exited'
}

/**
 * Trailer for a command-not-found result.
 * @param program - program name the shell could not resolve.
 * @param exitCode - the shell's status (normally 127).
 * @param manifestPath - published capability manifest, or null when the shell
 *   could not materialise one; a null path is never advertised.
 * @returns the trailer.
 */
export function notAvailableTrailer(
  program: string,
  exitCode = 127,
  manifestPath: string | null = SHELL_MANIFEST_PATH,
): ShellTrailer {
  return { exitCode, program, reason: 'not-available', hint: unavailableHint(program, manifestPath) }
}

/**
 * Annotation for a stream cut by the per-stream output cap.
 *
 * A truncated tool result is incomplete: keeping the command's 0 would present
 * a partial page as a complete success. The final status is therefore 1 when
 * the command itself succeeded.
 * @param stdoutTruncated - whether stdout was cut.
 * @param stderrTruncated - whether stderr was cut.
 * @param maxBytes - the cap that was applied, for the hint.
 * @returns `{ trailer, exitCode }` or undefined when nothing was cut.
 */
export function truncationAnnotation(
  stdoutTruncated: boolean,
  stderrTruncated: boolean,
  maxBytes: number,
): { readonly trailer: ShellTrailer; readonly exitCode: number } | undefined {
  if (!stdoutTruncated && !stderrTruncated) return undefined
  const what = stdoutTruncated && stderrTruncated ? 'stdout and stderr' : stdoutTruncated ? 'stdout' : 'stderr'
  return {
    trailer: {
      exitCode: 1,
      program: 'bash',
      reason: 'output-truncated',
      hint: `${what} exceeded ${String(maxBytes)} bytes; narrow the command or raise PDSH_SHELL_MAX_OUTPUT_BYTES`,
    },
    exitCode: 1,
  }
}
