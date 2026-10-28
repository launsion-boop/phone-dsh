// SPDX-License-Identifier: MIT
/**
 * The Worker shell's `awk` command surface.
 *
 * `awk` is a just-bash built-in (Apache-2.0, imported unmodified). Its program
 * language is complete enough for the field and `gsub` idioms the scenarios
 * use, but its command line is not POSIX/GNU `awk`: `-f PROGRAM-FILE` is
 * rejected with `awk: invalid option -- 'f'`, `--posix`/`--traditional` are
 * unrecognised, and there is no `-V`/`--version`. G2-A01 hit the first one: a
 * model that wrote `trim.awk` and ran `awk -f trim.awk` got a usage error
 * instead of its `gsub(/^ +| +$/,"",s)` result.
 *
 * This module shadows the built-in through just-bash's custom-command table —
 * the same seam `find.ts` and `stat.ts` use — and implements only the command
 * line: it reads every `-f` program file, concatenates the program sources the
 * way GNU awk does, normalises the accepted no-op compatibility options, and
 * hands the built-in the shape it already understands (`-F`, `-v`, one program
 * string, operands). Parsing the awk language, and the `gsub`/`sub`/`split`
 * builtins themselves, stay in the built-in.
 *
 * A missing program file is a fatal `awk: cannot open program file 'x' for
 * reading (No such file or directory)` with exit 2, matching GNU awk's
 * diagnostic class, instead of a silently empty program.
 * @module @phone-dsh/dsh-shell-ext/awk
 */

import { posix } from 'node:path'
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult } from 'just-bash/browser'
import { shellFailure } from './contract.ts'

/** An `awk` command-line error with the GNU message body. */
export class AwkUsageError extends Error {
  /** Exit status GNU awk uses for a fatal command-line error. */
  readonly exitCode: number

  /**
   * @param message - diagnostic body (without the `awk: ` prefix).
   * @param exitCode - 2 for a fatal error, 1 for a usage error.
   */
  constructor(message: string, exitCode = 2) {
    super(message)
    this.name = 'AwkUsageError'
    this.exitCode = exitCode
  }
}

/**
 * Parse one `awk` argv into the shape the built-in understands.
 *
 * The result is pure and filesystem-free: {@link createAwkCommand} reads the
 * `-f` files after this function has classified the argv.
 * @param argv - arguments after the program name.
 * @returns the invocation; `program` may be a list of `-f` paths to read.
 */
export function parseAwkArguments(argv: readonly string[]): {
  readonly fieldSeparator: string | undefined
  readonly assignments: readonly string[]
  readonly programFiles: readonly string[]
  readonly programText: string | undefined
  readonly operands: readonly string[]
  readonly version: boolean
  readonly help: boolean
} {
  let fieldSeparator: string | undefined
  const assignments: string[] = []
  const programFiles: string[] = []
  let programText: string | undefined
  const operands: string[] = []
  let options = true
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index] as string
    if (!options) {
      if (programText === undefined && programFiles.length === 0) programText = argument
      else operands.push(argument)
      continue
    }
    if (argument === '--') {
      options = false
      continue
    }
    if (argument === '-') {
      // `awk -` reads the program from standard input in GNU awk; the Worker
      // has no program-file stdin convention and the shell's stdin is data.
      throw new AwkUsageError("option '-' is not supported as a program file", 2)
    }
    if (!argument.startsWith('-')) {
      if (programText === undefined && programFiles.length === 0) programText = argument
      else operands.push(argument)
      continue
    }
    if (argument === '--help') return { fieldSeparator, assignments, programFiles, programText, operands, version: false, help: true }
    if (argument === '--version' || argument === '-V') {
      return { fieldSeparator, assignments, programFiles, programText, operands, version: true, help: false }
    }
    if (argument === '--posix' || argument === '--traditional' || argument === '--lint' || argument === '-b') {
      // Accepted compatibility switches: the built-in already runs POSIX awk.
      continue
    }
    if (argument === '-F' || argument === '-v' || argument === '-f') {
      const value = argv[index + 1]
      if (value === undefined) throw new AwkUsageError(`option requires an argument -- '${argument.slice(1)}'`, 2)
      index += 1
      if (argument === '-F') fieldSeparator = value
      else if (argument === '-v') assignments.push(value)
      else programFiles.push(value)
      continue
    }
    if (argument.startsWith('-F') && argument.length > 2) {
      fieldSeparator = argument.slice(2)
      continue
    }
    if (argument.startsWith('-v') && argument.length > 2) {
      assignments.push(argument.slice(2))
      continue
    }
    if (argument.startsWith('-f') && argument.length > 2) {
      programFiles.push(argument.slice(2))
      continue
    }
    if (argument.startsWith('--')) throw new AwkUsageError(`unrecognized option '${argument}'`, 2)
    throw new AwkUsageError(`invalid option -- '${argument.slice(1)}'`, 2)
  }
  return { fieldSeparator, assignments, programFiles, programText, operands, version: false, help: false }
}

/** Usage text for `awk --help` (the built-in's own help is the language core). */
const AWK_HELP = [
  'Usage: awk [POSIX or GNU style options] -f progfile [--] file ...',
  "Usage: awk [POSIX or GNU style options] [--] 'program' file ...",
  '',
  '  -F fs               --field-separator=fs',
  '  -v var=val          --assign=var=val',
  '  -f progfile         --file=progfile',
  '  --posix             compatibility mode (accepted; the shell is POSIX awk)',
  '  --traditional       compatibility mode (accepted)',
  '  -V, --version       output version information and exit',
  '  --help              display this help and exit',
  '',
].join('\n')

/**
 * Build the `awk` command that adds the POSIX/GNU program-file surface.
 * @returns the command definition.
 */
export function createAwkCommand(): Command {
  return defineCommand('awk', async (args, ctx): Promise<ExecResult> => {
    let parsed: ReturnType<typeof parseAwkArguments>
    try {
      parsed = parseAwkArguments(args)
    } catch (error) {
      const status = error instanceof AwkUsageError ? error.exitCode : 2
      return shellFailure('awk', `awk: ${error instanceof Error ? error.message : String(error)}`, 'unsupported-option', {
        exitCode: status,
      })
    }
    if (parsed.help) return { stdout: AWK_HELP, stderr: '', exitCode: 0 }
    if (parsed.version) return { stdout: 'awk (Worker shell, just-bash) 1.0\n', stderr: '', exitCode: 0 }
    if (ctx.origCommand === undefined) {
      return shellFailure('awk', 'awk: the built-in awk is unavailable in this shell', 'backend-failed')
    }
    let program = parsed.programText
    if (parsed.programFiles.length > 0) {
      const sources: string[] = []
      for (const file of parsed.programFiles) {
        try {
          sources.push(await ctx.fs.readFile(posix.resolve(ctx.cwd, file)))
        } catch {
          return shellFailure('awk', `awk: cannot open program file '${file}' for reading (No such file or directory)`, 'command-exited', { exitCode: 2 })
        }
      }
      program = sources.join('\n')
    }
    if (program === undefined) {
      return shellFailure('awk', 'awk: no program given', 'unsupported-option')
    }
    const rewritten: string[] = []
    if (parsed.fieldSeparator !== undefined) rewritten.push('-F', parsed.fieldSeparator)
    for (const assignment of parsed.assignments) rewritten.push('-v', assignment)
    rewritten.push(program, ...parsed.operands)
    return await ctx.origCommand(rewritten)
  })
}
