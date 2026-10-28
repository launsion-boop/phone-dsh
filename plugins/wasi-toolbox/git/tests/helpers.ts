// SPDX-License-Identifier: MIT
/**
 * Shared fixture plumbing for the Worker git tests.
 *
 * The golden tests compare byte-for-byte against the system git, so every
 * fixture is produced by that git itself (never by the implementation under
 * test) with an isolated HOME, fixed author/committer dates and deterministic
 * file contents. When `git` is absent the suites skip with a message instead
 * of failing, matching the task's "generate fixtures with the system git when
 * present, else skip" contract.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/helpers
 */
import { spawnSync } from 'node:child_process'
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { runGit } from '../cli.ts'

/** True when the system git is installed. */
export const HAS_GIT: boolean = spawnSync('git', ['--version'], { encoding: 'utf8' }).status === 0

/** Message used for `{ skip }` when the system git is missing. */
export const SKIP_NO_GIT = 'the system git is not installed; golden fixture generation skipped'

/** The system git release the oracle was captured from. */
export interface SystemGitVersion {
  readonly major: number
  readonly minor: number
  readonly patch: number
}

function detectSystemGitVersion(): SystemGitVersion {
  const result = spawnSync('git', ['--version'], { encoding: 'utf8' })
  const match = /git version (\d+)\.(\d+)(?:\.(\d+))?/.exec(result.stdout ?? '')
  if (match === null) return { major: 0, minor: 0, patch: 0 }
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3] ?? 0) }
}

/** Parsed `git --version`; zeroes when git is absent. */
export const SYSTEM_GIT_VERSION: SystemGitVersion = detectSystemGitVersion()

/** True when the system git is at least `major.minor`. */
export function systemGitAtLeast(major: number, minor: number): boolean {
  return SYSTEM_GIT_VERSION.major > major
    || (SYSTEM_GIT_VERSION.major === major && SYSTEM_GIT_VERSION.minor >= minor)
}

/** One settled command result with binary streams. */
export interface CommandResult {
  readonly stdout: Buffer
  readonly stderr: Buffer
  readonly code: number
}

/**
 * Adjust the one known pre-2.45 `%aI`/`%cI` oracle difference.
 *
 * Git 2.45 changed strict ISO UTC from `+00:00` to `Z`
 * (Documentation/RelNotes/2.45.0.txt). The Worker always emits the modern
 * canonical `Z`; an older system git is the oracle for everything else. Only
 * an exact strict-ISO timestamp token ending in `+00:00` is rewritten, and
 * only when the oracle predates 2.45, so an arbitrary stdout/stderr diff is
 * still a failure.
 */
export function adaptStrictIsoOracle(result: CommandResult): CommandResult {
  if (!HAS_GIT || systemGitAtLeast(2, 45)) return result
  const text = result.stdout.toString('latin1')
  const adapted = text.replace(/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\+00:00/g, '$1Z')
  if (adapted === text) return result
  return { ...result, stdout: Buffer.from(adapted, 'latin1') }
}

/** Fixed identity and dates keep commit ids reproducible. */
export interface FixtureEnvironment {
  readonly home: string
  readonly env: Record<string, string>
}

/** Create the isolated environment the fixture git and the Worker git share. */
export function fixtureEnvironment(parent: string): FixtureEnvironment {
  const home = join(parent, 'home')
  mkdirSync(home, { recursive: true })
  return {
    home,
    env: {
      HOME: home,
      XDG_CONFIG_HOME: home,
      // No user or system configuration can leak into a fixture: the commit
      // ids and the golden bytes must depend only on the fixture itself.
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_GLOBAL: '/dev/null',
      GIT_TERMINAL_PROMPT: '0',
      GIT_AUTHOR_NAME: 'Fixture Author',
      GIT_AUTHOR_EMAIL: 'fixture@localhost',
      GIT_COMMITTER_NAME: 'Fixture Author',
      GIT_COMMITTER_EMAIL: 'fixture@localhost',
      GIT_AUTHOR_DATE: '1700000000 +0000',
      GIT_COMMITTER_DATE: '1700000000 +0000',
    },
  }
}

/** Run the system git. */
export function systemGit(
  args: readonly string[],
  cwd: string,
  env: Readonly<Record<string, string | undefined>>,
  stdin?: Buffer | string,
): CommandResult {
  const result = spawnSync('git', [...args], {
    cwd,
    env: { ...process.env, ...env },
    encoding: 'buffer',
    ...stdin === undefined ? {} : { input: stdin },
  })
  return {
    stdout: Buffer.from(result.stdout ?? ''),
    stderr: Buffer.from(result.stderr ?? ''),
    code: result.status ?? 1,
  }
}

/** Run the Worker git in-process. */
export async function workerGit(
  args: readonly string[],
  cwd: string,
  env: Readonly<Record<string, string | undefined>>,
  stdin?: Uint8Array | string,
): Promise<CommandResult> {
  const result = await runGit(args, {
    cwd,
    env: { ...process.env, ...env },
    ...stdin === undefined ? {} : { stdin },
  })
  return {
    stdout: Buffer.from(result.stdout),
    stderr: Buffer.from(result.stderr),
    code: result.exitCode,
  }
}

/** Register cleanup for one temporary directory. */
export function tempDirectory(): { path: string; cleanup: () => void } {
  const path = mkdtempSync(join(tmpdir(), 'pdsh-worker-git-'))
  return { path, cleanup: () => { rmSync(path, { recursive: true, force: true }) } }
}

/** Copy a fixture repository so two implementations can run independently. */
export function copyRepository(source: string, destination: string): void {
  cpSync(source, destination, { recursive: true, preserveTimestamps: true })
}

/** A write helper that also sets the executable bit. */
export function writeFile(path: string, content: string | Uint8Array, mode?: number): void {
  writeFileSync(path, content)
  if (mode !== undefined) chmodSync(path, mode)
}

/** Result of {@link buildFixture}. */
export interface Fixture {
  readonly repository: string
  readonly environment: FixtureEnvironment
  readonly baseTree: string
  readonly changedTree: string
  readonly baseCommit: string
  readonly secondCommit: string
}

/**
 * Build the golden fixture: a base commit, work-tree changes including an exact
 * rename, a binary edit, a mode change, a deletion, an addition and ignored
 * untracked files, then the second commit produced by the system git.
 */
export async function buildFixture(root: string): Promise<Fixture> {
  const environment = fixtureEnvironment(root)
  const repository = join(root, 'fixture')
  mkdirSync(repository)
  const env = environment.env
  const git = (args: readonly string[], stdin?: string): CommandResult => systemGit(args, repository, env, stdin)
  git(['init', '-q', '-b', 'main'])
  writeFile(join(repository, '.gitignore'), '*.log\nbuild/\n')
  writeFile(join(repository, 'a.txt'), 'alpha\nbeta\ngamma\n')
  writeFile(join(repository, 'mod.txt'), 'one\ntwo\nthree\nfour\nfive\n')
  writeFile(join(repository, 'del.txt'), 'gone\n')
  writeFile(join(repository, 'old-name.txt'), 'rename me\nsecond line\nthird line\n')
  writeFile(join(repository, 'bin.dat'), Uint8Array.from([0x62, 0x69, 0x6e, 0x00, 0x01, 0x02]))
  mkdirSync(join(repository, 'dir'))
  writeFile(join(repository, 'dir', 'n.txt'), 'nested\n')
  writeFile(join(repository, 'exec.sh'), '#!/bin/sh\necho hi\n', 0o755)
  mkdirSync(join(repository, 'sub'))
  writeFile(join(repository, 'sub', 'one.txt'), 'one\n')
  mkdirSync(join(repository, 'sub', 'deep'))
  writeFile(join(repository, 'sub', 'deep', 'd.txt'), 'deep\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'base commit'])
  const baseCommit = git(['rev-parse', 'HEAD']).stdout.toString().trim()
  const baseTree = git(['write-tree']).stdout.toString().trim()
  // Work-tree changes only; no `git add` yet so `add --all` has work to do.
  writeFile(join(repository, 'a.txt'), 'alpha\nBETA\ngamma\ndelta\n')
  writeFile(join(repository, 'mod.txt'), 'one\nTWO\nthree\nfour\nfive\n')
  rmSync(join(repository, 'del.txt'))
  cpSync(join(repository, 'old-name.txt'), join(repository, 'new-name.txt'))
  rmSync(join(repository, 'old-name.txt'))
  writeFile(join(repository, 'bin.dat'), Uint8Array.from([0x62, 0x69, 0x6e, 0x00, 0x0a, 0x0b, 0x0c]))
  chmodSync(join(repository, 'dir', 'n.txt'), 0o755)
  writeFile(join(repository, 'added.txt'), 'brand new\nline\n')
  writeFile(join(repository, 'ignored.log'), 'ignored\n')
  mkdirSync(join(repository, 'build'))
  writeFile(join(repository, 'build', 'out.bin'), 'ignored build\n')
  mkdirSync(join(repository, 'priv'))
  writeFile(join(repository, 'priv', 'p.txt'), 'private\n')
  git(['add', '-A'])
  const changedTree = git(['write-tree']).stdout.toString().trim()
  git(['commit', '-qm', 'second commit'])
  const secondCommit = git(['rev-parse', 'HEAD']).stdout.toString().trim()
  return {
    repository,
    environment,
    baseTree,
    changedTree,
    baseCommit,
    secondCommit,
  }
}

/** Assert that two command results match exactly. */
export function diffResults(expected: CommandResult, actual: CommandResult): string | undefined {
  if (expected.code !== actual.code) {
    return `exit ${actual.code} != ${expected.code}\n  expected stderr ${JSON.stringify(expected.stderr.toString())}\n  actual   stderr ${JSON.stringify(actual.stderr.toString())}`
  }
  if (Buffer.compare(expected.stdout, actual.stdout) !== 0) {
    return `stdout\n  expected ${JSON.stringify(expected.stdout.toString())}\n  actual   ${JSON.stringify(actual.stdout.toString())}`
  }
  if (Buffer.compare(expected.stderr, actual.stderr) !== 0) {
    return `stderr\n  expected ${JSON.stringify(expected.stderr.toString())}\n  actual   ${JSON.stringify(actual.stderr.toString())}`
  }
  return undefined
}
