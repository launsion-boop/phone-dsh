// SPDX-License-Identifier: MIT
/**
 * Golden vectors for the undo/correct family: `git commit --amend` and
 * `git restore`.
 *
 * Both commands are locally implementable — they only need the object
 * database, the index and the work tree the Worker git already owns — so the
 * fixture runs the system git on one copy and the Worker git on a second copy
 * and compares the observable repository state (commit object, refs, index,
 * work tree and status) instead of accepting a hand-written expectation.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/restore-amend.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, copyRepository, diffResults, fixtureEnvironment, systemGit, tempDirectory, workerGit,
} from './helpers.ts'
import type { CommandResult } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

function expectSame(label: string, expected: CommandResult, actual: CommandResult): void {
  const difference = diffResults(expected, actual)
  assert.equal(difference, undefined, `${label}: ${difference}`)
}

function write(root: string, path: string, content: string): void {
  const absolute = join(root, path)
  const slash = path.lastIndexOf('/')
  if (slash > 0) mkdirSync(join(root, path.slice(0, slash)), { recursive: true })
  writeFileSync(absolute, content)
}

/** A two-commit repository with a nested directory, built by the system git. */
function buildRepository(root: string, env: Record<string, string>): string {
  const repository = join(root, 'repo')
  mkdirSync(repository)
  const git = (args: readonly string[]): CommandResult => {
    const result = systemGit(args, repository, env)
    assert.equal(result.code, 0, `${args.join(' ')}: ${result.stderr.toString()}`)
    return result
  }
  git(['init', '-q', '-b', 'main'])
  write(repository, 'a.txt', 'one\n')
  write(repository, 'b.txt', 'two\n')
  write(repository, 'sub/c.txt', 'three\n')
  git(['add', '-A'])
  git(['commit', '-qm', 'base'])
  write(repository, 'a.txt', 'base-a\n')
  git(['add', 'a.txt'])
  git(['commit', '-qm', 'second'])
  return repository
}

/** Compare the index shape the system git prints for both repositories. */
function expectSameIndex(label: string, systemRepository: string, workerRepository: string, env: Record<string, string>): void {
  expectSame(
    label,
    systemGit(['ls-files', '--stage'], systemRepository, env),
    systemGit(['ls-files', '--stage'], workerRepository, env),
  )
}

test('git commit --amend replaces HEAD and moves the branch like the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const baseEnv = fixtureEnvironment(temp.path).env
    const source = buildRepository(temp.path, baseEnv)
    const systemRepo = join(temp.path, 'amend-system')
    const workerRepo = join(temp.path, 'amend-worker')
    write(source, 'a.txt', 'amended work\n')
    assert.equal(systemGit(['add', '-A'], source, baseEnv).code, 0)
    copyRepository(source, systemRepo)
    copyRepository(source, workerRepo)
    const amendEnv = { ...baseEnv, GIT_AUTHOR_DATE: '1700000500 +0000', GIT_COMMITTER_DATE: '1700000500 +0000' }
    const oldHead = systemGit(['rev-parse', 'HEAD'], workerRepo, baseEnv).stdout.toString().trim()

    const expected = systemGit(['commit', '--amend', '--no-edit'], systemRepo, amendEnv)
    const actual = await workerGit(['commit', '--amend', '--no-edit'], workerRepo, amendEnv)
    assert.equal(expected.code, 0, expected.stderr.toString())
    assert.equal(actual.code, 0, actual.stderr.toString())

    const expectedHead = systemGit(['rev-parse', 'HEAD'], systemRepo, amendEnv).stdout.toString().trim()
    const actualHead = systemGit(['rev-parse', 'HEAD'], workerRepo, amendEnv).stdout.toString().trim()
    assert.notEqual(actualHead, oldHead, 'amend created a new commit')
    assert.equal(actualHead, expectedHead, 'amend produced the same commit id as the system git')
    // The current branch ref follows the amended commit.
    assert.equal(
      systemGit(['rev-parse', 'refs/heads/main'], workerRepo, amendEnv).stdout.toString().trim(),
      actualHead,
      'the branch ref moved to the new commit',
    )
    // The amended commit keeps HEAD's tree, parent, author and message.
    expectSame(
      'amended commit object',
      systemGit(['cat-file', '-p', expectedHead], systemRepo, amendEnv),
      systemGit(['cat-file', '-p', actualHead], workerRepo, amendEnv),
    )
    expectSame('log after amend', systemGit(['log', '--oneline'], systemRepo, amendEnv), await workerGit(['log', '--oneline'], workerRepo, amendEnv))
    expectSame(
      'status after amend',
      systemGit(['status', '--porcelain'], systemRepo, amendEnv),
      systemGit(['status', '--porcelain'], workerRepo, amendEnv),
    )
    expectSame(
      'parent after amend',
      systemGit(['rev-parse', 'HEAD^'], systemRepo, amendEnv),
      systemGit(['rev-parse', 'HEAD^'], workerRepo, amendEnv),
    )

    // A second amend with an explicit message replaces the message too.
    for (const repository of [systemRepo, workerRepo]) {
      write(repository, 'b.txt', 'second amend\n')
      assert.equal(systemGit(['add', 'b.txt'], repository, baseEnv).code, 0)
    }
    const messageEnv = { ...baseEnv, GIT_AUTHOR_DATE: '1700000600 +0000', GIT_COMMITTER_DATE: '1700000600 +0000' }
    assert.equal(systemGit(['commit', '--amend', '-m', 'amended subject', '-m', 'body line'], systemRepo, messageEnv).code, 0)
    const workerMessage = await workerGit(['commit', '--amend', '-m', 'amended subject', '-m', 'body line'], workerRepo, messageEnv)
    assert.equal(workerMessage.code, 0, workerMessage.stderr.toString())
    const expectedMessageHead = systemGit(['rev-parse', 'HEAD'], systemRepo, messageEnv).stdout.toString().trim()
    const actualMessageHead = systemGit(['rev-parse', 'HEAD'], workerRepo, messageEnv).stdout.toString().trim()
    assert.equal(actualMessageHead, expectedMessageHead, 'messaged amend matches the system git commit id')
    expectSame(
      'messaged amended commit object',
      systemGit(['cat-file', '-p', expectedMessageHead], systemRepo, messageEnv),
      systemGit(['cat-file', '-p', actualMessageHead], workerRepo, messageEnv),
    )

    // An amend with nothing staged is still a valid rewrite (the empty-commit
    // check compares the new tree with the amended commit's parent).
    const noChangeEnv = { ...baseEnv, GIT_AUTHOR_DATE: '1700000700 +0000', GIT_COMMITTER_DATE: '1700000700 +0000' }
    assert.equal(systemGit(['commit', '--amend', '--no-edit'], systemRepo, noChangeEnv).code, 0)
    const workerNoChange = await workerGit(['commit', '--amend', '--no-edit'], workerRepo, noChangeEnv)
    assert.equal(workerNoChange.code, 0, workerNoChange.stderr.toString())
    const expectedNoChangeHead = systemGit(['rev-parse', 'HEAD'], systemRepo, noChangeEnv).stdout.toString().trim()
    const actualNoChangeHead = systemGit(['rev-parse', 'HEAD'], workerRepo, noChangeEnv).stdout.toString().trim()
    assert.equal(actualNoChangeHead, expectedNoChangeHead, 'no-change amend matches the system git commit id')

    // --author replaces the author identity but an amend keeps the original
    // author date, exactly like the system git.
    const authorEnv = { ...baseEnv, GIT_AUTHOR_DATE: '1700000800 +0000', GIT_COMMITTER_DATE: '1700000800 +0000' }
    assert.equal(
      systemGit(['commit', '--amend', '--no-edit', '--author', 'Other <other@localhost>'], systemRepo, authorEnv).code,
      0,
    )
    const workerAuthor = await workerGit(
      ['commit', '--amend', '--no-edit', '--author', 'Other <other@localhost>'],
      workerRepo,
      authorEnv,
    )
    assert.equal(workerAuthor.code, 0, workerAuthor.stderr.toString())
    const expectedAuthorHead = systemGit(['rev-parse', 'HEAD'], systemRepo, authorEnv).stdout.toString().trim()
    const actualAuthorHead = systemGit(['rev-parse', 'HEAD'], workerRepo, authorEnv).stdout.toString().trim()
    assert.equal(actualAuthorHead, expectedAuthorHead, '--author amend matches the system git commit id')
    expectSame(
      '--author amended commit object',
      systemGit(['cat-file', '-p', expectedAuthorHead], systemRepo, authorEnv),
      systemGit(['cat-file', '-p', actualAuthorHead], workerRepo, authorEnv),
    )

    // Amending a root commit keeps zero parents.
    const rootSource = join(temp.path, 'root-repo')
    mkdirSync(rootSource)
    const rootGit = (args: readonly string[]): CommandResult => {
      const result = systemGit(args, rootSource, baseEnv)
      assert.equal(result.code, 0, result.stderr.toString())
      return result
    }
    rootGit(['init', '-q', '-b', 'main'])
    write(rootSource, 'root.txt', 'root\n')
    rootGit(['add', '-A'])
    rootGit(['commit', '-qm', 'root commit'])
    write(rootSource, 'root.txt', 'root amended\n')
    rootGit(['add', '-A'])
    const rootSystem = join(temp.path, 'root-system')
    const rootWorker = join(temp.path, 'root-worker')
    copyRepository(rootSource, rootSystem)
    copyRepository(rootSource, rootWorker)
    assert.equal(systemGit(['commit', '--amend', '-m', 'root amended'], rootSystem, baseEnv).code, 0)
    const rootAmend = await workerGit(['commit', '--amend', '-m', 'root amended'], rootWorker, baseEnv)
    assert.equal(rootAmend.code, 0, rootAmend.stderr.toString())
    const rootExpected = systemGit(['rev-parse', 'HEAD'], rootSystem, baseEnv).stdout.toString().trim()
    const rootActual = systemGit(['rev-parse', 'HEAD'], rootWorker, baseEnv).stdout.toString().trim()
    assert.equal(rootActual, rootExpected, 'root amend matches the system git commit id')
    expectSame(
      'root amended commit object',
      systemGit(['cat-file', '-p', rootExpected], rootSystem, baseEnv),
      systemGit(['cat-file', '-p', rootActual], rootWorker, baseEnv),
    )
    assert.doesNotMatch(
      systemGit(['cat-file', '-p', rootActual], rootWorker, baseEnv).stdout.toString(),
      /^parent /m,
      'the amended root commit has no parent',
    )
  } finally {
    temp.cleanup()
  }
})

test('git restore (default, --staged, --source, pathspec) matches the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const env = fixtureEnvironment(temp.path).env
    const source = buildRepository(temp.path, env)
    // Stage one change per file, then dirty both work-tree copies on top.
    write(source, 'a.txt', 'staged-a\n')
    write(source, 'b.txt', 'staged-b\n')
    assert.equal(systemGit(['add', 'a.txt', 'b.txt'], source, env).code, 0)
    write(source, 'a.txt', 'worktree-a\n')
    write(source, 'b.txt', 'worktree-b\n')
    write(source, 'untracked.txt', 'untracked\n')
    // A staged restore writes an index stat cache. Keep the work-tree mtime
    // old so the cache is not "racily clean": a cache copied from the dirty
    // file would then hide the work-tree change from `git status` every time,
    // and the golden comparison catches it deterministically.
    const oldTime = new Date('2001-02-03T04:05:06Z')
    utimesSync(join(source, 'b.txt'), oldTime, oldTime)
    const systemRepo = join(temp.path, 'restore-system')
    const workerRepo = join(temp.path, 'restore-worker')
    copyRepository(source, systemRepo)
    copyRepository(source, workerRepo)

    const both = async (args: readonly string[]): Promise<void> => {
      const expected = systemGit(args, systemRepo, env)
      const actual = await workerGit(args, workerRepo, env)
      assert.equal(expected.code, 0, expected.stderr.toString())
      assert.equal(actual.code, 0, actual.stderr.toString())
      expectSame(args.join(' '), expected, actual)
    }
    const expectState = async (label: string): Promise<void> => {
      expectSame(
        `${label}: status`,
        systemGit(['status', '--porcelain'], systemRepo, env),
        systemGit(['status', '--porcelain'], workerRepo, env),
      )
      expectSame(
        `${label}: Worker status`,
        systemGit(['status', '--porcelain'], systemRepo, env),
        await workerGit(['status', '--porcelain'], workerRepo, env),
      )
      expectSameIndex(`${label}: index`, systemRepo, workerRepo, env)
      for (const path of ['a.txt', 'b.txt', 'sub/c.txt']) {
        assert.equal(
          readFileSync(join(workerRepo, path), 'utf8'),
          readFileSync(join(systemRepo, path), 'utf8'),
          `${label}: work tree ${path}`,
        )
      }
    }

    // Default: work tree from the index.
    await both(['restore', 'a.txt'])
    assert.equal(readFileSync(join(workerRepo, 'a.txt'), 'utf8'), 'staged-a\n', 'restore took the index copy')
    await expectState('restore <path>')

    // --staged: index from HEAD; the work tree is left alone.
    await both(['restore', '--staged', 'b.txt'])
    assert.equal(readFileSync(join(workerRepo, 'b.txt'), 'utf8'), 'worktree-b\n', 'restore --staged left the work tree')
    await expectState('restore --staged')

    // --source=<tree-ish>: work tree from an older commit, index untouched.
    await both(['restore', '--source=HEAD~1', 'a.txt'])
    assert.equal(readFileSync(join(workerRepo, 'a.txt'), 'utf8'), 'one\n', 'restore --source took the older blob')
    await expectState('restore --source')

    // --staged --source=<tree-ish>: the index follows the same tree.
    await both(['restore', '--staged', '--source=HEAD~1', 'a.txt'])
    await expectState('restore --staged --source')

    // --staged --worktree writes both from the source.
    await both(['restore', '--staged', '--worktree', 'b.txt'])
    assert.equal(readFileSync(join(workerRepo, 'b.txt'), 'utf8'), 'two\n', 'restore --staged --worktree reset both')
    await expectState('restore --staged --worktree')

    // A directory pathspec restores every tracked path underneath it.
    rmSync(join(systemRepo, 'sub'), { recursive: true, force: true })
    rmSync(join(workerRepo, 'sub'), { recursive: true, force: true })
    await both(['restore', 'sub/'])
    assert.equal(readFileSync(join(workerRepo, 'sub/c.txt'), 'utf8'), 'three\n')
    await expectState('restore directory pathspec')

    // A tree object is a valid --source.
    const tree = systemGit(['rev-parse', 'HEAD~1^{tree}'], systemRepo, env).stdout.toString().trim()
    await both(['restore', `--source=${tree}`, 'b.txt'])
    assert.equal(readFileSync(join(workerRepo, 'b.txt'), 'utf8'), 'two\n')
    await expectState('restore --source=<tree>')

    // An unmatched pathspec is git's ordinary error, not a fatal or an
    // instruction to leave the Worker.
    const expectedMissing = systemGit(['restore', 'missing.txt'], systemRepo, env)
    const actualMissing = await workerGit(['restore', 'missing.txt'], workerRepo, env)
    assert.equal(actualMissing.code, 1, 'unmatched restore exits 1')
    expectSame('restore unmatched pathspec', expectedMissing, actualMissing)
    assert.doesNotMatch(actualMissing.stderr.toString(), /\/v1\/exec/)

    // `git checkout -- <path>` runs through the same primitive and agrees.
    const checkoutSystem = join(temp.path, 'checkout-system')
    const checkoutWorkerRestore = join(temp.path, 'checkout-worker-restore')
    const checkoutWorkerCheckout = join(temp.path, 'checkout-worker-checkout')
    write(workerRepo, 'a.txt', 'dirty\n')
    for (const destination of [checkoutSystem, checkoutWorkerRestore, checkoutWorkerCheckout]) {
      copyRepository(workerRepo, destination)
    }
    const checkedOut = await workerGit(['checkout', '--', 'a.txt'], checkoutWorkerCheckout, env)
    assert.equal(checkedOut.code, 0, checkedOut.stderr.toString())
    expectSame(
      'checkout -- path',
      systemGit(['checkout', '--', 'a.txt'], checkoutSystem, env),
      checkedOut,
    )
    const restored = await workerGit(['restore', 'a.txt'], checkoutWorkerRestore, env)
    assert.equal(restored.code, 0, restored.stderr.toString())
    expectSame('restore path agrees with checkout -- path', restored, checkedOut)
    assert.equal(readFileSync(join(checkoutWorkerRestore, 'a.txt'), 'utf8'), 'one\n')
    assert.equal(readFileSync(join(checkoutWorkerCheckout, 'a.txt'), 'utf8'), 'one\n')
    expectSame(
      'checkout -- state',
      systemGit(['status', '--porcelain'], checkoutSystem, env),
      systemGit(['status', '--porcelain'], checkoutWorkerCheckout, env),
    )
    expectSame(
      'restore state',
      systemGit(['status', '--porcelain'], checkoutWorkerRestore, env),
      systemGit(['status', '--porcelain'], checkoutWorkerCheckout, env),
    )
  } finally {
    temp.cleanup()
  }
})
