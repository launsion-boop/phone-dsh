// SPDX-License-Identifier: MIT
/**
 * `git config --list` is the first command a diagnostic reaches for. The
 * Worker git used to answer 129 "only get and set", which made every
 * "what is this checkout configured with?" question fail before it started.
 *
 * The list is compared byte-for-byte with the system git for the same
 * isolated repository (fixed HOME, no system/global configuration), and the
 * flags that genuinely cannot be honoured still fail loudly.
 */
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, fixtureEnvironment, systemGit, tempDirectory, workerGit,
} from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

test('git config --list matches the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    const git = (args: readonly string[]): ReturnType<typeof systemGit> =>
      systemGit(args, repository, environment.env)
    git(['init', '-q', '-b', 'main'])
    writeFileSync(join(repository, 'a.txt'), 'alpha\n')

    assert.equal((await workerGit(['config', 'user.name', 'Worker Author'], repository, environment.env)).code, 0)
    assert.equal((await workerGit(['config', 'user.email', 'worker@localhost'], repository, environment.env)).code, 0)
    assert.equal((await workerGit(['config', 'remote.origin.url', 'https://example.test/repository.git'], repository, environment.env)).code, 0)

    const expected = git(['config', '--list'])
    assert.equal(expected.code, 0)
    // `systemGit` adds `-c gc.auto=0 -c maintenance.auto=0` to every call, so
    // the oracle also lists those command-scope overrides. They are the test
    // harness, not repository configuration; drop exactly those two lines.
    const expectedText = expected.stdout.toString()
      .split('\n')
      .filter(line => line !== 'gc.auto=0' && line !== 'maintenance.auto=0')
      .join('\n')
    const actual = await workerGit(['config', '--list'], repository, environment.env)
    assert.equal(actual.code, 0, actual.stderr.toString())
    assert.equal(actual.stderr.byteLength, 0)
    assert.equal(actual.stdout.toString(), expectedText)

    // `-l` is the documented short form; `--local --list` reads the same file
    // in a repository (the home/global layer is empty here).
    const short = await workerGit(['config', '-l'], repository, environment.env)
    assert.equal(short.stdout.toString(), expectedText)
    const local = await workerGit(['config', '--local', '--list'], repository, environment.env)
    assert.equal(local.stdout.toString(), expectedText)
    assert.match(local.stdout.toString(), /^user\.name=Worker Author$/m)
  } finally {
    temp.cleanup()
  }
})

test('git config --list outside a repository lists the home config, not an error', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    writeFileSync(join(environment.home, '.gitconfig'), '[user]\n\tname = Home Author\n')
    const outside = join(temp.path, 'not-a-repo')
    mkdirSync(outside)
    const actual = await workerGit(['config', '--list'], outside, environment.env)
    assert.equal(actual.code, 0, actual.stderr.toString())
    assert.equal(actual.stdout.toString(), 'user.name=Home Author\n')

    // --local keeps the truthful failure: there is no repository file.
    const local = await workerGit(['config', '--local', '--list'], outside, environment.env)
    assert.notEqual(local.code, 0)
    assert.match(local.stderr.toString(), /not a git repository|--local can only be used inside a git repository/)
  } finally {
    temp.cleanup()
  }
})

test('git config list keeps display modifiers loud', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = join(temp.path, 'repo')
    mkdirSync(repository)
    systemGit(['init', '-q', '-b', 'main'], repository, environment.env)

    for (const args of [
      ['config', '--list', '--show-origin'],
      ['config', '--list', '--show-scope'],
      ['config', '--list', '--name-only'],
      ['config', '--list', 'user.name'],
    ] as const) {
      const result = await workerGit(args, repository, environment.env)
      assert.notEqual(result.code, 0, `${args.join(' ')}: exits non-zero`)
      assert.equal(result.stdout.byteLength, 0, `${args.join(' ')}: writes no partial list`)
      assert.match(result.stderr.toString(), /unsupported|takes no name/, `${args.join(' ')}: names the refusal`)
    }
    // --global still cannot be honoured.
    const global = await workerGit(['config', '--global', '--list'], repository, environment.env)
    assert.notEqual(global.code, 0)
    assert.match(global.stderr.toString(), /unsupported/)
  } finally {
    temp.cleanup()
  }
})
