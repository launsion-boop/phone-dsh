// SPDX-License-Identifier: MIT
/**
 * The failure contract for subcommands the Worker git deliberately does not
 * implement: exit 128, a clear `fatal:` line, the statement that the operation
 * needs host-side git (a limitation, not a tool the session can call) and no
 * change to the working tree or index. No diagnostic in this package may point
 * at the host exec bridge (`POST /v1/exec`): the Worker's `fetch` reaches only
 * `/v1/http` and static assets, so that endpoint is not reachable from inside
 * the session. Unknown subcommands keep git's ordinary "not a git command"
 * answer (exit 1).
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/unsupported.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, fixtureEnvironment, systemGit, tempDirectory, workerGit,
} from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

test('unsupported subcommands fail loud and state the host-side limitation', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    systemGit(['init', '-q', '-b', 'main'], repository, env)
    writeFileSync(join(repository, 'a.txt'), 'alpha\n')
    systemGit(['add', '-A'], repository, env)
    systemGit(['commit', '-qm', 'base'], repository, env)
    const before = systemGit(['status', '--porcelain'], repository, env).stdout.toString()
    for (const command of ['rebase', 'stash', 'submodule', 'gc', 'cherry-pick', 'worktree']) {
      const result = await workerGit([command, 'x'], repository, env)
      assert.equal(result.code, 128, `${command} exits 128`)
      const stderr = result.stderr.toString()
      assert.match(stderr, /^fatal: git /, `${command} starts with fatal`)
      assert.match(stderr, /unsupported inside the Worker/, `${command} says it is unsupported`)
      assert.match(stderr, /needs host-side git and is not available in this session/, `${command} states the limitation`)
      assert.match(stderr, /Nothing was changed/, `${command} promises no side effects`)
      // The host exec bridge is not reachable from the Worker: never instruct
      // the model to call it.
      assert.doesNotMatch(stderr, /\/v1\/exec/, `${command} must not name the unreachable host exec bridge`)
      assert.equal(result.stdout.byteLength, 0, `${command} writes nothing to stdout`)
    }
    assert.equal(systemGit(['status', '--porcelain'], repository, env).stdout.toString(), before, 'the tree is untouched')
    const unknown = await workerGit(['frobnicate'], repository, env)
    assert.equal(unknown.code, 1)
    assert.match(unknown.stderr.toString(), /^git: 'frobnicate' is not a git command/)
    const outside = await workerGit(['status'], temp.path, env)
    assert.equal(outside.code, 128)
    assert.match(outside.stderr.toString(), /fatal: not a git repository/)
  } finally {
    temp.cleanup()
  }
})

test('failing local operations never recommend the unreachable host exec bridge', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    systemGit(['init', '-q', '-b', 'main'], repository, env)
    writeFileSync(join(repository, 'a.txt'), 'alpha\n')
    systemGit(['add', '-A'], repository, env)
    systemGit(['commit', '-qm', 'base'], repository, env)
    // Locally implementable commands with a bad option, a missing path or an
    // unsupported form: each fails for a Worker-side reason, so none may send
    // the caller to a host endpoint.
    for (const args of [
      ['restore', '--frobnicate', 'a.txt'],
      ['restore', 'missing.txt'],
      ['commit', '--frobnicate'],
      ['checkout', '--', 'missing.txt'],
      ['status', '--ignored'],
      ['diff', '--binary'],
      ['remote', 'add', 'origin', 'https://example.invalid/repo.git'],
      ['merge', 'missing'],
    ]) {
      const result = await workerGit(args, repository, env)
      assert.notEqual(result.code, 0, `${args.join(' ')} fails`)
      assert.doesNotMatch(
        result.stderr.toString(),
        /\/v1\/exec/,
        `${args.join(' ')} must not recommend the unreachable host exec bridge`,
      )
    }
  } finally {
    temp.cleanup()
  }
})

test('real Worker git supports show <rev>:<path> and really trims ranges/show-ref', { skip }, async () => {
  // The git fixture must live outside the host /tmp: NodeGitFs maps the
  // virtual /tmp onto /dsh/tmp, and this container's os.tmpdir() is /tmp.
  const root = mkdtempSync(join(process.cwd(), '.pdsh-git-capability-'))
  try {
    const environment = fixtureEnvironment(root)
    const env = environment.env
    const repository = join(root, 'repo')
    mkdirSync(repository)
    systemGit(['init', '-q', '-b', 'main'], repository, env)
    writeFileSync(join(repository, 'a.txt'), 'alpha\n')
    systemGit(['add', '-A'], repository, env)
    systemGit(['commit', '-qm', 'base'], repository, env)
    writeFileSync(join(repository, 'a.txt'), 'beta\n')
    systemGit(['add', '-A'], repository, env)
    systemGit(['commit', '-qm', 'second'], repository, env)

    // Supported form: a blob's content, exactly like real git.
    const blob = await workerGit(['show', 'HEAD:a.txt'], repository, env)
    assert.equal(blob.code, 0, blob.stderr.toString())
    assert.equal(blob.stdout.toString(), 'beta\n')

    // A..B ranges are trimmed, not silently accepted as one revision.
    const range = await workerGit(['show', 'HEAD~1..HEAD'], repository, env)
    assert.notEqual(range.code, 0, 'A..B must not resolve')
    assert.match(range.stderr.toString(), /unsupported revision syntax|ambiguous argument/)

    // show-ref is not a subcommand (git's ordinary exit 1), so the disclosed
    // alternatives use commands that are implemented.
    const showRef = await workerGit(['show-ref'], repository, env)
    assert.equal(showRef.code, 1)
    assert.match(showRef.stderr.toString(), /'show-ref' is not a git command/)
    const revParse = await workerGit(['rev-parse', 'main'], repository, env)
    assert.equal(revParse.code, 0, revParse.stderr.toString())
    const branch = await workerGit(['branch', '--show-current'], repository, env)
    assert.equal(branch.stdout.toString(), 'main\n')

    // log --graph/--decorate are explicit unsupported options.
    const graph = await workerGit(['log', '--graph'], repository, env)
    assert.equal(graph.code, 129)
    assert.match(graph.stderr.toString(), /unsupported log option '--graph'/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('the Worker git package sources carry no unreachable POST /v1/exec recommendation', () => {
  const root = fileURLToPath(new URL('..', import.meta.url))
  const files = readdirSync(root, { withFileTypes: true })
    .filter(entry => entry.isFile() && (entry.name.endsWith('.ts') || entry.name === 'README.md'))
    .map(entry => entry.name)
  assert.ok(files.includes('cli.ts'), 'the source scan found the git package')
  for (const file of files) {
    const text = readFileSync(join(root, file), 'utf8')
    assert.doesNotMatch(text, /\/v1\/exec/, `${file} must not name the unreachable host exec bridge`)
  }
})
