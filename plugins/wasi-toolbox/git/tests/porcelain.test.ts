// SPDX-License-Identifier: MIT
/**
 * Porcelain tests: `init`, `add`, `commit`, `status`, `log`, `diff`,
 * `branch`, `checkout`/`switch`, fast-forward `merge`, `rm` and `show`.
 *
 * Where the output is a machine format (`status --porcelain`, `log --oneline`,
 * `diff`) it is compared with the system git byte-for-byte; where it is a
 * summary (`commit`'s statistics, checkout's stderr) the test asserts the
 * observable state instead — the commit object itself is compared byte-for-byte
 * by id, which is the stronger contract.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/porcelain.test
 */
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, buildFixture, copyRepository, diffResults, fixtureEnvironment, systemGit, tempDirectory,
  workerGit,
} from './helpers.ts'
import type { CommandResult } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

function expectSame(label: string, expected: CommandResult, actual: CommandResult): void {
  const difference = diffResults(expected, actual)
  assert.equal(difference, undefined, `${label}: ${difference}`)
}

/** Create a small repository with the system git and return its path. */
function simpleRepo(root: string, env: Record<string, string>): string {
  const repository = join(root, 'repo')
  mkdirSync(repository)
  const git = (args: readonly string[]): CommandResult => systemGit(args, repository, env)
  git(['init', '-q', '-b', 'main'])
  writeFileSync(join(repository, 'a.txt'), 'alpha\nbeta\ngamma\n')
  writeFileSync(join(repository, 'b.txt'), 'one\ntwo\n')
  mkdirSync(join(repository, 'sub'))
  writeFileSync(join(repository, 'sub', 'c.txt'), 'see\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'base'])
  return repository
}

test('git init creates a repository the system git accepts', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    const init = await workerGit(['init', '-b', 'main'], repository, environment.env)
    assert.equal(init.code, 0, init.stderr.toString())
    assert.match(init.stdout.toString(), /^Initialized empty Git repository in .*\/\.git\/\n$/)
    assert.equal(readFileSync(join(repository, '.git', 'HEAD'), 'utf8'), 'ref: refs/heads/main\n')
    assert.equal(systemGit(['status', '--porcelain'], repository, environment.env).stdout.toString(), '')
    assert.equal(systemGit(['rev-parse', '--abbrev-ref', 'HEAD'], repository, environment.env).stdout.toString(), 'HEAD\n')
    // A second init reports the reinitialised wording.
    const again = await workerGit(['init'], repository, environment.env)
    assert.equal(again.code, 0)
    assert.match(again.stdout.toString(), /^Reinitialized existing Git repository/)
  } finally {
    temp.cleanup()
  }
})

test('our commit object is byte-identical to the system git commit', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = { ...environment.env, GIT_AUTHOR_DATE: '1700000500 +0000', GIT_COMMITTER_DATE: '1700000500 +0000' }
    const systemRepo = simpleRepo(temp.path, env)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      writeFileSync(join(repository, 'a.txt'), 'alpha\nBETA\n')
      writeFileSync(join(repository, 'new file.txt'), 'new\n')
    }
    const systemAdd = systemGit(['add', '-A'], systemRepo, env)
    assert.equal(systemAdd.code, 0, systemAdd.stderr.toString())
    const systemResult = systemGit(['commit', '-qm', 'second commit\n\nbody line'], systemRepo, env)
    assert.equal(systemResult.code, 0, systemResult.stderr.toString())
    const workerAdd = await workerGit(['add', '-A'], workerRepo, env)
    assert.equal(workerAdd.code, 0, workerAdd.stderr.toString())
    const workerCommit = await workerGit(['commit', '-m', 'second commit', '-m', 'body line'], workerRepo, env)
    assert.equal(workerCommit.code, 0, workerCommit.stderr.toString())
    const systemId = systemGit(['rev-parse', 'HEAD'], systemRepo, env).stdout.toString().trim()
    const workerId = systemGit(['rev-parse', 'HEAD'], workerRepo, env).stdout.toString().trim()
    assert.equal(workerId, systemId, 'identical commit object')
    expectSame(
      'system git reads the Worker commit',
      systemGit(['cat-file', '-p', systemId], systemRepo, env),
      systemGit(['cat-file', '-p', workerId], workerRepo, env),
    )
    const fsck = systemGit(['fsck', '--strict'], workerRepo, env)
    assert.equal(fsck.code, 0, `${fsck.stdout.toString()}${fsck.stderr.toString()}`)
    expectSame('log after the Worker commit', systemGit(['log', '--oneline'], systemRepo, env), await workerGit(['log', '--oneline'], workerRepo, env))
  } finally {
    temp.cleanup()
  }
})

test('status / diff / log / branch / show / rm match the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const fixture = await buildFixture(temp.path)
    const repository = fixture.repository
    const env = environment.env
    const git = (args: readonly string[]): CommandResult => systemGit(args, repository, env)
    const ours = async (args: readonly string[]): Promise<CommandResult> => workerGit(args, repository, env)
    // Fixture is committed; introduce each status class.
    writeFileSync(join(repository, 'a.txt'), 'alpha\nBETA\ngamma\ndelta\nedited\n')
    writeFileSync(join(repository, 'untracked.txt'), 'u\n')
    mkdirSync(join(repository, 'untracked-dir'))
    writeFileSync(join(repository, 'untracked-dir', 'x.txt'), 'x\n')
    rmSync(join(repository, 'sub', 'deep', 'd.txt'))
    git(['add', 'sub/deep/d.txt'])
    writeFileSync(join(repository, 'staged.txt'), 'staged\n')
    git(['add', 'staged.txt'])
    for (const args of [
      ['status', '--porcelain'],
      ['status', '--porcelain', '-z'],
      ['status', '--short'],
      ['status'],
      ['status', '--porcelain', '-uall'],
    ]) {
      expectSame(args.join(' '), git(args), await ours(args))
    }
    for (const args of [
      ['diff'],
      ['diff', '--cached'],
      ['diff', '--cached', '--name-status'],
      ['diff', '--cached', '--numstat'],
      ['diff', 'HEAD', '--name-only'],
      ['diff', '--stat'],
    ]) {
      expectSame(args.join(' '), git(args), await ours(args))
    }
    for (const args of [
      ['log', '--oneline'],
      ['log', '--oneline', '-n', '1'],
      ['log', '-n', '1'],
      ['log', '--stat', '-n', '1'],
      ['show', 'HEAD'],
      ['show', '--stat', 'HEAD'],
      ['show', '--oneline', 'HEAD'],
    ]) {
      expectSame(args.join(' '), git(args), await ours(args))
    }
    // Destructive operations run on independent copies of the same state.
    const systemBranch = join(temp.path, 'branch-system')
    const workerBranch = join(temp.path, 'branch-worker')
    copyRepository(repository, systemBranch)
    copyRepository(repository, workerBranch)
    const systemGitAt = (args: readonly string[]): CommandResult => systemGit(args, systemBranch, env)
    const workerGitAt = async (args: readonly string[]): Promise<CommandResult> => workerGit(args, workerBranch, env)
    expectSame('branch create', systemGitAt(['branch', 'side', 'HEAD~1']), await workerGitAt(['branch', 'side', 'HEAD~1']))
    expectSame('branch list', systemGitAt(['branch']), await workerGitAt(['branch']))
    expectSame('branch show-current', systemGitAt(['branch', '--show-current']), await workerGitAt(['branch', '--show-current']))
    expectSame('branch delete', systemGitAt(['branch', '-D', 'side']), await workerGitAt(['branch', '-D', 'side']))
    expectSame('branch list after delete', systemGitAt(['branch']), await workerGitAt(['branch']))
    const systemRm = join(temp.path, 'rm-system')
    const workerRm = join(temp.path, 'rm-worker')
    copyRepository(repository, systemRm)
    copyRepository(repository, workerRm)
    // rm --cached stages a deletion and leaves the file in place.
    expectSame('rm --cached', systemGit(['rm', '--cached', 'untracked.txt'], systemRm, env), await workerGit(['rm', '--cached', 'untracked.txt'], workerRm, env))
    expectSame('status after rm', systemGit(['status', '--porcelain'], systemRm, env), systemGit(['status', '--porcelain'], workerRm, env))
    assert.equal(existsSync(join(workerRm, 'untracked.txt')), true, 'rm --cached left the file in place')
  } finally {
    temp.cleanup()
  }
})

test('UTF-8 text and Unicode paths stay UTF-8 while cat-file preserves binary blob bytes', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = join(temp.path, 'unicode-system')
    mkdirSync(systemRepo)
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    system(['init', '-q', '-b', 'main'])
    const textPath = '中文-🙂.txt'
    const binaryPath = '数据-📦.bin'
    const originalText = '你好，世界\n初始文字\n'
    const updatedText = '你好，世界\n更新 ✅\n'
    const originalBinary = Uint8Array.from([0x00, 0x80, 0xff, 0x41, 0x0a])
    const updatedBinary = Uint8Array.from([0x00, 0x81, 0xfe, 0x42, 0x0a])
    writeFileSync(join(systemRepo, textPath), originalText)
    writeFileSync(join(systemRepo, binaryPath), originalBinary)
    system(['add', '-A'])
    assert.equal(system(['commit', '-qm', '中文初始提交']).code, 0)
    const workerRepo = join(temp.path, 'unicode-worker')
    copyRepository(systemRepo, workerRepo)
    const worker = (args: readonly string[]): Promise<CommandResult> => workerGit(args, workerRepo, env)

    for (const path of [textPath, binaryPath]) {
      const oid = system([`rev-parse`, `HEAD:${path}`]).stdout.toString().trim()
      expectSame(`cat-file blob ${path}`, system(['cat-file', 'blob', oid]), await worker(['cat-file', 'blob', oid]))
    }
    expectSame('show UTF-8 commit and Unicode paths', system(['show', 'HEAD']), await worker(['show', 'HEAD']))

    for (const repository of [systemRepo, workerRepo]) {
      writeFileSync(join(repository, textPath), updatedText)
      writeFileSync(join(repository, binaryPath), updatedBinary)
    }
    expectSame('diff UTF-8 text, Unicode paths, and binary summary', system(['diff']), await worker(['diff']))
    system(['add', '-A'])
    assert.equal((await worker(['add', '-A'])).code, 0)
    expectSame('cached diff UTF-8 text and binary summary', system(['diff', '--cached']), await worker(['diff', '--cached']))
    assert.equal(system(['commit', '-qm', '更新中文文件']).code, 0)
    assert.equal((await worker(['commit', '-m', '更新中文文件'])).code, 0)
    expectSame('show UTF-8 commit and binary change', system(['show', 'HEAD']), await worker(['show', 'HEAD']))
  } finally {
    temp.cleanup()
  }
})

test('branch --list patterns filter like the system git and unmatched patterns stay empty', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = simpleRepo(temp.path, environment.env)
    for (const name of ['stable', 'feature/ui', 'feature/api', 'release']) {
      const created = systemGit(['branch', name], source, environment.env)
      assert.equal(created.code, 0, created.stderr.toString())
    }
    const systemRepo = join(temp.path, 'branch-system')
    const workerRepo = join(temp.path, 'branch-worker')
    copyRepository(source, systemRepo)
    copyRepository(source, workerRepo)
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, environment.env)
    const worker = (args: readonly string[]): Promise<CommandResult> => workerGit(args, workerRepo, environment.env)

    for (const args of [
      ['branch', '--list', 'sta*'],
      ['branch', '--list', 'feature/*'],
      ['branch', '-l', 'release'],
      ['branch', '--list', 'missing*'],
    ]) {
      expectSame(args.join(' '), system(args), await worker(args))
    }
  } finally {
    temp.cleanup()
  }
})

test('checkout / switch update the work tree and index like the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const source = simpleRepo(temp.path, env)
    const git = (repository: string, args: readonly string[]): CommandResult => systemGit(args, repository, env)
    // Build `feature` with one extra commit and a deleted file.
    git(source, ['switch', '-q', '-c', 'feature'])
    writeFileSync(join(source, 'feature.txt'), 'feature\n')
    writeFileSync(join(source, 'b.txt'), 'one\ntwo\nthree\n')
    git(source, ['add', '-A'])
    git(source, ['commit', '-qm', 'feature work'])
    git(source, ['switch', '-q', 'main'])
    const systemRepo = join(temp.path, 'system')
    const workerRepo = join(temp.path, 'worker')
    copyRepository(source, systemRepo)
    copyRepository(source, workerRepo)
    // A dirty file that is unchanged between branches must survive the switch.
    writeFileSync(join(systemRepo, 'sub', 'c.txt'), 'local edit\n')
    writeFileSync(join(workerRepo, 'sub', 'c.txt'), 'local edit\n')
    const systemSwitch = systemGit(['switch', 'feature'], systemRepo, env)
    const workerSwitch = await workerGit(['switch', 'feature'], workerRepo, env)
    assert.equal(systemSwitch.code, 0, systemSwitch.stderr.toString())
    assert.equal(workerSwitch.code, 0, workerSwitch.stderr.toString())
    for (const relative of ['a.txt', 'b.txt', 'feature.txt', 'sub/c.txt']) {
      assert.equal(
        readFileSync(join(workerRepo, relative)).toString(),
        readFileSync(join(systemRepo, relative)).toString(),
        `work tree ${relative}`,
      )
    }
    expectSame('status after switch', systemGit(['status', '--porcelain'], systemRepo, env), systemGit(['status', '--porcelain'], workerRepo, env))
    // Restore one path from the index.
    writeFileSync(join(systemRepo, 'a.txt'), 'broken\n')
    writeFileSync(join(workerRepo, 'a.txt'), 'broken\n')
    expectSame('checkout -- path', systemGit(['checkout', '--', 'a.txt'], systemRepo, env), await workerGit(['checkout', '--', 'a.txt'], workerRepo, env))
    assert.equal(readFileSync(join(workerRepo, 'a.txt')).toString(), readFileSync(join(systemRepo, 'a.txt')).toString())
    // Create a branch with -b and switch back.
    const systemCreate = systemGit(['checkout', '-b', 'from-worker'], systemRepo, env)
    const create = await workerGit(['checkout', '-b', 'from-worker'], workerRepo, env)
    assert.equal(systemCreate.code, 0, systemCreate.stderr.toString())
    assert.equal(create.code, 0, create.stderr.toString())
    expectSame('branch after checkout -b', systemGit(['branch'], systemRepo, env), await workerGit(['branch'], workerRepo, env))
    const back = await workerGit(['switch', 'main'], workerRepo, env)
    assert.equal(back.code, 0, back.stderr.toString())
    assert.equal(existsSync(join(workerRepo, 'feature.txt')), false)
    expectSame('status after switch back', systemGit(['status', '--porcelain'], systemRepo, env), systemGit(['status', '--porcelain'], workerRepo, env))
  } finally {
    temp.cleanup()
  }
})

test('fast-forward merge matches the system git and a conflicting merge fails loud', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const source = simpleRepo(temp.path, env)
    const git = (repository: string, args: readonly string[]): CommandResult => systemGit(args, repository, env)
    git(source, ['switch', '-q', '-c', 'feature'])
    writeFileSync(join(source, 'feature.txt'), 'feature\n')
    git(source, ['add', '-A'])
    git(source, ['commit', '-qm', 'feature work'])
    git(source, ['switch', '-q', 'main'])
    const systemRepo = join(temp.path, 'system')
    const workerRepo = join(temp.path, 'worker')
    copyRepository(source, systemRepo)
    copyRepository(source, workerRepo)
    const systemMerge = systemGit(['merge', 'feature'], systemRepo, env)
    const workerMerge = await workerGit(['merge', 'feature'], workerRepo, env)
    assert.equal(systemMerge.code, 0, systemMerge.stderr.toString())
    assert.equal(workerMerge.code, 0, workerMerge.stderr.toString())
    expectSame('merge log', systemGit(['log', '--oneline'], systemRepo, env), await workerGit(['log', '--oneline'], workerRepo, env))
    expectSame('merge status', systemGit(['status', '--porcelain'], systemRepo, env), systemGit(['status', '--porcelain'], workerRepo, env))
    assert.equal(readFileSync(join(workerRepo, 'feature.txt')).toString(), 'feature\n')
    // A divergent history needs a three-way merge: both fail, ours states the
    // limitation and leaves the tree untouched.
    writeFileSync(join(workerRepo, 'main-only.txt'), 'main\n')
    git(workerRepo, ['add', '-A'])
    git(workerRepo, ['commit', '-qm', 'main only'])
    git(workerRepo, ['switch', '-q', 'feature'])
    writeFileSync(join(workerRepo, 'feature-only.txt'), 'feature\n')
    git(workerRepo, ['add', '-A'])
    git(workerRepo, ['commit', '-qm', 'feature only'])
    git(workerRepo, ['switch', '-q', 'main'])
    const before = git(workerRepo, ['status', '--porcelain']).stdout.toString()
    const conflicting = await workerGit(['merge', 'feature'], workerRepo, env)
    assert.equal(conflicting.code, 128)
    assert.match(conflicting.stderr.toString(), /three-way conflict resolution, which the Worker git does not do/)
    assert.match(conflicting.stderr.toString(), /Nothing was changed/)
    assert.doesNotMatch(conflicting.stderr.toString(), /\/v1\/exec/)
    assert.equal(git(workerRepo, ['status', '--porcelain']).stdout.toString(), before)
  } finally {
    temp.cleanup()
  }
})
