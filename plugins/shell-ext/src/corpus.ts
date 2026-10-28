// SPDX-License-Identifier: MIT
/**
 * Corpus-host commands for the `just-bash` coverage runner.
 *
 * The public corpus exercises external toolchains (`git`, `npm`, `cargo`,
 * `node`, ...) that a phone Worker does not implement. The coverage runner
 * measures the shell language and the command table, not whether those
 * toolchains are real, so it registers deterministic success stubs for the
 * programs the corpus names — the same methodology as the brush spike's
 * `PDSH_BRUSH_MODE=stub` run. Every stub says on stderr that it did not execute,
 * and `shell-ext/README.md` records the gap list. Production `subprocess-xl`
 * never registers these (`createCorpusHostCommands` is only imported by the
 * coverage runner).
 * @module @phone-dsh/dsh-shell-ext/corpus
 */

import { defineCommand } from 'just-bash/browser'
import { findCommandPath } from './command-paths.ts'
import type { Command } from 'just-bash/browser'

/** External programs the public corpus names that the Worker does not implement. */
export const CORPUS_STUB_PROGRAMS: readonly string[] = [
  'apk',
  'apt-get',
  'bazel',
  'black',
  'brew',
  'bun',
  'bundle',
  'cargo',
  'cmake',
  'composer',
  'deno',
  'dig',
  'docker',
  'dotnet',
  'flutter',
  'gem',
  'git',
  'go',
  'gofmt',
  'gradle',
  'host',
  'http',
  'jest',
  'make',
  'mvn',
  'mypy',
  'nc',
  'npx',
  'npm',
  'node',
  'nslookup',
  'openssl',
  'pip',
  'ping',
  'playwright',
  'pnpm',
  'pytest',
  'python',
  'python3',
  'rsync',
  'ruff',
  'rustc',
  'scp',
  'ssh',
  'ssh-keygen',
  'swift',
  'telnet',
  'tox',
  'tsc',
  'uv',
  'vitest',
  'wget',
  'xh',
  'xcodebuild',
  'yarn',
]

/**
 * Build one explicit coverage stub.
 * @param program - program name.
 * @returns a command that succeeds without executing anything.
 */
export function createCorpusStub(program: string): Command {
  return defineCommand(program, async () => ({
    stdout: '',
    stderr: `pdsh-corpus: ${program} is not implemented by the Worker; the coverage host returned success without running it\n`,
    exitCode: 0,
  }))
}

/**
 * Build the coverage host's stub table.
 * @param programs - programs to stub; defaults to {@link CORPUS_STUB_PROGRAMS}.
 * @returns one command per program.
 */
export function createCorpusHostCommands(programs: readonly string[] = CORPUS_STUB_PROGRAMS): Command[] {
  return [...new Set(programs)].map(program => createCorpusStub(program))
}

/**
 * Build a `which` that reports what the shell can actually run.
 *
 * The command name and the filesystem have to agree: `which` prints a path
 * only when a `PATH` directory really contains that entry (the Worker shell
 * materialises one per registered command, see `command-paths.ts`), and exits 1
 * for a name the shell does not serve. It never fabricates `/usr/bin/<name>`
 * for a missing file — the G2-A05 defect — and unlike just-bash's built-in it
 * also recognises the interpreter's own builtins through the extra-name set
 * the command table passes in.
 * @param extraNames - names registered as custom commands.
 * @returns the command definition.
 */
export function createWhichCommand(extraNames: readonly string[] = []): Command {
  const known = new Set(extraNames)
  return defineCommand('which', async (args, ctx) => {
    if (args.length === 0) return { stdout: '', stderr: 'which: missing program name\n', exitCode: 1 }
    for (const name of ctx.getRegisteredCommands?.() ?? []) known.add(name)
    const searchPath = ctx.env.get('PATH') ?? '/usr/bin:/bin'
    const found: string[] = []
    const missing: string[] = []
    for (const name of args) {
      if (name.includes('/')) {
        const absolute = ctx.fs.resolvePath(ctx.cwd, name)
        try {
          if (await ctx.fs.exists(absolute)) found.push(absolute)
          else missing.push(name)
        } catch {
          missing.push(name)
        }
        continue
      }
      const located = await findCommandPath(ctx.fs, name, searchPath)
      if (located !== undefined) found.push(located)
      else missing.push(name)
    }
    if (missing.length > 0) {
      return { stdout: `${found.length > 0 ? `${found.join('\n')}\n` : ''}`, stderr: `which: no ${missing.join(', ')} in (${searchPath})\n`, exitCode: 1 }
    }
    return { stdout: `${found.join('\n')}\n`, stderr: '', exitCode: 0 }
  })
}
