// SPDX-License-Identifier: MIT
/**
 * Recheck regressions for the Worker shell safety surface.
 *
 * The first-wave fixes made `trap`, `cp -a/-p/-d` and `od -N/-j` real, but
 * three boundaries were still dishonest:
 *
 * - an EXIT handler that ignored the cooperative abort could keep running and
 *   write after the command had already returned 124/130;
 * - `cp -a-` normalised its invalid trailing short flag to `--`, so the bundled
 *   parser copied successfully and exited 0;
 * - `od -N/-j` still called `readFileBuffer` for an overlapping operand, so a
 *   four-byte window over a huge file read the whole file.
 *
 * These tests drive the real `WorkerShell` and the production command table.
 * The `od` cases use a real instrumented `node:fs` face and count bytes at the
 * reader boundary, not only the formatted output.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { promises as fsp, type Stats } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'
import { after, test } from 'node:test'
import { defineCommand } from 'just-bash/browser'
import type { CustomCommand } from 'just-bash/browser'
import {
  OD_MAX_UNRANGED_READ_BYTES,
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  type VfsFileSystemIo,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A throwaway real-directory VFS below temp. */
function workspace(commands: readonly CustomCommand[] = createWorkerCommands({ git: false, curl: false, toolbox: false })): {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
} {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-recheck-safety-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  const fs = new VfsFileSystem({ root })
  return { root, fs, shell: new WorkerShell({ fs, commands: [...commands] }) }
}

/** Counters at the exact reader boundary the adapter calls. */
interface ReadCounters {
  readFileCalls: number
  readFileBytes: number
  rangeCalls: number
  rangeBytes: number
  rangeStarts: number[]
  rangeLengths: number[]
}

function counters(): ReadCounters {
  return {
    readFileCalls: 0,
    readFileBytes: 0,
    rangeCalls: 0,
    rangeBytes: 0,
    rangeStarts: [],
    rangeLengths: [],
  }
}

/** Read a real range with `FileHandle.read`, the same primitive the adapter uses. */
async function readRange(path: string, start: number, length: number): Promise<Uint8Array> {
  const handle = await fsp.open(path, 'r')
  try {
    const buffer = Buffer.alloc(length)
    let offset = 0
    while (offset < length) {
      const { bytesRead } = await handle.read(buffer, offset, length - offset, start + offset)
      if (bytesRead === 0) break
      offset += bytesRead
    }
    return new Uint8Array(buffer.subarray(0, offset))
  } finally {
    await handle.close()
  }
}

/** A real `node:fs` face that counts whole-file and ranged reads. */
function instrumentedIo(counts: ReadCounters, range: boolean): VfsFileSystemIo {
  return {
    ...fsp,
    async readFile(path: string): Promise<Buffer> {
      counts.readFileCalls += 1
      const bytes = await fsp.readFile(path)
      counts.readFileBytes += bytes.byteLength
      return bytes
    },
    ...range
      ? {
          async readFileRange(path: string, start: number, length: number): Promise<Uint8Array> {
            counts.rangeCalls += 1
            counts.rangeBytes += length
            counts.rangeStarts.push(start)
            counts.rangeLengths.push(length)
            return await readRange(path, start, length)
          },
        }
      : {},
  } as VfsFileSystemIo
}

/** Build a VFS whose `node:fs` face counts reads. */
function countedWorkspace(options: { range: boolean }): {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
  readonly counts: ReadCounters
} {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-recheck-od-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  const counts = counters()
  const fs = new VfsFileSystem({ root, nodeFs: instrumentedIo(counts, options.range) })
  return { root, fs, shell: new WorkerShell({ fs }), counts }
}

test('EXIT handler cannot write after the wall clock fires while it is running', async () => {
  const state = { started: 0 }
  const slowwrite = defineCommand('slowwrite', async (args, ctx) => {
    state.started += 1
    await sleep(300)
    await ctx.fs.writeFile(ctx.fs.resolvePath(ctx.cwd, args[0] as string), 'late\n')
    return { stdout: '', stderr: '', exitCode: 0 }
  })
  const { fs, shell } = workspace([...createWorkerCommands({ git: false, curl: false, toolbox: false }), slowwrite])

  const result = await shell.run(['bash', '-c', "trap 'slowwrite late.txt' EXIT; echo hi"], {
    cwd: CWD,
    timeoutMs: 100,
  })
  assert.equal(result.exitCode, 124, result.stderr)
  assert.equal(result.timedOut, true)
  assert.equal(state.started, 1, 'the handler must have started before the deadline')
  // The handler keeps sleeping beyond the command result; a post-abort write
  // would land here if the gate did not cover the cooperative-unwind window.
  await sleep(450)
  assert.equal(await fs.exists(`${CWD}/late.txt`), false, 'the timed-out handler must not write after 124')
  const afterTimeout = await shell.run(['bash', '-c', 'trap -p; echo still-ok'], { cwd: CWD })
  assert.equal(afterTimeout.exitCode, 0, afterTimeout.stderr)
  assert.equal(afterTimeout.stdout, 'still-ok\n', 'the interrupted execution must leave no trap state')
})

test('EXIT handler cannot write after a caller abort while it is running', async () => {
  const state = { started: 0 }
  const slowwrite = defineCommand('slowwrite', async (args, ctx) => {
    state.started += 1
    await sleep(300)
    await ctx.fs.writeFile(ctx.fs.resolvePath(ctx.cwd, args[0] as string), 'late\n')
    return { stdout: '', stderr: '', exitCode: 0 }
  })
  const { fs, shell } = workspace([...createWorkerCommands({ git: false, curl: false, toolbox: false }), slowwrite])
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 100)
  try {
    const result = await shell.run(['bash', '-c', "trap 'slowwrite late.txt' EXIT; echo hi"], {
      cwd: CWD,
      signal: controller.signal,
      timeoutMs: 5_000,
    })
    assert.equal(result.exitCode, 130)
    assert.equal(result.aborted, true)
    assert.equal(state.started, 1, 'the handler must have started before the abort')
    await sleep(450)
    assert.equal(await fs.exists(`${CWD}/late.txt`), false, 'the aborted handler must not write after 130')
  } finally {
    clearTimeout(timer)
  }
})

test('a normal EXIT handler keeps final cwd and original status and leaves no handler behind', async () => {
  const { fs, shell } = workspace()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const result = await shell.run([
    'bash',
    '-c',
    'X=kept; f() { cd /dsh/workspace/other; exit 7; }; '
      + 'trap \'printf "handler=%s var=%s\\n" "$PWD" "$X"; echo final > final.txt\' EXIT; f',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 7)
  assert.equal(result.stdout, `handler=${CWD}/other var=kept\n`)
  assert.equal(await fs.readFile(`${CWD}/other/final.txt`), 'final\n')
  assert.equal(await fs.exists(`${CWD}/final.txt`), false)

  const chained = await shell.run([
    'bash',
    '-c',
    'X=chain; trap \'printf "chain=%s var=%s\\n" "$PWD" "$X"\' EXIT; cd /dsh/workspace/other && exit 5',
  ], { cwd: CWD })
  assert.equal(chained.exitCode, 5)
  assert.equal(chained.stdout, `chain=${CWD}/other var=chain\n`, 'the capture must not change && semantics')

  const next = await shell.run(['bash', '-c', 'echo next'], { cwd: CWD })
  assert.equal(next.exitCode, 0)
  assert.equal(next.stdout, 'next\n', 'the finished handler must not leak into the next execution')
})

test('bare exit and exit $? preserve the status the shell entered with', async () => {
  const { shell } = workspace()
  const cases = [
    { script: 'false; exit', expected: 1 },
    { script: 'false; exit $?', expected: 1 },
    { script: 'false; exit "$?"', expected: 1 },
    { script: 'false; exit 7', expected: 7 },
    { script: 'set -e; false || exit', expected: 1 },
    { script: 'set -e; false || exit 7', expected: 7 },
    { script: 'set -e; ! true; exit 7', expected: 7 },
  ]
  for (const { script, expected } of cases) {
    const result = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(result.exitCode, expected, `${script}: ${result.stderr}`)
    assert.equal(result.stdout, '', script)
    assert.equal(result.stderr, '', script)
  }

  for (const script of ['false; exit', 'false; exit $?']) {
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'printf "handler-status=%s\\n" "$?"' EXIT; ${script}`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${script} with EXIT trap: ${result.stderr}`)
    assert.equal(result.stdout, 'handler-status=1\n', `${script}: the handler must start from the preserved status`)
    assert.equal(result.stderr, '', script)
  }
})

test('an EXIT handler ignores state captured while a function exits in a child execution', async () => {
  const { fs, shell } = workspace()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  await fs.mkdir(`${CWD}/final`, { recursive: true })
  const invocations = [
    { label: 'subshell', script: '(f) || :' },
    { label: 'command substitution', script: 'v=$(f) || :' },
    { label: 'pipeline', script: 'f | cat || :' },
    { label: 'background job', script: 'f & wait || :' },
  ]
  for (const [index, { label, script }] of invocations.entries()) {
    const marker = `trap-${String(index)}.txt`
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'printf "handler=%s var=%s\\n" "$PWD" "$X"; echo final > ${marker}' EXIT; `
        + `f() { cd /dsh/workspace/other; exit 3; }; ${script}; cd /dsh/workspace/final; X=final`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${label}: ${result.stderr}`)
    assert.equal(result.stdout, `handler=${CWD}/final var=final\n`, `${label} must use the main shell's final state`)
    assert.equal(result.stderr, '', label)
    assert.equal(await fs.readFile(`${CWD}/final/${marker}`), 'final\n', label)
    assert.equal(await fs.exists(`${CWD}/other/${marker}`), false, `${label} must not write in the child's cwd`)
  }

  const afterChild = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler=%s var=%s\\n" "$PWD" "$X"\' EXIT; '
      + 'f() { cd /dsh/workspace/other; exit 3; }; (f) || :; '
      + 'cd /dsh/workspace/final; X=final; exit 5',
  ], { cwd: CWD })
  assert.equal(afterChild.exitCode, 5, afterChild.stderr)
  assert.equal(afterChild.stdout, `handler=${CWD}/final var=final\n`)
  assert.equal(afterChild.stderr, '')
})

test('cp rejects invalid short clusters containing an archive flag before writing a target', async () => {
  const { fs, shell } = workspace()
  await fs.writeFile(`${CWD}/source`, 'source\n')
  const cases = [
    { cluster: '-a-', target: 'a-dash' },
    { cluster: '-p-', target: 'p-dash' },
    { cluster: '-d-', target: 'd-dash' },
    { cluster: '-ax', target: 'a-x' },
    { cluster: '-avx', target: 'a-v-x' },
  ]
  for (const { cluster, target } of cases) {
    const result = await shell.run(['bash', '-c', `cp ${cluster} source ${target}`], { cwd: CWD })
    assert.notEqual(result.exitCode, 0, `${cluster} must fail`)
    assert.match(result.stderr, /^cp: invalid option -- '[x-]'/mu, `${cluster}: ${result.stderr}`)
    assert.match(result.stderr, /reason=unsupported-option/u, `${cluster}: missing contract trailer`)
    assert.equal(result.stdout, '', cluster)
    assert.equal(await fs.exists(`${CWD}/${target}`), false, `${cluster} must not create its target`)
  }

  await fs.writeFile(`${CWD}/existing`, 'keep\n')
  const overwrite = await shell.run(['bash', '-c', 'cp -a- source existing'], { cwd: CWD })
  assert.notEqual(overwrite.exitCode, 0)
  assert.match(overwrite.stderr, /^cp: invalid option -- '-/mu)
  assert.equal(await fs.readFile(`${CWD}/existing`), 'keep\n', 'a rejected option must not touch an existing target')

  const valid = await shell.run(['bash', '-c', 'cp -a source preserved'], { cwd: CWD })
  assert.equal(valid.exitCode, 0, valid.stderr)
  assert.equal(await fs.readFile(`${CWD}/preserved`), 'source\n')
})

test('od reads only the requested window through the ranged filesystem face', async () => {
  const { root, fs, shell, counts } = countedWorkspace({ range: true })
  assert.equal(fs.supportsRangedReads, true)
  const big = Buffer.alloc(2 * 1024 * 1024, 0x41)
  big.write('ABCD', 0, 'latin1')
  big.write('EFGH', 1024 * 1024 - 4, 'latin1')
  writeFileSync(join(root, 'dsh/workspace/big'), big)

  const first = await shell.run(['bash', '-c', 'od -An -tx1 -N4 big'], { cwd: CWD })
  assert.equal(first.exitCode, 0, first.stderr)
  assert.equal(first.stdout, ' 41 42 43 44\n')
  assert.equal(counts.readFileCalls, 0, 'a ranged read must not call whole-file readFile')
  assert.equal(counts.readFileBytes, 0)
  assert.equal(counts.rangeCalls, 1)
  assert.equal(counts.rangeBytes, 4)
  assert.deepEqual(counts.rangeStarts, [0])
  assert.deepEqual(counts.rangeLengths, [4])

  const offset = 1024 * 1024 - 4
  const second = await shell.run(['bash', '-c', `od -An -tx1 -j${String(offset)} -N8 big`], { cwd: CWD })
  assert.equal(second.exitCode, 0, second.stderr)
  assert.equal(second.stdout, ' 45 46 47 48 41 41 41 41\n')
  assert.equal(counts.readFileCalls, 0)
  assert.deepEqual(counts.rangeStarts, [0, offset])
  assert.deepEqual(counts.rangeLengths, [4, 8])
})

test('od clips the window at source boundaries and reads nothing for -N0 or whole-source skips', async () => {
  const { root, fs, shell, counts } = countedWorkspace({ range: true })
  writeFileSync(join(root, 'dsh/workspace/first'), 'ABCDE')
  writeFileSync(join(root, 'dsh/workspace/second'), 'FGHIJ')

  const crossing = await shell.run(['bash', '-c', 'od -An -tx1 -j3 -N4 first second'], { cwd: CWD })
  assert.equal(crossing.exitCode, 0, crossing.stderr)
  assert.equal(crossing.stdout, ' 44 45 46 47\n')
  assert.deepEqual(counts.rangeStarts, [3, 0])
  assert.deepEqual(counts.rangeLengths, [2, 2])

  await fs.writeFile(`${CWD}/only`, 'abcdefghij')
  counts.rangeCalls = 0
  counts.rangeBytes = 0
  counts.rangeStarts = []
  counts.rangeLengths = []
  const zero = await shell.run(['bash', '-c', 'od -An -tx1 -N0 only'], { cwd: CWD })
  assert.equal(zero.exitCode, 0, zero.stderr)
  assert.equal(zero.stdout, '')
  assert.equal(counts.rangeCalls, 0, '-N0 must not read any bytes')

  const past = await shell.run(['bash', '-c', 'od -An -tx1 -j10 -N4 only'], { cwd: CWD })
  assert.equal(past.exitCode, 0, past.stderr)
  assert.equal(past.stdout, '')
  assert.equal(counts.rangeCalls, 0, 'a skip equal to the file size must not read it')

  const beyond = await shell.run(['bash', '-c', 'od -An -tx1 -j8 -N100 only'], { cwd: CWD })
  assert.equal(beyond.exitCode, 0, beyond.stderr)
  assert.equal(beyond.stdout, ' 69 6a\n', 'the window is clipped at EOF, not padded')
  assert.deepEqual(counts.rangeStarts, [8])
  assert.deepEqual(counts.rangeLengths, [2])
})

test('od refuses an unbounded whole-file fallback on a backend without ranged reads', async () => {
  const { root, fs, shell, counts } = countedWorkspace({ range: false })
  assert.equal(fs.supportsRangedReads, false)
  const big = Buffer.alloc(OD_MAX_UNRANGED_READ_BYTES + 1, 0x41)
  big.write('ABCD', 0, 'latin1')
  writeFileSync(join(root, 'dsh/workspace/big'), big)
  writeFileSync(join(root, 'dsh/workspace/small'), 'ABCD')

  const refused = await shell.run(['bash', '-c', 'od -An -tx1 -N4 big'], { cwd: CWD })
  assert.notEqual(refused.exitCode, 0)
  assert.equal(refused.stdout, '')
  assert.match(refused.stderr, /unranged read limit/u)
  assert.match(refused.stderr, /reason=limit-refused/u)
  assert.equal(counts.readFileCalls, 0, 'the refusal must happen before the whole-file read')

  const small = await shell.run(['bash', '-c', 'od -An -tx1 small'], { cwd: CWD })
  assert.equal(small.exitCode, 0, small.stderr)
  assert.equal(small.stdout, ' 41 42 43 44\n')
  assert.equal(counts.readFileCalls, 1)
  assert.equal(counts.readFileBytes, 4, 'the bounded fallback reads only the small file')
})

test('an execution-limit failure skips EXIT when the failing pipeline state is unproven', async () => {
  const { fs, shell } = workspace()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  await fs.mkdir(`${CWD}/final`, { recursive: true })
  await fs.writeFile(`${CWD}/recur.sh`, 'source /dsh/workspace/recur.sh\n')
  // `source` nesting overflows as ExecutionLimitError (exit 126) with no
  // transform metadata, fast enough for a unit regression.
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler=%s var=%s status=%s\\n" "$PWD" "$X" "$?"\' EXIT; '
      + 'f() { cd /dsh/workspace/other; exit 3; }; f | cat || :; '
      + 'cd /dsh/workspace/final; X=final; source /dsh/workspace/recur.sh',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 126, result.stderr)
  assert.match(result.stderr, /maximum nesting depth/u)
  assert.match(result.stderr, /reason=backend-failed/u)
  assert.equal(result.stdout, '', 'the EXIT handler must not run from an earlier state checkpoint')
})

test('a completed nonfatal command error runs EXIT from the returned final state', async () => {
  const { fs, shell } = workspace()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  await fs.mkdir(`${CWD}/final`, { recursive: true })
  // PosixFatalError, like ExecutionLimitError, returns without transform
  // metadata. The pending child capture must not make either look like an
  // explicit top-level exit.
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler=%s var=%s status=%s\\n" "$PWD" "$X" "$?"\' EXIT; '
      + 'f() { cd /dsh/workspace/other; exit 3; }; f | cat || :; '
      + 'cd /dsh/workspace/final; X=final; set -o posix; shift 1',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 1, result.stderr)
  assert.match(result.stderr, /shift count out of range/u)
  assert.equal(result.stdout, `handler=${CWD}/final var=final status=1\n`)
})

test('statement checkpoints do not clobber a direct pipeline PIPESTATUS in a trap script', async () => {
  const { shell } = workspace()
  const result = await shell.run([
    'bash',
    '-c',
    'trap : EXIT; false | true\nprintf "pipe=%s,%s\\n" "${PIPESTATUS[0]}" "${PIPESTATUS[1]}"',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'pipe=1,0\n')
  assert.equal(result.stderr, '')
})

test('statement checkpoint preserves set-e exemption inside an && chain', async () => {
  const { shell } = workspace()
  const result = await shell.run([
    'bash',
    '-c',
    "trap 'echo trap:$?' EXIT; set -e; false && echo skipped; echo kept",
  ], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'kept\ntrap:0\n')
  assert.equal(result.stderr, '')
})

test('statement checkpoint preserves set-e exemption for a negated pipeline', async () => {
  const { shell } = workspace()
  const result = await shell.run([
    'bash',
    '-c',
    "trap 'echo trap:$?' EXIT; set -e; ! true; echo kept",
  ], { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'kept\ntrap:0\n')
  assert.equal(result.stderr, '')
})

test('source, dot and eval exits capture the final cwd/environment for the EXIT handler', async () => {
  const { fs, shell } = workspace()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  await fs.writeFile(`${CWD}/lib.sh`, 'cd /dsh/workspace/other; X=from-source; exit 7\n')
  const cases = [
    { label: 'source', script: 'source /dsh/workspace/lib.sh', variable: 'from-source' },
    { label: 'dot', script: '. /dsh/workspace/lib.sh', variable: 'from-source' },
    {
      label: 'eval',
      script: 'cd /dsh/workspace/other; X=from-eval; eval \'exit 7\'',
      variable: 'from-eval',
    },
  ]
  for (const { label, script, variable } of cases) {
    const result = await shell.run([
      'bash',
      '-c',
      `trap 'printf "handler=%s var=%s status=%s\\n" "$PWD" "$X" "$?"' EXIT; ${script}`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 7, `${label}: ${result.stderr}`)
    assert.equal(result.stdout, `handler=${CWD}/other var=${variable} status=7\n`, label)
    assert.equal(result.stderr, '', label)
  }
  // The transformed source text is staged in a per-execution temp file; every
  // return path removes it instead of leaving a hidden script in the VFS.
  const tempEntries = await fs.readdir('/dsh/tmp').catch(() => [] as string[])
  assert.deepEqual(tempEntries.filter(name => name.startsWith('.pdsh-source-')), [])
})

/** A workspace whose delayed late.txt write is the one the test controls. */
function delayedWriteWorkspace(): {
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
  readonly state: { started: number; finished: number; onStart: () => void; startedPromise: Promise<void> }
} {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-recheck-inflight-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  let signalStart: () => void = () => {}
  const startedPromise = new Promise<void>((resolve) => { signalStart = resolve })
  const state = { started: 0, finished: 0, onStart: signalStart, startedPromise }
  const io: VfsFileSystemIo = {
    ...fsp,
    async writeFile(path, data, options): Promise<void> {
      if (!path.endsWith('/late.txt')) {
        await fsp.writeFile(path, data, options)
        return
      }
      state.started += 1
      state.onStart()
      await sleep(300)
      await fsp.writeFile(path, data, options)
      state.finished += 1
    },
  } as VfsFileSystemIo
  const fs = new VfsFileSystem({ root, nodeFs: io })
  return { fs, shell: new WorkerShell({ fs }), state }
}

test('an EXIT handler write already in flight at the deadline is rolled back before 124', async () => {
  const { fs, shell, state } = delayedWriteWorkspace()
  const began = Date.now()
  const result = await shell.run(['bash', '-c', "trap 'echo late > late.txt' EXIT; echo hi"], {
    cwd: CWD,
    timeoutMs: 100,
  })
  const elapsed = Date.now() - began
  assert.equal(result.exitCode, 124)
  assert.equal(result.timedOut, true)
  assert.ok(elapsed >= 100, 'the command runs through its timeout before the rollback grace')
  assert.ok(elapsed <= 100 + 600 + 150,
    `settlement and cleanup grace must be bounded (waited ${String(elapsed)} ms)`)
  assert.equal(state.started, 1, 'the late write must have started before the deadline')
  assert.equal(state.finished, 1, 'the underlying write settled after the abort')
  assert.equal(
    await fs.exists(`${CWD}/late.txt`),
    false,
    'the completed late write must be rolled back before 124 is returned',
  )
})

test('an EXIT handler write already in flight at a caller abort is rolled back before 130', async () => {
  const { fs, shell, state } = delayedWriteWorkspace()
  const controller = new AbortController()
  const pending = shell.run(['bash', '-c', "trap 'echo late > late.txt' EXIT; echo hi"], {
    cwd: CWD,
    signal: controller.signal,
    timeoutMs: 5_000,
  })
  await state.startedPromise
  controller.abort()
  const result = await pending
  assert.equal(result.exitCode, 130)
  assert.equal(result.aborted, true)
  assert.equal(state.started, 1)
  assert.equal(state.finished, 1, 'the underlying write settled after the abort')
  assert.equal(
    await fs.exists(`${CWD}/late.txt`),
    false,
    'the completed late write must be rolled back before 130 is returned',
  )
})

test('source and eval keep the leading -- option terminator', async () => {
  const { fs, shell } = workspace()
  await fs.writeFile(`${CWD}/lib.sh`, 'printf "sourced:%s\\n" "${1-unset}"\n')

  const sourced = await shell.run(['bash', '-c', 'source -- /dsh/workspace/lib.sh arg'], { cwd: CWD })
  assert.equal(sourced.exitCode, 0, sourced.stderr)
  assert.equal(sourced.stdout, 'sourced:arg\n')
  assert.equal(sourced.stderr, '')

  const dynamicTerminator = await shell.run([
    'bash',
    '-c',
    'flag=--; source "$flag" /dsh/workspace/lib.sh arg',
  ], { cwd: CWD })
  assert.equal(dynamicTerminator.exitCode, 0, dynamicTerminator.stderr)
  assert.equal(dynamicTerminator.stdout, 'sourced:arg\n',
    'a runtime-expanded -- must still consume the filename operand')
  assert.equal(dynamicTerminator.stderr, '')

  const dotted = await shell.run(['bash', '-c', '. -- /dsh/workspace/lib.sh'], { cwd: CWD })
  assert.equal(dotted.exitCode, 0, dotted.stderr)
  assert.equal(dotted.stdout, 'sourced:unset\n')
  assert.equal(dotted.stderr, '')

  const evaluated = await shell.run(['bash', '-c', "eval -- 'echo hi'"], { cwd: CWD })
  assert.equal(evaluated.exitCode, 0, evaluated.stderr)
  assert.equal(evaluated.stdout, 'hi\n')
  assert.equal(evaluated.stderr, '')

  for (const script of ['-z hello', '-- foo']) {
    const optionLikeText = await shell.run(['bash', '-c', `eval -- '${script}'`], { cwd: CWD })
    assert.equal(optionLikeText.exitCode, 127, optionLikeText.stderr)
    assert.match(optionLikeText.stderr, /command not found/u)
    assert.doesNotMatch(optionLikeText.stderr, /__pdsh_(?:state|eval_text)/u,
      'the real eval must execute option-like script text without exposing transformed text')
  }

  const emptyEval = await shell.run(['bash', '-c', 'eval --'], { cwd: CWD })
  assert.equal(emptyEval.exitCode, 0, emptyEval.stderr)
  assert.equal(emptyEval.stdout, '')
  assert.equal(emptyEval.stderr, '')

  const emptySource = await shell.run(['bash', '-c', 'source --'], { cwd: CWD })
  assert.equal(emptySource.exitCode, 2)
  assert.equal(emptySource.stdout, '')
  assert.equal(emptySource.stderr, 'bash: source: filename argument required\n')

  const badEvalOption = await shell.run(['bash', '-c', "eval -z 'echo hi'"], { cwd: CWD })
  assert.equal(badEvalOption.exitCode, 2)
  assert.equal(badEvalOption.stdout, '')
  assert.equal(badEvalOption.stderr, 'bash: eval: -z: invalid option\neval: usage: eval [arg ...]\n')
})

test('pipeline child exit is not mistaken for explicit exit after a later source error', async () => {
  const { fs, shell } = workspace()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  await fs.mkdir(`${CWD}/final`, { recursive: true })
  await fs.writeFile(`${CWD}/recur.sh`, 'source /dsh/workspace/recur.sh\n')
  await fs.writeFile(`${CWD}/lib.sh`, 'cd /dsh/workspace/other; X=stale; exit 3\n')
  const cases = [
    {
      label: 'eval',
      functions: "f() { cd /dsh/workspace/other; eval 'X=stale; exit 3'; }",
      pipeline: 'f | cat',
    },
    {
      label: 'source',
      functions: 'f() { cd /dsh/workspace/other; source /dsh/workspace/lib.sh; }',
      pipeline: 'f | cat',
    },
    {
      label: 'indirect eval',
      functions: "f() { cd /dsh/workspace/other; eval 'X=stale; exit 3'; }; g() { f; }",
      pipeline: 'g | cat',
    },
  ]
  for (const { label, functions, pipeline } of cases) {
    const result = await shell.run([
      'bash',
      '-c',
      'trap \'printf "handler=%s var=%s status=%s\\n" "$PWD" "$X" "$?"\' EXIT; '
        + `cd ${CWD}/final; X=final; ${functions}; `
        + `${pipeline}; source ${CWD}/recur.sh`,
    ], { cwd: CWD })
    assert.equal(result.exitCode, 126, `${label}: ${result.stderr}`)
    assert.match(result.stderr, /maximum nesting depth/u, label)
    assert.match(result.stderr, /reason=backend-failed/u, label)
    assert.equal(result.stdout, '',
      `${label}: do not run EXIT using a pipeline child's stale capture after an abnormal error`)
    assert.ok((await fs.readdir('/dsh/tmp')).every(name => !name.startsWith('.pdsh-source-')),
      `${label}: skip the trap but still clean source staging files`)
  }
})

test('an EXIT handler sees state from completed pipelines inside an && chain', async () => {
  const { fs, shell } = workspace()
  await fs.mkdir(`${CWD}/other`, { recursive: true })
  const result = await shell.run([
    'bash',
    '-c',
    'trap \'printf "handler=%s var=%s status=%s\\n" "$PWD" "$X" "$?"\' EXIT; '
      + `cd ${CWD}/other && X=intermediate && exit 126`,
  ], { cwd: CWD })
  assert.equal(result.exitCode, 126, result.stderr)
  assert.equal(result.stdout, `handler=${CWD}/other var=intermediate status=126\n`)
})

test('a handler write that never settles cannot hold the command past its budget', { timeout: 5_000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-recheck-never-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  let started = 0
  const io: VfsFileSystemIo = {
    ...fsp,
    async writeFile(path, data, options): Promise<void> {
      if (!path.endsWith('/late.txt')) {
        await fsp.writeFile(path, data, options)
        return
      }
      started += 1
      await new Promise<void>(() => {})
    },
  } as VfsFileSystemIo
  const fs = new VfsFileSystem({ root, nodeFs: io })
  const shell = new WorkerShell({ fs })

  const began = Date.now()
  const result = await shell.run(['bash', '-c', "trap 'echo late > late.txt' EXIT; echo hi"], {
    cwd: CWD,
    timeoutMs: 100,
  })
  const elapsed = Date.now() - began
  assert.equal(result.exitCode, 124)
  assert.equal(result.timedOut, true)
  assert.equal(started, 1, 'the stuck write must have started before the deadline')
  assert.ok(elapsed <= 100 + 600 + 150,
    `the command must return within its timeout plus cleanup grace (waited ${String(elapsed)}ms)`)
  assert.match(result.stderr, /reason=backend-failed/u, 'an unsettled backend operation must be labelled, not hidden')
})

test('a handler write that settles after the bounded wait is rolled back in the background', { timeout: 5_000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-recheck-late-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  let started = 0
  let finished = 0
  let releaseWrite: () => void = () => {}
  const gate = new Promise<void>((resolve) => { releaseWrite = resolve })
  const io: VfsFileSystemIo = {
    ...fsp,
    async writeFile(path, data, options): Promise<void> {
      if (!path.endsWith('/late.txt')) {
        await fsp.writeFile(path, data, options)
        return
      }
      started += 1
      await gate
      await fsp.writeFile(path, data, options)
      finished += 1
    },
  } as VfsFileSystemIo
  const fs = new VfsFileSystem({ root, nodeFs: io })
  const shell = new WorkerShell({ fs })

  const pending = shell.run(['bash', '-c', "trap 'echo late > late.txt' EXIT; echo hi"], {
    cwd: CWD,
    timeoutMs: 100,
  })
  while (started === 0) await sleep(10)
  const result = await pending
  assert.equal(result.exitCode, 124)
  assert.equal(result.timedOut, true)
  assert.equal(finished, 0, 'the command must return before the stuck write settles')
  releaseWrite()
  for (let index = 0; index < 200 && (finished === 0 || await fs.exists(`${CWD}/late.txt`)); index += 1) {
    await sleep(10)
  }
  assert.equal(finished, 1, 'the abandoned write still completes in the background')
  assert.equal(await fs.exists(`${CWD}/late.txt`), false, 'the late write must be rolled back after it settles')
})

test('a failed rollback is reported as backend-failed instead of a clean interruption', { timeout: 5_000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-recheck-rollback-failed-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  let started = 0
  let finished = 0
  const io: VfsFileSystemIo = {
    ...fsp,
    async writeFile(path, data, options): Promise<void> {
      if (!path.endsWith('/late.txt')) {
        await fsp.writeFile(path, data, options)
        return
      }
      started += 1
      await sleep(150)
      await fsp.writeFile(path, data, options)
      finished += 1
    },
    async rm(path, options): Promise<void> {
      if (path.endsWith('/late.txt')) throw new Error('injected rollback denial')
      await fsp.rm(path, options)
    },
  } as VfsFileSystemIo
  const fs = new VfsFileSystem({ root, nodeFs: io })
  const shell = new WorkerShell({ fs })

  const result = await shell.run(['bash', '-c', "trap 'echo late > late.txt' EXIT; echo hi"], {
    cwd: CWD,
    timeoutMs: 50,
  })
  assert.equal(result.exitCode, 124)
  assert.equal(result.timedOut, true)
  assert.equal(started, 1)
  assert.equal(finished, 1, 'the backend write settled before the rollback attempt')
  assert.match(result.stderr, /reason=backend-failed/u,
    'failed snapshot restoration must not be reported as a clean timeout')
  assert.equal(await fs.exists(`${CWD}/late.txt`), true,
    'the failed restoration leaves the uncertain side effect visible for diagnosis')
})

test('a failed source staging cleanup is reported as backend-failed', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-recheck-source-cleanup-failed-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  const io: VfsFileSystemIo = {
    ...fsp,
    async rm(path, options): Promise<void> {
      if (path.includes('.pdsh-source-')) throw new Error('injected staging cleanup denial')
      await fsp.rm(path, options)
    },
  } as VfsFileSystemIo
  const fs = new VfsFileSystem({ root, nodeFs: io })
  await fs.writeFile(`${CWD}/trap.sh`, "trap 'sleep 5' EXIT; echo ready\n")
  const shell = new WorkerShell({ fs })

  const result = await shell.run(['bash', '-c', 'source /dsh/workspace/trap.sh'], {
    cwd: CWD,
    timeoutMs: 100,
  })
  assert.equal(result.exitCode, 124, result.stderr)
  assert.equal(result.timedOut, true, result.stderr)
  assert.match(result.stderr, /reason=backend-failed/u,
    'failed staging cleanup must not be mistaken for clean interruption')
  const staged = await fs.readdir('/dsh/tmp')
  assert.ok(staged.some(name => name.startsWith('.pdsh-source-')),
    'the failed cleanup leaves the stage visible for diagnosis')
})

test('source staging cleanup runs after an in-flight stage write settles', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-recheck-source-stage-race-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  let stageWriteStarted = false
  let stageWriteFinished = false
  const io: VfsFileSystemIo = {
    ...fsp,
    async writeFile(path, data, options): Promise<void> {
      if (path.includes('/.pdsh-source-')) {
        stageWriteStarted = true
        await sleep(150)
        await fsp.writeFile(path, data, options)
        stageWriteFinished = true
        return
      }
      await fsp.writeFile(path, data, options)
    },
  } as VfsFileSystemIo
  const fs = new VfsFileSystem({ root, nodeFs: io })
  await fs.writeFile(`${CWD}/lib.sh`, 'echo sourced\n')
  const shell = new WorkerShell({ fs })

  const result = await shell.run(['bash', '-c', 'source /dsh/workspace/lib.sh'], {
    cwd: CWD,
    timeoutMs: 40,
  })
  assert.equal(result.exitCode, 124, result.stderr)
  assert.equal(result.timedOut, true)
  assert.equal(stageWriteStarted, true)
  assert.equal(stageWriteFinished, true, 'the delayed stage write settled within its grace')
  assert.deepEqual(await fs.readdir('/dsh/tmp'), [],
    'cleanup after settlement removes the file the delayed write created')
})
