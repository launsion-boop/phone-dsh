// SPDX-License-Identifier: MIT
/**
 * Golden tests for the eight subcommands DSH's `workspace-changes` plugin runs.
 *
 * Every expectation is captured from the system git on a fixture repository it
 * built itself, then compared byte-for-byte against the Worker git: same exit
 * status, same stdout bytes (NUL-delimited records included) and same stderr.
 * The repository is exercised twice, once with loose objects and once after
 * `git gc --aggressive` has packed and deltified everything, because a phone
 * workspace usually starts from a clone.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/golden.test
 */
import assert from 'node:assert/strict'
import { copyFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, buildFixture, copyRepository, diffResults, systemGit, tempDirectory, workerGit,
} from './helpers.ts'
import type { CommandResult, Fixture } from './helpers.ts'

function expectSame(label: string, expected: CommandResult, actual: CommandResult): void {
  const difference = diffResults(expected, actual)
  assert.equal(difference, undefined, `${label}: ${difference}`)
}

/** Resolve one object id with the system git. */
function oid(fixture: Fixture, expression: string): string {
  const result = systemGit(['rev-parse', expression], fixture.repository, fixture.environment.env)
  assert.equal(result.code, 0, result.stderr.toString())
  return result.stdout.toString().trim()
}

const skip = HAS_GIT ? false : SKIP_NO_GIT

test('the eight workspace-changes subcommands match the system git', { skip }, async t => {
  const temp = tempDirectory()
  try {
    const fixture = await buildFixture(temp.path)
    const env = fixture.environment.env
    const root = fixture.repository
    const subdir = join(root, 'sub')

    await t.test('rev-parse', async () => {
      for (const cwd of [root, subdir]) {
        const args = ['rev-parse', '--show-toplevel', '--absolute-git-dir', '--git-path', 'objects']
        expectSame(`rev-parse in ${cwd}`, systemGit(args, cwd, env), await workerGit(args, cwd, env))
      }
      const inside = ['rev-parse', '--is-inside-work-tree', '--is-bare-repository', '--is-inside-git-dir']
      expectSame('rev-parse flags', systemGit(inside, root, env), await workerGit(inside, root, env))
      const prefix = ['rev-parse', '--show-prefix', '--show-cdup']
      expectSame('rev-parse prefix', systemGit(prefix, subdir, env), await workerGit(prefix, subdir, env))
      expectSame('rev-parse verify', systemGit(['rev-parse', '--verify', 'HEAD'], root, env), await workerGit(['rev-parse', '--verify', 'HEAD'], root, env))
      expectSame('rev-parse verify missing', systemGit(['rev-parse', '--verify', '-q', 'missing'], root, env), await workerGit(['rev-parse', '--verify', '-q', 'missing'], root, env))
      expectSame('rev-parse short', systemGit(['rev-parse', '--short', 'HEAD'], root, env), await workerGit(['rev-parse', '--short', 'HEAD'], root, env))
      expectSame('rev-parse abbrev-ref', systemGit(['rev-parse', '--abbrev-ref', 'HEAD'], root, env), await workerGit(['rev-parse', '--abbrev-ref', 'HEAD'], root, env))
    })

    await t.test('add --all and write-tree through the snapshot environment', async () => {
      const systemCopy = join(temp.path, 'add-system')
      const workerCopy = join(temp.path, 'add-worker')
      copyRepository(root, systemCopy)
      copyRepository(root, workerCopy)
      const systemObjects = join(temp.path, 'objects-system')
      const workerObjects = join(temp.path, 'objects-worker')
      mkdirSync(systemObjects)
      mkdirSync(workerObjects)
      const systemIndex = join(temp.path, 'index-system')
      const workerIndex = join(temp.path, 'index-worker')
      copyFileSync(join(systemCopy, '.git', 'index'), systemIndex)
      copyFileSync(join(workerCopy, '.git', 'index'), workerIndex)
      const snapshotEnv = (objects: string, index: string): Record<string, string> => ({
        ...env,
        GIT_OBJECT_DIRECTORY: objects,
        GIT_ALTERNATE_OBJECT_DIRECTORIES: join(systemCopy, '.git', 'objects'),
        GIT_INDEX_FILE: index,
      })
      const systemEnv = snapshotEnv(systemObjects, systemIndex)
      const workerEnv = snapshotEnv(workerObjects, workerIndex)
      const addArgs = ['add', '--all', '--ignore-errors', '--', '.', ':(exclude)priv']
      const expectedAdd = systemGit(addArgs, systemCopy, systemEnv)
      const actualAdd = await workerGit(addArgs, workerCopy, workerEnv)
      if (expectedAdd.code === 1) {
        assert.equal(actualAdd.code, 1, 'git add accepted unreadable files but reported exit 1')
      } else {
        expectSame('add --all', expectedAdd, actualAdd)
      }
      expectSame(
        'write-tree after add',
        systemGit(['write-tree'], systemCopy, systemEnv),
        await workerGit(['write-tree'], workerCopy, workerEnv),
      )
      // The private index this implementation wrote must be readable by the
      // system git, because DSH copies and re-reads it on every snapshot.
      expectSame(
        'system git reads the Worker index',
        systemGit(['ls-files', '-z', '--stage'], systemCopy, systemEnv),
        systemGit(['ls-files', '-z', '--stage'], workerCopy, workerEnv),
      )
      assert.equal(
        systemGit(['status', '--porcelain'], workerCopy, { ...env, GIT_INDEX_FILE: workerIndex }).stdout.toString(),
        '',
        'the work tree is clean after add --all',
      )
    })

    await t.test('ls-tree', async () => {
      const tree = fixture.baseTree
      const blob = oid(fixture, 'HEAD~1:a.txt')
      for (const args of [
        ['ls-tree', '-z', '-l', tree, '--', 'a.txt'],
        ['ls-tree', '-z', '-l', tree, '--', 'sub'],
        ['ls-tree', '-z', '-l', tree, '--', 'missing.txt'],
        ['ls-tree', '-z', '-l', '-r', '-t', tree],
        ['ls-tree', '-z', '-l', tree, '--', 'exec.sh'],
        ['ls-tree', '-l', tree],
        ['ls-tree', '-z', '-l', tree, '--', 'bin.dat'],
      ]) {
        expectSame(args.join(' '), systemGit(args, root, env), await workerGit(args, root, env))
      }
      expectSame('ls-tree blob path', systemGit(['ls-tree', '-z', '-l', tree, '--', 'a.txt'], root, env), await workerGit(['ls-tree', '-z', '-l', tree, '--', 'a.txt'], root, env))
      assert.equal(blob.length, 40)
    })

    await t.test('cat-file', async () => {
      const blob = oid(fixture, 'HEAD~1:a.txt')
      for (const args of [
        ['cat-file', 'blob', blob],
        ['cat-file', '-t', blob],
        ['cat-file', '-s', blob],
        ['cat-file', '-p', fixture.baseTree],
        ['cat-file', 'blob', fixture.baseTree],
        ['cat-file', 'blob', '0000000000000000000000000000000000000000'],
      ]) {
        expectSame(args.join(' '), systemGit(args, root, env), await workerGit(args, root, env))
      }
    })

    await t.test('diff-tree --numstat', async () => {
      const args = ['diff-tree', '-r', '-M', '-z', '--numstat', fixture.baseTree, fixture.changedTree]
      expectSame('diff-tree numstat', systemGit(args, root, env), await workerGit(args, root, env))
      const nameStatus = ['diff-tree', '-r', '-M', '--name-status', fixture.baseTree, fixture.changedTree]
      expectSame('diff-tree name-status', systemGit(nameStatus, root, env), await workerGit(nameStatus, root, env))
      const same = ['diff-tree', '-r', '-M', '-z', '--numstat', fixture.changedTree, fixture.changedTree]
      expectSame('diff-tree empty', systemGit(same, root, env), await workerGit(same, root, env))
    })

    await t.test('ls-files', async () => {
      for (const args of [
        ['ls-files', '-z', '--stage'],
        ['ls-files', '-z'],
      ]) {
        expectSame(args.join(' '), systemGit(args, root, env), await workerGit(args, root, env))
      }
    })

    await t.test('check-ignore -z --stdin', async () => {
      const input = Buffer.from('ignored.log\0build/out.bin\0a.txt\0nope.log\0sub/deep/x.log\0priv/p.txt\0', 'utf8')
      const args = ['check-ignore', '-z', '--stdin']
      expectSame('check-ignore', systemGit(args, root, env, input), await workerGit(args, root, env, input))
      const trackedOnly = Buffer.from('a.txt\0', 'utf8')
      expectSame('check-ignore tracked', systemGit(args, root, env, trackedOnly), await workerGit(args, root, env, trackedOnly))
    })

    await t.test('packed repository (gc --aggressive)', async () => {
      const packed = join(temp.path, 'packed')
      copyRepository(root, packed)
      const gc = systemGit(['gc', '--aggressive', '--prune=now'], packed, env)
      assert.equal(gc.code, 0, gc.stderr.toString())
      const blob = oid(fixture, 'HEAD:a.txt')
      const commands: string[][] = [
        ['rev-parse', '--show-toplevel', '--absolute-git-dir', '--git-path', 'objects'],
        ['ls-tree', '-z', '-l', fixture.baseTree, '--', 'a.txt'],
        ['ls-tree', '-z', '-l', fixture.baseTree, '--', 'sub'],
        ['cat-file', 'blob', blob],
        ['cat-file', '-t', fixture.baseCommit],
        ['diff-tree', '-r', '-M', '-z', '--numstat', fixture.baseTree, fixture.changedTree],
        ['ls-files', '-z', '--stage'],
        ['check-ignore', '-z', '--stdin'],
        ['log', '--oneline'],
        ['status', '--porcelain'],
      ]
      for (const args of commands) {
        const stdin = args[0] === 'check-ignore' ? Buffer.from('ignored.log\0a.txt\0', 'utf8') : undefined
        expectSame(`packed ${args.join(' ')}`, systemGit(args, packed, env, stdin), await workerGit(args, packed, env, stdin))
      }
      expectSame(
        'packed diff-tree name-status',
        systemGit(['diff-tree', '-r', '-M', '--name-status', fixture.baseTree, fixture.changedTree], packed, env),
        await workerGit(['diff-tree', '-r', '-M', '--name-status', fixture.baseTree, fixture.changedTree], packed, env),
      )
    })
  } finally {
    temp.cleanup()
  }
})
