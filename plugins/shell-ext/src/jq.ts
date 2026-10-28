// SPDX-License-Identifier: MIT
/**
 * The Worker shell's `jq` input-builtin shim (`inputs`, `input`,
 * `input_line_number`).
 *
 * `jq` is a just-bash 3.6.0 built-in (Apache-2.0, imported unmodified). Its
 * evaluator implements a large jq language, but the input-consumption family
 * is missing:
 *
 * - `inputs` and `input` are not functions at all, so
 *   `jq -n '[inputs]' a.json` exits 3 with `Unknown function: inputs` and a
 *   program that reads a stream cannot express it (G2-FIX-130);
 * - `input_line_number` is a stub that always returns `1`, so
 *   `jq 'input_line_number'` on two NDJSON records prints `1` twice instead of
 *   `1` and `2`.
 *
 * This module shadows the built-in through just-bash's custom-command table,
 * the same seam `find.ts`, `grep.ts` and `stat.ts` use. It is deliberately a
 * small wrapper, not a second jq engine:
 *
 * 1. parse the jq argv (filter, stdin/file operands, the option surface jq
 *    documents);
 * 2. if the filter does not contain a bare `inputs` / `input` /
 *    `input_line_number` identifier, delegate the **original** argv to
 *    `ctx.origCommand` unchanged, so every existing jq behaviour is untouched;
 * 3. otherwise read every JSON document the invocation names (stdin or the
 *    file operands) and evaluate the filter once per outer document through
 *    the built-in with `-n` and three injected variables:
 *    `$__pdsh_jq_current` (the current document), `$__pdsh_jq_inputs` (the
 *    documents after it) and `$__pdsh_jq_line` (jq 1.6's `input_line_number`
 *    for the current document).
 *    The filter is rewritten textually — outside string literals and comments,
 *    on identifier boundaries, and recursively inside `\(...)` interpolation
 *    bodies — to `$__pdsh_jq_inputs[]` (`inputs`), `$__pdsh_jq_inputs[0]`
 *    (`input`) and `$__pdsh_jq_line` (`input_line_number`), and is evaluated
 *    as `$__pdsh_jq_current | (<filter>\n)`.
 *
 * ## Outer-cursor semantics
 *
 * Non-`-n` jq runs the filter once per top-level document. For the filters this
 * shim accepts, consumption is unconditional and therefore known exactly:
 * `inputs` consumes the rest of the stream, so the shim evaluates only the
 * first outer document and stops; `input` consumes exactly one following
 * document, so each outer iteration advances the cursor by two; a filter with
 * only `input_line_number` consumes nothing and advances by one. `-n`
 * evaluates the filter once with a `null` current document and every parsed
 * document available to `inputs`.
 *
 * Input-family calls inside object constructors are refused because jq may
 * reevaluate generator-valued entries. Index expressions accept only one
 * scalar input index or slice (for example .[input:2]); index generators are
 * refused. Interpolations accept one bare input/input_line_number body or a
 * liftable whole inputs body, never a multi-value interpolation, and never as
 * a function argument. A consuming `input`/`inputs` passed to a function
 * (`has(inputs)`, `test(input)`) is refused too: a function may evaluate its
 * argument zero or more times, and `inputs` is a generator the built-in would
 * reduce to its first value. `input_line_number` is informational and stays
 * allowed.
 *
 * jq's real cursor is advanced by the *evaluation* of `input`/`inputs`, not by
 * their textual presence. A filter such as `if . == 3 then input else . end`,
 * `select(. > 1) | inputs` or `first(inputs)` consumes a conditionally/lazily
 * determined number of documents. A wrapper that injects an immutable array
 * cannot observe those calls, so the shim refuses those filters (exit 2 with a
 * `jq:` diagnostic) rather than advancing the cursor statically and silently
 * dropping documents. See {@link findUnsafeInputConsumption}.
 *
 * ## Deliberate limits
 *
 * The accepted expression shapes are intentionally narrow: input-family
 * references inside object constructors are refused, as are multi-value
 * index expressions before a consuming call. A scalar input index/slice such
 * as .[input:2] remains supported. A string interpolation may contain only
 * one bare input or input_line_number body; a whole inputs body uses the
 * documented lift, but only outside a function argument, where the built-in
 * would keep just the first generated value. Parse errors use jq 1.6 exit 4
 * while input exhaustion is break exit 5. In -n input_line_number mode, input
 * files are not read.
 *
 * The shim refuses, with exit 2 and a diagnostic, the combinations it cannot
 * keep honest instead of silently repeating or fabricating output:
 *
 * - `-s`/`--slurp` or `-R`/`--raw-input` combined with the input family (the
 *   built-in's slurp/raw pipelines own that reading mode);
 * - `inputs` together with `input` in one filter;
 * - more than one `input` or more than one `inputs` in one filter (each call
 *   advances/consumes, which the per-outer-document loop cannot model);
 * - `input_line_number` together with `input`/`inputs` (the line number after a
 *   consumption is not the current document's line);
 * - a consuming `input`/`inputs` as a function argument (`has(inputs)`,
 *   `test(input)`, `test("\(input)")`): jq may evaluate the argument filter
 *   zero or more times, and a generator argument loses every value after the
 *   first in the built-in. Collect the inputs first (for example `[inputs]`)
 *   or bind the consumed value first. See
 *   {@link findUnsafeInputsValueArgument}.
 * - `inputs` inside a `\(...)` interpolation body unless the body is exactly
 *   `inputs`, it is the string's only interpolation, it is not the format
 *   string of a preceding `@format` (for example `@json "\(inputs)"`), and it
 *   is not a function argument (for example `test("\(inputs)")`).
 *   That form is lifted to `$__pdsh_jq_inputs[] | "\(.)"` so jq's
 *   one-string-per-document generator semantics survive; the built-in
 *   interpolation engine would otherwise join a multi-valued body into one
 *   string. Any other interpolation is refused because lifting would rebind
 *   other `.` expressions to the input document, and a parenthesized generator
 *   is not valid after `@format`;
 * - a filter that defines its own `def`initions while naming the input family
 *   (a user definition can shadow the built-in name);
 * - an empty call argument list (`length()`): jq 1.6 reports a syntax error
 *   there, while the pinned built-in resolves it as arity zero and would turn a
 *   zero-document `-e` compile error into status 0;
 * - an `as`/`label` declaration before the next `|`, across a function's `;`
 *   argument separator, or directly in an object value: these lexical scopes
 *   are not modeled, and jq itself rejects the object-value form. Variable
 *   names must pass jq 1.6's lexer (`$if` and `$1abc` are syntax errors;
 *   `$true`/`$false`/`$null` remain legal IDENTs; `__loc__` cannot be bound);
 * - a label `break` after an earlier output in the label body: the pinned
 *   evaluator drops those values, so only the `then break`/`else break` shape
 *   already checked against native jq is retained;
 * - conditional/lazy/partial/repeated consumption before the input call: `if`,
 *   `select`, `first`, `last`, `limit`, `try`, `?`, `//`, `and`, `or`,
 *   `empty`, `reduce`/`foreach`/`while`/`until`, iterators (`.[]`, `..`),
 *   `sub`/`gsub` (their replacement expression is evaluated zero or more
 *   times) and the other filter-argument builtins listed in
 *   {@link JQ_UNSAFE_INPUT_WORDS}. A comma generator that feeds a pipe into
 *   `input` (for example `(1, 2) | (., input)`) is refused too: later commas
 *   do not make the pipe safe. Any other comma sequence before an `input`
 *   call outside an array/object constructor (`., input`, `1, input`,
 *   `(1, input)`, `1 | ., input`) is refused for the same reason: jq emits the
 *   values produced before the failing `input` and then reports `break`, so a
 *   wrapper that gives up before evaluating the document would silently lose
 *   that prefix. Postfix `?` is refused anywhere because it can turn an
 *   exhausted `input` into an empty result.
 *
 * `input` on an exhausted stream fails with jq's `break` diagnostic and exit
 * 5, like real jq; it never fabricates a `null` document. Multi-file input is
 * flattened across the operand list. Both are recorded in
 * `docs/p1/jq-input-builtins.md`.
 *
 * `-e`/`--exit-status` is computed from the last output across every outer
 * document (truthy -> 0, `false`/`null` -> 1) and is 4 when an evaluated input
 * produced no output, matching jq 1.6. An invocation with no input documents
 * at all is the one exception in jq 1.6: it never enters the filter and exits
 * 0. The pinned built-in only uses "every output was false/null", so
 * forwarding `-e` to it would misreport filters such as `1, false`; the shim
 * strips it from the evaluation options and runs a compact `last(...)` probe
 * per outer document instead.
 *
 * Multiple file operands are parsed as one continuous byte stream, exactly as
 * jq 1.6 concatenates them: a file that ends without a trailing newline can
 * merge its last token with the next file's first token (`1` followed by `2`
 * is the single document `12`, not two documents). `input_line_number` still
 * resets per source; the reported line follows jq 1.6's newline-terminated
 * line count within that source (a document on line 1 with no trailing newline
 * reports `0`, a trailing newline after the document reports the document's end
 * line, and blank lines between documents are counted before the next
 * document). When a primitive token reaches the end of a source, jq reads the
 * next source to find its delimiter, so the line comes from that next source's
 * first 4095-byte read. Operands are joined as raw bytes before UTF-8 decoding
 * (read through the optional `readFileBytes` or the required
 * `readFileBuffer`; the already-decoded `readFile` is never used); a BOM at the
 * start of that stream is skipped while its three bytes remain in
 * the line/source mapping. A BOM after any other stream byte is not skipped,
 * matching native jq's parse error. Invalid UTF-8 is refused with exit 2
 * because jq's U+FFFD replacement boundaries are not claimed byte-exact.
 * @module @phone-dsh/dsh-shell-ext/jq
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, ResolvedCommandContext } from 'just-bash/browser'
import type { WorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'
import {
  byteStringOutput, byteStringToBytes, bytesToByteString, concatBytes, decodeByteString, decodeUtf8, encodeUtf8,
} from './encoding.ts'
import { GNU_CONVENTION_VERSION, scanGnuArgv } from './gnu-conventions.ts'
import { BoundedByteStream, engineStreamLimit } from './stream-budget.ts'
import { JQ_ENGINE_PROGRAM, guestCwdFor } from './toolbox-commands.ts'

/** The input-family functions this shim implements. */
export const JQ_INPUT_FUNCTIONS: readonly string[] = Object.freeze([
  'inputs',
  'input',
  'input_line_number',
])

/**
 * Internal variables injected into the built-in evaluator.
 *
 * The `__pdsh_jq_` prefix is deliberately outside the names jq filters normally
 * bind. A user `--arg`/`--argjson`/`--rawfile`/`--slurpfile` that names one of
 * these variables is refused with a reserved-name diagnostic instead of being
 * silently replaced by the shim's value.
 */
const JQ_INTERNAL_CURRENT = '__pdsh_jq_current'
const JQ_INTERNAL_INPUTS = '__pdsh_jq_inputs'
const JQ_INTERNAL_LINE = '__pdsh_jq_line'
const JQ_INTERNAL_VARIABLES: ReadonlySet<string> = new Set([
  JQ_INTERNAL_CURRENT,
  JQ_INTERNAL_INPUTS,
  JQ_INTERNAL_LINE,
])

/**
 * jq 1.6 tokens that are not identifiers after `$`.
 *
 * jq's lexer rejects `$if`, `$and`, `$or` and the other reserved words with a
 * syntax error; `$true`, `$false` and `$null` are different: the lexer still
 * accepts them as IDENT tokens, so they are legal variable names when bound and
 * merely undefined otherwise.
 */
const JQ_VARIABLE_KEYWORDS: ReadonlySet<string> = new Set([
  'if', 'elif', 'then', 'else', 'end', 'as', 'try', 'catch', 'reduce',
  'foreach', 'label', 'break', 'def', 'import', 'include', 'module', 'and',
  'or',
])

/** jq 1.6's built-in location variable, legal only as a reference. */
const JQ_LOCATION_VARIABLE = '__loc__'

/** True when `name` is a `$name` token jq 1.6's lexer accepts. */
function isJqVariableName(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/u.test(name) && !JQ_VARIABLE_KEYWORDS.has(name)
}

/** True when `name` can appear after `as`/`label` (lexer excludes `__loc__`). */
function isJqBindingName(name: string): boolean {
  return isJqVariableName(name) && name !== JQ_LOCATION_VARIABLE
}

/** jq 1.6 status for malformed JSON input (distinct from compile errors). */
const JQ_PARSE_ERROR_EXIT = 4
/** jq 1.6 status for an exhausted input() call. */
const JQ_BREAK_EXIT = 5
/** Internal status-probe failure; the real filter result is not reclassified. */
const JQ_STATUS_PROBE_ERROR_EXIT = 5
/** jq 1.6 -e status when an evaluated document emits no output. */
const JQ_EXIT_STATUS_NO_OUTPUT = 4

/** Long options that consume the next two argv words as their values. */
const JQ_VALUE_LONG_OPTIONS: ReadonlySet<string> = new Set([
  '--arg',
  '--argjson',
  '--rawfile',
  '--slurpfile',
])

/** Long boolean options the pinned built-in's parser accepts. */
const JQ_BOOLEAN_LONG_OPTIONS: ReadonlySet<string> = new Set([
  '--raw-input',
  '--raw-output',
  '--compact-output',
  '--exit-status',
  '--slurp',
  '--null-input',
  '--join-output',
  '--ascii',
  '--sort-keys',
  '--color',
  '--monochrome',
  '--tab',
  '--help',
])

/** Short option letters the pinned built-in's parser accepts as booleans. */
const JQ_SHORT_FLAGS: ReadonlySet<string> = new Set([
  'R', 'r', 'c', 'e', 's', 'n', 'j', 'a', 'S', 'C', 'M',
])

/** One parsed jq invocation. */
export interface JqInvocation {
  /** Option tokens (with their values) to forward to the built-in. */
  readonly options: readonly string[]
  /** The jq filter, or undefined when argv names none. */
  readonly filter?: string | undefined
  /** File operands, in command-line order (`-` means stdin). */
  readonly files: readonly string[]
  /** `--args` / `--jsonargs` positional values. */
  readonly positional: readonly string[]
  /** `-n` / `--null-input`. */
  readonly nullInput: boolean
  /** `-s` / `--slurp`. */
  readonly slurp: boolean
  /** `-R` / `--raw-input`. */
  readonly rawInput: boolean
  /** `-e` / `--exit-status`. */
  readonly exitStatus: boolean
  /** A real `--help` option token, excluding option values with that text. */
  readonly help: boolean
  /** `--args` / `--jsonargs`, when one was named. */
  readonly argsMode?: 'args' | 'jsonargs' | undefined
  /** First option token the shim does not model, if any. */
  readonly unsupportedOption?: string | undefined
}

/**
 * Parse the jq argument surface the shim needs to locate the filter and its
 * inputs. Unknown options are recorded in {@link JqInvocation.unsupportedOption}
 * so the caller can delegate them to the built-in's own parser and error.
 * @param argv - arguments after the program name.
 * @returns the parsed invocation.
 */
function isJqOptionShaped(token: string): boolean {
  if (token.length < 2 || token[0] !== '-') return false
  const second = token[1] as string
  return second === '-' || /[A-Za-z]/u.test(second)
}

export function parseJqInvocation(argv: readonly string[]): JqInvocation {
  const options: string[] = []
  const files: string[] = []
  const positional: string[] = []
  let filter: string | undefined
  let nullInput = false
  let slurp = false
  let rawInput = false
  let exitStatus = false
  let help = false
  let argsMode: 'args' | 'jsonargs' | undefined
  let unsupportedOption: string | undefined
  let optionsEnded = false
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string
    if (!optionsEnded && token === '--') {
      // jq 1.6 only treats `--` as "arguments done" after the filter is known.
      // Before that it prints usage; delegate instead of re-reading the next
      // option-shaped token as a filter.
      if (filter === undefined) {
        unsupportedOption ??= token
        options.push(token)
        continue
      }
      optionsEnded = true
      continue
    }
    if (!optionsEnded && isJqOptionShaped(token) && token.startsWith('--')) {
      if (JQ_VALUE_LONG_OPTIONS.has(token)) {
        options.push(token)
        const first = argv[index + 1]
        const second = argv[index + 2]
        if (first !== undefined) {
          options.push(first)
          index += 1
        }
        if (second !== undefined) {
          options.push(second)
          index += 1
        }
        continue
      }
      if (token === '--args' || token === '--jsonargs') {
        argsMode = token === '--args' ? 'args' : 'jsonargs'
        options.push(token)
        continue
      }
      if (JQ_BOOLEAN_LONG_OPTIONS.has(token)) {
        if (token === '--null-input') nullInput = true
        else if (token === '--slurp') slurp = true
        else if (token === '--raw-input') rawInput = true
        else if (token === '--exit-status') exitStatus = true
        else if (token === '--help') help = true
        options.push(token)
        continue
      }
      unsupportedOption ??= token
      options.push(token)
      continue
    }
    if (!optionsEnded && isJqOptionShaped(token) && !token.startsWith('--')) {
      for (const letter of token.slice(1)) {
        if (!JQ_SHORT_FLAGS.has(letter)) {
          unsupportedOption ??= token
          break
        }
        if (letter === 'n') nullInput = true
        else if (letter === 's') slurp = true
        else if (letter === 'R') rawInput = true
        else if (letter === 'e') exitStatus = true
      }
      options.push(token)
      continue
    }
    if (filter === undefined) {
      filter = token
      continue
    }
    if (argsMode !== undefined) positional.push(token)
    else files.push(token)
  }
  return {
    options,
    filter,
    files,
    positional,
    nullInput,
    slurp,
    rawInput,
    exitStatus,
    help,
    argsMode,
    unsupportedOption,
  }
}

/** Where a reference inside a `\(...)` string-interpolation body lives. */
export interface JqInterpolationContext {
  /** Start offset of the enclosing string literal (its opening quote). */
  readonly stringStart: number
  /** End offset of the enclosing string literal (just past the closing quote). */
  readonly stringEnd: number
  /** Start offset of the interpolation expression body. */
  readonly bodyStart: number
  /** End offset of the interpolation expression body (its closing `)`). */
  readonly bodyEnd: number
  /**
   * True when the string is top-level code rather than a nested string inside
   * another interpolation. Only a top-level `\(inputs)` can be lifted out.
   */
  readonly liftable: boolean
}

/** One bare reference to an input-family function inside a filter. */
export interface JqInputReference {
  /** Function name. */
  readonly name: string
  /** Start offset in the filter text. */
  readonly start: number
  /** End offset (exclusive) in the filter text. */
  readonly end: number
  /** Enclosing interpolation when the reference is inside `\(...)`. */
  readonly interpolation?: JqInterpolationContext | undefined
}

/** True for a jq identifier character. */
function isIdentifierCharacter(character: string | undefined): boolean {
  return character !== undefined && /[A-Za-z0-9_]/u.test(character)
}

/**
 * End offset of a jq number literal that starts at `index`, or undefined when
 * the text there is not a number.
 *
 * The bounded name validator has to skip a whole number token before looking
 * for identifiers: otherwise the exponent in `1e3` looks like a function named
 * `e3`. jq accepts an optional `-`, a fraction (including the `1.` spelling)
 * and an `e`/`E` exponent, so the scanner does too. `nan`/`infinite` are
 * ordinary builtins (`nan/0`, `infinite/0`) and stay subject to name/arity
 * validation.
 * @param text - jq filter text.
 * @param index - candidate start offset.
 * @param end - exclusive end of the scanned range.
 * @returns the token's exclusive end, or undefined when it is not a number.
 */
function jqNumericLiteralEnd(text: string, index: number, end: number): number | undefined {
  const match = /^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/u.exec(text.slice(index, end))
  return match === null ? undefined : index + match[0].length
}

/** Index of the next non-whitespace, non-comment character, or text.length. */
function nextSignificant(text: string, index: number): number {
  for (let cursor = index; cursor < text.length; cursor += 1) {
    const character = text[cursor] as string
    if (!/\s/u.test(character)) {
      if (character !== '#') return cursor
      while (cursor < text.length && text[cursor] !== '\n') cursor += 1
    }
  }
  return text.length
}

/** One `\(...)` interpolation body inside a jq string literal. */
interface JqStringInterpolation {
  /** Offset of the first expression token (after `\(`). */
  readonly start: number
  /** Offset of the closing `)`, or the end of the text when unterminated. */
  readonly end: number
}

/** A scanned double-quoted jq string literal. */
interface JqStringScan {
  /** Offset just past the closing quote, or `text.length` when unterminated. */
  readonly end: number
  /** Direct interpolation bodies, in source order. */
  readonly interpolations: readonly JqStringInterpolation[]
}

/**
 * Offset of the `)` that closes an interpolation body, or `text.length` when
 * the interpolation is unterminated. Nested parentheses, strings and comments
 * inside the interpolation are skipped.
 */
function findJqInterpolationEnd(text: string, start: number): number {
  let depth = 1
  let index = start
  while (index < text.length) {
    const character = text[index] as string
    if (character === '"') {
      index = scanJqString(text, index).end
      continue
    }
    if (character === '#') {
      while (index < text.length && text[index] !== '\n') index += 1
      continue
    }
    if (character === '(') {
      depth += 1
      index += 1
      continue
    }
    if (character === ')') {
      depth -= 1
      if (depth === 0) return index
      index += 1
      continue
    }
    index += 1
  }
  return text.length
}

/**
 * Scan a double-quoted jq string, including escapes and `\(...)` bodies.
 *
 * A `\(` starts an executable interpolation; every other backslash escape
 * (including `\\(`) is literal. Nested strings inside an interpolation are
 * scanned recursively so their parentheses do not terminate the body early.
 */
function scanJqString(text: string, start: number): JqStringScan {
  const interpolations: JqStringInterpolation[] = []
  let index = start + 1
  while (index < text.length) {
    const character = text[index] as string
    if (character === '\\') {
      if (text[index + 1] === '(') {
        const bodyStart = index + 2
        const bodyEnd = findJqInterpolationEnd(text, bodyStart)
        interpolations.push({ start: bodyStart, end: bodyEnd })
        index = bodyEnd < text.length ? bodyEnd + 1 : text.length
        continue
      }
      index += 2
      continue
    }
    index += 1
    if (character === '"') return { end: index, interpolations }
  }
  return { end: text.length, interpolations }
}

/**
 * A bare function name, as opposed to a field access (`.inputs`), a variable
 * (`$inputs`), a format (`@inputs`), an object key (`{inputs: ...}`) or a
 * `def` name. The scanner only calls this for identifier-shaped runs, so the
 * word-boundary half is already guaranteed.
 * @param before - index of the previous code character (whitespace and `#`
 *   comments already skipped by the scanner), or -1.
 * @param inObjectKeyPosition - true when the identifier is the first token of
 *   an object-constructor entry. That is the only place jq's `{inputs}`
 *   shorthand names a key; a comma inside an array or at the top level is an
 *   ordinary expression separator and must still rewrite the function.
 */
function isBareFunctionName(
  text: string,
  before: number,
  end: number,
  inObjectKeyPosition: boolean,
): boolean {
  if (before >= 0) {
    const character = text[before] as string
    if (character === '.' || character === '$' || character === '@') return false
    if (character === '"') return false
    // `def name:` defines the name; a user definition may shadow the built-in.
    if (/[A-Za-z_]/u.test(character)) {
      const wordStart = text.slice(0, before + 1).search(/[A-Za-z0-9_]+$/u)
      const previousWord = wordStart === -1 ? '' : text.slice(wordStart, before + 1)
      if (previousWord === 'def') return false
    }
  }
  const after = nextSignificant(text, end)
  // An identifier before ':' is an object key only at an object entry start.
  // In an index expression such as .[input:2], it is a real input call.
  if (inObjectKeyPosition && after < text.length && text[after] === ':') return false
  // jq object shorthand (`{inputs}` == `{inputs: .inputs}`) names a key, not
  // the built-in function. Only apply this inside an object constructor:
  // `[1, inputs, 2]` and `1, inputs, 2` are comma expressions, not shorthands.
  if (inObjectKeyPosition && after < text.length
    && (text[after] === '}' || text[after] === ',')) return false
  return true
}

/**
 * Find the bare input-family references in one code range. String literals are
 * skipped, but their `\(...)` interpolation bodies contain executable code and
 * are scanned recursively (with a fresh object-key/bracket context).
 */
function scanJqInputReferencesInRange(
  filter: string,
  start: number,
  end: number,
  references: JqInputReference[],
  interpolation?: JqInterpolationContext,
): void {
  const stack: { readonly kind: '{' | '[' | '('; entryStart: boolean }[] = []
  // Last code character outside strings, whitespace and `#` comments. Tracking
  // it here (rather than scanning backwards) keeps a comment that ends in
  // `.`, `$`, `@` or `def` from becoming the "previous token" of the next line.
  let previousCodeIndex = -1
  let index = start
  while (index < end) {
    const character = filter[index] as string
    if (character === '"') {
      const scanned = scanJqString(filter, index)
      for (const body of scanned.interpolations) {
        scanJqInputReferencesInRange(
          filter,
          Math.max(body.start, start),
          Math.min(body.end, end),
          references,
          {
            stringStart: index,
            stringEnd: scanned.end,
            bodyStart: body.start,
            bodyEnd: body.end,
            liftable: interpolation === undefined,
          },
        )
      }
      index = scanned.end
      previousCodeIndex = index - 1
      continue
    }
    if (character === '#') {
      while (index < end && filter[index] !== '\n') index += 1
      continue
    }
    if (character === '{') {
      stack.push({ kind: '{', entryStart: true })
      previousCodeIndex = index
      index += 1
      continue
    }
    if (character === '[' || character === '(') {
      stack.push({ kind: character, entryStart: false })
      previousCodeIndex = index
      index += 1
      continue
    }
    if (character === '}' || character === ']' || character === ')') {
      const expected = character === '}' ? '{' : character === ']' ? '[' : '('
      if (stack[stack.length - 1]?.kind === expected) stack.pop()
      previousCodeIndex = index
      index += 1
      continue
    }
    if (character === ',') {
      const top = stack[stack.length - 1]
      if (top?.kind === '{') top.entryStart = true
      previousCodeIndex = index
      index += 1
      continue
    }
    if (character === ':') {
      const top = stack[stack.length - 1]
      if (top?.kind === '{') top.entryStart = false
      previousCodeIndex = index
      index += 1
      continue
    }
    if (/[A-Za-z_]/u.test(character)) {
      let tokenEnd = index + 1
      while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
      const name = filter.slice(index, tokenEnd)
      const top = stack[stack.length - 1]
      const inObjectKeyPosition = top?.kind === '{' && top.entryStart
      if (JQ_INPUT_FUNCTIONS.includes(name)
        && isBareFunctionName(filter, previousCodeIndex, tokenEnd, inObjectKeyPosition)) {
        references.push(
          interpolation === undefined
            ? { name, start: index, end: tokenEnd }
            : { name, start: index, end: tokenEnd, interpolation },
        )
      }
      previousCodeIndex = tokenEnd - 1
      index = tokenEnd
      continue
    }
    if (!/\s/u.test(character)) previousCodeIndex = index
    index += 1
  }
}

/**
 * Find the bare `inputs` / `input` / `input_line_number` references in a jq
 * filter. String literals and `#` comments are skipped; jq has no separate
 * regex-literal syntax (regular expressions are strings). Code inside a
 * string's `\(...)` interpolation is not literal text and is scanned too.
 * @param filter - the jq filter text.
 * @returns every bare reference, in source order.
 */
export function scanJqInputReferences(filter: string): JqInputReference[] {
  const references: JqInputReference[] = []
  scanJqInputReferencesInRange(filter, 0, filter.length, references)
  return references
}

/**
 * Rewrite input-family references to the injected variables.
 *
 * Every reference becomes `$__pdsh_jq_inputs[]` (`inputs`),
 * `$__pdsh_jq_inputs[0]` (`input`) or `$__pdsh_jq_line`
 * (`input_line_number`); everything outside the
 * references is preserved byte for byte.
 * @param filter - the jq filter text.
 * @param references - scanned references; defaults to a fresh scan.
 * @returns the rewritten filter.
 */
export function rewriteJqInputFunctions(
  filter: string,
  references: readonly JqInputReference[] = scanJqInputReferences(filter),
): string {
  let output = ''
  let cursor = 0
  for (const reference of references) {
    output += filter.slice(cursor, reference.start)
    if (reference.name === 'inputs') output += `$${JQ_INTERNAL_INPUTS}[]`
    else if (reference.name === 'input') output += `$${JQ_INTERNAL_INPUTS}[0]`
    else output += `$${JQ_INTERNAL_LINE}`
    cursor = reference.end
  }
  return output + filter.slice(cursor)
}

/**
 * True when the code in one range contains a real `def name:` declaration.
 *
 * A bare `def` token is not enough: `.def` and `$def` are a field/variable
 * access, `@def` is a format, `{def: 1}` is an object key, and `mydef` is a
 * different identifier. Only `def` followed by a definition name (and an
 * optional argument list) and then `:` declares a function.
 * @param filter - the jq filter text.
 * @param start - range start.
 * @param end - range end.
 * @returns whether a `def` declaration starts in the range.
 */
function hasJqDefDeclarationInRange(
  filter: string,
  start: number,
  end: number,
): boolean {
  let previousCodeIndex = -1
  let index = start
  while (index < end) {
    const character = filter[index] as string
    if (character === '"') {
      const scanned = scanJqString(filter, index)
      for (const interpolation of scanned.interpolations) {
        if (hasJqDefDeclarationInRange(
          filter,
          Math.max(interpolation.start, start),
          Math.min(interpolation.end, end),
        )) return true
      }
      index = scanned.end
      previousCodeIndex = index - 1
      continue
    }
    if (character === '#') {
      while (index < end && filter[index] !== '\n') index += 1
      continue
    }
    if (/[A-Za-z_]/u.test(character)) {
      let tokenEnd = index + 1
      while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
      const name = filter.slice(index, tokenEnd)
      const previous = previousCodeIndex < 0 ? undefined : filter[previousCodeIndex]
      if (name === 'def' && previous !== '.' && previous !== '$' && previous !== '@') {
        let cursor = nextSignificant(filter, tokenEnd)
        if (cursor < end && /[A-Za-z_]/u.test(filter[cursor] as string)) {
          cursor += 1
          while (cursor < end && isIdentifierCharacter(filter[cursor])) cursor += 1
          cursor = nextSignificant(filter, cursor)
          if (cursor < end && filter[cursor] === '(') {
            let depth = 1
            cursor += 1
            while (cursor < end && depth > 0) {
              const inner = filter[cursor] as string
              if (inner === '"') {
                cursor = scanJqString(filter, cursor).end
                continue
              }
              if (inner === '#') {
                while (cursor < end && filter[cursor] !== '\n') cursor += 1
                continue
              }
              if (inner === '(') depth += 1
              else if (inner === ')') depth -= 1
              cursor += 1
            }
            cursor = nextSignificant(filter, cursor)
          }
          if (cursor < end && filter[cursor] === ':') return true
        }
      }
      previousCodeIndex = tokenEnd - 1
      index = tokenEnd
      continue
    }
    if (!/\s/u.test(character)) previousCodeIndex = index
    index += 1
  }
  return false
}

/**
 * True when the filter contains a real `def name:` declaration outside string
 * literals and comments. Interpolation bodies are code and are scanned too.
 */
function hasJqDefDeclaration(filter: string): boolean {
  return hasJqDefDeclarationInRange(filter, 0, filter.length)
}

/**
 * jq words/operators whose evaluation can skip, repeat or short-circuit the
 * filter that follows them. When one appears before the input-family call, the
 * shim cannot know how many documents the real jq cursor would consume. This
 * includes filter-argument builtins (`map`, `select`, `any`, ...) and builtins
 * that can yield zero or several values (`values`, `paths`, `splits`, ...);
 * single-value operations such as `length` or `keys` are intentionally absent.
 */
export const JQ_UNSAFE_INPUT_WORDS: ReadonlySet<string> = new Set([
  'if', 'elif', 'then', 'else', 'end',
  'select', 'first', 'last', 'limit', 'nth', 'try', 'catch',
  'reduce', 'foreach', 'while', 'until', 'repeat', 'recurse', 'recurse_down',
  'range', 'map', 'map_values', 'walk', 'empty',
  'values', 'arrays', 'objects', 'strings', 'numbers', 'booleans', 'nulls',
  'scalars', 'iterables', 'paths', 'leaf_paths', 'tostream', 'fromstream',
  'truncate_stream', 'combinations', 'splits', 'scan', 'match', 'capture',
  'label', 'break', 'halt', 'halt_error', 'error',
  'isempty', 'any', 'all', 'sort_by', 'group_by', 'unique_by', 'min_by', 'max_by',
  'with_entries', 'IN', 'INDEX', 'path', 'del', 'pick',
  // `sub`/`gsub` evaluate their replacement filter once per match (zero or
  // more times), so `sub("a"; input)` can consume a variable number of
  // documents that an immutable injected array cannot observe.
  'sub', 'gsub',
  'and', 'or',
])

/**
 * Return whether an input reference is in a syntactic context where this
 * wrapper cannot prove one ordered consumption. Top-level and array-building
 * comma expressions are retained; object construction, index generators and
 * parenthesized generators are rejected.
 */
function findUnsafeInputStructure(filter: string, reference: JqInputReference): string | undefined {
  interface Frame {
    readonly kind: '{' | '[' | '('
    readonly start: number
    readonly index: boolean
  }
  const scan = (
    start: number,
    end: number,
    inherited: readonly Frame[],
  ): string | undefined => {
    const stack = [...inherited]
    let previousCodeIndex = -1
    let commaBeforeReference = false
    let commaInParentheses = false
    let commaInIndex = false
    let pipeAfterComma = false
    for (let index = start; index < end;) {
      const character = filter[index] as string
      if (character === '"') {
        const string = scanJqString(filter, index)
        const nested = string.interpolations.find(
          interpolation => reference.start >= interpolation.start && reference.start < interpolation.end,
        )
        if (nested !== undefined) {
          return scan(Math.max(nested.start, start), Math.min(nested.end, end), stack)
        }
        index = string.end
        previousCodeIndex = index - 1
        continue
      }
      if (character === '#') {
        while (index < end && filter[index] !== '\n') index += 1
        continue
      }
      if (index === reference.start) {
        if (stack.some(frame => frame.kind === '{')) {
          return 'input consumption inside an object constructor'
        }
        const indexFrame = [...stack].reverse().find(frame => frame.kind === '[' && frame.index)
        if (indexFrame !== undefined) {
          const close = filter.indexOf(']', indexFrame.start + 1)
          const body = close < 0 ? '' : filter.slice(indexFrame.start + 1, close).trim()
          const simpleInputSlice = reference.name === 'input'
            && /^input(?:\s*:\s*-?\d*)?$/u.test(body)
          if (!simpleInputSlice) return 'an index expression that may generate multiple values'
        }
        if (pipeAfterComma) return 'a comma sequence feeding a pipe into input'
        if (commaInIndex) return 'an index generator before input consumption'
        if (commaInParentheses) return 'a comma sequence before input'
        if (commaBeforeReference && reference.name === 'input'
          && stack[stack.length - 1]?.kind !== '[') {
          return 'a comma sequence before input'
        }
        return undefined
      }
      if (character === ',') {
        commaBeforeReference = true
        const top = stack[stack.length - 1]
        if (top?.kind === '(') commaInParentheses = true
        if (top?.kind === '[' && top.index) commaInIndex = true
        previousCodeIndex = index
        index += 1
        continue
      }
      if (character === '|' && filter[index + 1] !== '=') {
        if (commaBeforeReference) pipeAfterComma = true
        previousCodeIndex = index
        index += 1
        continue
      }
      if (character === '[') {
        const close = nextSignificant(filter, index + 1)
        if (filter[close] === ']') {
          stack.push({ kind: '[', start: index, index: false })
          previousCodeIndex = index
          index += 1
          continue
        }
        const previous = previousCodeIndex < 0 ? '' : filter[previousCodeIndex] as string
        const isIndex = previous === '.' || previous === ')' || previous === ']'
          || previous === '}' || previous === '"' || isIdentifierCharacter(previous)
        stack.push({ kind: '[', start: index, index: isIndex })
        previousCodeIndex = index
        index += 1
        continue
      }
      if (character === '{' || character === '(') {
        stack.push({ kind: character, start: index, index: false })
        previousCodeIndex = index
        index += 1
        continue
      }
      if (character === '}' || character === ']' || character === ')') {
        const expected = character === '}' ? '{' : character === ']' ? '[' : '('
        if (stack[stack.length - 1]?.kind === expected) stack.pop()
        previousCodeIndex = index
        index += 1
        continue
      }
      if (/[A-Za-z_]/u.test(character)) {
        let tokenEnd = index + 1
        while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
        previousCodeIndex = tokenEnd - 1
        index = tokenEnd
        continue
      }
      if (!/\s/u.test(character)) previousCodeIndex = index
      index += 1
    }
    return undefined
  }
  return scan(0, filter.length, [])
}

/**
 * Find the first construct that makes the input-family call's evaluation
 * conditional or repeated. The check is deliberately conservative: a false
 * positive produces a `jq:` diagnostic (never a silently different stream),
 * while a missed construct would drop documents.
 *
 * Interpolation bodies are executable code and are scanned recursively. A
 * comma before an `input` call is accepted only inside an array/object
 * constructor, where jq builds the value before emitting it and a failing
 * `input` therefore emits no prefix. At stream level (including parentheses)
 * jq emits the values produced before the failing `input`, which the
 * per-document wrapper cannot reproduce.
 * @param filter - the jq filter text.
 * @returns a short description of the offending construct, or undefined when
 *   the call is unconditional enough for the per-document cursor.
 */
export function findUnsafeInputConsumption(filter: string): string | undefined {
  const reference = scanJqInputReferences(filter)
    .find(candidate => candidate.name === 'input' || candidate.name === 'inputs')
  if (reference === undefined) return undefined
  const structure = findUnsafeInputStructure(filter, reference)
  if (structure !== undefined) return structure
  let commaBeforeInput = false
  let streamCommaBeforeInput = false
  let pipeAfterCommaBeforeInput = false

  const scan = (start: number, end: number): string | undefined => {
    const stack: ('{' | '[' | '(')[] = []
    let index = start
    while (index < end) {
      const character = filter[index] as string
      if (character === '"') {
        const scanned = scanJqString(filter, index)
        for (const interpolation of scanned.interpolations) {
          const nested = scan(
            Math.max(interpolation.start, start),
            Math.min(interpolation.end, end),
          )
          if (nested !== undefined) return nested
        }
        index = scanned.end
        continue
      }
      if (character === '#') {
        while (index < end && filter[index] !== '\n') index += 1
        continue
      }
      // Postfix `?` can turn an exhausted `input` into `empty`; it is never
      // safe around a consuming call, even after it.
      if (character === '?') return "the optional operator '?'"
      if (character === ',') {
        if (index < reference.start) {
          commaBeforeInput = true
          if (reference.name === 'input') {
            const top = stack[stack.length - 1]
            if (top !== '[' && top !== '{') streamCommaBeforeInput = true
          }
        }
        index += 1
        continue
      }
      if (character === '|' && filter[index + 1] !== '=') {
        if (commaBeforeInput && index < reference.start) pipeAfterCommaBeforeInput = true
        index += 1
        continue
      }
      if (character === '.' && filter[index + 1] === '.') {
        if (index < reference.start) return "the recursive-descent operator '..'"
        index += 2
        continue
      }
      if (character === '[') {
        const close = nextSignificant(filter, index + 1)
        if (filter[close] === ']') {
          if (index < reference.start) return "the iterator '[]'"
          index = close + 1
          continue
        }
        stack.push('[')
        index += 1
        continue
      }
      if (character === '{' || character === '(') {
        stack.push(character)
        index += 1
        continue
      }
      if (character === '}' || character === ']' || character === ')') {
        stack.pop()
        index += 1
        continue
      }
      if (character === '/' && filter[index + 1] === '/') {
        if (index < reference.start) return "the alternative operator '//'"
        index += 2
        continue
      }
      if (/[A-Za-z_]/u.test(character)) {
        let tokenEnd = index + 1
        while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
        const name = filter.slice(index, tokenEnd)
        if (JQ_UNSAFE_INPUT_WORDS.has(name) && index < reference.start) {
          return `'${name}'`
        }
        index = tokenEnd
        continue
      }
      index += 1
    }
    return undefined
  }

  const unsafe = scan(0, filter.length)
  if (unsafe !== undefined) return unsafe
  if (pipeAfterCommaBeforeInput) return 'a comma sequence feeding a pipe into input'
  if (streamCommaBeforeInput) return 'a comma sequence before input'
  return undefined
}

/** A filter rewritten for evaluation through the injected variables. */
export interface JqShimPlan {
  /** The rewritten filter body. */
  readonly filter: string
  /** True when the filter names bare `inputs`. */
  readonly usesInputs: boolean
  /** True when the filter names bare `input`. */
  readonly usesInput: boolean
  /** True when the filter names bare `input_line_number`. */
  readonly usesLineNumber: boolean
  /** Number of bare `input` references. */
  readonly inputCount: number
  /** Number of bare `inputs` references. */
  readonly inputsCount: number
  /** True when `\(inputs)` was lifted out of its string for evaluation. */
  readonly liftedInputsInterpolation: boolean
  /**
   * True when `inputs` appears in an interpolation the wrapper cannot lift
   * (a nested string, a multi-value body, an expression around `inputs`, a
   * string with other interpolations or an `@format` string).
   */
  readonly unsupportedInputInterpolation: boolean
}

/**
 * True when the string at `stringStart` is the format string of a preceding
 * `@format` (`@json "..."`, `@text "..."`, ...). jq applies the format to each
 * interpolation body, so replacing such a string with a parenthesized
 * generator is not valid jq and changes the value; the lift must not happen.
 */
function isJqFormatStringPosition(filter: string, stringStart: number): boolean {
  let index = 0
  let lastCodeIndex = -1
  while (index < stringStart) {
    const character = filter[index] as string
    if (character === '"') {
      index = scanJqString(filter, index).end
      lastCodeIndex = index - 1
      continue
    }
    if (character === '#') {
      while (index < stringStart && filter[index] !== '\n') index += 1
      continue
    }
    if (!/\s/u.test(character)) lastCodeIndex = index
    index += 1
  }
  if (lastCodeIndex < 0) return false
  let tokenStart = lastCodeIndex
  while (tokenStart > 0 && isIdentifierCharacter(filter[tokenStart - 1])) tokenStart -= 1
  return filter[tokenStart - 1] === '@'
}

/** One source range of a function call's argument list. */
interface JqCallArgumentRange {
  /** Offset of the call's opening `(`. */
  readonly start: number
  /** Offset just past the call's closing `)`. */
  readonly end: number
}

/**
 * Ranges of jq function-call argument lists in a filter.
 *
 * A `(` whose preceding code token is an identifier starts a call's argument
 * list (`test(...)`, `has(...)`). Grouping parentheses (`(inputs)`) are not
 * argument lists. String literals are skipped but their `\(...)` interpolation
 * bodies are code and are scanned recursively, so a call inside an
 * interpolation is found too.
 * @param filter - the jq filter text.
 * @returns the argument-list ranges, in source order.
 */
function jqCallArgumentRanges(filter: string): JqCallArgumentRange[] {
  const ranges: JqCallArgumentRange[] = []
  const scan = (start: number, end: number): void => {
    const stack: { readonly start: number; readonly call: boolean }[] = []
    let previousCodeIndex = -1
    let index = start
    while (index < end) {
      const character = filter[index] as string
      if (character === '"') {
        const scanned = scanJqString(filter, index)
        for (const interpolation of scanned.interpolations) {
          scan(
            Math.max(interpolation.start, start),
            Math.min(interpolation.end, end),
          )
        }
        index = scanned.end
        previousCodeIndex = index - 1
        continue
      }
      if (character === '#') {
        while (index < end && filter[index] !== '\n') index += 1
        continue
      }
      if (character === '(') {
        const previous = previousCodeIndex < 0 ? '' : filter[previousCodeIndex] as string
        stack.push({ start: index, call: isIdentifierCharacter(previous) })
        previousCodeIndex = index
        index += 1
        continue
      }
      if (character === ')') {
        const frame = stack.pop()
        if (frame?.call === true) ranges.push({ start: frame.start, end: index + 1 })
        previousCodeIndex = index
        index += 1
        continue
      }
      if (/[A-Za-z_]/u.test(character)) {
        let tokenEnd = index + 1
        while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
        previousCodeIndex = tokenEnd - 1
        index = tokenEnd
        continue
      }
      if (!/\s/u.test(character)) previousCodeIndex = index
      index += 1
    }
  }
  scan(0, filter.length)
  return ranges
}

/** True when `offset` lies inside one of the filter's function arguments. */
function isJqFunctionArgumentPosition(filter: string, offset: number): boolean {
  return jqCallArgumentRanges(filter)
    .some(range => offset >= range.start && offset < range.end)
}

/**
 * Find a consuming `input`/`inputs` used as a function argument.
 *
 * jq evaluates a function call once per value of each filter argument, and a
 * built-in (or a later definition) may evaluate that argument zero or more
 * times. `inputs` is also a generator, so the built-in evaluator would keep
 * only its first value and silently drop the rest. `input` advances the stream
 * per argument evaluation, so its count is not provable from one textual
 * occurrence either. Both are refused; `input_line_number` is informational and
 * remains allowed. The shim refuses such filters instead of substituting one
 * value and pretending the result is complete.
 * @param filter - the jq filter text.
 * @returns a short description of the offending argument, or undefined.
 */
export function findUnsafeInputsValueArgument(filter: string): string | undefined {
  const ranges = jqCallArgumentRanges(filter)
  if (ranges.length === 0) return undefined
  const reference = scanJqInputReferences(filter).find(candidate =>
    (candidate.name === 'input' || candidate.name === 'inputs')
      && ranges.some(range => candidate.start >= range.start && candidate.start < range.end),
  )
  if (reference === undefined) return undefined
  if (reference.name === 'inputs') {
    return reference.interpolation === undefined
      ? 'inputs used as a function argument'
      : 'an inputs interpolation used as a function argument'
  }
  return reference.interpolation === undefined
    ? 'input used as a function argument'
    : 'an input interpolation used as a function argument'
}

/**
 * True when the sole `inputs` reference is the whole body of a top-level
 * `\(...)` interpolation, and the string has no other interpolation, so the
 * string can be lifted into a pipe without rebinding any other `.` expression.
 * A string that is itself a function argument is not liftable: the lifted
 * generator would still lose every value after the first in the built-in's
 * argument evaluation.
 */
function isLiftableInputsInterpolation(
  filter: string,
  reference: JqInputReference,
): boolean {
  const interpolation = reference.interpolation
  if (interpolation === undefined || !interpolation.liftable) return false
  if (filter.slice(interpolation.bodyStart, interpolation.bodyEnd).trim() !== 'inputs') return false
  if (isJqFormatStringPosition(filter, interpolation.stringStart)) return false
  if (isJqFunctionArgumentPosition(filter, reference.start)) return false
  return scanJqString(filter, interpolation.stringStart).interpolations.length === 1
}

/**
 * Lift `"pre\(inputs)post"` to `($__pdsh_jq_inputs[] | "pre\(.)post")`.
 *
 * jq's interpolation is a generator: one string per value of the body. The
 * built-in interpolation engine instead concatenates a multi-valued body into
 * one string, so a direct `$__pdsh_jq_inputs[]` rewrite would silently join every
 * remaining document. Moving the iteration outside the string restores the
 * one-output-per-document shape.
 */
function liftInputsInterpolation(filter: string, reference: JqInputReference): string {
  const interpolation = reference.interpolation
  if (interpolation === undefined) return rewriteJqInputFunctions(filter, [reference])
  const stringText = filter.slice(interpolation.stringStart, interpolation.stringEnd)
  const start = reference.start - interpolation.stringStart
  const end = reference.end - interpolation.stringStart
  const rewrittenString = `${stringText.slice(0, start)}.${stringText.slice(end)}`
  return `${filter.slice(0, interpolation.stringStart)}($${JQ_INTERNAL_INPUTS}[] | ${rewrittenString})${filter.slice(interpolation.stringEnd)}`
}

/**
 * Plan the shim's evaluation of one filter.
 * @param filter - the jq filter text.
 * @returns undefined when the filter does not name the input family, so the
 *   invocation must be delegated unchanged.
 */
export function planJqShim(filter: string): JqShimPlan | undefined {
  const references = scanJqInputReferences(filter)
  if (references.length === 0) return undefined
  const inputCount = references.filter(reference => reference.name === 'input').length
  const inputsReferences = references.filter(reference => reference.name === 'inputs')
  const inputsCount = inputsReferences.length
  const onlyInputs = inputsCount === 1 ? inputsReferences[0] : undefined
  const liftedInputsInterpolation = onlyInputs !== undefined
    && onlyInputs.interpolation !== undefined
    && isLiftableInputsInterpolation(filter, onlyInputs)
  const unsupportedInputInterpolation = references.some(reference => {
    const interpolation = reference.interpolation
    if (interpolation === undefined) return false
    if (reference.name === 'inputs') return !isLiftableInputsInterpolation(filter, reference)
    const body = filter.slice(interpolation.bodyStart, interpolation.bodyEnd).trim()
    const onlyInterpolation = scanJqString(filter, interpolation.stringStart).interpolations.length === 1
    return !interpolation.liftable || body !== reference.name || !onlyInterpolation
  })
  return {
    filter: liftedInputsInterpolation && onlyInputs !== undefined
      ? liftInputsInterpolation(filter, onlyInputs)
      : rewriteJqInputFunctions(filter, references),
    usesInputs: inputsCount > 0,
    usesInput: inputCount > 0,
    usesLineNumber: references.some(reference => reference.name === 'input_line_number'),
    inputCount,
    inputsCount,
    liftedInputsInterpolation,
    unsupportedInputInterpolation,
  }
}

/**
 * The jq argv cannot be kept honest by the wrapper.
 *
 * The command answers exit 2 with a `jq:` diagnostic instead of silently
 * producing a different input stream.
 */
export class JqShimError extends Error {
  /**
   * @param message - diagnostic body (without the `jq: ` prefix).
   */
  constructor(message: string) {
    super(message)
    this.name = 'JqShimError'
  }
}

/** One parsed top-level JSON document. */
export interface JqDocument {
  /** The document value. */
  readonly value: unknown
  /** 1-based line on which the document starts in its source. */
  readonly line: number
  /** 1-based line holding the document's last character (used by diagnostics). */
  readonly endLine: number
  /** jq 1.6 `input_line_number` (newline-terminated read count for the source). */
  readonly inputLine: number
  /** Operand name that supplied the document (`<stdin>` for standard input). */
  readonly source: string
}

/** One input source (a file or stdin), kept as raw bytes until the stream is joined. */
interface JqSource {
  readonly name: string
  readonly bytes: Uint8Array
}

/** Where an exhausted `input` reports its jq 1.6 `break` position. */
interface JqBreakPosition {
  readonly source?: string | undefined
  readonly line?: number | undefined
}

/** True for JSON whitespace. */
function isJsonWhitespace(character: string | undefined): boolean {
  return character === ' ' || character === '\t' || character === '\n' || character === '\r'
}

/** True for JSON whitespace other than a newline. */
function isJsonHorizontalWhitespace(byte: number | undefined): boolean {
  return byte === 0x20 || byte === 0x09 || byte === 0x0d
}

/**
 * End offset (exclusive) of the JSON value that starts at `start`.
 * @throws Error when the value is unterminated or its delimiters do not match.
 */
function scanJsonValueEnd(text: string, start: number): number {
  const first = text[start] as string
  if (first === '{' || first === '[') {
    const expected: string[] = []
    let inString = false
    let escaped = false
    for (let index = start; index < text.length; index += 1) {
      const character = text[index] as string
      if (inString) {
        if (escaped) escaped = false
        else if (character === '\\') escaped = true
        else if (character === '"') inString = false
        continue
      }
      if (character === '"') {
        inString = true
        continue
      }
      if (character === '{' || character === '[') {
        expected.push(character === '{' ? '}' : ']')
        continue
      }
      if (character === '}' || character === ']') {
        if (expected.pop() !== character) {
          throw new Error(`Mismatched JSON delimiter at position ${String(index)}`)
        }
        if (expected.length === 0) return index + 1
      }
    }
    throw new Error(`Unexpected end of JSON input at position ${String(start)} (unclosed ${first})`)
  }
  if (first === '"') {
    let escaped = false
    for (let index = start + 1; index < text.length; index += 1) {
      const character = text[index] as string
      if (escaped) {
        escaped = false
        continue
      }
      if (character === '\\') {
        escaped = true
        continue
      }
      if (character === '"') return index + 1
    }
    throw new Error(`Unexpected end of JSON input at position ${String(start)} (unclosed string)`)
  }
  let index = start
  while (index < text.length) {
    const character = text[index] as string
    // A number/literal token ends at whitespace or any structural delimiter,
    // including the opening byte of the next value. jq's lexer stops at the
    // first byte that cannot continue the token, so `1{"a":2}`, `1[2]` and
    // `1"s"` are two documents even when the two values meet across a file
    // boundary with no trailing newline. Number-internal bytes (digits, `-`,
    // `+`, `.`, `e`) keep the token going, so `1` + `2` still merges to `12`.
    if (
      isJsonWhitespace(character) ||
      character === ',' ||
      character === ']' ||
      character === '}' ||
      character === '[' ||
      character === '{' ||
      character === '"'
    ) {
      break
    }
    index += 1
  }
  return index
}

/** The result of parsing a source stream: documents or a diagnostic. */
type JqSourceResult =
  | { readonly documents: readonly JqDocument[] }
  | {
    readonly error: string
    readonly source?: string
    readonly kind?: 'parse' | 'encoding'
  }

/** One `fgets` chunk boundary and the newline count after reading it. */
interface JqLineCheckpoint {
  /** Offset just past the chunk within its source. */
  readonly end: number
  /** Newline-terminated chunks read from this source through this chunk. */
  readonly line: number
}

/** One source's byte range in the concatenated jq input stream. */
interface JqSourceRange {
  readonly source: JqSource
  readonly start: number
  readonly end: number
  /** Byte offsets of every `\n` in the source, for O(log n) line lookups. */
  readonly newlines: readonly number[]
  /** jq's 4095-byte `fgets` chunk boundaries. */
  readonly checkpoints: readonly JqLineCheckpoint[]
}

/**
 * Build jq 1.6's `fgets(buf, 4096, file)` chunk boundaries.
 *
 * Each chunk holds at most 4095 bytes and stops after the first newline, so a
 * newline beyond the first 4094 bytes is not seen by that read. A completed
 * JSON value may be handed back before jq reads the chunk that holds the
 * following newline.
 * @param bytes - one source's raw bytes.
 * @returns chunk boundaries and the newline count after each chunk.
 */
function jqLineCheckpoints(bytes: Uint8Array): JqLineCheckpoint[] {
  const checkpoints: JqLineCheckpoint[] = []
  let position = 0
  let line = 0
  while (position < bytes.length) {
    const limit = Math.min(position + 4095, bytes.length)
    let newline = -1
    for (let index = position; index < limit; index += 1) {
      if (bytes[index] === 0x0a) {
        newline = index
        break
      }
    }
    const end = newline === -1 ? limit : newline + 1
    if (newline !== -1) line += 1
    checkpoints.push({ end, line })
    position = end
  }
  return checkpoints
}

/**
 * jq 1.6's `input_line_number` for a document ending at a source-local byte.
 *
 * The value is the number of newline-terminated `fgets` chunks jq had read when
 * the parser returned the document, not the physical line of its last
 * character. That distinction shows up when a value ends exactly on a 4095-byte
 * read boundary (the following newline is in the next chunk and is not counted)
 * and when a multi-byte character moves the newline across the byte boundary.
 * @param checkpoints - the source's chunk boundaries.
 * @param end - source-local exclusive end offset of the value.
 * @returns the number jq reports for `input_line_number`.
 */
function jqInputLine(
  checkpoints: readonly JqLineCheckpoint[],
  end: number,
): number {
  if (end <= 0) return 0
  let low = 0
  let high = checkpoints.length
  while (low < high) {
    const middle = (low + high) >> 1
    if ((checkpoints[middle] as JqLineCheckpoint).end < end) low = middle + 1
    else high = middle
  }
  return checkpoints[low]?.line ?? 0
}

/** 1-based line of the byte at `offset` within one source. */
function jqLineAt(newlines: readonly number[], offset: number): number {
  let low = 0
  let high = newlines.length
  while (low < high) {
    const middle = (low + high) >> 1
    if ((newlines[middle] as number) < offset) low = middle + 1
    else high = middle
  }
  return low + 1
}

/** Number of newline bytes in a source. */
function jqNewlineCount(bytes: Uint8Array): number {
  let count = 0
  for (const byte of bytes) if (byte === 0x0a) count += 1
  return count
}

/**
 * True when jq's first read chunk of a source includes a newline.
 * @param bytes - one source's raw bytes.
 * @returns whether the first newline is within the first 4095-byte read.
 */
function jqFirstLineTerminated(bytes: Uint8Array): boolean {
  const limit = Math.min(bytes.length, 4095)
  for (let index = 0; index < limit; index += 1) {
    if (bytes[index] === 0x0a) return true
  }
  return false
}

/** True when parsed JSON contains a number that JSON.stringify would turn into null. */
function jqContainsNonFiniteNumber(value: unknown): boolean {
  if (typeof value === 'number') return !Number.isFinite(value)
  if (Array.isArray(value)) return value.some(jqContainsNonFiniteNumber)
  if (value !== null && typeof value === 'object') {
    return Object.values(value as Record<string, unknown>).some(jqContainsNonFiniteNumber)
  }
  return false
}

/**
 * Offset of the first byte that is not valid UTF-8, or undefined for valid
 * input. jq 1.6 replaces invalid sequences character by character; the shim
 * refuses the stream instead of guessing whether its replacement boundaries
 * match jq exactly. Codepoints split across file operands are valid after the
 * raw join and are accepted.
 * @param bytes - concatenated raw input bytes.
 * @returns the first invalid byte offset, if any.
 */
function firstInvalidUtf8Byte(bytes: Uint8Array): number | undefined {
  let index = 0
  while (index < bytes.length) {
    const first = bytes[index] as number
    if (first < 0x80) {
      index += 1
      continue
    }
    let continuation: number
    let minimum: number
    let codepoint: number
    if ((first & 0xe0) === 0xc0) {
      continuation = 1
      minimum = 0x80
      codepoint = first & 0x1f
    } else if ((first & 0xf0) === 0xe0) {
      continuation = 2
      minimum = 0x800
      codepoint = first & 0x0f
    } else if ((first & 0xf8) === 0xf0) {
      continuation = 3
      minimum = 0x10000
      codepoint = first & 0x07
    } else {
      return index
    }
    if (index + continuation >= bytes.length) return index
    for (let offset = 1; offset <= continuation; offset += 1) {
      const next = bytes[index + offset] as number
      if ((next & 0xc0) !== 0x80) return index
      codepoint = (codepoint << 6) | (next & 0x3f)
    }
    if (codepoint < minimum || codepoint > 0x10ffff
      || (codepoint >= 0xd800 && codepoint <= 0xdfff)) return index
    index += continuation + 1
  }
  return undefined
}

/** Find the source range containing a global byte offset. */
function jqSourceRangeAt(ranges: readonly JqSourceRange[], offset: number): JqSourceRange {
  for (const range of ranges) {
    if (offset < range.end) return range
  }
  return ranges[ranges.length - 1] as JqSourceRange
}

/**
 * The line jq reports after reading the next non-empty source for a primitive
 * token that ended exactly at a source boundary.
 *
 * The parser needs one more byte to terminate a number/literal. If that byte
 * lives in a later source, jq opens it, resets `current_line`, and reads its
 * first chunk; the document then reports that chunk's count (1 when it contains
 * a newline, 0 otherwise). Empty sources are opened and skipped with the
 * counter still at 0. `undefined` means there is no later non-empty source and
 * the per-source value should stand.
 * @param ranges - source ranges in operand order.
 * @param endRange - the range holding the token's last character.
 * @returns the replacement input line, or undefined.
 */
function jqContinuedInputLine(
  ranges: readonly JqSourceRange[],
  endRange: JqSourceRange,
): number | undefined {
  const endIndex = ranges.indexOf(endRange)
  let openedLaterSource = false
  for (let index = endIndex + 1; index < ranges.length; index += 1) {
    openedLaterSource = true
    const bytes = (ranges[index] as JqSourceRange).source.bytes
    if (bytes.length === 0) continue
    return jqFirstLineTerminated(bytes) ? 1 : 0
  }
  return openedLaterSource ? 0 : undefined
}

/** True when a source's last byte can complete the current JSON value. */
function jqEndsWithCompleteValue(bytes: Uint8Array): boolean {
  const last = bytes[bytes.length - 1]
  return last === 0x0a || isJsonHorizontalWhitespace(last)
    || last === 0x7d || last === 0x5d || last === 0x22
}

/** True when bytes contain only JSON horizontal whitespace after an offset. */
function jqHasOnlyHorizontalWhitespace(bytes: Uint8Array, start: number): boolean {
  for (let index = start; index < bytes.length; index += 1) {
    if (!isJsonHorizontalWhitespace(bytes[index])) return false
  }
  return true
}

/**
 * The jq 1.6 `break` position at end of input.
 *
 * jq keeps reporting the last operand while that source is still open. A final
 * newline leaves `file:N`; a value that needed one more byte at EOF, or a
 * primitive without a delimiter, has already closed the source and reports
 * `<unknown>`. A trailing empty operand is reported as `empty:0` when the
 * previous source ended with a complete value, but is consumed while
 * terminating a primitive otherwise. An operand containing only horizontal
 * whitespace remains open at line 0; a leading BOM is ignored for this check
 * only when no earlier operand contributed bytes to the joined stream.
 * @param sources - operands in order.
 * @returns the source and line to print, or `{}` for `<unknown>`.
 */
function jqBreakPosition(sources: readonly JqSource[]): JqBreakPosition {
  const last = sources[sources.length - 1]
  if (last === undefined) return {}
  if (last.bytes.length === 0) {
    let previous = sources.length - 2
    while (previous >= 0 && (sources[previous] as JqSource).bytes.length === 0) previous -= 1
    if (previous < 0) return { source: last.name, line: 0 }
    return jqEndsWithCompleteValue((sources[previous] as JqSource).bytes)
      ? { source: last.name, line: 0 }
      : {}
  }
  const bytes = last.bytes
  const priorStreamIsEmpty = sources.slice(0, -1).every(source => source.bytes.length === 0)
  const leadingBOMLength = priorStreamIsEmpty
    && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf
    ? 3
    : 0
  if (jqHasOnlyHorizontalWhitespace(bytes, leadingBOMLength)) {
    return { source: last.name, line: 0 }
  }
  const lastByte = bytes[bytes.length - 1] as number
  if (lastByte === 0x0a) return { source: last.name, line: jqNewlineCount(bytes) }
  if (isJsonHorizontalWhitespace(lastByte)) {
    let previous = bytes.length - 1
    while (previous >= 0 && isJsonHorizontalWhitespace(bytes[previous])) previous -= 1
    if (previous >= 0 && bytes[previous] === 0x0a) {
      return { source: last.name, line: jqNewlineCount(bytes) }
    }
  }
  return {}
}

/**
 * Parse the concatenated top-level JSON documents of one source.
 * @param text - source text.
 * @returns the documents, or a parse-error diagnostic.
 */
export function parseJqDocuments(text: string): JqSourceResult {
  return parseJqSources([{ name: '<stdin>', bytes: encodeUtf8(text) }])
}

/**
 * Parse the top-level JSON documents of multiple sources as jq 1.6's one
 * continuous byte stream, while reporting `input_line_number` and the source
 * name from the operand that held the document's final byte.
 * @param sources - file/stdin sources in operand order.
 * @returns the documents, or a parse-error diagnostic.
 */
function parseJqSources(sources: readonly JqSource[]): JqSourceResult {
  const ranges: JqSourceRange[] = []
  let total = 0
  for (const source of sources) {
    const newlines: number[] = []
    for (let index = 0; index < source.bytes.length; index += 1) {
      if (source.bytes[index] === 0x0a) newlines.push(index)
    }
    ranges.push({
      source,
      start: total,
      end: total + source.bytes.length,
      newlines,
      checkpoints: jqLineCheckpoints(source.bytes),
    })
    total += source.bytes.length
  }
  if (ranges.length === 0) return { documents: [] }
  const bytes = concatBytes(sources.map(source => source.bytes))
  const invalid = firstInvalidUtf8Byte(bytes)
  if (invalid !== undefined) {
    const range = jqSourceRangeAt(ranges, invalid)
    return {
      error: `invalid UTF-8 byte at source offset ${String(invalid - range.start)}`,
      source: range.source.name,
      kind: 'encoding',
    }
  }
  const decoded = decodeUtf8(bytes)
  // `decodeUtf8` follows the platform default and removes a leading U+FEFF
  // BOM. jq 1.6 skips that BOM at the start of the concatenated stream, but
  // its bytes still count for line numbers and source ownership, so restore it
  // here and skip it in the parser. `byteAt` can then map every decoded
  // character back to the original byte offsets (a BOM is three UTF-8 bytes).
  // A BOM that is not at the very start (for example after a newline or in a
  // later operand) is not skipped, matching native jq's parse error there.
  const combined = bytes.length >= 3
    && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf
    ? `\uFEFF${decoded}`
    : decoded
  const documents: JqDocument[] = []
  let index = combined.charCodeAt(0) === 0xfeff ? 1 : 0
  let mappedChar = 0
  let mappedByte = 0
  const byteAt = (charIndex: number): number => {
    mappedByte += encodeUtf8(combined.slice(mappedChar, charIndex)).byteLength
    mappedChar = charIndex
    return mappedByte
  }
  while (index < combined.length) {
    while (index < combined.length && isJsonWhitespace(combined[index])) index += 1
    if (index >= combined.length) break
    const start = index
    const startByte = byteAt(start)
    const startRange = jqSourceRangeAt(ranges, startByte)
    const startLine = jqLineAt(startRange.newlines, startByte - startRange.start)
    let end: number
    try {
      end = scanJsonValueEnd(combined, start)
    } catch (error) {
      return {
        error: error instanceof Error ? error.message : String(error),
        source: startRange.source.name,
        kind: 'parse',
      }
    }
    if (end <= start) {
      return {
        error: `Invalid JSON at line ${String(startLine)}`,
        source: startRange.source.name,
        kind: 'parse',
      }
    }
    const raw = combined.slice(start, end)
    let value: unknown
    try {
      value = JSON.parse(raw)
      if (jqContainsNonFiniteNumber(value)) {
        return {
          error: `number out of range at line ${String(startLine)}`,
          source: startRange.source.name,
          kind: 'parse',
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return {
        error: `${message} at line ${String(startLine)}`,
        source: startRange.source.name,
        kind: 'parse',
      }
    }
    const endByte = byteAt(end)
    const endRange = jqSourceRangeAt(ranges, endByte - 1)
    const localEnd = endByte - endRange.start
    const endLine = jqLineAt(endRange.newlines, localEnd - 1)
    let inputLine = jqInputLine(endRange.checkpoints, localEnd)
    // jq's lexer needs a delimiter after a number or literal. When the token
    // ends exactly at a source boundary, it opens the next source and resets
    // the line counter before the value is returned. Arrays, objects and
    // strings are complete at their closing delimiter and do not read ahead.
    const primitive = raw[0] !== '{' && raw[0] !== '[' && raw[0] !== '"'
    if (primitive && endByte === endRange.end) {
      const continued = jqContinuedInputLine(ranges, endRange)
      if (continued !== undefined) inputLine = continued
    }
    documents.push({
      value,
      line: startLine,
      endLine,
      inputLine,
      source: startRange.source.name,
    })
    index = end
  }
  return { documents }
}

/** Read one source as raw bytes, resolving a file operand against the command cwd. */
async function readSource(
  ctx: ResolvedCommandContext,
  file: string,
  stdin: { used: boolean },
): Promise<JqSource | { readonly error: string }> {
  if (file === '-') {
    if (stdin.used) return { name: '<stdin>', bytes: new Uint8Array() }
    stdin.used = true
    return { name: '<stdin>', bytes: byteStringToBytes(ctx.stdin as unknown as string) }
  }
  const resolved = posix.resolve(ctx.cwd, file)
  try {
    // jq concatenates operands as raw bytes. `readFile` has already decoded
    // UTF-8 (and replaced invalid sequences), so it cannot be used as a byte
    // source. `readFileBytes` is optional for external IFileSystem
    // implementations; the required `readFileBuffer` is the fallback. A backend
    // that offers neither is refused rather than pretending the decoded text
    // was byte-exact.
    const fs = ctx.fs as unknown as {
      readonly readFileBytes?: ((path: string) => Promise<string>) | undefined
      readonly readFileBuffer?: ((path: string) => Promise<Uint8Array>) | undefined
    }
    if (typeof fs.readFileBytes === 'function') {
      return { name: file, bytes: byteStringToBytes(await fs.readFileBytes(resolved)) }
    }
    if (typeof fs.readFileBuffer === 'function') {
      return { name: file, bytes: new Uint8Array(await fs.readFileBuffer(resolved)) }
    }
    return {
      error: `Could not read ${file}: the filesystem provides neither readFileBytes nor readFileBuffer, so jq cannot join raw input bytes`,
    }
  } catch (error) {
    return { error: `Could not open ${file}: ${error instanceof Error ? error.message : String(error)}` }
  }
}

/** Read every JSON document named by the invocation. */
async function readJqDocuments(
  ctx: ResolvedCommandContext,
  invocation: JqInvocation,
): Promise<
  | { readonly documents: readonly JqDocument[]; readonly breakPosition: JqBreakPosition }
  | { readonly error: string; readonly exitCode: number }
> {
  const stdin = { used: false }
  const sourceNames = invocation.files.length > 0 ? invocation.files : ['-']
  const sources: JqSource[] = []
  for (const file of sourceNames) {
    const source = await readSource(ctx, file, stdin)
    if ('error' in source) return { error: source.error, exitCode: 2 }
    sources.push(source)
  }
  const parsed = parseJqSources(sources)
  if ('error' in parsed) {
    if (parsed.kind === 'encoding') {
      return {
        error: `invalid UTF-8 input is not supported by the Worker jq shim (${parsed.error}; ${parsed.source ?? sourceNames[0]})`,
        exitCode: 2,
      }
    }
    return {
      error: `parse error: ${parsed.error} (${parsed.source ?? sourceNames[0]})`,
      exitCode: JQ_PARSE_ERROR_EXIT,
    }
  }
  return { documents: parsed.documents, breakPosition: jqBreakPosition(sources) }
}

/** A jq-shaped diagnostic result. */
function jqFailure(message: string, exitCode: number): ExecResult {
  return { stdout: '', stderr: `jq: ${message}\n`, exitCode }
}

/** The variable names bound by `--arg`, `--argjson`, `--rawfile` and `--slurpfile`. */
function jqBoundOptionNames(options: readonly string[]): string[] {
  const names: string[] = []
  for (let index = 0; index < options.length; index += 1) {
    if (!JQ_VALUE_LONG_OPTIONS.has(options[index] as string)) continue
    const name = options[index + 1]
    if (name !== undefined) names.push(name)
    index += 2
  }
  return names
}

/**
 * Refuse an input-family combination the per-document wrapper cannot model.
 * @param invocation - parsed invocation.
 * @param plan - the input-family plan.
 * @throws JqShimError with the concrete limitation.
 */
function assertSupported(invocation: JqInvocation, plan: JqShimPlan): void {
  for (const name of jqBoundOptionNames(invocation.options)) {
    if (JQ_INTERNAL_VARIABLES.has(name)) {
      throw new JqShimError(
        `the variable name '${name}' is reserved for the Worker jq shim's internal state; choose another --arg/--argjson/--rawfile/--slurpfile name`,
      )
    }
  }
  if (invocation.slurp || invocation.rawInput) {
    const mode = invocation.slurp ? '--slurp' : '--raw-input'
    throw new JqShimError(
      `${mode} together with inputs/input/input_line_number is not supported by the Worker jq shim; use an NDJSON stream or file operands`,
    )
  }
  if (plan.usesInputs && plan.usesInput) {
    throw new JqShimError(
      'a filter combining inputs and input is not supported by the Worker jq shim; the two consume the stream differently',
    )
  }
  if (plan.inputCount > 1) {
    throw new JqShimError(
      'a filter calling input more than once is not supported by the Worker jq shim; it would consume more than one following document per outer document',
    )
  }
  if (plan.inputsCount > 1) {
    throw new JqShimError(
      'a filter calling inputs more than once is not supported by the Worker jq shim; the stream is consumed by the first call',
    )
  }
  if (plan.unsupportedInputInterpolation) {
    throw new JqShimError(
      'inputs inside a string interpolation is supported only as a liftable whole body in a value position (not as a function argument); input and input_line_number interpolation is supported only as one bare function in the sole interpolation; multi-value bodies are unsupported',
    )
  }
  if (plan.usesLineNumber && (plan.usesInput || plan.usesInputs)) {
    throw new JqShimError(
      'input_line_number combined with input/inputs is not supported by the Worker jq shim; the line number after a consumption is not the current document line',
    )
  }
  if (plan.usesInput || plan.usesInputs) {
    const unsafe = findUnsafeInputConsumption(invocation.filter ?? '')
    if (unsafe !== undefined) {
      throw new JqShimError(
        `conditional or lazy input consumption is not supported by the Worker jq shim (${unsafe} can skip or repeat input); evaluate input/inputs unconditionally`,
      )
    }
  }
  if (plan.usesInput || plan.usesInputs) {
    const argument = findUnsafeInputsValueArgument(invocation.filter ?? '')
    if (argument !== undefined) {
      const reason = argument.includes('inputs')
        ? 'jq evaluates the call once per remaining input, but the built-in keeps only the first value, so collect the inputs first (for example [inputs])'
        : 'a function may evaluate its argument zero or more times, so bind the consumed value first (for example input as $x)'
      throw new JqShimError(
        `${argument} is not supported by the Worker jq shim; ${reason}`,
      )
    }
  }
  if (hasJqDefDeclaration(invocation.filter ?? '')) {
    throw new JqShimError(
      'a filter that defines functions and names inputs/input/input_line_number is not supported by the Worker jq shim; a user definition can shadow the built-in name',
    )
  }
}

/**
 * Keep an option value from being mistaken for the built-in's `--help` flag.
 * @param option - a value-taking jq option.
 * @param name - its variable name.
 * @param value - its value or file operand.
 * @param cwd - the invocation's current working directory.
 * @returns equivalent built-in argv tokens with no exact `--help` value.
 */
function jqReplayValueOption(
  option: string,
  name: string | undefined,
  value: string | undefined,
  cwd: string,
): string[] {
  if (name === undefined) return [option]
  if (value === undefined) return [option, name]
  if (value !== '--help') return [option, name, value]
  if (option === '--arg') return ['--argjson', name, JSON.stringify(value)]
  if (option === '--argjson') return [option, name, `${value} `]
  // A relative filename beginning with `--help` is option data; resolve it so
  // the pinned built-in cannot mistake the exact token for the help switch.
  return [option, name, posix.resolve(cwd, value)]
}

/**
 * The variable/positional-argument options to replay on an `-e` status probe.
 * Output-shaping flags are omitted so the probe always emits plain JSON.
 * @param options - the parsed option tokens (values included).
 * @param cwd - the invocation's current working directory.
 * @returns the options that bind variables or positional arguments.
 */
function jqBindingOptions(options: readonly string[], cwd: string): string[] {
  const bindings: string[] = []
  for (let index = 0; index < options.length; index += 1) {
    const token = options[index] as string
    if (JQ_VALUE_LONG_OPTIONS.has(token)) {
      const first = options[index + 1]
      const second = options[index + 2]
      bindings.push(...jqReplayValueOption(token, first, second, cwd))
      if (first !== undefined) index += 1
      if (second !== undefined) index += 1
      continue
    }
    if (token === '--args' || token === '--jsonargs') bindings.push(token)
  }
  return bindings
}

/**
 * Find a reference that the built-in's unreachable-branch probe cannot compile
 * check. The jq implementation resolves names lazily, so empty-input calls
 * validate function and variable references against its public `builtins`
 * query before running that non-executing syntax/option probe.
 */
function jqZeroInputCallArity(filter: string, nameEnd: number, end: number): number | undefined {
  const open = nextSignificant(filter, nameEnd)
  if (open >= end || filter[open] !== '(') return 0
  let nesting = 1
  let separators = 0
  let hasArgument = false
  let index = open + 1
  while (index < end) {
    const character = filter[index] as string
    if (character === '"') {
      const scanned = scanJqString(filter, index)
      hasArgument = true
      index = scanned.end
      continue
    }
    if (character === '#') {
      while (index < end && filter[index] !== '\n') index += 1
      continue
    }
    if (character === '(' || character === '[' || character === '{') {
      nesting += 1
      hasArgument = true
      index += 1
      continue
    }
    if (character === ')' || character === ']' || character === '}') {
      nesting -= 1
      if (nesting === 0) return hasArgument ? separators + 1 : undefined
      hasArgument = true
      index += 1
      continue
    }
    if (character === ';' && nesting === 1) {
      separators += 1
      hasArgument = false
      index += 1
      continue
    }
    if (!/\s/u.test(character)) hasArgument = true
    index += 1
  }
  return hasArgument ? separators + 1 : undefined
}

/** The variables a bounded `as`/`label` pattern declares and its end offset. */
interface JqBindingScan {
  /** Declared variable names, in pattern order. */
  readonly names: readonly string[]
  /** Offset just past the pattern. */
  readonly end: number
}

/** One lexical scope for the bounded `as`/`label` variable check. */
interface JqScopeNode {
  /** Enclosing scope; `undefined` for the filter's root scope. */
  readonly parent: JqScopeNode | undefined
}

/**
 * True when `scope` is `ancestor` or one of its descendants.
 * @param scope - reference's lexical scope.
 * @param ancestor - declaration's lexical scope.
 * @returns whether the declaration is visible at the reference.
 */
function jqScopeContains(scope: JqScopeNode, ancestor: JqScopeNode): boolean {
  let current: JqScopeNode | undefined = scope
  while (current !== undefined) {
    if (current === ancestor) return true
    current = current.parent
  }
  return false
}

/**
 * Scan a simple `$name` binding after an `as` or `label` keyword.
 *
 * The shim deliberately does not model destructuring/alternative patterns
 * (`as {a: $x}`, `as [$x]`, `as $x ?// $y`): a partial scan used to accept
 * them and then silently fabricated `null`/no output where native jq either
 * destructures or fails at runtime. Only the whole pattern `$name` is proven;
 * anything else returns undefined and makes the caller fail loud.
 * @param filter - jq filter text.
 * @param start - offset just past the `as`/`label` token.
 * @param end - exclusive end of the scanned range.
 * @returns the declared name and the pattern end, or undefined when unprovable.
 */
function scanJqBindingNames(
  filter: string,
  start: number,
  end: number,
): JqBindingScan | undefined {
  const index = nextSignificant(filter, start)
  if (index >= end || filter[index] !== '$') return undefined
  const nameStart = index + 1
  if (!/[A-Za-z_]/u.test(filter[nameStart] ?? '')) return undefined
  let tokenEnd = nameStart + 1
  while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
  const name = filter.slice(nameStart, tokenEnd)
  // `as`/`label` take a simple `$name` followed by `|`. The next significant
  // token check keeps `as $x` in a function argument or object value from being
  // accepted as if its scope extended to the next `;`/`,`/`}`; it also refuses
  // `?//` alternative patterns, which this scanner does not model.
  const afterPattern = nextSignificant(filter, tokenEnd)
  if (afterPattern >= end || filter[afterPattern] !== '|') return undefined
  return { names: [name], end: tokenEnd }
}

/** The kind of one lexical variable binding. */
type JqBindingKind = 'as' | 'label'

/** One collected `as`/`label` declaration. */
interface JqBinding {
  readonly name: string
  readonly index: number
  readonly scope: JqScopeNode
  readonly kind: JqBindingKind
}

/** A reference the bounded validator could not prove. */
interface JqUnknownReference {
  readonly kind: 'function' | 'variable' | 'variable-name' | 'scope' | 'label' | 'reserved' | 'args' | 'syntax' | 'control-flow' | 'break'
  readonly name: string
}

function findUnknownJqReference(
  filter: string,
  knownFunctions: ReadonlySet<string>,
  boundVariables: ReadonlySet<string>,
  scopePolicy: 'refuse' | 'check-bindings',
): JqUnknownReference | undefined {
  const keywords = new Set([
    'if', 'elif', 'then', 'else', 'end', 'as', 'try', 'catch', 'reduce',
    'foreach', 'label', 'break', 'def', 'import', 'include',
    'module', 'true', 'false', 'null', 'and', 'or',
  ])
  // These introduce a syntactic boundary that is not a bracket: an `as`
  // declaration inside a branch/init/update/extract does not extend to the
  // sibling branch. The shim does not implement that full lexical model, so a
  // declaration after one of them is refused instead of being treated as
  // top-level.
  const controlKeywords = new Set(['if', 'elif', 'then', 'else', 'reduce', 'foreach', 'try', 'catch'])
  const functions = new Set([...knownFunctions, ...JQ_INPUT_FUNCTIONS.map(name => name + '/0')])
  // `$ARGS` would expose the shim's injected `--argjson` values through
  // `$ARGS.named`; `$__loc__` is not implemented by the pinned built-in.
  const variables = new Set([...boundVariables, 'ENV'])
  const referencedVariables: {
    readonly name: string
    readonly index: number
    readonly scope: JqScopeNode
    readonly breakTarget: boolean
  }[] = []
  const bindings: JqBinding[] = []
  const functionsToValidate: { readonly name: string; readonly arity: number | undefined }[] = []
  let hasBindingScope = false
  let unprovableBindingScope = false
  let reservedBindingName: string | undefined
  let invalidVariableName: string | undefined
  let invalidIfControl = false
  let hasBareBreak = false
  const scan = (
    start: number,
    end: number,
    outerScope: JqScopeNode,
    inheritedControl: boolean,
  ): void => {
    interface Frame {
      readonly kind: '{' | '[' | '('
      entryStart: boolean
      scope: JqScopeNode
      control: boolean
    }
    const stack: Frame[] = []
    const ifFrames: { state: 'condition' | 'then' | 'else'; depth: number }[] = []
    const currentScope = (): JqScopeNode => stack[stack.length - 1]?.scope ?? outerScope
    let rootControl = inheritedControl
    const hasControl = (): boolean => rootControl || stack.some(frame => frame.control)
    const markControl = (): void => {
      const top = stack[stack.length - 1]
      if (top === undefined) rootControl = true
      else top.control = true
    }
    let previousCodeIndex = -1
    let previousToken: string | undefined
    let index = start
    while (index < end) {
      const character = filter[index] as string
      if (character === '"') {
        const scanned = scanJqString(filter, index)
        for (const interpolation of scanned.interpolations) {
          scan(
            Math.max(interpolation.start, start),
            Math.min(interpolation.end, end),
            { parent: currentScope() },
            hasControl(),
          )
        }
        index = scanned.end
        previousCodeIndex = index - 1
        previousToken = '"'
        continue
      }
      if (character === '#') {
        while (index < end && filter[index] !== '\n') index += 1
        continue
      }
      if (character === '{') {
        stack.push({ kind: '{', entryStart: true, scope: { parent: currentScope() }, control: false })
        previousCodeIndex = index
        previousToken = character
        index += 1
        continue
      }
      if (character === '[' || character === '(') {
        stack.push({ kind: character, entryStart: false, scope: { parent: currentScope() }, control: false })
        previousCodeIndex = index
        previousToken = character
        index += 1
        continue
      }
      if (character === '}' || character === ']' || character === ')') {
        const expected = character === '}' ? '{' : character === ']' ? '[' : '('
        if (stack[stack.length - 1]?.kind === expected) stack.pop()
        previousCodeIndex = index
        previousToken = character
        index += 1
        continue
      }
      if (character === ',') {
        const top = stack[stack.length - 1]
        if (top?.kind === '{') top.entryStart = true
        previousCodeIndex = index
        previousToken = character
        index += 1
        continue
      }
      if (character === ':') {
        const top = stack[stack.length - 1]
        if (top?.kind === '{') top.entryStart = false
        previousCodeIndex = index
        previousToken = character
        index += 1
        continue
      }
      if (character === ';') {
        // Function arguments are separated by `;`. A declaration in one
        // argument is not visible in the next: create a sibling scope rather
        // than a child of the current argument scope, so bindings recorded
        // before the separator cannot cover references after it.
        const top = stack[stack.length - 1]
        if (top !== undefined) top.scope = { parent: top.scope.parent }
        previousCodeIndex = index
        previousToken = character
        index += 1
        continue
      }
      const numericEnd = jqNumericLiteralEnd(filter, index, end)
      if (numericEnd !== undefined) {
        previousCodeIndex = numericEnd - 1
        previousToken = 'number'
        index = numericEnd
        continue
      }
      if (character === '$') {
        // jq 1.6 accepts `$IDENT` and the special `$__loc__`; a keyword after
        // `$` or a token starting with a digit is a syntax error, not a name
        // the built-in may lazily resolve to null.
        const nameStart = index + 1
        if (/[A-Za-z_]/u.test(filter[nameStart] ?? '')) {
          let tokenEnd = nameStart + 1
          while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
          const name = filter.slice(nameStart, tokenEnd)
          if (JQ_VARIABLE_KEYWORDS.has(name)) {
            invalidVariableName ??= name
          } else {
            referencedVariables.push({
              name,
              index,
              scope: currentScope(),
              breakTarget: previousToken === 'break',
            })
          }
          previousCodeIndex = tokenEnd - 1
          previousToken = `$${name}`
          index = tokenEnd
          continue
        }
        let tokenEnd = index + 1
        while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
        const invalid = filter.slice(index, tokenEnd)
        invalidVariableName ??= invalid === '' ? '$' : invalid
        previousCodeIndex = tokenEnd - 1
        previousToken = invalid
        index = tokenEnd
        continue
      }
      if (/[A-Za-z_]/u.test(character)) {
        let tokenEnd = index + 1
        while (tokenEnd < end && isIdentifierCharacter(filter[tokenEnd])) tokenEnd += 1
        const name = filter.slice(index, tokenEnd)
        const previous = previousCodeIndex >= 0 ? filter[previousCodeIndex] : undefined
        const after = nextSignificant(filter, tokenEnd)
        const top = stack[stack.length - 1]
        const objectKey = top?.kind === '{' && top.entryStart
          && (after >= end || filter[after] === ':' || filter[after] === ',' || filter[after] === '}')
        const bareKeyword = previous !== '.' && previous !== '$' && previous !== '@'
        // `. as $x` has the same previous-code character as the `.as` field,
        // but only without whitespace is it a field access.
        const adjacentMember = previousCodeIndex === index - 1
          && (previous === '.' || previous === '$' || previous === '@')
        const structuralKeyword = !adjacentMember && !objectKey
        if (controlKeywords.has(name) && structuralKeyword) {
          markControl()
        }
        if (structuralKeyword) {
          if (name === 'if') {
            ifFrames.push({ state: 'condition', depth: stack.length })
          } else if (name === 'then' || name === 'elif' || name === 'else' || name === 'end') {
            const current = ifFrames[ifFrames.length - 1]
            if (current === undefined || current.depth !== stack.length) {
              invalidIfControl = true
            } else if (name === 'then') {
              if (current.state !== 'condition') invalidIfControl = true
              else current.state = 'then'
            } else if (name === 'elif') {
              if (current.state !== 'then') invalidIfControl = true
              else current.state = 'condition'
            } else if (name === 'else') {
              if (current.state !== 'then') invalidIfControl = true
              else current.state = 'else'
            } else if (current.state !== 'else') {
              invalidIfControl = true
            } else {
              ifFrames.pop()
            }
          }
        }
        if ((name === 'as' || name === 'label') && !adjacentMember && !objectKey) {
          hasBindingScope = true
          const binding = scanJqBindingNames(filter, tokenEnd, end)
          // An `as`/`label` directly in an object value is a jq syntax error;
          // only a parenthesized expression (`{a: (1 as $x | $x)}`) binds
          // there. The top frame is the object only when the declaration is not
          // nested in its own bracket.
          const inObjectValue = top?.kind === '{' && !top.entryStart
          if (binding === undefined || hasControl() || inObjectValue) {
            unprovableBindingScope = true
          }
          if (binding !== undefined) {
            for (const bound of binding.names) {
              if (JQ_INTERNAL_VARIABLES.has(bound)) reservedBindingName = bound
              if (!isJqBindingName(bound)) {
                unprovableBindingScope = true
                continue
              }
              bindings.push({
                name: bound,
                index: binding.end,
                scope: currentScope(),
                kind: name === 'label' ? 'label' : 'as',
              })
            }
            previousCodeIndex = binding.end - 1
            previousToken = name
            index = binding.end
            continue
          }
        }
        if (!keywords.has(name) && bareKeyword && !objectKey) {
          functionsToValidate.push({
            name,
            arity: jqZeroInputCallArity(filter, tokenEnd, end),
          })
        }
        if (name === 'break' && bareKeyword && !objectKey) hasBareBreak = true
        previousCodeIndex = tokenEnd - 1
        // Only a bare `break` is the label-target keyword; `.break`/`{break:}`
        // are a field/object key and cannot make the next `$name` a target.
        previousToken = name === 'break' && bareKeyword && !objectKey ? 'break' : name
        index = tokenEnd
        continue
      }
      if (!/\s/u.test(character)) {
        previousCodeIndex = index
        previousToken = character
      }
      index += 1
    }
    if (ifFrames.length > 0) invalidIfControl = true
  }
  const rootScope: JqScopeNode = { parent: undefined }
  scan(0, filter.length, rootScope, false)
  if (reservedBindingName !== undefined) {
    return { kind: 'reserved', name: reservedBindingName }
  }
  if (invalidVariableName !== undefined) {
    return { kind: 'variable-name', name: invalidVariableName }
  }
  if (invalidIfControl) {
    return { kind: 'control-flow', name: 'if/elif/then/else/end' }
  }
  if (hasBindingScope && scopePolicy === 'refuse') {
    return { kind: 'scope', name: 'as/label binding scope' }
  }
  if (unprovableBindingScope) {
    return { kind: 'scope', name: 'as/label binding scope' }
  }
  for (const reference of referencedVariables) {
    const asCovered = bindings.some(binding =>
      binding.kind === 'as'
      && binding.name === reference.name
      && binding.index < reference.index
      && jqScopeContains(reference.scope, binding.scope))
    const labelCovered = bindings.some(binding =>
      binding.kind === 'label'
      && binding.name === reference.name
      && binding.index < reference.index
      && jqScopeContains(reference.scope, binding.scope))
    // A label target is a separate namespace: only a visible `label` binding
    // can satisfy `break $name`; an `as` binding or `--arg` cannot.
    if (reference.breakTarget) {
      if (labelCovered) continue
      return { kind: 'label', name: reference.name }
    }
    if (reference.name === 'ARGS') return { kind: 'args', name: 'ARGS' }
    // `$__loc__` is a lexer special, not an ordinary variable. `--arg
    // __loc__` does not replace it in jq 1.6, and the pinned built-in does not
    // implement the location value, so it never becomes a whitelisted name.
    if (reference.name === JQ_LOCATION_VARIABLE) return { kind: 'variable', name: JQ_LOCATION_VARIABLE }
    if (variables.has(reference.name)) continue
    if (asCovered) continue
    // A label variable is only legal as a `break` target. Native jq reports a
    // compile error for `label $x | $x`, `[$x]` and `"\($x)"`; the shim
    // refuses instead of resolving the label name as a null value.
    if (labelCovered) return { kind: 'label', name: reference.name }
    return { kind: 'variable', name: reference.name }
  }
  for (const reference of functionsToValidate) {
    if (reference.arity === undefined) {
      return { kind: 'syntax', name: reference.name + '()' }
    }
    if (!functions.has(reference.name + '/' + String(reference.arity))) {
      return { kind: 'function', name: reference.name + '/' + String(reference.arity) }
    }
  }
  // The pinned evaluator can discard values already produced inside a label
  // body when `break` interrupts it. Refuse all input-family breaks instead of
  // guessing from nearby `then`/`else` tokens that no earlier value was lost.
  // Empty-input compile validation never evaluates the filter and retains jq's
  // compile-only behavior.
  if (scopePolicy === 'check-bindings' && hasBareBreak) {
    return { kind: 'break', name: 'break' }
  }
  return undefined
}

/** Format the bounded validator's diagnostic for an input-family filter. */
function jqUnknownReferenceMessage(
  unknown: JqUnknownReference,
  emptyInput: boolean,
): string {
  const lead = emptyInput ? 'empty-input compile validation ' : 'compile validation '
  if (unknown.kind === 'scope') {
    return lead + 'cannot prove ' + unknown.name + '; this filter shape is unsupported'
  }
  if (unknown.kind === 'label') {
    return lead + "cannot use label variable '" + unknown.name + "' as a value; label variables are only valid as break targets"
  }
  if (unknown.kind === 'reserved') {
    return "the variable name '" + unknown.name + "' is reserved for the Worker jq shim's internal state; choose another as/label binding"
  }
  if (unknown.kind === 'args') {
    return lead + "cannot expose $ARGS in an input-family filter; the shim's injected state would appear in $ARGS.named"
  }
  if (unknown.kind === 'variable-name') {
    return lead + "cannot accept '" + unknown.name + "' as a variable name; jq 1.6 reserves that token after '$'"
  }
  if (unknown.kind === 'syntax') {
    return lead + "cannot accept the empty argument list of '" + unknown.name + "'; jq 1.6 reports a syntax error there"
  }
  if (unknown.kind === 'control-flow') {
    return lead + 'cannot validate ' + unknown.name + ' pairing; this input-family filter shape is unsupported'
  }
  if (unknown.kind === 'break') {
    return lead + 'cannot prove this input-family label-break shape preserves output; the built-in may drop values produced before break'
  }
  return lead + "cannot resolve " + unknown.kind + " '" + unknown.name + "'; this filter shape is unsupported"
}

/**
 * Strip `-e`/`--exit-status` (whole or inside a combined short flag) from the
 * options forwarded to the built-in. The shim computes the real jq status from
 * the last output itself; the built-in's "every output was false/null" rule
 * would otherwise misreport filters such as `1, false`.
 * @param options - the parsed option tokens (values included).
 * @param cwd - the invocation's current working directory.
 * @returns the options without the exit-status flag.
 */
function jqEvaluationOptions(options: readonly string[], cwd: string): string[] {
  const evaluation: string[] = []
  for (let index = 0; index < options.length; index += 1) {
    const token = options[index] as string
    if (JQ_VALUE_LONG_OPTIONS.has(token)) {
      const first = options[index + 1]
      const second = options[index + 2]
      evaluation.push(...jqReplayValueOption(token, first, second, cwd))
      if (first !== undefined) index += 1
      if (second !== undefined) index += 1
      continue
    }
    if (token === '--exit-status') continue
    if (token.startsWith('-') && !token.startsWith('--') && token.length > 1) {
      const letters = token.slice(1)
      if (letters.includes('e')) {
        const remaining = letters.replaceAll('e', '')
        if (remaining !== '') evaluation.push(`-${remaining}`)
        continue
      }
    }
    evaluation.push(token)
  }
  return evaluation
}

/**
 * The jq 1.6 `-e` status for one probe's final output.
 * @param stdout - the probe's stdout (one compact JSON value, or empty).
 * @returns 0 for a truthy last output, 1 for `false`/`null`, undefined when the
 *   filter produced no output.
 */
/**
 * The jq 1.6 -e status for one probe's final output.
 * The probe emits a JSON boolean so non-finite numeric values remain truthy
 * even when jq's JSON serializer renders them as null.
 */
function jqProbeExitStatus(stdout: string): number | undefined {
  const trimmed = stdout.trim()
  if (trimmed === '') return undefined
  const value: unknown = JSON.parse(trimmed)
  if (typeof value !== 'boolean') throw new Error('status probe did not return a boolean')
  return value ? 0 : 1
}

/**
 * Evaluate one invocation through the built-in with the input variables
 * injected.
 * @param invocation - parsed invocation.
 * @param plan - the rewritten filter plan.
 * @param documents - every parsed input document.
 * @param cwd - the invocation's current working directory.
 * @param runBuiltin - the shadowed `jq` argv runner.
 * @returns the combined command result.
 */
async function evaluateJq(
  invocation: JqInvocation,
  plan: JqShimPlan,
  documents: readonly JqDocument[],
  breakPosition: JqBreakPosition,
  cwd: string,
  runBuiltin: (args: string[]) => Promise<ExecResult>,
): Promise<ExecResult> {
  const outer: readonly JqDocument[] = invocation.nullInput
    ? [{ value: null, line: 0, endLine: 0, inputLine: 0, source: '<stdin>' }]
    : documents
  const evaluationOptions = jqEvaluationOptions(invocation.options, cwd)
  const bindingOptions = jqBindingOptions(invocation.options, cwd)
  let stdout = ''
  let stderr = ''
  // jq 1.6's -e status comes from the last processed outer document, not from
  // the last value emitted by the whole stream: a final document that emits
  // nothing is status 4 even when an earlier document emitted a truthy value.
  let lastExitStatus: number | undefined
  const registry = await runBuiltin(['-n', '-c', 'builtins'])
  let builtinNames: Set<string>
  try {
    const entries: unknown = JSON.parse(registry.stdout.trim())
    if (registry.exitCode !== 0 || !Array.isArray(entries)
      || entries.some(entry => typeof entry !== 'string')) {
      throw new Error('builtins query returned an unexpected shape')
    }
    builtinNames = new Set(entries as string[])
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return jqFailure(`unable to validate filter names (${message})`, 2)
  }
  const boundVariables = new Set(jqBoundOptionNames(invocation.options))
  // jq 1.6 does not enter the filter at all when a non-null invocation has no
  // input document, and reports success rather than the "no output" status 4.
  if (!invocation.nullInput && outer.length === 0) {
    // jq compiles the filter and validates its binding/file options even when
    // there is no input document, but it never evaluates the filter. Keep that
    // boundary by compiling the rewritten filter in an unreachable branch.
    // This catches syntax/unknown-function/option errors without triggering
    // filter runtime errors or consuming the input stream.
    const validation = await runBuiltin([
      ...evaluationOptions,
      '-n',
      '--argjson', JQ_INTERNAL_CURRENT, 'null',
      '--argjson', JQ_INTERNAL_INPUTS, '[]',
      '--argjson', JQ_INTERNAL_LINE, '0',
      `if false then (${plan.filter}\n) else empty end`,
      ...invocation.positional,
    ])
    if (validation.exitCode !== 0) {
      return { stdout: validation.stdout, stderr: validation.stderr, exitCode: validation.exitCode }
    }
    const unknown = findUnknownJqReference(
      invocation.filter ?? '',
      builtinNames,
      boundVariables,
      'refuse',
    )
    if (unknown !== undefined) {
      return jqFailure(jqUnknownReferenceMessage(unknown, true), 2)
    }
    return { stdout: '', stderr: '', exitCode: 0 }
  }
  // The built-in resolves function/variable names lazily and silently treats an
  // unknown variable as null (and wrong arities can be ignored), so validate
  // names before the first evaluation too. `as`/label bindings are collected in
  // their bounded lexical scope; a reference that no declaration covers still
  // fails loud, and an unparseable pattern refuses the whole filter. This is a
  // fail-loud boundary, never a false success.
  const unknownName = findUnknownJqReference(
    invocation.filter ?? '',
    builtinNames,
    boundVariables,
    'check-bindings',
  )
  if (unknownName !== undefined) {
    return jqFailure(jqUnknownReferenceMessage(unknownName, false), 2)
  }
  for (let index = 0; index < outer.length;) {
    const current = outer[index] as JqDocument
    let documentStatus: number | undefined
    // Inject only the documents this plan consumes. A line-number-only filter
    // gets no stream array; input gets at most its next document; inputs gets
    // the remaining stream once. This avoids serializing every suffix of an
    // NDJSON file for each outer document.
    const inputDocuments = plan.usesInputs
      ? invocation.nullInput ? documents : documents.slice(index + 1)
      : plan.usesInput
        ? invocation.nullInput ? documents.slice(0, 1) : documents.slice(index + 1, index + 2)
        : []
    // An exhausted input is jq's break, not a fabricated null document.
    if (plan.usesInput && inputDocuments.length === 0) {
      const position = breakPosition.source !== undefined && breakPosition.line !== undefined
        ? `${breakPosition.source}:${String(breakPosition.line)}`
        : '<unknown>'
      return {
        stdout,
        stderr: stderr + `jq: error (at ${position}): break\n`,
        exitCode: JQ_BREAK_EXIT,
      }
    }
    const injections = [
      '--argjson', JQ_INTERNAL_CURRENT, JSON.stringify(current.value),
      ...(plan.usesInput || plan.usesInputs
        ? ['--argjson', JQ_INTERNAL_INPUTS, JSON.stringify(inputDocuments.map(document => document.value))]
        : []),
      ...(plan.usesLineNumber
        ? ['--argjson', JQ_INTERNAL_LINE, String(current.inputLine)]
        : []),
    ]
    const args = [
      ...evaluationOptions,
      '-n',
      ...injections,
      `$${JQ_INTERNAL_CURRENT} | (${plan.filter}\n)`,
      ...invocation.positional,
    ]
    const result = await runBuiltin(args)
    stdout += result.stdout
    stderr += result.stderr
    if (result.exitCode !== 0) return { stdout, stderr, exitCode: result.exitCode }
    if (invocation.exitStatus) {
      // jq's -e status is decided by the last output of the whole stream. A
      // `last(...)` probe with plain JSON output keeps that decision exact for
      // every output mode (-r/-j included) without parsing user-formatted
      // bytes. An empty probe means this document produced no output.
      const probe = await runBuiltin([
        ...bindingOptions,
        '-n',
        ...injections,
        `last($${JQ_INTERNAL_CURRENT} | (${plan.filter}\n)) | (type == "number" or (. != false and . != null))`,
        ...invocation.positional,
      ])
      if (probe.exitCode !== 0) {
        return { stdout, stderr: stderr + probe.stderr, exitCode: probe.exitCode }
      }
      let status: number | undefined
      try {
        status = jqProbeExitStatus(probe.stdout)
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return {
          stdout,
          stderr: `${stderr}jq: error: unable to determine --exit-status from the filter output (${message})\n`,
          exitCode: JQ_STATUS_PROBE_ERROR_EXIT,
        }
      }
      if (status !== undefined) documentStatus = status
    }
    if (invocation.exitStatus) lastExitStatus = documentStatus ?? JQ_EXIT_STATUS_NO_OUTPUT
    if (invocation.nullInput) break
    // For the accepted (unconditional) filters these counts are the actual
    // consumption: `inputs` takes every remaining document, `input` takes
    // exactly one following document, and a line-number-only filter takes none.
    if (plan.usesInputs) break
    index += plan.usesInput ? 2 : 1
  }
  if (invocation.exitStatus) return { stdout, stderr, exitCode: lastExitStatus ?? JQ_EXIT_STATUS_NO_OUTPUT }
  return { stdout, stderr, exitCode: 0 }
}

/**
 * Read the toolbox the Worker entry published.
 *
 * The shell bundle keeps its runtime dependencies to just-bash and exec-bridge;
 * the toolbox is already a Worker global (`setWorkerToolbox`), so reading that
 * slot avoids a second runtime package edge for the same object.
 */
function currentWorkerToolbox(): WorkerToolbox | undefined {
  const value = (globalThis as { __PDSH_WASI_TOOLBOX__?: unknown }).__PDSH_WASI_TOOLBOX__
  if (typeof value !== 'object' || value === null) return undefined
  const candidate = value as Partial<WorkerToolbox>
  return typeof candidate.run === 'function' && typeof candidate.list === 'function'
    ? candidate as WorkerToolbox
    : undefined
}

/** Environment one just-bash context exports, matching the toolbox adapter. */
function jqShellEnvironment(context: ResolvedCommandContext): Record<string, string> {
  const candidate = context as unknown as {
    readonly env?: ReadonlyMap<string, string> | Readonly<Record<string, string>>
    readonly exportedEnv?: Readonly<Record<string, string>>
  }
  if (candidate.exportedEnv !== undefined) return { ...candidate.exportedEnv }
  const env = candidate.env
  if (env === undefined) return {}
  if (typeof (env as ReadonlyMap<string, string>).get === 'function') {
    return Object.fromEntries(env as ReadonlyMap<string, string>)
  }
  return { ...(env as Readonly<Record<string, string>>) }
}

/** True when argv is a `jq --version` probe. */
function isJqVersionProbe(args: readonly string[]): boolean {
  return scanGnuArgv('jq', args).longOptions.has('--version')
}

/**
 * A safe guest cwd for a version probe outside every preopen.
 *
 * `jq --version` reads no file and must answer with the bound engine's identity
 * even when the shell cwd is an unmapped but legal directory (`/`, `/dsh`,
 * ...). The direct `jq-wasi --version` bridge has no cwd to map and falls back
 * to the toolbox's configured default, so the wrapper uses the first preopen
 * when one exists and otherwise leaves the cwd to the toolbox. This fallback is
 * only for the version probe; every input-reading invocation still fails loud
 * when its cwd cannot be mapped.
 * @param toolbox - toolbox whose preopens describe a usable guest directory.
 * @returns a guest directory, or undefined to keep the toolbox default.
 */
function versionProbeGuestCwd(toolbox: WorkerToolbox): string | undefined {
  const preopen = toolbox.preopenTable?.[0]
  if (preopen === undefined) return undefined
  return preopen.guestPath.replace(/\/+$/u, '') || '/'
}

/**
 * Run one invocation through the real WASI jq engine.
 *
 * The engine reads and writes only through the toolbox's preopened Worker VFS,
 * receives the shell's exported environment and cwd, and returns the guest's
 * real exit status. Cancellation and the budget ceiling are the existing
 * hot-instance/worker path (the toolbox's `terminate` and memory limit), not a
 * second execution lane.
 *
 * stdout/stderr are captured through a bounded per-stream collector and the
 * same caps are passed to the toolbox, so an infinite `jq` generator cannot
 * grow the host heap before the shell's display truncation runs. Crossing a
 * cap aborts the dispatch through its normal signal path (the toolbox drops
 * the WASM worker) and turns into an explicit `E_OUTPUT_LIMIT` failure.
 * @param args - argv after the program name.
 * @param ctx - the shell context that supplies stdin/cwd/env/signal.
 * @param toolbox - the published toolbox that registered `jq-wasi`.
 * @returns the command result, or undefined when the engine is not registered.
 */
async function runJqEngine(
  args: readonly string[],
  ctx: ResolvedCommandContext,
  toolbox: WorkerToolbox,
): Promise<ExecResult | undefined> {
  if (!toolbox.has(JQ_ENGINE_PROGRAM)) return undefined
  const versionProbe = isJqVersionProbe(args)
  const mappedCwd = guestCwdFor(toolbox, ctx.cwd)
  if (mappedCwd === undefined && !versionProbe) {
    return jqFailure(`jq: cannot map the shell cwd ${ctx.cwd} into the WASI file view`, 1)
  }
  // `--version` must not depend on a mapped cwd: it reads no file, and a legal
  // shell cwd outside the preopen table (for example `/` or `/dsh`) used to
  // turn the probe into the mapping failure above. A probe also never consumes
  // stdin, so a `jq --version` in a pipeline cannot block on its input.
  const cwd = mappedCwd ?? (versionProbe ? versionProbeGuestCwd(toolbox) : undefined)
  const env = jqShellEnvironment(ctx)
  if (cwd === undefined) delete env.PWD
  else env.PWD = cwd
  const stdin = !versionProbe && typeof ctx.stdin === 'string'
    ? byteStringToBytes(ctx.stdin as unknown as string)
    : undefined
  const limit = engineStreamLimit()
  const stdout = new BoundedByteStream(limit)
  const stderr = new BoundedByteStream(limit)
  // The collector and the toolbox enforce the same ceiling. The local abort is
  // the fallback for a toolbox implementation that does not know the cap yet;
  // its normal signal path still terminates the real WASM worker.
  const controller = new AbortController()
  const external = ctx.signal
  const relayAbort = (): void => { controller.abort(external?.reason) }
  if (external?.aborted === true) relayAbort()
  else external?.addEventListener('abort', relayAbort, { once: true })
  const stopForLimit = (): void => {
    if (!controller.signal.aborted) {
      controller.abort(new Error(`jq: ${JQ_ENGINE_PROGRAM} exceeded its ${String(limit)}-byte stream cap`))
    }
  }
  let result
  try {
    result = await toolbox.run({
      program: JQ_ENGINE_PROGRAM,
      argv: [...args],
      env,
      ...cwd === undefined ? {} : { cwd },
      ...stdin === undefined ? {} : { stdin },
      signal: controller.signal,
      maxStdoutBytes: limit,
      maxStderrBytes: limit,
      onStdout: chunk => {
        if (stdout.push(chunk)) stopForLimit()
      },
      onStderr: chunk => {
        if (stderr.push(chunk)) stopForLimit()
      },
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return jqFailure(`jq: the WASI engine failed: ${message}`, 1)
  } finally {
    external?.removeEventListener('abort', relayAbort)
  }
  const overflow = result.failureCode === 'E_OUTPUT_LIMIT' || stdout.truncated || stderr.truncated
  let stderrText = decodeByteString(bytesToByteString(concatBytes(stderr.chunks)))
  if (overflow) {
    const which = result.stdoutTruncated === true || stdout.truncated ? 'stdout' : 'stderr'
    // Use the toolbox's guest-produced counters, not the local collector's
    // kept prefix: the collector may also have seen the host's cap diagnostic.
    const produced = which === 'stdout' ? result.stdoutBytes : result.stderrBytes
    stderrText += `jq: ${which} exceeded the ${String(limit)}-byte stream cap `
      + `(${String(produced)} bytes produced); `
      + 'the jq engine was stopped [E_OUTPUT_LIMIT]\n'
  }
  return {
    ...byteStringOutput(bytesToByteString(concatBytes(stdout.chunks))),
    stderr: stderrText,
    exitCode: overflow ? 1 : result.exitCode,
  }
}

/**
 * Build the `jq` custom command that shadows just-bash's built-in.
 *
 * An invocation whose filter does not name the input family is delegated to
 * the built-in with its original argv. An input-family invocation is parsed
 * and evaluated per outer document with the injected variables described in
 * the module header.
 *
 * The toolbox binding is explicit so a Worker assembled around a *different*
 * filesystem cannot accidentally dispatch through the process-wide
 * `__PDSH_WASI_TOOLBOX__` slot:
 * - `undefined` keeps the normal single-Worker default: use the current
 *   published toolbox (the production `shell.ts`/`createWorkerCommands()`
 *   path);
 * - `false` means "no WASI engine in this command table"; the built-in/shim
 *   path runs even when some other toolbox is globally published;
 * - a concrete toolbox uses exactly that engine and never falls back to the
 *   global slot when it lacks `jq-wasi`.
 * @param toolbox - explicit engine binding, `false` to disable it, or
 *   `undefined` for the normal current-toolbox default.
 * @returns the `jq` command definition.
 */
export function createJqCommand(toolbox?: WorkerToolbox | false): Command {
  const bound = toolbox
  return defineCommand('jq', async (args, ctx): Promise<ExecResult> => {
    const toolbox = bound === false ? undefined : bound ?? currentWorkerToolbox()
    if (toolbox !== undefined) {
      const engine = await runJqEngine(args, ctx, toolbox)
      if (engine !== undefined) return engine
    }
    // The GNU convention wrapper delegates `jq --version` here instead of
    // printing the shim banner, so the bound engine can name the real
    // implementation. Without an engine the historical shim line stays.
    if (scanGnuArgv('jq', args).longOptions.has('--version')) {
      return { stdout: `jq (just-bash) ${GNU_CONVENTION_VERSION}\n`, stderr: '', exitCode: 0 }
    }
    const origCommand = ctx.origCommand
    if (origCommand === undefined) {
      return jqFailure('error: the built-in jq is unavailable in this shell', 1)
    }
    const invocation = parseJqInvocation(args)
    if (invocation.help) return await origCommand([...args])
    const filter = invocation.filter
    if (filter === undefined || invocation.unsupportedOption !== undefined) {
      return await origCommand([...args])
    }
    const plan = planJqShim(filter)
    if (plan === undefined) return await origCommand([...args])
    try {
      assertSupported(invocation, plan)
    } catch (error) {
      if (error instanceof JqShimError) return jqFailure(error.message, 2)
      throw error
    }
    const parsed: Awaited<ReturnType<typeof readJqDocuments>> =
      invocation.nullInput && plan.usesLineNumber && !plan.usesInput && !plan.usesInputs
        ? { documents: [], breakPosition: {} }
        : await readJqDocuments(ctx, invocation)
    if ('error' in parsed) return jqFailure(parsed.error, parsed.exitCode)
    return await evaluateJq(
      invocation,
      plan,
      parsed.documents,
      parsed.breakPosition,
      ctx.cwd,
      arg => origCommand(arg),
    )
  })
}
