// SPDX-License-Identifier: MIT
/**
 * Reflog tests: every ref change made by `commit`, `branch`, `switch` and
 * `checkout` must append the same bytes the system git writes under
 * `<git-dir>/logs`.
 *
 * The fixtures are built by the system git itself (with its own reflog), copied
 * into a system/worker pair, then both implementations run the same command
 * sequence. The test compares the complete `.git/logs` tree byte-for-byte and
 * asks the system `git reflog` to render the worker repository, so a malformed
 * line is caught even if two implementations happened to agree on it.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/reflog.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, copyRepository, fixtureEnvironment, systemGit, tempDirectory, workerGit,
} from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

/** One command in a paired sequence; `prepare` writes identical fixture input. */
interface Step {
  readonly args: readonly string[]
  readonly prepare?: (repository: string) => void
}

/** Two copies of one fixture that receive the same command sequence. */
interface Pair {
  readonly root: string
  readonly system: string
  readonly worker: string
  readonly env: Record<string, string>
}

/** Initialize a repository in `root` with the system git. */
function initRepository(root: string, env: Record<string, string>, name: string): string {
  const repository = join(root, name)
  mkdirSync(repository)
  const init = systemGit(['init', '-q', '-b', 'main'], repository, env)
  assert.equal(init.code, 0, init.stderr.toString())
  return repository
}

/** A repository with one commit, and therefore an existing reflog. */
function baseRepository(root: string, env: Record<string, string>, name: string): string {
  const repository = initRepository(root, env, name)
  writeFileSync(join(repository, 'a.txt'), 'alpha\n')
  assert.equal(systemGit(['add', '-A'], repository, env).code, 0)
  const commit = systemGit(['commit', '-qm', 'base commit'], repository, env)
  assert.equal(commit.code, 0, commit.stderr.toString())
  return repository
}

/** Copy one fixture twice, once for the system git and once for Worker git. */
function pairFrom(source: string, root: string, env: Record<string, string>, label: string): Pair {
  const system = join(root, `system-${label}`)
  const worker = join(root, `worker-${label}`)
  copyRepository(source, system)
  copyRepository(source, worker)
  return { root, system, worker, env }
}

/** Empty repository pair, for the initial-commit and enable/disable vectors. */
function emptyPair(
  root: string,
  env: Record<string, string>,
  label: string,
  configure?: readonly (readonly string[])[],
): Pair {
  const source = initRepository(root, env, `empty-${label}`)
  for (const args of configure ?? []) {
    const result = systemGit(args, source, env)
    assert.equal(result.code, 0, result.stderr.toString())
  }
  return pairFrom(source, root, env, label)
}

/** Read every file under a reflog root, keyed by its slash-relative path. */
function readLogTree(root: string): Map<string, Buffer> {
  const files = new Map<string, Buffer>()
  const walk = (directory: string, prefix: string): void => {
    let entries
    try {
      entries = readdirSync(directory, { withFileTypes: true })
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
      throw error
    }
    for (const entry of entries.sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)) {
      const relative = `${prefix}${entry.name}`
      if (entry.isDirectory()) walk(join(directory, entry.name), `${relative}/`)
      else if (entry.isFile()) files.set(relative, readFileSync(join(directory, entry.name)))
    }
  }
  walk(root, '')
  return files
}

/** Compare the complete logs tree of both copies, bytes included. */
function assertLogsEqual(pair: Pair, label: string): void {
  const expected = readLogTree(join(pair.system, '.git', 'logs'))
  const actual = readLogTree(join(pair.worker, '.git', 'logs'))
  assert.deepEqual(
    [...actual.keys()],
    [...expected.keys()],
    `${label}: the Worker wrote a different set of reflog files`,
  )
  for (const [file, expectedBytes] of expected) {
    const actualBytes = actual.get(file) as Buffer
    assert.equal(
      actualBytes.toString('utf8'),
      expectedBytes.toString('utf8'),
      `${label}: ${file} differs from the system git`,
    )
  }
}

/** Compare the refs both repositories carry, read by the system git. */
function assertRefsEqual(pair: Pair, label: string): void {
  const args = ['for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', 'refs/tags']
  const expected = systemGit(args, pair.system, pair.env)
  const actual = systemGit(args, pair.worker, pair.env)
  assert.equal(actual.code, expected.code, `${label}: for-each-ref exit status`)
  assert.equal(actual.stdout.toString(), expected.stdout.toString(), `${label}: refs differ`)
}

/** Let the system git parse the Worker reflog and compare its rendering. */
function assertReflogReadable(pair: Pair, label: string): void {
  const args = ['reflog', '--all', '--format=%H %gD %gs']
  const expected = systemGit(args, pair.system, pair.env)
  const actual = systemGit(args, pair.worker, pair.env)
  assert.equal(actual.code, expected.code, `${label}: git reflog exit status\n${actual.stderr.toString()}`)
  assert.equal(actual.stdout.toString(), expected.stdout.toString(), `${label}: git reflog output differs`)
}

/** Run one command sequence in both copies and compare the observable state. */
async function runPair(
  pair: Pair,
  label: string,
  steps: readonly Step[],
  options: { readonly bare?: boolean } = {},
): Promise<void> {
  for (const step of steps) {
    if (step.prepare !== undefined) {
      step.prepare(pair.system)
      step.prepare(pair.worker)
    }
    const expected = systemGit(step.args, pair.system, pair.env)
    const actual = await workerGit(step.args, pair.worker, pair.env)
    assert.equal(actual.code, expected.code, `${label}: git ${step.args.join(' ')} exit status\n${actual.stderr.toString()}`)
  }
  assertRefsEqual(pair, label)
  if (options.bare === true) {
    const expected = readLogTree(join(pair.system, 'logs'))
    const actual = readLogTree(join(pair.worker, 'logs'))
    assert.deepEqual([...actual.keys()], [...expected.keys()], `${label}: bare reflog file set`)
    for (const [file, bytes] of expected) {
      assert.equal((actual.get(file) as Buffer).toString(), bytes.toString(), `${label}: ${file}`)
    }
  } else {
    assertLogsEqual(pair, label)
    assertReflogReadable(pair, label)
  }
}

/** One HEAD reflog line, or undefined when the file does not exist. */
function headLog(pair: Pair, repository = pair.worker): string | undefined {
  try {
    return readFileSync(join(repository, '.git', 'logs', 'HEAD'), 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw error
  }
}

test('initial commit writes HEAD and branch reflogs', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const pair = emptyPair(temp.path, environment.env, 'initial')
    await runPair(pair, 'initial commit', [
      {
        args: ['add', '-A'],
        prepare: repository => writeFileSync(join(repository, 'a.txt'), 'alpha\n'),
      },
      { args: ['commit', '-m', 'initial commit'] },
    ])
    const log = headLog(pair) as string
    assert.match(log, /^0{40} [0-9a-f]{40} Fixture Author <fixture@localhost> 1700000000 \+0000\tcommit \(initial\): initial commit\n$/)
    assert.equal(readFileSync(join(pair.worker, '.git', 'logs', 'refs', 'heads', 'main'), 'utf8'), log)
  } finally {
    temp.cleanup()
  }
})

test('normal and amended commits append commit reflogs', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'commit-source')
    const normal = pairFrom(source, temp.path, environment.env, 'commit-normal')
    await runPair(normal, 'second commit', [
      { args: ['commit', '--allow-empty', '-m', 'second commit'] },
    ])
    assert.match(headLog(normal) as string, /\tcommit: second commit\n$/)

    const amended = pairFrom(source, temp.path, environment.env, 'commit-amend')
    await runPair(amended, 'amend', [
      { args: ['commit', '--allow-empty', '--amend', '-m', 'amended subject'] },
    ])
    assert.match(headLog(amended) as string, /\tcommit \(amend\): amended subject\n$/)

    const detached = pairFrom(source, temp.path, environment.env, 'commit-detached')
    await runPair(detached, 'detached commit', [
      { args: ['checkout', '--detach', 'main'] },
      { args: ['commit', '--allow-empty', '-m', 'detached commit'] },
    ])
    assert.match(headLog(detached) as string, /\tcommit: detached commit\n$/)
    assert.doesNotMatch(
      readFileSync(join(detached.worker, '.git', 'logs', 'refs', 'heads', 'main'), 'utf8'),
      /detached commit/,
      'a detached commit writes only the HEAD reflog',
    )
  } finally {
    temp.cleanup()
  }
})

test('branch creation records the start point, including a detached HEAD', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'branch-source')

    const plain = pairFrom(source, temp.path, environment.env, 'branch-plain')
    await runPair(plain, 'branch default', [{ args: ['branch', 'b'] }])
    assert.match(
      readFileSync(join(plain.worker, '.git', 'logs', 'refs', 'heads', 'b'), 'utf8'),
      /\tbranch: Created from main\n$/,
    )

    const explicit = pairFrom(source, temp.path, environment.env, 'branch-explicit')
    await runPair(explicit, 'branch explicit start', [{ args: ['branch', 'c', 'HEAD'] }])
    assert.match(
      readFileSync(join(explicit.worker, '.git', 'logs', 'refs', 'heads', 'c'), 'utf8'),
      /\tbranch: Created from HEAD\n$/,
    )

    const detached = pairFrom(source, temp.path, environment.env, 'branch-detached')
    await runPair(detached, 'branch from detached HEAD', [
      { args: ['checkout', '--detach', 'main'] },
      { args: ['branch', 'd'] },
    ])
    assert.match(
      readFileSync(join(detached.worker, '.git', 'logs', 'refs', 'heads', 'd'), 'utf8'),
      /\tbranch: Created from HEAD\n$/,
    )
  } finally {
    temp.cleanup()
  }
})

test('switch and checkout append checkout reflogs, including same-branch moves', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'switch-source')

    const switched = pairFrom(source, temp.path, environment.env, 'switch')
    await runPair(switched, 'switch', [{ args: ['branch', 'side'] }, { args: ['switch', 'side'] }])
    assert.match(headLog(switched) as string, /\tcheckout: moving from main to side\n$/)

    const created = pairFrom(source, temp.path, environment.env, 'switch-create')
    await runPair(created, 'switch -c', [{ args: ['switch', '-c', 'newb'] }])
    assert.match(
      readFileSync(join(created.worker, '.git', 'logs', 'refs', 'heads', 'newb'), 'utf8'),
      /\tbranch: Created from HEAD\n$/,
    )
    assert.match(headLog(created) as string, /\tcheckout: moving from main to newb\n$/)

    const checkedOut = pairFrom(source, temp.path, environment.env, 'checkout')
    await runPair(checkedOut, 'checkout', [{ args: ['branch', 'side'] }, { args: ['checkout', 'side'] }])
    assert.match(headLog(checkedOut) as string, /\tcheckout: moving from main to side\n$/)

    const checkoutCreate = pairFrom(source, temp.path, environment.env, 'checkout-create')
    await runPair(checkoutCreate, 'checkout -b', [{ args: ['checkout', '-b', 'x'] }])
    assert.match(
      readFileSync(join(checkoutCreate.worker, '.git', 'logs', 'refs', 'heads', 'x'), 'utf8'),
      /\tbranch: Created from HEAD\n$/,
    )
    assert.match(headLog(checkoutCreate) as string, /\tcheckout: moving from main to x\n$/)

    const detached = pairFrom(source, temp.path, environment.env, 'checkout-detach')
    await runPair(detached, 'checkout --detach', [{ args: ['checkout', '--detach', 'main'] }])
    assert.match(headLog(detached) as string, /\tcheckout: moving from main to main\n$/)

    const same = pairFrom(source, temp.path, environment.env, 'checkout-same')
    await runPair(same, 'checkout same branch', [{ args: ['checkout', 'main'] }])
    const lines = (headLog(same) as string).trimEnd().split('\n')
    const last = lines[lines.length - 1] as string
    const [oldOid, newOid] = last.split(' ')
    assert.equal(oldOid, newOid, 'a same-branch checkout still appends an old=new HEAD line')
    assert.match(last, /\tcheckout: moving from main to main$/)

    const back = pairFrom(source, temp.path, environment.env, 'checkout-from-detached')
    await runPair(back, 'checkout from detached HEAD', [
      { args: ['checkout', '--detach', 'main'] },
      { args: ['checkout', 'main'] },
    ])
    assert.match(
      headLog(back) as string,
      /\tcheckout: moving from [0-9a-f]{40} to main\n$/,
      'the old label of a detached HEAD is its full object id',
    )
  } finally {
    temp.cleanup()
  }
})

test('branch -D removes the branch reflog and branch -f appends a reset line', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'branch-delete-source')

    const deleted = pairFrom(source, temp.path, environment.env, 'branch-delete')
    await runPair(deleted, 'branch -D', [{ args: ['branch', 'gone'] }, { args: ['branch', '-D', 'gone'] }])
    assert.equal(readLogTree(join(deleted.worker, '.git', 'logs')).has('refs/heads/gone'), false)

    const forced = pairFrom(source, temp.path, environment.env, 'branch-force')
    await runPair(forced, 'branch -f', [
      { args: ['branch', 'move'] },
      { args: ['commit', '--allow-empty', '-m', 'advance main'] },
      { args: ['branch', '-f', 'move', 'main'] },
    ])
    assert.match(
      readFileSync(join(forced.worker, '.git', 'logs', 'refs', 'heads', 'move'), 'utf8'),
      /\tbranch: Reset to main\n$/,
    )

    const disabled = pairFrom(source, temp.path, environment.env, 'branch-delete-disabled')
    await runPair(disabled, 'branch -D with logging disabled', [
      { args: ['branch', 'gone'] },
      { args: ['config', 'core.logAllRefUpdates', 'false'] },
      { args: ['branch', '-D', 'gone'] },
    ])
    assert.equal(readLogTree(join(disabled.worker, '.git', 'logs')).has('refs/heads/gone'), false)
  } finally {
    temp.cleanup()
  }
})

test('branch listing, show-current, failed commands and checkout -- paths do not write', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'quiet-source')

    const listing = pairFrom(source, temp.path, environment.env, 'branch-list')
    const beforeListing = headLog(listing)
    await runPair(listing, 'branch list', [{ args: ['branch'] }, { args: ['branch', '--show-current'] }])
    assert.equal(headLog(listing), beforeListing)

    const failed = pairFrom(source, temp.path, environment.env, 'failed')
    const beforeFailed = headLog(failed)
    await runPair(failed, 'failed switch', [{ args: ['switch', 'does-not-exist'] }])
    assert.equal(headLog(failed), beforeFailed)

    const paths = pairFrom(source, temp.path, environment.env, 'checkout-paths')
    const beforePaths = headLog(paths)
    await runPair(paths, 'checkout -- path', [
      {
        args: ['checkout', '--', 'a.txt'],
        prepare: repository => writeFileSync(join(repository, 'a.txt'), 'local edit\n'),
      },
    ])
    assert.equal(headLog(paths), beforePaths)
  } finally {
    temp.cleanup()
  }
})

test('core.logAllRefUpdates=false suppresses creation but still matches git for existing logs', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)

    const fresh = emptyPair(temp.path, environment.env, 'log-disabled-fresh', [
      ['config', 'core.logAllRefUpdates', 'false'],
    ])
    await runPair(fresh, 'disabled fresh repository', [
      { args: ['commit', '--allow-empty', '-m', 'one'] },
      { args: ['branch', 'b'] },
    ])
    assert.deepEqual([...readLogTree(join(fresh.system, '.git', 'logs')).keys()], [])
    assert.deepEqual([...readLogTree(join(fresh.worker, '.git', 'logs')).keys()], [])

    const source = baseRepository(temp.path, environment.env, 'log-disabled-source')
    const existing = pairFrom(source, temp.path, environment.env, 'log-disabled-existing')
    await runPair(existing, 'disabled with existing logs', [
      { args: ['config', 'core.logAllRefUpdates', 'false'] },
      { args: ['commit', '--allow-empty', '-m', 'no new branch log'] },
      { args: ['branch', 'new-branch'] },
    ])
    assert.equal(readLogTree(join(existing.worker, '.git', 'logs')).has('refs/heads/new-branch'), false)

    const override = pairFrom(source, temp.path, environment.env, 'log-disabled-override')
    await runPair(override, '-c core.logAllRefUpdates=false', [
      { args: ['-c', 'core.logAllRefUpdates=false', 'commit', '--allow-empty', '-m', 'no new branch log'] },
      { args: ['-c', 'core.logAllRefUpdates=false', 'branch', 'via-c'] },
    ])
    assert.equal(readLogTree(join(override.worker, '.git', 'logs')).has('refs/heads/via-c'), false)
  } finally {
    temp.cleanup()
  }
})

test('a bare repository does not create reflogs by default', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'bare-source')
    const bare = join(temp.path, 'bare.git')
    const clone = systemGit(['clone', '-q', '--bare', source, bare], temp.path, environment.env)
    assert.equal(clone.code, 0, clone.stderr.toString())
    const pair = pairFrom(bare, temp.path, environment.env, 'bare')
    await runPair(pair, 'bare branch', [{ args: ['branch', 'b', 'HEAD'] }], { bare: true })
    assert.deepEqual([...readLogTree(join(pair.system, 'logs')).keys()], [])
    assert.deepEqual([...readLogTree(join(pair.worker, 'logs')).keys()], [])
  } finally {
    temp.cleanup()
  }
})

test('branch -D deletes the reflog even when another name fails', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'branch-delete-partial-source')
    const pair = pairFrom(source, temp.path, environment.env, 'branch-delete-partial')
    await runPair(pair, 'create a1', [{ args: ['branch', 'a1'] }])
    // Both implementations delete a1 and then fail on the missing name. The
    // exit statuses are both non-zero (the Worker reports the same fatal, with
    // its existing 128 status), but the reflog tree must still converge.
    const expected = systemGit(['branch', '-D', 'a1', 'missing'], pair.system, pair.env)
    const actual = await workerGit(['branch', '-D', 'a1', 'missing'], pair.worker, pair.env)
    assert.notEqual(expected.code, 0)
    assert.notEqual(actual.code, 0)
    assertLogsEqual(pair, 'branch -D partial')
    assertReflogReadable(pair, 'branch -D partial')
    assertRefsEqual(pair, 'branch -D partial')
    assert.equal(
      readLogTree(join(pair.worker, '.git', 'logs')).has('refs/heads/a1'),
      false,
      'the log of the branch deleted before the failure must be removed too',
    )
  } finally {
    temp.cleanup()
  }
})

test('checkout -B and switch -C reset existing branches and keep their reflogs', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'reset-source')

    const switchReset = pairFrom(source, temp.path, environment.env, 'switch-reset')
    await runPair(switchReset, 'switch -C different oid', [
      { args: ['branch', 'c'] },
      { args: ['commit', '--allow-empty', '-m', 'advance main'] },
      { args: ['switch', '-C', 'c'] },
    ])
    assert.match(
      readFileSync(join(switchReset.worker, '.git', 'logs', 'refs', 'heads', 'c'), 'utf8'),
      /\tbranch: Reset to HEAD\n$/,
    )

    const checkoutReset = pairFrom(source, temp.path, environment.env, 'checkout-reset')
    await runPair(checkoutReset, 'checkout -B different oid', [
      { args: ['branch', 'c'] },
      { args: ['commit', '--allow-empty', '-m', 'advance main'] },
      { args: ['checkout', '-B', 'c'] },
    ])
    assert.match(
      readFileSync(join(checkoutReset.worker, '.git', 'logs', 'refs', 'heads', 'c'), 'utf8'),
      /\tbranch: Reset to HEAD\n$/,
    )

    // Same oid: git prints a reset notice but does not move the branch ref, so
    // the branch log keeps its single creation line and HEAD gets the checkout
    // line. `-c` without the force flag must still reject an existing name.
    const same = pairFrom(source, temp.path, environment.env, 'switch-reset-same')
    await runPair(same, 'switch -C same oid', [
      { args: ['branch', 'c'] },
      { args: ['switch', '-C', 'c'] },
    ])
    assert.equal(
      readFileSync(join(same.worker, '.git', 'logs', 'refs', 'heads', 'c'), 'utf8')
        .match(/branch: Reset/g)?.length ?? 0,
      0,
    )

    const sameCheckout = pairFrom(source, temp.path, environment.env, 'checkout-reset-same')
    await runPair(sameCheckout, 'checkout -B same oid', [
      { args: ['branch', 'c'] },
      { args: ['checkout', '-B', 'c'] },
    ])
    assert.equal(
      readFileSync(join(sameCheckout.worker, '.git', 'logs', 'refs', 'heads', 'c'), 'utf8')
        .match(/branch: Reset/g)?.length ?? 0,
      0,
    )

    const createExisting = pairFrom(source, temp.path, environment.env, 'create-existing')
    assert.equal(systemGit(['branch', 'c'], createExisting.system, createExisting.env).code, 0)
    assert.equal(systemGit(['branch', 'c'], createExisting.worker, createExisting.env).code, 0)
    const expected = systemGit(['switch', '-c', 'c'], createExisting.system, createExisting.env)
    const actual = await workerGit(['switch', '-c', 'c'], createExisting.worker, createExisting.env)
    assert.equal(expected.code, 128)
    assert.equal(actual.code, 128)
    assert.match(actual.stderr.toString(), /already exists/)
  } finally {
    temp.cleanup()
  }
})

test('resetting the current branch appends HEAD Reset and prints Reset branch', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'current-reset-source')
    const advanced = baseRepository(temp.path, environment.env, 'current-reset-advanced')
    assert.equal(systemGit(['branch', 'side'], advanced, environment.env).code, 0)
    assert.equal(systemGit(['branch', 'c', 'side'], advanced, environment.env).code, 0)
    assert.equal(
      systemGit(['commit', '--allow-empty', '-qm', 'advance main'], advanced, environment.env).code,
      0,
    )

    const compare = async (pair: Pair, label: string, args: readonly string[]): Promise<void> => {
      const expected = systemGit(args, pair.system, pair.env)
      const actual = await workerGit(args, pair.worker, pair.env)
      assert.equal(actual.code, expected.code, `${label}: exit status`)
      assert.equal(actual.stdout.toString(), expected.stdout.toString(), `${label}: stdout`)
      assert.equal(actual.stderr.toString(), expected.stderr.toString(), `${label}: stderr`)
      assertRefsEqual(pair, label)
      assertLogsEqual(pair, label)
      assertReflogReadable(pair, label)
    }

    // Same oid on the current branch: git still appends the reset record to
    // HEAD, leaves the branch log alone, and prints `Reset branch 'main'`.
    for (const [label, args] of [
      ['checkout -B current same', ['checkout', '-B', 'main']],
      ['switch -C current same', ['switch', '-C', 'main']],
    ] as const) {
      const pair = pairFrom(source, temp.path, environment.env, label.replaceAll(' ', '-'))
      await compare(pair, label, args)
      const head = headLog(pair) as string
      assert.match(head, /\tbranch: Reset to HEAD\n[^\n]*\tcheckout: moving from main to main\n$/)
      assert.equal(
        (readFileSync(join(pair.worker, '.git', 'logs', 'refs', 'heads', 'main'), 'utf8')
          .match(/branch: Reset/g)?.length ?? 0),
        0,
        `${label}: an unchanged branch oid writes no branch reset entry`,
      )
    }

    // Different oid on the current branch: HEAD and the branch log both get
    // `Reset to side`, HEAD before its checkout line.
    for (const [label, args] of [
      ['checkout -B current different oid', ['checkout', '-B', 'main', 'side']],
      ['switch -C current different oid', ['switch', '-C', 'main', 'side']],
    ] as const) {
      const pair = pairFrom(advanced, temp.path, environment.env, label.replaceAll(' ', '-'))
      await compare(pair, label, args)
      const head = headLog(pair) as string
      assert.match(head, /\tbranch: Reset to side\n[^\n]*\tcheckout: moving from main to main\n$/)
      assert.match(
        readFileSync(join(pair.worker, '.git', 'logs', 'refs', 'heads', 'main'), 'utf8'),
        /\tbranch: Reset to side\n$/,
      )
    }

    // A reset of a non-current branch keeps git's `Switched to and reset
    // branch` notice and writes only that branch's reset, not HEAD's.
    const side = pairFrom(advanced, temp.path, environment.env, 'switch-reset-non-current')
    await compare(side, 'switch -C non-current', ['switch', '-C', 'c'])
    assert.equal(
      (headLog(side) as string).match(/branch: Reset/g)?.length ?? 0,
      0,
      'a non-current branch reset does not write a HEAD reset entry',
    )
    assert.match(
      readFileSync(join(side.worker, '.git', 'logs', 'refs', 'heads', 'c'), 'utf8'),
      /\tbranch: Reset to HEAD\n$/,
    )
  } finally {
    temp.cleanup()
  }
})

test('an already-detached checkout at the same commit appends no HEAD entry', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'detached-noop-source')
    const pair = pairFrom(source, temp.path, environment.env, 'detached-noop')
    systemGit(['checkout', '-q', '--detach', 'main'], pair.system, pair.env)
    systemGit(['checkout', '-q', '--detach', 'main'], pair.worker, pair.env)
    const before = headLog(pair, pair.worker) as string
    await runPair(pair, 'detached no-op', [{ args: ['checkout', '--detach', 'HEAD'] }])
    assert.equal(headLog(pair, pair.worker), before, 'the same detached commit writes no reflog line')
    await runPair(pair, 'detached switch no-op', [{ args: ['switch', '--detach', 'HEAD'] }])
    assert.equal(headLog(pair, pair.worker), before, 'switch --detach at the same commit is also a no-op')
  } finally {
    temp.cleanup()
  }
})

test('GIT_*_DATE without an offset uses the local timezone like the system git', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'local-zone-source')
    // The bare epoch and an ISO timestamp without a suffix are local-time
    // forms. git prints the local offset; the Worker used to reject the bare
    // epoch and store +0000 for the zone-less ISO form.
    for (const [label, authorDate] of [
      ['bare epoch', '1700000000'],
      ['zone-less ISO', '2023-11-14T22:13:20'],
    ] as const) {
      const env = {
        ...environment.env,
        GIT_AUTHOR_DATE: authorDate,
        GIT_COMMITTER_DATE: authorDate,
      }
      const pair = pairFrom(source, temp.path, env, `local-zone-${label.replaceAll(' ', '-')}`)
      await runPair(pair, `local timezone ${label}`, [
        { args: ['commit', '--allow-empty', '-m', `local zone ${label}`] },
      ])
      const expected = systemGit(['cat-file', '-p', 'HEAD'], pair.system, pair.env)
      const actual = systemGit(['cat-file', '-p', 'HEAD'], pair.worker, pair.env)
      assert.equal(actual.stdout.toString(), expected.stdout.toString(), `${label}: commit object identity`)
    }
  } finally {
    temp.cleanup()
  }
})

test('GIT_COMMITTER_DATE=now keeps read-only and log-disabled commands working', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const source = baseRepository(temp.path, environment.env, 'date-now-source')

    const listing = pairFrom(
      source,
      temp.path,
      { ...environment.env, GIT_COMMITTER_DATE: 'now' },
      'date-now-list',
    )
    await runPair(listing, 'branch listing with now', [
      { args: ['branch'] },
      { args: ['branch', '--show-current'] },
    ])

    const deletion = pairFrom(source, temp.path, { ...environment.env }, 'date-now-delete')
    await runPair(deletion, 'create branch before now', [{ args: ['branch', 'gone'] }])
    deletion.env.GIT_COMMITTER_DATE = 'now'
    await runPair(deletion, 'branch -D with now', [{ args: ['branch', '-D', 'gone'] }])
    assert.equal(readLogTree(join(deletion.worker, '.git', 'logs')).has('refs/heads/gone'), false)

    const disabled = emptyPair(temp.path, { ...environment.env }, 'date-now-disabled', [
      ['config', 'core.logAllRefUpdates', 'false'],
    ])
    await runPair(disabled, 'commit without logs', [
      { args: ['commit', '--allow-empty', '-m', 'one'] },
    ])
    disabled.env.GIT_COMMITTER_DATE = 'now'
    await runPair(disabled, 'checkout -b with now and logging disabled', [
      { args: ['checkout', '-b', 'x'] },
    ])
  } finally {
    temp.cleanup()
  }
})

test('a reflog write failure fails the command loudly', { skip }, async () => {
  const temp = tempDirectory()
  try {
    const environment = fixtureEnvironment(temp.path)
    const repository = baseRepository(temp.path, environment.env, 'reflog-failure')
    // A file where the logs directory must be makes the append fail; the
    // command must report that instead of silently dropping the audit entry.
    rmSync(join(repository, '.git', 'logs'), { recursive: true, force: true })
    writeFileSync(join(repository, '.git', 'logs'), 'not a directory\n')
    const result = await workerGit(['commit', '--allow-empty', '-m', 'no audit'], repository, environment.env)
    assert.notEqual(result.code, 0)
    assert.match(result.stderr.toString(), /^fatal: /m)
  } finally {
    temp.cleanup()
  }
})
