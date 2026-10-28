// SPDX-License-Identifier: MIT
// workspace-changes snapshots the work tree by running a fixed set of git
// subcommands. The phone's git implementation mirrors those argv vectors, so a
// change here is a change the Worker git must follow.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { gitRunArgvs, parseText } from '../src/ast.ts'
import { readCheckoutFile } from '../src/checkout-file.ts'
import { observe } from '../src/observed.ts'

/** The eight snapshot subcommands, in the order the recorder runs them. */
const SUBCOMMANDS = [
  'rev-parse',
  'add',
  'write-tree',
  'ls-tree',
  'cat-file',
  'diff-tree',
  'ls-files',
  'check-ignore',
] as const

/** Flags each subcommand's argv must keep. */
const REQUIRED_FLAGS: Readonly<Record<string, readonly string[]>> = {
  'rev-parse': ['--show-toplevel', '--absolute-git-dir', '--git-path', 'objects'],
  'add': ['--all', '--ignore-errors'],
  'write-tree': [],
  'ls-tree': ['-z', '-l'],
  'cat-file': ['blob'],
  'diff-tree': ['-r', '-M', '-z', '--numstat'],
  'ls-files': ['-z', '--stage'],
  'check-ignore': ['-z', '--stdin'],
}

test('workspace changes: git argv uses the eight snapshot subcommands', (t) => {
  const source = parseText(
    'git.ts',
    readCheckoutFile('packages/deliverables/workspace-changes/src/git.ts'),
  )
  const runs = gitRunArgvs(source)
  observe(t, 'workspaceChangesGitArgv', runs)
  assert.deepEqual(runs.map(run => run.subcommand), SUBCOMMANDS, 'the snapshot subcommand sequence changed')
  for (const run of runs) {
    const required = REQUIRED_FLAGS[run.subcommand] ?? []
    for (const flag of required) {
      assert.ok(run.argv.includes(flag), `git ${run.subcommand} no longer passes ${flag}`)
    }
  }
  const add = runs.find(run => run.subcommand === 'add')
  assert.ok(add?.argv.some(token => token.startsWith('...')), 'git add must still spread the exclude pathspec')
})
