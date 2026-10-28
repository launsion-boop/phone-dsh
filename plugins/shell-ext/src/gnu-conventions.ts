// SPDX-License-Identifier: MIT
/**
 * One owner for the GNU argv conventions the Worker command surface exposes.
 *
 * Two classes of divergence had accumulated command by command in just-bash
 * 3.6.0:
 *
 * 1. **End of options (`--`).** `mv -- old new` and `rm -- old` already accept
 *    the GNU terminator, while `sha256sum -- f`, `head -- f`, `cut -c1 -- f`,
 *    `sed -n 1p -- f`, `chmod 644 -- f`, `jq . -- f`, `comm -- a b`,
 *    `date --` and `xargs -- echo` reject it as an unrecognized option. The
 *    same script shape therefore worked for some commands and failed for
 *    others with no owner deciding the rule.
 * 2. **Capability probes (`--version` / `--help`).** Most built-ins answered a
 *    legal `--version` with exit 1/2 (`head: unrecognized option '--version'`),
 *    and `od --help`/`od --version` returned an empty success. A model probing
 *    a capability cannot distinguish "unsupported option" from "program
 *    missing".
 *
 * {@link applyGnuConventions} is the single table-driven owner:
 *
 * - for every name in {@link GNU_CONVENTION_PROGRAMS} it returns an idempotent
 *   wrapper (marked with a module `Symbol`), so `createWorkerCommands` and a
 *   bare `WorkerShell` can both apply it without nesting twice;
 * - a wrapper that does not hit a convention calls the original command
 *   unchanged — an existing custom command through its own `execute`, a
 *   bundled-only command through `ctx.origCommand`;
 * - `--version` before the genuine end-of-options prints
 *   `<name> (just-bash) 3.6.0` and exits 0;
 * - `--help` first calls the original. A non-empty exit-0 help is preserved
 *   byte for byte; a refusal or an empty success is replaced by a non-empty
 *   usage line with exit 0, never a silent empty success;
 * - the genuine `--` is removed and the arguments after it are kept as
 *   operands. A per-program value-arity table finds it, so a literal `--`
 *   consumed as an option value (`find . -name --`, `sort -o -- f`) is left
 *   alone. For file-operand commands a token that begins with `-` (but is not
 *   the single `-`) is rewritten to `./-...` so the bundled parser cannot read
 *   it as an option again. Commands whose first positional is a script/filter
 *   (`sed`, `jq`) or a mode (`chmod`) only rewrite the subsequent file
 *   operands; `find`/`date`/`xargs` have non-file operand grammars and only
 *   lose the terminator. An option-shaped sed script after `--` is rejected
 *   with GNU's diagnostic, and an option-shaped jq filter fails explicitly
 *   because the bundled parser has neither positional escape.
 *
 * `echo` and `printf` are deliberately absent: their `--version` is literal
 * output, not a probe, and the wrapper must not change it. `bash`/`sh`,
 * `mktemp`, `diff`, `git`, the WASI toolbox and host accelerators also keep
 * their native version semantics. `sort` and `du` are the Worker's own shadows
 * and take part in the same table (their successful native help is preserved,
 * and their own `--` parsers remain authoritative for the delegated argv).
 * @module @phone-dsh/dsh-shell-ext/gnu-conventions
 */

import { defineCommand } from 'just-bash/browser'
import type { Command, CustomCommand, ExecResult, ResolvedCommandContext } from 'just-bash/browser'
import { createDuCommand } from './du.ts'
import { createSortCommand } from './sort.ts'

/** The engine version the unified `--version` line names. */
export const GNU_CONVENTION_VERSION = '3.6.0'

/**
 * Programs whose `--`, `--version` and `--help` conventions this module owns.
 *
 * Every name exists in just-bash 3.6.0's bundled table, so wrapping it cannot
 * fabricate a `command -v` entry for a program that does not exist. `sort` and
 * `du` are the Worker's own shadows over bundled programs and share the same
 * wrapper table; `echo`/`printf` keep literal arguments; `bash`/`sh`,
 * `mktemp`, `diff`, `git`, the toolbox and host accelerators keep their native
 * version surface.
 */
export const GNU_CONVENTION_PROGRAMS: readonly string[] = Object.freeze([
  'sha256sum', 'sha1sum', 'md5sum',
  'head', 'tail', 'cut', 'sed', 'find', 'chmod', 'jq', 'date', 'comm', 'xargs', 'od',
  'rm', 'mv', 'cp', 'ls', 'wc', 'uniq', 'cat', 'mkdir', 'touch', 'ln',
  // The Worker's own `sort -z` and `du` shadows take part in the same table:
  // their native `--version`/`--help` stays authoritative when it succeeds and
  // their `--` handling is shared instead of being a third convention.
  'sort', 'du',
])

/** The set form used by the per-command check. */
const GNU_CONVENTION_SET: ReadonlySet<string> = new Set(GNU_CONVENTION_PROGRAMS)

/** Marker that makes a wrapped command idempotent across composition layers. */
export const GNU_CONVENTION_WRAPPED: unique symbol = Symbol('phone-dsh.gnu-conventions.wrapped')

/** A wrapped command carrying the idempotency marker. */
interface GnuWrappedCommand extends Command {
  readonly [GNU_CONVENTION_WRAPPED]?: true
}

/** True when a custom-command entry is already a GNU convention wrapper. */
export function isGnuConventionWrapper(command: CustomCommand): boolean {
  return (command as GnuWrappedCommand)[GNU_CONVENTION_WRAPPED] === true
}

/** Programs whose operands after `--` are files (dash tokens become `./-…`). */
const FILE_OPERAND_PROGRAMS: ReadonlySet<string> = new Set([
  'sha256sum', 'sha1sum', 'md5sum', 'head', 'tail', 'cut', 'od', 'comm',
  'rm', 'mv', 'cp', 'ls', 'wc', 'uniq', 'cat', 'mkdir', 'touch', 'ln',
  // The Worker's own `sort -z` and `du` shadows take part in the same table:
  // their native `--version`/`--help` stays authoritative when it succeeds and
  // their `--` handling is shared instead of being a third convention.
  'sort', 'du',
])

/** Per-program usage line used when the original cannot provide help. */
const GNU_USAGE: Readonly<Record<string, string>> = Object.freeze({
  chmod: 'usage: chmod [OPTION]... MODE FILE...\n',
  comm: 'usage: comm [OPTION]... FILE1 FILE2\n',
  date: 'usage: date [OPTION]... [+FORMAT]\n',
  find: 'usage: find [PATH...] [EXPRESSION]\n',
  jq: 'usage: jq [OPTION]... FILTER [FILE...]\n',
  od: 'usage: od [OPTION]... [FILE]...\n',
  sed: 'usage: sed [OPTION]... {script} [input-file]...\n',
  xargs: 'usage: xargs [OPTION]... [COMMAND [INITIAL-ARGS]]\n',
})

/** The fallback usage line for a program with no specific entry. */
function usageLine(name: string): string {
  return GNU_USAGE[name] ?? `usage: ${name} [OPTION]... [FILE]...\n`
}

/**
 * Value-taking options per program, used to find the real end-of-options.
 *
 * A literal `--` is only a terminator when it is not the value of the option
 * before it: `find . -name --` searches for a file named `--`, and
 * `sort -o -- f` writes to a file named `--`, exactly as GNU does. The table
 * below is deliberately per command: a short cluster such as `-n5` carries its
 * value, while `-n 5` consumes the next word. `wordValues` covers grammars
 * whose long-ish options use a single dash (`find -name`, `sed -e`), and
 * `wordSentences` covers `find -exec ... ;` whose value is several words.
 */
interface GnuOptionSpec {
  /** Short option letters that consume the next word when the cluster ends. */
  readonly shortValues: ReadonlySet<string>
  /** Long options that consume N following words. */
  readonly longValues: ReadonlyMap<string, number>
  /** Single-dash words that consume exactly one following word. */
  readonly wordValues: ReadonlySet<string>
  /** Single-dash words that consume words up to `;`/`+` (`find -exec`). */
  readonly wordSentences: ReadonlySet<string>
}

/** Build a set from literal option names. */
function optionSet(...values: string[]): ReadonlySet<string> {
  return new Set(values)
}

/** Build a long-option value-count map from `name, count` pairs. */
function optionCounts(...pairs: readonly (readonly [string, number])[]): ReadonlyMap<string, number> {
  return new Map(pairs)
}

/** The empty spec for a program whose options take no separate value. */
const NO_VALUE_OPTIONS: GnuOptionSpec = Object.freeze({
  shortValues: optionSet(),
  longValues: optionCounts(),
  wordValues: optionSet(),
  wordSentences: optionSet(),
})

/** Value-taking option grammar for the wrapped programs. */
const GNU_OPTION_SPECS: Readonly<Record<string, GnuOptionSpec>> = Object.freeze({
  head: {
    shortValues: optionSet('n', 'c'),
    longValues: optionCounts(['--lines', 1], ['--bytes', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  tail: {
    shortValues: optionSet('n', 'c', 's'),
    longValues: optionCounts(['--lines', 1], ['--bytes', 1], ['--pid', 1], ['--sleep-interval', 1], ['--max-unchanged-stats', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  cut: {
    shortValues: optionSet('b', 'c', 'd', 'f'),
    longValues: optionCounts(['--bytes', 1], ['--characters', 1], ['--delimiter', 1], ['--fields', 1], ['--output-delimiter', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  sed: {
    shortValues: optionSet('e', 'f', 'l'),
    longValues: optionCounts(['--expression', 1], ['--file', 1], ['--line-length', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  find: {
    shortValues: optionSet(),
    longValues: optionCounts(['--files0-from', 1]),
    wordValues: optionSet(
      '-name', '-iname', '-path', '-ipath', '-wholename', '-iwholename',
      '-regex', '-iregex', '-type', '-xtype', '-size', '-mtime', '-atime',
      '-ctime', '-mmin', '-amin', '-cmin', '-newer', '-anewer', '-cnewer',
      '-user', '-group', '-perm', '-maxdepth', '-mindepth', '-fstype',
      '-inum', '-links', '-printf', '-fprintf', '-regextype', '-used',
      '-samefile', '-lname', '-ilname', '-context', '-newermt', '-newerat',
      '-newerct',
    ),
    wordSentences: optionSet('-exec', '-execdir', '-ok', '-okdir'),
  },
  chmod: {
    shortValues: optionSet(),
    longValues: optionCounts(['--reference', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  jq: {
    shortValues: optionSet('L'),
    longValues: optionCounts(
      ['--arg', 2], ['--argjson', 2], ['--slurpfile', 2], ['--rawfile', 2],
      ['--argfile', 2], ['--indent', 1], ['--library-path', 1], ['--from-file', 1],
    ),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  date: {
    shortValues: optionSet('d', 'f', 'r'),
    longValues: optionCounts(['--date', 1], ['--file', 1], ['--reference', 1], ['--rfc-3339', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  comm: {
    shortValues: optionSet(),
    longValues: optionCounts(['--output-delimiter', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  xargs: {
    shortValues: optionSet('a', 'd', 'E', 'I', 'L', 'n', 'P', 's', 'J'),
    longValues: optionCounts(
      ['--arg-file', 1], ['--delimiter', 1], ['--eof', 1], ['--replace', 1],
      ['--max-lines', 1], ['--max-args', 1], ['--max-procs', 1],
      ['--max-chars', 1], ['--process-slot-var', 1],
    ),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  od: {
    shortValues: optionSet('A', 'j', 'N', 't', 'w', 'S'),
    longValues: optionCounts(
      ['--address-radix', 1], ['--skip-bytes', 1], ['--read-bytes', 1],
      ['--format', 1], ['--width', 1], ['--endian', 1], ['--strings', 1],
    ),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  mv: {
    shortValues: optionSet('t', 'S'),
    longValues: optionCounts(['--target-directory', 1], ['--suffix', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  cp: {
    shortValues: optionSet('t', 'S'),
    longValues: optionCounts(
      ['--target-directory', 1], ['--suffix', 1], ['--preserve', 1],
      ['--sparse', 1], ['--reflink', 1],
    ),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  ln: {
    shortValues: optionSet('t', 'S'),
    longValues: optionCounts(['--target-directory', 1], ['--suffix', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  ls: {
    shortValues: optionSet('I', 'w', 'T'),
    longValues: optionCounts(
      ['--ignore', 1], ['--width', 1], ['--tabsize', 1], ['--block-size', 1],
      ['--color', 0], ['--sort', 1], ['--time', 1], ['--time-style', 1],
      ['--format', 1], ['--quoting-style', 1], ['--indicator-style', 1],
      ['--hide', 1], ['--hyperlink', 1],
    ),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  wc: {
    shortValues: optionSet(),
    longValues: optionCounts(['--files0-from', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  uniq: {
    shortValues: optionSet('f', 's', 'w'),
    longValues: optionCounts(['--skip-fields', 1], ['--skip-chars', 1], ['--check-chars', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  mkdir: {
    shortValues: optionSet('m'),
    longValues: optionCounts(['--mode', 1], ['--context', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  touch: {
    shortValues: optionSet('d', 'r', 't'),
    longValues: optionCounts(['--date', 1], ['--reference', 1], ['--time', 1]),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  sort: {
    shortValues: optionSet('o', 'k', 't', 'S', 'T'),
    longValues: optionCounts(
      ['--output', 1], ['--key', 1], ['--field-separator', 1],
      ['--buffer-size', 1], ['--temporary-directory', 1],
      ['--compress-program', 1], ['--files0-from', 1], ['--batch-size', 1],
      ['--parallel', 1], ['--random-source', 1], ['--sort', 1],
    ),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
  du: {
    shortValues: optionSet('d', 'B', 't'),
    longValues: optionCounts(
      ['--max-depth', 1], ['--block-size', 1], ['--exclude', 1],
      ['--exclude-from', 1], ['--files0-from', 1], ['--time-style', 1],
      ['--threshold', 1],
    ),
    wordValues: optionSet(),
    wordSentences: optionSet(),
  },
})

/** The spec for one program, or the empty spec when it has no value options. */
function optionSpec(name: string): GnuOptionSpec {
  return GNU_OPTION_SPECS[name] ?? NO_VALUE_OPTIONS
}

/** The option scan of one invocation. */
export interface GnuArgvScan {
  /** Index of the genuine terminator, or -1 when there is none. */
  readonly terminator: number
  /** Exact long-option names (`--version`, `--help`) seen before it. */
  readonly longOptions: ReadonlySet<string>
}

/**
 * Scan argv for the real end-of-options and the convention probes.
 *
 * A `--` word consumed as an option value is skipped, so it never ends the
 * option list. Long options with an attached value (`--output=--`) are left
 * alone because they consume no following word.
 * @param name - program name.
 * @param args - arguments after the program name.
 * @returns the terminator index and the long options seen before it.
 */
export function scanGnuArgv(name: string, args: readonly string[]): GnuArgvScan {
  const spec = optionSpec(name)
  const longOptions = new Set<string>()
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index] as string
    if (token === '--') return { terminator: index, longOptions }
    if (token === '-' || !token.startsWith('-')) continue
    if (token.startsWith('--')) {
      const separator = token.indexOf('=')
      const option = separator === -1 ? token : token.slice(0, separator)
      if (separator === -1) longOptions.add(token)
      const count = spec.longValues.get(option) ?? 0
      // Zero-value long options (for example ls --color) never skip a word;
      // only a positive count is a required value.
      if (separator === -1 && count > 0) index += count
      continue
    }
    if (spec.wordSentences.has(token)) {
      let end = index + 1
      while (end < args.length && args[end] !== ';' && args[end] !== '+') end += 1
      index = end
      continue
    }
    if (spec.wordValues.has(token)) {
      index += 1
      continue
    }
    for (let offset = 1; offset < token.length; offset += 1) {
      if (!spec.shortValues.has(token[offset] as string)) continue
      if (offset === token.length - 1) index += 1
      break
    }
  }
  return { terminator: -1, longOptions }
}

/** True when a token looks like an option rather than an operand. */
function isOptionLike(token: string): boolean {
  return token.length > 1 && token.startsWith('-')
}

/** Rewrite one operand so a bundled parser cannot read it as an option. */
function asFileOperand(token: string): string {
  return isOptionLike(token) ? `./${token}` : token
}

/**
 * Whether `chmod`'s MODE operand already appeared before the terminator.
 * `--reference` consumes one value; every other chmod option is boolean.
 */
function chmodModeSeen(before: readonly string[]): boolean {
  for (let index = 0; index < before.length; index += 1) {
    const token = before[index] as string
    if (token === '-' || !token.startsWith('-')) return true
    if (token === '--reference') index += 1
  }
  return false
}

/**
 * Whether `sed` already has its script: from `-e`/`-f`/`--expression`/
 * `--file`, or from a positional operand before the terminator.
 */
function sedScriptSeen(before: readonly string[]): boolean {
  for (let index = 0; index < before.length; index += 1) {
    const token = before[index] as string
    if (token === '-' || !token.startsWith('-')) return true
    if (token.startsWith('--')) {
      const name = token.split('=')[0] as string
      if (name === '--expression' || name === '--file') index += 1
      continue
    }
    for (let offset = 1; offset < token.length; offset += 1) {
      const flag = token[offset] as string
      if (flag !== 'e' && flag !== 'f') continue
      // The rest of the cluster (if any) is the script; otherwise the next
      // argv word is. Either way the script now exists.
      if (offset === token.length - 1) index += 1
      return true
    }
  }
  return false
}

/**
 * Whether `jq` already has its filter: a positional operand before the
 * terminator. Options that consume values are skipped.
 */
function jqFilterSeen(before: readonly string[]): boolean {
  const valueOptions: ReadonlySet<string> = new Set([
    '--arg', '--argjson', '--rawfile', '--slurpfile', '--argfile', '--indent',
  ])
  for (let index = 0; index < before.length; index += 1) {
    const token = before[index] as string
    if (token === '-' || !token.startsWith('-')) return true
    if (token.startsWith('--')) {
      const name = token.split('=')[0] as string
      if (token.includes('=')) continue
      if (valueOptions.has(name)) index += name === '--arg' || name === '--argjson' || name === '--rawfile' || name === '--slurpfile' || name === '--argfile' ? 2 : 1
      continue
    }
    for (let offset = 1; offset < token.length; offset += 1) {
      const flag = token[offset] as string
      if (flag !== 'L') continue
      if (offset === token.length - 1) index += 1
      break
    }
  }
  return false
}

/**
 * Apply the terminator convention for one program.
 * @param name - program name.
 * @param before - argv words before the first `--`.
 * @param after - argv words after the first `--`.
 * @returns the delegated argv with no terminator.
 */
export function applyGnuTerminator(name: string, before: readonly string[], after: readonly string[]): string[] {
  if (name === 'find' || name === 'date') return [...before, ...after]
  if (name === 'xargs') {
    // After `--`, xargs' first word is the COMMAND. A command whose name
    // begins with `-` must not fall back into the bundled option parser; `./`
    // keeps it an error (GNU also fails to execute it) instead of a silent
    // option reinterpretation. Later words are the command's own arguments.
    if (after.length > 0 && isOptionLike(after[0] as string)) {
      return [...before, `./${after[0] as string}`, ...after.slice(1)]
    }
    return [...before, ...after]
  }
  if (name === 'chmod') {
    if (chmodModeSeen(before)) return [...before, ...after.map(asFileOperand)]
    return [...before, ...after.slice(0, 1), ...after.slice(1).map(asFileOperand)]
  }
  if (name === 'sed') {
    if (sedScriptSeen(before)) return [...before, ...after.map(asFileOperand)]
    return [...before, ...after.slice(0, 1), ...after.slice(1).map(asFileOperand)]
  }
  if (name === 'jq') {
    if (jqFilterSeen(before)) return [...before, ...after.map(asFileOperand)]
    return [...before, ...after.slice(0, 1), ...after.slice(1).map(asFileOperand)]
  }
  if (FILE_OPERAND_PROGRAMS.has(name)) return [...before, ...after.map(asFileOperand)]
  return [...before, ...after]
}

/** The result a wrapper produces for one invocation. */
async function runGnuConvention(
  name: string,
  args: readonly string[],
  ctx: ResolvedCommandContext,
  delegate: ((args: string[], ctx: ResolvedCommandContext) => Promise<ExecResult>) | undefined,
): Promise<ExecResult> {
  const scan = scanGnuArgv(name, args)
  const { terminator } = scan
  const after = terminator === -1 ? [] : args.slice(terminator + 1)
  if (scan.longOptions.has('--version') && name !== 'jq') {
    return { stdout: `${name} (just-bash) ${GNU_CONVENTION_VERSION}\n`, stderr: '', exitCode: 0 }
  }
  // `jq --version` must name the engine this table actually dispatches to.
  // The jq command owns that identity (and keeps the shim banner when no
  // engine is bound), so the convention wrapper delegates instead of printing
  // the generic just-bash line. A bare table with no invoker keeps the shim
  // line below rather than turning a legal probe into 127.
  const jqVersion = name === 'jq' && scan.longOptions.has('--version')
  // A sed script after `--` is a positional operand, never an option. The
  // bundled parser cannot be told that directly, and a script beginning with
  // `-` is always an invalid command, so return GNU's diagnostic instead of
  // letting the parser read it as `-n`/`-e` and silently succeed.
  if (name === 'sed' && terminator !== -1 && !sedScriptSeen(args.slice(0, terminator))) {
    const script = after[0]
    if (script !== undefined && isOptionLike(script)) {
      return {
        stdout: '',
        stderr: `sed: -e expression #1, char 1: unknown command: \`${script[0] ?? ''}'\n`,
        exitCode: 1,
      }
    }
  }
  // jq's option parser cannot accept an option-shaped filter after `--`
  // either, and the bundled program does not support `--` to preserve. Fail
  // explicitly (GNU jq also exits 2 for this shape) instead of re-reading the
  // filter as an option.
  if (name === 'jq' && terminator !== -1 && !jqFilterSeen(args.slice(0, terminator))) {
    const filter = after[0]
    if (filter !== undefined && isOptionLike(filter)) {
      return { stdout: '', stderr: `jq: option-shaped filter cannot follow '--': ${filter}\n`, exitCode: 2 }
    }
  }
  // `date` operands are `+FORMAT` strings; an option-shaped word after `--`
  // is an invalid date, never a re-read option (GNU exits 1 with this shape).
  if (name === 'date') {
    const invalid = after.find(isOptionLike)
    if (invalid !== undefined) return { stdout: '', stderr: `date: invalid date '${invalid}'\n`, exitCode: 1 }
  }
  const delegatedArgs = terminator === -1
    ? [...args]
    : applyGnuTerminator(name, args.slice(0, terminator), args.slice(terminator + 1))
  const orig = ctx.origCommand
  const invoke = delegate ?? (orig === undefined ? undefined : async (next: string[]) => await orig(next))
  if (invoke === undefined) {
    if (jqVersion) {
      return { stdout: `jq (just-bash) ${GNU_CONVENTION_VERSION}\n`, stderr: '', exitCode: 0 }
    }
    return { stdout: '', stderr: `${name}: command unavailable\n`, exitCode: 127 }
  }
  if (scan.longOptions.has('--help')) {
    const original = await invoke(delegatedArgs, ctx)
    if (original.exitCode === 0 && original.stdout !== '') return original
    return { stdout: usageLine(name), stderr: '', exitCode: 0 }
  }
  return await invoke(delegatedArgs, ctx)
}

/** Build one wrapper command around an existing command's `execute`. */
function wrapCommand(original: Command): GnuWrappedCommand {
  const name = original.name
  const wrapped: GnuWrappedCommand = {
    name,
    ...original.trusted === undefined ? {} : { trusted: original.trusted },
    [GNU_CONVENTION_WRAPPED]: true,
    execute: async (args, ctx) => await runGnuConvention(name, args, ctx, original.execute.bind(original)),
  }
  return wrapped
}

/** Worker-owned commands a bare table may still need before wrapping. */
const WORKER_OWNED_PROGRAMS: ReadonlyMap<string, () => Command> = new Map<string, () => Command>([
  ['sort', createSortCommand],
  ['du', createDuCommand],
])

/** Build one wrapper for a bundled-only command (delegates via `origCommand`). */
function createWrapperCommand(name: string): GnuWrappedCommand {
  const command = defineCommand(name, async (args, ctx) => {
    return await runGnuConvention(name, args, ctx, undefined)
  })
  return Object.assign(command, { [GNU_CONVENTION_WRAPPED]: true as const })
}

/**
 * Apply the GNU argv conventions to a command table.
 *
 * Idempotent: an already-wrapped command is left as-is. Existing custom
 * commands are wrapped in place so their implementation (the `find` shim, a
 * caller-supplied shadow) stays authoritative; a registry name that is not in
 * the table gets a wrapper that delegates to the bundled command through
 * `ctx.origCommand`.
 * @param commands - the assembled custom-command table.
 * @returns a new table with one wrapper per {@link GNU_CONVENTION_PROGRAMS}
 *   entry.
 */
export function applyGnuConventions(commands: readonly CustomCommand[]): CustomCommand[] {
  const result: CustomCommand[] = []
  for (const command of commands) {
    if (!('execute' in command) || typeof command.execute !== 'function') {
      result.push(command)
      continue
    }
    if (!GNU_CONVENTION_SET.has(command.name) || isGnuConventionWrapper(command)) {
      result.push(command)
      continue
    }
    result.push(wrapCommand(command))
  }
  for (const name of GNU_CONVENTION_PROGRAMS) {
    if (result.some(command => command.name === name)) continue
    const workerOwned = WORKER_OWNED_PROGRAMS.get(name)
    // `sort -z`/`du` are Worker shadows, not just a wrapper over a bundled
    // program: a table that lacks them gets the real Worker command (then the
    // convention wrapper), never a wrapper that would delegate `-z` to the
    // bundled parser that rejects it.
    result.push(workerOwned === undefined ? createWrapperCommand(name) : wrapCommand(workerOwned()))
  }
  return result
}
