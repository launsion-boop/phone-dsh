// SPDX-License-Identifier: MIT
/**
 * UTF-8 decoding of the shell's `read` variables.
 *
 * just-bash 3.6.0's `read` builtin copies the standard-input **bytes** into the
 * target shell variables (its internal pipeline currency is a latin1-shaped
 * byte string). Every other command in the engine treats a variable as
 * Unicode text: `echo "$x"` and `printf '%s' "$x"` return text, and a
 * redirection UTF-8-encodes that text on the way to the file. A variable that
 * holds the byte string therefore reaches disk re-encoded:
 *
 * ```
 * printf '王\n' > f; read x < f; echo "$x" > g
 * od -An -tx1 g   # e7 8e 8b (correct) vs c3 a7 c2 8e c2 8b (engine)
 * ```
 *
 * That is the exact byte shape the G2-E03 phone run persisted (`C3A7 C28E
 * C28B`), and it also corrupts a `while read` loop's CJK *file names*: the
 * redirect target `letters/$name.md` is encoded from the same byte string.
 * just-bash is not a `@deepseek-ai/*` package, so this is not a DSH patch; it
 * is the maintained our-layer shim for an upstream decoder gap, and the whole
 * class disappears for every script that uses `read` the same way.
 *
 * ## Why a transform, not a command override
 *
 * Shell builtins are not replaceable by `customCommands` (the engine resolves
 * `read` before the custom table), and a custom command cannot advance the
 * interpreter's stdin cursor (`internalStdinConsumed` is ignored for a
 * redirected `read`), so re-implementing `read` would break `while read`
 * loops. The plugin instead inserts a second, ordinary Worker command after
 * each simple `read` invocation:
 *
 * ```
 * read -r line          ->   read -r line; __xl_utf8_read "$?" line
 * ```
 *
 * The builtin still owns the option grammar, the stdin cursor, backslash
 * handling and IFS field splitting — only its already-assigned variables are
 * decoded once with the shared helper ({@link decodeByteString}). The helper
 * replays `read`'s exit status, so `while read`, `&&`, `||` and `! ` see the
 * same success/failure as before.
 *
 * ## Deliberate limits
 *
 * - `read -a ARRAY` is left alone: array elements live in interpreter state
 *   that a command context cannot read back.
 * - `mapfile`/`readarray` have the same engine byte-in-variable shape, but
 *   their output is an array, not scalar variables; the same array-state limit
 *   applies, so they are outside this shim.
 * - A script that defines a shell function named `read` is left alone, so the
 *   transform cannot rewrite calls to user code.
 * - A `read` word that is not statically known (an expanded name) and a
 *   `read` inside a pipeline stage (not the sole command of the pipeline) are
 *   left alone; they keep the engine behavior instead of acquiring a new one.
 * - A file executed by the `source` builtin is parsed by the engine itself and
 *   is not transformed; `bash -c`, `bash script.sh` and an executable script
 *   run by path (the WorkerShell execution path) are.
 * @module @phone-dsh/dsh-shell-ext/read-encoding
 */

import { defineCommand } from 'just-bash/browser'
import type { CustomCommand, TransformContext, TransformPlugin, TransformResult } from 'just-bash'
import { decodeByteString } from './encoding.ts'

/** Worker-local command that decodes the variables a `read` just assigned. */
export const READ_DECODE_COMMAND = '__xl_utf8_read'

/** Transform plugin name registered with `Bash.registerTransformPlugin`. */
export const READ_DECODE_PLUGIN = 'pdsh-read-utf8'

/** Every short option that consumes a value (`read -d ,` and friends). */
const VALUE_OPTIONS: ReadonlySet<string> = new Set(['d', 'n', 'N', 'p', 't', 'u'])

/** Short options with no argument that the transform can preserve. */
const BARE_OPTIONS: ReadonlySet<string> = new Set(['r', 's', 'e'])

/** A POSIX variable name `read` can assign. */
const VARIABLE_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/u

/** Minimal structural view of the just-bash AST nodes this plugin edits. */
interface NodeLike {
  type: string
  [key: string]: unknown
}

interface StatementLike extends NodeLike {
  pipelines: PipelineLike[]
  operators?: string[]
}

interface PipelineLike extends NodeLike {
  commands: CommandLike[]
  negated?: boolean
  timed?: boolean
  timePosix?: boolean
}

interface CommandLike extends NodeLike {
  name?: WordLike | null
  args?: WordLike[]
  redirections?: { target?: NodeLike }[]
}

interface WordLike extends NodeLike {
  parts?: WordPartLike[]
}

interface WordPartLike extends NodeLike {
  value?: string
  parts?: WordPartLike[]
  body?: NodeLike
}

/** The literal text of a word, or undefined when any part is dynamic. */
function literalWord(word: WordLike | null | undefined): string | undefined {
  if (word === null || word === undefined) return undefined
  let text = ''
  for (const part of word.parts ?? []) {
    if (part.type === 'DoubleQuoted') {
      const inner = literalWord({ type: 'Word', parts: part.parts ?? [] })
      if (inner === undefined) return undefined
      text += inner
      continue
    }
    if (part.type !== 'Literal' && part.type !== 'SingleQuoted' && part.type !== 'Escaped') return undefined
    if (typeof part.value !== 'string') return undefined
    text += part.value
  }
  return text
}

/**
 * Parse a statically-known `read` argv into its target variable names.
 *
 * The option grammar mirrors the builtin closely enough to decide whether the
 * names are literal: a word that is not an option is a target, `--` ends the
 * option list, and a value-taking short option consumes the rest of its word
 * or the following word. Anything this parser cannot prove (`-a`, an unknown
 * option, a dynamic word) makes the whole invocation ineligible.
 * @param argv - `read` arguments with the program name removed.
 * @returns the target names (empty means REPLY), or undefined when ineligible.
 */
export function readTargetNames(argv: readonly string[]): string[] | undefined {
  const names: string[] = []
  let options = true
  let index = 0
  while (index < argv.length) {
    const word = argv[index] as string
    index += 1
    if (!options || !word.startsWith('-') || word === '-') {
      names.push(word)
      continue
    }
    if (word === '--') {
      options = false
      continue
    }
    let offset = 1
    while (offset < word.length) {
      const flag = word[offset] as string
      if (BARE_OPTIONS.has(flag)) {
        offset += 1
        continue
      }
      if (flag === 'a') return undefined
      if (!VALUE_OPTIONS.has(flag)) return undefined
      // A value-taking option consumes the rest of this word, else the next.
      if (offset + 1 >= word.length) index += 1
      offset = word.length
    }
  }
  if (names.some(name => !VARIABLE_NAME.test(name))) return undefined
  return names
}

/** One `<Word>` node built from a literal string. */
function literalWordNode(value: string): WordLike {
  return { type: 'Word', parts: [{ type: 'Literal', value }] }
}

/** One `<Word>` node that is the quoted value `value`. */
function quotedWordNode(value: string): WordLike {
  return { type: 'Word', parts: [{ type: 'SingleQuoted', value }] }
}

/** The `<Word>` node that expands `$?`. */
function lastStatusWord(): WordLike {
  return { type: 'Word', parts: [{ type: 'ParameterExpansion', parameter: '?', operation: null }] }
}

/** The helper command that decodes the variables of one `read` invocation. */
function decodeCommand(names: readonly string[]): CommandLike {
  return {
    type: 'SimpleCommand',
    assignments: [],
    name: literalWordNode(READ_DECODE_COMMAND),
    args: [lastStatusWord(), ...names.map(name => quotedWordNode(name))],
    redirections: [],
  }
}

/** One pipeline wrapping a single command. */
function pipelineOf(command: CommandLike): PipelineLike {
  return { type: 'Pipeline', commands: [command], negated: false }
}

/**
 * True when the statement's sole pipeline is an eligible `read`.
 * @param pipeline - candidate pipeline.
 * @returns the target names, or undefined when the pipeline is not rewritten.
 */
function eligibleRead(pipeline: PipelineLike): string[] | undefined {
  // A negated pipeline (`! read ...`) is eligible: `$?` already carries the
  // inverted status when the helper runs, so replaying it keeps the statement's
  // status (and a `while ! read` condition) exactly as before.
  if (pipeline.commands.length !== 1) return undefined
  const command = pipeline.commands[0] as CommandLike
  if (command.type !== 'SimpleCommand') return undefined
  if (literalWord(command.name) !== 'read') return undefined
  const argv: string[] = []
  for (const argument of command.args ?? []) {
    const text = literalWord(argument)
    if (text === undefined) return undefined
    argv.push(text)
  }
  return readTargetNames(argv)
}

/**
 * Rewrite one statement, splitting each unconditional `read` in two pipelines.
 *
 * A pipeline reached only through `&&`/`||` can be skipped by an earlier
 * failure/success; inserting an unconditional decode after it would decode a
 * variable that `read` never assigned (and could double-decode a previous
 * value). Only a `read` whose preceding operators are all `;` is guaranteed to
 * run, so only that one is rewritten. The inserted `;` keeps the statement's
 * status equal to the helper's, which replays `read`'s status, so `while read`,
 * `&&`, `||` and `!` observe the same control flow as before.
 * @param statement - statement to rewrite in place.
 */
function rewriteStatement(statement: StatementLike): void {
  const originalOperators = statement.operators ?? []
  const pipelines: PipelineLike[] = []
  const operators: string[] = []
  let unconditional = true
  statement.pipelines.forEach((pipeline, index) => {
    if (index > 0) {
      const operator = originalOperators[index - 1] ?? ';'
      operators.push(operator)
      if (operator !== ';') unconditional = false
    }
    pipelines.push(pipeline)
    if (!unconditional) return
    const names = eligibleRead(pipeline)
    if (names === undefined) return
    operators.push(';')
    pipelines.push(pipelineOf(decodeCommand(names)))
  })
  statement.pipelines = pipelines
  statement.operators = operators
}

/** True when the script defines a shell function named `read`. */
function definesReadFunction(node: unknown): boolean {
  if (Array.isArray(node)) return node.some(item => definesReadFunction(item))
  if (typeof node !== 'object' || node === null) return false
  const typed = node as NodeLike
  if (typed.type === 'FunctionDef' && typed.name === 'read') return true
  for (const key of Object.keys(typed)) {
    if (key === 'type') continue
    if (definesReadFunction((typed as Record<string, unknown>)[key])) return true
  }
  return false
}

/** Rewrite every statement in the tree, without touching arithmetic or spans. */
function rewriteTree(node: unknown): void {
  if (Array.isArray(node)) {
    for (const item of node) rewriteTree(item)
    return
  }
  if (typeof node !== 'object' || node === null) return
  const typed = node as NodeLike
  if (typed.type === 'Statement') {
    rewriteStatement(typed as StatementLike)
  }
  for (const key of Object.keys(typed)) {
    if (key === 'type' || key === 'sourceText') continue
    rewriteTree((typed as Record<string, unknown>)[key])
  }
}

/**
 * Build the Worker-local command that decodes one `read`'s variables.
 *
 * The command never reads stdin and never writes output: it maps each target
 * variable's byte string to text exactly once and replays the status it was
 * given. `assignShellVariable` is the interpreter's own assignment gateway
 * (the same one `printf -v` uses), so `declare`, readonly and array rules keep
 * working; a context without that gateway falls back to the shared env map.
 * @returns the command definition.
 */
export function createReadDecodeCommand(): CustomCommand {
  return defineCommand(READ_DECODE_COMMAND, async (args, ctx) => {
    const status = Number.parseInt(args[0] ?? '', 10)
    // 0 = data read, 1 = EOF: both paths assign the targets. A larger status
    // is a usage/timeout failure where the engine may not have written them,
    // so decoding (and possibly double-decoding a previous value) is skipped.
    if (!(status === 0 || status === 1)) {
      return { stdout: '', stderr: '', exitCode: Number.isInteger(status) ? status : 0 }
    }
    const names = args.length > 1 ? args.slice(1) : ['REPLY']
    for (const name of names) {
      if (!VARIABLE_NAME.test(name)) continue
      const current = ctx.env?.get(name)
      if (current === undefined) continue
      const decoded = decodeByteString(current)
      if (decoded === current) continue
      if (ctx.assignShellVariable !== undefined) await ctx.assignShellVariable(name, decoded)
      else ctx.env?.set(name, decoded)
    }
    return { stdout: '', stderr: '', exitCode: Number.isInteger(status) ? status : 0 }
  })
}

/**
 * Build the transform that inserts the decode command after every `read`.
 * @returns the plugin to register with `Bash.registerTransformPlugin`.
 */
export function createReadDecodePlugin(): TransformPlugin {
  return {
    name: READ_DECODE_PLUGIN,
    transform(context: TransformContext): TransformResult {
      const ast = context.ast as unknown as NodeLike
      if (definesReadFunction(ast)) return { ast: context.ast }
      rewriteTree(ast)
      return { ast: context.ast }
    },
  }
}
