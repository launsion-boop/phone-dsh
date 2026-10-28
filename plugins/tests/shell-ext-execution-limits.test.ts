// SPDX-License-Identifier: MIT
/**
 * G2-FIX-118: the per-command execution ceilings are phone-dsh's own,
 * disclosed numbers.
 *
 * just-bash 3.6 defaults `maxCommandCount`, `maxLoopIterations`,
 * `maxAwkIterations` and `maxSedIterations` to 100000. Before this fix the
 * Worker shell did not set them and the capability manifest did not publish
 * them, so the model could not know why `seq`/`awk`/`for` stopped. The shell
 * now spreads the frozen owner constants and the manifest renders the same
 * object; this test drives the real boundary and checks the two agree.
 * @module @phone-dsh/dsh-plugins/tests/shell-ext-execution-limits.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Bash } from 'just-bash/browser'
import {
  VfsFileSystem,
  WORKER_EXECUTION_LIMITS,
  WorkerShell,
} from '../shell-ext/src/index.ts'
import { executionLimitProgram } from '../shell-ext/src/shell.ts'
import {
  buildCapabilityManifest,
  type CapabilityManifestInput,
} from '../worker-entry/src/capabilities.ts'

const scratch: string[] = []

after(() => {
  for (const root of scratch) rmSync(root, { recursive: true, force: true })
})

/** A Worker shell over a real temporary VFS root, like the shell-ext tests. */
function shellFixture(): WorkerShell {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-execution-limits-'))
  scratch.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  return new WorkerShell({ fs: new VfsFileSystem({ root }), commands: [] })
}

function manifestInput(overrides: Partial<CapabilityManifestInput> = {}): CapabilityManifestInput {
  return { commands: ['awk', 'bash', 'git', 'sed', 'seq'], ...overrides }
}

test('WORKER_EXECUTION_LIMITS is one frozen owner and every field is 100000', () => {
  assert.equal(Object.isFrozen(WORKER_EXECUTION_LIMITS), true)
  assert.deepEqual(WORKER_EXECUTION_LIMITS, {
    maxCommandCount: 100000,
    maxLoopIterations: 100000,
    maxAwkIterations: 100000,
    maxSedIterations: 100000,
  })
})

test('the shell stops seq and awk exactly at the disclosed iteration ceiling', { timeout: 30_000 }, async () => {
  const shell = shellFixture()
  // The boundary is exactly the constant: 100000 values pass, 100001 fails.
  const atLimit = await shell.run(['bash', '-c', 'seq 1 100000 >/dev/null'], { cwd: '/dsh/workspace' })
  assert.equal(atLimit.exitCode, 0, atLimit.stderr)

  const over = await shell.run(['bash', '-c', 'seq 1 100001 >/dev/null'], { cwd: '/dsh/workspace' })
  assert.notEqual(over.exitCode, 0, 'seq over the limit must fail')
  assert.match(over.stderr, /100000/)
  assert.match(over.stderr, /iterations?/i)
  assert.match(over.stderr, /reason=iterations/)
  assert.match(over.stderr, /program=seq/)

  const awkAtLimit = await shell.run(
    ['bash', '-c', "awk 'BEGIN{for(i=0;i<100000;i++) x=i}'"],
    { cwd: '/dsh/workspace' },
  )
  assert.equal(awkAtLimit.exitCode, 0, awkAtLimit.stderr)

  const awkOver = await shell.run(
    ['bash', '-c', "awk 'BEGIN{for(i=0;i<100001;i++) x=i}'"],
    { cwd: '/dsh/workspace' },
  )
  assert.notEqual(awkOver.exitCode, 0, 'awk over the limit must fail')
  assert.match(awkOver.stderr, /100000/)
  assert.match(awkOver.stderr, /iterations/i)
  assert.match(awkOver.stderr, /reason=iterations/)
  assert.match(awkOver.stderr, /program=awk/)
})

test('for and while stopped by the command ceiling still report reason=iterations', { timeout: 60_000 }, async () => {
  const shell = shellFixture()
  for (const script of [
    'for ((i=0;i<100001;i++)); do :; done',
    'i=0; while ((i<100001)); do ((i++)); done',
  ]) {
    const result = await shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' })
    assert.notEqual(result.exitCode, 0, `loop over the limit must fail: ${script}`)
    // In production `maxCommandCount` and `maxLoopIterations` are both 100000,
    // so a loop body reaches the command ceiling first. That message used to
    // carry no trailer at all; it is the same execution ceiling to the model.
    assert.match(result.stderr, /too many commands executed/iu)
    assert.match(result.stderr, /100000/u)
    assert.match(result.stderr, /reason=iterations/u)
    assert.match(result.stderr, /program=bash/u)
  }
})

test('a real maxLoopIterations trip is classified as an iterations failure', { timeout: 30_000 }, async () => {
  for (const [script, program] of [
    ['for ((i=0;i<6;i++)); do :; done', 'for'],
    ['i=0; while ((i<6)); do i=$((i+1)); done', 'while'],
    ['i=0; until [ $i -ge 6 ]; do i=$((i+1)); done', 'until'],
  ] as const) {
    // WorkerShell's owner constants are 100000, so drive the engine boundary
    // directly with a small ceiling and classify the message it really emits.
    const bash = new Bash({ executionLimits: { maxCommandCount: 100000, maxLoopIterations: 3 } })
    const result = await bash.exec(script)
    assert.notEqual(result.exitCode, 0, `${program} loop over maxLoopIterations must fail`)
    assert.match(result.stderr, new RegExp(`${program} loop: too many iterations`, 'u'))
    assert.equal(executionLimitProgram(result.stderr), program)
  }
})

test('the ceiling classifier owns every just-bash 3.6 message shape', () => {
  assert.equal(
    executionLimitProgram('bash: too many commands executed (>100000), increase executionLimits.maxCommandCount\n'),
    'bash',
  )
  assert.equal(
    executionLimitProgram('bash: seq: iteration limit exceeded (100000)\n'),
    'seq',
  )
  assert.equal(
    executionLimitProgram('bash: awk: iteration limit exceeded (100000)\n'),
    'awk',
  )
  assert.equal(executionLimitProgram('bash: no such file\n'), undefined)
})

test('the manifest limits.execution is the same object the shell enforces', () => {
  const manifest = buildCapabilityManifest(manifestInput())
  assert.deepEqual(manifest.json.limits.execution, {
    max_command_count: WORKER_EXECUTION_LIMITS.maxCommandCount,
    max_loop_iterations: WORKER_EXECUTION_LIMITS.maxLoopIterations,
    max_awk_iterations: WORKER_EXECUTION_LIMITS.maxAwkIterations,
    max_sed_iterations: WORKER_EXECUTION_LIMITS.maxSedIterations,
  })
  // AGENTS.md renders the numbers from the owner, never a literal.
  assert.match(
    manifest.markdown,
    new RegExp(`<= ${String(WORKER_EXECUTION_LIMITS.maxCommandCount)} commands`, 'u'),
  )
  assert.match(manifest.markdown, /loop\/awk\/sed iterations/u)
  assert.match(manifest.markdown, /reason=iterations/u)
})
