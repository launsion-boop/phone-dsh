// SPDX-License-Identifier: MIT
/**
 * Worker-side fallback for the execution-surface read policy.
 *
 * `channel.md` §6 makes `/dsh/home/{sessions,storages,tool-journal}/**`
 * DSH-internal. The host accelerator owns the bytes, so its VFS is the
 * authoritative enforcement point (P12 added it in `pdsh-core`). This module is
 * the Worker half of the defence: before an accelerator `EXEC_REQ` leaves the
 * Worker, the argv it carries is checked against the same root table, and a
 * refused read is answered locally with the same `EACCES` sentence — no request
 * is sent, so a host that regresses (or an older host binary) still cannot leak
 * a path the Worker already knows is internal.
 *
 * The sentence and the root table are imported from
 * `@phone-dsh/dsh-wasi-toolbox` rather than restated: `VfsNamespace` is the one
 * authority the contract names, and a second literal here would be the third
 * wording the spec forbids.
 *
 * The scan is deliberately conservative. Only `rg` and `jaq` have path
 * operands worth classifying; for anything else only the cwd is checked. The
 * host layer remains the complete answer, including a directory discovered by
 * `rg`'s own walk — the Worker never sees those names, so it cannot be the
 * authority.
 * @module @phone-dsh/dsh-shell-ext/exec-read-guard
 */

import { posix } from 'node:path'

import type { ExecClient, ExecEvent, ExecRequest, EventStream } from '@phone-dsh/dsh-exec-bridge'
import {
  EXEC_INTERNAL_ROOTS,
  execReadDeniedMessage,
  isWithin,
} from '@phone-dsh/dsh-wasi-toolbox'

/** One refused accelerator read, ready to render and dispatch-free. */
export interface ExecReadRefusal {
  /** The program name the request names (`rg`, `jaq`). */
  readonly program: string
  /** The argv word (or cwd) that named the refused path, as the caller spelled it. */
  readonly operand: string
  /** The canonical guest path that was refused. */
  readonly path: string
  /** The DSH-internal root that contains {@link path}. */
  readonly root: string
  /** `EACCES: <remediation sentence>` — the exact contract text. */
  readonly denial: string
  /** The program's own error exit code: `rg` 2, `jaq` 5. */
  readonly exitCode: number
}

/** Programs whose argv carries path operands this layer can classify. */
const PATH_PROGRAMS = new Set(['rg', 'ripgrep', 'jaq', 'jq'])

/** `rg`'s error exit code (a refused root is an error, not "no match"). */
const RG_EXIT_ERROR = 2

/** `jaq`'s runtime-error exit code. */
const JAQ_EXIT_RUNTIME = 5

/** The refusal message line, in the same shape P2 renders for `cat`/`ls`. */
export function execReadRefusalLine(refusal: ExecReadRefusal): string {
  return `${refusal.program}: ${refusal.operand}: ${refusal.denial}\n`
}

/** Resolve one operand after the request's cwd and normalise it. */
function resolveOperand(cwd: string, operand: string): string {
  if (operand.startsWith('/')) return posix.normalize(operand)
  return posix.normalize(posix.join(cwd, operand))
}

/** The internal root containing `path`, or undefined. */
function rootOf(path: string): string | undefined {
  return EXEC_INTERNAL_ROOTS.find(root => isWithin(root, path))
}

/** One argv scan: the tokens that may name a read, and whether the first is a pattern. */
interface OperandScan {
  /** Positional words plus the values of `--flag=value` and `-fVALUE`. */
  readonly candidates: readonly string[]
  /**
   * True when the first candidate is the pattern (`rg`) or filter (`jaq`),
   * which is not a path. A command that names its pattern/filter through a flag
   * (`rg -e PATTERN`, `jaq -f FILE`) has no positional pattern, so every
   * candidate is an operand.
   */
  readonly firstIsPattern: boolean
}

/**
 * `rg` flags whose value is itself a file the program reads.
 *
 * A value that names DSH-internal state is a read, and a request carrying one
 * has no positional pattern: `--files-from` supplies the patterns.
 */
const RG_PATH_FLAGS = new Set([
  '--file',
  '--files-from',
  '--ignore-file',
  '--regexp',
])

/**
 * Classify `rg` argv into "maybe a path" tokens.
 *
 * Only the shapes that can name a file are collected: positionals, attached
 * short values (`-fFILE`), and `--flag=value`. Whether a token is a pattern is
 * decided by the `--files` / `-e` / `--regexp` / `-f` / `--file` / `--files-from`
 * flags; a mis-classification here can only miss a denial, never invent one,
 * because the host remains authoritative.
 * @param args - argv after `argv[0]`.
 * @returns the candidate operands.
 */
function scanRg(args: readonly string[]): OperandScan {
  const candidates: string[] = []
  let patternDeclared = false
  let filesMode = false
  for (const arg of args) {
    if (arg === '--') continue
    if (arg === '--files') {
      filesMode = true
      continue
    }
    if (arg.startsWith('--')) {
      const equals = arg.indexOf('=')
      if (equals > 0) {
        const name = arg.slice(0, equals)
        if (RG_PATH_FLAGS.has(name)) patternDeclared = true
        candidates.push(arg.slice(equals + 1))
      } else if (RG_PATH_FLAGS.has(arg)) {
        patternDeclared = true
      }
      continue
    }
    if (arg.length > 1 && arg.startsWith('-')) {
      if (arg[1] === 'e' || arg[1] === 'f') patternDeclared = true
      if (arg.length > 2 && arg[1] === 'f') candidates.push(arg.slice(2))
      continue
    }
    candidates.push(arg)
  }
  return { candidates, firstIsPattern: !filesMode && !patternDeclared }
}

/**
 * Classify `jaq` argv into "maybe a path" tokens.
 * @param args - argv after `argv[0]`.
 * @returns the candidate operands.
 */
function scanJaq(args: readonly string[]): OperandScan {
  const candidates: string[] = []
  let filterDeclared = false
  for (const arg of args) {
    if (arg === '--') continue
    if (arg.startsWith('--')) {
      const equals = arg.indexOf('=')
      if (equals > 0) {
        const name = arg.slice(0, equals)
        if (name === '--from-file') filterDeclared = true
        candidates.push(arg.slice(equals + 1))
      } else if (arg === '--from-file') {
        filterDeclared = true
      }
      continue
    }
    if (arg.length > 1 && arg.startsWith('-')) {
      if (arg[1] === 'f') filterDeclared = true
      if (arg.length > 2 && arg[1] === 'f') candidates.push(arg.slice(2))
      continue
    }
    candidates.push(arg)
  }
  return { candidates, firstIsPattern: !filterDeclared }
}

/**
 * The refusal one accelerator request names, before it is dispatched.
 *
 * The cwd is checked first: a shell that `cd`s into internal state and runs
 * `rg PATTERN` with no path operand would otherwise read the whole directory.
 * @param request - the `EXEC_REQ` argv and cwd the Worker is about to send.
 * @returns the refusal, or undefined when the request names no internal state.
 */
export function execReadDenialForRequest(
  request: Pick<ExecRequest, 'argv' | 'cwd'>,
): ExecReadRefusal | undefined {
  const program = posix.basename(request.argv[0] ?? '')
  const cwd = posix.normalize(request.cwd)

  const refusal = (operand: string, path: string, root: string): ExecReadRefusal => ({
    program,
    operand,
    path,
    root,
    denial: `EACCES: ${execReadDeniedMessage(path, root)}`,
    exitCode: program === 'jaq' || program === 'jq' ? JAQ_EXIT_RUNTIME : RG_EXIT_ERROR,
  })

  const cwdRoot = rootOf(cwd)
  if (cwdRoot !== undefined) return refusal(request.cwd, cwd, cwdRoot)

  if (!PATH_PROGRAMS.has(program)) return undefined
  const scan = program === 'jaq' || program === 'jq'
    ? scanJaq(request.argv.slice(1))
    : scanRg(request.argv.slice(1))
  for (const candidate of scan.firstIsPattern ? scan.candidates.slice(1) : scan.candidates) {
    if (candidate === '' || candidate === '-') continue
    const path = resolveOperand(cwd, candidate)
    const root = rootOf(path)
    if (root !== undefined) return refusal(candidate, path, root)
  }
  return undefined
}

/**
 * Wrap an exec client so a refused request never becomes an `EXEC_REQ`.
 *
 * Everything except `exec` is delegated untouched: only the question "may this
 * request read this path" is answered here, and only when the answer is no.
 * @param client - the transport client the Worker would use.
 * @returns the guarded client.
 */
export function guardExecClient(client: ExecClient): ExecClient {
  return {
    hello: signal => client.hello(signal),
    exec: (request, signal) => {
      const refusal = execReadDenialForRequest(request)
      if (refusal === undefined) return client.exec(request, signal)
      return Promise.resolve(refusedExecStream(request.exec_id, refusal))
    },
    events: (execId, afterSeq, signal) => client.events(execId, afterSeq, signal),
    cancel: (execId, body, signal) => client.cancel(execId, body, signal),
    stdin: (execId, body, signal) => client.stdin(execId, body, signal),
    lifecycle: (since, waitMs, signal) => client.lifecycle(since, waitMs, signal),
    destroy: () => client.destroy(),
  }
}

/**
 * A synthetic event stream for a request this Worker refused locally.
 *
 * It has the same shape the transport would produce for a program that ran and
 * failed: one stderr chunk, then one exit with the program's error code, so
 * both `createExecBridgeAccelerators` and `BridgeProcess` render it without a
 * special case.
 * @param execId - the would-be execution id (kept for the event shape).
 * @param refusal - the refusal to print.
 * @returns a one-shot event stream.
 */
export function refusedExecStream(execId: string, refusal: ExecReadRefusal): EventStream {
  const line = execReadRefusalLine(refusal)
  const events: readonly ExecEvent[] = [
    { type: 'start', exec_id: execId, seq: 0 },
    {
      type: 'output',
      exec_id: execId,
      seq: 1,
      stream: 'stderr',
      data: Buffer.from(line, 'utf8').toString('base64'),
    },
    {
      type: 'exit',
      exec_id: execId,
      seq: 2,
      code: refusal.exitCode,
      signal: null,
      status: 'exited',
      quiescent: true,
    },
  ]
  return {
    async *[Symbol.asyncIterator]() {
      for (const event of events) yield event
    },
    close() {},
  }
}
