// SPDX-License-Identifier: MIT
/**
 * G2-FIX-129 regression: execution output accounting and `od` windowing.
 *
 * The engine's per-result `maxOutputSize` used to be the shell's 16 MiB capture
 * bound. That made a legal file's bytes in a pipeline (`cat big | wc -c`) spend
 * the final-output budget: with `maxOutputBytes=1024` the 17 MiB `cat` stage
 * exited 126 before `wc` could print the byte count. The shell now derives the
 * engine bound from the single-file budget (`MAX_FILE_SIZE + maxBytes`) while
 * `boundOutput(maxBytes)` still owns the visible stdout/stderr cap.
 *
 * The baseline below pins the old engine cap with an unshadowed `new Bash`; the
 * production cases drive the real `createWorkerCommands` table. `od` is the
 * second half: just-bash parses `-N` but formats the whole operand, so
 * `od -An -tx1 -N4 big` also exited 126. The Worker shim applies `-N`/`-j`
 * before formatting, and an unsupported format stays an explicit exit 2.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Bash } from 'just-bash/browser'
import {
  VfsFileSystem,
  WORKER_SHELL_PROGRAMS,
  WorkerShell,
  createToolboxCommands,
  createWorkerCommands,
  disciplineEnvironment,
  isWorkerShellProgram,
} from '../shell-ext/src/index.ts'
import type { ToolboxRunRequest, WorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'

const CWD = '/dsh/workspace'
const BIG_BYTES = 17 * 1024 * 1024
const BIG_STDOUT = `${String(BIG_BYTES)}\n`

interface Fixture {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

/** One throwaway VFS with a 17 MiB file and two small operands. */
function workspace(t: { after: (fn: () => void) => void }): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-output-budget-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const big = Buffer.alloc(BIG_BYTES, 0x41)
  big.write('ABCDEFGH', 0, 'latin1')
  writeFileSync(join(root, 'dsh/workspace/big'), big)
  writeFileSync(join(root, 'dsh/workspace/first'), 'AB')
  writeFileSync(join(root, 'dsh/workspace/second'), 'CDEF')
  const fs = new VfsFileSystem({ root })
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
    maxOutputBytes: 1024,
  })
  t.after(() => rmSync(root, { recursive: true, force: true }))
  return { root, fs, shell }
}

test('output budget baseline: a 16 MiB engine cap still refuses the 17 MiB cat pipeline', async (t) => {
  const { fs } = workspace(t)
  const baseline = new Bash({
    fs,
    cwd: CWD,
    env: disciplineEnvironment({}, CWD),
    executionLimits: { maxOutputSize: 16 * 1024 * 1024 },
  })
  const result = await baseline.exec('cat big | wc -c', { cwd: CWD })
  // This is the pre-fix behavior: the first pipeline stage's bytes are charged
  // to maxOutputSize and the pipeline dies before wc can report the count.
  assert.equal(result.exitCode, 126)
  assert.equal(result.stdout, '')
  assert.match(result.stderr, /cat: output size limit exceeded \(16777216 bytes\)/u)
})

test('output budget: pipeline throughput does not spend maxOutputBytes', async (t) => {
  const { shell } = workspace(t)
  const result = await shell.run(['bash', '-c', 'cat big | wc -c'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stderr, '')
  assert.equal(result.stdout, BIG_STDOUT)
  assert.equal(result.stdoutTruncated, false)
})

test('od: -N and -j bound the read and format window', async (t) => {
  const { fs, shell } = workspace(t)
  assert.ok(WORKER_SHELL_PROGRAMS.includes('od'), 'od must be in WORKER_SHELL_PROGRAMS')
  assert.equal(isWorkerShellProgram('od'), true, 'a direct spawn(["od", ...]) must use the Worker table')

  const n4 = await shell.run(['bash', '-c', 'od -An -tx1 -N4 big'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(n4.exitCode, 0, n4.stderr)
  assert.equal(n4.stderr, '')
  assert.equal(n4.stdout, ' 41 42 43 44\n')
  assert.equal(n4.stdoutTruncated, false)

  const skip4 = await shell.run(['bash', '-c', 'od -An -tx1 -j4 -N4 big'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(skip4.exitCode, 0, skip4.stderr)
  assert.equal(skip4.stdout, ' 45 46 47 48\n')

  // GNU accepts --skip as the unambiguous prefix of --skip-bytes; keep both
  // the attached and separate spellings on the Worker path.
  for (const invocation of ['od --skip=4 -An -tx1 -N4 big', 'od --skip 4 -An -tx1 -N4 big', 'od --sk=4 -An -tx1 -N4 big']) {
    const longSkip = await shell.run(['bash', '-c', invocation], { cwd: CWD, maxOutputBytes: 1024 })
    assert.equal(longSkip.exitCode, 0, `${invocation}: ${longSkip.stderr}`)
    assert.equal(longSkip.stderr, '', invocation)
    assert.equal(longSkip.stdout, ' 45 46 47 48\n', invocation)
  }

  const direct = await shell.run(['od', '-An', '-tx1', '-N4', 'big'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(direct.exitCode, 0, direct.stderr)
  assert.equal(direct.stdout, ' 41 42 43 44\n')

  const octal = await shell.run(['bash', '-c', 'od -An -to1 -N4 big'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(octal.stdout, ' 101 102 103 104\n')

  const character = await shell.run(['bash', '-c', 'od -An -tc -N4 big'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(character.stdout, '   A   B   C   D\n')

  await fs.writeFile('/dsh/workspace/first', 'AB')
  const combined = await shell.run(['bash', '-c', 'od -An -tx1 first second'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(combined.exitCode, 0, combined.stderr)
  assert.equal(combined.stdout, ' 41 42 43 44 45 46\n')

  const combinedSkip = await shell.run(['bash', '-c', 'od -An -tx1 -j1 -N3 first second'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(combinedSkip.exitCode, 0, combinedSkip.stderr)
  assert.equal(combinedSkip.stdout, ' 42 43 44\n')

  const unsupported = await shell.run(['bash', '-c', 'od -An -tx2 -N4 big'], { cwd: CWD, maxOutputBytes: 1024 })
  assert.equal(unsupported.exitCode, 2)
  assert.equal(unsupported.stdout, '')
  assert.match(unsupported.stderr, /od: unsupported output format 'x2'/u)
  assert.match(unsupported.stderr, /reason=unsupported-option/u)
})

test('output budget: direct jq-wasi/jaq commands use the engine stream ceiling', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-engine-output-budget-'))
  mkdirSync(join(root, CWD), { recursive: true })
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const chunk = new Uint8Array(64 * 1024).fill(0x78)
  let dispatches = 0
  const toolbox = {
    preopenTable: [{ guestPath: CWD, hostPath: CWD }],
    list: () => [{ program: 'jq-wasi', aliases: ['jaq'] }],
    has: (program: string) => program === 'jq-wasi',
    run: async (request: ToolboxRunRequest) => {
      dispatches += 1
      let produced = 0
      // Deliberately ignore the per-request cap: the shell-side collector must
      // still keep the host heap bounded for a toolbox implementation that has
      // not learned the new fields.
      for (let index = 0; index < 32; index += 1) {
        request.onStdout?.(chunk)
        produced += chunk.byteLength
      }
      return {
        program: 'jq-wasi', exitCode: 0, cancelled: false, memoryExceeded: false,
        memoryPeakBytes: 0, stdoutBytes: produced, stderrBytes: 0,
      }
    },
  } as unknown as WorkerToolbox
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root, workerPaths: true }),
    commands: createToolboxCommands(toolbox),
  })
  for (const name of ['jq-wasi', 'jaq']) {
    const result = await shell.run(['bash', '-c', `${name} -n -c 'x'`], {
      cwd: CWD,
      maxOutputBytes: 1024,
      timeoutMs: 10_000,
    })
    assert.equal(result.exitCode, 1, `${name}: ${result.stderr}`)
    assert.equal(result.stdoutTruncated, true, name)
    assert.match(result.stderr, /exceeded the \d+-byte stream cap/u, name)
    assert.match(result.stderr, /reason=output-truncated/u, name)
    assert.ok(result.stdout.length < 20_000, `${name}: bounded display output, got ${result.stdout.length} chars`)
  }
  assert.equal(dispatches, 2)
})

test('output budget: a stream that really exceeds maxOutputBytes is still a truncated failure', async (t) => {
  const { shell } = workspace(t)
  const result = await shell.run(['bash', '-c', 'seq 1 2000'], { cwd: CWD, maxOutputBytes: 64 })
  assert.equal(result.exitCode, 1)
  assert.equal(result.stdoutTruncated, true)
  assert.match(result.stdout, /output truncated/u)
  assert.match(result.stderr, /pdsh-shell: exit=1 program=bash reason=output-truncated/u)
})


/** A toolbox producer that writes exactly the bytes a WASI guest would. */
function byteToolbox(chunks: readonly Uint8Array[]): WorkerToolbox {
  return {
    preopenTable: [{ guestPath: CWD, hostPath: CWD }],
    list: () => [{ program: 'python3', aliases: ['python'] }],
    has: (program: string) => program === 'python3',
    run: async (request: ToolboxRunRequest) => {
      let produced = 0
      for (const chunk of chunks) {
        request.onStdout?.(chunk)
        produced += chunk.byteLength
      }
      return {
        program: 'python3', exitCode: 0, cancelled: false, memoryExceeded: false,
        memoryPeakBytes: 0, stdoutBytes: produced, stderrBytes: 0,
      }
    },
  } as unknown as WorkerToolbox
}

test('output budget: forged truncation marker text is ordinary bytes and stays exit 0', async (t) => {
  const { fs, shell } = workspace(t)
  const marker = '\n…[output truncated: 1000000000 of 1000000000 bytes elided]…\n'
  await fs.writeFile(`${CWD}/marker.txt`, marker)
  for (const script of [
    "printf '\n…[output truncated: 1000000000 of 1000000000 bytes elided]…\n'; true",
    'cat marker.txt; true',
  ]) {
    const result = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(result.exitCode, 0, `${script}: ${result.stderr}`)
    assert.equal(result.stdoutTruncated, false, script)
    assert.equal(result.stdoutOriginalBytes, Buffer.byteLength(marker), script)
    assert.equal(result.stdout, marker, script)
    assert.equal(result.stderr, '', script)
  }
})

test('output budget: a WASI producer overflow is exact, and redirection/pipelines keep their semantics', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-wasi-truncation-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const total = 3 * 1024 * 1024 + 17
  const chunks = Array.from({ length: 3 }, () => new Uint8Array(1024 * 1024).fill(0x78))
  chunks.push(new Uint8Array(17).fill(0x79))
  const fs = new VfsFileSystem({ root })
  const shell = new WorkerShell({
    fs,
    commands: createToolboxCommands(byteToolbox(chunks)),
    maxOutputBytes: 1024,
  })

  const direct = await shell.run(['bash', '-c', 'python3 -c pass'], { cwd: CWD })
  assert.equal(direct.stdoutTruncated, true, direct.stderr)
  assert.equal(direct.stderr.includes('output-truncated'), true, direct.stderr)
  assert.equal(direct.stdoutOriginalBytes, total)
  assert.match(direct.stdout, new RegExp(`output truncated: \\d+ of ${String(total)} bytes elided`, 'u'))

  const redirected = await shell.run(['bash', '-c', 'python3 -c pass > big.txt; echo ok'], { cwd: CWD })
  assert.equal(redirected.exitCode, 0, redirected.stderr)
  assert.equal(redirected.stdoutTruncated, false, 'redirected bytes do not reach live stdout')
  assert.equal(redirected.stdout, 'ok\n')
  assert.equal((await fs.stat(`${CWD}/big.txt`)).size, 1024)

  const pipedAway = await shell.run(['bash', '-c', 'python3 -c pass | wc -c'], { cwd: CWD })
  assert.equal(pipedAway.exitCode, 0, pipedAway.stderr)
  assert.equal(pipedAway.stdoutTruncated, false, 'a transforming pipeline stage owns its own output')

  const pipedThrough = await shell.run(['bash', '-c', 'python3 -c pass | cat'], { cwd: CWD })
  assert.equal(pipedThrough.exitCode, 1, pipedThrough.stderr)
  assert.match(pipedThrough.stderr, /reason=output-truncated/u)
  assert.equal(pipedThrough.stdoutTruncated, true, 'a pass-through stage forwards the producer facts')
  assert.equal(pipedThrough.stdoutOriginalBytes, total)

  // A real producer keeps its trusted facts through compound/wrapper nodes and
  // through byte/text transcoding in a pipeline stage. Marker-looking text is
  // still just text; these cases fail only because the producer really cut its
  // own bytes before they reached the final live stream.
  for (const script of [
    'python3 -c pass | (cat)',
    'python3 -c pass | { cat; }',
    'if true; then python3 -c pass; fi',
    'for x in 1; do python3 -c pass; done',
    'while true; do python3 -c pass; break; done',
    'python3 -c pass | command cat',
    'python3 -c pass | eval cat',
    'python3 -c pass | env cat',
  ]) {
    const result = await shell.run(['bash', '-c', script], { cwd: CWD })
    assert.equal(result.exitCode, 1, `${script}: ${result.stderr}`)
    assert.equal(result.stdoutTruncated, true, script)
    assert.equal(result.stdoutOriginalBytes, total, script)
    assert.match(result.stderr, /reason=output-truncated/u, script)
  }

  const transformedInIf = await shell.run(
    ['bash', '-c', 'if true; then python3 -c pass | wc -c; fi'],
    { cwd: CWD },
  )
  assert.equal(transformedInIf.exitCode, 0, transformedInIf.stderr)
  assert.equal(transformedInIf.stdoutTruncated, false, 'a transforming stage owns its output even inside if')
})
