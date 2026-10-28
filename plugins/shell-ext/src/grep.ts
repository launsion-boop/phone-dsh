// SPDX-License-Identifier: MIT
/**
 * The Worker shell's `grep` shim: GNU/BusyBox binary-file options.
 *
 * The pinned just-bash 3.6.0 `grep` has no `-I` / `--binary-files=without-match`
 * in its option parser, so a `grep -RIn ...` invocation — the shape the
 * G2-B05 model reached for — dies with `invalid option -- 'I'` before it reads
 * a single file. This module shadows the built-in through the custom-command
 * table and adds exactly that option surface:
 *
 * - `-I` is accepted as its own argument and inside a combined short-option
 *   cluster (`-RIn`, `-nRI`, ...);
 * - `--binary-files=without-match` (and its separate-value spelling) is
 *   accepted and removed before the built-in sees it;
 * - a file whose content contains a NUL byte is treated as empty, so every
 *   option combination (`-l`, `-n`, `-c`, `-L`, `-v`, context flags, ...)
 *   applies the "assumed not to contain matching data" rule from GNU grep
 *   without re-implementing the option parser, the traversal, the glob
 *   filters or the output formatting.
 *
 * Every invocation without the option delegates to the built-in unchanged
 * (byte-for-byte behavior, including every unsupported-option error). A
 * `-I` invocation runs the same built-in in a nested `Bash` over a read-only
 * view of the Worker VFS whose `readFile` hides NUL-containing files; the
 * outer VFS is never patched, so a pipeline running other commands beside
 * grep cannot observe the shim. Arguments that consume the next word (`-e`,
 * `-f`, `-m`, `-A`, `-B`, `-C`) are respected so a pattern or pattern file
 * literally named `-I` is not rewritten.
 * @module @phone-dsh/dsh-shell-ext/grep
 */

import { Bash, defineCommand } from 'just-bash/browser'
import type { Command, ExecResult, IFileSystem, ResolvedCommandContext } from 'just-bash/browser'
import { shellFailure } from './contract.ts'

/** Short options whose next argv word is a value, never another option. */
const GREP_VALUE_OPTIONS: ReadonlySet<string> = new Set(['-e', '-f', '-m', '-A', '-B', '-C'])

/** Short options that take their value in the same word (`-m5`, `-A2`, ...). */
const GREP_ATTACHED_VALUE = /^-([ABCm])\d+$/u

/** Cluster letters the built-in `grep` option parser knows as booleans. */
const GREP_BOOLEAN_FLAGS: ReadonlySet<string> = new Set([
  'i', 'n', 'v', 'c', 'l', 'L', 'r', 'R', 'w', 'x', 'E', 'P', 'F', 'o', 'h', 'q',
])

/** The GNU long spelling of `-I`. */
const WITHOUT_MATCH_LONG = '--binary-files=without-match'

/** The long option and its separate-value spelling. */
const BINARY_FILES_LONG = '--binary-files'

/** One argv after the binary-file options were removed. */
export interface StrippedGrepOptions {
  /** argv with `-I` / `--binary-files=without-match` removed. */
  readonly args: string[]
  /** True when at least one of the spellings was present. */
  readonly withoutMatch: boolean
}

/**
 * Remove the binary-file options from one `grep` argv.
 *
 * Unknown short flags are left untouched (the built-in's own `invalid option`
 * error remains the contract), as are all words after `--` and every value of
 * an option that consumes the next word.
 * @param argv - arguments after the program name.
 * @returns the rewritten argv and whether a binary-file option was present.
 */
export function stripGrepBinaryOptions(argv: readonly string[]): StrippedGrepOptions {
  const args: string[] = []
  let withoutMatch = false
  let optionsEnded = false
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string
    if (optionsEnded) {
      args.push(token)
      continue
    }
    if (token === '--') {
      optionsEnded = true
      args.push(token)
      continue
    }
    if (token === WITHOUT_MATCH_LONG) {
      withoutMatch = true
      continue
    }
    if (token === BINARY_FILES_LONG && argv[index + 1] === 'without-match') {
      withoutMatch = true
      index += 1
      continue
    }
    if (token.startsWith('--')) {
      args.push(token)
      continue
    }
    if (token === '-' || !token.startsWith('-')) {
      args.push(token)
      continue
    }
    if (GREP_VALUE_OPTIONS.has(token)) {
      args.push(token)
      if (index + 1 < argv.length) {
        index += 1
        args.push(argv[index] as string)
      }
      continue
    }
    if (GREP_ATTACHED_VALUE.test(token)) {
      args.push(token)
      continue
    }
    // A short-option cluster: only rewrite it when every letter before a
    // value-taking `f` is a flag the built-in knows, so an unknown option
    // keeps exactly its own diagnostic.
    const body = token.slice(1)
    const fileOption = body.indexOf('f')
    const letters = fileOption === -1 ? body : body.slice(0, fileOption)
    if ([...letters].some(letter => letter !== 'I' && !GREP_BOOLEAN_FLAGS.has(letter))) {
      args.push(token)
      continue
    }
    if (!letters.includes('I')) {
      args.push(token)
      continue
    }
    withoutMatch = true
    const flags = [...letters].filter(letter => letter !== 'I').join('')
    const suffix = fileOption === -1 ? '' : body.slice(fileOption)
    // `-RIf FILE`: the next word is the pattern file, not another option.
    if (suffix === 'f' && index + 1 < argv.length) {
      args.push(`-${flags}f`)
      index += 1
      args.push(argv[index] as string)
      continue
    }
    const rewritten = `-${flags}${suffix}`
    if (rewritten !== '-') args.push(rewritten)
  }
  return { args, withoutMatch }
}

/** Quote one shell word without importing the shell module (avoids a cycle). */
function quoteWord(word: string): string {
  return `'${word.replace(/'/g, `'\\''`)}'`
}

/** True when a command's stdin buffer contains a NUL byte. */
function stdinHasNul(stdin: ResolvedCommandContext['stdin']): boolean {
  const bytes = stdin as unknown
  return typeof bytes === 'string' && bytes.includes('\0')
}

/**
 * A read-only view of `fs` where every NUL-containing file reads as empty.
 *
 * The built-in grep then applies its normal matching, counting and printing
 * paths; the Worker VFS instance itself is never mutated, so concurrent
 * commands in the same pipeline keep the real content.
 * @param fs - the command's filesystem.
 * @returns a proxy with the same API and the binary-file rule.
 */
export function createWithoutMatchFileSystem(fs: IFileSystem): IFileSystem {
  return new Proxy(fs, {
    get(target, property, receiver) {
      if (property === 'readFile') {
        return async (path: string, options?: unknown): Promise<string> => {
          const content = await target.readFile(path, options as Parameters<IFileSystem['readFile']>[1])
          return content.includes('\0') ? '' : content
        }
      }
      const value = Reflect.get(target, property, target) as unknown
      if (typeof value !== 'function') return value
      return (value as (...args: unknown[]) => unknown).bind(target)
    },
  })
}

/**
 * Build the `grep` custom command that shadows just-bash's built-in.
 * @returns the `grep` command definition.
 */
export function createGrepCommand(): Command {
  return defineCommand('grep', async (args, ctx): Promise<ExecResult> => {
    if (ctx.origCommand === undefined) {
      return shellFailure('grep', 'grep: the built-in grep is unavailable in this shell', 'backend-failed')
    }
    const stripped = stripGrepBinaryOptions(args)
    if (!stripped.withoutMatch) return await ctx.origCommand(stripped.args)
    const script = ['grep', ...stripped.args].map(quoteWord).join(' ')
    const nested = new Bash({
      fs: createWithoutMatchFileSystem(ctx.fs),
      cwd: ctx.cwd,
      env: { ...Object.fromEntries(ctx.env), PWD: ctx.cwd },
      executionLimits: ctx.limits,
    })
    return await nested.exec(script, {
      cwd: ctx.cwd,
      // `-I` also treats a binary standard input as non-matching. An empty
      // buffer gives the built-in the same answer for a `-` operand and for
      // the no-file-operand form without touching text stdin.
      stdin: stdinHasNul(ctx.stdin) ? '' : ctx.stdin as unknown as string,
      stdinKind: 'bytes',
      ...ctx.signal === undefined ? {} : { signal: ctx.signal },
    })
  })
}
