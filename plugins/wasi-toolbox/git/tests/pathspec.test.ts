// SPDX-License-Identifier: MIT
/**
 * Golden tests for the pathspec glob and directory-only edge cases shared by
 * `ls-files`, `rev-list` and `diff`.
 *
 * The fixture deliberately contains a regular file named `dir` next to a real
 * directory `folder`. The system git is the oracle for every pattern: a
 * directory-only pathspec (`dir/`) must not select the same-named file, while
 * `folder/` still selects the files below the directory. Glob patterns are
 * compared byte-for-byte, including `?` on a UTF-8 name, descending ranges and
 * an unterminated bracket expression.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/pathspec.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync } from 'node:fs'
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

interface PathspecFixture {
  readonly repository: string
  readonly env: Record<string, string>
  readonly baseCommit: string
}

/** Commit single-byte, ASCII, CJK and file/directory-shaped names. */
function buildPathspecFixture(root: string): PathspecFixture {
  const environment = fixtureEnvironment(root)
  const repository = join(root, 'pathspec-fixture')
  mkdirSync(repository)
  mkdirSync(join(repository, 'folder'))
  mkdirSync(join(repository, 'd['))
  const env = environment.env
  const git = (args: readonly string[]): CommandResult => {
    const result = systemGit(args, repository, env)
    assert.equal(result.code, 0, `fixture git ${args.join(' ')}: ${result.stderr.toString()}`)
    return result
  }

  git(['init', '-q', '-b', 'main'])
  const files: readonly (readonly [string, string])[] = [
    ['a', 'a\n'],
    ['b', 'b\n'],
    ['c', 'c\n'],
    ['d', 'd\n'],
    ['z', 'z\n'],
    ['a.txt', 'a text\n'],
    ['ab.txt', 'ab text\n'],
    ['分支', 'cjk\n'],
    ['a[', 'literal open bracket\n'],
    ['[a]', 'literal bracket class\n'],
    ['a*', 'literal star\n'],
    ['dir', 'regular file named dir\n'],
    [join('d[', 'f.txt'), 'literal bracket directory\n'],
    [join('folder', 'keep.txt'), 'keep\n'],
  ]
  for (const [path, content] of files) writeFileSync(join(repository, path), content)
  git(['add', '-A'])
  git(['commit', '-qm', 'pathspec base'])
  const baseCommit = git(['rev-parse', 'HEAD']).stdout.toString().trim()

  // Work-tree edits give `diff` something to name for each matching path.
  for (const [path] of files) writeFileSync(join(repository, path), `${path} changed\n`)
  return { repository, env, baseCommit }
}

/** Null-delimited stdout as UTF-8 path strings. */
function paths(result: CommandResult): string[] {
  return result.stdout.toString('utf8').split('\0').filter(path => path !== '')
}

const GLOBS = [
  '?', '??', '??????', '[a-c]', '[!a]', '[^a]', '[z-a]', '[a-', '[a]', 'a\\*',
  '[[:alpha:]]', '[[:bogus:]]', '分支', '?支', '*支*',
] as const

const DIRECTORIES = [
  'dir', 'dir/', './dir/', 'dir//',
  'folder', 'folder/', './folder/', 'folder//',
] as const

test('pathspec globs match the system git byte-for-byte', { skip }, async t => {
  const temp = tempDirectory()
  try {
    const fixture = buildPathspecFixture(temp.path)
    const { repository, env } = fixture

    await t.test('ls-files selects glob matches by bytes', async () => {
      for (const pattern of GLOBS) {
        const args = ['ls-files', '-z', '--', pattern]
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      }
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', '?'], repository, env)), ['a', 'b', 'c', 'd', 'z'])
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', '[a-c]'], repository, env)), ['a', 'b', 'c'])
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', '[!a]'], repository, env)), ['b', 'c', 'd', 'z'])
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', '[z-a]'], repository, env)), ['z'])
      // `??` is two bytes, not two UTF-16 units: the six-byte CJK name needs
      // six question marks.
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', '??'], repository, env)), ['a*', 'a['])
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', '??????'], repository, env)), ['ab.txt', '分支'])
      const unterminated = await workerGit(['ls-files', '-z', '--', '[a-'], repository, env)
      assert.equal(unterminated.code, 0)
      assert.deepEqual(paths(unterminated), [])
      assert.equal(unterminated.stderr.byteLength, 0)
      expectSame(
        'literal open bracket path before glob parsing',
        systemGit(['ls-files', '-z', '--', 'a['], repository, env),
        await workerGit(['ls-files', '-z', '--', 'a['], repository, env),
      )
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', 'a['], repository, env)), ['a['])
      expectSame(
        'literal bracket name before class matching',
        systemGit(['ls-files', '-z', '--', '[a]'], repository, env),
        await workerGit(['ls-files', '-z', '--', '[a]'], repository, env),
      )
      expectSame(
        'escaped wildcard pathspec',
        systemGit(['ls-files', '-z', '--', 'a\\*'], repository, env),
        await workerGit(['ls-files', '-z', '--', 'a\\*'], repository, env),
      )
      expectSame(
        'directory-only literal bracket pathspec',
        systemGit(['ls-files', '-z', '--', 'd[/'], repository, env),
        await workerGit(['ls-files', '-z', '--', 'd[/'], repository, env),
      )
    })

    await t.test('rev-list applies the same byte glob to history', async () => {
      for (const pattern of GLOBS) {
        const args = ['rev-list', 'HEAD', '--', pattern]
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
        const counted = ['rev-list', '--count', 'HEAD', '--', pattern]
        expectSame(counted.join(' '), systemGit(counted, repository, env), await workerGit(counted, repository, env))
      }
      assert.equal(
        (await workerGit(['rev-list', '--count', 'HEAD', '--', '[a-c]'], repository, env)).stdout.toString(),
        '1\n',
      )
      assert.equal(
        (await workerGit(['rev-list', '--count', 'HEAD', '--', '[z-a]'], repository, env)).stdout.toString(),
        '1\n',
      )
      assert.equal(
        (await workerGit(['rev-list', '--count', 'HEAD', '--', '??'], repository, env)).stdout.toString(),
        '1\n',
      )
      assert.equal(
        (await workerGit(['rev-list', '--count', 'HEAD', '--', '[a-'], repository, env)).stdout.toString(),
        '0\n',
      )
    })

    await t.test('diff applies the same byte glob to changed paths', async () => {
      for (const pattern of GLOBS) {
        const args = ['diff', '--name-only', '-z', '--', pattern]
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      }
      assert.deepEqual(paths(await workerGit(['diff', '--name-only', '-z', '--', '[a-c]'], repository, env)), ['a', 'b', 'c'])
      assert.deepEqual(paths(await workerGit(['diff', '--name-only', '-z', '--', '[!a]'], repository, env)), ['b', 'c', 'd', 'z'])
      assert.deepEqual(paths(await workerGit(['diff', '--name-only', '-z', '--', '[z-a]'], repository, env)), ['z'])
      assert.deepEqual(paths(await workerGit(['diff', '--name-only', '-z', '--', '[a-'], repository, env)), [])
    })

    await t.test('directory-only pathspecs never select a same-named file', async () => {
      for (const pattern of DIRECTORIES) {
        const lsFiles = ['ls-files', '-z', '--', pattern]
        expectSame(lsFiles.join(' '), systemGit(lsFiles, repository, env), await workerGit(lsFiles, repository, env))
        const revList = ['rev-list', 'HEAD', '--', pattern]
        expectSame(revList.join(' '), systemGit(revList, repository, env), await workerGit(revList, repository, env))
        const diff = ['diff', '--name-only', '-z', '--', pattern]
        expectSame(diff.join(' '), systemGit(diff, repository, env), await workerGit(diff, repository, env))
      }
      for (const pattern of ['dir/', './dir/', 'dir//']) {
        assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', pattern], repository, env)), [])
        assert.equal((await workerGit(['rev-list', '--count', 'HEAD', '--', pattern], repository, env)).stdout.toString(), '0\n')
        assert.deepEqual(paths(await workerGit(['diff', '--name-only', '-z', '--', pattern], repository, env)), [])
      }
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', 'dir'], repository, env)), ['dir'])
      assert.deepEqual(
        paths(await workerGit(['ls-files', '-z', '--', 'folder/'], repository, env)),
        ['folder/keep.txt'],
      )
      assert.equal(
        (await workerGit(['rev-list', '--count', 'HEAD', '--', 'folder/'], repository, env)).stdout.toString(),
        '1\n',
      )
    })

    await t.test('exclude-only pathspecs start from every path except excludes', async () => {
      const excludeOnly = ':(exclude)a.txt'
      for (const args of [
        ['ls-files', '-z', '--', excludeOnly],
        ['status', '--porcelain', '-z', '--', excludeOnly],
        ['diff', '--name-only', '-z', '--', excludeOnly],
      ]) {
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      }

      for (const operation of ['add', 'restore'] as const) {
        const systemRepo = join(temp.path, `exclude-${operation}-system`)
        const workerRepo = join(temp.path, `exclude-${operation}-worker`)
        copyRepository(repository, systemRepo)
        copyRepository(repository, workerRepo)
        const args = operation === 'add'
          ? ['add', '-A', '--', excludeOnly]
          : ['restore', '--source=HEAD', '--worktree', '--', excludeOnly]
        expectSame(args.join(' '), systemGit(args, systemRepo, env), await workerGit(args, workerRepo, env))
        const statusArgs = ['status', '--porcelain', '-z']
        expectSame(
          `${operation} exclude-only resulting status`,
          systemGit(statusArgs, systemRepo, env),
          await workerGit(statusArgs, workerRepo, env),
        )
      }
    })

    await t.test('ls-tree rejects exclude magic like the system git', async () => {
      const args = ['ls-tree', '-r', '--name-only', 'HEAD', '--', ':(exclude)a.txt']
      expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      const result = await workerGit(args, repository, env)
      assert.equal(result.code, 128)
      assert.equal(result.stdout.byteLength, 0)
      assert.match(result.stderr.toString(), /pathspec magic not supported by this command: 'exclude'/)
    })

    await t.test('glob pathspec magic uses pathname-aware matching', async () => {
      for (const pattern of [':(glob)dir*', ':(glob)*', ':(glob)**', ':(glob)folder/*']) {
        const args = ['ls-files', '-z', '--', pattern]
        expectSame(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      }
      // `*` stops at `/`: only the root file named `dir` is selected, never
      // the contents of the `d[` directory. The recursive form still sees it.
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', ':(glob)dir*'], repository, env)), ['dir'])
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', ':(glob)*'], repository, env)).includes('folder/keep.txt'), false)
      assert.deepEqual(paths(await workerGit(['ls-files', '-z', '--', ':(glob)**/*'], repository, env)).includes('folder/keep.txt'), true)
    })

    await t.test('bare rev-list keeps the file/directory distinction', async () => {
      const bare = join(temp.path, 'pathspec-bare.git')
      const clone = systemGit(['clone', '-q', '--bare', repository, bare], temp.path, env)
      assert.equal(clone.code, 0, clone.stderr.toString())
      for (const pattern of DIRECTORIES) {
        const args = ['rev-list', 'HEAD', '--', pattern]
        expectSame(args.join(' '), systemGit(args, bare, env), await workerGit(args, bare, env))
        const counted = ['rev-list', '--count', 'HEAD', '--', pattern]
        expectSame(counted.join(' '), systemGit(counted, bare, env), await workerGit(counted, bare, env))
      }
      for (const pattern of ['dir/', './dir/', 'dir//']) {
        const result = await workerGit(['rev-list', '--count', 'HEAD', '--', pattern], bare, env)
        assert.equal(result.code, 0)
        assert.equal(result.stdout.toString(), '0\n')
        assert.equal(result.stderr.byteLength, 0)
      }
      assert.equal(
        (await workerGit(['rev-list', '--count', 'HEAD', '--', 'folder/'], bare, env)).stdout.toString(),
        '1\n',
      )
    })
  } finally {
    temp.cleanup()
  }
})
