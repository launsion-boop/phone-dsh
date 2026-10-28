// SPDX-License-Identifier: MIT
/**
 * `git tag` golden tests.
 *
 * Fixtures are produced by the system git with an isolated HOME and fixed
 * identities and dates; every vector compares exit status, stdout bytes and
 * stderr bytes. Creation vectors also read the Worker's tag object back with
 * the system git and compare it with the object the system git itself wrote.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/tag.test
 */
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
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

/**
 * Known wording changes in newer git's parse-options diagnostics.
 *
 * Git 2.50 rewords the `-n` value and the list/delete incompatibility lines.
 * The Worker keeps git 2.39's stable wording; only these exact system lines
 * are mapped back, so code 129, empty stdout, both option names and every
 * other stderr byte still have to match exactly.
 */
const MODERN_TAG_DIAGNOSTICS: readonly (readonly [RegExp, string])[] = [
  [
    /^error: switch `n' expects an integer value with an optional k\/m\/g suffix\n$/,
    "error: switch `n' expects a numerical value\n",
  ],
  [
    /^error: options '-l' and '-d' cannot be used together\n$/,
    "error: switch `l' is incompatible with --delete\n",
  ],
  [
    /^error: options '-d' and '-l' cannot be used together\n$/,
    "error: switch `d' is incompatible with --list\n",
  ],
  [
    /^error: options '--list' and '--delete' cannot be used together\n$/,
    "error: option `list' is incompatible with --delete\n",
  ],
  [
    /^error: options '--delete' and '--list' cannot be used together\n$/,
    "error: option `delete' is incompatible with --list\n",
  ],
]

function canonicalTagDiagnostic(stderr: string): string {
  for (const [pattern, canonical] of MODERN_TAG_DIAGNOSTICS) {
    if (pattern.test(stderr)) return canonical
  }
  return stderr
}

/** Compare a known usage failure after narrowing only documented wording. */
function expectTagFailure(label: string, expected: CommandResult, actual: CommandResult): void {
  assert.equal(actual.code, expected.code, `${label}: exit status`)
  assert.equal(actual.code, 129, `${label}: usage failure`)
  assert.equal(Buffer.compare(actual.stdout, expected.stdout), 0, `${label}: stdout bytes`)
  assert.equal(
    actual.stderr.toString(),
    canonicalTagDiagnostic(expected.stderr.toString()),
    `${label}: stderr bytes`,
  )
}

/** A repository with committed files, made only by the system git. */
function committedRepository(root: string, env: Record<string, string>, commits = 2): string {
  const repository = join(root, 'repo')
  mkdirSync(repository)
  const git = (args: readonly string[]): CommandResult => systemGit(args, repository, env)
  git(['init', '-q', '-b', 'main'])
  for (let index = 1; index <= commits; index += 1) {
    writeFileSync(join(repository, 'a.txt'), `revision ${index}\n`)
    git(['add', '-A'])
    git(['commit', '-qm', `commit ${index}`])
  }
  return repository
}

/** The tag object bytes a system git reads from a repository. */
function tagObject(repository: string, name: string, env: Record<string, string>): CommandResult {
  return systemGit(['cat-file', 'tag', `refs/tags/${name}`], repository, env)
}

/** The tag ref the system git resolves in a repository. */
function tagOid(repository: string, name: string, env: Record<string, string>): string {
  const result = systemGit(['rev-parse', `refs/tags/${name}`], repository, env)
  assert.equal(result.code, 0, result.stderr.toString())
  return result.stdout.toString().trim()
}

test('tag list, -l, --list, -n and -n<num> match the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const repository = committedRepository(temp.path, env)
    const git = (args: readonly string[]): CommandResult => systemGit(args, repository, env)
    for (const tag of ['v1', 'v1.2', 'v1.10', 'alpha', 'a-very-long-tag-name-exceeding-15', 'release/v1']) {
      assert.equal(git(['tag', tag]).code, 0)
    }
    assert.equal(git(['tag', '-a', '-m', 'annotated subject', '-m', 'annotated body line', 'ann']).code, 0)
    for (const args of [
      ['tag'],
      ['tag', '-l'],
      ['tag', '-l', 'v*'],
      ['tag', '--list', 'v*'],
      ['tag', '-l', 'release/*'],
      ['tag', '-l', '[av]*'],
      ['tag', '-n'],
      ['tag', '-n1'],
      ['tag', '-n2'],
      ['tag', '-n3'],
      ['tag', '-n', 'ann'],
      ['tag', '-n2', 'v*'],
      ['tag', '-n0'],
    ]) {
      expectSame(args.join(' '), git(args), await workerGit(args, repository, env))
    }
  } finally {
    temp.cleanup()
  }
})

test('lightweight tag creation matches the system git and is readable by it', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = committedRepository(temp.path, env)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    const worker = async (args: readonly string[]): Promise<CommandResult> => await workerGit(args, workerRepo, env)
    for (const args of [
      ['tag', 'light', 'HEAD^'],
      ['tag', 'default'],
      ['tag', 'release/v1'],
    ]) {
      expectSame(args.join(' '), system(args), await worker(args))
      const name = args[1] as string
      assert.equal(tagOid(workerRepo, name, env), tagOid(systemRepo, name, env), `${name} ref target`)
    }
    expectSame('tag list after creation', system(['tag']), await worker(['tag']))
    expectSame('show-ref after creation', system(['show-ref', '--tags']), systemGit(['show-ref', '--tags'], workerRepo, env))
    assert.equal(existsSync(join(workerRepo, '.git', 'logs', 'refs', 'tags')), false, 'tag creation writes no reflog')
    assert.equal(systemGit(['fsck', '--strict'], workerRepo, env).code, 0)
  } finally {
    temp.cleanup()
  }
})

test('annotated tag object is byte-identical to the system git tag object', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = committedRepository(temp.path, env)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    const worker = async (args: readonly string[]): Promise<CommandResult> => await workerGit(args, workerRepo, env)
    for (const args of [
      ['tag', '-a', '-m', 'annotated subject', '-m', 'annotated body line', 'ann'],
      ['tag', '-m', 'message only', 'implied'],
      ['tag', '-am', 'combined message', 'combined'],
    ]) {
      expectSame(args.join(' '), system(args), await worker(args))
      const name = args[args.length - 1] as string
      assert.equal(tagOid(workerRepo, name, env), tagOid(systemRepo, name, env), `${name} tag object id`)
      expectSame(`${name} tag object`, tagObject(systemRepo, name, env), tagObject(workerRepo, name, env))
      assert.equal(systemGit(['cat-file', '-t', `refs/tags/${name}`], workerRepo, env).stdout.toString(), 'tag\n')
    }
    expectSame('tag -n after creation', system(['tag', '-n3']), await worker(['tag', '-n3']))
    assert.equal(existsSync(join(workerRepo, '.git', 'logs', 'refs', 'tags')), false, 'tag creation writes no reflog')
    assert.equal(systemGit(['fsck', '--strict'], workerRepo, env).code, 0)
  } finally {
    temp.cleanup()
  }
})

test('force retagging and duplicate names match the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = committedRepository(temp.path, env)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    const worker = async (args: readonly string[]): Promise<CommandResult> => await workerGit(args, workerRepo, env)
    for (const repository of [systemRepo, workerRepo]) {
      assert.equal(systemGit(['tag', 'old', 'HEAD^'], repository, env).code, 0)
      assert.equal(systemGit(['tag', '-a', '-m', 'old annotation', 'ann', 'HEAD^'], repository, env).code, 0)
    }
    for (const args of [
      ['tag', '-f', 'old', 'HEAD'],
      ['tag', '-f', 'old', 'HEAD'],
      ['tag', '-f', '-a', '-m', 'new annotation', 'ann', 'HEAD'],
      ['tag', 'old'],
      ['tag', 'v1', 'nope'],
      ['tag', 'old', 'HEAD', 'HEAD^'],
    ]) {
      expectSame(args.join(' '), system(args), await worker(args))
    }
    expectSame('refs after force', system(['show-ref', '--tags']), systemGit(['show-ref', '--tags'], workerRepo, env))
    expectSame('annotated object after force', tagObject(systemRepo, 'ann', env), tagObject(workerRepo, 'ann', env))
  } finally {
    temp.cleanup()
  }
})

test('tag deletion removes loose refs and matches the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = committedRepository(temp.path, env)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      assert.equal(systemGit(['tag', 'v1', 'HEAD^'], repository, env).code, 0)
      assert.equal(systemGit(['tag', 'v2', 'HEAD'], repository, env).code, 0)
      assert.equal(systemGit(['tag', '-a', '-m', 'annotation', 'ann', 'HEAD'], repository, env).code, 0)
      assert.equal(systemGit(['tag', 'keep', 'HEAD'], repository, env).code, 0)
    }
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    const worker = async (args: readonly string[]): Promise<CommandResult> => await workerGit(args, workerRepo, env)
    for (const args of [
      ['tag', '-d', 'v1'],
      ['tag', '-d', 'v2', 'ann'],
      ['tag', '-d', 'nope'],
    ]) {
      expectSame(args.join(' '), system(args), await worker(args))
    }
    expectSame('tag list after deletion', system(['tag']), await worker(['tag']))
    expectSame('show-ref after deletion', system(['show-ref', '--tags']), systemGit(['show-ref', '--tags'], workerRepo, env))
    assert.equal(existsSync(join(workerRepo, '.git', 'refs', 'tags', 'v1')), false)
    assert.equal(existsSync(join(workerRepo, '.git', 'refs', 'tags', 'ann')), false)
  } finally {
    temp.cleanup()
  }
})

test('tag deletion clears packed-refs entries and keeps the remaining ones byte-identical', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = committedRepository(temp.path, env)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      assert.equal(systemGit(['tag', 'v1', 'HEAD^'], repository, env).code, 0)
      assert.equal(systemGit(['tag', '-a', '-m', 'annotation', 'ann', 'HEAD^'], repository, env).code, 0)
      assert.equal(systemGit(['tag', 'keep', 'HEAD'], repository, env).code, 0)
      assert.equal(systemGit(['pack-refs', '--all', '--prune'], repository, env).code, 0)
      assert.equal(existsSync(join(repository, '.git', 'refs', 'tags', 'v1')), false, 'fixture is packed')
      assert.match(readFileSync(join(repository, '.git', 'packed-refs'), 'utf8'), /refs\/tags\/v1$/m)
    }
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    const worker = async (args: readonly string[]): Promise<CommandResult> => await workerGit(args, workerRepo, env)
    for (const args of [
      ['tag', '-d', 'v1'],
      ['tag', '-d', 'ann'],
    ]) {
      expectSame(args.join(' '), system(args), await worker(args))
      const expectedPacked = readFileSync(join(systemRepo, '.git', 'packed-refs'))
      const actualPacked = readFileSync(join(workerRepo, '.git', 'packed-refs'))
      assert.equal(actualPacked.toString(), expectedPacked.toString(), `${args.join(' ')} packed-refs bytes`)
      assert.doesNotMatch(actualPacked.toString(), new RegExp(`refs/tags/${args[2]}$`, 'm'))
    }
    expectSame('packed tag list after deletion', system(['tag']), await worker(['tag']))
    expectSame('packed show-ref after deletion', system(['show-ref', '--tags']), systemGit(['show-ref', '--tags'], workerRepo, env))
  } finally {
    temp.cleanup()
  }
})

test('missing annotated message fails loud without creating a ref', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = committedRepository(temp.path, environment.env)
    const before = systemGit(['tag'], repository, environment.env).stdout.toString()
    const result = await workerGit(['tag', '-a', 'needs-message'], repository, environment.env)
    assert.equal(result.code, 129, 'the Worker has no editor, so this is a usage failure')
    assert.match(result.stderr.toString(), /-m/)
    assert.equal(result.stdout.byteLength, 0)
    assert.equal(systemGit(['tag'], repository, environment.env).stdout.toString(), before)
    assert.equal(existsSync(join(repository, '.git', 'refs', 'tags', 'needs-message')), false)
  } finally {
    temp.cleanup()
  }
})

test('invalid and unsupported options fail loud', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = committedRepository(temp.path, environment.env)
    // `-n` expects a number; git answers with this line and 129. Newer git
    // only rewrites the wording, which `expectTagFailure` narrows.
    expectTagFailure(
      'tag -nfoo',
      systemGit(['tag', '-nfoo'], repository, environment.env),
      await workerGit(['tag', '-nfoo'], repository, environment.env),
    )
    for (const args of [
      ['tag', '.bad'],
      ['tag', 'a..b'],
      ['tag', 'bad name'],
      ['tag', 'bad/'],
      ['tag', '-a', '-m', 'x', 'bad name'],
    ]) {
      expectSame(args.join(' '), systemGit(args, repository, environment.env), await workerGit(args, repository, environment.env))
    }
    for (const args of [['tag', '--bogus'], ['tag', '-Z']]) {
      const expected = systemGit(args, repository, environment.env)
      const actual = await workerGit(args, repository, environment.env)
      assert.equal(actual.code, expected.code, `${args.join(' ')} exit`)
      assert.equal(actual.code, 129)
      assert.equal(actual.stdout.byteLength, 0)
      assert.match(actual.stderr.toString(), new RegExp(args[1] as string))
    }
  } finally {
    temp.cleanup()
  }
})

test('tag accepts @ and rejects option-shaped names after --', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = committedRepository(temp.path, env)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    const worker = async (args: readonly string[]): Promise<CommandResult> => await workerGit(args, workerRepo, env)

    // `@` is a legal one-level refname; `git tag @` is an ordinary tag.
    expectSame('tag @', system(['tag', '@']), await worker(['tag', '@']))
    assert.equal(tagOid(workerRepo, '@', env), tagOid(systemRepo, '@', env))
    expectSame('tag -l @', system(['tag', '-l', '@']), await worker(['tag', '-l', '@']))
    expectSame('tag -d @', system(['tag', '-d', '@']), await worker(['tag', '-d', '@']))

    // A leading dash is still rejected for creation, even behind `--`.
    const expected = system(['tag', '--', '-foo'])
    const actual = await worker(['tag', '--', '-foo'])
    expectSame('tag -- -foo', expected, actual)
    assert.equal(actual.code, 128)
    assert.equal(systemGit(['tag', '-l', '-foo'], workerRepo, env).stdout.byteLength, 0)
  } finally {
    temp.cleanup()
  }
})

test('tag globs match ref-name bytes like the system wildmatch', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = committedRepository(temp.path, env)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      for (const name of ['@', 'one', 'z', 'zz', '分支', 'a-b', 'b']) {
        assert.equal(systemGit(['tag', name], repository, env).code, 0)
      }
    }
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    const worker = async (args: readonly string[]): Promise<CommandResult> => await workerGit(args, workerRepo, env)
    for (const pattern of [
      '?', '??', '???', 'a?', 'a?b', '[!a]', '[^a]', '[a-c]', '[z-a]', '分*',
      '[]', '[]]', '[!]]', '[a-', '[[:alpha:]]', '[[:digit:]]', '[[:bogus:]]', '[[:alpha:]',
    ]) {
      expectSame(`tag -l ${pattern}`, system(['tag', '-l', pattern]), await worker(['tag', '-l', pattern]))
    }
    // `?` is one UTF-8 byte: two question marks select `zz`, never the
    // six-byte CJK name. The old RegExp translation matched UTF-16 units.
    assert.equal((await worker(['tag', '-l', '??'])).stdout.toString(), 'zz\n')
    assert.doesNotMatch((await worker(['tag', '-l', '??'])).stdout.toString(), /分支/)

    // A descending range follows git's wildmatch instead of throwing a raw
    // SyntaxError: the range test never succeeds, so the first endpoint still
    // matches and later bytes in the reverse range do not.
    const descending = await worker(['tag', '-l', '[z-a]'])
    assert.equal(descending.code, 0)
    assert.equal(descending.stdout.toString(), 'z\n')
    assert.equal(descending.stderr.byteLength, 0)
    assert.doesNotMatch(descending.stderr.toString(), /SyntaxError/)
  } finally {
    temp.cleanup()
  }
})

test('tag outside a repository fails like the other commands', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    for (const args of [['tag'], ['tag', '-l'], ['tag', 'v1']]) {
      const result = await workerGit(args, temp.path, environment.env)
      assert.equal(result.code, 128, `${args.join(' ')} exit`)
      assert.match(result.stderr.toString(), /^fatal: not a git repository/)
      assert.equal(result.stdout.byteLength, 0)
    }
  } finally {
    temp.cleanup()
  }
})

test('tag deletion treats refname traversal as not found and never touches other refs', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    for (const [index, name] of ['../../HEAD', '../heads/main'].entries()) {
      const root = join(temp.path, `traversal-${index}`)
      mkdirSync(root)
      const systemRepo = committedRepository(root, env, 1)
      const workerRepo = join(root, 'worker')
      copyRepository(systemRepo, workerRepo)
      for (const repository of [systemRepo, workerRepo]) {
        assert.equal(systemGit(['branch', 'victim'], repository, env).code, 0)
        assert.equal(systemGit(['tag', 'keep'], repository, env).code, 0)
      }
      expectSame(
        `tag -d ${name}`,
        systemGit(['tag', '-d', name], systemRepo, env),
        await workerGit(['tag', '-d', name], workerRepo, env),
      )
      assert.equal(
        readFileSync(join(workerRepo, '.git', 'HEAD'), 'utf8'),
        readFileSync(join(systemRepo, '.git', 'HEAD'), 'utf8'),
        'HEAD is untouched',
      )
      expectSame(
        `refs after tag -d ${name}`,
        systemGit(['show-ref'], systemRepo, env),
        systemGit(['show-ref'], workerRepo, env),
      )
      expectSame(`tags after tag -d ${name}`, systemGit(['tag'], systemRepo, env), systemGit(['tag'], workerRepo, env))
      assert.equal(systemGit(['rev-parse', '--verify', 'refs/heads/main'], workerRepo, env).code, 0)
    }
  } finally {
    temp.cleanup()
  }
})

test('list and delete options are incompatible like the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const repository = committedRepository(temp.path, env)
    for (const tag of ['zz', 'v1']) assert.equal(systemGit(['tag', tag], repository, env).code, 0)
    for (const args of [
      ['tag', '-d', '-l', 'zz'],
      ['tag', '-l', '-d', 'zz'],
      ['tag', '-dl', 'zz'],
      ['tag', '-ld', 'zz'],
      ['tag', '--delete', '--list', 'zz'],
      ['tag', '--list', '--delete', 'zz'],
    ]) {
      expectTagFailure(args.join(' '), systemGit(args, repository, env), await workerGit(args, repository, env))
      expectSame(`${args.join(' ')} leaves tags`, systemGit(['tag'], repository, env), await workerGit(['tag'], repository, env))
      assert.equal(systemGit(['tag', '-l', 'zz'], repository, env).stdout.toString(), 'zz\n', 'zz was not deleted')
    }
  } finally {
    temp.cleanup()
  }
})

test('deleting a nested tag removes its empty namespace so the parent name can be reused', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const env = environment.env
    const systemRepo = committedRepository(temp.path, env, 1)
    const workerRepo = join(temp.path, 'worker')
    copyRepository(systemRepo, workerRepo)
    for (const repository of [systemRepo, workerRepo]) {
      assert.equal(systemGit(['tag', 'release/v1'], repository, env).code, 0)
    }
    const system = (args: readonly string[]): CommandResult => systemGit(args, systemRepo, env)
    const worker = async (args: readonly string[]): Promise<CommandResult> => await workerGit(args, workerRepo, env)
    expectSame('delete nested tag', system(['tag', '-d', 'release/v1']), await worker(['tag', '-d', 'release/v1']))
    assert.equal(
      existsSync(join(workerRepo, '.git', 'refs', 'tags', 'release')),
      false,
      'the empty release/ namespace is removed, as the system git does',
    )
    expectSame('create the parent tag after deletion', system(['tag', 'release']), await worker(['tag', 'release']))
    expectSame('list after parent tag creation', system(['tag']), await worker(['tag']))
    assert.equal(tagOid(workerRepo, 'release', env), tagOid(systemRepo, 'release', env), 'parent tag ref target')
    assert.equal(systemGit(['fsck', '--strict'], workerRepo, env).code, 0)
  } finally {
    temp.cleanup()
  }
})
