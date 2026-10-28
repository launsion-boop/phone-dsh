// SPDX-License-Identifier: MIT
// The JS shell interpreter is what keeps `bash -c` in the Worker. The contract
// pins the command node kinds and redirection subtypes it handles, and runs one
// small command line per construct so a shrinking shell is visible.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { parseText, switchCaseLabelsInMethod } from '../src/ast.ts'
import { readCheckoutFile } from '../src/checkout-file.ts'
import { observe } from '../src/observed.ts'
import { loadProbe } from '../src/probe-loader.ts'
import type { ProbeShellRun } from '../src/probe-types.ts'

/** Command AST node kinds the interpreter must dispatch. */
const COMMAND_KINDS = ['command', 'envs', 'subshell', 'group'] as const

/** Redirection subtypes the interpreter must at least recognise. */
const REDIRECTION_SUBTYPES = ['<', '<<<', '>', '>>', '>&', '<&'] as const

test('shell interpreter: command node kinds and redirection subtypes are handled', (t) => {
  const source = parseText(
    'interpret.ts',
    readCheckoutFile('packages/experimental/webworker-runtime/src/shell/interpret.ts'),
  )
  const commandKinds = switchCaseLabelsInMethod(source, 'command')
  const redirectionSubtypes = switchCaseLabelsInMethod(source, 'redirected')
  observe(t, 'interpreterNodeKinds', { commandKinds, redirectionSubtypes })
  for (const kind of COMMAND_KINDS) {
    assert.ok(commandKinds.includes(kind), `the interpreter command switch no longer handles ${kind}`)
  }
  for (const subtype of REDIRECTION_SUBTYPES) {
    assert.ok(redirectionSubtypes.includes(subtype), `the interpreter redirect switch no longer recognises ${subtype}`)
  }
})

test('shell interpreter: every command kind and supported redirection runs', async (t) => {
  const probe = await loadProbe()
  const vfs = new probe.MemoryVfs()
  probe.setActiveVfs(vfs)
  vfs.seedDirectory('/dsh/workspace')
  vfs.writeFileSync('/dsh/workspace/in.txt', 'from-file\n')

  const outcomes: Record<string, ProbeShellRun> = {}
  const run = async (name: string, source: string): Promise<ProbeShellRun> => {
    const outcome = await probe.runShellCommand(source, { cwd: '/dsh/workspace', env: {} })
    outcomes[name] = outcome
    return outcome
  }

  await run('command', 'echo plain')
  await run('envs', 'FOO=bar; echo $FOO')
  await run('subshell', '(echo sub)')
  await run('group', '{ echo group; }')
  await run('redirection<', 'cat < /dsh/workspace/in.txt')
  await run('redirection<<<', 'cat <<< here')
  await run('redirection>', 'echo one > /dsh/workspace/out.txt; cat < /dsh/workspace/out.txt')
  await run('redirection>>', 'echo two >> /dsh/workspace/out.txt; cat < /dsh/workspace/out.txt')
  await run('redirection>&', 'echo err >&2')
  await run('redirection<&', 'cat <&0')

  observe(t, 'interpreterOutcomes', outcomes)
  assert.equal(outcomes['command']?.stdout, 'plain\n')
  assert.equal(outcomes['envs']?.stdout, 'bar\n')
  assert.equal(outcomes['subshell']?.stdout, 'sub\n')
  assert.equal(outcomes['group']?.stdout, 'group\n')
  assert.equal(outcomes['redirection<']?.stdout, 'from-file\n')
  assert.equal(outcomes['redirection<<<']?.stdout, 'here\n')
  assert.equal(outcomes['redirection>']?.stdout, 'one\n')
  assert.equal(outcomes['redirection>>']?.stdout, 'one\ntwo\n')
  assert.equal(outcomes['redirection>&']?.stderr, 'err\n')
  assert.equal(outcomes['redirection>&']?.exitCode, 0)
  // `<&` is recognised but refused by this shell revision; record whether a
  // future checkout starts supporting it rather than failing on the change.
  assert.equal(typeof outcomes['redirection<&']?.exitCode, 'number')
})
