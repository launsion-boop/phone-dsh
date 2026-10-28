// SPDX-License-Identifier: MIT
/**
 * The Worker shell integration surface: the just-bash-shaped `git` command,
 * the toolbox descriptor, and the registration helpers.
 *
 * The shell passes a byte-string stdin (`check-ignore -z --stdin`), an exported
 * environment and its cwd; the command must answer with byte-string streams and
 * a status, exactly like any other custom command in `createWorkerCommands`.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/command.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import { createGitCommand, createGitToolboxProgram, registerGitCommand, registerGitProgram, runGitForShell } from '../command.ts'
import type { GitShellContext } from '../command.ts'
import { HAS_GIT, SKIP_NO_GIT, fixtureEnvironment, systemGit, tempDirectory } from './helpers.ts'
import { VfsFileSystem } from '../../../shell-ext/src/filesystem.ts'
import { WorkerShell } from '../../../shell-ext/src/shell.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

/** The context shape just-bash hands to a custom command. */
function shellContext(cwd: string, env: Record<string, string>, stdin?: string): GitShellContext {
  return {
    cwd,
    env: new Map(Object.entries(env)),
    ...stdin === undefined ? {} : { stdin },
  }
}

test('createGitCommand is a just-bash shaped command over the VFS', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    const command = createGitCommand()
    assert.equal(command.name, 'git')
    assert.match(command.description, /workspace-changes/)
    const context = shellContext(repository, environment.env)
    const init = await command.execute(['init', '-b', 'main'], context)
    assert.equal(init.exitCode, 0)
    assert.match(init.stdout, /^Initialized empty Git repository/)
    writeFileSync(join(repository, 'a.txt'), 'alpha\n')
    const add = await command.execute(['add', '-A'], context)
    assert.equal(add.exitCode, 0, add.stderr)
    const status = await command.execute(['status', '--porcelain'], context)
    assert.equal(status.stdout, 'A  a.txt\n')
    const commit = await command.execute(['commit', '-m', 'base'], context)
    assert.equal(commit.exitCode, 0, commit.stderr)
    const log = await command.execute(['log', '--oneline'], context)
    assert.match(log.stdout, /^[0-9a-f]{7} base\n$/)
    // Byte-string stdin travels through unchanged: the NUL separator survives
    // because the shell hands latin1 code units rather than UTF-8 text.
    writeFileSync(join(repository, '.gitignore'), '*.log\n')
    writeFileSync(join(repository, 'x.log'), 'x\n')
    const nulInput = 'x.log\0a.txt\0'
    const ignored = await command.execute(['check-ignore', '-z', '--stdin'], shellContext(repository, environment.env, nulInput))
    assert.equal(ignored.exitCode, 0)
    assert.equal(ignored.stdout, 'x.log\0')
    // A failing command reports its status instead of throwing.
    const failure = await command.execute(['cat-file', 'blob', '0000000000000000000000000000000000000000'], context)
    assert.equal(failure.exitCode, 128)
    assert.match(failure.stderr, /^fatal: /)
    // The system git accepts what the command wrote.
    assert.equal(systemGit(['status', '--porcelain'], repository, environment.env).stdout.toString(), '?? .gitignore\n')
  } finally {
    temp.cleanup()
  }
})

test('runGitForShell honours exportedEnv and the abort signal', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    const exported = await runGitForShell(['init', '-b', 'main'], {
      cwd: repository,
      exportedEnv: environment.env,
    })
    assert.equal(exported.exitCode, 0)
    const controller = new AbortController()
    controller.abort()
    const aborted = await runGitForShell(['status'], { cwd: repository, env: environment.env, signal: controller.signal })
    assert.equal(aborted.exitCode, 130)
    assert.match(aborted.stderr, /interrupted/)
  } finally {
    temp.cleanup()
  }
})

test('the registration helpers feed both command tables', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    const shellTable: { name: string; execute?: unknown }[] = []
    const registered = registerGitCommand({ register: (command: { name: string }) => { shellTable.push(command) } })
    assert.equal(registered.name, 'git')
    assert.equal(shellTable.length, 1)
    const toolboxTable: unknown[] = []
    const program = registerGitProgram({ register: (command: unknown) => { toolboxTable.push(command) } })
    assert.equal(program.program, 'git')
    assert.equal(toolboxTable.length, 1)
    let stdout = ''
    let stderr = ''
    const run = await createGitToolboxProgram().run({
      argv: ['init', '-b', 'main'],
      cwd: repository,
      env: environment.env,
      onStdout: chunk => { stdout += Buffer.from(chunk).toString() },
      onStderr: chunk => { stderr += Buffer.from(chunk).toString() },
    })
    assert.equal(run.exitCode, 0, stderr)
    assert.match(stdout, /^Initialized empty Git repository/)
  } finally {
    temp.cleanup()
  }
})

test('the command runs inside the Worker shell core (just-bash)', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = join(temp.path, 'shell-repo')
    mkdirSync(repository)
    // VfsFileSystem with an empty root maps virtual paths to the real paths the
    // Worker's node:fs would present, which is exactly the production layout.
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root: '' }),
      commands: [createGitCommand()],
    })
    const init = await shell.run(['bash', '-c', 'git init -b main && echo one > a.txt && git add -A && git status --porcelain'], {
      cwd: repository,
      env: environment.env,
    })
    assert.equal(init.exitCode, 0, init.stderr)
    assert.match(init.stdout, /^Initialized empty Git repository/)
    assert.equal(init.stdout.endsWith('A  a.txt\n'), true, init.stdout)
    const commit = await shell.run(['bash', '-c', 'git commit -m base && git log --oneline'], {
      cwd: repository,
      env: environment.env,
    })
    assert.equal(commit.exitCode, 0, commit.stderr)
    assert.match(commit.stdout, /^\[main \(root-commit\) [0-9a-f]{7}\] base\n(?: .*\n)*[0-9a-f]{7} base\n$/)
    // A failing git command surfaces its status through the shell.
    const failure = await shell.run(['bash', '-c', 'git cat-file blob 0000000000000000000000000000000000000000'], {
      cwd: repository,
      env: environment.env,
    })
    assert.equal(failure.exitCode, 128)
    assert.match(failure.stderr, /fatal: git cat-file/)
  } finally {
    temp.cleanup()
  }
})
