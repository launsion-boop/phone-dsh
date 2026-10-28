// SPDX-License-Identifier: MIT
/**
 * Arithmetic parameter-expansion shim for the Worker shell.
 *
 * just-bash 3.6.0 parses `$(( ))` and `(( ))` into an arithmetic AST. Its
 * `ArithBracedExpansion` node evaluates through a small helper that only knows
 * the forms `${name}`, `${#name}`, `${!name}` and the default-value operators;
 * every other `${...}` is passed to the variable lookup as a literal name. As
 * a result `${x#0}` and `${clock:0:2}` inside arithmetic reach the nounset
 * check as `x#0` / `clock:0:2`, and `${x}` after a `10#` base prefix is
 * concatenated through that prefix's NaN token (`NaN02`). Both are engine
 * defects, not Worker-script defects, and every script that validates a value
 * this way dies the same way.
 *
 * This module is the maintained shim at our layer (just-bash is not a
 * `@deepseek-ai/*` package, so this is not a DSH patch). It supplies the two
 * arithmetic semantics GNU bash has and the engine does not:
 *
 * 1. **Operand normalisation.** A public `TransformPlugin` rewrites each
 *    arithmetic operand that needs a real parameter expansion into a
 *    temporary shell variable and executes the expansion with the shell's own
 *    normal word-expansion path before the command runs. Base prefixes are
 *    converted by a small Worker-local command (`__xl_arith_base`) so `10#`,
 *    `16#` and dynamic `${base}#` keep bash's numeric meaning.
 * 2. **Nounset fatality.** An `(( ))` arithmetic command catches every
 *    evaluation error as an ordinary command failure (and a `$(( ))` operand
 *    that the rewriter moved into a prelude loses the word-expansion fatality
 *    the same way). GNU bash instead aborts a non-interactive script when an
 *    arithmetic operand names an unset variable under `set -u`; a comparison
 *    therefore never silently continues with a false result. The transform checks the operands the expression
 *    reads (in evaluation order, with assignments tracked) before the command
 *    and exits the shell with the unbound-variable diagnostic, which survives
 *    the compound-command nesting where the engine would downgrade the error
 *    to a command failure. Non-nounset arithmetic errors (division by zero,
 *    bad base digits, syntax) keep the engine's non-fatal command behaviour,
 *    exactly like bash.
 *
 * No scenario, script or file name is special-cased. Both dispatch forms —
 * `bash -c` and a script file run by path — use the same `WorkerShell` core,
 * so both register this one plugin (`shell.ts` routes executable scripts
 * through the same execution method).
 *
 * The shim is deliberately scoped to what the arithmetic parser loses:
 * - operands written as `${var...}` with any operation other than a plain
 *   name, length or indirection are expanded through bash's parameter
 *   expansion semantics;
 * - a `N#` / `0x` prefix followed by an expansion is evaluated by the helper;
 * - arithmetic text that contains neither is not touched, so the engine's
 *   existing pre-expansion path for `$x` remains in charge.
 *
 * Known limitation: a C-style `for ((...; ...; ...))` evaluates its
 * expressions inside the loop node, so this statement-level insertion cannot
 * recompute a dynamic operand before every condition/update; that form keeps
 * the engine's pre-fix behavior.
 *
 * @module @phone-dsh/dsh-shell-ext/arithmetic
 */

import type { TransformContext, TransformPlugin, TransformResult } from 'just-bash'
import type { CustomCommand } from 'just-bash'
import { defineCommand } from 'just-bash/browser'

/** Worker-local command that converts a `base#digits` operand to decimal. */
export const ARITHMETIC_BASE_COMMAND = '__xl_arith_base'

/** A parsed arithmetic-base operand. */
interface BaseNumber {
  readonly value: number
}

/** Parse bash's `base#digits` value (and the `0x` prefix form). */
function parseArithmeticBase(base: string, digits: string): number | undefined {
  if (base === '0x' || base === '0X') {
    if (!/^[0-9a-fA-F]+$/.test(digits)) return undefined
    const value = Number.parseInt(digits, 16)
    return Number.isSafeInteger(value) ? value : Number.MAX_SAFE_INTEGER
  }
  if (!/^[0-9]{1,2}$/.test(base)) return undefined
  const radix = Number.parseInt(base, 10)
  if (radix < 2 || radix > 64 || digits === '') return undefined
  let value = 0
  for (const character of digits) {
    let digit: number
    if (/[0-9]/.test(character)) digit = character.charCodeAt(0) - 48
    else if (/[a-z]/.test(character)) digit = character.charCodeAt(0) - 97 + 10
    else if (/[A-Z]/.test(character)) digit = character.charCodeAt(0) - 65 + (radix <= 36 ? 10 : 36)
    else if (character === '@') digit = 62
    else if (character === '_') digit = 63
    else return undefined
    if (digit >= radix) return undefined
    value = value * radix + digit
    if (value > Number.MAX_SAFE_INTEGER) return Number.MAX_SAFE_INTEGER
  }
  return value
}

/**
 * The Worker-local base converter used by the arithmetic shim.
 *
 * It is deliberately not part of the user-visible command table: the shell
 * keeps it out of the materialised `PATH`, and the transform only emits it for
 * an arithmetic operand it rewrites.
 */
export function createArithmeticBaseCommand(): CustomCommand {
  return defineCommand(ARITHMETIC_BASE_COMMAND, async (args) => {
    const base = args[0] ?? ''
    const digits = args[1] ?? ''
    const value = parseArithmeticBase(base, digits)
    if (value === undefined) {
      return {
        stdout: '',
        stderr: `bash: ${base}#${digits}: value too great for base\n`,
        exitCode: 1,
      }
    }
    return { stdout: String(value), stderr: '', exitCode: 0 }
  })
}

/** Minimal structural view of the just-bash AST nodes this shim edits. */
interface NodeLike {
  type: string
  [key: string]: unknown
}

interface ScriptLike {
  type: string
  statements: StatementLike[]
}

interface StatementLike {
  type: string
  pipelines: PipelineLike[]
  operators?: string[]
  background?: boolean
}

interface PipelineLike {
  type: string
  commands: CommandLike[]
  negated?: boolean
  timed?: boolean
  timePosix?: boolean
}

interface CommandLike extends NodeLike {
  line?: number
  assignments?: AssignmentLike[]
  name?: WordLike | null
  args?: WordLike[]
  redirections?: RedirectionLike[]
  expression?: ArithmeticExpressionLike
  clauses?: IfClauseLike[]
  elseBody?: StatementLike[] | null
  words?: WordLike[] | null
  word?: WordLike
  items?: unknown[]
  body?: StatementLike[] | CommandLike
  condition?: StatementLike[]
  init?: ArithmeticExpressionLike | null
  update?: ArithmeticExpressionLike | null
}

interface IfClauseLike {
  condition: StatementLike[]
  body: StatementLike[]
}

interface AssignmentLike {
  value?: WordLike | null
  array?: WordLike[] | null
}

interface RedirectionLike {
  target?: NodeLike
}

interface WordLike extends NodeLike {
  parts?: WordPartLike[]
}

interface WordPartLike extends NodeLike {
  parts?: WordPartLike[]
  expression?: ArithmeticExpressionLike
  body?: ScriptLike
}

interface ArithmeticExpressionLike extends NodeLike {
  expression?: ArithLike
  originalText?: string
}

interface ArithLike extends NodeLike {
  parts?: ArithLike[]
  content?: string
  value?: unknown
  errorToken?: string
  baseExpr?: string
  name?: string
  hasDollarPrefix?: boolean
  operator?: string
  operand?: ArithLike
  left?: ArithLike
  right?: ArithLike
  condition?: ArithLike
  consequent?: ArithLike
  alternate?: ArithLike
  subscript?: ArithLike
  index?: ArithLike
  nameExpr?: ArithLike
  target?: ArithLike
  base?: ArithLike
  prefix?: string
  suffix?: string
  variable?: string
  stringKey?: string
  array?: string
}

/** One deferred shell assignment: `name=valueText`. */
interface Prelude {
  readonly name: string
  readonly valueText: string
}

/** Collects the prelude script for one wrapped command. */
class PreludeCollector {
  private readonly entries: string[] = []
  private readonly checks: string[] = []
  private statusName: string | undefined

  /** True when nothing must run before the command. */
  get empty(): boolean {
    return this.entries.length === 0 && this.checks.length === 0 && this.statusName === undefined
  }

  /** Add one `name=value` assignment. */
  add(prelude: Prelude): void {
    this.entries.push(`${prelude.name}=${prelude.valueText}`)
  }

  /**
   * Add the arithmetic operands whose unset state aborts a bash script under
   * `set -u`. The check is emitted before the command (see
   * {@link nounsetCheckScript}); without nounset it does nothing.
   */
  addChecks(names: readonly string[]): void {
    for (const name of names) if (!this.checks.includes(name)) this.checks.push(name)
  }

  /** Capture `$?` before any prelude command and return its variable. */
  captureStatus(name: string): string {
    this.statusName ??= name
    return this.statusName
  }

  /**
   * The prelude script handed to one `builtin eval`:
   * `status=$?`, then the nounset check, then the operand-normalisation
   * assignments. `$?` is captured first so a check or assignment cannot
   * overwrite the status an expression reads.
   */
  get script(): string {
    const parts: string[] = []
    if (this.statusName !== undefined) parts.push(`${this.statusName}=$?`)
    if (this.checks.length > 0) parts.push(nounsetCheckScript(this.checks))
    parts.push(...this.entries)
    return parts.join('; ')
  }
}

/** One arithmetic expression being rewritten. */
class ArithmeticRewriter {
  private readonly preludes: Prelude[] = []
  private readonly bases: string[]
  private readonly collector: PreludeCollector
  private readonly nextName: () => string
  private statusWord: string | undefined
  private changed = false

  constructor(
    bases: readonly string[],
    collector: PreludeCollector,
    nextName: () => string,
  ) {
    this.bases = [...bases]
    this.collector = collector
    this.nextName = nextName
  }

  /** True when this expression lost something the engine would mis-evaluate. */
  get didChange(): boolean { return this.changed }

  /** The captured `$?` variable, allocated on first use. */
  private status(): string {
    if (this.statusWord === undefined) this.statusWord = this.collector.captureStatus(this.nextName())
    return this.statusWord
  }

  /** Rewrite the expression and return it (or a replacement node). */
  rewrite(node: ArithLike | undefined): ArithLike | undefined {
    if (node === undefined) return undefined

    if (node.type === 'ArithSpecialVar' && node.name === '?') {
      this.changed = true
      return { type: 'ArithBracedExpansion', content: this.status() }
    }

    if (node.type === 'ArithBracedExpansion') {
      const content = node.content ?? ''
      if (isPlainBracedExpansion(content)) return node
      const name = this.nextName()
      this.preludes.push({ name, valueText: `\${${content}}` })
      this.changed = true
      return { type: 'ArithBracedExpansion', content: name }
    }

    if (node.type === 'ArithConcat') {
      const parts = node.parts ?? []
      const head = parts[0]
      let base: string | undefined
      if (head !== undefined) {
        if (head.type === 'ArithNumber' && Number.isNaN(head.value)) base = this.bases.shift()
        else if (head.type === 'ArithSyntaxError' && /^0[xX]$/u.test(head.errorToken ?? '')) base = head.errorToken
        else if (head.type === 'ArithDynamicBase' && head.value === '') base = `\${${head.baseExpr ?? ''}}`
      }
      if (base !== undefined) {
        let tail = ''
        let renderable = true
        for (const part of parts.slice(1)) {
          const word = renderShellWord(part, () => this.status())
          if (word === undefined) { renderable = false; break }
          tail += word
        }
        if (renderable) {
          const name = this.nextName()
          // `set -f; IFS=` keeps the operand's pattern/substring result one
          // word even when it contains whitespace or glob characters.
          this.preludes.push({ name, valueText: `$(set -f; IFS=; ${ARITHMETIC_BASE_COMMAND} ${base} ${tail})` })
          this.changed = true
          return { type: 'ArithBracedExpansion', content: name }
        }
      }
      node.parts = parts.map(part => this.rewrite(part) as ArithLike)
      return node
    }

    // Every other arithmetic node is a container: binary/unary/ternary,
    // assignments, groups, nested arithmetic, arrays and concat parts.
    for (const key of Object.keys(node)) {
      if (key === 'type' || key === 'originalText') continue
      const value = node[key]
      if (Array.isArray(value)) {
        node[key] = value.map(item => (isNode(item) ? this.rewrite(item as ArithLike) : item))
      } else if (isNode(value)) {
        node[key] = this.rewrite(value as ArithLike)
      }
    }
    return node
  }

  /** Append the collected assignments to the command's collector, in order. */
  commit(): void {
    for (const prelude of this.preludes) this.collector.add(prelude)
  }
}

/** True when a `${...}` is one of the forms just-bash already evaluates. */
function isPlainBracedExpansion(content: string): boolean {
  if (/^[A-Za-z_][A-Za-z0-9_]*$/u.test(content)) return true
  // `${#name}` length and `${!name}` indirection are implemented.
  return content.startsWith('#') || content.startsWith('!')
}

/** The identifier at the start of a `${...}` body (prefix match). */
const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*/u

/** A name a `${...}` may contain: an identifier or a positional parameter. */
const PARAMETER = /^(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+)$/u

/**
 * The variable a `${content}` reads for nounset purposes.
 *
 * The engine's helper evaluates each operator itself; the only operation that
 * makes an unset name safe is the default/assign/alternate/error family
 * (`${x-d}`, `${x:-d}`, `${x:=d}`, `${x:+d}`, `${x:?d}`), so those return
 * `undefined`. Every other operator (`#`, `%`, substring, replacement, length,
 * indirection) reads the name and errors when it is unset, as does a plain
 * `${x}`.
 * @param content - the text between `${` and `}`.
 * @returns the variable name, or undefined when unset is not an error.
 */
function bracedExpansionRead(content: string): string | undefined {
  const offset = content.startsWith('#') || content.startsWith('!') ? 1 : 0
  const match = IDENTIFIER.exec(content.slice(offset))
  if (match === null) return undefined
  const name = match[0]
  const rest = content.slice(offset + name.length)
  if (rest === '') return name
  // `${x[0]}`, `${x[@]}`, `${!x[@]}`: the array/positional base name is the
  // nounset subject; the subscript is handled by the engine.
  if (rest.startsWith('[')) return name
  if (/^:?[-+=?]/u.test(rest)) return undefined
  return name
}

/** Accumulator for {@link arithmeticReads}. */
interface ReadState {
  readonly reads: string[]
  readonly assigned: Set<string>
}

/** Record one nounset-relevant read, in first-read order. */
function recordRead(state: ReadState, name: string | undefined): void {
  if (name === undefined || !PARAMETER.test(name) || state.assigned.has(name)) return
  if (!state.reads.includes(name)) state.reads.push(name)
}

/**
 * The names an arithmetic expression reads before they are definitely
 * assigned, in language evaluation order.
 *
 * `nameText` marks a context where the engine uses a bare `ArithVariable` as
 * literal name text instead of a variable value: the digits of a `10#n`
 * operand and the name-producing side of `$name` assignments
 * (`ArithDynamicAssignment`/`ArithDynamicElement`). Such a bare part is not a
 * read — GNU bash reports `(( 10#n ))` as bad base digits, not as `n: unbound
 * variable`. `nameContext` is the stricter name-building context used for
 * dynamic element names. A read in a short-circuit/ternary branch is still
 * checked because the engine (and bash 3.2) expands the whole arithmetic
 * command's variables before evaluating operators; assignments in such a
 * branch are not definite and are not recorded.
 * @param node - arithmetic AST node.
 * @param state - read/assignment accumulator.
 * @param nameText - whether a bare variable here is literal name text.
 * @param definite - whether assignments here definitely execute.
 * @param nameContext - whether this subtree builds a variable name.
 */
function visitArithmeticReads(
  node: ArithLike | undefined,
  state: ReadState,
  nameText = false,
  definite = true,
  nameContext = false,
): void {
  if (node === undefined) return
  switch (node.type) {
    case 'ArithNumber':
    case 'ArithSingleQuote':
    case 'ArithSyntaxError':
    case 'ArithNumberSubscript':
    case 'ArithDoubleSubscript':
      return
    case 'ArithSpecialVar':
      // `$?`, `$$`, `$#`, `$@`, `$*`, `$-`, `$!`: always set.
      return
    case 'ArithCommandSubst':
      // The command runs in its own subshell; an unset operand inside it
      // aborts that subshell, not this script.
      return
    case 'ArithVariable': {
      const name = node.name
      if (nameContext || nameText) {
        if (node.hasDollarPrefix === true) recordRead(state, name)
        return
      }
      recordRead(state, name)
      return
    }
    case 'ArithBracedExpansion':
      recordRead(state, bracedExpansionRead(node.content ?? ''))
      return
    case 'ArithDynamicBase':
      recordRead(state, bracedExpansionRead(node.baseExpr ?? ''))
      return
    case 'ArithDynamicNumber':
      recordRead(state, bracedExpansionRead(node.prefix ?? ''))
      return
    case 'ArithArrayElement':
      visitArithmeticReads(node.index, state, false, definite, false)
      recordRead(state, node.array)
      return
    case 'ArithDynamicElement':
      visitArithmeticReads(node.nameExpr, state, true, definite, true)
      visitArithmeticReads(node.subscript, state, false, definite, false)
      return
    case 'ArithUnary': {
      if ((node.operator === '++' || node.operator === '--') && node.operand?.type === 'ArithVariable') {
        recordRead(state, node.operand.name)
        if (definite && node.operand.name !== undefined) state.assigned.add(node.operand.name)
        return
      }
      visitArithmeticReads(node.operand, state, nameText, definite, nameContext)
      return
    }
    case 'ArithAssignment': {
      if (node.operator !== '=') recordRead(state, node.variable)
      visitArithmeticReads(node.subscript, state, false, definite, false)
      visitArithmeticReads(node.value as ArithLike | undefined, state, false, definite, false)
      if (definite && node.variable !== undefined) state.assigned.add(node.variable)
      return
    }
    case 'ArithDynamicAssignment':
      visitArithmeticReads(node.target, state, true, definite, true)
      visitArithmeticReads(node.subscript, state, false, definite, false)
      visitArithmeticReads(node.value as ArithLike | undefined, state, false, definite, false)
      return
    case 'ArithBinary': {
      visitArithmeticReads(node.left, state, nameText, definite, nameContext)
      const shortCircuit = node.operator === '&&' || node.operator === '||'
      visitArithmeticReads(node.right, state, nameText, definite && !shortCircuit, nameContext)
      return
    }
    case 'ArithTernary':
      visitArithmeticReads(node.condition, state, nameText, definite, nameContext)
      visitArithmeticReads(node.consequent, state, nameText, false, nameContext)
      visitArithmeticReads(node.alternate, state, nameText, false, nameContext)
      return
    case 'ArithGroup':
    case 'ArithNested':
      visitArithmeticReads(node.expression as ArithLike | undefined, state, nameText, definite, nameContext)
      return
    case 'ArithConcat':
      // Every concat part is name text unless it is written as an expansion:
      // the engine's concat helper returns a bare name literally, so only
      // `$name` / `${...}` actually read a variable.
      for (const part of node.parts ?? []) visitArithmeticReads(part, state, true, definite, nameContext)
      return
    default: {
      // A future engine node: recurse so its reads are still covered, without
      // assuming anything about evaluation order.
      for (const key of Object.keys(node)) {
        if (key === 'type' || key === 'originalText') continue
        const value = node[key]
        if (Array.isArray(value)) {
          for (const item of value) {
            if (isNode(item)) visitArithmeticReads(item as ArithLike, state, false, false, false)
          }
        } else if (isNode(value)) {
          visitArithmeticReads(value as ArithLike, state, false, false, false)
        }
      }
    }
  }
}

/**
 * The nounset-relevant reads of one arithmetic expression (`(( ))` or `$(( ))`).
 * @param node - the arithmetic expression AST.
 * @returns variable names in first-read order.
 */
function arithmeticReads(node: ArithLike | undefined): string[] {
  const state: ReadState = { reads: [], assigned: new Set<string>() }
  visitArithmeticReads(node, state)
  return state.reads
}

/** True when `value` is an AST node object. */
function isNode(value: unknown): value is NodeLike {
  return value !== null && typeof value === 'object' && typeof (value as { type?: unknown }).type === 'string'
}

/** Collect the literal `N#` prefixes that precede an expansion in source text. */
function collectBasePrefixes(text: string | undefined): string[] {
  if (text === undefined) return []
  const bases: string[] = []
  const pattern = /(?:^|[^\w$])([0-9]{1,2})#(?=\$)/gu
  let match: RegExpExecArray | null
  while ((match = pattern.exec(text)) !== null) bases.push(match[1] as string)
  return bases
}

/** Render one arithmetic concat part as the equivalent shell word text. */
function renderShellWord(node: ArithLike, status: () => string): string | undefined {
  switch (node.type) {
    case 'ArithBracedExpansion': return `\${${node.content ?? ''}}`
    case 'ArithVariable': return `\${${node.name ?? ''}}`
    case 'ArithSpecialVar': return node.name === '?' ? `\${${status()}}` : `$${node.name ?? ''}`
    case 'ArithCommandSubst': {
      const command = typeof node.command === 'string' ? node.command : undefined
      return command === undefined ? undefined : `$(${command})`
    }
    case 'ArithNumber': {
      const value = node.value
      return typeof value === 'number' && Number.isFinite(value) ? String(value) : undefined
    }
    case 'ArithConcat': {
      let text = ''
      for (const part of node.parts ?? []) {
        const word = renderShellWord(part, status)
        if (word === undefined) return undefined
        text += word
      }
      return text
    }
    case 'ArithSingleQuote': return typeof node.content === 'string' ? node.content : undefined
    default: return undefined
  }
}

/** True when an arithmetic subtree contains an operand this shim must expand. */
function needsRewrite(node: ArithLike | undefined): boolean {
  if (node === undefined) return false
  if (node.type === 'ArithBracedExpansion') return !isPlainBracedExpansion(node.content ?? '')
  if (node.type === 'ArithConcat') {
    const head = node.parts?.[0]
    if (head !== undefined) {
      if (head.type === 'ArithNumber' && Number.isNaN(head.value)) return true
      if (head.type === 'ArithSyntaxError' && /^0[xX]$/u.test(head.errorToken ?? '')) return true
      if (head.type === 'ArithDynamicBase' && head.value === '') return true
    }
  }
  for (const key of Object.keys(node)) {
    if (key === 'type') continue
    const value = node[key]
    if (Array.isArray(value)) {
      if (value.some(item => isNode(item) && needsRewrite(item as ArithLike))) return true
    } else if (isNode(value) && needsRewrite(value as ArithLike)) {
      return true
    }
  }
  return false
}

/** Build one AST word from parts. */
function word(parts: WordPartLike[]): WordLike {
  return { type: 'Word', parts }
}

/** Build a literal word part. */
function literal(value: string): WordPartLike {
  return { type: 'Literal', value }
}

/** Wrap one command in a Statement node. */
function statement(command: CommandLike): StatementLike {
  return {
    type: 'Statement',
    pipelines: [{ type: 'Pipeline', commands: [command], negated: false, timed: false, timePosix: false }],
    operators: [],
    background: false,
  }
}

/** The `builtin eval '<prelude>'` command the shim runs before a wrapped command. */
function preludeCommand(script: string): CommandLike {
  return {
    type: 'SimpleCommand',
    assignments: [],
    // `builtin` bypasses a script-defined `eval` function as well; the raw
    // prelude text still goes through the normal parser and word expansion.
    name: word([literal('builtin')]),
    args: [word([literal('eval')]), word([{ type: 'DoubleQuoted', parts: [literal(script)] }])],
    redirections: [],
  }
}

/**
 * The nounset check script for one arithmetic expression.
 *
 * It must not *expand* the operand: an expansion error is only fatal at the
 * script boundary that raises it in just-bash 3.6.0, while GNU bash aborts the
 * whole shell (except a subshell) even from an `if` condition or a loop body.
 * `${name+set}` is the unset-safe alternate-value form, `$-` says whether
 * nounset is active, and `exit` propagates through every compound context the
 * way a bash expansion error does. The diagnostic and status mirror the
 * engine's own top-level nounset path (`exit 1`); any non-zero status meets
 * the contract.
 * @param names - variables the expression reads before definite assignment.
 * @returns a self-contained shell script for `builtin eval`.
 */
function nounsetCheckScript(names: readonly string[]): string {
  // `false` before the explicit exit leaves the failed arithmetic
  // statement's own pipeline/status (`[1]`) in the terminal record. Without
  // it, a root EXIT handler would see the previous `PIPESTATUS` (usually
  // `[0]`) while `$?` is already 1, which contradicts GNU bash.
  const checks = names.map(name => (
    `if [ -z "\${${name}+set}" ]; then echo 'bash: ${name}: unbound variable' >&2; false; exit 1; fi`
  ))
  return `case $- in *u*) ${checks.join('; ')} ;; esac`
}

/**
 * Wrap a command in a group whose prelude must succeed first.
 *
 * The `&&` is deliberate: a prelude that fails must skip the command and make
 * the group return that failure. The nounset check exits the shell itself
 * (bash's expansion error is not local to the compound command); the remaining
 * preludes are assignments. A plain `;` would let the command run with an
 * empty operand and turn the error into a zero result.
 */
function groupWithPrelude(command: CommandLike, collector: PreludeCollector): CommandLike {
  return {
    type: 'Group',
    body: [{
      type: 'Statement',
      pipelines: [
        statement(preludeCommand(collector.script)).pipelines[0] as PipelineLike,
        statement(command).pipelines[0] as PipelineLike,
      ],
      operators: ['&&'],
      background: false,
    }],
    redirections: [],
  }
}

/** The AST rewriter behind {@link createArithmeticExpansionPlugin}. */
class ArithmeticExpansionTransform {
  private tempCounter = 0

  processScript(script: ScriptLike | undefined): void {
    if (script?.statements === undefined) return
    for (const statementNode of script.statements) this.processStatement(statementNode)
  }

  private processStatement(statementNode: StatementLike): void {
    for (const pipeline of statementNode.pipelines ?? []) {
      if (pipeline.commands === undefined) continue
      pipeline.commands = pipeline.commands.map(command => this.processCommand(command))
    }
  }

  private processCommand(command: CommandLike): CommandLike {
    const collector = new PreludeCollector()
    this.processCommandHeader(command, collector)

    // Nested statement lists keep their own prelude scope: a loop body must
    // recompute its expansions on every iteration, not once before the loop.
    switch (command.type) {
      case 'If':
        for (const clause of command.clauses ?? []) {
          for (const condition of clause.condition ?? []) this.processStatement(condition)
          for (const body of clause.body ?? []) this.processStatement(body)
        }
        for (const body of command.elseBody ?? []) this.processStatement(body)
        break
      case 'For':
      case 'CStyleFor':
      case 'While':
      case 'Until':
        if (command.type !== 'For' && command.type !== 'CStyleFor') {
          for (const condition of command.condition ?? []) this.processStatement(condition)
        }
        for (const body of command.body as StatementLike[] ?? []) this.processStatement(body)
        break
      case 'Case':
        for (const item of (command.items ?? []) as { body?: StatementLike[] }[]) {
          for (const body of item.body ?? []) this.processStatement(body)
        }
        break
      case 'Subshell':
      case 'Group':
        for (const body of command.body as StatementLike[] ?? []) this.processStatement(body)
        break
      case 'FunctionDef':
        if (isNode(command.body)) command.body = this.processCommand(command.body as CommandLike)
        break
      default:
        break
    }

    return collector.empty ? command : groupWithPrelude(command, collector)
  }

  /** Rewrite a command's own words/expressions, not its nested bodies. */
  private processCommandHeader(command: CommandLike, collector: PreludeCollector): void {
    switch (command.type) {
      case 'SimpleCommand':
        for (const assignment of command.assignments ?? []) {
          if (assignment.value !== null && assignment.value !== undefined) this.processWord(assignment.value, collector)
          for (const value of assignment.array ?? []) this.processWord(value, collector)
        }
        if (command.name !== null && command.name !== undefined) this.processWord(command.name, collector)
        for (const arg of command.args ?? []) this.processWord(arg, collector)
        break
      case 'ArithmeticCommand':
        this.processArithmeticExpression(command.expression, collector)
        break
      case 'ConditionalCommand':
        this.processWordValue(command.expression, collector)
        break
      case 'Case':
        if (command.word !== undefined) this.processWord(command.word, collector)
        for (const item of (command.items ?? []) as { patterns?: WordLike[] }[]) {
          for (const pattern of item.patterns ?? []) this.processWord(pattern, collector)
        }
        break
      case 'For':
        for (const value of command.words ?? []) this.processWord(value, collector)
        break
      default:
        break
    }
    // Redirections are evaluated when the command runs, whichever command
    // kind carries them (function definitions and compound commands too).
    for (const redirection of command.redirections ?? []) this.processRedirection(redirection, collector)
  }

  private processRedirection(redirection: RedirectionLike, collector: PreludeCollector): void {
    const target = redirection.target
    if (target === undefined) return
    if (target.type === 'HereDoc' && target.quoted === true) return
    this.processWordValue(target, collector)
  }

  private processWord(wordNode: WordLike, collector: PreludeCollector): void {
    this.processWordValue(wordNode, collector)
  }

  /** Walk a word (or a nested part) and rewrite its arithmetic expansions. */
  private processWordValue(value: unknown, collector: PreludeCollector): void {
    if (Array.isArray(value)) {
      for (const item of value) this.processWordValue(item, collector)
      return
    }
    if (!isNode(value)) return
    if (value.type === 'ArithmeticExpansion') {
      this.processArithmeticExpression(value.expression as ArithmeticExpressionLike | undefined, collector)
      return
    }
    if (value.type === 'CommandSubstitution' || value.type === 'ProcessSubstitution') {
      this.processScript(value.body as ScriptLike | undefined)
      return
    }
    for (const key of Object.keys(value)) {
      if (key === 'type') continue
      this.processWordValue(value[key], collector)
    }
  }

  private processArithmeticExpression(
    node: ArithmeticExpressionLike | undefined,
    collector: PreludeCollector,
  ): void {
    if (node === undefined || node.expression === undefined) return
    // Read the *source* operands before the rewriter replaces them: the
    // nounset check must name the user variable, never a shim temporary.
    const reads = arithmeticReads(node.expression)
    if (reads.length === 0 && !needsRewrite(node.expression)) return
    const rewriter = new ArithmeticRewriter(
      collectBasePrefixes(node.originalText),
      collector,
      () => `__xl_arith_${this.tempCounter++}`,
    )
    node.expression = rewriter.rewrite(node.expression) as ArithLike
    collector.addChecks(reads)
    // Once our AST carries the expansion result, the engine's own
    // `originalText` re-parse path would overwrite it with the pre-fix text.
    if (rewriter.didChange) delete node.originalText
    rewriter.commit()
  }
}

/**
 * The transform plugin the Worker shell registers on every just-bash instance.
 * @returns a per-shell plugin with a fresh temporary-variable counter.
 */
export function createArithmeticExpansionPlugin(): TransformPlugin {
  const transform = new ArithmeticExpansionTransform()
  return {
    name: 'pdsh-arithmetic-parameter-expansion',
    transform(context: TransformContext): TransformResult {
      transform.processScript(context.ast as unknown as ScriptLike)
      return { ast: context.ast }
    },
  }
}
