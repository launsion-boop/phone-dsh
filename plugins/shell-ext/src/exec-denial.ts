// SPDX-License-Identifier: MIT
/**
 * One rendering layer for the execution-surface read policy.
 *
 * `channel.md` §VFS makes `/dsh/home/{sessions,storages,tool-journal}/**`
 * DSH-internal: an execution surface receives `EACCES` plus one remediation
 * sentence, and every surface gives the same answer. The policy itself was
 * already owned by `VfsNamespace.execReadDenial`, and the shell adapter exposes
 * it as `VfsFileSystem.execReadDenial`, but each *command* still decided what
 * to print with the refusal:
 *
 * - `cat`, `head`, `tail`, `sort`, `sed`, `awk`, `ln` and the bundled `find`
 *   catch every read failure and print a hardcoded "No such file or directory"
 *   (or their own fixed text), so a denial was reported as absence;
 * - `du`, `od` and `stat -c` map the code correctly to "Permission denied" but
 *   drop the remediation sentence;
 * - `grep`, `awk` and `find` can swallow the failure entirely.
 *
 * Fixing that command by command is the approach that already failed: `ls` was
 * patched and the next fifteen commands were not, and a command added tomorrow
 * would be wrong again. The command cannot be the owner, because the answer is
 * not part of any command's contract — it is a property of the filesystem.
 *
 * This module therefore records the refusal where it happens and renders it
 * once, on the way out:
 *
 * 1. {@link recordExecReadDenial} is called from the per-execution filesystem
 *    wrapper (`guardedFileSystem` in `shell.ts`) for every `IFileSystem` read
 *    that the policy refused — including `exists()`, which answers `false`
 *    instead of throwing and would otherwise hide the denial. Every command,
 *    built-in or custom, reads through that wrapper, so no command can bypass
 *    the record.
 * 2. {@link ExecReadDenialLog.render} runs on the command's final stderr. A
 *    line that already carries the contract's sentence is left alone; a line
 *    whose trailing errno phrase names a refused path has that phrase replaced
 *    by the contract's sentence; a refusal no line mentions gets one appended.
 *    The sentence itself is never rebuilt here — it is the exact string
 *    `VfsNamespace.execReadDenial` produced, so the shell and `python3` cannot
 *    drift apart.
 *
 * The layer is deliberately errno-and-subject based instead of line oriented
 * per program: it never needs to know which command produced the line, only
 * that the line names a path the policy refused.
 * @module @phone-dsh/dsh-shell-ext/exec-denial
 */

import { posix } from 'node:path'
import { WORKER_VFS_NAMESPACE, isWriteDenied } from '../../wasi-toolbox/src/vfs-namespace.ts'

/** One refused read: the virtual path and the contract's `EACCES` sentence. */
export interface ExecReadDenial {
  /** Virtual path the execution surface was refused (as the adapter saw it). */
  readonly path: string
  /** `EACCES: <remediation>` — the exact `VfsNamespace.execReadDenial` text. */
  readonly denial: string
  /**
   * True when a read that should have failed (`open`/`readFile`/`stat`/...)
   * was refused, as opposed to an `exists()` predicate answer. Only a hard
   * refusal that a command swallowed and then reported success over turns its
   * exit status into a failure: `test -e` on a denied path legitimately
   * answers "no", while `awk` silently reading nothing must not exit 0.
   */
  readonly hard: boolean
}

/** The `IFileSystem` members that read bytes or metadata of one path. */
export const EXEC_READ_METHODS: ReadonlySet<string> = new Set([
  'readFile',
  'readFileBytes',
  'readFileBuffer',
  'readFileBufferRange',
  'readdir',
  'readdirWithFileTypes',
  'stat',
  'lstat',
  'readlink',
  'realpath',
  'access',
  'open',
  'opendir',
])

/**
 * The errno phrases just-bash and the Worker commands spell into stderr.
 *
 * Only the phrases a refused read can produce are listed; the line is rewritten
 * only when its subject resolves to a path this execution was actually refused,
 * so a genuine `ENOENT` for a different file keeps its text.
 */
const TRAILING_ERRNO: readonly string[] = Object.freeze([
  'No such file or directory',
  'Permission denied',
  'Not a directory',
  'Is a directory',
])

/** The filesystem face the policy check is asked of. */
interface ExecDenialFace {
  execReadDenial?(path: string): string | undefined
}

/**
 * Record one refused read when the failure is the execution read policy (and
 * not an unrelated `EACCES` such as a real mode-bit refusal).
 *
 * `error` is the rejection a read threw; `exists()` passes `undefined` because
 * it swallows its failure and answers `false`. The refusal sentence comes from
 * the adapter's `execReadDenial`, the one authority `channel.md` §VFS names.
 * @param log - the execution's denial log.
 * @param fs - the filesystem whose policy refused the read.
 * @param path - the path argument the command passed.
 * @param error - the rejection, or undefined for the `exists()` probe.
 * @returns true when a refusal was recorded.
 */
export function recordExecReadDenial(
  log: ExecReadDenialLog,
  fs: unknown,
  path: unknown,
  error?: unknown,
): boolean {
  if (typeof path !== 'string' || !path.startsWith('/')) return false
  if (error !== undefined && (error as { code?: unknown } | null)?.code !== 'EACCES') return false
  const face = fs as ExecDenialFace
  if (typeof face.execReadDenial !== 'function') return false
  let denial: string | undefined
  try {
    denial = face.execReadDenial(path)
  } catch {
    denial = undefined
  }
  if (denial === undefined) return false
  log.record(path, denial, error !== undefined)
  return true
}

/** What the renderer needs to place a refusal on the right stderr line. */
export interface ExecDenialRenderContext {
  /** Working directory the execution started in. */
  readonly cwd: string
  /** Working directories a subject may be relative to (start and terminal). */
  readonly cwds?: readonly string[]
  /** Program name used for a line the command did not print itself. */
  readonly program: string
  /** The shell's path resolver (`IFileSystem.resolvePath`). */
  resolvePath(cwd: string, path: string): string
}

/** The rendering outcome: the rewritten stream and how much was appended. */
export interface ExecDenialRenderResult {
  readonly stderr: string
  /** Refusals no command line mentioned; one line each was appended. */
  readonly appended: number
  /** Appended lines that came from a hard read refusal. */
  readonly appendedHard: number
  /** Refusals a command already spelled correctly (no change made). */
  readonly retained: number
}

/**
 * Accumulates the policy refusals of one shell execution.
 *
 * The log is keyed by virtual path, so a command that probes the same refused
 * path twice (or whose `exists()` and `stat()` both fail) produces one line.
 */
export class ExecReadDenialLog {
  private readonly refusals = new Map<string, { denial: string; hard: boolean }>()

  /** Record one refusal; the first sentence for a path wins, any hard one does. */
  record(path: string, denial: string, hard: boolean): void {
    let canonical: string
    try {
      canonical = posix.normalize(path)
    } catch {
      canonical = path
    }
    const previous = this.refusals.get(canonical)
    if (previous === undefined) this.refusals.set(canonical, { denial, hard })
    else if (hard) previous.hard = true
  }

  /** Refusals in the order they were first seen. */
  entries(): readonly ExecReadDenial[] {
    return [...this.refusals].map(([path, refusal]) => ({ path, ...refusal }))
  }

  /**
   * Render the execution's refusals into its final stderr.
   *
   * Idempotent: a stream that already carries every sentence is returned
   * unchanged, so a nested shell result processed twice cannot gain a second
   * line.
   * @param stderr - the command's assembled (and bounded) stderr.
   * @param context - cwd/program/path-resolution for matching subjects.
   * @returns the rewritten stream and the accounting the caller uses to decide
   *   whether a silent success must become a failure.
   */
  render(stderr: string, context: ExecDenialRenderContext): ExecDenialRenderResult {
    const entries = this.entries()
    if (entries.length === 0) return { stderr, appended: 0, appendedHard: 0, retained: 0 }
    const represented = new Set<string>()
    for (const entry of entries) {
      if (stderr.includes(entry.denial)) represented.add(entry.path)
    }
    const retained = represented.size
    const cwds = context.cwds ?? [context.cwd]
    const lines = stderr.split('\n')
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index] as string
      const split = splitTrailingErrno(line)
      if (split === undefined) continue
      const subjects = candidateSubjects(split.body)
      const entry = entries.find(candidate =>
        !represented.has(candidate.path)
        && subjects.some(subject =>
          subjectNamesPath(subject, candidate.path, cwds, context.resolvePath)),
      )
      if (entry === undefined) continue
      represented.add(entry.path)
      lines[index] = `${split.body}${entry.denial}${split.suffix}`
    }
    let appended = 0
    let appendedHard = 0
    for (const entry of entries) {
      if (represented.has(entry.path)) continue
      // One refused subtree answers once. A failed glob reports the directory
      // it could not list *and* the literal pattern it then handed to the
      // command; those are one refusal, not two, so a path already covered by
      // an ancestor or descendant line is not appended again.
      if (entries.some(other =>
        represented.has(other.path)
        && (namesPathOrChild(other.path, entry.path) || namesPathOrChild(entry.path, other.path)))) {
        represented.add(entry.path)
        continue
      }
      const line = `${context.program}: ${entry.path}: ${entry.denial}`
      // Insert before the empty tail a trailing newline leaves behind, so the
      // appended line stays ahead of the final newline and after every
      // diagnostic the command itself printed.
      if (lines.length > 0 && lines[lines.length - 1] === '') lines.splice(lines.length - 1, 0, line)
      else lines.push(line)
      represented.add(entry.path)
      appended += 1
      if (entry.hard) appendedHard += 1
    }
    if (appended === 0 && retained === entries.length) {
      return { stderr, appended, appendedHard, retained }
    }
    return { stderr: lines.join('\n'), appended, appendedHard, retained }
  }
}

/** One stderr line split into a body and the trailing errno phrase. */
interface SplitErrnoLine {
  /** Everything before the phrase, including the `: ` separator. */
  readonly body: string
  /** Whitespace that trailed the phrase (kept verbatim). */
  readonly suffix: string
}

/**
 * Split a line that ends with a known errno phrase.
 *
 * The phrase is the only part replaced: every command's own prefix
 * (`cat: `, `stat: cannot stat `, `du: cannot access `) stays byte-identical,
 * so the diagnostic still names the program and its verb.
 * @param line - one stderr line, without its newline.
 * @returns the split, or undefined when the line does not end with a phrase.
 */
function splitTrailingErrno(line: string): SplitErrnoLine | undefined {
  const withoutPadding = line.replace(/[ \t]+$/u, '')
  for (const phrase of TRAILING_ERRNO) {
    if (!withoutPadding.endsWith(phrase)) continue
    return {
      body: withoutPadding.slice(0, -phrase.length),
      suffix: line.slice(withoutPadding.length),
    }
  }
  return undefined
}

/**
 * The path-shaped words one diagnostic body contains.
 *
 * Every shape the engine and the Worker commands use puts the operand
 * somewhere in the body: `cat: PATH: phrase`, `stat: cannot stat 'PATH':
 * phrase`, `find: PATH: phrase`, `ln: failed to access 'PATH': phrase`. Rather
 * than parse each program's grammar, the renderer hands every quoted string
 * and every whole word to {@link subjectNamesPath}, which only accepts a word
 * that names a refused path.
 * @param body - the diagnostic without its errno phrase.
 * @returns candidate operand spellings.
 */
function candidateSubjects(body: string): readonly string[] {
  const subjects = new Set<string>()
  for (const match of body.matchAll(/'([^']+)'|"([^"]+)"/gu)) {
    const quoted = match[1] ?? match[2]
    if (quoted !== undefined) subjects.add(quoted)
  }
  for (const word of body.split(/\s+/u)) {
    const cleaned = word.replace(/^[([{]+/u, '').replace(/[)\]},;:]+$/u, '')
    if (cleaned === '' || cleaned === '-') continue
    subjects.add(cleaned)
  }
  return [...subjects]
}

/** Strip the quoting commands put around an operand in a diagnostic. */
function unquote(subject: string): string {
  const trimmed = subject.trim()
  if (trimmed.length >= 2) {
    const first = trimmed[0]
    const last = trimmed[trimmed.length - 1]
    if ((first === "'" && last === "'") || (first === '"' && last === '"')) {
      return trimmed.slice(1, -1)
    }
  }
  return trimmed
}

/**
 * Whether one diagnostic subject names the refused path.
 *
 * A command does not always print the exact path it was refused. Three shapes
 * reach stderr, and all three must be recognised or the layer silently misses
 * the refusal:
 *
 *  - the refused path itself (`stat /dsh/home/sessions`);
 *  - a **glob** that failed to expand (`cat /dsh/home/sessions/*\/x.jsonl`):
 *    the shell expanded the pattern through a refused `readdir`, then handed
 *    the literal pattern to the command, so the printed subject is a
 *    *descendant* of the refused directory;
 *  - a relative spelling of either (`cd /dsh/home && cat sessions/*`).
 *
 * Absolute subjects are normalised and accepted when equal to, or below, the
 * refused path (glob characters are ordinary path bytes here, so a pattern
 * under a refused directory matches its ancestor). A relative subject is
 * resolved against the execution's working directories first. A script may
 * `cd` before reading, so the last resort accepts a relative subject that is a
 * path tail of the refusal (`sessions/project/x` names
 * `/dsh/home/sessions/project/x`); a subject with `..` is never matched by
 * tail because its parent is unknown.
 * @param subject - the path text a command printed.
 * @param path - the refused virtual path.
 * @param cwds - working directories to resolve a relative subject against.
 * @param resolvePath - the shell's resolver.
 * @returns whether the subject names the refusal.
 */
function subjectNamesPath(
  subject: string,
  path: string,
  cwds: readonly string[],
  resolvePath: (cwd: string, path: string) => string,
): boolean {
  const spelling = unquote(subject)
  if (spelling === '' || spelling === '-') return false
  let normalised: string
  try {
    normalised = posix.normalize(spelling)
  } catch {
    return false
  }
  if (namesPathOrChild(normalised, path)) return true
  if (spelling.startsWith('/')) return false
  for (const cwd of cwds) {
    try {
      if (namesPathOrChild(resolvePath(cwd, spelling), path)) return true
    } catch {
      // A resolver that refuses this spelling proves nothing either way.
    }
  }
  if (spelling.startsWith('..') || spelling.includes('/..')) return false
  return namesPathOrChild(`/${normalised}`, path) || path.endsWith(`/${normalised}`)
}

/**
 * Whether `subject` is the refused path or lies below it.
 *
 * Below matters because a denied directory makes a whole subtree unreadable: a
 * command asked for `/dsh/home/sessions/*\/x.jsonl` was refused at
 * `/dsh/home/sessions` and prints the pattern, not the directory. The check is
 * component-wise, so `sessions-archive` is not below `sessions`.
 * @param subject - a canonical absolute path or glob.
 * @param path - the refused virtual path.
 * @returns whether the subject belongs to the refused subtree.
 */
function namesPathOrChild(subject: string, path: string): boolean {
  return subject === path || subject.startsWith(`${path}/`)
}

// ------------------------------------------------------------ write policy

/** One refused write: the virtual path and the contract's full answer. */
export interface ExecWriteDenial {
  /** Virtual path the execution surface was refused (as the adapter saw it). */
  readonly path: string
  /** `EACCES: ...` line plus the shared `pdsh-shell: writable roots are ...` line. */
  readonly denial: string
}

/**
 * Accumulates the write-policy refusals of one shell execution.
 *
 * The write answer has two lines: the node-shaped `EACCES` sentence naming the
 * path, and the one remediation line that lists the writable roots. The first
 * line survives any command's own diagnostic; the second cannot travel in the
 * thrown error because just-bash's error sanitizer rewrites `/home`, `/tmp`
 * and `/etc` inside error text to `<path>` (the roots list would read
 * `/dsh<path>, <path>`). It is therefore rendered here, on the way out, once
 * per execution — the same placement P2 chose for the read policy.
 */
export class ExecWriteDenialLog {
  private readonly refusals = new Map<string, string>()

  /** Record one refusal; the first answer for a path wins. */
  record(path: string, denial: string): void {
    let canonical: string
    try {
      canonical = posix.normalize(path)
    } catch {
      canonical = path
    }
    if (!this.refusals.has(canonical)) this.refusals.set(canonical, denial)
  }

  /** Refusals in the order they were first seen. */
  entries(): readonly ExecWriteDenial[] {
    return [...this.refusals].map(([path, denial]) => ({ path, denial }))
  }

  /**
   * Whether every refusal's own `EACCES` line is already in the stream.
   *
   * False means a command swallowed the failure and printed nothing about it
   * (`rm -rf` on an image directory used to do exactly that); the caller must
   * then refuse to report success over the refusal.
   * @param stderr - the command's assembled stderr.
   * @returns true when each refusal's errno line is present.
   */
  represented(stderr: string): boolean {
    for (const refusal of this.refusals.values()) {
      const errnoLine = refusal.slice(0, refusal.indexOf('\n'))
      if (!stderr.includes(errnoLine)) return false
    }
    return true
  }

  /**
   * The full answer for the first refusal, or undefined when none was seen.
   *
   * Used by the fatal path, where the engine aborted before a command result
   * existed: the caller renders this answer instead of the generic
   * `backend-failed` failure.
   * @returns the first refusal.
   */
  first(): ExecWriteDenial | undefined {
    return this.entries()[0]
  }

  /**
   * Append the shared remediation line when a refusal is not represented yet.
   *
   * Idempotent: a stream that already carries the exact sentence is returned
   * unchanged, so a nested shell result processed twice gains no second line.
   * The sentence itself is the one `VfsNamespace.writableRootsLine` produced;
   * this module never rebuilds it.
   * @param stderr - the command's assembled (and bounded) stderr.
   * @param sentence - the exact `pdsh-shell: writable roots are ...` line.
   * @returns the rewritten stream and the number of appended lines (0 or 1).
   */
  render(stderr: string, sentence: string): { readonly stderr: string; readonly appended: number } {
    if (this.refusals.size === 0) return { stderr, appended: 0 }
    // A command that rendered the thrown error itself has the sentence, but
    // just-bash sanitizes host-looking paths in error text (`/home`, `/tmp`,
    // `/etc` become `<path>`), so the line it printed is the mangled variant.
    // Repair that exact line rather than leaving two versions of the answer.
    const lines = stderr.split('\n')
    let repaired = false
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index] as string
      if (line === sentence) return { stderr, appended: 0 }
      if (line.startsWith('pdsh-shell: writable roots are ')) {
        lines[index] = sentence
        repaired = true
      }
    }
    if (repaired) return { stderr: lines.join('\n'), appended: 0 }
    const body = stderr === '' || stderr.endsWith('\n') ? stderr : `${stderr}\n`
    return { stderr: `${body}${sentence}\n`, appended: 1 }
  }
}

/**
 * Record one refused write when the failure is the execution write policy.
 *
 * The adapter and the namespace wrapper mark their refusals
 * ({@link isWriteDenied}); an ordinary mode-bit `EACCES` inside a writable
 * root is not marked and is left to the command's own diagnostic.
 * @param log - the execution's write-denial log.
 * @param path - the path argument the command passed.
 * @param error - the rejection a mutation threw.
 * @returns true when a refusal was recorded.
 */
export function recordExecWriteDenial(
  log: ExecWriteDenialLog,
  path: unknown,
  error: unknown,
): boolean {
  if (typeof path !== 'string' || !path.startsWith('/')) return false
  if (!isWriteDenied(error)) return false
  const denial = WORKER_VFS_NAMESPACE.writeDenial(path, syscallOf(error) ?? 'open')
  if (denial === undefined) return false
  log.record(path, denial)
  return true
}

/** The node syscall name an adapter error carries, when it has one. */
function syscallOf(error: unknown): string | undefined {
  const syscall = (error as { syscall?: unknown } | null)?.syscall
  return typeof syscall === 'string' && /^[a-z]+$/u.test(syscall) ? syscall : undefined
}
